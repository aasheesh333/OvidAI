import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { DEFAULT_SANDBOX_LIMITS, loadSandboxConfig } from "./config.js";

// <package root>/bin/sandbox-enter.sh, as resolved by config.ts via
// import.meta.url — same computation from this file's location in src/.
const DEFAULT_LAUNCHER = fileURLToPath(new URL("../bin/sandbox-enter.sh", import.meta.url));

describe("loadSandboxConfig", () => {
  it("defaults to the pinned production values", () => {
    expect(loadSandboxConfig({})).toEqual({
      workspacesRoot: "/workspaces/users",
      rootfsPath: "/opt/ovid-rootfs/current",
      cgroupRoot: "/sys/fs/cgroup",
      cgroupBase: "ovid-sandboxes.slice/ovid-worker.service",
      uidBase: 200_000,
      uidMax: 209_999,
      maxActiveSandboxes: 24,
      acquireTimeoutMs: 60_000,
      workspaceQuotaMb: 500,
      proWorkspaceQuotaMb: 2048,
      storeQuotaMb: 2048,
      maxWarmGb: 8,
      minFreeGb: 2,
      limits: {
        cpuMax: "100000 100000",
        memoryMaxBytes: 536_870_912,
        memorySwapMaxBytes: 0,
        pidsMax: 64,
      },
      sandboxDns: ["1.1.1.1", "9.9.9.9"],
      bwrapPath: "/usr/bin/bwrap",
      launcherPath: DEFAULT_LAUNCHER,
      launch: "setuid",
    });
  });

  it("DEFAULT_SANDBOX_LIMITS pins the cgroup limit values", () => {
    expect(DEFAULT_SANDBOX_LIMITS.cpuMax).toBe("100000 100000");
    expect(DEFAULT_SANDBOX_LIMITS.memoryMaxBytes).toBe(536_870_912);
    expect(DEFAULT_SANDBOX_LIMITS.memorySwapMaxBytes).toBe(0);
    expect(DEFAULT_SANDBOX_LIMITS.pidsMax).toBe(64);
  });

  it("applies every env override", () => {
    const cfg = loadSandboxConfig({
      OVID_WORKSPACES_ROOT: "/srv/ws",
      OVID_ROOTFS: "/srv/rootfs",
      OVID_CGROUP_ROOT: "/cgroup2",
      OVID_CGROUP_BASE: "ovid.slice/worker.slice",
      OVID_SANDBOX_UID_BASE: "300000",
      OVID_SANDBOX_UID_MAX: "305000",
      OVID_MAX_ACTIVE_SANDBOXES: "8",
      OVID_ACQUIRE_TIMEOUT_MS: "2500",
      OVID_WORKSPACE_QUOTA_MB: "128",
      OVID_PRO_WORKSPACE_QUOTA_MB: "512",
      OVID_STORE_QUOTA_MB: "1024",
      OVID_MAX_WARM_GB: "2",
      OVID_SANDBOX_CPU_MAX: "50000 25000",
      OVID_SANDBOX_MEMORY_MAX_MB: "256",
      OVID_SANDBOX_SWAP_MAX_MB: "64",
      OVID_SANDBOX_PIDS_MAX: "32",
      OVID_SANDBOX_DNS: "10.0.0.1, 10.0.0.2",
      OVID_BWRAP_PATH: "/usr/local/bin/bwrap",
      OVID_SANDBOX_LAUNCHER: "/opt/ovid/sandbox-enter.sh",
      OVID_SANDBOX_LAUNCH: "rootmap",
    });
    expect(cfg.workspacesRoot).toBe("/srv/ws");
    expect(cfg.rootfsPath).toBe("/srv/rootfs");
    expect(cfg.cgroupRoot).toBe("/cgroup2");
    expect(cfg.cgroupBase).toBe("ovid.slice/worker.slice");
    expect(cfg.uidBase).toBe(300_000);
    expect(cfg.uidMax).toBe(305_000);
    expect(cfg.maxActiveSandboxes).toBe(8);
    expect(cfg.acquireTimeoutMs).toBe(2_500);
    expect(cfg.workspaceQuotaMb).toBe(128);
    expect(cfg.proWorkspaceQuotaMb).toBe(512);
    expect(cfg.storeQuotaMb).toBe(1024);
    expect(cfg.maxWarmGb).toBe(2);
    expect(cfg.limits).toEqual({
      cpuMax: "50000 25000",
      memoryMaxBytes: 256 * 1024 * 1024,
      memorySwapMaxBytes: 64 * 1024 * 1024,
      pidsMax: 32,
    });
    expect(cfg.sandboxDns).toEqual(["10.0.0.1", "10.0.0.2"]);
    expect(cfg.bwrapPath).toBe("/usr/local/bin/bwrap");
    expect(cfg.launcherPath).toBe("/opt/ovid/sandbox-enter.sh");
    expect(cfg.launch).toBe("rootmap");
    expect(cfg.minFreeGb).toBe(2); // fixed in v1 — never env-tunable
  });

  it("uid base is configurable (G4): staging 220000 widens the whole range", () => {
    // Base alone: uidMax follows at base+9999 (staging per P10).
    const baseOnly = loadSandboxConfig({ OVID_SANDBOX_UID_BASE: "220000" });
    expect(baseOnly.uidBase).toBe(220_000);
    expect(baseOnly.uidMax).toBe(229_999);

    // Base + explicit max agreeing on the same range → identical result.
    const explicitMax = loadSandboxConfig({
      OVID_SANDBOX_UID_BASE: "220000",
      OVID_SANDBOX_UID_MAX: "229999",
    });
    expect(explicitMax.uidBase).toBe(220_000);
    expect(explicitMax.uidMax).toBe(229_999);

    // 199999 is ABOVE the 100000 floor (the brief's malformed-list entry
    // calling it "below the 100000 floor" is arithmetically wrong): per the
    // binding G4 ruling it is a valid base, with the default width on top.
    const base199999 = loadSandboxConfig({ OVID_SANDBOX_UID_BASE: "199999" });
    expect(base199999.uidBase).toBe(199_999);
    expect(base199999.uidMax).toBe(209_998);
  });

  it("throws naming the variable on malformed values", () => {
    const cases: Array<[NodeJS.ProcessEnv, RegExp]> = [
      [{ OVID_MAX_ACTIVE_SANDBOXES: "0" }, /OVID_MAX_ACTIVE_SANDBOXES/],
      // Below the 100000 floor. (The brief listed 199999 as "below the
      // 100000 floor" — arithmetically false: 199999 >= 100000, so per the
      // binding G4 ruling (uidBase>=100000, base-relative width) it is a
      // VALID base, asserted below. 99999 is the genuinely-below-floor case.)
      [{ OVID_SANDBOX_UID_BASE: "99999" }, /OVID_SANDBOX_UID_BASE/],
      [{ OVID_SANDBOX_UID_BASE: "abc" }, /OVID_SANDBOX_UID_BASE/],
      // Width > 9999 above the configured base.
      [{ OVID_SANDBOX_UID_BASE: "220000", OVID_SANDBOX_UID_MAX: "230000" }, /OVID_SANDBOX_UID_MAX/],
      // uidMax must strictly exceed uidBase.
      [{ OVID_SANDBOX_UID_BASE: "220000", OVID_SANDBOX_UID_MAX: "220000" }, /OVID_SANDBOX_UID_MAX/],
      // Below the default base (200000).
      [{ OVID_SANDBOX_UID_MAX: "199999" }, /OVID_SANDBOX_UID_MAX/],
      [{ OVID_SANDBOX_LAUNCH: "nope" }, /OVID_SANDBOX_LAUNCH/],
      [{ OVID_SANDBOX_DNS: "" }, /OVID_SANDBOX_DNS/],
      [{ OVID_SANDBOX_DNS: "1.1.1.1,," }, /OVID_SANDBOX_DNS/],
      [{ OVID_SANDBOX_PIDS_MAX: "0" }, /OVID_SANDBOX_PIDS_MAX/],
      [{ OVID_SANDBOX_MEMORY_MAX_MB: "-1" }, /OVID_SANDBOX_MEMORY_MAX_MB/],
      [{ OVID_SANDBOX_SWAP_MAX_MB: "-1" }, /OVID_SANDBOX_SWAP_MAX_MB/],
      [{ OVID_ACQUIRE_TIMEOUT_MS: "soon" }, /OVID_ACQUIRE_TIMEOUT_MS/],
      [{ OVID_WORKSPACE_QUOTA_MB: "1.5" }, /OVID_WORKSPACE_QUOTA_MB/],
      [{ OVID_MAX_WARM_GB: "0" }, /OVID_MAX_WARM_GB/],
    ];
    for (const [env, pattern] of cases) {
      expect(() => loadSandboxConfig(env), JSON.stringify(env)).toThrow(pattern);
    }
  });

  it("minFreeGb is fixed at 2 in v1 (not env-tunable)", () => {
    expect(loadSandboxConfig({ OVID_MIN_FREE_GB: "99" }).minFreeGb).toBe(2);
  });
});
