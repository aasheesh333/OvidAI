// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
// Authored regression-first; no test runner or typecheck was invoked in this lane.
import Fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import { afterEach, describe, expect, it } from "vitest";

import {
  StudioPreviewWorkerHttpError,
  StudioPreviewWorkerUnavailableError,
  createStudioPreviewWorkerClient,
  type StudioPreviewRegistration,
} from "./studioPreviewWorkerClient.js";

const UID = "verified-preview-user";
const SID = "00000000-0000-4000-8000-000000000091";
const PID = "0199aaaa-0000-7000-8000-000000000091";
const TOKEN = "internal-preview-token-that-must-not-reach-preview-content";
const NOW = new Date("2026-10-25T12:00:00.000Z");
const BASE = `/internal/sessions/${SID}/previews`;
const cleanups: Array<() => Promise<void> | void> = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

function registration(overrides: Partial<StudioPreviewRegistration> = {}): StudioPreviewRegistration {
  return {
    id: PID,
    userId: UID,
    sessionId: SID,
    generation: 7,
    kind: "dev_server",
    status: "running",
    bindHost: "127.0.0.1",
    port: 23_456,
    expiresAt: "2026-10-25T12:15:00.000Z",
    lastAccessAt: null,
    ...overrides,
  } as StudioPreviewRegistration;
}

function dto(overrides: Record<string, unknown> = {}) {
  return {
    id: PID,
    kind: "dev_server",
    status: "running",
    generation: 7,
    expiresAt: "2026-10-25T12:15:00.000Z",
    lastAccessAt: null,
    logAvailable: true,
    ...overrides,
  };
}

interface CapturedCall {
  method: string;
  url: string;
  uid: unknown;
  token: unknown;
  authorization: unknown;
  cookie: unknown;
  body: unknown;
}

interface StaticAnswer {
  status: number;
  headers?: Record<string, string>;
  body?: Buffer | string;
}

async function fakeWorker(initial = registration()) {
  const app = Fastify({ logger: false });
  cleanups.push(() => app.close());
  let current = initial;
  let touchResult: boolean = true;
  let staticAnswer: StaticAnswer = {
    status: 200,
    headers: { "content-type": "text/plain" },
    body: "bytes",
  };
  const calls: CapturedCall[] = [];
  const touches: Array<{ generation: number; now: string }> = [];

  app.addHook("preHandler", async (request, reply) => {
    if (
      request.headers["x-ovid-internal-token"] !== TOKEN ||
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
      uid: request.headers["x-ovid-user-id"],
      token: request.headers["x-ovid-internal-token"],
      authorization: request.headers.authorization,
      cookie: request.headers.cookie,
      body: request.body,
    });
  };
  const owned = (request: FastifyRequest): boolean =>
    request.headers["x-ovid-user-id"] === current.userId &&
    (request.params as { sid?: string }).sid === current.sessionId;
  const missing = (reply: FastifyReply): FastifyReply => reply.code(404).send({
    error: { code: "not_found", message: "worker-owned not-found detail" },
  });

  app.post("/internal/sessions/:sid/previews", async (request, reply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    return reply.code(201).send(dto());
  });
  app.get("/internal/sessions/:sid/previews", async (request, reply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    return { items: [dto()] };
  });
  app.get("/internal/sessions/:sid/previews/:pid", async (request, reply) => {
    capture(request);
    if (!owned(request) || (request.params as { pid: string }).pid !== current.id) {
      return missing(reply);
    }
    return dto();
  });
  app.post("/internal/sessions/:sid/previews/:pid/stop", async (request, reply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    return dto({ status: "stopped" });
  });
  app.get("/internal/sessions/:sid/previews/:pid/logs", async (request, reply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    return { text: "redacted worker log\n", truncated: false };
  });
  app.get("/internal/sessions/:sid/previews/:pid/registration", async (request, reply) => {
    capture(request);
    if (!owned(request) || (request.params as { pid: string }).pid !== current.id) {
      return missing(reply);
    }
    return current;
  });
  app.post("/internal/sessions/:sid/previews/:pid/touch", async (request, reply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    const body = request.body as { generation: number; now: string };
    touches.push(body);
    if (touchResult && body.generation === current.generation) {
      current = registration({ ...current, lastAccessAt: body.now });
    }
    return { touched: touchResult };
  });

  const staticBytes = async (request: FastifyRequest, reply: FastifyReply) => {
    capture(request);
    if (!owned(request)) return missing(reply);
    const answer = staticAnswer;
    for (const [name, value] of Object.entries(answer.headers ?? {})) reply.header(name, value);
    return reply.code(answer.status).send(answer.body ?? "");
  };
  app.route({ method: ["GET", "HEAD"], url: "/internal/sessions/:sid/previews/:pid/static", handler: staticBytes });
  app.route({ method: ["GET", "HEAD"], url: "/internal/sessions/:sid/previews/:pid/static/*", handler: staticBytes });

  const fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = new URL(String(input));
    const headers = Object.fromEntries(new Headers(init?.headers).entries());
    const method = (init?.method ?? "GET") as "GET" | "HEAD" | "POST";
    const response = await app.inject({
      method,
      url: `${url.pathname}${url.search}`,
      headers,
      ...(init?.body !== undefined && init.body !== null ? { payload: String(init.body) } : {}),
    });
    const responseHeaders = Object.fromEntries(
      Object.entries(response.headers).filter((entry): entry is [string, string] => typeof entry[1] === "string"),
    );
    return new Response(method === "HEAD" || response.statusCode === 204 || response.statusCode === 304
      ? null
      : response.rawPayload, {
      status: response.statusCode,
      headers: responseHeaders,
    });
  };

  return {
    app,
    calls,
    touches,
    client: createStudioPreviewWorkerClient({
      baseUrl: "http://worker.internal:8093",
      token: TOKEN,
      fetch: fetch as typeof fetch,
      maxStaticBytes: 5,
    }),
    setRecord(next: StudioPreviewRegistration) { current = next; },
    setTouchResult(next: boolean) { touchResult = next; },
    setStaticAnswer(next: StaticAnswer) { staticAnswer = next; },
    get record() { return current; },
  };
}

