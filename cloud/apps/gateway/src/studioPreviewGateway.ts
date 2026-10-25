import type { FastifyError, FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";

import {
  PreviewProxyError,
  createPreviewCsp,
  createPreviewResponseHeaders,
  normalizePreviewPath,
  proxyPreviewHttpRequest,
  type LivePreviewRegistration,
  type PreviewHttpProxyResult,
} from "./previewOrigin.js";
import {
  createPreviewExchange,
  parsePreviewCookie,
  type PreviewBinding,
  type PreviewCookieGrant,
  type PreviewTicketRedis,
  type PreviewTicketStore,
} from "./studioPreviewTickets.js";
import {
  StudioPreviewWorkerHttpError,
  StudioPreviewWorkerUnavailableError,
  type BoundStudioPreviewWorkerClient,
  type StudioPreviewRegistration,
  type StudioPreviewWorkerClient,
} from "./studioPreviewWorkerClient.js";
import { parseStudioPreviewOrigin, parseStudioPreviewWorkerHost } from "./env.js";
import { isUuid, sendError } from "./routes/http.js";

const PREVIEW_ID = /^[A-Za-z0-9_-]{1,128}$/;
const TICKET = /^[A-Za-z0-9_-]{43}$/;
const DEFAULT_REDIS_PREFIX = "ovid:studio:preview:";
const CREATE_BODY_LIMIT = 16 * 1024;
const EMPTY_BODY_LIMIT = 128;

const createBody = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("static"),
    workspacePath: z.string().min(1).max(4_096),
  }).strict(),
  z.object({
    kind: z.literal("dev_server"),
    projectDir: z.string().min(1).max(4_096),
    script: z.enum(["dev", "start", "preview"]),
  }).strict(),
]);
const exchangeQuery = z.object({ ticket: z.string().regex(TICKET) }).strict();
const grantIdentity = z.string().min(1).max(512).refine(
  (value) => !/[\u0000-\u001f\u007f]/.test(value),
);
const cookieGrantSchema = z.object({
  userId: grantIdentity,
  sessionId: grantIdentity,
  previewId: z.string().regex(PREVIEW_ID),
  generation: z.number().int().positive(),
  cookieToken: z.string().regex(TICKET),
  cookieExpiresAt: z.string().max(64).refine((value) => Number.isFinite(Date.parse(value))),
}).strict();

export interface StudioPreviewGatewayConfig {
  /** Exact configured origins; never derived from a request Host header. */
  previewOrigin: string;
  webOrigin: string;
  /** Trusted private hostname/IP used only for registered dev upstream reconstruction. */
  workerHost: string;
  worker: StudioPreviewWorkerClient;
  tickets: Pick<PreviewTicketStore, "mint" | "consume" | "verifyCookie">;
  /** Same Redis boundary as the ticket store; cookie grants are read with GET only. */
  redis: PreviewTicketRedis;
  redisKeyPrefix?: string;
  isSessionOwner(userId: string, sessionId: string): Promise<boolean>;
  now?: () => Date;
  /** Test seams only; production composition leaves these unset. */
  devFetch?: typeof fetch;
  devIdleTimeoutMs?: number;
  devMaxBytes?: number;
}

interface ResolvedOrigins {
  previewOrigin: string;
  webOrigin: string;
  workerHost: string;
}

function resolvedOrigins(config: StudioPreviewGatewayConfig): ResolvedOrigins {
  const previewOrigin = parseStudioPreviewOrigin(config.previewOrigin, "OVID_PREVIEW_ORIGIN");
  const webOrigin = parseStudioPreviewOrigin(config.webOrigin, "OVID_WEB_ORIGIN");
  if (previewOrigin === webOrigin) {
    throw new Error("OVID_PREVIEW_ORIGIN and OVID_WEB_ORIGIN must be different origins.");
  }
  return {
    previewOrigin,
    webOrigin,
    workerHost: parseStudioPreviewWorkerHost(config.workerHost),
  };
}

/** Used only to keep the ordinary Firebase-aware rate-limit hook off origin routes. */
export function isStudioPreviewOriginPath(rawUrl: string): boolean {
  const path = rawUrl.split("?", 1)[0]!;
  return path === "/preview/exchange" || path.startsWith("/preview/");
}

