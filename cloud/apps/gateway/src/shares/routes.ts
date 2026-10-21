import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { sharesRepo, type Db } from "@ovid/db";
import type { AuthPrincipal, Verifier } from "../auth.js";
import { sqlText } from "../sql.js";
import { pageCsp, SHARES_HEADERS } from "./headers.js";
import { parseCreateShare, parseForkShare, ShareValidationError } from "./snapshot.js";
import { escapeHtml, landingPage, packageName, playStoreUrl } from "./viewer.js";

/**
 * Legacy share routes — port of `server/shares/api.py`.
 *
 * Registered on the gateway ROOT (Caddy proxies `/shares*`, `/s/*` and
 * `/.well-known/assetlinks.json` verbatim), NOT under `/cloud/v1`. Wire shapes
 * are the Python snake_case ones and every failure is the legacy
 * `{"detail": code}` body — never the cloud ApiError envelope.
 */

const MAX_RAW_BYTES = 1_500_000;
const DEFAULT_TTL_SECONDS = 30 * 86400;
const ACTIVE_LIMIT = 100;
const LIFETIME_LIMIT = 1000;
const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
const FINGERPRINT_RE = /^[0-9A-F]{2}(?::[0-9A-F]{2}){31}$/;

const NOT_FOUND_PAGE =
  "<!doctype html><title>Link unavailable</title><h1>Link unavailable</h1>" +
  "<p>This link was revoked or has expired.</p>";
const INVITE_NOT_FOUND_PAGE =
  "<!doctype html><title>Link unavailable</title><h1>Link unavailable</h1>";

const PAGE_CSP = pageCsp();
/** Reply marker: assetlinks may be publicly cached (plan-pinned header). */
const PUBLIC_CACHE = Symbol("ovid.assetlinks.publicCache");

/**
 * Task 15 `lifecycle.access` seam. Runs the operation under the deletion
 * fence; throws an AccountError-shaped `{status, code}` to deny. Absent in
 * tests/dev → only the Python `invalid_identity` guard runs.
 */
export type ShareAdmission = <T>(
  principal: AuthPrincipal,
  fn: (uid: string) => Promise<T>,
) => Promise<T>;

/**
 * Per-uid token bucket for the WRITE endpoints (create + fork). The quota is
 * a product limit, not a burst limiter: without this an account can hammer
 * the create path (and the per-owner quota lock) as fast as the network allows.
 */
export interface ShareRateLimit {
  /** Burst size handed out to a cold caller. */
  capacity: number;
  /** Tokens replenished per second. */
  refillPerSecond: number;
}

export const DEFAULT_SHARE_RATE_LIMIT: ShareRateLimit = {
  capacity: 10,
  refillPerSecond: 0.5,
};

/** Hard bound on the bucket map so hostile uids cannot grow it forever. */
const MAX_RATE_BUCKETS = 10_000;

export interface SharesDeps {
  db: Db;
  /** The gateway verifier, mapped onto the Python `verify_uid` contract. */
  verifier: Verifier;
  /** OVID_SHARE_BASE_URL — receipts/viewer URLs are built ONLY from this. */
  baseUrl: string;
  admission?: ShareAdmission;
  clock?: () => Date;
  ttlSeconds?: number;
  rateLimit?: ShareRateLimit;
}

/** Composition-root config: db/verifier come from GatewayDeps. */
export type SharesConfig = Omit<SharesDeps, "db" | "verifier">;

/** Legacy HTTP error carrying the Python `(status, code)` pair. */
export class SharesHttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
    this.name = "SharesHttpError";
  }
}

interface PublicBase {
  /** Configured origin without a trailing slash. */
  base: string;
  /** URL netloc (host[:port]) — used for the Android intent, never Host. */
  host: string;
  /** URL path prefix ("" or "/prefix"). */
  path: string;
}

/**
 * Python `router()` base-URL validation: HTTPS deployment origin, no
 * credentials/query/fragment, and a path of `[A-Za-z0-9_-]` segments only.
 * A bad value is a deployment misconfiguration and fails at registration.
 */
