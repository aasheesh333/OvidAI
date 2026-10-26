import { describe, expect, it } from "vitest";

import type { PreviewBinding } from "./studioPreviewTickets.js";
import {
  PREVIEW_HTTP_IDLE_TIMEOUT_MS,
  PREVIEW_HTTP_MAX_BYTES,
  PREVIEW_WS_ABSOLUTE_TTL_MS,
  PREVIEW_WS_IDLE_TTL_MS,
  PREVIEW_WS_MAX_FRAME_BYTES,
  PREVIEW_WS_MAX_FRAMES_PER_WINDOW,
  PREVIEW_WS_RATE_WINDOW_MS,
  PreviewProxyError,
  authorizePreviewHmrUpgrade,
  buildPreviewUpstreamHeaders,
  buildPreviewWebSocketHeaders,
  createPreviewCsp,
  createPreviewResponseHeaders,
  createPreviewWebSocketGuard,
  normalizePreviewPath,
  proxyPreviewHttpRequest,
  reconstructPreviewUpstream,
  type LivePreviewRegistration,
} from "./previewOrigin.js";

const NOW = new Date("2026-10-24T12:00:00.000Z");
const BINDING: PreviewBinding = {
  userId: "user-1",
  sessionId: "session-1",
  previewId: "preview-1",
  generation: 7,
};
const DEV_CSP = createPreviewCsp({
  kind: "dev_server",
  webOrigin: "https://web.example.test",
  previewOrigin: "https://preview.example.test",
});

function live(
  overrides: Partial<LivePreviewRegistration> & Record<string, unknown> = {},
): LivePreviewRegistration {
  return {
    id: BINDING.previewId,
    userId: BINDING.userId,
    sessionId: BINDING.sessionId,
    generation: BINDING.generation,
    kind: "dev_server",
    status: "running",
    bindHost: "127.0.0.1",
    port: 23_456,
    expiresAt: "2026-10-24T13:00:00.000Z",
    lastAccessAt: null,
    ...overrides,
  };
}

/**
 * Stateful registration fixture for the DEDICATED boolean access-touch port.
 * True means a real lastAccessAt-only write; false means stale/denied OR a
 * throttled no-write. Every authorized call therefore needs a following read.
 * The opt-in legacy mode reproduces the real former defect: an access write
 * increments generation and invalidates the cookie.
 */
function registrationAccess(
  initial: LivePreviewRegistration = live(),
  behavior: { legacyIncrementingUpdate?: boolean } = {},
) {
  let record = initial;
  let nowMs = NOW.getTime();
  let writes = 0;
  const reads: Array<{ previewId: string; generation: number }> = [];
  const touches: Array<{ id: string; generation: number }> = [];
  const touchResults: boolean[] = [];
  const expiresAtMs = () => record.expiresAt instanceof Date
    ? record.expiresAt.getTime()
    : Date.parse(record.expiresAt);

  return {
    reads,
    touches,
    touchResults,
    get record() { return record; },
    get writes() { return writes; },
    now: () => new Date(nowMs),
    setRecord(next: LivePreviewRegistration) { record = next; },
    advance(ms: number) { nowMs += ms; },
    async getLiveRegistration(previewId: string, generation: number) {
      reads.push({ previewId, generation });
      return record.id === previewId && record.generation === generation
        ? record
        : null;
    },
    async touch({ id, generation, now }: { id: string; generation: number; now: Date }) {
      touches.push({ id, generation });
      const touchAtMs = now.getTime();
      if (
        record.id !== id ||
        record.generation !== generation ||
        record.status !== "running" ||
        expiresAtMs() <= touchAtMs
      ) {
        touchResults.push(false);
        return false;
      }
      const lastAccessMs = Date.parse(record.lastAccessAt ?? "");
      if (Number.isFinite(lastAccessMs) && touchAtMs - lastAccessMs < 1_000) {
        // The DB boolean is false for a throttled no-write, not a denial. The
        // resolver must still re-read this record before granting access.
        touchResults.push(false);
        return false;
      }
      record = live({
        ...record,
        // Dedicated touch preserves generation. Legacy mode deliberately
        // models the incrementing-update incompatibility from review R2-1.
        generation: behavior.legacyIncrementingUpdate === true
          ? record.generation + 1
          : record.generation,
        lastAccessAt: now.toISOString(),
      });
      writes += 1;
      touchResults.push(true);
      return true;
    },
  };
}

function streamResponse(chunks: Uint8Array[], headers: HeadersInit = {}): Response {
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        for (const chunk of chunks) controller.enqueue(chunk);
        controller.close();
      },
    }),
    { status: 200, headers },
  );
}