function privateHeaders(reply: FastifyReply): void {
  reply
    .header("cache-control", "private, no-store")
    .header("pragma", "no-cache")
    .header("referrer-policy", "no-referrer");
}

function safeRouteError(reply: FastifyReply, error: FastifyError): FastifyReply {
  privateHeaders(reply);
  const status = typeof error.statusCode === "number" ? error.statusCode : 500;
  if (status === 404) return originNotFound(reply);
  if (status === 413) {
    return sendError(reply, 413, "payload_too_large", "Preview request is too large.");
  }
  if (status >= 400 && status < 500) {
    return sendError(reply, 400, "bad_request", "Invalid Studio preview request.");
  }
  return previewUnavailable(reply);
}

function configuredHost(request: FastifyRequest, previewOrigin: string): boolean {
  const host = request.headers.host;
  return typeof host === "string" && host.toLowerCase() === new URL(previewOrigin).host.toLowerCase();
}

function originNotFound(reply: FastifyReply): FastifyReply {
  return sendError(reply, 404, "not_found", "Preview not found.");
}

function hmrUnavailable(reply: FastifyReply): FastifyReply {
  return sendError(
    reply,
    501,
    "preview_hmr_unavailable",
    "Preview WebSocket and HMR access are not available.",
  );
}

function previewUnavailable(reply: FastifyReply): FastifyReply {
  return sendError(
    reply,
    503,
    "preview_unavailable",
    "Studio previews are temporarily unavailable.",
  );
}

function gatewayNow(config: StudioPreviewGatewayConfig): Date {
  const value = config.now?.() ?? new Date();
  if (!Number.isFinite(value.getTime())) throw new StudioPreviewWorkerUnavailableError();
  return value;
}

function emptyQuery(request: FastifyRequest): boolean {
  const query = request.query as Record<string, unknown>;
  return typeof query === "object" && query !== null && Object.keys(query).length === 0;
}

function emptyBody(body: unknown): boolean {
  return body === undefined || (
    typeof body === "object" && body !== null && !Array.isArray(body) && Object.keys(body).length === 0
  );
}

function managementError(reply: FastifyReply, error: unknown): FastifyReply {
  if (error instanceof StudioPreviewWorkerHttpError) {
    if (error.status === 404) return originNotFound(reply);
    if (error.status === 400) {
      return sendError(reply, 400, "bad_request", "Invalid Studio preview definition.");
    }
    if (error.status === 429 && error.code === "per_user_capacity") {
      return sendError(reply, 429, error.code, "This account has reached its preview process limit.");
    }
    if (error.status === 429 && error.code === "global_capacity") {
      return sendError(reply, 429, error.code, "Preview capacity is full. Retry shortly.");
    }
    if (error.status === 409 && error.code === "no_repo") {
      return sendError(reply, 409, "no_repo", "No repository is bound to this session.");
    }
    if (error.status === 409 && error.code === "not_running") {
      return sendError(reply, 409, "not_running", "Preview is not running.");
    }
    if (error.status === 409 && error.code === "lifecycle_conflict") {
      return sendError(reply, 409, "lifecycle_conflict", "Preview lifecycle is still changing. Retry the operation.");
    }
  }
  return previewUnavailable(reply);
}

function originError(reply: FastifyReply, error: unknown): FastifyReply {
  if (error instanceof PreviewProxyError) {
    switch (error.code) {
      case "bad_headers":
        return sendError(reply, 400, error.code, "Preview request headers are invalid.");
      case "bad_path":
        return sendError(reply, 400, error.code, "Preview path is invalid.");
      case "method_not_allowed":
        return sendError(reply, 405, error.code, "Only GET and HEAD are allowed for preview content.");
      case "not_found":
        return originNotFound(reply);
      case "hmr_denied":
        return sendError(reply, 403, error.code, "Preview HMR access is not allowed.");
      case "redirect_denied":
        return sendError(reply, 502, error.code, "Preview upstream redirects are not allowed.");
      case "response_too_large":
        return sendError(reply, 413, error.code, "Preview response is too large.");
      case "upstream_timeout":
        return sendError(reply, 504, error.code, "Preview upstream timed out.");
      case "upstream_unavailable":
        return sendError(reply, 502, error.code, "Preview upstream is unavailable.");
      case "registration_unavailable":
        return previewUnavailable(reply);
    }
  }
  if (error instanceof StudioPreviewWorkerHttpError) {
    if (error.status === 404) return originNotFound(reply);
    if (error.status === 400 || error.code === "bad_path" || error.code === "bad_headers") {
      return sendError(reply, 400, "bad_request", "Preview request is invalid.");
    }
    if (error.status === 405) {
      return sendError(reply, 405, "method_not_allowed", "Only GET and HEAD are allowed for preview content.");
    }
    if (error.status === 413 || error.code === "response_too_large") {
      return sendError(reply, 413, "response_too_large", "Preview response is too large.");
    }
    if (error.code === "redirect_denied") {
      return sendError(reply, 502, error.code, "Preview upstream redirects are not allowed.");
    }
    if (error.code === "upstream_timeout") {
      return sendError(reply, 504, error.code, "Preview upstream timed out.");
    }
  }
  return previewUnavailable(reply);
}

