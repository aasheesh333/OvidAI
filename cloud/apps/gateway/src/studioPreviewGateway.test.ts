// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
// Regression-first composition tests; no test runner, Redis, Postgres, or network was used.
import Fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import { afterEach, describe, expect, it } from "vitest";

import { buildGateway, type BuildGatewayOptions } from "./app.js";
import { loadGatewayEnv } from "./env.js";
import { createPreviewCsp, PREVIEW_HTTP_MAX_BYTES } from "./previewOrigin.js";
import {
  PREVIEW_COOKIE_NAME,
  PREVIEW_TICKET_TTL_SECONDS,
  createPreviewTicketStore,
  parsePreviewCookie,
  type PreviewTicketRedis,
} from "./studioPreviewTickets.js";
import {
  createStudioPreviewWorkerClient,
  type StudioPreviewRegistration,
} from "./studioPreviewWorkerClient.js";
import type { StudioPreviewGatewayConfig } from "./studioPreviewGateway.js";
import {
  authHeaders,
  noopDb,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubVerifier,
} from "./test/stubs.js";

const UID = "preview-owner";
const OTHER_UID = "preview-stranger";
const SID = "00000000-0000-4000-8000-000000000092";
const OTHER_SID = "00000000-0000-4000-8000-000000000093";
const PID = "0199aaaa-0000-7000-8000-000000000092";
const OTHER_PID = "0199aaaa-0000-7000-8000-000000000093";
const INTERNAL_TOKEN = "studio-preview-internal-token-never-public";
const PREVIEW_ORIGIN = "https://preview.example.test";
const WEB_ORIGIN = "https://web.example.test";
const NOW = new Date("2026-10-25T12:00:00.000Z");
const API_BASE = `/cloud/v1/studio/sessions/${SID}/previews`;
const cleanups: Array<() => Promise<void> | void> = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

class MemoryPreviewRedis implements PreviewTicketRedis {
  readonly values = new Map<string, string>();
  readonly expiries = new Map<string, number>();
  readonly calls: Array<{ command: string; key: string; seconds?: number }> = [];

  async set(key: string, value: string, expiryMode: "EX", seconds: number): Promise<string> {
    expect(expiryMode).toBe("EX");
    this.values.set(key, value);
    this.expiries.set(key, seconds);
    this.calls.push({ command: "SET", key, seconds });
    return "OK";
  }

  async get(key: string): Promise<string | null> {
    this.calls.push({ command: "GET", key });
    return this.values.get(key) ?? null;
  }

  async call(command: "GETDEL", key: string): Promise<string | null> {
    this.calls.push({ command, key });
    const value = this.values.get(key) ?? null;
    this.values.delete(key);
    return value;
  }
}

function staticRegistration(overrides: Record<string, unknown> = {}): StudioPreviewRegistration {
  return {
    id: PID,
    userId: UID,
    sessionId: SID,
    generation: 7,
    kind: "static",
    status: "running",
    bindHost: null,
    port: null,
    expiresAt: "2026-10-25T12:15:00.000Z",
    lastAccessAt: null,
    ...overrides,
  } as StudioPreviewRegistration;
}

function devRegistration(overrides: Record<string, unknown> = {}): StudioPreviewRegistration {
  return staticRegistration({
    kind: "dev_server",
    bindHost: "127.0.0.1",
    port: 23_456,
    ...overrides,
  });
}

function publicDto(record: StudioPreviewRegistration, status = record.status) {
  return {
    id: record.id,
    kind: record.kind,
    status,
    generation: record.generation,
    expiresAt: record.expiresAt,
    lastAccessAt: record.lastAccessAt,
    logAvailable: record.kind === "dev_server",
  };
}

interface StaticAnswer {
  status: number;
  headers?: Record<string, string>;
  body?: Buffer | string;
}

