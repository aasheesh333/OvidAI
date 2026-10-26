import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { Verifier } from "./auth.js";
import {
  DEFAULT_TRUSTED_PROXY_CIDRS,
  canonicalizeClientIp,
  compileTrustedProxies,
  resolveClientIp,
  type ClientNetwork,
} from "./clientIp.js";

export type RateLimitClass =
  | "send"
  | "ticket"
  | "devices"
  | "attachments"
  | "connections"
  | "plugin_source"
  | "preview"
  | "voice"
  | "collab_join"
  | "turn"
  | "poll"
  | "shares"
  | "admin"
  | "default"
  | "reports";

export type RateLimitScope = "uid" | "ip" | "unknown" | "uid+ip";

export interface RateLimitConsume {
  class: RateLimitClass;
  uid?: string;
  ip?: string;
  /** Signed edge/internal requests only: prevents edge + gateway double-count. */
  requestId?: string;
}

export interface RateLimitDecision {
  allowed: boolean;
  retryAfterSeconds: number;
  scope: RateLimitScope;
}

export interface RateLimiter {
  consume(input: RateLimitConsume): Promise<RateLimitDecision>;
}

interface RateLimitPolicy {
  uid: number;
  ip: number;
  windowMs: number;
}

const MINUTE = 60_000;
const DAY = 86_400_000;
export const RATE_LIMIT_POLICIES: Readonly<Record<RateLimitClass, RateLimitPolicy>> = {
  send: { uid: 20, ip: 120, windowMs: MINUTE },
  ticket: { uid: 30, ip: 180, windowMs: MINUTE },
  devices: { uid: 10, ip: 60, windowMs: MINUTE },
  attachments: { uid: 60, ip: 360, windowMs: MINUTE },
  connections: { uid: 20, ip: 120, windowMs: MINUTE },
  plugin_source: { uid: 5, ip: 30, windowMs: MINUTE },
  preview: { uid: 10, ip: 60, windowMs: MINUTE },
  voice: { uid: 20, ip: 120, windowMs: MINUTE },
  collab_join: { uid: 10, ip: 60, windowMs: MINUTE },
  turn: { uid: 20, ip: 120, windowMs: MINUTE },
  poll: { uid: 120, ip: 720, windowMs: MINUTE },
  shares: { uid: 60, ip: 360, windowMs: MINUTE },
  admin: { uid: 30, ip: 60, windowMs: MINUTE },
  default: { uid: 300, ip: 1800, windowMs: MINUTE },
  reports: { uid: 50, ip: 50, windowMs: DAY },
};

export function isRateLimitClass(value: unknown): value is RateLimitClass {
  return typeof value === "string" && Object.hasOwn(RATE_LIMIT_POLICIES, value);
}

/** One classifier at the gateway boundary; authorization stays in each route. */
export function rateLimitClassFor(method: string, rawPath: string): RateLimitClass {
  const path = rawPath.split("?", 1)[0]!.replace(/\/+$/, "") || "/";
  const verb = method.toUpperCase();
  if (path === "/v1/reports" || path === "/cloud/v1/reports") return "reports";
  if (path === "/cloud/v1/auth/ticket") return "ticket";
  if (path === "/cloud/v1/devices" && (verb === "POST" || verb === "DELETE")) return "devices";
  if (path.includes("/attachments")) return "attachments";
  if (path.includes("/mcp/connections") || path === "/cloud/ws") return "connections";
  if (path === "/cloud/v1/plugins/install") return "plugin_source";
  if (path.startsWith("/admin/") || path.startsWith("/cloud/v1/admin/")) return "admin";
  if (path === "/admin") return "admin";
  if (
    path === "/shares" ||
    path.startsWith("/shares/") ||
    path === "/s" ||
    path.startsWith("/s/") ||
    path.startsWith("/cloud/v1/shares")
  ) {
    return "shares";
  }
  if (/(?:^|\/)(?:preview|previews)(?:\/|$)/.test(path) && verb === "POST") {
    return "preview";
  }
  if (/(?:^|\/)(?:voice|speech|transcriptions?)(?:\/|$)/.test(path)) return "voice";
  if (path.includes("/collab/") || path.startsWith("/collab/") || path.includes("/chat/") || path.startsWith("/chat/")) {
    if (/(?:^|\/)(?:join|members)\/?$/.test(path)) return "collab_join";
    if (/(?:^|\/)turns?\/?$/.test(path)) return "turn";
    if (verb === "GET" || /(?:^|\/)poll\/?$/.test(path)) return "poll";
  }
  if (verb === "GET" && /^\/cloud\/v1\/runs\/[^/]+$/.test(path)) return "poll";
  if (verb === "GET" && /^\/cloud\/v1\/sessions\/[^/]+\/events$/.test(path)) return "poll";
  if (verb === "POST" && /^\/cloud\/v1\/sessions\/[^/]+\/messages$/.test(path)) {
    return "send";
  }
  return "default";
}