function resolveBase(raw: string): PublicBase {
  const trimmed = raw.trim().replace(/\/+$/, "");
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new Error("OVID_SHARE_BASE_URL must be an absolute https URL");
  }
  const path = parsed.pathname === "/" ? "" : parsed.pathname;
  if (
    parsed.protocol !== "https:" ||
    parsed.hostname === "" ||
    parsed.username !== "" ||
    parsed.password !== "" ||
    parsed.search !== "" ||
    parsed.hash !== "" ||
    (path !== "" && !/^(?:\/[A-Za-z0-9_-]+)+$/.test(path))
  ) {
    throw new Error(
      "OVID_SHARE_BASE_URL must be a configured HTTPS deployment base URL " +
        "(no credentials, query, fragment or arbitrary path)",
    );
  }
  return { base: trimmed, host: parsed.host, path };
}

function headerValue(raw: string | string[] | undefined): string | null {
  const value = Array.isArray(raw) ? raw[0] : raw;
  return typeof value === "string" && value !== "" ? value : null;
}

function sendDetail(reply: FastifyReply, status: number, code: string): FastifyReply {
  return reply.code(status).send({ detail: code });
}

/** AccountError / ShareError / SharesHttpError all carry `{status, code}`. */
function knownError(error: unknown): { status: number; code: string } | null {
  if (typeof error !== "object" || error === null) return null;
  const candidate = error as { status?: unknown; code?: unknown };
  if (typeof candidate.code === "string" && typeof candidate.status === "number") {
    return { status: candidate.status, code: candidate.code };
  }
  return null;
}

function nowOf(deps: SharesDeps): Date {
  return deps.clock ? deps.clock() : new Date();
}

/** Bearer + App Check via the gateway verifier → Python error codes. */
async function requirePrincipal(
  request: FastifyRequest,
  verifier: Verifier,
): Promise<AuthPrincipal> {
  const authorization = headerValue(request.headers.authorization);
  if (authorization === null || !authorization.startsWith("Bearer ")) {
    throw new SharesHttpError(401, "authentication_required");
  }
  const idToken = authorization.slice("Bearer ".length);
  if (idToken.trim() === "") throw new SharesHttpError(401, "authentication_required");
  try {
    return await verifier(idToken, headerValue(request.headers["x-firebase-appcheck"]));
  } catch {
    throw new SharesHttpError(401, "invalid_authentication");
  }
}

/** Python's admission context manager (no admission → identity guard only). */
async function withAdmission<T>(
  deps: SharesDeps,
  principal: AuthPrincipal,
  fn: (uid: string) => Promise<T>,
): Promise<T> {
  if (deps.admission !== undefined) return deps.admission(principal, fn);
  if (typeof principal.uid !== "string" || principal.uid.trim() === "") {
    throw new SharesHttpError(401, "invalid_identity");
  }
  return fn(principal.uid);
}

function toRepoBody(body: ReturnType<typeof parseCreateShare>) {
  return {
    sessionId: body.session_id,
    requestId: body.request_id,
    messages: body.messages.map((message) => ({
      role: message.role,
      content: message.content,
    })),
  };
}

function receiptJson(
  receipt: { token: string; sessionId: string; requestId: string; createdAt: Date; expiresAt: Date },
  base: string,
): Record<string, unknown> {
  return {
    id: receipt.token,
    session_id: receipt.sessionId,
    request_id: receipt.requestId,
    created_at: receipt.createdAt.getTime() / 1000,
    expires_at: receipt.expiresAt.getTime() / 1000,
    url: `${base}/s/${receipt.token}`,
  };
}

/**
 * Quota counters read INSIDE the caller's transaction (raw SQL: the repo's
 * `counts()` takes a `Db`, not a transaction handle, and the whole point is
 * that the count and the insert are one atomic unit).
 */
async function countSharesInTransaction(
  tx: Db,
  uid: string,
  now: Date,
): Promise<{ active: number; lifetime: number }> {
  const rows = (await tx.execute(
    `SELECT
       count(*) FILTER (
         WHERE revoked_at IS NULL AND content IS NOT NULL AND expires_at > ${sqlText(
           now.toISOString(),
         )}::timestamptz
       )::int AS active,
       count(*)::int AS lifetime
     FROM shares
     WHERE owner_uid = ${sqlText(uid)}`,
  )) as unknown as Array<{ active: number; lifetime: number }>;
  return { active: Number(rows[0]?.active ?? 0), lifetime: Number(rows[0]?.lifetime ?? 0) };
}

