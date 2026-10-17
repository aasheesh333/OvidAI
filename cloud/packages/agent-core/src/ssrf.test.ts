import { afterEach, describe, expect, it } from "vitest";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";

import {
  SsrfBlockedError,
  createGuardedEgressFetch,
  createSsrfGuard,
  isMetadataOrLinkLocalAddress,
  isNonPublicAddress,
  type SsrfGuard,
} from "./ssrf.js";

// Ported case-by-case from test/security_ssrf_guard_test.dart and the scheme
// cases of test/browser_scheme_guard_test.dart. Where the Dart suite and the
// task brief disagree (resolver failure), the brief wins: fail-closed.

/** Dart: SsrfGuard.resolverForTest — a table-backed stub resolver. */
function guardResolvingTo(
  table: Record<string, string[]>,
  o?: { lookupTimeoutMs?: number },
): SsrfGuard {
  return createSsrfGuard({
    resolver: (host) => Promise.resolve(table[host] ?? []),
    lookupTimeoutMs: o?.lookupTimeoutMs,
  });
}

describe("isNonPublicAddress — Dart address classification table", () => {
  const nonPublic = [
    // IPv4
    "0.0.0.0", "0.1.2.3", "10.0.0.1", "10.255.255.255",
    "100.64.0.1", "100.100.100.200", "100.127.255.254",
    "127.0.0.1", "127.8.9.10", "169.254.169.254", "169.254.0.1",
    "172.16.0.1", "172.31.255.255", "192.0.0.8", "192.168.1.1",
    "198.18.0.1", "198.19.255.255", "224.0.0.1", "239.255.255.250",
    "240.0.0.1", "255.255.255.255",
    // IPv6
    "::", "::1", "fc00::1", "fd12:3456::1", "fe80::1", "febf::1",
    "fec0::1", "ff02::1",
    // IPv4-embedding IPv6 forms
    "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:169.254.169.254",
    "::ffff:100.64.0.1", "::127.0.0.1", "64:ff9b::a9fe:a9fe",
    "64:ff9b::7f00:1", "2002:7f00:1::1", "2002:c0a8:101::1",
  ];
  const publicAddresses = [
    "1.1.1.1", "8.8.8.8", "93.184.216.34", "100.63.255.255",
    "100.128.0.1", "172.15.255.255", "172.32.0.1", "192.0.1.1",
    "192.169.0.1", "198.17.0.1", "198.20.0.1", "223.255.255.254",
    "2606:4700:4700::1111", "2001:4860:4860::8888", "::ffff:8.8.8.8",
    "64:ff9b::808:808", "2002:808:808::1", "fbff::1", "fe7f::1",
  ];

  for (const a of nonPublic) {
    it(`${a} is non-public`, () => {
      expect(isNonPublicAddress(a)).toBe(true);
    });
  }
  for (const a of publicAddresses) {
    it(`${a} is public`, () => {
      expect(isNonPublicAddress(a)).toBe(false);
    });
  }

  it("bracketed / trailing-dot / unparseable inputs fail closed", () => {
    expect(isNonPublicAddress("[::1]")).toBe(true);
    expect(isNonPublicAddress("[::ffff:10.0.0.1]")).toBe(true);
    expect(isNonPublicAddress("10.0.0.1.")).toBe(true);
    expect(isNonPublicAddress("not-an-ip")).toBe(true);
    expect(isNonPublicAddress("")).toBe(true);
  });
});

describe("isMetadataOrLinkLocalAddress — Dart metadata subset", () => {
  it("detects the metadata/link-local family", () => {
    for (const a of [
      "169.254.169.254",
      "100.100.100.200",
      "fe80::1",
      "::ffff:169.254.169.254",
      "64:ff9b::a9fe:a9fe",
      "[fe80::1]",
    ]) {
      expect(isMetadataOrLinkLocalAddress(a)).toBe(true);
    }
  });

  it("loopback, LAN, ULA and public addresses are not metadata", () => {
    for (const a of ["127.0.0.1", "10.0.0.1", "8.8.8.8", "fd00::1", "100.64.0.1"]) {
      expect(isMetadataOrLinkLocalAddress(a)).toBe(false);
    }
  });
});

