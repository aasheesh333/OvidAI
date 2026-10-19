import { describe, expect, it } from "vitest";

import {
  loadBrowserEngineConfig,
  parseBrowserUidEnv,
  parseSandboxUidRange,
} from "./config.js";

/** A minimal env with nothing set — defaults must come out. */
function bareEnv(): NodeJS.ProcessEnv {
  return {};
}

describe("screencast frame-rate cap (Wave 5 R3)", () => {
  it("OVID_SCREENCAST_MAX_FPS overrides the 4 fps default", () => {
    expect(loadBrowserEngineConfig({ OVID_SCREENCAST_MAX_FPS: "5" }).screencast.maxFps).toBe(5);
  });

  it("a malformed OVID_SCREENCAST_MAX_FPS fails fast naming the variable", () => {
    expect(() => loadBrowserEngineConfig({ OVID_SCREENCAST_MAX_FPS: "fast" })).toThrow(/OVID_SCREENCAST_MAX_FPS/);
  });
});

describe("loadBrowserEngineConfig defaults", () => {
  it("returns the exact default admission numbers and screencast shape", () => {
    const cfg = loadBrowserEngineConfig(bareEnv());
    expect(cfg.maxLiveBrowsers).toBe(4);
    expect(cfg.tier1FallbackContexts).toBe(2);
    // Muse ephemeral step leases: a context freezes after 15 s idle.
    expect(cfg.idleEvictMs).toBe(15_000);
    expect(cfg.maxTier1Processes).toBe(8);
    expect(cfg.tier1TimeoutMs).toBe(20_000);
    expect(cfg.maxActiveScreencasts).toBe(3);
    expect(cfg.screencastLoadMax).toBe(6.0);
    expect(cfg.screencast).toEqual({
      width: 1280,
      height: 800,
      quality: 60,
      everyNthFrame: 2,
      // Wave 5 R3: one frame in flight + a 4 fps cap ⇒ the effective live
      // view is 3–5 fps and chromium never encodes frames nobody will see.
      maxFramesInFlight: 1,
      maxFps: 4,
    });
    expect(cfg.stateDir).toBeNull();
    expect(cfg.lightpandaBin).toBeNull();
    expect(cfg.allowHosts).toEqual([]);
    expect(cfg.ownPublicIp).toBeNull();
    // Resource diet: a small V8 heap, two renderers, no background work.
    expect(cfg.blockHeavyResources).toBe(true);
    expect(cfg.chromiumArgs).toEqual([
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--js-flags=--max-old-space-size=96",
      "--renderer-process-limit=2",
      "--disable-extensions",
      "--disable-background-networking",
      "--disable-component-update",
      "--disable-default-apps",
      "--disable-sync",
      "--mute-audio",
      "--no-first-run",
      "--no-default-browser-check",
    ]);
    // No dedicated uid in dev/test by default; production refuses this.
    expect(cfg.egressUid).toBeNull();
    expect(cfg.browserUidRange).toBeNull();
    expect(cfg.sandboxUidRange).toEqual([200_000, 209_999]);
    expect(cfg.uidDropMode).toBe("auto");
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

describe("browser egress uid validation", () => {
  it("single uid and range are parsed; the range's first uid is the engine uid", () => {
    const single = loadBrowserEngineConfig({ OVID_BROWSER_EGRESS_UID: "230000" });
    expect(single.egressUid).toBe(230_000);
    expect(single.browserUidRange).toEqual([230_000, 230_000]);

    const ranged = loadBrowserEngineConfig({ OVID_BROWSER_EGRESS_UID: "230000-230099" });
    expect(ranged.egressUid).toBe(230_000);
    expect(ranged.browserUidRange).toEqual([230_000, 230_099]);
  });

  it("rejects uids below the 100000 floor, naming OVID_BROWSER_EGRESS_UID", () => {
    for (const bad of ["0", "99999", "1", "99999-100000"]) {
      expect(() => loadBrowserEngineConfig({ OVID_BROWSER_EGRESS_UID: bad }), bad).toThrow(
        /OVID_BROWSER_EGRESS_UID/,
      );
    }
  });

  it("rejects the production sandbox block (200000-209999) and its edges", () => {
    for (const bad of ["200000", "205000", "209999", "205000-205999"]) {
      let err: unknown;
      try {
        loadBrowserEngineConfig({ OVID_BROWSER_EGRESS_UID: bad });
      } catch (e) {
        err = e;
      }
      expect(err, bad).toBeInstanceOf(Error);
      expect((err as Error).message, bad).toMatch(/overlaps the sandbox uid block/);
    }
    // Just outside the block is valid.
    expect(loadBrowserEngineConfig({ OVID_BROWSER_EGRESS_UID: "210000" }).egressUid).toBe(210_000);
    expect(loadBrowserEngineConfig({ OVID_BROWSER_EGRESS_UID: "199999" }).egressUid).toBe(199_999);
  });

  it("rejects the staging sandbox block (220000-229999) configured via the same env", () => {
    const env = {
      OVID_SANDBOX_UID_BASE: "220000",
      OVID_SANDBOX_UID_MAX: "229999",
    };
    expect(() =>
      loadBrowserEngineConfig({ ...env, OVID_BROWSER_EGRESS_UID: "225000" }),
    ).toThrow(/overlaps the sandbox uid block/);
    const cfg = loadBrowserEngineConfig({ ...env, OVID_BROWSER_EGRESS_UID: "230000" });
    expect(cfg.egressUid).toBe(230_000);
    expect(cfg.sandboxUidRange).toEqual([220_000, 229_999]);
  });

  it("malformed values throw naming the variable", () => {
    for (const bad of ["abc", "230000-", "-230000", "230099-230000", "23a000", "1.5"]) {
      expect(() => loadBrowserEngineConfig({ OVID_BROWSER_EGRESS_UID: bad }), bad).toThrow(
        /OVID_BROWSER_EGRESS_UID/,
      );
    }
  });

  it("production REQUIRES a dedicated uid (never silently root)", () => {
    expect(() =>
      loadBrowserEngineConfig({ NODE_ENV: "production" }),
    ).toThrow(/OVID_BROWSER_EGRESS_UID is required when NODE_ENV=production/);
    const cfg = loadBrowserEngineConfig({
      NODE_ENV: "production",
      OVID_BROWSER_EGRESS_UID: "230000",
    });
    expect(cfg.egressUid).toBe(230_000);
  });

  it("dev/test defaults to no drop, but required/disabled modes are explicit", () => {
    // dev auto without a uid: no drop.
    expect(loadBrowserEngineConfig({}).egressUid).toBeNull();
    // required without a uid: refuse.
    expect(() =>
      loadBrowserEngineConfig({ OVID_BROWSER_UID_DROP: "required" }),
    ).toThrow(/OVID_BROWSER_EGRESS_UID is required when OVID_BROWSER_UID_DROP=required/);
    // disabled with a uid: contradictory — the nftables rule would be inert.
    expect(() =>
      loadBrowserEngineConfig({
        OVID_BROWSER_EGRESS_UID: "230000",
        OVID_BROWSER_UID_DROP: "disabled",
      }),
    ).toThrow(/would be inert/);
    // disabled is a dev/test escape hatch only.
    expect(() =>
      loadBrowserEngineConfig({ NODE_ENV: "production", OVID_BROWSER_UID_DROP: "disabled" }),
    ).toThrow(/refused when NODE_ENV=production/);
    expect(
      loadBrowserEngineConfig({ NODE_ENV: "development", OVID_BROWSER_UID_DROP: "disabled" })
        .egressUid,
    ).toBeNull();
  });

  it("unknown OVID_BROWSER_UID_DROP values throw", () => {
    expect(() => loadBrowserEngineConfig({ OVID_BROWSER_UID_DROP: "yes" })).toThrow(
      /OVID_BROWSER_UID_DROP/,
    );
  });
});

describe("parseSandboxUidRange / parseBrowserUidEnv (unit)", () => {
  it("mirrors the sandbox block defaults and width validation", () => {
    expect(parseSandboxUidRange({})).toEqual([200_000, 209_999]);
    expect(() => parseSandboxUidRange({ OVID_SANDBOX_UID_BASE: "99999" })).toThrow(
      /OVID_SANDBOX_UID_BASE/,
    );
    expect(() =>
      parseSandboxUidRange({ OVID_SANDBOX_UID_BASE: "220000", OVID_SANDBOX_UID_MAX: "231000" }),
    ).toThrow(/OVID_SANDBOX_UID_MAX/);
  });

  it("parseBrowserUidEnv returns nulls for unset/empty and rejects overlap", () => {
    expect(parseBrowserUidEnv(undefined, [200_000, 209_999])).toEqual({
      uid: null,
      range: null,
    });
    expect(parseBrowserUidEnv("", [200_000, 209_999])).toEqual({ uid: null, range: null });
    expect(parseBrowserUidEnv("230000-230099", [200_000, 209_999])).toEqual({
      uid: 230_000,
      range: [230_000, 230_099],
    });
    expect(() => parseBrowserUidEnv("205000", [200_000, 209_999])).toThrow(
      /distinct uid keyspace/,
    );
  });
});