async function fakeWorker(
  initial: StudioPreviewRegistration,
  options: { idleTimeoutMs?: number } = {},
) {
  const app = Fastify({ logger: false });
  cleanups.push(() => app.close());
  let current = initial;
  let touchResult = true;
  let afterTouch: (() => void) | null = null;
  let staticResponse: Response | null = null;
  const staticSignals: Array<AbortSignal | null | undefined> = [];
  let staticAnswer: StaticAnswer = {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8" },
    body: "<h1>static preview</h1>",
  };
  const calls: Array<{
    method: string;
    url: string;
    headers: Record<string, unknown>;
    body: unknown;
  }> = [];
  const touchResults: boolean[] = [];

  app.addHook("preHandler", async (request, reply) => {
    if (
      request.headers["x-ovid-internal-token"] !== INTERNAL_TOKEN ||
      typeof request.headers["x-ovid-user-id"] !== "string"
    ) {
      return reply.code(401).send({
        error: { code: "unauthenticated", message: "Internal credentials required." },
      });
    }
  });
  const capture = (request: FastifyRequest): void => {
    calls.push({
      method: request.method,
      url: request.url,
      headers: { ...request.headers },
      body: request.body,
    });
  };
  const owned = (request: FastifyRequest): boolean =>
    request.headers["x-ovid-user-id"] === current.userId &&
    (request.params as { sid: string }).sid === current.sessionId;
  const missing = (reply: FastifyReply): FastifyReply => reply.code(404).send({
    error: { code: "not_found", message: "private worker detail" },
  });

  app.post("/internal/sessions/:sid/previews", async (request, reply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    return reply.code(201).send(publicDto(current));
  });
  app.get("/internal/sessions/:sid/previews", async (request, reply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    return { items: [publicDto(current)] };
  });
  app.get("/internal/sessions/:sid/previews/:pid", async (request, reply) => {
    capture(request);
    if (!owned(request) || (request.params as { pid: string }).pid !== current.id) return missing(reply);
    return publicDto(current);
  });
  app.post("/internal/sessions/:sid/previews/:pid/stop", async (request, reply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    return publicDto(current, "stopped");
  });
  app.get("/internal/sessions/:sid/previews/:pid/logs", async (request, reply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    return { text: "redacted preview log\n", truncated: false };
  });
  app.get("/internal/sessions/:sid/previews/:pid/registration", async (request, reply) => {
    capture(request);
    if (!owned(request) || (request.params as { pid: string }).pid !== current.id) return missing(reply);
    return current;
  });
  app.post("/internal/sessions/:sid/previews/:pid/touch", async (request, reply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    const body = request.body as { generation: number; now: string };
    touchResults.push(touchResult);
    if (touchResult && body.generation === current.generation) {
      current = staticRegistration({ ...current, lastAccessAt: body.now });
    }
    if (afterTouch !== null) {
      const callback = afterTouch;
      afterTouch = null;
      callback();
    }
    return { touched: touchResult };
  });

  const staticBytes = async (request: FastifyRequest, reply: FastifyReply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    for (const [name, value] of Object.entries(staticAnswer.headers ?? {})) reply.header(name, value);
    return reply.code(staticAnswer.status).send(staticAnswer.body ?? "");
  };
  app.route({ method: ["GET", "HEAD"], url: "/internal/sessions/:sid/previews/:pid/static", handler: staticBytes });
  app.route({ method: ["GET", "HEAD"], url: "/internal/sessions/:sid/previews/:pid/static/*", handler: staticBytes });

  const fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = new URL(String(input));
    const method = (init?.method ?? "GET") as "GET" | "HEAD" | "POST";
    const staticCall = url.pathname.includes("/static");
    if (staticCall) staticSignals.push(init?.signal);
    const response = await app.inject({
      method,
      url: `${url.pathname}${url.search}`,
      headers: Object.fromEntries(new Headers(init?.headers).entries()),
      ...(init?.body !== undefined && init.body !== null ? { payload: String(init.body) } : {}),
    });
    if (staticCall && staticResponse !== null) return staticResponse;
    return new Response(method === "HEAD" || response.statusCode === 204 || response.statusCode === 304
      ? null
      : response.rawPayload, {
      status: response.statusCode,
      headers: Object.fromEntries(
        Object.entries(response.headers).filter((entry): entry is [string, string] => typeof entry[1] === "string"),
      ),
    });
  };

  return {
    calls,
    touchResults,
    client: createStudioPreviewWorkerClient({
      baseUrl: "http://worker.internal:8093",
      token: INTERNAL_TOKEN,
      fetch: fetch as typeof fetch,
      ...(options.idleTimeoutMs !== undefined ? { idleTimeoutMs: options.idleTimeoutMs } : {}),
    }),
    staticSignals,
    registrationCalls: () => calls.filter((call) => call.url.endsWith("/registration")),
    touchCalls: () => calls.filter((call) => call.url.endsWith("/touch")),
    staticCalls: () => calls.filter((call) => call.url.includes("/static")),
    setRecord(next: StudioPreviewRegistration) { current = next; },
    setTouchResult(next: boolean) { touchResult = next; },
    afterNextTouch(patch: Partial<StudioPreviewRegistration>) {
      afterTouch = () => { current = staticRegistration({ ...current, ...patch }); };
    },
    setStaticAnswer(next: StaticAnswer) { staticAnswer = next; },
    setStaticResponse(next: Response) { staticResponse = next; },
    get record() { return current; },
  };
}

interface HarnessOptions {
  disabled?: boolean;
  registration?: StudioPreviewRegistration;
  rateLimits?: boolean;
  devMaxBytes?: number;
  logger?: BuildGatewayOptions["logger"];
  previewOrigin?: string;
  webOrigin?: string;
  workerHost?: string;
  workerIdleTimeoutMs?: number;
}

async function harness(options: HarnessOptions = {}) {
  const initial = options.registration ?? staticRegistration();
  const worker = await fakeWorker(initial, {
    ...(options.workerIdleTimeoutMs !== undefined
      ? { idleTimeoutMs: options.workerIdleTimeoutMs }
      : {}),
  });
  const redis = new MemoryPreviewRedis();
  let nowMs = NOW.getTime();
  const now = () => new Date(nowMs);
  const tickets = createPreviewTicketStore(redis, { now });
  const ownership: Array<{ userId: string; sessionId: string }> = [];
  let sessionRevoked = false;
  const config: StudioPreviewGatewayConfig = {
    previewOrigin: options.previewOrigin ?? PREVIEW_ORIGIN,
    webOrigin: options.webOrigin ?? WEB_ORIGIN,
    workerHost: options.workerHost ?? "worker.internal",
    worker: worker.client,
    tickets,
    redis,
    now,
    isSessionOwner: async (userId, sessionId) => {
      ownership.push({ userId, sessionId });
      return !sessionRevoked && userId === UID && sessionId === SID;
    },
    ...(options.devMaxBytes !== undefined ? { devMaxBytes: options.devMaxBytes } : {}),
  };
  const baseVerifier = stubVerifier();
  let verifierCalls = 0;
  const limiterCalls: unknown[] = [];
  const { queues } = stubQueues();
  const app = buildGateway({
    system: stubSystemBus(),
    db: noopDb,
    queues,
    verifier: async (token, appCheck) => {
      verifierCalls += 1;
      return baseVerifier(token, appCheck);
    },
    tickets: {
      mint: async () => "ws-ticket",
      verify: async () => null,
    },
    keys: stubKeys(),
    mint: stubMint(),
    events: noopEvents,
    clock: now,
    ...(options.rateLimits === true ? {
      rateLimiter: {
        consume: async (input: unknown) => {
          limiterCalls.push(input);
          return { allowed: true, retryAfterSeconds: 0, scope: "ip" as const };
        },
      },
    } : {}),
    ...(options.disabled === true ? {} : { studioPreview: config }),
  }, {
    ...(options.logger !== undefined ? { logger: options.logger } : {}),
  });
  cleanups.push(() => app.close());

  const devCalls: Array<{ url: string; init?: RequestInit }> = [];
  let devAnswer: Response | (() => Response | Promise<Response>) = new Response("<h1>dev preview</h1>", {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
  config.devFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    devCalls.push({ url: String(input), init });
    return typeof devAnswer === "function" ? devAnswer() : devAnswer;
  }) as typeof fetch;

  const api = (method: "GET" | "POST", url: string, options: {
    uid?: string;
    body?: unknown;
    headers?: Record<string, string>;
  } = {}) => app.inject({
    method,
    url,
    headers: {
      ...authHeaders(options.uid ?? UID),
      host: "api.example.test",
      ...options.headers,
    },
    ...(options.body !== undefined ? { payload: options.body } : {}),
  });
  const origin = (method: "GET" | "HEAD" | "POST", url: string, options: {
    host?: string;
    cookie?: string;
    headers?: Record<string, string>;
  } = {}) => app.inject({
    method,
    url,
    headers: {
      host: options.host ?? "preview.example.test",
      ...(options.cookie !== undefined ? { cookie: options.cookie } : {}),
      ...options.headers,
    },
  });
  const mintLaunch = async (): Promise<{ ticket: string; launchUrl: string }> => {
    const response = await api("POST", `${API_BASE}/${PID}/ticket`);
    expect(response.statusCode).toBe(200);
    const body = response.json();
    const parsed = new URL(body.launchUrl);
    return { ticket: parsed.searchParams.get("ticket")!, launchUrl: body.launchUrl };
  };
  const exchange = async (): Promise<{ ticket: string; cookie: string; response: Awaited<ReturnType<typeof origin>> }> => {
    const launch = await mintLaunch();
    const url = new URL(launch.launchUrl);
    const response = await origin("GET", `${url.pathname}${url.search}`);
    expect(response.statusCode).toBe(303);
    const setCookie = response.headers["set-cookie"];
    expect(typeof setCookie).toBe("string");
    const cookie = parsePreviewCookie(setCookie as string);
    const rawCookie = /__Host-ovid_preview=([A-Za-z0-9_-]{43})/.exec(setCookie as string)?.[1];
    expect(rawCookie).toBeDefined();
    expect(cookie).toBe(rawCookie);
    return { ticket: launch.ticket, cookie: rawCookie!, response };
  };

  return {
    app,
    api,
    origin,
    mintLaunch,
    exchange,
    worker,
    redis,
    config,
    ownership,
    devCalls,
    limiterCalls,
    setDevAnswer(next: Response | (() => Response | Promise<Response>)) { devAnswer = next; },
    get verifierCalls() { return verifierCalls; },
    resetVerifierCalls() { verifierCalls = 0; },
    revokeSession() { sessionRevoked = true; },
    advance(ms: number) { nowMs += ms; },
  };
}