async function ownedWorker(
  request: FastifyRequest,
  reply: FastifyReply,
  config: StudioPreviewGatewayConfig,
): Promise<BoundStudioPreviewWorkerClient | null> {
  const sessionId = (request.params as { id: string }).id;
  const uid = request.principal.uid;
  if (!isUuid(sessionId)) {
    originNotFound(reply);
    return null;
  }
  let owned: boolean;
  try {
    owned = await config.isSessionOwner(uid, sessionId);
  } catch {
    previewUnavailable(reply);
    return null;
  }
  if (!owned) {
    originNotFound(reply);
    return null;
  }
  try {
    return config.worker.forUser(uid);
  } catch {
    previewUnavailable(reply);
    return null;
  }
}

function validPreviewId(reply: FastifyReply, previewId: string): boolean {
  if (PREVIEW_ID.test(previewId)) return true;
  originNotFound(reply);
  return false;
}

function liveBinding(
  registration: StudioPreviewRegistration | null,
  expected: Omit<PreviewBinding, "generation"> & { generation?: number },
  now: Date,
): PreviewBinding | null {
  if (
    registration === null ||
    registration.id !== expected.previewId ||
    registration.userId !== expected.userId ||
    registration.sessionId !== expected.sessionId ||
    (expected.generation !== undefined && registration.generation !== expected.generation) ||
    !Number.isSafeInteger(registration.generation) ||
    registration.generation <= 0 ||
    registration.status !== "running" ||
    Date.parse(registration.expiresAt) <= now.getTime()
  ) {
    return null;
  }
  return {
    userId: registration.userId,
    sessionId: registration.sessionId,
    previewId: registration.id,
    generation: registration.generation,
  };
}