/**
 * Create ONE share with the quota enforced inside the insert transaction
 * (Python parity). The per-owner advisory lock serializes concurrent creates,
 * so N parallel requests can never all observe "one slot left".
 *
 * ORDER is preserved: when at the boundary, an existing (owner, requestId)
 * receipt still falls through to `create()` — identical content replays the
 * receipt, revoked/expired/changed content is its 409 — and only a genuinely
 * new request is 429.
 */
async function createWithQuota(
  deps: SharesDeps,
  uid: string,
  body: ReturnType<typeof parseCreateShare>,
  now: Date,
) {
  return deps.db.transaction(async (tx) => {
    await tx.execute(`SELECT pg_advisory_xact_lock(hashtext(${sqlText(`shares:${uid}`)}))`);
    const counts = await countSharesInTransaction(tx as unknown as Db, uid, now);
    if (counts.active >= ACTIVE_LIMIT || counts.lifetime >= LIFETIME_LIMIT) {
      const previous = (await tx.execute(
        `SELECT token FROM shares
         WHERE owner_uid = ${sqlText(uid)} AND request_id = ${sqlText(body.request_id)}
         LIMIT 1`,
      )) as unknown as unknown[];
      if (previous.length === 0) {
        if (counts.active >= ACTIVE_LIMIT) {
          throw new SharesHttpError(429, "share_limit_reached");
        }
        throw new SharesHttpError(429, "share_storage_limit_reached");
      }
    }
    // drizzle nests this as a savepoint on the SAME transaction, so the row
    // commits only together with the quota check above.
    return sharesRepo.create(tx as unknown as Db, uid, toRepoBody(body), {
      now,
      ttlSeconds: deps.ttlSeconds ?? DEFAULT_TTL_SECONDS,
    });
  });
}

/** Per-uid token bucket; `false` = over budget (legacy 429 `rate_limited`). */
function createTokenBucket(
  config: ShareRateLimit,
  now: () => Date,
): (uid: string) => boolean {
  const capacity = Math.max(1, config.capacity);
  const refillPerSecond = Math.max(0, config.refillPerSecond);
  const buckets = new Map<string, { tokens: number; updatedAt: number }>();
  return (uid: string): boolean => {
    const nowMs = now().getTime();
    let bucket = buckets.get(uid);
    if (bucket === undefined) {
      if (buckets.size >= MAX_RATE_BUCKETS) buckets.clear();
      bucket = { tokens: capacity, updatedAt: nowMs };
      buckets.set(uid, bucket);
    }
    const elapsedSeconds = Math.max(0, nowMs - bucket.updatedAt) / 1000;
    bucket.tokens = Math.min(capacity, bucket.tokens + elapsedSeconds * refillPerSecond);
    bucket.updatedAt = nowMs;
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  };
}

async function publicSnapshot(
  deps: SharesDeps,
  token: string,
): Promise<{ sessionId: string; messages: { role: string; content: string }[] } | null> {
  if (!TOKEN_RE.test(token)) return null;
  return sharesRepo.publicSnapshot(deps.db, token, { now: nowOf(deps) });
}