describe("checkHost — DNS resolution (stub resolver)", () => {
  it("a name with ANY internal address is refused", async () => {
    const guard = guardResolvingTo({
      "mixed.example": ["93.184.216.34", "10.0.0.5"],
      "mapped.example": ["::ffff:127.0.0.1"],
      "cgnat.example": ["100.64.1.1"],
      "ula.example": ["fd00::5"],
      "public.example": ["93.184.216.34", "2606:4700::1"],
    });
    for (const host of [
      "mixed.example",
      "mapped.example",
      "cgnat.example",
      "ula.example",
      "localhost",
      "api.localhost",
    ]) {
      expect(await guard.checkHost(host)).toBe(false);
    }
    expect(await guard.checkHost("public.example")).toBe(true);
    expect(await guard.checkHost("[::1]")).toBe(false);
  });

  it("resolver failure refuses (fail-closed)", async () => {
    const guard = createSsrfGuard({
      resolver: () => Promise.reject(new Error("ENOTFOUND")),
    });
    expect(await guard.checkHost("nx.example")).toBe(false);
    await expect(guard.assertSafeUrl("http://nx.example/")).rejects.toBeInstanceOf(SsrfBlockedError);
  });

  it("an empty resolver result refuses (fail-closed)", async () => {
    const guard = guardResolvingTo({});
    expect(await guard.checkHost("empty.example")).toBe(false);
  });

  it("a resolver hanging past lookupTimeoutMs refuses", async () => {
    const guard = createSsrfGuard({
      resolver: () => new Promise<string[]>(() => {}),
      lookupTimeoutMs: 25,
    });
    expect(await guard.checkHost("slow.example")).toBe(false);
    await expect(guard.assertSafeUrl("http://slow.example/")).rejects.toBeInstanceOf(SsrfBlockedError);
  });
});

describe("assertSafeUrl — literals, schemes and ports", () => {
  const guard = guardResolvingTo({
    "example.com": ["93.184.216.34"],
  });

  it("non-public literals are blocked with the address named in the message", async () => {
    for (const url of [
      "http://10.0.0.1/",
      "http://192.168.1.1/",
      "http://169.254.169.254/latest/meta-data/",
      "http://127.0.0.1:8080/",
      "http://[::1]/",
      "http://[fd00::1]/",
      "http://[::ffff:127.0.0.1]/",
      "http://[fe80::1]/",
      "http://100.64.0.1/",
      "http://0.0.0.0/",
      "http://api.localhost/",
    ]) {
      const err = await guard.assertSafeUrl(url).then(
        () => null,
        (e: unknown) => e,
      );
      expect(err, url).toBeInstanceOf(SsrfBlockedError);
    }
    const message = await guard
      .assertSafeUrl("http://169.254.169.254/latest/meta-data/")
      .then(
        () => "",
        (e: unknown) => String((e as Error).message),
      );
    expect(message).toContain("169.254.169.254");
  });

  it("a public literal passes and returns the parsed URL", async () => {
    const url = await guard.assertSafeUrl("https://93.184.216.34/");
    expect(url).toBeInstanceOf(URL);
    expect(url.hostname).toBe("93.184.216.34");
  });

  it("decimal/hex IPv4 shorthands are normalized by the URL parser and blocked", async () => {
    await expect(guard.assertSafeUrl("http://2130706433/")).rejects.toBeInstanceOf(SsrfBlockedError);
    await expect(guard.assertSafeUrl("http://0x7f000001/")).rejects.toBeInstanceOf(SsrfBlockedError);
  });

  it("non-http(s) schemes are refused", async () => {
    for (const url of [
      "file:///etc/passwd",
      "ftp://example.com/pub",
      "gopher://example.com/",
      "javascript:alert(1)",
      "data:text/html,<script>alert(1)</script>",
    ]) {
      await expect(guard.assertSafeUrl(url)).rejects.toBeInstanceOf(SsrfBlockedError);
    }
    await expect(guard.assertSafeUrl("ftp://example.com/")).rejects.toThrow(/ftp/);
  });

  it("only ports 80 and 443 (explicit or default) are allowed", async () => {
    await expect(guard.assertSafeUrl("https://example.com:8443/")).rejects.toBeInstanceOf(SsrfBlockedError);
    await expect(guard.assertSafeUrl("http://example.com:8080/")).rejects.toBeInstanceOf(SsrfBlockedError);
    await expect(guard.assertSafeUrl("http://example.com:8443/")).rejects.toThrow(/8443/);
    await expect(guard.assertSafeUrl("http://example.com:80/")).resolves.toBeInstanceOf(URL);
    await expect(guard.assertSafeUrl("https://example.com:443/")).resolves.toBeInstanceOf(URL);
    await expect(guard.assertSafeUrl("http://example.com/")).resolves.toBeInstanceOf(URL);
    await expect(guard.assertSafeUrl("https://example.com/")).resolves.toBeInstanceOf(URL);
  });

  it("an unparseable URL is refused", async () => {
    await expect(guard.assertSafeUrl("http://")).rejects.toBeInstanceOf(SsrfBlockedError);
    await expect(guard.assertSafeUrl("::::")).rejects.toBeInstanceOf(SsrfBlockedError);
  });
});

