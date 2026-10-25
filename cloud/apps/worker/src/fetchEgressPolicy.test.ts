import { describe, expect, it, vi } from "vitest";
import {
  createSsrfGuard,
  SsrfBlockedError,
  type SsrfGuard,
} from "@ovid/agent-core";
import {
  createFetchHandler,
  createPublicWebFetch,
  followGuardedRedirects,
  PUBLIC_WEB_FETCH_REQUEST,
  type McpCallContext,
  type PinnedDispatcherOptions,
  type PinnedDispatchRequest,
  type PinnedDispatchResponse,
  type PublicWebFetchRequestInit,
} from "@ovid/mcp";

import { createFetchEgressPolicy } from "./fetchEgressPolicy.js";

interface RecordedRequest {
  url: string;
  init: RequestInit | undefined;
}

function scriptedTransport(
  script: (url: string, call: number) => Response,
): { requests: RecordedRequest[]; fetchImpl: typeof fetch } {
  const requests: RecordedRequest[] = [];
  const fetchImpl = (async (
    input: Parameters<typeof fetch>[0],
    init?: RequestInit,
  ): Promise<Response> => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.href
          : input.url;
    requests.push({ url, init });
    return script(url, requests.length);
  }) as typeof fetch;
  return { requests, fetchImpl };
}

function publicGuard(): { guard: SsrfGuard; lookups: string[] } {
  const lookups: string[] = [];
  const guard = createSsrfGuard({
    resolver: async (host) => {
      lookups.push(host);
      // Public-by-classifier fixture: no DNS or network access is needed.
      return ["93.184.216.34"];
    },
  });
  return { guard, lookups };
}

function nativeContext(
  fetchImpl: McpCallContext["fetchImpl"],
  signal?: AbortSignal,
): McpCallContext {
  return Object.assign(
    { uid: "user-1", secrets: {}, workspace: {}, fetchImpl },
    signal === undefined ? {} : { signal },
  );
}