describe("UNEXECUTED Studio preview configuration deny-by-default", () => {
  it("disables preview unless an exact HTTPS origin and separate complete config exist", () => {
    expect(loadGatewayEnv({ OVID_AUTH_MODE: "test" }).preview).toBeUndefined();
    expect(loadGatewayEnv({
      OVID_AUTH_MODE: "test",
      OVID_PREVIEW_ORIGIN: PREVIEW_ORIGIN,
    }).preview).toBeUndefined();
    expect(loadGatewayEnv({
      OVID_AUTH_MODE: "test",
      OVID_PREVIEW_ORIGIN: PREVIEW_ORIGIN,
      OVID_WEB_ORIGIN: WEB_ORIGIN,
    }).preview).toBeUndefined();
    expect(loadGatewayEnv({
      OVID_AUTH_MODE: "test",
      OVID_PREVIEW_ORIGIN: PREVIEW_ORIGIN,
      OVID_WEB_ORIGIN: WEB_ORIGIN,
      OVID_PREVIEW_WORKER_HOST: "worker.internal",
    }).preview).toEqual({
      previewOrigin: PREVIEW_ORIGIN,
      webOrigin: WEB_ORIGIN,
      workerHost: "worker.internal",
    });
  });

  it.each([
    ["http://preview.example.test", WEB_ORIGIN, "worker.internal"],
    ["https://preview.example.test/path", WEB_ORIGIN, "worker.internal"],
    ["https://preview.example.test/?query=1", WEB_ORIGIN, "worker.internal"],
    ["https://preview.example.test/#fragment", WEB_ORIGIN, "worker.internal"],
    ["https://user:pass@preview.example.test", WEB_ORIGIN, "worker.internal"],
    [PREVIEW_ORIGIN, "https://web.example.test/path", "worker.internal"],
    [PREVIEW_ORIGIN, WEB_ORIGIN, "http://worker.internal"],
    [PREVIEW_ORIGIN, WEB_ORIGIN, "worker.internal:23456"],
    [PREVIEW_ORIGIN, WEB_ORIGIN, "8.8.8.8"],
    [PREVIEW_ORIGIN, PREVIEW_ORIGIN, "worker.internal"],
  ])("refuses unsafe or non-dedicated preview config: %s", async (previewOrigin, webOrigin, workerHost) => {
    expect(() => loadGatewayEnv({
      OVID_AUTH_MODE: "test",
      OVID_PREVIEW_ORIGIN: previewOrigin,
      OVID_WEB_ORIGIN: webOrigin,
      OVID_PREVIEW_WORKER_HOST: workerHost,
    })).toThrow(/OVID_PREVIEW|OVID_WEB/);
  });

  it("leaves API and origin routes unmounted when preview is disabled", async () => {
    const h = await harness({ disabled: true });
    const api = await h.api("GET", API_BASE);
    expect(api.statusCode).toBe(404);
    const root = await h.origin("GET", "/preview/exchange?ticket=disabled-secret");
    expect(root.statusCode).toBe(404);
    expect(root.body).not.toContain("disabled-secret");
    expect(h.worker.calls).toEqual([]);
  });
});

