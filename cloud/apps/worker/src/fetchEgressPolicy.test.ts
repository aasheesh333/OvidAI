import { describe, expect, it } from "vitest";
import {
  createSsrfGuard,
  SsrfBlockedError,
  type SsrfGuard,
} from "@ovid/agent-core";
import { createFetchHandler, type McpCallContext } from "@ovid/mcp";

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

function nativeContext(fetchImpl: McpCallContext["fetchImpl"]): McpCallContext {
  return { uid: "user-1", secrets: {}, workspace: {}, fetchImpl };
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

  it("denies a downgrade through the real native handler and guarded-egress composition", async () => {
    const { requests, fetchImpl } = scriptedTransport(() =>
      new Response(null, {
        status: 302,
        headers: { location: "http://source.public.test/collect" },
      }),
    );
    const { guard } = publicGuard();
    const egress = createFetchEgressPolicy(guard, fetchImpl);

    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://source.public.test/start" },
      nativeContext(egress),
    );

    expect(result.isError).toBe(true);
    expect(result.text).toContain("egress_redirect_downgrade");
    expect(requests.map((request) => request.url)).toEqual([
      "https://source.public.test/start",
    ]);
  });

  it("allows a public HTTPS redirect chain through the same native composition", async () => {
    const { requests, fetchImpl } = scriptedTransport((url) => {
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
    const egress = createFetchEgressPolicy(guard, fetchImpl);

    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://source.public.test/start", raw: true },
      nativeContext(egress),
    );

    expect(result.isError).toBe(false);
    expect(result.text).toBe("public-landing");
    expect(requests.map((request) => request.url)).toEqual([
      "https://source.public.test/start",
      "https://source.public.test/middle",
      "https://target.public.test/final",
    ]);
    expect(lookups).toEqual([
      "source.public.test",
      "source.public.test",
      "target.public.test",
    ]);
    for (const request of requests) {
      expect(request.init?.redirect).toBe("manual");
      expect(new Headers(request.init?.headers).has("authorization")).toBe(false);
      expect(new Headers(request.init?.headers).has("cookie")).toBe(false);
    }
  });
});