describe("dedicated preview CSP and response policy", () => {
  it("locks static content to self style/image/font with no active content", () => {
    const staticCsp = createPreviewCsp({
      kind: "static",
      webOrigin: "https://web.example.test",
      previewOrigin: "https://preview.example.test",
    });
    expect(staticCsp).toContain("default-src 'none'");
    expect(staticCsp).toBe(
      "default-src 'none'; script-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors https://web.example.test",
    );
    expect(staticCsp).not.toContain("unsafe-");
    expect(staticCsp).not.toContain("https://api.ovidsi.com");
  });

  it("allows only self dev assets and same-preview HMR, with exact Web framing", () => {
    expect(DEV_CSP).toBe(
      "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self' wss://preview.example.test; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors https://web.example.test",
    );
    expect(DEV_CSP).not.toContain("unsafe-");
    expect(DEV_CSP).not.toContain("data:");
    expect(DEV_CSP).not.toContain("https://api.ovidsi.com");
  });

  it.each([
    "*",
    "https://web.example.test/path",
    "https://user:pass@web.example.test",
    "https://web.example.test/?query=1",
    "javascript:alert(1)",
  ])("rejects a non-origin or unsafe configured origin: %s", (origin) => {
    expect(() => createPreviewCsp({
      kind: "dev_server",
      webOrigin: origin,
      previewOrigin: "https://preview.example.test",
    })).toThrow();
  });

  it("forces private no-store and strips upstream cookies and redirect policy", () => {
    const headers = createPreviewResponseHeaders(new Headers({
      "content-type": "text/html",
      "cache-control": "public, max-age=31536000",
      "set-cookie": "ovid_session=secret",
      location: "https://evil.example.test",
      "x-ovid-internal-token": "secret",
      etag: '"version-1"',
    }), DEV_CSP);
    expect(headers).toMatchObject({
      "content-type": "text/html",
      "cache-control": "private, no-store",
      pragma: "no-cache",
      "content-security-policy": DEV_CSP,
      "x-content-type-options": "nosniff",
      etag: '"version-1"',
    });
    expect(headers).not.toHaveProperty("set-cookie");
    expect(headers).not.toHaveProperty("location");
    expect(headers).not.toHaveProperty("x-ovid-internal-token");
  });
});

describe("registered preview upstream reconstruction and paths", () => {
  it("uses only the configured worker host and live registered port/generation", () => {
    const registration = live({
      configuredWorkerHost: "attacker.invalid",
      host: "169.254.169.254",
      url: "http://169.254.169.254/latest/meta-data",
      upstream: "http://attacker.invalid:9999",
    });
    expect(reconstructPreviewUpstream({
      configuredWorkerHost: "worker.internal",
      registration,
      binding: BINDING,
      now: NOW,
    })).toEqual({
      origin: "http://worker.internal:23456",
      generation: 7,
    });
  });

  it.each([
    ["wrong user", live({ userId: "other-user" })],
    ["wrong session", live({ sessionId: "other-session" })],
    ["wrong preview", live({ id: "other-preview" })],
    ["stale generation", live({ generation: 6 })],
    ["starting", live({ status: "starting" })],
    ["stopped", live({ status: "stopped" })],
    ["expired status", live({ status: "expired" })],
    ["expired time", live({ expiresAt: NOW.toISOString() })],
    ["public bind", live({ bindHost: "8.8.8.8" })],
    ["wildcard bind", live({ bindHost: "0.0.0.0" })],
    ["hostname bind", live({ bindHost: "metadata.internal" })],
    ["low port", live({ port: 19_999 })],
    ["high port", live({ port: 30_000 })],
    ["fractional port", live({ port: 23_456.5 })],
    ["zero generation", live({ generation: 0 })],
  ])("denies %s before selecting an upstream", (_name, registration) => {
    expect(reconstructPreviewUpstream({
      configuredWorkerHost: "worker.internal",
      registration,
      binding: BINDING,
      now: NOW,
    })).toBeNull();
  });

  it.each([
    "worker.internal/path",
    "http://worker.internal",
    "user:pass@worker.internal",
    "worker.internal:23456",
    "worker internal",
  ])("fails closed for an invalid configured worker host: %s", (configuredWorkerHost) => {
    expect(reconstructPreviewUpstream({
      configuredWorkerHost,
      registration: live(),
      binding: BINDING,
      now: NOW,
    })).toBeNull();
  });

  it.each([
    ["/", "/"],
    ["/assets/index.js", "/assets/index.js"],
    ["/a//b/", "/a/b/"],
    ["/@vite/client", "/@vite/client"],
    ["/assets/%E2%9C%93.js?raw", "/assets/%E2%9C%93.js?raw"],
    ["/assets/%3F.js", "/assets/%3F.js"],
    ["/safe?next=https://evil.example.test", "/safe?next=https://evil.example.test"],
    ["/assets/../secret", null],
    ["/assets/%2e%2e/secret", null],
    ["/%252e%252e/secret", null],
    ["/%2f%2fevil.example.test/x", null],
    ["//evil.example.test/x", null],
    ["http://evil.example.test/x", null],
    ["/assets/%5c..%5csecret", null],
    ["/assets/%00secret", null],
    ["/assets/#fragment", null],
    ["/assets/%", null],
    ["/\ud800", null],
  ])("normalizes or rejects decoded path %s", (input, expected) => {
    expect(normalizePreviewPath(input)).toBe(expected);
  });

  it("forwards only explicit safe request headers", () => {
    expect(buildPreviewUpstreamHeaders({
      accept: "text/html",
      "accept-language": "en",
      range: "bytes=0-99",
      "if-none-match": '"version-1"',
      authorization: "Bearer ovid-secret",
      cookie: "ovid_session=secret; __Host-ovid_preview=secret",
      host: "169.254.169.254",
      forwarded: "for=127.0.0.1;host=evil",
      "x-forwarded-host": "evil.example.test",
      "x-forwarded-port": "80",
      "x-ovid-internal-token": "secret",
      referer: "https://preview.example.test/exchange?ticket=secret",
      "user-agent": "private-client",
    })).toEqual({
      accept: "text/html",
      "accept-language": "en",
      range: "bytes=0-99",
      "if-none-match": '"version-1"',
    });
  });
});