describe("worker original fetch egress redirect parity", () => {
  it("denies HTTPS to HTTP before the downgrade request or its credentials leave the process", async () => {
    const { requests, fetchImpl } = scriptedTransport((_url, call) =>
      call === 1
        ? new Response(null, {
            status: 302,
            headers: { location: "http://downgrade.public.test/collect" },
          })
        : new Response("credential captured", { status: 200 }),
    );
    const { guard, lookups } = publicGuard();
    const egress = createFetchEgressPolicy(guard, fetchImpl);

    const denial = await egress("https://source.public.test/start", {
      headers: {
        authorization: "Bearer test-only-secret",
        cookie: "session=test-only-secret",
      },
    }).then(
      () => null,
      (error: unknown) => error,
    );

    expect(denial).toBeInstanceOf(SsrfBlockedError);
    expect((denial as Error).message).toBe("egress_redirect_downgrade");
    // The fixture really is credential-bearing on the initial HTTPS request.
    expect(new Headers(requests[0]?.init?.headers).get("authorization")).toBe(
      "Bearer test-only-secret",
    );
    expect(requests.map((request) => request.url)).toEqual([
      "https://source.public.test/start",
    ]);
    expect(lookups).toEqual(["source.public.test"]);
  });

  it("denies a later-hop downgrade after valid HTTPS redirects before DNS, transport, or credential forwarding", async () => {
    const { requests, fetchImpl } = scriptedTransport((url) => {
      if (url === "https://source.public.test/start") {
        return new Response(null, { status: 307, headers: { location: "/middle" } });
      }
      if (url === "https://source.public.test/middle") {
        return new Response(null, { status: 302, headers: { location: "/ready" } });
      }
      return new Response(null, {
        status: 302,
        headers: { location: "http://downgrade.public.test/collect" },
      });
    });
    const { guard, lookups } = publicGuard();
    const egress = createFetchEgressPolicy(guard, fetchImpl);

    const denial = await egress("https://source.public.test/start", {
      headers: {
        authorization: "Bearer later-hop-test-secret",
        cookie: "session=later-hop-test-secret",
      },
    }).then(
      () => null,
      (error: unknown) => error,
    );

    expect(denial).toBeInstanceOf(SsrfBlockedError);
    expect((denial as Error).message).toBe("egress_redirect_downgrade");
    expect(requests.map((request) => request.url)).toEqual([
      "https://source.public.test/start",
      "https://source.public.test/middle",
      "https://source.public.test/ready",
    ]);
    // Credentials may traverse the valid same-origin HTTPS hops, but there is
    // no fourth HTTP request to receive or forward them.
    expect(
      requests.map((request) =>
        new Headers(request.init?.headers).get("authorization"),
      ),
    ).toEqual([
      "Bearer later-hop-test-secret",
      "Bearer later-hop-test-secret",
      "Bearer later-hop-test-secret",
    ]);
    expect(lookups).toEqual([
      "source.public.test",
      "source.public.test",
      "source.public.test",
    ]);
  });

  it("denies a native downgrade without falling back to the legacy worker transport", async () => {
    const legacy = scriptedTransport(() => new Response("legacy must not run"));
    const pinned = scriptedTransport(() =>
      new Response(null, {
        status: 302,
        headers: { location: "http://source.public.test/collect" },
      }),
    );
    const { guard } = publicGuard();
    const egress = createFetchEgressPolicy(guard, legacy.fetchImpl, pinned.fetchImpl);

    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://source.public.test/start" },
      nativeContext(egress),
    );

    expect(result.isError).toBe(true);
    expect(result.text).toBe("Fetch error: request blocked.");
    expect(result.text).not.toContain("egress_redirect_downgrade");
    expect(pinned.requests.map((request) => request.url)).toEqual([
      "https://source.public.test/start",
    ]);
    expect(legacy.requests).toHaveLength(0);
  });

  it("routes only marked native calls to pinned public-web transport across redirects", async () => {
    const legacy = scriptedTransport(() => new Response("legacy must not run"));
    const pinned = scriptedTransport((url) => {
      if (url === "https://source.public.test/start") {
        return new Response(null, { status: 307, headers: { location: "/middle" } });
      }
      if (url === "https://source.public.test/middle") {
        return new Response(null, {
          status: 302,
          headers: { location: "https://target.public.test/final" },
        });
      }
      return new Response("public-landing", { status: 200 });
    });
    const { guard, lookups } = publicGuard();
    const egress = createFetchEgressPolicy(guard, legacy.fetchImpl, pinned.fetchImpl);

    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://source.public.test/start", raw: true },
      nativeContext(egress),
    );

    expect(result.isError).toBe(false);
    expect(result.text).toBe("public-landing");
    expect(pinned.requests.map((request) => request.url)).toEqual([
      "https://source.public.test/start",
      "https://source.public.test/middle",
      "https://target.public.test/final",
    ]);
    // The injected pinned test double owns its resolution. Production uses
    // createPublicWebFetch's resolver, never this legacy guard/raw fetch pair.
    expect(lookups).toEqual([]);
    expect(legacy.requests).toHaveLength(0);
    for (const request of pinned.requests) {
      expect(request.init?.redirect).toBe("manual");
      expect(new Headers(request.init?.headers).has("authorization")).toBe(false);
      expect(new Headers(request.init?.headers).has("cookie")).toBe(false);
    }
  });
});

const PUBLIC_ADDRESS = "93.184.216.34";
const BODY_CAP = 2 * 1024 * 1024;
const COMPOSITION_CANARY = "composition-upstream-canary";

interface ProductionHop {
  options: PinnedDispatcherOptions;
  input: PinnedDispatchRequest;
}