describe("createGuardedEgressFetch — live redirect handling", () => {
  // The Dart suite runs this against a MockClient; here a real local
  // http.createServer stands in for both the allowed origin and the redirect
  // chain. The guard is stubbed allow-all-except-metadata because the test
  // server necessarily lives on 127.0.0.1 (non-public, but the only thing
  // under test is the redirect policing).
  const stubGuard: SsrfGuard = {
    async assertSafeUrl(rawUrl: string): Promise<URL> {
      const url = new URL(rawUrl);
      if (isMetadataOrLinkLocalAddress(url.hostname)) {
        throw new SsrfBlockedError(`metadata/link-local host is always refused: ${url.hostname}`);
      }
      return url;
    },
    async checkHost(host: string): Promise<boolean> {
      return !isMetadataOrLinkLocalAddress(host);
    },
  };

  const openServers: Array<() => void> = [];
  afterEach(() => {
    for (const close of openServers.splice(0)) close();
  });

  function startServer(
    handler: (req: IncomingMessage, res: ServerResponse) => void,
  ): Promise<{ origin: string; requestCount: () => number }> {
    let count = 0;
    const server = createServer((req, res) => {
      count += 1;
      handler(req, res);
    });
    const ready = new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    openServers.push(() => {
      server.closeAllConnections();
      server.close();
    });
    return ready.then(() => {
      const { port } = server.address() as AddressInfo;
      return { origin: `http://127.0.0.1:${port}`, requestCount: () => count };
    });
  }

  it("follows a 302 to another allowed host", async () => {
    const target = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("ok-landing");
    });
    const source = await startServer((_req, res) => {
      res.writeHead(302, { location: `${target.origin}/landing` });
      res.end();
    });
    const egress = createGuardedEgressFetch(stubGuard);
    const res = await egress(`${source.origin}/start`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok-landing");
    expect(target.requestCount()).toBe(1);
  });

  it("blocks a 302 to the cloud metadata address", async () => {
    const source = await startServer((_req, res) => {
      res.writeHead(302, { location: "http://169.254.169.254/latest/meta-data/" });
      res.end();
    });
    const egress = createGuardedEgressFetch(stubGuard);
    const err = await egress(`${source.origin}/start`).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(SsrfBlockedError);
    expect((err as Error).message).toContain("169.254.169.254");
    expect(source.requestCount()).toBe(1);
  });

  it("refuses after maxRedirects (default 5) chained redirects", async () => {
    let hops = 0;
    const source = await startServer((_req, res) => {
      hops += 1;
      res.writeHead(302, { location: `/hop-${hops}` });
      res.end();
    });
    const egress = createGuardedEgressFetch(stubGuard);
    const err = await egress(`${source.origin}/start`).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(SsrfBlockedError);
    expect((err as Error).message).toContain("redirect");
    expect(source.requestCount()).toBe(6);
  });

  it("honors an explicit maxRedirects", async () => {
    const target = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("end");
    });
    const source = await startServer((_req, res) => {
      res.writeHead(302, { location: `${target.origin}/end` });
      res.end();
    });
    const egress = createGuardedEgressFetch(stubGuard, fetch, 0);
    await expect(egress(`${source.origin}/start`)).rejects.toBeInstanceOf(SsrfBlockedError);
    expect(target.requestCount()).toBe(0);
  });

  it("passes the AbortSignal through to the transport", async () => {
    const source = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("never");
    });
    const controller = new AbortController();
    controller.abort();
    const egress = createGuardedEgressFetch(stubGuard);
    await expect(egress(`${source.origin}/start`, { signal: controller.signal })).rejects.toThrow();
    expect(source.requestCount()).toBe(0);
  });
});