export interface RateLimitRedis {
  eval(script: string, numKeys: number, ...args: Array<string | number>): unknown;
}

export interface RateLimiterOptions {
  keyPrefix?: string;
  onDegraded?: (error: unknown) => void;
}

export class RateLimitStoreError extends Error {
  constructor(options?: { cause?: unknown }) {
    super("rate limit store unavailable", options);
    this.name = "RateLimitStoreError";
  }
}

function digest(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("base64url");
}

/**
 * Atomic fixed-window token buckets. Redis performs both capacity checks before
 * either INCR, so concurrent gateway instances cannot over-admit and a denied
 * UID does not spend the IP budget. An optional signed request id stores its
 * decision in the same script, making edge→gateway admission exactly-once.
 */
const CONSUME_LUA = `
local both = ARGV[4] == '1'
local hasReceipt = ARGV[5] == '1'
local windowMs = tonumber(ARGV[3])
local firstCap = tonumber(ARGV[1])
local secondCap = tonumber(ARGV[2])
local receiptKey = KEYS[#KEYS]
local function ttlFor(index)
  local ttl = redis.call('PTTL', KEYS[index])
  if ttl <= 0 then return windowMs end
  return ttl
end
local function denied(scope, index)
  local ttl = ttlFor(index)
  if hasReceipt then
    redis.call('SET', receiptKey, '0:' .. scope, 'PX', ttl)
  end
  return {0, ttl, scope}
end
if hasReceipt then
  local cached = redis.call('GET', receiptKey)
  if cached then
    local allowed, scope = string.match(cached, '^(%d):(%d)$')
    if allowed == '1' then return {1, 0, 0} end
    local index = 1
    if both and tonumber(scope) == 2 then index = 2 end
    local ttl = ttlFor(index)
    return {0, ttl, tonumber(scope)}
  end
end
local firstCount = tonumber(redis.call('GET', KEYS[1]) or '0')
if firstCount >= firstCap then return denied(1, 1) end
if both then
  local secondCount = tonumber(redis.call('GET', KEYS[2]) or '0')
  if secondCount >= secondCap then return denied(2, 2) end
end
local function increment(index)
  local n = redis.call('INCR', KEYS[index])
  local ttl = redis.call('PTTL', KEYS[index])
  if n == 1 or ttl < 0 then
    redis.call('PEXPIRE', KEYS[index], windowMs)
    return windowMs
  end
  return ttl
end
local firstTtl = increment(1)
local receiptTtl = firstTtl
if both then
  local secondTtl = increment(2)
  if secondTtl > receiptTtl then receiptTtl = secondTtl end
end
if hasReceipt then
  redis.call('SET', receiptKey, '1:0', 'PX', receiptTtl)
end
return {1, 0, 0}
`;