describe("UNEXECUTED authenticated Studio preview API composition", () => {
  it("creates, lists, gets, stops, and reads logs through the verified session owner", async () => {
    const h = await harness({ registration: devRegistration() });
    const created = await h.api("POST", API_BASE, {
      body: { kind: "dev_server", projectDir: "app", script: "dev" },
    });
    expect(created.statusCode).toBe(201);
    expect(created.json()).toEqual(publicDto(devRegistration()));
    expect(h.worker.calls[0]?.headers).toMatchObject({
      "x-ovid-internal-token": INTERNAL_TOKEN,
      "x-ovid-user-id": UID,
    });
    expect(h.worker.calls[0]?.headers).not.toHaveProperty("authorization");
    expect(h.worker.calls[0]?.body).toEqual({
      kind: "dev_server",
      projectDir: "app",
      script: "dev",
    });

    expect((await h.api("GET", API_BASE)).json()).toEqual({ items: [publicDto(devRegistration())] });
    expect((await h.api("GET", `${API_BASE}/${PID}`)).json()).toEqual(publicDto(devRegistration()));
    expect((await h.api("GET", `${API_BASE}/${PID}/logs`)).json()).toEqual({
      text: "redacted preview log\n",
      truncated: false,
    });
    expect((await h.api("POST", `${API_BASE}/${PID}/stop`)).json().status).toBe("stopped");
    expect(h.ownership.every((call) => call.userId === UID && call.sessionId === SID)).toBe(true);
  });

  it("denies unauthenticated, foreign-session, malformed-id, and extra-field requests before worker effects", async () => {
    const h = await harness();
    const unauthenticated = await h.app.inject({ method: "GET", url: API_BASE });
    expect(unauthenticated.statusCode).toBe(401);
    const foreign = await h.api("GET", `/cloud/v1/studio/sessions/${OTHER_SID}/previews`, { uid: OTHER_UID });
    expect(foreign.statusCode).toBe(404);
    const malformed = await h.api("GET", "/cloud/v1/studio/sessions/not-a-uuid/previews");
    expect(malformed.statusCode).toBe(404);

    for (const body of [
      { kind: "static", workspacePath: "dist", url: "http://attacker.invalid" },
      { kind: "dev_server", projectDir: "app", script: "dev", command: "id" },
      { kind: "dev_server", projectDir: "app", script: "build" },
    ]) {
      const response = await h.api("POST", API_BASE, { body });
      expect(response.statusCode).toBe(400);
    }
    const extraStop = await h.api("POST", `${API_BASE}/${PID}/stop`, {
      body: { ticket: "must-not-be-accepted" },
    });
    expect(extraStop.statusCode).toBe(400);
    expect(h.worker.calls).toEqual([]);
  });

  it("collapses worker failures to a safe 503 without raw credential or provider detail", async () => {
    const h = await harness();
    h.config.worker = {
      forUser: () => ({
        start: async () => {
          throw new Error("worker firebase-secret provider payload");
        },
      }),
    } as unknown as StudioPreviewGatewayConfig["worker"];
    const response = await h.api("POST", API_BASE, {
      body: { kind: "static", workspacePath: "dist" },
    });
    expect(response.statusCode).toBe(503);
    expect(response.json()).toEqual({
      error: { code: "preview_unavailable", message: "Studio previews are temporarily unavailable." },
    });
    expect(response.body).not.toContain("firebase-secret");
    expect(response.body).not.toContain("provider payload");
  });

  it("mints a 60-second launch only from the authoritative running worker binding", async () => {
    const h = await harness();
    const response = await h.api("POST", `${API_BASE}/${PID}/ticket`, {
      headers: { host: "attacker.invalid" },
    });
    expect(response.statusCode).toBe(200);
    const body = response.json();
    const launch = new URL(body.launchUrl);
    expect(launch.origin).toBe(PREVIEW_ORIGIN);
    expect(launch.pathname).toBe("/preview/exchange");
    expect(launch.searchParams.get("ticket")).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(body.ticketExpiresAt).toBe("2026-10-25T12:01:00.000Z");
    expect(body.cookieExpiresAt).toBe("2026-10-25T12:15:00.000Z");
    expect(body).not.toHaveProperty("cookieToken");
    expect(body).not.toHaveProperty("bindHost");
    expect(body).not.toHaveProperty("port");
    expect(PREVIEW_TICKET_TTL_SECONDS).toBe(60);
    expect([...h.redis.expiries.values()].sort((a, b) => a - b)).toEqual([60, 900]);
    const stored = [...h.redis.values.values()].map((value) => JSON.parse(value));
    expect(stored).toHaveLength(2);
    for (const grant of stored) {
      expect(grant).toMatchObject({
        userId: UID,
        sessionId: SID,
        previewId: PID,
        generation: 7,
      });
    }
  });

  it("does not mint for starting, stopped, expired, or foreign registrations", async () => {
    for (const registration of [
      staticRegistration({ status: "starting" }),
      staticRegistration({ status: "stopped" }),
      staticRegistration({ expiresAt: NOW.toISOString() }),
      staticRegistration({ userId: OTHER_UID }),
    ]) {
      const h = await harness({ registration });
      const before = h.redis.calls.length;
      const response = await h.api("POST", `${API_BASE}/${PID}/ticket`);
      expect(response.statusCode).toBe(404);
      expect(h.redis.calls.length).toBe(before);
      expect(h.worker.touchCalls()).toEqual([]);
    }
  });
});

