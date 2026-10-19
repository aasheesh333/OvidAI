import { lookup as dnsLookup } from "node:dns/promises";
import { isIP } from "node:net";
import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import { accountSettings, byokKeysRepo, newId, users, type ByokKeyRow, type Db } from "@ovid/db";
import {
  byokRecordId,
  EndpointRejectedError,
  isNonPublicAddress,
  validateEndpoint,
  type EnvelopeCrypto,
} from "@ovid/escrow";
import { sendError, zodBadRequest } from "./http.js";

/**
 * BYOK escrow routes (P9 Task 11).
 *
 *  - `POST /byok` validates + canonicalizes the provider endpoint (the Python
 *    sync contract, ported in @ovid/escrow) and envelope-encrypts the API key
 *    under the row's recordId (`byok_keys:{id}`). The plaintext is NEVER
 *    echoed, logged or stored. The stored endpoint is UNTRUSTED at use time:
 *    this route checks only its grammar (see the SECURITY note at the insert).
 *  - `GET /byok` projects metadata only — the four ciphertext columns never
 *    leave the DB.
 *  - `DELETE /byok/:id` is owner-scoped; unknown id and wrong owner are the
 *    same 404 (no existence leak).
 *  - `POST /byok/:id/test` validates the target (port allow-list + the
 *    canonical `isNonPublicAddress` classifier), then decrypts and probes the
 *    provider's `GET <endpoint>/models` with a 10 s timeout. The DNS check is
 *    ADVISORY, not binding: `fetch` resolves again at connect time, so the
 *    rebinding TOCTOU documented at the fetch below remains. Probe errors are
 *    sanitized; the result is persisted via byokKeysRepo.setTestResult.
 *
 * All routes sit behind the gateway authHook; `request.principal.uid` is the
 * only owner identity ever used.
 */

/** Injectable seams for the probe (never set by the composition root). */
export interface ByokRouteOverrides {
  fetchImpl?: typeof fetch;
  lookupHost?: (host: string) => Promise<string[]>;
}

export interface ByokDeps extends ByokRouteOverrides {
  db: Db;
  /** Envelope crypto; absent → POST/test answer a loud 503. */
  crypto?: EnvelopeCrypto;
}

const createBodySchema = z
  .object({
    providerId: z.string().trim().min(1).max(200),
    // The endpoint grammar belongs to validateEndpoint (not zod): non-strings
    // must still yield endpoint_rejected, not a generic bad_request.
    endpoint: z.unknown(),
    apiKey: z.string().min(1).max(16_384),
    label: z.string().trim().max(200).nullable().optional(),
  })
  .strict();

const PROBE_TIMEOUT_MS = 10_000;
const ALLOWED_PROBE_PORTS = new Set([443, 80]);

/**
 * Row-growth hygiene (review L3): an authenticated account may store at most
 * this many BYOK entries. The check is best-effort under concurrency (two
 * simultaneous POSTs can land at cap+1); it exists to stop unbounded storage
 * growth, not to enforce a billing quota.
 */
export const MAX_BYOK_KEYS_PER_USER = 20;

/** Hostnames that are metadata services even before DNS resolution. */
const METADATA_HOSTS = new Set([
  "metadata",
  "metadata.google.internal",
  "instance-data",
  "instance-data.ec2.internal",
]);

function unavailable(reply: FastifyReply): FastifyReply {
  return sendError(reply, 503, "unavailable", "BYOK escrow is not configured.");
}

function endpointRejected(reply: FastifyReply): FastifyReply {
  return sendError(
    reply,
    400,
    "endpoint_rejected",
    "The provider endpoint is not an allowed endpoint identity.",
  );
}

function project(row: ByokKeyRow): Record<string, unknown> {
  return {
    id: row.id,
    providerId: row.providerId,
    endpoint: row.endpoint,
    label: row.label,
    status: row.status,
    lastTestAt: row.lastTestAt,
    lastTestOk: row.lastTestOk,
    createdAt: row.createdAt,
  };
}