export function createRateLimiter(
  redis: RateLimitRedis,
  opts: RateLimiterOptions = {},
): RateLimiter {
  const keyPrefix = opts.keyPrefix ?? "ovid:ratelimit:v1:";
  return {
    async consume(input) {
      const policy = RATE_LIMIT_POLICIES[input.class];
      if (policy === undefined) throw new Error("unknown rate limit class");
      const uid = input.uid?.trim() || null;
      const ip = canonicalizeClientIp(input.ip);
      const both = uid !== null && ip !== null;
      const requestId = input.requestId?.trim() || null;
      if (requestId !== null && (requestId.length > 200 || /[\r\n]/.test(requestId))) {
        throw new Error("invalid rate limit request id");
      }
      const keys: string[] = [];
      let firstCap: number;
      let secondCap: number;
      if (both) {
        keys.push(
          `${keyPrefix}${input.class}:uid:${digest(uid)}`,
          `${keyPrefix}${input.class}:ip:${digest(ip)}`,
        );
        firstCap = policy.uid;
        secondCap = policy.ip;
      } else {
        // One shared conservative bucket when EITHER fact is unknown. Using the
        // known half alone would let missing IP/identity become a bypass.
        keys.push(`${keyPrefix}${input.class}:unknown`);
        firstCap = Math.min(policy.uid, policy.ip);
        secondCap = firstCap;
      }
      if (requestId !== null) {
        keys.push(
          `${keyPrefix}receipt:${digest(`${input.class}:${uid ?? ""}:${ip ?? ""}:${requestId}`)}`,
        );
      }
      try {
        const raw = await redis.eval(
          CONSUME_LUA,
          keys.length,
          ...keys,
          firstCap,
          secondCap,
          policy.windowMs,
          both ? 1 : 0,
          requestId !== null ? 1 : 0,
        );
        if (!Array.isArray(raw) || raw.length !== 3) throw new Error("malformed Redis decision");
        const allowed = Number(raw[0]) === 1;
        const retryMs = Number(raw[1]);
        const scopeCode = Number(raw[2]);
        if (!Number.isFinite(retryMs) || ![0, 1, 2, 3].includes(scopeCode)) {
          throw new Error("malformed Redis decision");
        }
        const scope: RateLimitScope = allowed
          ? both
            ? "uid+ip"
            : "unknown"
          : scopeCode === 1 && both
            ? "uid"
            : scopeCode === 2 && both
              ? "ip"
              : "unknown";
        return {
          allowed,
          retryAfterSeconds: allowed ? 0 : Math.max(1, Math.ceil(retryMs / 1000)),
          scope,
        };
      } catch (error) {
        opts.onDegraded?.(error);
        if (error instanceof RateLimitStoreError) throw error;
        throw new RateLimitStoreError({ cause: error });
      }
    },
  };
}

export const RATE_LIMIT_INTERNAL_PATH = "/internal/rate-limits/consume";
const EDGE_SIGNATURE_MAX_AGE_SECONDS = 300;

function singleHeader(value: string | string[] | undefined): string | null {
  return typeof value === "string" ? value : null;
}

function safeHexEqual(actual: string, expected: string): boolean {
  if (!/^[0-9a-f]{64}$/i.test(actual)) return false;
  const a = Buffer.from(actual, "hex");
  const b = Buffer.from(expected, "hex");
  return a.length === b.length && timingSafeEqual(a, b);
}

function internalSignature(secret: string, timestamp: string, body: string): string {
  return createHmacForRateLimit(
    secret,
    `POST\n${RATE_LIMIT_INTERNAL_PATH}\n${timestamp}\n${body}`,
  );
}

function createHmacForRateLimit(secret: string, value: string): string {
  return createHmac("sha256", secret).update(value).digest("hex");
}

function edgeSignature(
  secret: string,
  input: {
    timestamp: string;
    requestId: string;
    className: RateLimitClass;
    ip: string;
    asn: string;
    authorization: string;
    appCheck: string;
  },
): string {
  return createHmacForRateLimit(
    secret,
    `EDGE\n${input.timestamp}\n${input.requestId}\n${input.className}\n${input.ip}\n${input.asn}\n${input.authorization}\n${input.appCheck}`,
  );
}

export interface VerifiedEdgeRequest extends ClientNetwork {
  requestId: string;
}

const EDGE_REQUESTS = new WeakMap<FastifyRequest, VerifiedEdgeRequest>();

export function verifiedEdgeNetwork(request: FastifyRequest): ClientNetwork | undefined {
  const edge = EDGE_REQUESTS.get(request);
  return edge === undefined ? undefined : { ip: edge.ip, asn: edge.asn };
}

function freshTimestamp(raw: string | null, now: () => Date): string | null {
  if (raw === null || !/^\d{1,12}$/.test(raw)) return null;
  const timestamp = Number(raw);
  const nowSeconds = Math.floor(now().getTime() / 1000);
  return Math.abs(nowSeconds - timestamp) <= EDGE_SIGNATURE_MAX_AGE_SECONDS ? raw : null;
}