export function registerSharesRoutes(app: FastifyInstance, deps: SharesDeps): void {
  const publicBase = resolveBase(deps.baseUrl);
  const takeToken = createTokenBucket(
    deps.rateLimit ?? DEFAULT_SHARE_RATE_LIMIT,
    () => nowOf(deps),
  );

  app.register(async (scope) => {
    // Legacy error shape for every failure in this scope.
    scope.setErrorHandler((error, request, reply) => {
      const known = knownError(error);
      if (known !== null) return sendDetail(reply, known.status, known.code);
      if (error instanceof ShareValidationError) {
        return sendDetail(reply, 422, "invalid_snapshot");
      }
      if ((error as { code?: string }).code === "FST_ERR_CTP_BODY_TOO_LARGE") {
        return sendDetail(reply, 413, "snapshot_too_large");
      }
      if (error instanceof SyntaxError) {
        return sendDetail(reply, 422, "invalid_snapshot");
      }
      // Python's ShareRoute turns every request-body validation failure into
      // the same 422 shape (never echoing the rejected body). A missing or
      // unsupported content type is Fastify's equivalent of that failure.
      if ((error as { code?: string }).code === "FST_ERR_CTP_INVALID_MEDIA_TYPE") {
        return sendDetail(reply, 422, "invalid_snapshot");
      }
      request.log.error({ err: error }, "shares route failed");
      return sendDetail(reply, 503, "shares_unavailable");
    });

    // Bound the raw body BEFORE JSON decoding (Python ShareRoute does this on
    // the request stream). Fastify's parser bodyLimit is the chunked-request
    // bound; the onRequest guard catches a declared oversized Content-Length.
    scope.addContentTypeParser(
      "application/json",
      { parseAs: "buffer", bodyLimit: MAX_RAW_BYTES },
      (_request, body, done) => {
        try {
          done(null, JSON.parse(body.toString("utf8")));
        } catch {
          done(new ShareValidationError());
        }
      },
    );

    scope.addHook("onRequest", async (request, reply) => {
      if (request.method !== "POST" && request.method !== "PUT") return;
      const raw = headerValue(request.headers["content-length"]);
      if (raw === null) return;
      if (!/^\d+$/.test(raw) || Number(raw) > MAX_RAW_BYTES) {
        await reply.code(413).send({ detail: "snapshot_too_large" });
      }
    });

    // Python's ShareRoute wrapper: HEADERS on every response; landing pages
    // keep their script-bearing CSP; assetlinks keeps its public cache rule.
    scope.addHook("onSend", async (_request, reply, payload) => {
      const landing = reply.getHeader("content-security-policy") === PAGE_CSP;
      for (const [name, value] of Object.entries(SHARES_HEADERS)) reply.header(name, value);
      if (landing) reply.header("Content-Security-Policy", PAGE_CSP);
      if ((reply as unknown as Record<symbol, boolean>)[PUBLIC_CACHE] === true) {
        reply.header("Cache-Control", "public, max-age=3600");
      }
      return payload;
    });

    scope.post("/shares", async (request, reply) => {
      const principal = await requirePrincipal(request, deps.verifier);
      if (!takeToken(principal.uid)) throw new SharesHttpError(429, "rate_limited");
      const body = parseCreateShare(request.body);
      const receipt = await withAdmission(deps, principal, (uid) =>
        createWithQuota(deps, uid, body, nowOf(deps)),
      );
      return reply.code(201).send(receiptJson(receipt, publicBase.base));
    });

    scope.get("/shares", async (request, reply) => {
      const principal = await requirePrincipal(request, deps.verifier);
      const query = request.query as Record<string, unknown>;
      const sessionId = typeof query.session_id === "string" ? query.session_id : null;
      if (sessionId !== null && Array.from(sessionId).length > 128) {
        throw new ShareValidationError();
      }
      const rows = await withAdmission(deps, principal, (uid) =>
        sharesRepo.list(deps.db, uid, sessionId, { now: nowOf(deps) }),
      );
      return reply.send({ shares: rows.map((row) => receiptJson(row, publicBase.base)) });
    });

    scope.put("/shares/:token", async (request, reply) => {
      const principal = await requirePrincipal(request, deps.verifier);
      const body = parseCreateShare(request.body);
      const { token } = request.params as { token: string };
      const receipt = await withAdmission(deps, principal, (uid) =>
        sharesRepo.update(deps.db, uid, token, toRepoBody(body), { now: nowOf(deps) }),
      );
      return reply.send(receiptJson(receipt, publicBase.base));
    });

    scope.delete("/shares/:token", async (request, reply) => {
      const principal = await requirePrincipal(request, deps.verifier);
      const { token } = request.params as { token: string };
      await withAdmission(deps, principal, (uid) =>
        sharesRepo.revoke(deps.db, uid, token, { now: nowOf(deps) }),
      );
      return reply.code(204).send();
    });

    scope.post("/shares/:token/fork", async (request, reply) => {
      const principal = await requirePrincipal(request, deps.verifier);
      if (!takeToken(principal.uid)) throw new SharesHttpError(429, "rate_limited");
      const body = parseForkShare(request.body);
      const { token } = request.params as { token: string };
      const result = await withAdmission(deps, principal, (uid) =>
        sharesRepo.fork(deps.db, uid, token, body.request_id, { now: nowOf(deps) }),
      );
      return reply.code(201).send({ session_id: result.sessionId });
    });

    // Public JSON snapshot — no auth, no owner metadata.
    scope.get("/s/:token.json", async (request, reply) => {
      const { token } = request.params as { token: string };
      const snapshot = await publicSnapshot(deps, token);
      if (snapshot === null) return sendDetail(reply, 404, "share_not_found");
      return reply.send({ messages: snapshot.messages, session_id: snapshot.sessionId });
    });

    // Read-only HTML viewer.
    scope.get("/s/:token", async (request, reply) => {
      const { token } = request.params as { token: string };
      const snapshot = await publicSnapshot(deps, token);
      if (snapshot === null) {
        return reply.code(404).type("text/html; charset=utf-8").send(NOT_FOUND_PAGE);
      }
      const rows = snapshot.messages
        .map(
          (message) =>
            `<section><h2>${message.role === "user" ? "You" : "Assistant"}</h2>` +
            `<pre>${escapeHtml(message.content)}</pre></section>`,
        )
        .join("");
      const page = landingPage({
        title: "Shared conversation · Ovid",
        heading: "Shared conversation",
        lead: "A read-only Ovid chat shared by its owner.",
        body: rows,
        host: publicBase.host,
        path: `${publicBase.path}/s/${token}`,
        play: playStoreUrl(token),
      });
      return reply
        .code(200)
        .type("text/html; charset=utf-8")
        .header("Content-Security-Policy", page.csp)
        .send(page.html);
    });

    // Collab invite landing: NO lookup; joining (and the 10-member cap) is
    // enforced by the authenticated join call.
    scope.get("/s/:token/:invite", async (request, reply) => {
      const { token, invite } = request.params as { token: string; invite: string };
      if (!TOKEN_RE.test(token) || !TOKEN_RE.test(invite)) {
        return reply.code(404).type("text/html; charset=utf-8").send(INVITE_NOT_FOUND_PAGE);
      }
      const page = landingPage({
        title: "Live session invite · Ovid",
        heading: "Join a live Ovid session",
        lead:
          "You were invited to chat together in a live session. Each person " +
          "uses their own model and account. Open the link in the Ovid app.",
        body: "",
        host: publicBase.host,
        path: `${publicBase.path}/s/${token}/${invite}`,
        play: playStoreUrl(token, invite),
      });
      return reply
        .code(200)
        .type("text/html; charset=utf-8")
        .header("Content-Security-Policy", page.csp)
        .send(page.html);
    });

    // Android App Links. Comma-separated: the Play App Signing key AND the
    // upload key. Unconfigured/malformed → 503 (never a partial assetlinks).
    scope.get("/.well-known/assetlinks.json", async (request, reply) => {
      const raw = process.env.OVID_ANDROID_RELEASE_CERT_SHA256 ?? "";
      const fingerprints = raw
        .split(",")
        .map((value) => value.trim())
        .filter((value) => value !== "")
        .map((value) => value.toUpperCase());
      if (
        fingerprints.length === 0 ||
        !fingerprints.every((value) => FINGERPRINT_RE.test(value))
      ) {
        return sendDetail(reply, 503, "android_release_fingerprint_not_configured");
      }
      (reply as unknown as Record<symbol, boolean>)[PUBLIC_CACHE] = true;
      // packageName() may throw for an invalid configured app id → the scope
      // handler answers 503 shares_unavailable (Python parity).
      const pkg = packageName();
      return reply.send([
        {
          relation: ["delegate_permission/common.handle_all_urls"],
          target: {
            namespace: "android_app",
            package_name: pkg,
            sha256_cert_fingerprints: fingerprints,
          },
        },
      ]);
    });
  });
}