describe("bounded registered HTTP proxy primitive", () => {
  function harness(
    response: Response | (() => Promise<Response> | Response),
    behavior: { legacyIncrementingUpdate?: boolean } = {},
  ) {
    const calls: Array<{ url: string; init?: RequestInit }> = [];
    const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(input), init });
      // A Response body can be consumed once; the fixture must hand each
      // request its own clone (the template itself is never consumed).
      return typeof response === "function" ? response() : response.clone();
    }) as typeof fetch;
    const access = registrationAccess(live(), behavior);
    return {
      calls,
      access,
      lookups: access.reads,
      config: {
        configuredWorkerHost: "worker.internal",
        webOrigin: "https://web.example.test",
        previewOrigin: "https://preview.example.test",
        now: access.now,
        getLiveRegistration: access.getLiveRegistration,
        touch: access.touch,
        fetch: fetchImpl,
      },
    };
  }

  it("pins host/port, ignores client routing headers, and relays no Ovid credentials", async () => {
    const h = harness(new Response("preview html", {
      status: 200,
      headers: {
        "content-type": "text/html",
        "set-cookie": "preview_session=must-not-cross",
        "cache-control": "public, max-age=9999",
      },
    }));
    const request = {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {
        accept: "text/html",
        authorization: "Bearer ovid-secret",
        cookie: "ovid_session=secret",
        host: "169.254.169.254",
        "x-forwarded-host": "evil.example.test",
        "x-forwarded-port": "80",
        "x-forwarded-proto": "http",
        "x-ovid-internal-token": "secret",
      },
    };
    const result = await proxyPreviewHttpRequest(h.config, {
      ...request,
      url: "http://169.254.169.254/latest",
      port: 80,
      upstream: "http://evil.example.test",
    } as typeof request);
    expect(h.calls).toHaveLength(1);
    expect(h.calls[0]?.url).toBe("http://worker.internal:23456/");
    expect(h.calls[0]?.init?.method).toBe("GET");
    expect(h.calls[0]?.init?.redirect).toBe("manual");
    expect(h.calls[0]?.init?.body).toBeUndefined();
    expect(Object.fromEntries(new Headers(h.calls[0]?.init?.headers).entries())).toEqual({
      accept: "text/html",
    });
    expect(h.lookups).toEqual([
      { previewId: BINDING.previewId, generation: BINDING.generation },
      { previewId: BINDING.previewId, generation: BINDING.generation },
    ]);
    expect(result.status).toBe(200);
    expect(Buffer.from(result.body).toString()).toBe("preview html");
    expect(result.headers).toMatchObject({
      "cache-control": "private, no-store",
      "content-security-policy": DEV_CSP,
      "content-length": "12",
    });
    expect(result.headers).not.toHaveProperty("set-cookie");
  });

  // UNEXECUTED regression under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it("maps boolean touch results through post-touch reads while the original cookie remains valid", async () => {
    const h = harness(new Response("ok"));
    const before = h.access.record;
    const request = {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    };
    await proxyPreviewHttpRequest(h.config, request);
    expect(h.access.touches).toEqual([
      { id: BINDING.previewId, generation: BINDING.generation },
    ]);
    expect(h.access.touchResults).toEqual([true]);
    expect(h.access.writes).toBe(1);
    expect(h.access.record).toEqual({
      ...before,
      lastAccessAt: "2026-10-24T12:00:00.000Z",
    });
    expect(h.access.record.generation).toBe(BINDING.generation);
    expect(h.access.reads).toHaveLength(2);

    // False here is the throttle verdict, not denial. The same original cookie
    // remains authorized and MUST perform a second authoritative read.
    await proxyPreviewHttpRequest(h.config, request);
    expect(h.access.touches).toHaveLength(2);
    expect(h.access.touchResults).toEqual([true, false]);
    expect(h.access.writes).toBe(1);
    expect(h.access.reads).toHaveLength(4);
    h.access.advance(1_000);
    await proxyPreviewHttpRequest(h.config, request);
    expect(h.access.touches).toHaveLength(3);
    expect(h.access.touchResults).toEqual([true, false, true]);
    expect(h.access.writes).toBe(2);
    expect(h.access.reads).toHaveLength(6);
    expect(h.access.record).toEqual({
      ...before,
      lastAccessAt: "2026-10-24T12:00:01.000Z",
    });
    expect(h.access.record.generation).toBe(BINDING.generation);
    expect(h.calls).toHaveLength(3);
  });

  // UNEXECUTED regression under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it.each([
    ["stopped", live({ status: "stopped" })],
    ["expired", live({ expiresAt: NOW.toISOString() })],
  ])("does not touch a %s registration denied before content access", async (_name, registration) => {
    const h = harness(new Response("must not be reached"));
    h.access.setRecord(registration);
    await expect(proxyPreviewHttpRequest(h.config, {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    })).rejects.toMatchObject({ code: "not_found", status: 404 });
    expect(h.access.touches).toEqual([]);
    expect(h.access.writes).toBe(0);
    expect(h.calls).toEqual([]);
  });

  it.each(["POST", "PUT", "DELETE", "PATCH", "OPTIONS"])("denies %s before any lookup or network", async (method) => {
    const h = harness(new Response("must not be reached"));
    const promise = proxyPreviewHttpRequest(h.config, {
      binding: BINDING,
      method,
      path: "/",
      headers: {},
    });
    await expect(promise).rejects.toBeInstanceOf(PreviewProxyError);
    await expect(promise).rejects.toMatchObject({ code: "method_not_allowed", status: 405 });
    expect(h.lookups).toEqual([]);
    expect(h.access.touches).toEqual([]);
    expect(h.calls).toEqual([]);
  });

  it("denies an encoded traversal before any lookup or network", async () => {
    const h = harness(new Response("must not be reached"));
    await expect(proxyPreviewHttpRequest(h.config, {
      binding: BINDING,
      method: "GET",
      path: "/%2e%2e/private",
      headers: {},
    })).rejects.toMatchObject({ code: "bad_path", status: 400 });
    expect(h.lookups).toEqual([]);
    expect(h.access.touches).toEqual([]);
    expect(h.calls).toEqual([]);
  });

  it("revalidates the live generation on every request and fails closed when it changes", async () => {
    let registration = live();
    const h = harness(new Response("ok"));
    h.config.getLiveRegistration = async () => registration;
    await proxyPreviewHttpRequest(h.config, {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    });
    registration = live({ generation: 8, port: 28_888 });
    await expect(proxyPreviewHttpRequest(h.config, {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    })).rejects.toMatchObject({ code: "not_found", status: 404 });
    expect(h.access.touches).toHaveLength(1);
    expect(h.access.writes).toBe(1);
    expect(h.calls).toHaveLength(1);
  });

  // UNEXECUTED regression under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it("does not write when the generation changes between registration read and touch", async () => {
    const h = harness(new Response("must not be reached"));
    const grantedRead = h.access.record;
    const read = h.config.getLiveRegistration;
    let reads = 0;
    h.config.getLiveRegistration = async (previewId, generation) => {
      reads += 1;
      if (reads === 1) {
        await read(previewId, generation);
        h.access.setRecord(live({ generation: 8 }));
        return grantedRead;
      }
      return read(previewId, generation);
    };
    await expect(proxyPreviewHttpRequest(h.config, {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    })).rejects.toMatchObject({ code: "not_found", status: 404 });
    expect(h.access.touches).toHaveLength(1);
    expect(h.access.touchResults).toEqual([false]);
    expect(h.access.reads).toHaveLength(2);
    expect(h.access.writes).toBe(0);
    expect(h.access.record.lastAccessAt).toBeNull();
    expect(h.calls).toEqual([]);
  });

  // UNEXECUTED regression under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it("models the former incrementing-update defect and rejects its changed generation", async () => {
    const h = harness(new Response("must not be reached"), {
      legacyIncrementingUpdate: true,
    });
    const request = {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    };
    await expect(proxyPreviewHttpRequest(h.config, request)).rejects.toMatchObject({
      code: "not_found",
      status: 404,
    });
    expect(h.access.touchResults).toEqual([true]);
    expect(h.access.writes).toBe(1);
    expect(h.access.record.lastAccessAt).toBe("2026-10-24T12:00:00.000Z");
    expect(h.access.record.generation).toBe(BINDING.generation + 1);
    expect(h.calls).toEqual([]);

    // The legacy write has invalidated the original cookie on the next read;
    // it cannot be silently rebound to the incremented content generation.
    await expect(proxyPreviewHttpRequest(h.config, request)).rejects.toMatchObject({
      code: "not_found",
      status: 404,
    });
    expect(h.access.touches).toHaveLength(1);
    expect(h.calls).toEqual([]);
  });

  // UNEXECUTED regression under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it("rejects a record-shaped adapter answer instead of casting it from the boolean port", async () => {
    const h = harness(new Response("must not be reached"));
    // Deliberately model an untyped/mistaken composition adapter at runtime.
    const malformedConfig = {
      ...h.config,
      touch: async () => h.access.record,
    } as unknown as typeof h.config;
    await expect(proxyPreviewHttpRequest(malformedConfig, {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    })).rejects.toMatchObject({ code: "registration_unavailable", status: 503 });
    expect(h.access.reads).toHaveLength(1);
    expect(h.access.writes).toBe(0);
    expect(h.calls).toEqual([]);
  });

  // UNEXECUTED regression under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it.each([
    ["stopped", live({ status: "stopped", lastAccessAt: NOW.toISOString() })],
    ["expired", live({ expiresAt: NOW.toISOString(), lastAccessAt: NOW.toISOString() })],
  ])("revalidates %s status after a throttled false touch before fetch", async (_name, replacement) => {
    const h = harness(new Response("must not be reached"));
    h.access.setRecord(live({ lastAccessAt: NOW.toISOString() }));
    const read = h.config.getLiveRegistration;
    let reads = 0;
    h.config.getLiveRegistration = async (previewId, generation) => {
      reads += 1;
      if (reads === 2) h.access.setRecord(replacement);
      return read(previewId, generation);
    };
    await expect(proxyPreviewHttpRequest(h.config, {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    })).rejects.toMatchObject({ code: "not_found", status: 404 });
    expect(h.access.touchResults).toEqual([false]);
    expect(h.access.reads).toHaveLength(2);
    expect(h.access.writes).toBe(0);
    expect(h.calls).toEqual([]);
  });

  it("does not follow or relay an upstream redirect", async () => {
    const h = harness(new Response("redirect-secret-body", {
      status: 302,
      headers: { location: "http://169.254.169.254/latest/meta-data" },
    }));
    const promise = proxyPreviewHttpRequest(h.config, {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    });
    await expect(promise).rejects.toMatchObject({ code: "redirect_denied", status: 502 });
    await expect(promise).rejects.not.toMatchObject({ message: expect.stringContaining("redirect-secret-body") });
    expect(h.calls).toHaveLength(1);
    expect(h.calls[0]?.init?.redirect).toBe("manual");
  });

  it("does not let redirect body cleanup defeat the bounded denial", async () => {
    const response = new Response(new ReadableStream<Uint8Array>({
      cancel() {
        return new Promise<void>(() => {});
      },
    }), {
      status: 302,
      headers: { location: "http://169.254.169.254/latest" },
    });
    const h = harness(response);
    const outcome = await Promise.race([
      proxyPreviewHttpRequest({ ...h.config, idleTimeoutMs: 5 }, {
        binding: BINDING,
        method: "GET",
        path: "/",
        headers: {},
      }).catch((error: unknown) => error),
      new Promise<string>((resolve) => setTimeout(() => resolve("still-pending"), 25)),
    ]);
    expect(outcome).toMatchObject({ code: "redirect_denied", status: 502 });
  });

  it("does not wait forever to discard a HEAD response body", async () => {
    const response = new Response(new ReadableStream<Uint8Array>({
      cancel() {
        return new Promise<void>(() => {});
      },
    }), {
      status: 200,
      headers: { "content-length": "5" },
    });
    const h = harness(response);
    const outcome = await Promise.race([
      proxyPreviewHttpRequest({ ...h.config, idleTimeoutMs: 5 }, {
        binding: BINDING,
        method: "HEAD",
        path: "/",
        headers: {},
      }).catch((error: unknown) => error),
      new Promise<string>((resolve) => setTimeout(() => resolve("still-pending"), 25)),
    ]);
    expect(outcome).toMatchObject({
      status: 200,
      body: Buffer.alloc(0),
      headers: expect.objectContaining({ "content-length": "5" }),
    });
  });

  it("accepts exactly 16 MiB and counts streamed bytes instead of trusting content-length", async () => {
    expect(PREVIEW_HTTP_MAX_BYTES).toBe(16 * 1024 * 1024);
    const exact = Buffer.alloc(PREVIEW_HTTP_MAX_BYTES, 1);
    const accepted = harness(new Response(exact));
    const result = await proxyPreviewHttpRequest(accepted.config, {
      binding: BINDING,
      method: "GET",
      path: "/large",
      headers: {},
    });
    expect(result.body).toHaveLength(PREVIEW_HTTP_MAX_BYTES);
    expect(result.headers["content-length"]).toBe(String(PREVIEW_HTTP_MAX_BYTES));

    const oversized = harness(streamResponse([
      Buffer.alloc(8 * 1024 * 1024),
      Buffer.alloc(8 * 1024 * 1024),
      Buffer.from([1]),
    ], { "content-length": "1" }));
    await expect(proxyPreviewHttpRequest(oversized.config, {
      binding: BINDING,
      method: "GET",
      path: "/large",
      headers: {},
    })).rejects.toMatchObject({ code: "response_too_large", status: 413 });
  });

  it("enforces a real idle deadline even when a response stalls between chunks", async () => {
    expect(PREVIEW_HTTP_IDLE_TIMEOUT_MS).toBe(15_000);
    const stalled = new Response(new ReadableStream<Uint8Array>({
      pull(controller) {
        if (controller.desiredSize !== null && !signalled) {
          signalled = true;
          controller.enqueue(Buffer.from("first"));
        }
        // Later reads remain pending forever.
      },
    }));
    let signalled = false;
    const h = harness(stalled);
    const promise = proxyPreviewHttpRequest({ ...h.config, idleTimeoutMs: 5 }, {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    });
    await expect(promise).rejects.toMatchObject({ code: "upstream_timeout", status: 504 });
  });

  it("aborts and times out when upstream headers never arrive", async () => {
    let signal: AbortSignal | null | undefined;
    const h = harness(() => new Promise<Response>(() => {}));
    const originalFetch = h.config.fetch;
    h.config.fetch = ((input: string | URL | Request, init?: RequestInit) => {
      signal = init?.signal;
      return originalFetch(input, init);
    }) as typeof fetch;
    await expect(proxyPreviewHttpRequest({ ...h.config, idleTimeoutMs: 5 }, {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    })).rejects.toMatchObject({ code: "upstream_timeout", status: 504 });
    expect(signal?.aborted).toBe(true);
  });

  it("does not expose raw upstream failures", async () => {
    const h = harness(() => {
      throw new Error("dial secret-credential-canary");
    });
    const promise = proxyPreviewHttpRequest(h.config, {
      binding: BINDING,
      method: "GET",
      path: "/",
      headers: {},
    });
    await expect(promise).rejects.toMatchObject({
      code: "upstream_unavailable",
      message: "Preview upstream is unavailable.",
    });
    await expect(promise).rejects.not.toMatchObject({
      message: expect.stringContaining("secret-credential-canary"),
    });
  });
});