export function registerByokRoutes(app: FastifyInstance, deps: ByokDeps): void {
  app.post("/byok", async (request, reply) => {
    if (deps.crypto === undefined) return unavailable(reply);

    const parsed = createBodySchema.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const body = parsed.data;

    let endpoint: string;
    try {
      endpoint = validateEndpoint(body.endpoint, body.providerId);
    } catch (err) {
      if (err instanceof EndpointRejectedError) return endpointRejected(reply);
      throw err;
    }

    const uid = request.principal.uid;
    // FK: byok_keys.user_id references users.uid (same provisioning the other
    // authenticated routes do).
    await users.ensure(deps.db, uid, request.principal.email);

    // L3 row cap. list() is metadata+ciphertext rows, but the bound is small
    // and this avoids widening the repo surface for a hygiene check.
    const existing = await byokKeysRepo.list(deps.db, uid);
    if (existing.length >= MAX_BYOK_KEYS_PER_USER) {
      return sendError(
        reply,
        409,
        "limit_reached",
        `At most ${MAX_BYOK_KEYS_PER_USER} BYOK keys may be stored per account.`,
      );
    }

    // ── SECURITY: the stored endpoint is UNTRUSTED at use time ────────────
    // validateEndpoint proves only that `endpoint` is a well-formed, canonical
    // provider identity. It deliberately accepts private/loopback literals
    // (https://127.0.0.1/v1, https://10.x, https://169.254.169.254) — the
    // /test route applies the egress guard, but the dangerous consumer is the
    // worker dialing this endpoint for a real run (P9 Task 9).
    //
    // Every consumer MUST send the decrypted endpoint through guarded egress
    // (resolve + classify + refuse non-public answers). NEVER add a
    // user-supplied endpoint to `createProviderEgress`'s trusted
    // `providerBaseUrls`: only operator-configured origins (litellm /
    // anthropic base URLs) may bypass that guard. This is a T9 requirement;
    // do not relax it here.
    const id = newId();
    const envelope = deps.crypto.encrypt(body.apiKey, byokRecordId(id));
    // byokKeysRepo.create spreads the row over its generated id, so passing an
    // explicit `id` here pins the id the envelope AAD was bound to. The extra
    // properties are structurally ignored by ByokKeyInsert's type.
    const insert = {
      id,
      userId: uid,
      providerId: body.providerId,
      endpoint,
      label: body.label ?? null,
      wrappedDek: envelope.wrappedDek,
      iv: envelope.iv,
      ciphertext: envelope.ciphertext,
      tag: envelope.tag,
      status: "untested",
    };
    const row = await byokKeysRepo.create(deps.db, insert);

    return reply.code(201).send({
      id: row.id,
      providerId: row.providerId,
      endpoint: row.endpoint,
      label: row.label,
      createdAt: row.createdAt,
      status: row.status,
    });
  });

  app.get("/byok", async (request) => {
    const rows = await byokKeysRepo.list(deps.db, request.principal.uid);
    return { items: rows.map(project) };
  });

  app.delete("/byok/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const removed = await byokKeysRepo.remove(deps.db, id, request.principal.uid);
    if (!removed) {
      return sendError(reply, 404, "not_found", "BYOK key not found.");
    }
    // Wave 4 (SE-004): runs must never reference a deleted key — a default
    // pointing at it falls back to Ovid models.
    await accountSettings.clearByokDefaultIfKey(deps.db, request.principal.uid, id);
    return reply.code(204).send();
  });

  app.post("/byok/:id/test", async (request, reply) => {
    if (deps.crypto === undefined) return unavailable(reply);
    const uid = request.principal.uid;
    const { id } = request.params as { id: string };

    const row = await byokKeysRepo.get(deps.db, id, uid);
    if (row === null) {
      return sendError(reply, 404, "not_found", "BYOK key not found.");
    }

    // SSRF guard: validate the target BEFORE decrypting (review L4), so a
    // request that can never be probed does not materialize the plaintext key
    // at all. Resolve the canonical endpoint's host and refuse private,
    // link-local, loopback, CGNAT and metadata targets before any fetch.
    let target: { host: string; port: number };
    try {
      target = probeTarget(row.endpoint);
      if (!ALLOWED_PROBE_PORTS.has(target.port)) throw new EndpointRejectedError();
      const addresses = await resolveAddresses(target.host, deps.lookupHost);
      if (addresses.some(isNonPublicAddress)) throw new EndpointRejectedError();
    } catch (err) {
      if (err instanceof EndpointRejectedError) {
        await setTestResult(deps.db, row.id, false, request);
        return endpointRejected(reply);
      }
      // DNS failure is a probe failure, not a contract rejection.
      request.log.warn({ err, byokId: row.id }, "BYOK probe DNS resolution failed");
      await setTestResult(deps.db, row.id, false, request);
      return reply.code(200).send({ ok: false, error: "dns_resolution_failed" });
    }

    let apiKey: string;
    try {
      apiKey = deps.crypto.decrypt(
        {
          wrappedDek: row.wrappedDek,
          iv: row.iv,
          ciphertext: row.ciphertext,
          tag: row.tag,
        },
        byokRecordId(row.id),
      );
    } catch (err) {
      request.log.error({ err, byokId: row.id }, "BYOK envelope failed to decrypt");
      await setTestResult(deps.db, row.id, false, request);
      return sendError(reply, 500, "internal", "BYOK key could not be decrypted.");
    }

    // ── DNS-rebinding TOCTOU: accepted risk, documented (review M1) ───────
    // The guard above resolves the host and refuses non-public answers, but
    // `fetch` performs its OWN resolution at connect time. A resolver with a
    // near-zero TTL (or an alternating answer set) can therefore return a
    // public address to the check and a private/metadata address to the
    // transport. This is the same remaining limit documented at the top of
    // `@ovid/agent-core/src/ssrf.ts`; the resolution is advisory, not binding.
    //
    // Why the validated address is not pinned here: pinning needs a
    // per-request DNS lookup (or connect-to-IP + Host/SNI split), which the
    // WHATWG `fetch` surface does not expose. Doing it would require an
    // undici Agent (not a gateway dependency) or node:https with a custom
    // `lookup`, replacing the injectable `fetchImpl` seam the probe tests use
    // and coupling the route to one transport. The exposure is bounded
    // instead: the endpoint policy is HTTPS-ONLY (never widen it to http),
    // TLS verification makes a rebind to an internal HTTP service
    // (metadata/admin) fail the handshake unless it holds a certificate valid
    // for the user's hostname, redirects are not followed, and the response
    // body is cancelled unread below — only the status code is surfaced. The
    // worst case is blind SSRF with no response or metadata read.
    const fetchImpl = deps.fetchImpl ?? fetch;
    let ok = false;
    let error: string | undefined;
    try {
      const response = await fetchImpl(modelsUrl(row.endpoint), {
        method: "GET",
        // No redirect following: a public endpoint must not be able to bounce
        // the probe into a private target (redirect-based SSRF).
        redirect: "manual",
        headers: {
          authorization: `Bearer ${apiKey}`,
          accept: "application/json",
        },
        signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
      });
      ok = response.ok;
      if (!ok) error = `HTTP ${response.status}`;
      // Never read or forward the body (provider payloads may be large).
      try {
        await response.body?.cancel();
      } catch {
        /* already consumed/absent */
      }
    } catch {
      error = "request_failed";
    }

    await setTestResult(deps.db, row.id, ok, request);
    return reply.code(200).send(error === undefined ? { ok } : { ok, error });
  });
}