/** Authenticated /cloud/v1 composition. The parent scope owns authHook. */
export function registerStudioPreviewApiRoutes(
  app: FastifyInstance,
  config: StudioPreviewGatewayConfig,
): void {
  const origins = resolvedOrigins(config);
  app.register(async (scoped) => {
    scoped.addHook("onSend", async (_request, reply) => {
      privateHeaders(reply);
    });
    scoped.setErrorHandler((error, _request, reply) => safeRouteError(reply, error));

    scoped.post("/sessions/:id/previews", { bodyLimit: CREATE_BODY_LIMIT }, async (request, reply) => {
      if (!emptyQuery(request) || !createBody.safeParse(request.body).success) {
        return sendError(reply, 400, "bad_request", "Invalid Studio preview definition.");
      }
      const worker = await ownedWorker(request, reply, config);
      if (worker === null) return reply;
      const sessionId = (request.params as { id: string }).id;
      try {
        const created = await worker.start(sessionId, request.body as z.infer<typeof createBody>);
        return reply.code(201).send(created);
      } catch (error) {
        return managementError(reply, error);
      }
    });

    scoped.get("/sessions/:id/previews", async (request, reply) => {
      if (!emptyQuery(request)) {
        return sendError(reply, 400, "bad_request", "Preview query parameters are not supported.");
      }
      const worker = await ownedWorker(request, reply, config);
      if (worker === null) return reply;
      try {
        const items = await worker.list((request.params as { id: string }).id);
        return { items };
      } catch (error) {
        return managementError(reply, error);
      }
    });

    scoped.get("/sessions/:id/previews/:pid", async (request, reply) => {
      const previewId = (request.params as { pid: string }).pid;
      if (!emptyQuery(request)) {
        return sendError(reply, 400, "bad_request", "Preview query parameters are not supported.");
      }
      if (!validPreviewId(reply, previewId)) return reply;
      const worker = await ownedWorker(request, reply, config);
      if (worker === null) return reply;
      try {
        const preview = await worker.get((request.params as { id: string }).id, previewId);
        return preview === null ? originNotFound(reply) : preview;
      } catch (error) {
        return managementError(reply, error);
      }
    });

    scoped.get("/sessions/:id/previews/:pid/logs", async (request, reply) => {
      const previewId = (request.params as { pid: string }).pid;
      if (!emptyQuery(request)) {
        return sendError(reply, 400, "bad_request", "Preview query parameters are not supported.");
      }
      if (!validPreviewId(reply, previewId)) return reply;
      const worker = await ownedWorker(request, reply, config);
      if (worker === null) return reply;
      try {
        return await worker.logs((request.params as { id: string }).id, previewId);
      } catch (error) {
        return managementError(reply, error);
      }
    });

    scoped.post("/sessions/:id/previews/:pid/stop", { bodyLimit: EMPTY_BODY_LIMIT }, async (request, reply) => {
      const previewId = (request.params as { pid: string }).pid;
      if (!emptyQuery(request) || !emptyBody(request.body)) {
        return sendError(reply, 400, "bad_request", "Preview stop accepts no fields.");
      }
      if (!validPreviewId(reply, previewId)) return reply;
      const worker = await ownedWorker(request, reply, config);
      if (worker === null) return reply;
      try {
        return await worker.stop((request.params as { id: string }).id, previewId);
      } catch (error) {
        return managementError(reply, error);
      }
    });

    scoped.post("/sessions/:id/previews/:pid/ticket", { bodyLimit: EMPTY_BODY_LIMIT }, async (request, reply) => {
      const previewId = (request.params as { pid: string }).pid;
      if (!emptyQuery(request) || !emptyBody(request.body)) {
        return sendError(reply, 400, "bad_request", "Preview ticket accepts no fields.");
      }
      if (!validPreviewId(reply, previewId)) return reply;
      const worker = await ownedWorker(request, reply, config);
      if (worker === null) return reply;
      const sessionId = (request.params as { id: string }).id;
      const uid = request.principal.uid;
      try {
        const now = gatewayNow(config);
        const registration = await worker.getLiveRegistration(sessionId, previewId);
        const binding = liveBinding(registration, {
          userId: uid,
          sessionId,
          previewId,
        }, now);
        if (binding === null) return originNotFound(reply);
        const minted = await config.tickets.mint(binding);
        return {
          launchUrl: `${origins.previewOrigin}/preview/exchange?ticket=${encodeURIComponent(minted.ticket)}`,
          ticketExpiresAt: minted.ticketExpiresAt,
          cookieExpiresAt: minted.cookieExpiresAt,
        };
      } catch (error) {
        return managementError(reply, error);
      }
    });
  }, { prefix: "/studio" });
}

async function readCookieGrant(
  config: StudioPreviewGatewayConfig,
  cookieToken: string,
  previewId: string,
): Promise<PreviewCookieGrant | null> {
  const prefix = config.redisKeyPrefix ?? DEFAULT_REDIS_PREFIX;
  const raw = await config.redis.get(`${prefix}cookie:${cookieToken}`);
  if (raw === null) return null;
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return null;
  }
  const parsed = cookieGrantSchema.safeParse(json);
  if (!parsed.success || parsed.data.cookieToken !== cookieToken || parsed.data.previewId !== previewId) {
    return null;
  }
  return parsed.data;
}

function rawContentPath(request: FastifyRequest, previewId: string): string | null {
  const rawUrl = request.raw.url;
  if (!rawUrl.startsWith("/preview/")) return null;
  const idEnd = rawUrl.indexOf("/", "/preview/".length);
  if (idEnd < 0) return null;
  const rawId = rawUrl.slice("/preview/".length, idEnd);
  if (rawId !== previewId || !PREVIEW_ID.test(rawId)) return null;
  const suffix = rawUrl.slice(idEnd);
  return suffix.startsWith("/") ? suffix : null;
}

function isHmrRequest(request: FastifyRequest, normalizedPath: string): boolean {
  const connection = request.headers.connection?.toLowerCase() ?? "";
  return request.headers.upgrade !== undefined ||
    request.headers["sec-websocket-protocol"] !== undefined ||
    connection.split(",").some((token) => token.trim() === "upgrade") ||
    normalizedPath.split("?", 1)[0] === "/__vite_hmr";
}