describe("UNEXECUTED Studio preview worker HTTP boundary", () => {
  it("calls management routes with only the configured internal token and bound verified uid", async () => {
    const worker = await fakeWorker();
    const bound = worker.client.forUser(UID);

    await expect(bound.start(SID, { kind: "dev_server", projectDir: "app", script: "dev" })).resolves.toMatchObject({
      id: PID,
      generation: 7,
    });
    await expect(bound.list(SID)).resolves.toHaveLength(1);
    await expect(bound.get(SID, PID)).resolves.toMatchObject({ id: PID });
    await expect(bound.logs(SID, PID)).resolves.toEqual({
      text: "redacted worker log\n",
      truncated: false,
    });
    await expect(bound.stop(SID, PID)).resolves.toMatchObject({ status: "stopped" });

    expect(worker.calls.map((call) => `${call.method} ${call.url}`)).toEqual([
      `POST ${BASE}`,
      `GET ${BASE}`,
      `GET ${BASE}/${PID}`,
      `GET ${BASE}/${PID}/logs`,
      `POST ${BASE}/${PID}/stop`,
    ]);
    expect(worker.calls[0]?.body).toEqual({
      kind: "dev_server",
      projectDir: "app",
      script: "dev",
    });
    for (const call of worker.calls) {
      expect(call.uid).toBe(UID);
      expect(call.token).toBe(TOKEN);
      expect(call.authorization).toBeUndefined();
      expect(call.cookie).toBeUndefined();
      expect(JSON.stringify(call.body ?? {})).not.toContain("firebase-secret");
    }
  });

  it("uses the full private registration and sends only expected generation plus gateway time to touch", async () => {
    const worker = await fakeWorker();
    const bound = worker.client.forUser(UID);
    await expect(bound.getLiveRegistration(SID, PID)).resolves.toEqual(registration());
    await expect(bound.touch({
      sessionId: SID,
      previewId: PID,
      generation: 7,
      now: NOW,
    })).resolves.toBe(true);
    expect(worker.touches).toEqual([{ generation: 7, now: NOW.toISOString() }]);
    expect(worker.calls.at(-1)?.body).toEqual({ generation: 7, now: NOW.toISOString() });
    expect(worker.record).toEqual(registration({ lastAccessAt: NOW.toISOString() }));

    worker.setTouchResult(false);
    await expect(bound.touch({
      sessionId: SID,
      previewId: PID,
      generation: 7,
      now: NOW,
    })).resolves.toBe(false);
  });

  it("fails closed instead of treating the public DTO as a private registration", async () => {
    const client = createStudioPreviewWorkerClient({
      baseUrl: "http://worker.internal:8093",
      token: TOKEN,
      fetch: (async () => new Response(JSON.stringify(dto()), {
        status: 200,
        headers: { "content-type": "application/json" },
      })) as typeof fetch,
    });
    await expect(client.forUser(UID).getLiveRegistration(SID, PID)).rejects.toBeInstanceOf(
      StudioPreviewWorkerUnavailableError,
    );
    await expect(client.forUser(UID).touch({
      sessionId: SID,
      previewId: PID,
      generation: 7,
      now: NOW,
    })).rejects.toBeInstanceOf(StudioPreviewWorkerUnavailableError);
  });

  it("rejects malformed registration identity and non-boolean touch answers", async () => {
    const malformedRegistration = createStudioPreviewWorkerClient({
      baseUrl: "http://worker.internal:8093",
      token: TOKEN,
      fetch: (async () => new Response(JSON.stringify(registration({ port: 80 })), { status: 200 })) as typeof fetch,
    });
    await expect(malformedRegistration.forUser(UID).getLiveRegistration(SID, PID)).rejects.toMatchObject({
      code: "preview_unavailable",
      status: 503,
    });

    const malformedTouch = createStudioPreviewWorkerClient({
      baseUrl: "http://worker.internal:8093",
      token: TOKEN,
      fetch: (async () => new Response(JSON.stringify(registration()), { status: 200 })) as typeof fetch,
    });
    await expect(malformedTouch.forUser(UID).touch({
      sessionId: SID,
      previewId: PID,
      generation: 7,
      now: NOW,
    })).rejects.toBeInstanceOf(StudioPreviewWorkerUnavailableError);
  });

  it("proxies normalized static paths with internal service auth and no browser credentials", async () => {
    const worker = await fakeWorker(registration({
      kind: "static",
      bindHost: null,
      port: null,
    }));
    const result = await worker.client.forUser(UID).readStatic({
      sessionId: SID,
      previewId: PID,
      method: "GET",
      path: "/assets/app.txt?download=1",
      headers: {
        accept: "text/plain",
        authorization: "Bearer firebase-secret",
        cookie: "ovid_session=secret; __Host-ovid_preview=cookie-secret",
        "x-forwarded-host": "attacker.invalid",
        "x-ovid-internal-token": "attacker-token",
      },
    });
    expect(result.status).toBe(200);
    expect(result.body.toString()).toBe("bytes");
    expect(worker.calls).toHaveLength(1);
    expect(worker.calls[0]?.url).toBe(`${BASE}/${PID}/static/assets/app.txt?download=1`);
    expect(worker.calls[0]?.token).toBe(TOKEN);
    expect(worker.calls[0]?.uid).toBe(UID);
    expect(worker.calls[0]?.authorization).toBeUndefined();
    expect(worker.calls[0]?.cookie).toBeUndefined();
  });

  it("denies static redirects without following or exposing Location", async () => {
    const worker = await fakeWorker();
    worker.setStaticAnswer({
      status: 302,
      headers: { location: "http://169.254.169.254/latest" },
      body: "redirect-secret",
    });
    const promise = worker.client.forUser(UID).readStatic({
      sessionId: SID,
      previewId: PID,
      method: "GET",
      path: "/",
      headers: {},
    });
    await expect(promise).rejects.toBeInstanceOf(StudioPreviewWorkerHttpError);
    await expect(promise).rejects.toMatchObject({ status: 502, code: "redirect_denied" });
    await expect(promise).rejects.not.toMatchObject({ message: expect.stringContaining("redirect-secret") });
    expect(worker.calls).toHaveLength(1);
  });

  it("enforces streamed static bounds and leaves HEAD bodies empty", async () => {
    const worker = await fakeWorker();
    worker.setStaticAnswer({
      status: 200,
      headers: { "content-type": "text/plain" },
      body: "six!!!",
    });
    await expect(worker.client.forUser(UID).readStatic({
      sessionId: SID,
      previewId: PID,
      method: "GET",
      path: "/large",
      headers: {},
    })).rejects.toMatchObject({ status: 413, code: "response_too_large" });

    worker.setStaticAnswer({
      status: 200,
      headers: { "content-length": "5", "content-type": "text/plain" },
      body: "12345",
    });
    const head = await worker.client.forUser(UID).readStatic({
      sessionId: SID,
      previewId: PID,
      method: "HEAD",
      path: "/large",
      headers: {},
    });
    expect(head.body).toHaveLength(0);
    expect(head.headers.get("content-length")).toBe("5");

    worker.setStaticAnswer({
      status: 200,
      headers: { "content-length": "6" },
      body: "123456",
    });
    await expect(worker.client.forUser(UID).readStatic({
      sessionId: SID,
      previewId: PID,
      method: "HEAD",
      path: "/large",
      headers: {},
    })).rejects.toMatchObject({ status: 413, code: "response_too_large" });
  });

  it("fails closed on an idle static response and never exposes raw transport details", async () => {
    let signal: AbortSignal | null | undefined;
    const client = createStudioPreviewWorkerClient({
      baseUrl: "http://worker.internal:8093",
      token: TOKEN,
      idleTimeoutMs: 5,
      fetch: ((_input: string | URL | Request, init?: RequestInit) => {
        signal = init?.signal;
        return new Promise<Response>(() => {});
      }) as typeof fetch,
    });
    await expect(client.forUser(UID).readStatic({
      sessionId: SID,
      previewId: PID,
      method: "GET",
      path: "/",
      headers: {},
    })).rejects.toMatchObject({ status: 504, code: "upstream_timeout" });
    expect(signal?.aborted).toBe(true);

    const failed = createStudioPreviewWorkerClient({
      baseUrl: "http://worker.internal:8093",
      token: TOKEN,
      fetch: (async () => {
        throw new Error("dial firebase-secret and internal-token-secret");
      }) as typeof fetch,
    });
    const promise = failed.forUser(UID).list(SID);
    await expect(promise).rejects.toMatchObject({
      code: "preview_unavailable",
      status: 503,
      message: "Studio preview worker is unavailable.",
    });
    await expect(promise).rejects.not.toMatchObject({ message: expect.stringContaining("secret") });
  });
});