function bodyStream(
  chunks: readonly Uint8Array[],
  onCancel?: () => void,
  holdOpen = false,
): ReadableStream<Uint8Array> {
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

function dispatchResponse(
  patch: Partial<PinnedDispatchResponse> = {},
): PinnedDispatchResponse {
  return {
    status: 200,
    headers: new Headers(),
    body: new Response("ok").body!,
    remoteAddress: PUBLIC_ADDRESS,
    ...patch,
  };
}

function productionHarness(
  script: (input: PinnedDispatchRequest, hop: number) =>
    | PinnedDispatchResponse
    | Promise<PinnedDispatchResponse>,
) {
  const hops: ProductionHop[] = [];
  const resolutions: string[] = [];
  const close = vi.fn(async () => {});
  // Only the two lowest seams are replaced. Selection and every native,
  // redirect, DNS-classification, streaming, and output layer above them is real.
  const publicWebFetchImpl = createPublicWebFetch({
    resolver: async (host) => {
      resolutions.push(host);
      return [PUBLIC_ADDRESS];
    },
    dispatcherFactory: (options) => ({
      async dispatch(input) {
        hops.push({ options, input });
        return script(input, hops.length);
      },
      close,
    }),
  });
  const { guard, lookups } = publicGuard();
  const legacy = scriptedTransport(() => new Response("legacy fallback must not run"));
  const egress = createFetchEgressPolicy(guard, legacy.fetchImpl, publicWebFetchImpl);
  return { egress, hops, resolutions, close, legacy, lookups };
}

const utf8 = (value: string): Uint8Array => new TextEncoder().encode(value);

describe("production-shaped native → worker selection → publicWebFetch composition", () => {
  it("returns a terminal redirect landing through native and revalidates each real current hop", async () => {
    let redirectCancellations = 0;
    const harness = productionHarness((input) => {
      if (input.url.href === "https://source.public.test/start") {
        return dispatchResponse({
          status: 307,
          headers: new Headers({ location: "/middle" }),
          body: bodyStream([utf8("first redirect")], () => { redirectCancellations++; }, true),
        });
      }
      if (input.url.href === "https://source.public.test/middle") {
        return dispatchResponse({
          status: 302,
          headers: new Headers({ location: "https://target.public.test/final" }),
          body: bodyStream([utf8("second redirect")], () => { redirectCancellations++; }, true),
        });
      }
      return dispatchResponse({ body: new Response("public-landing").body! });
    });

    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://source.public.test/start", raw: true },
      nativeContext(harness.egress),
    );

    expect(result.isError).toBe(false);
    expect(result.text).toBe("public-landing");
    expect(harness.hops.map((hop) => hop.input.url.href)).toEqual([
      "https://source.public.test/start",
      "https://source.public.test/middle",
      "https://target.public.test/final",
    ]);
    expect(harness.resolutions).toEqual([
      "source.public.test",
      "source.public.test",
      "target.public.test",
    ]);
    expect(harness.close).toHaveBeenCalledTimes(3);
    expect(redirectCancellations).toBe(2);
    expect(harness.legacy.requests).toHaveLength(0);
    expect(harness.lookups).toEqual([]);
    for (const hop of harness.hops) {
      expect(Object.getOwnPropertySymbols(hop.input)).toEqual([]);
      expect("redirect" in hop.input).toBe(false);
      expect(
        (hop.input as unknown as { [PUBLIC_WEB_FETCH_REQUEST]?: unknown })[PUBLIC_WEB_FETCH_REQUEST],
      ).toBeUndefined();
      expect(hop.input.method).toBe("GET");
      expect(hop.input.headers.authorization).toBeUndefined();
      expect(hop.input.headers.cookie).toBeUndefined();
    }
  });

  it("preserves redirected:true metadata and the landing body at the terminal success Response", async () => {
    let cancelled = 0;
    const harness = productionHarness((_input, hop) => hop === 1
      ? dispatchResponse({
          status: 302,
          headers: new Headers({ location: "/final" }),
          body: bodyStream([utf8("redirect")], () => { cancelled++; }, true),
        })
      : dispatchResponse({ body: new Response("terminal-landing").body! }));

    const init: PublicWebFetchRequestInit = { [PUBLIC_WEB_FETCH_REQUEST]: true };
    const response = await followGuardedRedirects(
      harness.egress,
      "https://source.public.test/start",
      init,
    );

    expect(response.status).toBe(200);
    expect(response.redirected).toBe(true);
    expect(await response.text()).toBe("terminal-landing");
    expect(harness.hops.map((hop) => hop.input.url.href)).toEqual([
      "https://source.public.test/start",
      "https://source.public.test/final",
    ]);
    expect(cancelled).toBe(1);
    expect(harness.close).toHaveBeenCalledTimes(2);
    expect(harness.legacy.requests).toHaveLength(0);
  });

  it("preserves redirected:true and generic terminal non-2xx metadata after a real redirect", async () => {
    let cancelled = 0;
    const harness = productionHarness((_input, hop) => hop === 1
      ? dispatchResponse({
          status: 302,
          headers: new Headers({ location: "/failure" }),
          body: bodyStream([utf8("redirect")], () => { cancelled++; }, true),
        })
      : dispatchResponse({
          status: 503,
          headers: new Headers({ "x-upstream-canary": COMPOSITION_CANARY }),
          body: bodyStream([utf8(COMPOSITION_CANARY)], () => { cancelled++; }, true),
        }));

    const init: PublicWebFetchRequestInit = { [PUBLIC_WEB_FETCH_REQUEST]: true };
    const response = await followGuardedRedirects(
      harness.egress,
      "https://source.public.test/start",
      init,
    );

    expect(response.status).toBe(503);
    expect(response.redirected).toBe(true);
    expect(response.statusText).toBe("");
    expect(response.body).toBeNull();
    expect(response.headers.get("x-upstream-canary")).toBeNull();
    expect(await response.text()).toBe("");
    expect(harness.hops).toHaveLength(2);
    expect(cancelled).toBe(2);
    expect(harness.close).toHaveBeenCalledTimes(2);
    expect(harness.legacy.requests).toHaveLength(0);
  });

  it.each([
    {
      kind: "downgrade",
      location: "http://target.public.test/collect",
      message: "Fetch error: request blocked.",
    },
    {
      kind: "userinfo",
      location: `https://user:${COMPOSITION_CANARY}@target.public.test/collect`,
      message: "Fetch error: request blocked.",
    },
    {
      kind: "non-443",
      location: "https://target.public.test:444/collect",
      message: "Fetch error: public_fetch_port_denied",
    },
  ])("denies a native-owned $kind redirect without target DNS, fallback, or canary output", async ({ location, message }) => {
    let cancelled = 0;
    const harness = productionHarness(() => dispatchResponse({
      status: 302,
      headers: new Headers({ location }),
      body: bodyStream([utf8(COMPOSITION_CANARY)], () => { cancelled++; }, true),
    }));

    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://source.public.test/start" },
      nativeContext(harness.egress),
    );

    expect(result.isError).toBe(true);
    expect(result.text).toBe(message);
    expect(JSON.stringify(result)).not.toContain(COMPOSITION_CANARY);
    expect(harness.hops).toHaveLength(1);
    expect(harness.resolutions).toEqual(["source.public.test"]);
    expect(harness.legacy.requests).toHaveLength(0);
    expect(cancelled).toBe(1);
    expect(harness.close).toHaveBeenCalledTimes(1);
  });

  it("keeps the five-follow redirect bound in native, not in the current-hop transport", async () => {
    let cancellations = 0;
    const harness = productionHarness((_input, hop) => dispatchResponse({
      status: 302,
      headers: new Headers({ location: `/hop-${hop}` }),
      body: bodyStream([utf8("redirect")], () => { cancellations++; }),
    }));

    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://source.public.test/start" },
      nativeContext(harness.egress),
    );

    expect(result.isError).toBe(true);
    expect(result.text).toBe("Fetch error: too many redirects");
    expect(harness.hops).toHaveLength(6);
    expect(harness.resolutions).toHaveLength(6);
    expect(cancellations).toBe(6);
    expect(harness.close).toHaveBeenCalledTimes(6);
    expect(harness.legacy.requests).toHaveLength(0);
  });

  it("returns only a generic non-2xx status and discards its real transport body", async () => {
    let cancelled = 0;
    const harness = productionHarness(() => dispatchResponse({
      status: 503,
      headers: new Headers({ "x-upstream-canary": COMPOSITION_CANARY }),
      body: bodyStream([utf8(COMPOSITION_CANARY)], () => { cancelled++; }, true),
    }));

    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://source.public.test/error" },
      nativeContext(harness.egress),
    );

    expect(result).toEqual({
      text: "HTTP error 503",
      isError: true,
      content: [{ type: "text", text: "HTTP error 503" }],
    });
    expect(JSON.stringify(result)).not.toContain(COMPOSITION_CANARY);
    expect(cancelled).toBe(1);
    expect(harness.close).toHaveBeenCalledTimes(1);
    expect(harness.legacy.requests).toHaveLength(0);
  });

  it("settles an exact-2MiB/no-EOF body immediately through the real native seam", async () => {
    vi.useFakeTimers();
    try {
      let cancelled = 0;
      const body = bodyStream(
        [new Uint8Array(BODY_CAP).fill(0x61)],
        () => { cancelled++; },
        true,
      );
      const harness = productionHarness(() => dispatchResponse({ body }));
      const pending = createFetchHandler().callTool(
        "fetch",
        { url: "https://source.public.test/exact-cap", max_length: 100_000, raw: true },
        nativeContext(harness.egress),
      );
      let settled = false;
      void pending.then(() => { settled = true; });

      await vi.advanceTimersByTimeAsync(0);
      expect(settled).toBe(true);
      const result = await pending;
      expect(result.isError).toBe(false);
      expect(result.text).toContain("characters omitted —");
      expect(result.text).not.toContain("public_fetch_response_limit");
      expect(cancelled).toBe(1);
      expect(harness.close).toHaveBeenCalledTimes(1);
      expect(harness.legacy.requests).toHaveLength(0);
      expect(body.locked).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it("returns a 2MiB prefix instead of a response-limit error for a larger streamed body", async () => {
    let cancelled = 0;
    const oversized = new Uint8Array(BODY_CAP + 64).fill(0x61);
    oversized.fill(0x62, BODY_CAP);
    const body = bodyStream([oversized], () => { cancelled++; }, true);
    const harness = productionHarness(() => dispatchResponse({ body }));

    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://source.public.test/over-cap", max_length: 100_000, raw: true },
      nativeContext(harness.egress),
    );

    expect(result.isError).toBe(false);
    expect(result.text).toContain("characters omitted —");
    expect(result.text).not.toContain("b");
    expect(result.text).not.toContain("public_fetch_response_limit");
    expect(cancelled).toBe(1);
    expect(harness.close).toHaveBeenCalledTimes(1);
    expect(harness.legacy.requests).toHaveLength(0);
    expect(body.locked).toBe(false);
  });

  it("cancels a real streamed native body without reflecting the caller reason", async () => {
    let cancelled = 0;
    let markFirstChunk!: () => void;
    const firstChunk = new Promise<void>((resolve) => { markFirstChunk = resolve; });
    let sent = false;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (!sent) {
          sent = true;
          controller.enqueue(utf8("first"));
          markFirstChunk();
        }
      },
      cancel() { cancelled++; },
    });
    const harness = productionHarness(() => dispatchResponse({ body }));
    const controller = new AbortController();
    const pending = createFetchHandler().callTool(
      "fetch",
      { url: "https://source.public.test/stalled-body", raw: true },
      nativeContext(harness.egress, controller.signal),
    );
    await firstChunk;
    controller.abort(new Error(COMPOSITION_CANARY));

    const result = await pending;
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Fetch error: request timed out or was aborted.");
    expect(result.text).not.toContain(COMPOSITION_CANARY);
    expect(cancelled).toBeGreaterThan(0);
    expect(harness.close).toHaveBeenCalledTimes(1);
    expect(harness.legacy.requests).toHaveLength(0);
  });
});