function verifyEdgeRequest(
  request: FastifyRequest,
  className: RateLimitClass,
  secret: string,
  now: () => Date,
): VerifiedEdgeRequest | null {
  const requestId = singleHeader(request.headers["x-ovid-edge-request-id"]);
  const timestamp = freshTimestamp(
    singleHeader(request.headers["x-ovid-edge-timestamp"]),
    now,
  );
  const signature = singleHeader(request.headers["x-ovid-edge-signature"]);
  if (requestId === null || timestamp === null || signature === null) return null;
  if (requestId.trim() === "" || requestId.length > 200) return null;
  const rawIp = singleHeader(request.headers["x-ovid-edge-ip"]) ?? "";
  const rawAsn = singleHeader(request.headers["x-ovid-edge-asn"]) ?? "";
  const ip = rawIp === "" ? null : canonicalizeClientIp(rawIp);
  if (rawIp !== "" && ip === null) return null;
  const asnMatch = /^(?:as)?(\d{1,10})$/i.exec(rawAsn);
  const asn = rawAsn === "" ? null : asnMatch === null ? null : `AS${Number(asnMatch[1])}`;
  if (rawAsn !== "" && asn === null) return null;
  const authorization = singleHeader(request.headers.authorization) ?? "";
  const appCheck = singleHeader(request.headers["x-firebase-appcheck"]) ?? "";
  const expected = edgeSignature(secret, {
    timestamp,
    requestId,
    className,
    ip: ip ?? "",
    asn: asn ?? "",
    authorization,
    appCheck,
  });
  if (!safeHexEqual(signature, expected)) return null;
  return { requestId, ip, asn };
}

export interface RateLimitHookOptions {
  rateLimiter: RateLimiter;
  verifier: Verifier;
  rateLimitInternalSecret?: string;
  trustedProxyCidrs?: readonly string[];
  clock?: () => Date;
  onDegraded?: (error: unknown) => void;
  /**
   * Requests for which a rate-limit STORE failure must degrade open instead of
   * returning 503. Used only for the public health probes: a limiter outage is
   * not a system outage, and rewriting health as `rate_limit_unavailable`
   * would tell an operator a lie. Every other route keeps fail-closed.
   */
  degradeOnStoreFailure?: (request: FastifyRequest) => boolean;
}

function usesSeparateAdminAuthorization(path: string): boolean {
  return path === "/admin" || path.startsWith("/admin/") || path.startsWith("/cloud/v1/admin/");
}

/** Gateway's independent pre-side-effect enforcement for direct and Web calls. */
export function createRateLimitPreHandler(opts: RateLimitHookOptions) {
  const trustedProxies = compileTrustedProxies(
    opts.trustedProxyCidrs ?? DEFAULT_TRUSTED_PROXY_CIDRS,
  );
  const now = opts.clock ?? (() => new Date());
  return async (request: FastifyRequest, reply: FastifyReply): Promise<FastifyReply | void> => {
    if (request.url.split("?", 1)[0] === RATE_LIMIT_INTERNAL_PATH) return;
    const className = rateLimitClassFor(request.method, request.url);
    let uid = typeof request.principal?.uid === "string" ? request.principal.uid : undefined;
    if (uid === undefined && !usesSeparateAdminAuthorization(request.url.split("?", 1)[0]!)) {
      const authorization = singleHeader(request.headers.authorization) ?? "";
      if (/^Bearer \S+/.test(authorization)) {
        try {
          const principal = await opts.verifier(
            authorization.slice("Bearer ".length),
            singleHeader(request.headers["x-firebase-appcheck"]),
          );
          uid = principal.uid;
        } catch {
          // The legacy route returns its own contracted 401. This request uses
          // the conservative unknown bucket rather than bypassing enforcement.
        }
      }
    }

    let requestId: string | undefined;
    let ip: string | null;
    const secret = opts.rateLimitInternalSecret?.trim() ?? "";
    const edge = secret === "" ? null : verifyEdgeRequest(request, className, secret, now);
    if (edge !== null) {
      EDGE_REQUESTS.set(request, edge);
      requestId = edge.requestId;
      ip = edge.ip;
    } else {
      ip = resolveClientIp({
        peerAddress: request.socket.remoteAddress,
        forwardedFor: request.headers["x-forwarded-for"],
        trustedProxies,
      });
    }

    let decision: RateLimitDecision;
    try {
      decision = await opts.rateLimiter.consume({
        class: className,
        ...(uid !== undefined ? { uid } : {}),
        ...(ip !== null ? { ip } : {}),
        ...(requestId !== undefined ? { requestId } : {}),
      });
    } catch (error) {
      opts.onDegraded?.(error);
      request.log.warn({ feature: "rate_limits", status: "degraded" }, "rate limit store degraded");
      // A health probe answers truthfully even when the limiter store is down;
      // every other route stays fail-closed with the typed 503 below.
      if (opts.degradeOnStoreFailure?.(request) === true) return;
      return reply.code(503).send({
        error: {
          code: "rate_limit_unavailable",
          message: "Request limiting is temporarily unavailable. Try again shortly.",
        },
      });
    }
    if (!decision.allowed) {
      return reply
        .code(429)
        .header("retry-after", String(decision.retryAfterSeconds))
        .send({
          error: { code: "rate_limited", message: "Too many requests. Try again shortly." },
        });
    }
  };
}