function brokenCancelResponse(
  status: number,
  headers: Record<string, string>,
  mode: "open" | "stall" = "open",
) {
  let chunks = 0;
  let cancels = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (mode === "stall" && chunks++ === 0) {
        controller.enqueue(Buffer.from("first"));
      }
      // Deliberately never close the body or settle cancellation.
    },
    cancel() {
      cancels += 1;
      return new Promise<void>(() => {});
    },
  });
  return {
    response: new Response(stream, { status, headers }),
    cancels: () => cancels,
  };
}

function capturedCancellation(response: Response) {
  let signal: AbortSignal | null | undefined;
  const client = createStudioPreviewWorkerClient({
    baseUrl: "http://worker.internal:8093",
    token: TOKEN,
    idleTimeoutMs: 5,
    maxStaticBytes: 5,
    fetch: ((_input: string | URL | Request, init?: RequestInit) => {
      signal = init?.signal;
      return Promise.resolve(response);
    }) as typeof fetch,
  });
  return { client, signal: () => signal };
}

describe("UNEXECUTED G-4 request-scoped abort and broken body cancellation", () => {
  it("aborts the captured fetch signal on static redirect, HEAD, and declared-oversize cleanup", async () => {
    const redirect = capturedCancellation(brokenCancelResponse(302, {
      location: "http://169.254.169.254/latest",
    }).response);
    await expect(redirect.client.forUser(UID).readStatic({
      sessionId: SID,
      previewId: PID,
      method: "GET",
      path: "/",
      headers: {},
    })).rejects.toMatchObject({ status: 502, code: "redirect_denied" });
    expect(redirect.signal()?.aborted).toBe(true);

    const head = capturedCancellation(brokenCancelResponse(200, {
      "content-length": "5",
      "content-type": "text/plain",
    }).response);
    const result = await head.client.forUser(UID).readStatic({
      sessionId: SID,
      previewId: PID,
      method: "HEAD",
      path: "/",
      headers: {},
    });
    expect(result.body).toHaveLength(0);
    expect(head.signal()?.aborted).toBe(true);

    const oversized = capturedCancellation(brokenCancelResponse(200, {
      "content-length": "6",
      "content-type": "text/plain",
    }).response);
    await expect(oversized.client.forUser(UID).readStatic({
      sessionId: SID,
      previewId: PID,
      method: "GET",
      path: "/",
      headers: {},
    })).rejects.toMatchObject({ status: 413, code: "response_too_large" });
    expect(oversized.signal()?.aborted).toBe(true);
  });

  it("aborts the captured fetch signal on a static body stall without awaiting broken cancel", async () => {
    const answer = brokenCancelResponse(200, { "content-type": "text/plain" }, "stall");
    const h = capturedCancellation(answer.response);
    await expect(h.client.forUser(UID).readStatic({
      sessionId: SID,
      previewId: PID,
      method: "GET",
      path: "/",
      headers: {},
    })).rejects.toMatchObject({ status: 504, code: "upstream_timeout" });
    expect(h.signal()?.aborted).toBe(true);
    expect(answer.cancels()).toBeGreaterThan(0);
  });

  it("uses the same captured signal for JSON redirect, declared-oversize, and stalled-body errors", async () => {
    for (const answer of [
      brokenCancelResponse(302, { location: "http://169.254.169.254/latest" }),
      brokenCancelResponse(200, {
        "content-type": "application/json",
        "content-length": String(1024 * 1024 + 1),
      }),
      brokenCancelResponse(200, { "content-type": "application/json" }, "stall"),
    ]) {
      const h = capturedCancellation(answer.response);
      await expect(h.client.forUser(UID).list(SID)).rejects.toMatchObject({
        status: 503,
        code: "preview_unavailable",
      });
      expect(h.signal()?.aborted).toBe(true);
    }
  });
});
