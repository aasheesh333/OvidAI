import { describe, expect, it, vi } from "vitest";

import type { BrowserEngineConfig } from "./config.js";
import { assertPublicHost, createSsrfGuardedFetch, navigableUrlReason, SsrfError } from "./url.js";

const cfg = (over: Partial<BrowserEngineConfig> = {}): Pick<
  BrowserEngineConfig,
  "allowHosts" | "ownPublicIp"
> => ({
  allowHosts: over.allowHosts ?? [],
  ownPublicIp: over.ownPublicIp ?? null,
});

describe("navigableUrlReason", () => {
  it("refuses file: with copy naming the tool and scheme", () => {
    const reason = navigableUrlReason("file:///etc/passwd", "browser_open");
    expect(reason).toBeTruthy();
    expect(reason!).toContain("browser_open");
    expect(reason!).toContain("file:");
  });

  it("refuses javascript: URLs", () => {
    expect(navigableUrlReason("javascript:alert(1)", "browser_open")).toBeTruthy();
  });

  it("refuses other non-http schemes (data:, ftp:)", () => {
    expect(navigableUrlReason("data:text/html,hi", "browser_open")).toBeTruthy();
    expect(navigableUrlReason("ftp://x.test/f", "browser_navigate")).toBeTruthy();
  });

  it("allows https and http", () => {
    expect(navigableUrlReason("https://x.test", "browser_open")).toBeNull();
    expect(navigableUrlReason("http://x.test", "browser_open")).toBeNull();
  });

  it("allows scheme-less relative URLs (empty scheme)", () => {
    expect(navigableUrlReason("/docs/page", "browser_open")).toBeNull();
    expect(navigableUrlReason("page.html", "browser_open")).toBeNull();
  });
});

describe("assertPublicHost", () => {
  it("allows 127.0.0.1 when it is in allowHosts", async () => {
    await expect(
      assertPublicHost("http://127.0.0.1:3000/x", cfg({ allowHosts: ["127.0.0.1"] })),
    ).resolves.toBeUndefined();
  });

  it("throws SsrfError for 127.0.0.1 when allowHosts is empty", async () => {
    await expect(assertPublicHost("http://127.0.0.1:3000/x", cfg())).rejects.toBeInstanceOf(
      SsrfError,
    );
  });

  it("throws for the cloud metadata address", async () => {
    await expect(
      assertPublicHost("http://169.254.169.254/latest/meta-data/", cfg()),
    ).rejects.toBeInstanceOf(SsrfError);
  });

  it("throws for RFC1918, CGNAT, loopback-IPv6 and IPv4-mapped IPv6 targets", async () => {
    const blocked = [
      "http://10.0.0.5/",
      "http://192.168.1.1/",
      "http://172.16.0.1/",
      "http://100.64.0.1/",
      "http://[::1]/",
      "http://[::ffff:10.0.0.1]/",
      "http://[fe80::1]/",
      "http://[fc00::1]/",
    ];
    for (const url of blocked) {
      await expect(assertPublicHost(url, cfg())).rejects.toBeInstanceOf(SsrfError);
    }
  });

  it("blocks a host whose DNS resolution returns a private address", async () => {
    const lookup = async () => ["203.0.113.9", "172.16.0.9"];
    await expect(
      assertPublicHost("https://evil.example/", cfg(), lookup),
    ).rejects.toBeInstanceOf(SsrfError);
  });

  it("allows a host resolving only to public addresses", async () => {
    const lookup = async () => ["203.0.113.9"];
    await expect(assertPublicHost("https://ok.example/", cfg(), lookup)).resolves.toBeUndefined();
  });

  it("blocks the host's own public IP (SSRF self-block)", async () => {
    await expect(
      assertPublicHost("http://203.0.113.7/", cfg({ ownPublicIp: "203.0.113.7" })),
    ).rejects.toBeInstanceOf(SsrfError);
  });

  it("allowHosts bypass is an exact host match only", async () => {
    await expect(
      assertPublicHost("http://evil-127.0.0.1.attacker.test/", cfg({ allowHosts: ["127.0.0.1"] })),
    ).rejects.toBeInstanceOf(SsrfError);
  });
});

describe("createSsrfGuardedFetch", () => {
  it("rejects a private-IP URL without calling the transport fetch", async () => {
    const fetchImpl = vi.fn(async () => new Response("nope"));
    const guarded = createSsrfGuardedFetch(cfg(), fetchImpl);
    await expect(guarded("http://10.0.0.5/secret")).rejects.toBeInstanceOf(SsrfError);
    expect(fetchImpl).toHaveBeenCalledTimes(0);
  });

  it("passes public URLs through to the transport fetch", async () => {
    const fetchImpl = vi.fn(async () => new Response("ok"));
    const guarded = createSsrfGuardedFetch(cfg(), fetchImpl);
    // A public literal IP (TEST-NET-3): deterministic, no DNS needed — the
    // guard is fail-closed on unresolvable names, so a name-based URL here
    // would depend on the runner's resolver.
    const res = await guarded("https://203.0.113.9/");
    expect(res.status).toBe(200);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(fetchImpl).toHaveBeenCalledWith("https://203.0.113.9/");
  });
});
