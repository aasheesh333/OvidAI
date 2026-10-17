import { lookup as dnsLookup } from "node:dns/promises";
import { isIP } from "node:net";
import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import { byokKeysRepo, newId, users, type ByokKeyRow, type Db } from "@ovid/db";
import {
  byokRecordId,
  EndpointRejectedError,
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
 *    echoed, logged or stored.
 *  - `GET /byok` projects metadata only — the four ciphertext columns never
 *    leave the DB.
 *  - `DELETE /byok/:id` is owner-scoped; unknown id and wrong owner are the
 *    same 404 (no existence leak).
 *  - `POST /byok/:id/test` decrypts, resolves the host, refuses private /
 *    link-local / loopback / metadata targets (SSRF), then probes the
 *    provider's `GET <endpoint>/models` with a 10 s timeout. Probe errors are
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

    // SSRF guard: resolve the canonical endpoint's host and refuse private,
    // link-local, loopback, CGNAT and metadata targets BEFORE any fetch.
    let target: { host: string; port: number };
    try {
      target = probeTarget(row.endpoint);
      if (!ALLOWED_PROBE_PORTS.has(target.port)) throw new EndpointRejectedError();
      const addresses = await resolveAddresses(target.host, deps.lookupHost);
      if (addresses.some(isUnsafeAddress)) throw new EndpointRejectedError();
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

/** `<endpoint>/models`, preserving any query string the endpoint carries. */
function modelsUrl(endpoint: string): string {
  const queryAt = endpoint.indexOf("?");
  const base = queryAt < 0 ? endpoint : endpoint.slice(0, queryAt);
  const query = queryAt < 0 ? "" : endpoint.slice(queryAt);
  return `${base.replace(/\/+$/, "")}/models${query}`;
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

/** RFC1918 / loopback / link-local / CGNAT / multicast / ULA / metadata. */
function isUnsafeAddress(address: string): boolean {
  const family = isIP(address);
  if (family === 4) {
    const [a, b, c] = address.split(".").map(Number) as [number, number, number];
    if (a === 0 || a === 10 || a === 127) return true;
    if (a === 169 && b === 254) return true; // link-local + metadata
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT
    if (a === 192 && b === 0 && (c === 0 || c === 2)) return true;
    if (a === 198 && (b === 18 || b === 19)) return true;
    if (a >= 224) return true; // multicast + reserved
    return false;
  }
  if (family === 6) {
    const lower = address.toLowerCase();
    if (lower === "::" || lower === "::1") return true;
    if (/^fe[89ab]/.test(lower)) return true; // fe80::/10 link-local
    if (/^f[cd]/.test(lower)) return true; // fc00::/7 unique-local
    const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(lower);
    if (mapped !== null) return isUnsafeAddress(mapped[1]!);
    const mappedHex = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(lower);
    if (mappedHex !== null) {
      const hi = parseInt(mappedHex[1]!, 16);
      const lo = parseInt(mappedHex[2]!, 16);
      return isUnsafeAddress(`${hi >> 8}.${hi & 0xff}.${lo >> 8}.${lo & 0xff}`);
    }
    return false;
  }
  return true; // unparseable → unsafe
}
