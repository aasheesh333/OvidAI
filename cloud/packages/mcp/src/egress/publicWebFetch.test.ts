import { gzipSync } from "node:zlib";
import { describe, expect, it, vi } from "vitest";

import type { PinnedDispatchRequest } from "./providerEgress.js";
import {
  createPublicWebFetch,
  PUBLIC_WEB_FETCH_LIMITS,
  PUBLIC_WEB_FETCH_REQUEST,
  PublicWebFetchError,
  type PublicWebDispatcherOptions,
  type PublicWebFetchRequestInit,
} from "./publicWebFetch.js";

const PUBLIC_V4 = "93.184.216.34";
const PUBLIC_V6 = "2606:4700::1111";
const CANARY = "upstream-canary-must-not-escape";

interface Hop {
  options: PublicWebDispatcherOptions;
  input: PinnedDispatchRequest;
}

function wireResponse(patch: Partial<{
  status: number;
  headers: Headers;
  body: ReadableStream<Uint8Array>;
  remoteAddress: string;
  headerBytes: number;
}> = {}) {
  return {
    status: patch.status ?? 200,
    headers: patch.headers ?? new Headers(),
    body: patch.body ?? new Response("ok").body!,
    remoteAddress: patch.remoteAddress ?? PUBLIC_V4,
    ...(patch.headerBytes === undefined ? {} : { headerBytes: patch.headerBytes }),
  };
}

function harness(options: {
  resolver?: (host: string) => Promise<string[]>;
  dispatch?: (input: PinnedDispatchRequest, hop: number) => Promise<ReturnType<typeof wireResponse>>;
  limits?: Partial<typeof PUBLIC_WEB_FETCH_LIMITS>;
} = {}) {
  const hops: Hop[] = [];
  const close = vi.fn(async () => {});
  const fetchImpl = createPublicWebFetch({
    resolver: options.resolver ?? (async () => [PUBLIC_V4]),
    dispatcherFactory: (dispatcherOptions) => {
      const optionsForHop = dispatcherOptions;
      return {
        async dispatch(input) {
          hops.push({ options: optionsForHop, input });
          return options.dispatch === undefined
            ? wireResponse()
            : options.dispatch(input, hops.length);
        },
        close,
      };
    },
    ...(options.limits === undefined ? {} : { limits: options.limits }),
  });
  return { fetchImpl, hops, close };
}

function stream(chunks: readonly Uint8Array[], onCancel?: () => void, holdOpen = false) {
  let index = 0;
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (index < chunks.length) {
        controller.enqueue(chunks[index++]);
        return;
      }
      if (!holdOpen) controller.close();
    },
    cancel: onCancel,
  });
}

const bytes = (value: string): Uint8Array => new TextEncoder().encode(value);

async function failure(pending: Promise<unknown>): Promise<unknown> {
  return pending.then(() => null, (error: unknown) => error);
}

