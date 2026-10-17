import { afterEach, describe, expect, it, vi } from "vitest";
import {
  createGuardedFetch,
  isNonPublicAddress,
  SsrfBlockedError,
  type HostResolver,
} from "./ssrf.js";

// ---------------------------------------------------------------------------
// SSRF guard — port of the Dart app's lib/core/ssrf_guard.dart. No test here
// touches real DNS: every hostname case injects a resolver, every literal
// case never resolves. The fetch implementation is always a spy so "blocked"
// is provable as "the guarded fetch never reached the wire".
// ---------------------------------------------------------------------------

const okFetch = vi.fn(async () => new Response("ok", { status: 200 }));
const publicResolver: HostResolver = async () => ["93.184.216.34"];

afterEach(() => {
  vi.unstubAllGlobals();
  okFetch.mockClear();
});

describe("isNonPublicAddress (classifier, Dart parity)", () => {
  it.each([
    // IPv4: 0/8, 10/8, 100.64/10 (incl. Alibaba metadata 100.100.100.200),
    // 127/8, 169.254/16, 172.16/12, 192.0.0/24, 192.168/16, 198.18/15,
    // multicast 224/4, reserved 240/4, broadcast.
    "0.0.0.5",
    "10.0.0.1",
    "100.100.100.200",
    "127.0.0.1",
    "169.254.169.254",
    "172.16.0.1",
    "192.0.0.9",
    "192.168.1.1",
    "198.18.0.1",
    "224.0.0.1",
    "255.255.255.255",
    // IPv6: ::, ::1, fc00::/7, fe80::/10, fec0::/10, ff00::/8, and every
    // IPv6 form embedding an IPv4 — mapped ::ffff:a.b.c.d, compatible
    // ::a.b.c.d, NAT64 64:ff9b::/96, 6to4 2002::/16.
    "::",
    "::1",
    "fc00::1",
    "fe80::1",
    "fec0::1",
    "ff02::1",
    "::ffff:127.0.0.1",
    "::ffff:10.0.0.1",
    "::127.0.0.1",
    "::10.0.0.1",
    "64:ff9b::a00:1",
    "2002:7f00:1::1",
  ])("blocks literal private range %s", (ip) => {
    expect(isNonPublicAddress(ip)).toBe(true);
  });

  it.each([
    "1.2.3.4",
    "8.8.8.8",
    "93.184.216.34",
    "2606:4700::1111",
    "::ffff:93.184.216.34",
    "64:ff9b::808:808", // NAT64-embedded 8.8.8.8 — public stays public
  ])("classifies %s as public", (ip) => {
    expect(isNonPublicAddress(ip)).toBe(false);
  });

  it("fails closed on unparseable input", () => {
    expect(isNonPublicAddress("not-an-ip")).toBe(true);
  });
});

describe("createGuardedFetch", () => {
  it("blocks hostnames resolving to any private address (a mixed record set cannot slip one internal target in)", async () => {
    const resolver: HostResolver = async () => ["93.184.216.34", "127.0.0.1"];
    const fetchImpl = vi.fn(async () => new Response("ok"));
    const g = createGuardedFetch({ resolver, fetchImpl });
    await expect(g("https://example.com/")).rejects.toThrow(SsrfBlockedError);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("still blocks non-loopback private ranges outside production (the dev exemption is loopback-only)", async () => {
    const resolver: HostResolver = async () => ["10.0.0.1"];
    const fetchImpl = vi.fn(async () => new Response("ok"));
    const g = createGuardedFetch({ resolver, fetchImpl });
    await expect(g("https://example.com/")).rejects.toThrow(SsrfBlockedError);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("allows public addresses on 443/80 and hands the original URL to fetch", async () => {
    const fetchImpl = vi.fn(async () => new Response("ok", { status: 200 }));
    const g = createGuardedFetch({ resolver: publicResolver, fetchImpl });
    await g("https://example.com/x");
    await g("http://example.com");
    await g("https://example.com:443/y"); // default port spelling is fine too
    expect(fetchImpl).toHaveBeenCalledTimes(3);
    expect(fetchImpl).toHaveBeenNthCalledWith(1, "https://example.com/x", undefined);
    expect(fetchImpl).toHaveBeenNthCalledWith(2, "http://example.com", undefined);
    expect(fetchImpl).toHaveBeenNthCalledWith(3, "https://example.com:443/y", undefined);
  });

  it("rejects non-http schemes and odd ports", async () => {
    const g = createGuardedFetch({ resolver: publicResolver, fetchImpl: okFetch });
    await expect(g("ftp://example.com/file")).rejects.toThrow(SsrfBlockedError);
    await expect(g("gopher://example.com/")).rejects.toThrow(SsrfBlockedError);
    await expect(g("https://example.com:8443/")).rejects.toThrow(SsrfBlockedError);
    expect(okFetch).not.toHaveBeenCalled();
    // the same odd port passes when explicitly allowed
    const g8443 = createGuardedFetch({
      resolver: publicResolver,
      fetchImpl: okFetch,
      allowedPorts: [8443],
    });
    await g8443("https://example.com:8443/");
    expect(okFetch).toHaveBeenCalledTimes(1);
  });

  it("blocks localhost name forms regardless of what DNS would say", async () => {
    const g = createGuardedFetch({ resolver: publicResolver, fetchImpl: okFetch });
    await expect(g("https://localhost/")).rejects.toThrow(SsrfBlockedError);
    await expect(g("https://foo.localhost/")).rejects.toThrow(SsrfBlockedError);
    await expect(g("https://printer.local/")).rejects.toThrow(SsrfBlockedError);
    expect(okFetch).not.toHaveBeenCalled();
  });

  it("production mode blocks loopback; test mode allows it (fixture servers run on 127.0.0.1)", async () => {
    const fetchImpl = vi.fn(async () => new Response("ok", { status: 200 }));
    const g = createGuardedFetch({ fetchImpl, allowedPorts: [80, 443, 1234] });
    vi.stubEnv("NODE_ENV", "production");
    await expect(g("http://127.0.0.1:1234/")).rejects.toThrow(SsrfBlockedError);
    await expect(g("http://[::1]:1234/")).rejects.toThrow(SsrfBlockedError);
    expect(fetchImpl).not.toHaveBeenCalled();
    vi.stubEnv("NODE_ENV", "test");
    await expect(g("http://127.0.0.1:1234/")).resolves.toBeInstanceOf(Response);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(fetchImpl).toHaveBeenCalledWith("http://127.0.0.1:1234/", undefined);
  });
});