function contentLength(raw: string | null): number | null {
  if (raw === null || !/^\d+$/.test(raw)) return null;
  const value = Number(raw);
  return Number.isSafeInteger(value) ? value : null;
}

function sendProxyResult(
  request: FastifyRequest,
  reply: FastifyReply,
  result: PreviewHttpProxyResult,
): FastifyReply {
  return reply
    .code(result.status)
    .headers(result.headers)
    .send(request.method === "HEAD" || result.status === 204 || result.status === 304
      ? undefined
      : result.body);
}

async function proxyStatic(
  request: FastifyRequest,
  reply: FastifyReply,
  origins: ResolvedOrigins,
  worker: BoundStudioPreviewWorkerClient,
  binding: PreviewBinding,
  now: Date,
  path: string,
): Promise<FastifyReply> {
  const touched = await worker.touch({
    sessionId: binding.sessionId,
    previewId: binding.previewId,
    generation: binding.generation,
    now,
  });
  if (typeof touched !== "boolean") throw new StudioPreviewWorkerUnavailableError();

  // A throttled false verdict never skips this authoritative second read.
  const current = await worker.getLiveRegistration(binding.sessionId, binding.previewId);
  if (current?.kind !== "static" || liveBinding(current, binding, now) === null) {
    return originNotFound(reply);
  }
  const result = await worker.readStatic({
    sessionId: binding.sessionId,
    previewId: binding.previewId,
    method: request.method as "GET" | "HEAD",
    path,
    headers: request.headers,
  });
  const headers = createPreviewResponseHeaders(
    result.headers,
    createPreviewCsp({
      kind: "static",
      webOrigin: origins.webOrigin,
      previewOrigin: origins.previewOrigin,
    }),
  );
  const declared = contentLength(result.headers.get("content-length"));
  if (request.method === "HEAD" && declared !== null) {
    headers["content-length"] = String(declared);
  } else if (result.status !== 204 && result.status !== 304) {
    headers["content-length"] = String(result.body.length);
  }
  return sendProxyResult(request, reply, { status: result.status, headers, body: result.body });
}

async function proxyDev(
  request: FastifyRequest,
  reply: FastifyReply,
  config: StudioPreviewGatewayConfig,
  origins: ResolvedOrigins,
  worker: BoundStudioPreviewWorkerClient,
  binding: PreviewBinding,
  path: string,
): Promise<FastifyReply> {
  const result = await proxyPreviewHttpRequest({
    configuredWorkerHost: origins.workerHost,
    webOrigin: origins.webOrigin,
    previewOrigin: origins.previewOrigin,
    now: config.now,
    fetch: config.devFetch,
    idleTimeoutMs: config.devIdleTimeoutMs,
    maxBytes: config.devMaxBytes,
    getLiveRegistration: async (previewId, generation): Promise<LivePreviewRegistration | null> => {
      if (previewId !== binding.previewId || generation !== binding.generation) return null;
      const registration = await worker.getLiveRegistration(binding.sessionId, previewId);
      return registration?.kind === "dev_server" ? registration : null;
    },
    touch: async ({ id, generation, now }) => {
      if (id !== binding.previewId || generation !== binding.generation) return false;
      return worker.touch({ sessionId: binding.sessionId, previewId: id, generation, now });
    },
  }, {
    binding,
    method: request.method,
    path,
    headers: request.headers,
  });
  return sendProxyResult(request, reply, result);
}

/**
 * Dedicated ROOT registration only. No authHook is installed in this scope;
 * incoming Ovid cookies/auth headers are never forwarded to preview content.
 */
