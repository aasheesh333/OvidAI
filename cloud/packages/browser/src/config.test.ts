import { describe, expect, it } from "vitest";

import { loadBrowserEngineConfig } from "./config.js";

/** A minimal env with nothing set — defaults must come out. */
function bareEnv(): NodeJS.ProcessEnv {
  return {};
}

describe("loadBrowserEngineConfig defaults", () => {
  it("returns the exact default admission numbers and screencast shape", () => {
    const cfg = loadBrowserEngineConfig(bareEnv());
    expect(cfg.maxLiveBrowsers).toBe(4);
    expect(cfg.tier1FallbackContexts).toBe(2);
    expect(cfg.idleEvictMs).toBe(180_000);
    expect(cfg.maxTier1Processes).toBe(8);
    expect(cfg.tier1TimeoutMs).toBe(20_000);
    expect(cfg.maxActiveScreencasts).toBe(3);
    expect(cfg.screencastLoadMax).toBe(6.0);
    expect(cfg.screencast).toEqual({
      width: 1280,
      height: 800,
      quality: 60,
      everyNthFrame: 2,
      maxFramesInFlight: 2,
    });
    expect(cfg.stateDir).toBeNull();
    expect(cfg.lightpandaBin).toBeNull();
    expect(cfg.allowHosts).toEqual([]);
    expect(cfg.ownPublicIp).toBeNull();
    expect(cfg.chromiumArgs).toEqual(["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"]);
  });
});

describe("loadBrowserEngineConfig overrides", () => {
  it("MAX_LIVE_BROWSERS=6 overrides the default", () => {
    const cfg = loadBrowserEngineConfig({ MAX_LIVE_BROWSERS: "6" });
    expect(cfg.maxLiveBrowsers).toBe(6);
  });

  it("OVID_BROWSER_ALLOW_HOSTS splits on commas and trims", () => {
    const cfg = loadBrowserEngineConfig({ OVID_BROWSER_ALLOW_HOSTS: "a.com, b.com" });
    expect(cfg.allowHosts).toEqual(["a.com", "b.com"]);
  });

  it("OVID_BROWSER_STATE_DIR / OVID_LIGHTPANDA_BIN / OVID_PUBLIC_IP are honored", () => {
    const cfg = loadBrowserEngineConfig({
      OVID_BROWSER_STATE_DIR: "/var/lib/ovid/browser",
      OVID_LIGHTPANDA_BIN: "/usr/local/bin/lightpanda",
      OVID_PUBLIC_IP: "203.0.113.7",
    });
    expect(cfg.stateDir).toBe("/var/lib/ovid/browser");
    expect(cfg.lightpandaBin).toBe("/usr/local/bin/lightpanda");
    expect(cfg.ownPublicIp).toBe("203.0.113.7");
  });

  it("unset OVID_LIGHTPANDA_BIN stays null", () => {
    const cfg = loadBrowserEngineConfig({ MAX_LIVE_BROWSERS: "2" });
    expect(cfg.lightpandaBin).toBeNull();
  });
});

describe("loadBrowserEngineConfig malformed input", () => {
  it("MAX_LIVE_BROWSERS=abc throws naming the variable", () => {
    expect(() => loadBrowserEngineConfig({ MAX_LIVE_BROWSERS: "abc" })).toThrow(
      /MAX_LIVE_BROWSERS/,
    );
  });

  it("BROWSER_IDLE_EVICT_MS=-1 throws (must be a positive integer)", () => {
    expect(() => loadBrowserEngineConfig({ BROWSER_IDLE_EVICT_MS: "-1" })).toThrow(
      /BROWSER_IDLE_EVICT_MS/,
    );
  });

  it("OVID_SCREENCAST_LOAD_MAX=not-a-number throws naming the variable", () => {
    expect(() => loadBrowserEngineConfig({ OVID_SCREENCAST_LOAD_MAX: "nope" })).toThrow(
      /OVID_SCREENCAST_LOAD_MAX/,
    );
  });
});