describe("same-preview HMR authorization and standalone socket limits", () => {
  function upgradeConfig(registration: LivePreviewRegistration = live()) {
    const access = registrationAccess(registration);
    return {
      configuredWorkerHost: "worker.internal",
      now: access.now,
      getLiveRegistration: access.getLiveRegistration,
      touch: access.touch,
      access,
    };
  }

  it("authorizes only a live same-preview HMR upgrade and strips credentials", async () => {
    const grant = await authorizePreviewHmrUpgrade(upgradeConfig(), {
      binding: BINDING,
      method: "GET",
      path: "/__vite_hmr",
      headers: {
        connection: "keep-alive, Upgrade",
        upgrade: "websocket",
        "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
        "sec-websocket-version": "13",
        "sec-websocket-protocol": "vite-hmr",
        authorization: "Bearer secret",
        cookie: "ovid_session=secret",
        origin: "https://evil.example.test",
        host: "169.254.169.254",
        "x-forwarded-host": "evil.example.test",
      },
    });
    expect(grant.upstream).toEqual({
      origin: "http://worker.internal:23456",
      generation: 7,
    });
    expect(grant.path).toBe("/__vite_hmr");
    expect(grant.headers).toEqual({
      "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
      "sec-websocket-version": "13",
      "sec-websocket-protocol": "vite-hmr",
    });
  });

  // UNEXECUTED regression under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it("re-reads after boolean HMR touch results, including throttled false", async () => {
    const config = upgradeConfig();
    const before = config.access.record;
    const request = {
      binding: BINDING,
      method: "GET",
      path: "/__vite_hmr",
      headers: {
        connection: "Upgrade",
        upgrade: "websocket",
        "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
        "sec-websocket-version": "13",
        "sec-websocket-protocol": "vite-hmr",
      },
    };
    await authorizePreviewHmrUpgrade(config, request);
    expect(config.access.touchResults).toEqual([true]);
    expect(config.access.writes).toBe(1);
    expect(config.access.reads).toHaveLength(2);
    expect(config.access.record).toEqual({
      ...before,
      lastAccessAt: "2026-10-24T12:00:00.000Z",
    });

    await authorizePreviewHmrUpgrade(config, request);
    expect(config.access.touches).toHaveLength(2);
    expect(config.access.touchResults).toEqual([true, false]);
    expect(config.access.writes).toBe(1);
    expect(config.access.reads).toHaveLength(4);
    config.access.advance(1_000);
    await authorizePreviewHmrUpgrade(config, request);
    expect(config.access.touches).toHaveLength(3);
    expect(config.access.touchResults).toEqual([true, false, true]);
    expect(config.access.writes).toBe(2);
    expect(config.access.reads).toHaveLength(6);
    expect(config.access.record).toEqual({
      ...before,
      lastAccessAt: "2026-10-24T12:00:01.000Z",
    });
    expect(config.access.record.generation).toBe(BINDING.generation);
  });

  // UNEXECUTED regression under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it("always denies static-preview HMR before touching or granting an upstream", async () => {
    const config = upgradeConfig(live({ kind: "static" }));
    await expect(authorizePreviewHmrUpgrade(config, {
      binding: BINDING,
      method: "GET",
      path: "/__vite_hmr",
      headers: {
        connection: "Upgrade",
        upgrade: "websocket",
        "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
        "sec-websocket-version": "13",
        "sec-websocket-protocol": "vite-hmr",
      },
    })).rejects.toMatchObject({ code: "hmr_denied", status: 403 });
    expect(config.access.touches).toEqual([]);
    expect(config.access.writes).toBe(0);
  });

  // UNEXECUTED regression under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it("revalidates dev_server kind after a throttled false touch before granting HMR", async () => {
    const config = upgradeConfig(live({ lastAccessAt: NOW.toISOString() }));
    const read = config.getLiveRegistration;
    let reads = 0;
    config.getLiveRegistration = async (previewId, generation) => {
      reads += 1;
      if (reads === 2) {
        config.access.setRecord(live({ kind: "static", lastAccessAt: NOW.toISOString() }));
      }
      return read(previewId, generation);
    };
    await expect(authorizePreviewHmrUpgrade(config, {
      binding: BINDING,
      method: "GET",
      path: "/__vite_hmr",
      headers: {
        connection: "Upgrade",
        upgrade: "websocket",
        "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
        "sec-websocket-version": "13",
        "sec-websocket-protocol": "vite-hmr",
      },
    })).rejects.toMatchObject({ code: "hmr_denied", status: 403 });
    expect(config.access.touchResults).toEqual([false]);
    expect(config.access.reads).toHaveLength(2);
    expect(config.access.writes).toBe(0);
  });

  it.each([
    ["non-HMR path", { path: "/ordinary-socket" }, "hmr_denied"],
    ["other preview", { binding: { ...BINDING, previewId: "other-preview" } }, "not_found"],
    ["missing upgrade", { headers: { connection: "Upgrade", "sec-websocket-protocol": "vite-hmr" } }, "hmr_denied"],
    ["foreign protocol", { headers: { connection: "Upgrade", upgrade: "websocket", "sec-websocket-protocol": "other-protocol" } }, "hmr_denied"],
  ])("denies %s", async (_name, override, code) => {
    const input = {
      binding: BINDING,
      method: "GET",
      path: "/__vite_hmr",
      headers: {
        connection: "Upgrade",
        upgrade: "websocket",
        "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
        "sec-websocket-version": "13",
        "sec-websocket-protocol": "vite-hmr",
      },
      ...override,
    };
    const config = upgradeConfig();
    await expect(authorizePreviewHmrUpgrade(config, input)).rejects.toMatchObject({ code });
    expect(config.access.touches).toEqual([]);
    expect(config.access.writes).toBe(0);
  });

  it("has an independent WebSocket header allowlist", () => {
    // Compression is not negotiated: frame limits must apply to the exact
    // bytes relayed, without a decompressed-size side channel.
    expect(buildPreviewWebSocketHeaders({
      "sec-websocket-key": "key",
      "sec-websocket-version": "13",
      "sec-websocket-protocol": "vite-hmr",
      "sec-websocket-extensions": "permessage-deflate",
      authorization: "Bearer secret",
      cookie: "secret",
      "x-forwarded-for": "127.0.0.1",
    })).toEqual({
      "sec-websocket-key": "key",
      "sec-websocket-version": "13",
      "sec-websocket-protocol": "vite-hmr",
    });
  });

  it("caps every WebSocket frame at 256 KiB", () => {
    expect(PREVIEW_WS_MAX_FRAME_BYTES).toBe(256 * 1024);
    const guard = createPreviewWebSocketGuard();
    expect(guard.acceptFrame(PREVIEW_WS_MAX_FRAME_BYTES)).toEqual({ allowed: true });
    expect(guard.acceptFrame(PREVIEW_WS_MAX_FRAME_BYTES + 1)).toMatchObject({
      allowed: false,
      reason: "frame_too_large",
    });
  });

  it("rate limits frames within a real time window", () => {
    let now = 0;
    const guard = createPreviewWebSocketGuard({
      now: () => now,
      maxFramesPerWindow: 2,
      windowMs: 1_000,
    });
    expect(guard.acceptFrame(1)).toEqual({ allowed: true });
    expect(guard.acceptFrame(1)).toEqual({ allowed: true });
    expect(guard.acceptFrame(1)).toMatchObject({
      allowed: false,
      reason: "rate_limited",
      retryAfterSeconds: 1,
    });
    now = 1_000;
    expect(guard.acceptFrame(1)).toEqual({ allowed: true });
  });

  it("enforces idle and absolute TTLs without letting denied frames slide them", () => {
    expect(PREVIEW_WS_MAX_FRAMES_PER_WINDOW).toBeGreaterThan(0);
    expect(PREVIEW_WS_RATE_WINDOW_MS).toBe(60_000);
    expect(PREVIEW_WS_IDLE_TTL_MS).toBe(15 * 60_000);
    expect(PREVIEW_WS_ABSOLUTE_TTL_MS).toBe(60 * 60_000);

    let now = 0;
    const guard = createPreviewWebSocketGuard({
      now: () => now,
      maxFramesPerWindow: 1,
      windowMs: 60_000,
      idleTtlMs: 100,
      absoluteTtlMs: 250,
    });
    expect(guard.acceptFrame(1)).toEqual({ allowed: true });
    now = 50;
    expect(guard.acceptFrame(1)).toMatchObject({ allowed: false, reason: "rate_limited" });
    now = 101;
    expect(guard.acceptFrame(1)).toMatchObject({ allowed: false, reason: "idle_expired" });

    now = 0;
    const absolute = createPreviewWebSocketGuard({
      now: () => now,
      idleTtlMs: 1_000,
      absoluteTtlMs: 250,
    });
    expect(absolute.acceptFrame(1)).toEqual({ allowed: true });
    now = 200;
    expect(absolute.acceptFrame(1)).toEqual({ allowed: true });
    now = 250;
    expect(absolute.acceptFrame(1)).toMatchObject({ allowed: false, reason: "absolute_expired" });
  });

  // UNEXECUTED regression under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it("latches idle and absolute expiry across backward and recovered clock readings", () => {
    let now = 0;
    const idle = createPreviewWebSocketGuard({
      now: () => now,
      idleTtlMs: 100,
      absoluteTtlMs: 1_000,
    });
    expect(idle.acceptFrame(1)).toEqual({ allowed: true });
    now = 100;
    expect(idle.acceptFrame(1)).toMatchObject({ allowed: false, reason: "idle_expired" });
    now = -100;
    expect(idle.acceptFrame(1)).toMatchObject({ allowed: false, reason: "idle_expired" });
    now = 0;
    expect(idle.acceptFrame(1)).toMatchObject({ allowed: false, reason: "idle_expired" });

    now = 0;
    const absolute = createPreviewWebSocketGuard({
      now: () => now,
      idleTtlMs: 1_000,
      absoluteTtlMs: 250,
    });
    expect(absolute.acceptFrame(1)).toEqual({ allowed: true });
    now = 250;
    expect(absolute.acceptFrame(1)).toMatchObject({ allowed: false, reason: "absolute_expired" });
    now = -1;
    expect(absolute.acceptFrame(1)).toMatchObject({ allowed: false, reason: "absolute_expired" });
    now = 1;
    expect(absolute.acceptFrame(1)).toMatchObject({ allowed: false, reason: "absolute_expired" });
  });

  // UNEXECUTED regression under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it("fails closed and latches when the clock moves backward before a timeout", () => {
    let now = 100;
    const guard = createPreviewWebSocketGuard({
      now: () => now,
      idleTtlMs: 1_000,
      absoluteTtlMs: 2_000,
    });
    expect(guard.acceptFrame(1)).toEqual({ allowed: true });
    now = 99;
    expect(guard.acceptFrame(1)).toMatchObject({
      allowed: false,
      reason: "absolute_expired",
    });
    now = 100;
    expect(guard.acceptFrame(1)).toMatchObject({
      allowed: false,
      reason: "absolute_expired",
    });
  });
});