export function registerStudioPreviewOriginRoot(
  app: FastifyInstance,
  config: StudioPreviewGatewayConfig,
): void {
  const origins = resolvedOrigins(config);
  app.register(async (scoped) => {
    scoped.addHook("onSend", async (_request, reply) => {
      privateHeaders(reply);
    });
    scoped.setErrorHandler((error, _request, reply) => safeRouteError(reply, error));

    scoped.all("/preview/exchange", { bodyLimit: EMPTY_BODY_LIMIT }, async (request, reply) => {
      if (!configuredHost(request, origins.previewOrigin)) return originNotFound(reply);
      if (request.method !== "GET") {
        reply.header("allow", "GET");
        return sendError(reply, 405, "method_not_allowed", "Only GET is allowed for preview exchange.");
      }
      const connection = request.headers.connection?.toLowerCase() ?? "";
      if (request.headers.upgrade !== undefined ||
          request.headers["sec-websocket-protocol"] !== undefined ||
          connection.split(",").some((token) => token.trim() === "upgrade")) {
        return hmrUnavailable(reply);
      }
      const parsed = exchangeQuery.safeParse(request.query);
      if (!parsed.success || !emptyBody(request.body)) {
        return sendError(reply, 400, "bad_request", "Preview exchange requires exactly one ticket.");
      }
      let grant: PreviewCookieGrant | null;
      try {
        // GETDEL is atomic. No expected client binding is accepted or needed:
        // the stored grant came from the authoritative worker registration.
        grant = await config.tickets.consume(parsed.data.ticket);
        if (grant !== null && !(await config.isSessionOwner(grant.userId, grant.sessionId))) {
          return originNotFound(reply);
        }
      } catch {
        return previewUnavailable(reply);
      }
      if (grant === null) return originNotFound(reply);
      let exchange: ReturnType<typeof createPreviewExchange>;
      try {
        exchange = createPreviewExchange(grant);
      } catch {
        return previewUnavailable(reply);
      }
      // A 303 navigation replaces the exchange entry rather than creating a
      // ticket-bearing content history entry. Real Back-button acceptance is
      // still a deployment/browser gate, not something this source claims.
      return reply
        .code(exchange.status)
        .header("location", exchange.location)
        .header("cache-control", exchange.cacheControl)
        .header("referrer-policy", exchange.referrerPolicy)
        .header("set-cookie", exchange.setCookie)
        .send();
    });

    const content = async (request: FastifyRequest, reply: FastifyReply): Promise<FastifyReply> => {
      if (!configuredHost(request, origins.previewOrigin)) return originNotFound(reply);
      if (request.method !== "GET" && request.method !== "HEAD") {
        reply.header("allow", "GET, HEAD");
        return sendError(reply, 405, "method_not_allowed", "Only GET and HEAD are allowed for preview content.");
      }
      const previewId = (request.params as { pid: string }).pid;
      const rawPath = rawContentPath(request, previewId);
      if (rawPath === null) return originNotFound(reply);
      const path = normalizePreviewPath(rawPath);
      if (path === null) {
        return sendError(reply, 400, "bad_path", "Preview path is invalid.");
      }
      if (isHmrRequest(request, path)) return hmrUnavailable(reply);

      const cookieHeader = request.headers.cookie;
      const cookieToken = parsePreviewCookie(typeof cookieHeader === "string" ? cookieHeader : undefined);
      if (cookieToken === null) return originNotFound(reply);
      try {
        const grant = await readCookieGrant(config, cookieToken, previewId);
        const now = gatewayNow(config);
        if (grant === null || Date.parse(grant.cookieExpiresAt) <= now.getTime()) {
          return originNotFound(reply);
        }
        const binding: PreviewBinding = {
          userId: grant.userId,
          sessionId: grant.sessionId,
          previewId: grant.previewId,
          generation: grant.generation,
        };
        // Discovery needs the stored binding because the URL names only the
        // preview id. The reviewed primitive then performs the authoritative
        // GET-only cookie+full-binding verification; it never slides the TTL.
        const verified = await config.tickets.verifyCookie(cookieToken, binding);
        if (verified === null || !(await config.isSessionOwner(verified.userId, verified.sessionId))) {
          return originNotFound(reply);
        }
        const worker = config.worker.forUser(verified.userId);
        const initial = await worker.getLiveRegistration(binding.sessionId, binding.previewId);
        if (liveBinding(initial, binding, now) === null || initial === null) {
          return originNotFound(reply);
        }
        if (initial.kind === "static") {
          return await proxyStatic(request, reply, origins, worker, binding, now, path);
        }
        return await proxyDev(request, reply, config, origins, worker, binding, path);
      } catch (error) {
        return originError(reply, error);
      }
    };

    scoped.all("/preview/:pid/", { bodyLimit: EMPTY_BODY_LIMIT }, content);
    scoped.all("/preview/:pid/*", { bodyLimit: EMPTY_BODY_LIMIT }, content);
  });
}
