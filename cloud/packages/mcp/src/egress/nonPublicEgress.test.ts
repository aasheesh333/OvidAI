import { afterEach, describe, expect, it, vi } from "vitest";

import { followGuardedRedirects } from "../native/fetch.js";
import {
  createGuardedFetch,
  isNonPublicAddress,
  SsrfBlockedError,
} from "../ssrf.js";
import {
  createPublicWebFetch,
  PublicWebFetchError,
  type PublicWebDispatcherOptions,
} from "./publicWebFetch.js";
import type { PinnedDispatchRequest } from "./providerEgress.js";

// ---------------------------------------------------------------------------
// Non-public egress regression matrix.
//
// Every case here is an address form that a compromised/prompt-injected agent
// could hand to the public-web path. The assertions are deliberately at the
// TRANSPORT boundary: a refusal must be provable as "no dispatcher/socket was
// ever constructed", not merely "the URL string looked private".
//
// The classifier matrix pins 127/8, 10/8, 172.16/12, 192.168/16, 169.254/16
// (metadata), ::1, fc00::/7 and fe80::/10 together with their nearest public
// neighbours, so widening or narrowing a range breaks a test.
// ---------------------------------------------------------------------------

const PUBLIC_V4 = "93.184.216.34";
const PUBLIC_V6 = "2606:4700::1111";
const CANARY = "private-upstream-canary";

interface Hop {
  options: PublicWebDispatcherOptions;
  input: PinnedDispatchRequest;
}

function wireResponse(patch: Partial<{
  status: number;
  headers: Headers;
  body: ReadableStream<Uint8Array>;
}> = {}) {
  return {
    status: patch.status ?? 200,
    headers: patch.headers ?? new Headers(),
    body: patch.body ?? new Response("ok").body!,
    remoteAddress: PUBLIC_V4,
  };
}

function harness(options: {
  resolver?: (host: string) => Promise<string[]>;
  dispatch?: (input: PinnedDispatchRequest) => Promise<ReturnType<typeof wireResponse>>;
} = {}) {
  const hops: Hop[] = [];
  const fetchImpl = createPublicWebFetch({
    resolver: options.resolver ?? (async () => [PUBLIC_V4]),
    dispatcherFactory: (dispatcherOptions) => ({
      async dispatch(input) {
        hops.push({ options: dispatcherOptions, input });
        return options.dispatch === undefined ? wireResponse() : options.dispatch(input);
      },
      close: async () => {},
    }),
  });
  return { fetchImpl, hops };
}

async function failure(pending: Promise<unknown>): Promise<unknown> {
  return pending.then(() => null, (error: unknown) => error);
}

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("non-public range classifier (the shared copy every guard imports)", () => {
  it.each([
    // Loopback 127.0.0.0/8
    "127.0.0.1",
    "127.255.255.255",
    // Private 10.0.0.0/8
    "10.0.0.1",
    "10.255.255.255",
    // Private 172.16.0.0/12 — both inclusive edges
    "172.16.0.1",
    "172.31.255.255",
    // Private 192.168.0.0/16
    "192.168.0.1",
    "192.168.255.255",
    // Link-local / cloud metadata 169.254.0.0/16
    "169.254.0.1",
    "169.254.169.254",
    // IPv6 loopback, ULA fc00::/7, link-local fe80::/10
    "::1",
    "fc00::1",
    "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
    "fe80::1",
    "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
  ])("blocks %s", (address) => {
    expect(isNonPublicAddress(address)).toBe(true);
  });

  it.each([
    // One address below/above each blocked range must stay public.
    "172.15.255.255",
    "172.32.0.1",
    "192.167.255.255",
    "192.169.0.1",
    "169.253.255.255",
    "169.255.0.1",
    "fb00::1",
    "8.8.8.8",
    PUBLIC_V6,
  ])("leaves public %s reachable", (address) => {
    expect(isNonPublicAddress(address)).toBe(false);
  });
});

describe("public-web path blocks encoded IPv4 and IPv6-embedded forms before any socket", () => {
  it.each([
    // WHATWG URL normalizes every one of these to 127.0.0.1; the guard must
    // classify the NORMALIZED host, never the literal the caller typed.
    { name: "decimal dword", url: "https://2130706433/" },
    { name: "hex dword", url: "https://0x7f000001/" },
    { name: "octal dotted", url: "https://0177.0.0.1/" },
    { name: "short form 127.1", url: "https://127.1/" },
    { name: "hex + short", url: "https://0x7f.1/" },
    { name: "trailing dot", url: "https://127.0.0.1./" },
    // IPv6 forms that embed a non-public IPv4 address.
    { name: "mapped loopback", url: "https://[::ffff:127.0.0.1]/" },
    { name: "mapped metadata", url: "https://[::ffff:169.254.169.254]/" },
    { name: "mapped private 10/8", url: "https://[::ffff:a00:1]/" },
    { name: "compatible loopback", url: "https://[::127.0.0.1]/" },
    { name: "NAT64 loopback", url: "https://[64:ff9b::7f00:1]/" },
    { name: "6to4 loopback", url: "https://[2002:7f00:1::1]/" },
    // Native IPv6 special-purpose ranges.
    { name: "IPv6 loopback", url: "https://[::1]/" },
    { name: "IPv6 ULA", url: "https://[fc00::1]/" },
    { name: "IPv6 link-local", url: "https://[fe80::1]/" },
  ])("$name ($url) is refused with zero dispatchers", async ({ url }) => {
    const resolver = vi.fn(async () => [PUBLIC_V4]);
    const { fetchImpl, hops } = harness({ resolver });

    const error = await failure(fetchImpl(url));

    expect(error).toBeInstanceOf(PublicWebFetchError);
    expect((error as PublicWebFetchError).code).toBe("public_fetch_non_public_address");
    // Literal (normalized) hosts never consult DNS, and nothing was dispatched.
    expect(resolver).not.toHaveBeenCalled();
    expect(hops).toHaveLength(0);
  });
});