export interface RateLimitInternalRouteOptions extends RateLimitHookOptions {
  rateLimitInternalSecret: string;
}

/** Signed Web→gateway consume endpoint. Bearer identity is verified, never trusted from JSON. */
export function registerRateLimitInternalRoute(
  app: FastifyInstance,
  opts: RateLimitInternalRouteOptions,
): void {
  const now = opts.clock ?? (() => new Date());
  app.post(RATE_LIMIT_INTERNAL_PATH, async (request, reply) => {
    const timestamp = freshTimestamp(singleHeader(request.headers["x-ovid-timestamp"]), now);
    const signature = singleHeader(request.headers["x-ovid-signature"]);
    const bodyText = JSON.stringify(request.body ?? {});
    if (
      timestamp === null ||
      signature === null ||
      !safeHexEqual(signature, internalSignature(opts.rateLimitInternalSecret, timestamp, bodyText))
    ) {
      return reply.code(401).send({
        error: { code: "unauthorized", message: "Internal request signature is invalid." },
      });
    }
    const body = request.body;
    if (typeof body !== "object" || body === null || Array.isArray(body)) {
      return reply.code(400).send({ error: { code: "bad_request", message: "Invalid consume body." } });
    }
    const value = body as Record<string, unknown>;
    const allowedFields = new Set(["class", "ip", "asn", "requestId", "authorization", "appCheck"]);
    if (Object.keys(value).some((key) => !allowedFields.has(key)) || !isRateLimitClass(value.class)) {
      return reply.code(400).send({ error: { code: "bad_request", message: "Invalid consume body." } });
    }
    const requestId = value.requestId;
    if (requestId !== undefined && (typeof requestId !== "string" || requestId.trim() === "" || requestId.length > 200)) {
      return reply.code(400).send({ error: { code: "bad_request", message: "Invalid consume body." } });
    }
    let uid: string | undefined;
    if (typeof value.authorization === "string" && /^Bearer \S+/.test(value.authorization)) {
      try {
        const principal = await opts.verifier(
          value.authorization.slice("Bearer ".length),
          typeof value.appCheck === "string" ? value.appCheck : null,
        );
        uid = principal.uid;
      } catch {
        // Unknown identity enters the conservative bucket; the proxied route
        // will return its own authentication verdict without provider details.
      }
    }
    const ip = typeof value.ip === "string" ? canonicalizeClientIp(value.ip) : null;
    try {
      const decision = await opts.rateLimiter.consume({
        class: value.class,
        ...(uid !== undefined ? { uid } : {}),
        ...(ip !== null ? { ip } : {}),
        ...(typeof requestId === "string" ? { requestId } : {}),
      });
      return reply.send({
        allowed: decision.allowed,
        retryAfterSeconds: decision.retryAfterSeconds,
        scope: decision.scope,
      });
    } catch (error) {
      opts.onDegraded?.(error);
      return reply.code(503).send({
        error: {
          code: "rate_limit_unavailable",
          message: "Request limiting is temporarily unavailable. Try again shortly.",
        },
      });
    }
  });
}