describe("UNEXECUTED dedicated preview origin exchange and HMR refusal", () => {
  it("pins the configured host, consumes GETDEL once, sets only the preview cookie, and redirects clean", async () => {
    const h = await harness({ rateLimits: true });
    const launch = await h.mintLaunch();
    const beforeWorker = h.worker.calls.length;
    h.resetVerifierCalls();
    const beforeLimits = h.limiterCalls.length;

    const wrongHost = await h.origin("GET", `/preview/exchange?ticket=${encodeURIComponent(launch.ticket)}`, {
      host: "api.example.test",
      headers: { authorization: "Bearer firebase-secret" },
    });
    expect(wrongHost.statusCode).toBe(404);
    expect(wrongHost.body).not.toContain(launch.ticket);

    const url = new URL(launch.launchUrl);
    const exchanged = await h.origin("GET", `${url.pathname}${url.search}`, {
      headers: { authorization: "Bearer firebase-secret" },
    });
    expect(exchanged.statusCode).toBe(303);
    expect(exchanged.headers.location).toBe(`/preview/${PID}/`);
    expect(exchanged.headers.location).not.toContain("ticket");
    expect(exchanged.headers["cache-control"]).toBe("private, no-store");
    expect(exchanged.headers["referrer-policy"]).toBe("no-referrer");
    const setCookie = exchanged.headers["set-cookie"] as string;
    expect(setCookie).toContain(`${PREVIEW_COOKIE_NAME}=`);
    expect(setCookie).toContain("Secure");
    expect(setCookie).toContain("HttpOnly");
    expect(setCookie).toContain("SameSite=Strict");
    expect(setCookie).toContain("Path=/");
    expect(setCookie).not.toContain("Domain=");
    expect(setCookie).not.toContain("ovid_session");
    expect(exchanged.body).not.toContain(launch.ticket);
    expect(h.worker.calls.length).toBe(beforeWorker);
    expect(h.verifierCalls).toBe(0);
    expect(h.limiterCalls.length).toBe(beforeLimits);

    const replay = await h.origin("GET", `${url.pathname}${url.search}`);
    expect(replay.statusCode).toBe(404);
    expect(replay.headers["set-cookie"]).toBeUndefined();
    expect(replay.body).not.toContain(launch.ticket);
    expect(replay.body).not.toContain(setCookie);
    expect(h.redis.calls.filter((call) => call.command === "GETDEL")).toHaveLength(2);
  });

  it("refuses exchange/content WebSocket and HMR attempts without burning or echoing grants", async () => {
    const h = await harness();
    const launch = await h.mintLaunch();
    const hmrExchange = await h.origin("GET", `/preview/exchange?ticket=${encodeURIComponent(launch.ticket)}`, {
      headers: {
        connection: "Upgrade",
        upgrade: "websocket",
        "sec-websocket-protocol": "vite-hmr",
      },
    });
    expect(hmrExchange.statusCode).toBe(501);
    expect(hmrExchange.json().error.code).toBe("preview_hmr_unavailable");
    expect(hmrExchange.body).not.toContain(launch.ticket);
    expect(hmrExchange.headers["set-cookie"]).toBeUndefined();

    const exchanged = await h.origin("GET", `/preview/exchange?ticket=${encodeURIComponent(launch.ticket)}`);
    expect(exchanged.statusCode).toBe(303);
    const cookie = /__Host-ovid_preview=([A-Za-z0-9_-]{43})/.exec(exchanged.headers["set-cookie"] as string)![1]!;
    const before = h.worker.calls.length;
    for (const path of [`/preview/${PID}/`, `/preview/${PID}/__vite_hmr`]) {
      const denied = await h.origin("GET", path, {
        cookie: `__Host-ovid_preview=${cookie}`,
        headers: {
          connection: "Upgrade",
          upgrade: "websocket",
          "sec-websocket-protocol": "vite-hmr",
        },
      });
      expect(denied.statusCode).toBe(501);
      expect(denied.body).not.toContain(cookie);
      expect(denied.headers["set-cookie"]).toBeUndefined();
    }
    expect(h.worker.calls.length).toBe(before);
  });
});