describe("publicWebFetch checked-address current-hop transport", () => {
  it("pins the checked answer when a later resolver answer would rebind to private space", async () => {
    let resolutions = 0;
    const resolver = vi.fn(async () => {
      resolutions++;
      return resolutions === 1 ? [PUBLIC_V4] : ["127.0.0.1"];
    });
    const { fetchImpl, hops } = harness({ resolver });

    const response = await fetchImpl("https://public.test/resource");
    expect(await response.text()).toBe("ok");
    expect(resolver).toHaveBeenCalledTimes(1);
    expect(hops).toHaveLength(1);
    const checked = await new Promise<string[]>((resolve, reject) => {
      hops[0]!.options.lookup("public.test", { all: true }, (error, records) => {
        if (error) reject(error);
        else resolve((records as Array<{ address: string }>).map((record) => record.address));
      });
    });
    expect(checked).toEqual([PUBLIC_V4]);
    expect(hops[0]!.input.url.hostname).toBe("public.test");
  });

  it.each([
    { name: "mixed A/AAAA with private A", answers: [PUBLIC_V6, "10.0.0.8"] },
    { name: "mixed A/AAAA with link-local AAAA", answers: [PUBLIC_V4, "fe80::1"] },
    { name: "mapped loopback", answers: ["::ffff:127.0.0.1"] },
    { name: "mapped metadata", answers: ["::ffff:169.254.169.254"] },
    { name: "malformed answer", answers: ["not-an-address"] },
    { name: "empty answer", answers: [] },
  ])("refuses $name before constructing a dispatcher", async ({ answers }) => {
    const { fetchImpl, hops } = harness({ resolver: async () => answers });
    const error = await failure(fetchImpl("https://public.test/"));
    expect(error).toBeInstanceOf(PublicWebFetchError);
    expect((error as Error).message).toMatch(/^public_fetch_(?:non_public_address|dns_empty)$/);
    expect(hops).toHaveLength(0);
  });

  it("fails closed when DNS rejects and when DNS is aborted", async () => {
    const dnsFailure = harness({ resolver: async () => { throw new Error(CANARY); } });
    const refused = await failure(dnsFailure.fetchImpl("https://public.test/"));
    expect(refused).toMatchObject({ code: "public_fetch_dns_failed" });
    expect((refused as Error).message).not.toContain(CANARY);
    expect(dnsFailure.hops).toHaveLength(0);

    const pendingDns = harness({ resolver: () => new Promise<string[]>(() => {}) });
    const controller = new AbortController();
    const pending = pendingDns.fetchImpl("https://public.test/", { signal: controller.signal });
    controller.abort(new Error(CANARY));
    const aborted = await failure(pending);
    expect(aborted).toMatchObject({ code: "public_fetch_aborted", name: "AbortError" });
    expect((aborted as Error).message).not.toContain(CANARY);
    expect(pendingDns.hops).toHaveLength(0);
  });

  it("does not resolve or dispatch when the caller is already aborted", async () => {
    const resolver = vi.fn(async () => [PUBLIC_V4]);
    const { fetchImpl, hops } = harness({ resolver });
    const controller = new AbortController();
    controller.abort(new Error(CANARY));
    const error = await failure(fetchImpl("https://public.test/", { signal: controller.signal }));
    expect(error).toMatchObject({ code: "public_fetch_aborted" });
    expect((error as Error).message).not.toContain(CANARY);
    expect(resolver).not.toHaveBeenCalled();
    expect(hops).toHaveLength(0);
  });

  it.each([
    "http://public.test/",
    "https://public.test:8443/",
    `https://${CANARY}@public.test/`,
    `https://user:${CANARY}@public.test/`,
    "https://127.0.0.1/",
    "https://[::1]/",
    "https://169.254.169.254/latest/meta-data",
    "https://[fe80::1]/",
    "https://localhost/",
    "https://service.local/",
  ])("rejects a non-public or non-HTTPS current URL without resolution or a socket: %s", async (url) => {
    const resolver = vi.fn(async () => [PUBLIC_V4]);
    const { fetchImpl, hops } = harness({ resolver });
    const error = await failure(fetchImpl(url));
    expect(error).toBeInstanceOf(PublicWebFetchError);
    expect((error as Error).message).not.toContain(CANARY);
    expect(resolver).not.toHaveBeenCalled();
    expect(hops).toHaveLength(0);
  });

  it("rejects caller credentials, writes, and Host overrides without touching DNS", async () => {
    const resolver = vi.fn(async () => [PUBLIC_V4]);
    const { fetchImpl, hops } = harness({ resolver });
    const requests: RequestInit[] = [
      { headers: { authorization: `Bearer ${CANARY}` } },
      { headers: { cookie: `session=${CANARY}` } },
      { headers: { "proxy-authorization": CANARY } },
      { headers: { host: "169.254.169.254" } },
      { method: "POST" },
      { method: "GET", body: CANARY },
      { credentials: "include" },
    ];
    for (const init of requests) {
      const error = await failure(fetchImpl("https://public.test/", init));
      expect(error).toBeInstanceOf(PublicWebFetchError);
      expect((error as Error).message).not.toContain(CANARY);
    }
    expect(resolver).not.toHaveBeenCalled();
    expect(hops).toHaveLength(0);
  });

  it("preserves URL Host/TLS identity on each caller-driven hop with only checked lookup addresses", async () => {
    const { fetchImpl, hops } = harness({
      resolver: async (host) => host === "source.test" ? [PUBLIC_V4] : [PUBLIC_V6],
      dispatch: async (input) => input.url.hostname === "source.test"
        ? wireResponse({ status: 302, headers: new Headers({ location: "https://target.test/final" }) })
        : wireResponse({ remoteAddress: PUBLIC_V6, body: new Response("landed").body! }),
    });

    const first = await fetchImpl("https://source.test/start", {
      headers: { "user-agent": "public-fetch-test" },
    });
    expect(first.status).toBe(302);
    const second = await fetchImpl(new URL(first.headers.get("location")!, first.url).toString(), {
      headers: { "user-agent": "public-fetch-test" },
    });
    expect(await second.text()).toBe("landed");
    expect(hops.map((hop) => hop.options.servername)).toEqual(["source.test", "target.test"]);
    expect(hops.map((hop) => hop.options.origin.hostname)).toEqual(["source.test", "target.test"]);
    expect(hops.map((hop) => hop.input.url.href)).toEqual([
      "https://source.test/start",
      "https://target.test/final",
    ]);
    for (const hop of hops) {
      expect(hop.input.headers.host).toBeUndefined();
      expect(hop.input.headers.authorization).toBeUndefined();
      expect(hop.options.addresses).toEqual(
        hop.options.servername === "source.test" ? [PUBLIC_V4] : [PUBLIC_V6],
      );
      const records = await new Promise<Array<{ address: string }>>((resolve, reject) => {
        hop.options.lookup(hop.options.servername, { all: true }, (error, value) => {
          if (error) reject(error);
          else resolve(value as Array<{ address: string }>);
        });
      });
      expect(records.map((record) => record.address)).toEqual(hop.options.addresses);
    }
  });

  it("accepts an IPv4 socket for a checked mapped public address but rejects a wrong mapped remote", async () => {
    const mappedPublic = "::ffff:93.184.216.34";
    const accepted = harness({ resolver: async () => [mappedPublic] });
    const response = await accepted.fetchImpl("https://public.test/");
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");

    let cancelled = 0;
    const rejected = harness({
      resolver: async () => [mappedPublic],
      dispatch: async () => wireResponse({
        remoteAddress: "::ffff:10.0.0.8",
        body: stream([], () => { cancelled++; }),
      }),
    });
    const error = await failure(rejected.fetchImpl("https://public.test/"));
    expect(error).toMatchObject({ code: "public_fetch_remote_address" });
    expect(cancelled).toBe(1);
    expect(rejected.close).toHaveBeenCalled();
  });

  it("returns Location after discarding a redirect body without advancing or resolving the target", async () => {
    let cancelled = 0;
    const resolver = vi.fn(async () => [PUBLIC_V4]);
    const { fetchImpl, hops, close } = harness({
      resolver,
      dispatch: async () => wireResponse({
        status: 302,
        headers: new Headers({
          location: "https://private.test/collect",
          "x-upstream-canary": CANARY,
        }),
        body: stream([bytes("discard me")], () => { cancelled++; }, true),
      }),
    });

    const response = await fetchImpl("https://public.test/start");
    expect(response.status).toBe(302);
    expect(response.url).toBe("https://public.test/start");
    expect(response.headers.get("location")).toBe("https://private.test/collect");
    expect(response.headers.get("x-upstream-canary")).toBeNull();
    expect(response.body).toBeNull();
    expect(cancelled).toBe(1);
    expect(resolver).toHaveBeenCalledTimes(1);
    expect(resolver).toHaveBeenCalledWith("public.test");
    expect(hops).toHaveLength(1);
    expect(close).toHaveBeenCalledTimes(1);
  });

  it("revalidates only when the caller drives the next hop and refuses its private rebind", async () => {
    let resolutions = 0;
    const resolver = vi.fn(async () => {
      resolutions++;
      return resolutions === 1 ? [PUBLIC_V4] : ["127.0.0.1"];
    });
    const { fetchImpl, hops } = harness({
      resolver,
      dispatch: async () => wireResponse({ status: 302, headers: new Headers({ location: "/next" }) }),
    });
    const first = await fetchImpl("https://public.test/start");
    expect(first.status).toBe(302);
    const error = await failure(fetchImpl(new URL(first.headers.get("location")!, first.url).toString()));
    expect(error).toMatchObject({ code: "public_fetch_non_public_address" });
    expect(resolver).toHaveBeenCalledTimes(2);
    expect(hops).toHaveLength(1);
  });

  it("aborts a pending connect and closes its dispatcher without leaking the abort reason", async () => {
    const controller = new AbortController();
    let markStarted!: () => void;
    const started = new Promise<void>((resolve) => { markStarted = resolve; });
    const { fetchImpl, hops, close } = harness({
      dispatch: (_input) => {
        markStarted();
        return new Promise<ReturnType<typeof wireResponse>>(() => {});
      },
    });
    const pending = fetchImpl("https://public.test/", { signal: controller.signal });
    await started;
    controller.abort(new Error(CANARY));
    const error = await failure(pending);
    expect(error).toMatchObject({ code: "public_fetch_aborted" });
    expect((error as Error).message).not.toContain(CANARY);
    expect(hops).toHaveLength(1);
    expect(close).toHaveBeenCalled();
  });

  it("enforces the headers deadline even when a dispatcher never answers", async () => {
    vi.useFakeTimers();
    try {
      const { fetchImpl, close } = harness({
        dispatch: () => new Promise<ReturnType<typeof wireResponse>>(() => {}),
        limits: { headersMs: 20, totalMs: 500 },
      });
      const pending = failure(fetchImpl("https://public.test/"));
      await vi.advanceTimersByTimeAsync(20);
      expect(await pending).toMatchObject({ code: "public_fetch_headers_timeout" });
      expect(close).toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("enforces the total deadline during DNS", async () => {
    vi.useFakeTimers();
    try {
      const { fetchImpl, hops } = harness({
        resolver: () => new Promise<string[]>(() => {}),
        limits: { totalMs: 20 },
      });
      const pending = failure(fetchImpl("https://public.test/"));
      await vi.advanceTimersByTimeAsync(20);
      expect(await pending).toMatchObject({ code: "public_fetch_total_timeout" });
      expect(hops).toHaveLength(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it.each([
    { kind: "idle", idleMs: 20, totalMs: 500, code: "public_fetch_idle_timeout" },
    { kind: "total", idleMs: 500, totalMs: 20, code: "public_fetch_total_timeout" },
  ])("enforces the $kind deadline while streaming and cancels the source", async ({ idleMs, totalMs, code }) => {
    vi.useFakeTimers();
    try {
      let cancelled = 0;
      const { fetchImpl } = harness({
        dispatch: async () => wireResponse({
          body: stream([new Uint8Array([1])], () => { cancelled++; }, true),
        }),
        limits: { idleMs, totalMs },
      });
      const response = await fetchImpl("https://public.test/");
      const pending = failure(response.text());
      await vi.advanceTimersByTimeAsync(20);
      expect(await pending).toMatchObject({ code });
      expect(cancelled).toBeGreaterThan(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("drops non-2xx statusText, headers, and body canaries and closes the body", async () => {
    let cancelled = 0;
    const { fetchImpl } = harness({
      dispatch: async () => wireResponse({
        status: 503,
        headers: new Headers({ "x-upstream-canary": CANARY }),
        body: stream([bytes(CANARY)], () => { cancelled++; }, true),
      }),
    });
    const response = await fetchImpl("https://public.test/");
    expect(response.status).toBe(503);
    expect(response.statusText).toBe("");
    expect(response.body).toBeNull();
    const exposedHeaders: string[] = [];
    response.headers.forEach((_value, name) => exposedHeaders.push(name));
    expect(exposedHeaders).toEqual([]);
    expect(await response.text()).toBe("");
    expect(cancelled).toBe(1);
  });

  it("discards HEAD and no-body status bodies while retaining safe response metadata", async () => {
    for (const testCase of [{ method: "HEAD", status: 200 }, { method: "GET", status: 204 }]) {
      let cancelled = 0;
      const { fetchImpl } = harness({
        dispatch: async () => wireResponse({
          status: testCase.status,
          headers: new Headers({ "content-type": "text/plain" }),
          body: stream([bytes("must not escape")], () => { cancelled++; }, true),
        }),
      });
      const response = await fetchImpl("https://public.test/", { method: testCase.method });
      expect(response.body).toBeNull();
      expect(response.headers.get("content-type")).toBe("text/plain");
      expect(await response.text()).toBe("");
      expect(cancelled).toBe(1);
    }
  });

  it("terminates an exact-cap body without EOF and returns its prefix", async () => {
    let cancelled = 0;
    const { fetchImpl, close } = harness({
      dispatch: async () => wireResponse({
        body: stream([bytes("abcdefgh")], () => { cancelled++; }, true),
      }),
      limits: { responseBytes: 8, decompressedBytes: 20 },
    });
    const response = await fetchImpl("https://public.test/");
    expect(await response.text()).toBe("abcdefgh");
    expect(cancelled).toBe(1);
    expect(close).toHaveBeenCalled();
  });

  it("returns a bounded prefix instead of a response-limit error for identity overflow", async () => {
    let cancelled = 0;
    const { fetchImpl } = harness({
      dispatch: async () => wireResponse({
        body: stream([bytes("abcdefghOVERFLOW")], () => { cancelled++; }, true),
      }),
      limits: { responseBytes: 8, decompressedBytes: 20 },
    });
    const response = await fetchImpl("https://public.test/");
    expect(await response.text()).toBe("abcdefgh");
    expect(cancelled).toBe(1);
  });

  it("decompresses within the byte caps and removes stale wire framing headers", async () => {
    const compressed = gzipSync(bytes("decompressed public text"));
    const { fetchImpl } = harness({
      dispatch: async () => wireResponse({
        headers: new Headers({
          "content-encoding": "gzip",
          "content-length": String(compressed.byteLength),
        }),
        body: new Response(compressed).body!,
      }),
    });
    const response = await fetchImpl("https://public.test/");
    expect(await response.text()).toBe("decompressed public text");
    expect(response.headers.get("content-encoding")).toBeNull();
    expect(response.headers.get("content-length")).toBeNull();
  });

  it("cuts off decompressed expansion at the cap without buffering the bomb", async () => {
    let cancelled = 0;
    const compressed = gzipSync(bytes("a".repeat(10_000)));
    const { fetchImpl, close } = harness({
      dispatch: async () => wireResponse({
        headers: new Headers({ "content-encoding": "gzip" }),
        body: stream([compressed], () => { cancelled++; }, true),
      }),
      limits: { responseBytes: 20_000, decompressedBytes: 64 },
    });
    const response = await fetchImpl("https://public.test/");
    expect(await response.text()).toBe("a".repeat(64));
    expect(cancelled).toBeGreaterThan(0);
    expect(close).toHaveBeenCalled();
  });

  it("bounds compressed input and sanitizes incomplete decoder failures", async () => {
    let cancelled = 0;
    const compressed = gzipSync(bytes("a".repeat(10_000)));
    const { fetchImpl } = harness({
      dispatch: async () => wireResponse({
        headers: new Headers({ "content-encoding": "gzip" }),
        body: stream([compressed], () => { cancelled++; }, true),
      }),
      limits: { responseBytes: 8, decompressedBytes: 20_000 },
    });
    const response = await fetchImpl("https://public.test/");
    const error = await failure(response.text());
    expect(error).toMatchObject({ code: "public_fetch_transport_failed" });
    expect((error as Error).message).not.toContain(CANARY);
    expect(cancelled).toBe(1);
  });

  it("bounds redirect response header bytes without reflecting upstream text", async () => {
    const { fetchImpl, close } = harness({
      dispatch: async () => wireResponse({
        status: 302,
        headers: new Headers({ location: `/${CANARY}${"x".repeat(100)}` }),
        headerBytes: 2_000,
      }),
      limits: { headerBytes: 64 },
    });
    const error = await failure(fetchImpl("https://public.test/"));
    expect(error).toMatchObject({ code: "public_fetch_response_limit" });
    expect((error as Error).message).not.toContain(CANARY);
    expect(close).toHaveBeenCalled();
  });

  it("never forwards the internal native marker into dispatcher request fields", async () => {
    const { fetchImpl, hops } = harness();
    const init: PublicWebFetchRequestInit = { [PUBLIC_WEB_FETCH_REQUEST]: true };
    const response = await fetchImpl("https://public.test/", init);
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");
    expect(hops).toHaveLength(1);
    expect(Object.getOwnPropertySymbols(hops[0]!.input)).toEqual([]);
    expect(Object.keys(hops[0]!.input).sort()).toEqual([
      "connectMs",
      "headers",
      "headersMs",
      "method",
      "signal",
      "url",
    ]);
  });
});