async function setTestResult(
  db: Db,
  id: string,
  ok: boolean,
  request: { log: { warn: (obj: unknown, msg: string) => void } },
): Promise<void> {
  try {
    await byokKeysRepo.setTestResult(db, id, ok, new Date());
  } catch (err) {
    // The probe answer still reaches the caller; persistence failure is logged.
    request.log.warn({ err, byokId: id }, "BYOK test result could not be persisted");
  }
}

/**
 * `<endpoint>/models`, preserving any query string the endpoint carries.
 * An endpoint already ending in the `/models` PATH segment is used as-is
 * (review L5: do not produce `…/models/models`). The check looks at the path
 * only, so a host literally named `models` is not mistaken for the segment.
 */
function modelsUrl(endpoint: string): string {
  const queryAt = endpoint.indexOf("?");
  const base = queryAt < 0 ? endpoint : endpoint.slice(0, queryAt);
  const query = queryAt < 0 ? "" : endpoint.slice(queryAt);
  const trimmed = base.replace(/\/+$/, "");
  const schemeEnd = trimmed.indexOf("://");
  const pathStart = schemeEnd < 0 ? -1 : trimmed.indexOf("/", schemeEnd + 3);
  const path = pathStart < 0 ? "" : trimmed.slice(pathStart);
  const withModels = path.endsWith("/models") ? trimmed : `${trimmed}/models`;
  return `${withModels}${query}`;
}

/** Extract host + port from an already-canonical endpoint. */
function probeTarget(endpoint: string): { host: string; port: number } {
  let scheme: "https" | "http";
  let rest: string;
  if (endpoint.startsWith("https://")) {
    scheme = "https";
    rest = endpoint.slice("https://".length);
  } else if (endpoint.startsWith("http://")) {
    scheme = "http";
    rest = endpoint.slice("http://".length);
  } else {
    throw new EndpointRejectedError();
  }

  const cut = rest.search(/[/?]/);
  if (cut >= 0) rest = rest.slice(0, cut);

  let host: string;
  let port = scheme === "https" ? 443 : 80;
  if (rest.startsWith("[")) {
    const close = rest.indexOf("]");
    if (close < 0) throw new EndpointRejectedError();
    host = rest.slice(1, close);
    const tail = rest.slice(close + 1);
    if (tail.startsWith(":")) port = Number(tail.slice(1));
  } else {
    const colon = rest.indexOf(":");
    host = colon < 0 ? rest : rest.slice(0, colon);
    if (colon >= 0) port = Number(rest.slice(colon + 1));
  }

  if (host === "" || !Number.isInteger(port)) throw new EndpointRejectedError();
  return { host, port };
}

async function resolveAddresses(
  host: string,
  lookupHost: ((host: string) => Promise<string[]>) | undefined,
): Promise<string[]> {
  if (isIP(host) !== 0) return [host];
  if (METADATA_HOSTS.has(host.toLowerCase())) throw new EndpointRejectedError();
  const lookup =
    lookupHost ??
    (async (name: string) =>
      (await dnsLookup(name, { all: true })).map((entry) => entry.address));
  const addresses = await lookup(host);
  if (addresses.length === 0) throw new EndpointRejectedError();
  return addresses;
}