describe("UNEXECUTED static preview origin composition", () => {
  it("verifies the cookie, touches and re-reads, then serves bounded bytes with no credential forwarding", async () => {
    const h = await harness();
    const { cookie } = await h.exchange();
    h.worker.setStaticAnswer({
      status: 200,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "set-cookie": "ovid_session=must-not-cross",
        "cache-control": "public, max-age=9999",
      },
      body: "<h1>isolated</h1>",
    });
    const before = h.worker.calls.length;
    const response = await h.origin("GET", `/preview/${PID}/assets/index.html?theme=dark`, {
      cookie: `ovid_session=browser-secret; __Host-ovid_preview=${cookie}`,
      headers: {
        authorization: "Bearer firebase-secret",
        accept: "text/html",
        "x-forwarded-host": "attacker.invalid",
        "x-ovid-internal-token": "attacker-token",
      },
    });
    expect(response.statusCode).toBe(200);
    expect(response.body).toBe("<h1>isolated</h1>");
    expect(response.headers["content-security-policy"]).toBe(createPreviewCsp({
      kind: "static",
      webOrigin: WEB_ORIGIN,
      previewOrigin: PREVIEW_ORIGIN,
    }));
    expect(response.headers["content-security-policy"]).toContain("default-src 'none'");
    expect(response.headers["content-security-policy"]).not.toContain("api.ovidsi.com");
    expect(response.headers["cache-control"]).toBe("private, no-store");
    expect(response.headers["set-cookie"]).toBeUndefined();

    const contentCalls = h.worker.calls.slice(before);
    expect(contentCalls.map((call) => `${call.method} ${call.url}`)).toEqual([
      `GET /internal/sessions/${SID}/previews/${PID}/registration`,
      `POST /internal/sessions/${SID}/previews/${PID}/touch`,
      `GET /internal/sessions/${SID}/previews/${PID}/registration`,
      `GET /internal/sessions/${SID}/previews/${PID}/static/assets/index.html?theme=dark`,
    ]);
    expect(h.worker.touchCalls()[0]?.body).toEqual({ generation: 7, now: NOW.toISOString() });
    const staticCall = h.worker.staticCalls().at(-1)!;
    expect(staticCall.headers["x-ovid-internal-token"]).toBe(INTERNAL_TOKEN);
    expect(staticCall.headers["x-ovid-user-id"]).toBe(UID);
    expect(staticCall.headers.authorization).toBeUndefined();
    expect(staticCall.headers.cookie).toBeUndefined();
    expect(staticCall.headers["x-forwarded-host"]).toBeUndefined();
    expect(response.body).not.toContain(INTERNAL_TOKEN);
  });

  it("requires the authoritative post-touch read even when touch is throttled false", async () => {
    const h = await harness();
    const { cookie } = await h.exchange();
    h.worker.setTouchResult(false);
    const before = h.worker.registrationCalls().length;
    const response = await h.origin("GET", `/preview/${PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(response.statusCode).toBe(200);
    expect(h.worker.touchResults).toEqual([false]);
    expect(h.worker.registrationCalls().length - before).toBe(2);
    expect(h.worker.record.generation).toBe(7);
    expect(h.worker.staticCalls()).toHaveLength(1);
  });

  it("denies cross-binding cookies and revoked cookie grants before worker access", async () => {
    const h = await harness();
    const { cookie } = await h.exchange();
    const before = h.worker.calls.length;
    const wrongPreview = await h.origin("GET", `/preview/${OTHER_PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(wrongPreview.statusCode).toBe(404);
    expect(h.worker.calls.length).toBe(before);

    h.redis.values.delete(`ovid:studio:preview:cookie:${cookie}`);
    const revoked = await h.origin("GET", `/preview/${PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(revoked.statusCode).toBe(404);
    expect(h.worker.calls.length).toBe(before);
  });

  it("denies a session revoked after exchange before registration or touch", async () => {
    const h = await harness();
    const { cookie } = await h.exchange();
    h.revokeSession();
    const before = h.worker.calls.length;
    const response = await h.origin("GET", `/preview/${PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(response.statusCode).toBe(404);
    expect(h.worker.calls.length).toBe(before);
  });

  it.each([
    ["stale generation", staticRegistration({ generation: 8 })],
    ["stopped", staticRegistration({ status: "stopped" })],
    ["expired", staticRegistration({ expiresAt: NOW.toISOString() })],
  ])("denies %s before touch or byte access", async (_name, registration) => {
    const h = await harness();
    const { cookie } = await h.exchange();
    h.worker.setRecord(registration);
    const beforeTouches = h.worker.touchCalls().length;
    const beforeStatic = h.worker.staticCalls().length;
    const response = await h.origin("GET", `/preview/${PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(response.statusCode).toBe(404);
    expect(h.worker.touchCalls().length).toBe(beforeTouches);
    expect(h.worker.staticCalls().length).toBe(beforeStatic);
  });

  it("revalidates revocation after touch and never serves from the first snapshot", async () => {
    const h = await harness();
    const { cookie } = await h.exchange();
    h.worker.afterNextTouch({ status: "stopped" });
    const beforeStatic = h.worker.staticCalls().length;
    const response = await h.origin("GET", `/preview/${PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(response.statusCode).toBe(404);
    expect(h.worker.staticCalls().length).toBe(beforeStatic);
  });

  it("keeps HEAD empty, preserves its declared bound, and denies oversized declarations", async () => {
    const h = await harness();
    const { cookie } = await h.exchange();
    h.worker.setStaticAnswer({
      status: 200,
      headers: { "content-length": "5", "content-type": "text/plain" },
      body: "12345",
    });
    const head = await h.origin("HEAD", `/preview/${PID}/asset`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(head.statusCode).toBe(200);
    expect(head.rawPayload).toHaveLength(0);
    expect(head.headers["content-length"]).toBe("5");
    expect(h.worker.staticCalls().at(-1)?.method).toBe("HEAD");

    const oversized = await harness();
    const second = await oversized.exchange();
    oversized.worker.setStaticAnswer({
      status: 200,
      headers: { "content-length": String(PREVIEW_HTTP_MAX_BYTES + 1) },
      body: "not-read",
    });
    const denied = await oversized.origin("HEAD", `/preview/${PID}/asset`, {
      cookie: `__Host-ovid_preview=${second.cookie}`,
    });
    expect(denied.statusCode).toBe(413);
    expect(denied.rawPayload).toHaveLength(0);
  });
});

describe("UNEXECUTED dev-server preview origin composition", () => {
  it("uses the real registration/touch adapter and reconstructs only the configured private upstream", async () => {
    const h = await harness({ registration: devRegistration() });
    const { cookie } = await h.exchange();
    const before = h.worker.registrationCalls().length;
    const response = await h.origin("GET", `/preview/${PID}/assets/app.js?raw`, {
      cookie: `ovid_session=browser-secret; __Host-ovid_preview=${cookie}`,
      headers: {
        authorization: "Bearer firebase-secret",
        accept: "text/javascript",
        host: "preview.example.test",
        "x-forwarded-host": "attacker.invalid",
        "x-ovid-internal-token": "attacker-token",
      },
    });
    expect(response.statusCode).toBe(200);
    expect(response.body).toBe("<h1>dev preview</h1>");
    expect(h.devCalls).toHaveLength(1);
    expect(h.devCalls[0]?.url).toBe("http://worker.internal:23456/assets/app.js?raw");
    expect(h.devCalls[0]?.init?.redirect).toBe("manual");
    expect(Object.fromEntries(new Headers(h.devCalls[0]?.init?.headers).entries())).toEqual({
      accept: "text/javascript",
    });
    expect(h.worker.registrationCalls().length - before).toBe(3);
    expect(h.worker.touchCalls()).toHaveLength(1);
    expect(h.worker.touchCalls()[0]?.body).toEqual({ generation: 7, now: NOW.toISOString() });
    expect(response.headers["content-security-policy"]).toBe(createPreviewCsp({
      kind: "dev_server",
      webOrigin: WEB_ORIGIN,
      previewOrigin: PREVIEW_ORIGIN,
    }));
    expect(response.headers["content-security-policy"]).not.toContain("api.ovidsi.com");
    expect(response.headers["set-cookie"]).toBeUndefined();
  });

  it("denies dev upstream redirects without following or exposing their target", async () => {
    const h = await harness({ registration: devRegistration() });
    const { cookie } = await h.exchange();
    h.setDevAnswer(new Response("redirect-secret", {
      status: 302,
      headers: { location: "http://169.254.169.254/latest" },
    }));
    const response = await h.origin("GET", `/preview/${PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(response.statusCode).toBe(502);
    expect(response.json().error.code).toBe("redirect_denied");
    expect(response.headers.location).toBeUndefined();
    expect(response.body).not.toContain("169.254.169.254");
    expect(response.body).not.toContain("redirect-secret");
    expect(h.devCalls).toHaveLength(1);
  });

  it("returns no dev HEAD body and enforces the configured hard byte ceiling", async () => {
    const h = await harness({ registration: devRegistration() });
    const { cookie } = await h.exchange();
    h.setDevAnswer(new Response("12345", {
      status: 200,
      headers: { "content-length": "5", "content-type": "text/plain" },
    }));
    const head = await h.origin("HEAD", `/preview/${PID}/asset`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(head.statusCode).toBe(200);
    expect(head.rawPayload).toHaveLength(0);
    expect(head.headers["content-length"]).toBe("5");

    const bounded = await harness({ registration: devRegistration(), devMaxBytes: 5 });
    const second = await bounded.exchange();
    bounded.setDevAnswer(new Response("123456", {
      status: 200,
      headers: { "content-length": "6" },
    }));
    const denied = await bounded.origin("HEAD", `/preview/${PID}/asset`, {
      cookie: `__Host-ovid_preview=${second.cookie}`,
    });
    expect(denied.statusCode).toBe(413);
    expect(denied.rawPayload).toHaveLength(0);
  });

  it("fails closed 503 when registration or touch is unavailable", async () => {
    const h = await harness({ registration: devRegistration() });
    const { cookie } = await h.exchange();
    h.config.worker = {
      forUser: () => ({
        getLiveRegistration: async () => {
          throw new Error("private worker outage detail");
        },
      }),
    } as unknown as StudioPreviewGatewayConfig["worker"];
    const response = await h.origin("GET", `/preview/${PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(response.statusCode).toBe(503);
    expect(response.json()).toEqual({
      error: { code: "preview_unavailable", message: "Studio previews are temporarily unavailable." },
    });
    expect(response.body).not.toContain("private worker outage detail");
    expect(h.devCalls).toEqual([]);
  });
});

function neverSettlingCancelResponse(
  status: number,
  headers: Record<string, string>,
  mode: "open" | "stall" = "open",
) {
  let chunks = 0;
  let cancels = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (mode === "stall" && chunks++ === 0) {
        controller.enqueue(Buffer.from("first"));
      }
      // Intentionally leave later reads pending forever.
    },
    cancel() {
      cancels += 1;
      return new Promise<void>(() => {});
    },
  });
  return {
    response: new Response(body, { status, headers }),
    cancels: () => cancels,
  };
}

describe("UNEXECUTED G-1 preview request-log credential containment", () => {
  function logger(lines: string[]): BuildGatewayOptions["logger"] {
    return {
      level: "info",
      stream: { write(line) { lines.push(line); } },
      serializers: {
        req: (request: FastifyRequest) => ({
          method: request.method,
          url: request.url,
          headers: request.headers,
          telemetry: "custom-request-serializer",
        }),
      },
    };
  }

  it("redacts ticket URL and credential headers on a normal exchange while retaining safe telemetry", async () => {
    const lines: string[] = [];
    const h = await harness({ logger: logger(lines) });
    const launch = await h.mintLaunch();
    const rawUrl = `/preview/exchange?ticket=${encodeURIComponent(launch.ticket)}`;
    const response = await h.origin("GET", rawUrl, {
      cookie: "ovid_session=log-cookie-canary; __Host-ovid_preview=log-preview-cookie-canary",
      headers: {
        authorization: "Bearer log-authorization-canary",
        "x-ovid-internal-token": INTERNAL_TOKEN,
      },
    });
    expect(response.statusCode).toBe(303);
    const output = lines.join("\n");
    expect(output).toContain("incoming request");
    expect(output).toContain("/preview/exchange?[redacted]");
    expect(output).toContain("custom-request-serializer");
    expect(output).toContain(`${API_BASE}/${PID}/ticket`);
    expect(output).not.toContain(launch.ticket);
    expect(output).not.toContain(rawUrl);
    expect(output).not.toContain("log-cookie-canary");
    expect(output).not.toContain("log-preview-cookie-canary");
    expect(output).not.toContain("log-authorization-canary");
    expect(output).not.toContain(INTERNAL_TOKEN);
  });

  it("uses the safe default request serializer with no custom req serializer", async () => {
    const lines: string[] = [];
    const h = await harness({
      logger: {
        level: "info",
        stream: { write(line) { lines.push(line); } },
      },
    });
    const launch = await h.mintLaunch();
    const rawUrl = `/preview/exchange?ticket=${encodeURIComponent(launch.ticket)}`;
    const response = await h.origin("GET", rawUrl, {
      cookie: "ovid_session=default-log-cookie-canary",
      headers: {
        authorization: "Bearer default-log-authorization-canary",
        "x-ovid-internal-token": INTERNAL_TOKEN,
      },
    });
    expect(response.statusCode).toBe(303);
    const output = lines.join("\n");
    expect(output).toContain("incoming request");
    expect(output).toContain("/preview/exchange?[redacted]");
    expect(output).not.toContain(launch.ticket);
    expect(output).not.toContain(rawUrl);
    expect(output).not.toContain("default-log-cookie-canary");
    expect(output).not.toContain("default-log-authorization-canary");
    expect(output).not.toContain(INTERNAL_TOKEN);
  });

  it("redacts the still-valid ticket on pre-GETDEL Upgrade/501 and its later exchange", async () => {
    const lines: string[] = [];
    const h = await harness({ logger: logger(lines) });
    const launch = await h.mintLaunch();
    const rawUrl = `/preview/exchange?ticket=${encodeURIComponent(launch.ticket)}`;
    // app.inject covers the route decision only; real HTTP Upgrade remains a live gate.
    const denied = await h.origin("GET", rawUrl, {
      cookie: "ovid_session=log-upgrade-cookie-canary",
      headers: {
        connection: "Upgrade",
        upgrade: "websocket",
        "sec-websocket-protocol": "vite-hmr",
        authorization: "Bearer log-upgrade-authorization-canary",
        "x-ovid-internal-token": INTERNAL_TOKEN,
      },
    });
    expect(denied.statusCode).toBe(501);
    expect(h.redis.calls.filter((call) => call.command === "GETDEL")).toHaveLength(0);
    const exchanged = await h.origin("GET", rawUrl);
    expect(exchanged.statusCode).toBe(303);
    expect(h.redis.calls.filter((call) => call.command === "GETDEL")).toHaveLength(1);

    const output = lines.join("\n");
    expect(output).toContain("/preview/exchange?[redacted]");
    expect(output).not.toContain(launch.ticket);
    expect(output).not.toContain(rawUrl);
    expect(output).not.toContain("log-upgrade-cookie-canary");
    expect(output).not.toContain("log-upgrade-authorization-canary");
    expect(output).not.toContain(INTERNAL_TOKEN);
  });
});

describe("UNEXECUTED G-2/G-3 strict worker host and origin parsing", () => {
  it.each([
    ["2130706433", "127.0.0.1"],
    ["0x7f.0.0.1", "127.0.0.1"],
    ["0177.0.0.1", "127.0.0.1"],
    ["127.1", "127.0.0.1"],
    ["3232235777", "192.168.1.1"],
    ["[::ffff:127.0.0.1]", "[::ffff:7f00:1]"],
    ["[::ffff:7f00:1]", "[::ffff:7f00:1]"],
  ])("canonicalizes a private numeric worker host without using the raw spelling: %s", async (raw, canonical) => {
    expect(loadGatewayEnv({
      OVID_AUTH_MODE: "test",
      OVID_PREVIEW_ORIGIN: PREVIEW_ORIGIN,
      OVID_WEB_ORIGIN: WEB_ORIGIN,
      OVID_PREVIEW_WORKER_HOST: raw,
    }).preview?.workerHost).toBe(canonical);
  });

  it.each([
    "134744072",
    "0x08080808",
    "010.010.010.010",
    "8.8",
    "8.8.8",
    "169.254.169.254",
    "0xa9.0xfe.0xa9.0xfe",
    "0251.0376.0251.0376",
    "[::ffff:8.8.8.8]",
    "[::ffff:0808:0808]",
    "[::ffff:a9fe:a9fe]",
    "[fe80::1]",
    "é.example",
    "%77orker.internal",
  ])("rejects public/link-local numeric or mapped worker hosts: %s", async (workerHost) => {
    expect(() => loadGatewayEnv({
      OVID_AUTH_MODE: "test",
      OVID_PREVIEW_ORIGIN: PREVIEW_ORIGIN,
      OVID_WEB_ORIGIN: WEB_ORIGIN,
      OVID_PREVIEW_WORKER_HOST: workerHost,
    })).toThrow(/OVID_PREVIEW_WORKER_HOST/);
  });

  it("uses only the canonical private worker host in direct dev composition", async () => {
    const h = await harness({
      registration: devRegistration(),
      workerHost: "2130706433",
    });
    const { cookie } = await h.exchange();
    const response = await h.origin("GET", `/preview/${PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(response.statusCode).toBe(200);
    expect(h.devCalls[0]?.url).toBe("http://127.0.0.1:23456/");
    await expect(harness({
      registration: devRegistration(),
      workerHost: "134744072",
    })).rejects.toThrow(/OVID_PREVIEW_WORKER_HOST/);
  });

  it("accepts one conventional trailing slash but returns the canonical origin", () => {
    expect(loadGatewayEnv({
      OVID_AUTH_MODE: "test",
      OVID_PREVIEW_ORIGIN: `${PREVIEW_ORIGIN}/`,
      OVID_WEB_ORIGIN: `${WEB_ORIGIN}/`,
      OVID_PREVIEW_WORKER_HOST: "worker.internal",
    }).preview).toEqual({
      previewOrigin: PREVIEW_ORIGIN,
      webOrigin: WEB_ORIGIN,
      workerHost: "worker.internal",
    });
  });

  it.each([
    "https://preview.example.test/..",
    "https://preview.example.test/%2e%2e",
    "https://@preview.example.test",
    "https://preview.example.test:443",
    "https://preview.example.test//",
    "https://PREVIEW.example.test",
  ])("rejects noncanonical raw preview origin serialization at env: %s", async (previewOrigin) => {
    expect(() => loadGatewayEnv({
      OVID_AUTH_MODE: "test",
      OVID_PREVIEW_ORIGIN: previewOrigin,
      OVID_WEB_ORIGIN: WEB_ORIGIN,
      OVID_PREVIEW_WORKER_HOST: "worker.internal",
    })).toThrow(/OVID_PREVIEW_ORIGIN/);
  });

  it.each([
    ["https://preview.example.test/..", WEB_ORIGIN],
    ["https://@preview.example.test", WEB_ORIGIN],
    ["https://preview.example.test:443", WEB_ORIGIN],
    [PREVIEW_ORIGIN, "https://web.example.test/.."],
    [PREVIEW_ORIGIN, "https://@web.example.test"],
    [PREVIEW_ORIGIN, "https://web.example.test:443"],
  ])("uses the same raw-origin fence for direct gateway composition: %s", async (previewOrigin, webOrigin) => {
    await expect(harness({ previewOrigin, webOrigin })).rejects.toThrow(/OVID_PREVIEW_ORIGIN|OVID_WEB_ORIGIN/);
  });
});

describe("UNEXECUTED G-5 cookie expiry and composed static cleanup", () => {
  it("enforces cookieExpiresAt with gateway time before any worker access", async () => {
    const h = await harness();
    const { cookie } = await h.exchange();
    h.advance(15 * 60_000);
    const before = h.worker.calls.length;
    const response = await h.origin("GET", `/preview/${PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(response.statusCode).toBe(404);
    expect(h.worker.calls.length).toBe(before);
  });

  it("denies a composed static redirect and aborts its actual fetch signal despite broken body cancel", async () => {
    const h = await harness();
    const { cookie } = await h.exchange();
    const answer = neverSettlingCancelResponse(302, {
      location: "http://169.254.169.254/latest",
    });
    h.worker.setStaticResponse(answer.response);
    const response = await h.origin("GET", `/preview/${PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(response.statusCode).toBe(502);
    expect(response.json().error.code).toBe("redirect_denied");
    expect(response.headers.location).toBeUndefined();
    expect(response.body).not.toContain("169.254.169.254");
    expect(h.worker.staticSignals.at(-1)?.aborted).toBe(true);
  });

  it("bounds a composed static body stall and aborts the same fetch signal without awaiting cancel", async () => {
    const h = await harness({ workerIdleTimeoutMs: 5 });
    const { cookie } = await h.exchange();
    const answer = neverSettlingCancelResponse(200, {
      "content-type": "text/plain",
    }, "stall");
    h.worker.setStaticResponse(answer.response);
    const response = await h.origin("GET", `/preview/${PID}/`, {
      cookie: `__Host-ovid_preview=${cookie}`,
    });
    expect(response.statusCode).toBe(504);
    expect(response.json().error.code).toBe("upstream_timeout");
    expect(h.worker.staticSignals.at(-1)?.aborted).toBe(true);
    expect(answer.cancels()).toBeGreaterThan(0);
  });
});
