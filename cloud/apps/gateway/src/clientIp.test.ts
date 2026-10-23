import { describe, expect, it } from "vitest";
import {
  DEFAULT_TRUSTED_PROXY_CIDRS,
  compileTrustedProxies,
  isTrustedProxy,
  parseTrustedProxyCidrs,
  resolveClientIp,
} from "./clientIp.js";

/**
 * Client-IP trust contract.
 *
 * The gateway runs behind Caddy, which reaches it over loopback or the
 * Docker bridge. Fastify's `trustProxy` is deliberately NOT enabled, so
 * `request.ip` is the SOCKET PEER. The only way to learn the visitor's
 * address is X-Forwarded-For — and ONLY when that socket peer is one of the
 * configured reverse proxies. A header supplied by any other peer is
 * attacker-controlled and must be ignored completely.
 */

const TRUSTED = compileTrustedProxies(DEFAULT_TRUSTED_PROXY_CIDRS);

describe("resolveClientIp — trusted peer", () => {
  it("reads the single X-Forwarded-For hop Caddy writes", () => {
    expect(
      resolveClientIp({
        peerAddress: "127.0.0.1",
        forwardedFor: "203.0.113.7",
        trustedProxies: TRUSTED,
      }),
    ).toBe("203.0.113.7");
  });

  it("walks the chain right-to-left and returns the rightmost UNTRUSTED hop", () => {
    // A trusted proxy may append to an attacker-supplied header. The real
    // client is the rightmost address that is not itself a trusted proxy;
    // everything to its left is client-controlled and must be ignored.
    expect(
      resolveClientIp({
        peerAddress: "127.0.0.1",
        forwardedFor: "1.1.1.1, 203.0.113.7, 172.18.0.5",
        trustedProxies: TRUSTED,
      }),
    ).toBe("203.0.113.7");
  });

  it("returns the leftmost hop when every hop is a trusted proxy", () => {
    expect(
      resolveClientIp({
        peerAddress: "127.0.0.1",
        forwardedFor: "172.18.0.9, 127.0.0.1",
        trustedProxies: TRUSTED,
      }),
    ).toBe("172.18.0.9");
  });

  it("falls back to the peer when the header is absent", () => {
    expect(
      resolveClientIp({
        peerAddress: "127.0.0.1",
        forwardedFor: undefined,
        trustedProxies: TRUSTED,
      }),
    ).toBe("127.0.0.1");
  });

  it("ignores the whole header when any entry is malformed", () => {
    // Never salvage a partially-parsed chain: a garbage entry may be the
    // attacker's, and picking an earlier entry would honour it.
    expect(
      resolveClientIp({
        peerAddress: "127.0.0.1",
        forwardedFor: "203.0.113.7, not-an-ip",
        trustedProxies: TRUSTED,
      }),
    ).toBe("127.0.0.1");
  });

  it("handles IPv4-mapped peers and duplicate header values", () => {
    expect(
      resolveClientIp({
        peerAddress: "::ffff:127.0.0.1",
        forwardedFor: ["203.0.113.7", "198.51.100.4"],
        trustedProxies: TRUSTED,
      }),
    ).toBe("198.51.100.4");
  });
});

describe("resolveClientIp — untrusted peer", () => {
  it("IGNORES X-Forwarded-For from an untrusted peer", () => {
    // The security requirement: a public client cannot choose its own
    // observed IP by sending a header.
    expect(
      resolveClientIp({
        peerAddress: "203.0.113.9",
        forwardedFor: "198.51.100.1",
        trustedProxies: TRUSTED,
      }),
    ).toBe("203.0.113.9");
  });

  it("returns the peer when the peer address is missing or unparseable", () => {
    expect(
      resolveClientIp({
        peerAddress: undefined,
        forwardedFor: "198.51.100.1",
        trustedProxies: TRUSTED,
      }),
    ).toBeNull();
    expect(
      resolveClientIp({
        peerAddress: "garbage",
        forwardedFor: "198.51.100.1",
        trustedProxies: TRUSTED,
      }),
    ).toBeNull();
  });
});

describe("trusted proxy configuration", () => {
  it("defaults to loopback + RFC1918 (the reverse proxy's own address space)", () => {
    expect(parseTrustedProxyCidrs(undefined)).toEqual([
      ...DEFAULT_TRUSTED_PROXY_CIDRS,
    ]);
    expect(DEFAULT_TRUSTED_PROXY_CIDRS).toContain("127.0.0.0/8");
    expect(DEFAULT_TRUSTED_PROXY_CIDRS).toContain("172.16.0.0/12");
  });

  it("accepts a comma/space separated override and validates every entry", () => {
    expect(
      parseTrustedProxyCidrs(" 127.0.0.1/32, 10.0.0.0/8  172.18.0.0/16 "),
    ).toEqual(["127.0.0.1/32", "10.0.0.0/8", "172.18.0.0/16"]);
    expect(() => parseTrustedProxyCidrs("127.0.0.1/32, nope")).toThrow(
      /OVID_TRUSTED_PROXY_CIDRS/,
    );
    expect(() => parseTrustedProxyCidrs("10.0.0.0/33")).toThrow(
      /OVID_TRUSTED_PROXY_CIDRS/,
    );
  });

  it("matches IPv4, IPv6 and IPv4-mapped peers", () => {
    expect(isTrustedProxy("127.0.0.1", TRUSTED)).toBe(true);
    expect(isTrustedProxy("172.18.0.5", TRUSTED)).toBe(true);
    expect(isTrustedProxy("::1", TRUSTED)).toBe(true);
    expect(isTrustedProxy("::ffff:172.18.0.5", TRUSTED)).toBe(true);
    expect(isTrustedProxy("203.0.113.9", TRUSTED)).toBe(false);
  });
});