describe("DNS rebinding fails closed", () => {
  it("pins the first checked answer: a second resolver answer of 127.0.0.1 never reaches the socket", async () => {
    let resolutions = 0;
    const resolver = vi.fn(async () => {
      resolutions++;
      return resolutions === 1 ? [PUBLIC_V4] : ["127.0.0.1"];
    });
    const { fetchImpl, hops } = harness({ resolver });

    const response = await fetchImpl("https://rebind.test/resource");
    expect(await response.text()).toBe("ok");
    expect(resolver).toHaveBeenCalledTimes(1);

    // The dispatcher's lookup must serve only the already-checked address,
    // even though a fresh resolution would now answer private space.
    const lookedUp = await new Promise<string[]>((resolve, reject) => {
      hops[0]!.options.lookup("rebind.test", { all: true }, (error, records) => {
        if (error) reject(error);
        else resolve((records as Array<{ address: string }>).map((record) => record.address));
      });
    });
    expect(lookedUp).toEqual([PUBLIC_V4]);
    expect(resolutions).toBe(1);
  });

  it("a hostname that now answers metadata space is refused on the next caller-driven hop", async () => {
    let resolutions = 0;
    const resolver = vi.fn(async () => {
      resolutions++;
      return resolutions === 1 ? [PUBLIC_V4] : ["169.254.169.254"];
    });
    const { fetchImpl, hops } = harness({ resolver });

    const first = await fetchImpl("https://rebind.test/start");
    expect(first.status).toBe(200);

    const error = await failure(fetchImpl("https://rebind.test/next"));
    expect(error).toBeInstanceOf(PublicWebFetchError);
    expect((error as PublicWebFetchError).code).toBe("public_fetch_non_public_address");
    expect(resolutions).toBe(2);
    expect(hops).toHaveLength(1);
  });
});

describe("redirects to non-public targets are never followed", () => {
  it("metadata literal: the guarded redirect loop refuses hop 2 without dispatching it", async () => {
    const resolver = vi.fn(async () => [PUBLIC_V4]);
    const { fetchImpl, hops } = harness({
      resolver,
      dispatch: async () => wireResponse({
        status: 302,
        headers: new Headers({ location: "https://169.254.169.254/latest/meta-data/" }),
        body: new Response("redirect body").body!,
      }),
    });

    const error = await failure(
      followGuardedRedirects(fetchImpl, "https://public.test/start"),
    );

    expect(error).toBeInstanceOf(PublicWebFetchError);
    expect((error as PublicWebFetchError).code).toBe("public_fetch_non_public_address");
    // Exactly one wire request: the Location was classified before hop 2.
    expect(hops).toHaveLength(1);
    expect(resolver).toHaveBeenCalledTimes(1);
    expect(resolver).toHaveBeenCalledWith("public.test");
  });

  it("private hostname: a Location resolving to 10.0.0.7 is refused, not followed", async () => {
    const resolver = vi.fn(async (host: string) =>
      host === "internal.test" ? ["10.0.0.7"] : [PUBLIC_V4],
    );
    const { fetchImpl, hops } = harness({
      resolver,
      dispatch: async () => wireResponse({
        status: 307,
        headers: new Headers({ location: "https://internal.test/collect" }),
        body: new Response(CANARY).body!,
      }),
    });

    const error = await failure(
      followGuardedRedirects(fetchImpl, "https://public.test/start"),
    );

    expect(error).toBeInstanceOf(PublicWebFetchError);
    expect((error as PublicWebFetchError).code).toBe("public_fetch_non_public_address");
    expect((error as Error).message).not.toContain(CANARY);
    expect(hops).toHaveLength(1);
    expect(resolver.mock.calls.map(([host]) => host)).toEqual(["public.test", "internal.test"]);
  });

  it("legacy guarded fetch re-enters the guard on a private redirect (production, literal loopback)", async () => {
    vi.stubEnv("NODE_ENV", "production");
    const wire = vi.fn(async () => new Response(null, {
      status: 302,
      headers: { location: "https://127.0.0.1/collect" },
    }));
    const guarded = createGuardedFetch({
      resolver: async () => [PUBLIC_V4],
      fetchImpl: wire,
    });

    await expect(followGuardedRedirects(guarded, "https://public.test/start")).rejects.toBeInstanceOf(
      SsrfBlockedError,
    );
    expect(wire).toHaveBeenCalledTimes(1);
  });
});

describe("legitimate public traffic still succeeds", () => {
  it("public-web fetch returns the body and pins the public address", async () => {
    const { fetchImpl, hops } = harness();
    const response = await fetchImpl("https://example.com/ok");
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");
    expect(hops).toHaveLength(1);
    expect(hops[0]!.options.addresses).toEqual([PUBLIC_V4]);
  });

  it("guarded fetch reaches a public host", async () => {
    const wire = vi.fn(async () => new Response("public", { status: 200 }));
    const guarded = createGuardedFetch({
      resolver: async () => [PUBLIC_V4, PUBLIC_V6],
      fetchImpl: wire,
    });
    const response = await guarded("https://example.com/ok");
    expect(await response.text()).toBe("public");
    expect(wire).toHaveBeenCalledTimes(1);
  });
});
