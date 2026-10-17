import { describe, expect, it } from "vitest";
import {
  evaluateDiskPressureGate,
  evaluateWarmLruOutcome,
  runBackupGuardLeg,
  runWarmLruLeg,
  simulateWarmLruEviction,
  type BackupGuardDeps,
  type WarmLruDeps,
} from "./diskPressure.js";

/**
 * Review Focus #3 for disk-pressure: leg A only passes when the free-space
 * guard provably fired *before* any dump, and leg B only passes when the real
 * LRU engine evicted oldest-first without an ENOSPC. Fakes / injected probes
 * only — no real disk is filled here.
 */

const healthyGate = {
  mountPath: "/mnt/ovid-pressure",
  mounted: true,
  totalBytes: 256 * 1024 * 1024,
  expectedTotalBytes: 256 * 1024 * 1024,
  freeMb: 130,
  backupMinFreeMb: 200,
  hostFreeBeforeMb: 50_000,
  targetProblems: [] as string[],
};

describe("evaluateDiskPressureGate", () => {
  it("passes with the loopback mounted, free space below the guard, host healthy", () => {
    expect(evaluateDiskPressureGate(healthyGate).ok).toBe(true);
  });

  it("rejects an unmounted fixture", () => {
    const result = evaluateDiskPressureGate({ ...healthyGate, mounted: false });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("mounted");
  });

  it("rejects a fixture that is not the expected size", () => {
    expect(
      evaluateDiskPressureGate({
        ...healthyGate,
        totalBytes: 1024 * 1024 * 1024,
      }).ok,
    ).toBe(false);
  });

  it("rejects the vacuous case where free space is already above the guard", () => {
    const result = evaluateDiskPressureGate({ ...healthyGate, freeMb: 240 });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("free");
  });

  it("refuses to run when the host is nearly full", () => {
    expect(
      evaluateDiskPressureGate({ ...healthyGate, hostFreeBeforeMb: 200 }).ok,
    ).toBe(false);
  });

  it("rejects a non-staging target", () => {
    expect(
      evaluateDiskPressureGate({
        ...healthyGate,
        targetProblems: ["production backup dir"],
      }).ok,
    ).toBe(false);
  });
});

describe("runBackupGuardLeg", () => {
  const opts = {
    backupDir: "/mnt/ovid-pressure/backups",
    minFreeMb: 200,
    container: "ovid-cloud-staging-postgres-1",
    scriptPath: "/root/OvidAI/cloud/deploy/backup/pg_backup.sh",
  };

  function deps(overrides: Partial<BackupGuardDeps> = {}): BackupGuardDeps {
    return {
      runBackup: async () => ({
        exitCode: 1,
        stdout: "[backup] free 130MB (min 200MB)",
        stderr: "[backup] FATAL: only 130MB free under /mnt/ovid-pressure/backups (< 200MB required) — refusing to dump",
      }),
      listDumpRuns: async () => [],
      ...overrides,
    };
  }

  it("passes only when the guard aborts before writing a dump run", async () => {
    const assertion = await runBackupGuardLeg(deps(), opts);
    expect(assertion.passed).toBe(true);
    expect(assertion.name).toBe("backup-guard-fires");
  });

  it("fails when the script exits 0 (the guard did not fire)", async () => {
    const assertion = await runBackupGuardLeg(
      deps({
        runBackup: async () => ({ exitCode: 0, stdout: "done", stderr: "" }),
      }),
      opts,
    );
    expect(assertion.passed).toBe(false);
  });

  it("fails when the abort is not the free-space abort", async () => {
    const assertion = await runBackupGuardLeg(
      deps({
        runBackup: async () => ({
          exitCode: 1,
          stdout: "",
          stderr: "docker: command not found",
        }),
      }),
      opts,
    );
    expect(assertion.passed).toBe(false);
  });

  it("fails when a dump run directory was written before the abort", async () => {
    const assertion = await runBackupGuardLeg(
      deps({ listDumpRuns: async () => ["20261017-120000"] }),
      opts,
    );
    expect(assertion.passed).toBe(false);
    expect(assertion.detail).toContain("20261017-120000");
  });
});

describe("runWarmLruLeg", () => {
  const opts = {
    maxWarmBytes: 100 * 1024 * 1024,
    diskAlertFraction: 0.8,
    initialWarmBytes: 170 * 1024 * 1024,
    expectedOldestFirst: ["oldest", "middle", "newest"],
  };

  function deps(overrides: Partial<WarmLruDeps> = {}): WarmLruDeps {
    return {
      enforceCap: async () => ({
        evicted: 3,
        freedBytes: 170 * 1024 * 1024,
        evictedSessions: ["oldest", "middle", "newest"],
        warmBytesAfter: 0,
        errors: [],
      }),
      ...overrides,
    };
  }

  it("passes with oldest-first eviction and no ENOSPC", async () => {
    const result = await runWarmLruLeg(deps(), opts);
    expect(result.assertion.passed).toBe(true);
    expect(result.evictedSessions).toEqual(["oldest", "middle", "newest"]);
  });

  it("fails when nothing is evicted under pressure", async () => {
    const result = await runWarmLruLeg(
      deps({
        enforceCap: async () => ({
          evicted: 0,
          freedBytes: 0,
          evictedSessions: [],
          warmBytesAfter: opts.initialWarmBytes,
          errors: [],
        }),
      }),
      opts,
    );
    expect(result.assertion.passed).toBe(false);
  });

  it("fails when eviction is not oldest-first", async () => {
    const result = await runWarmLruLeg(
      deps({
        enforceCap: async () => ({
          evicted: 2,
          freedBytes: 110 * 1024 * 1024,
          evictedSessions: ["newest", "oldest"],
          warmBytesAfter: 60 * 1024 * 1024,
          errors: [],
        }),
      }),
      opts,
    );
    expect(result.assertion.passed).toBe(false);
    expect(result.assertion.detail).toContain("oldest-first");
  });

  it("fails when warm bytes remain above the cap", async () => {
    const result = await runWarmLruLeg(
      deps({
        enforceCap: async () => ({
          evicted: 1,
          freedBytes: 10 * 1024 * 1024,
          evictedSessions: ["oldest"],
          warmBytesAfter: 160 * 1024 * 1024,
          errors: [],
        }),
      }),
      opts,
    );
    expect(result.assertion.passed).toBe(false);
  });

  it("fails when the engine reports an ENOSPC error", async () => {
    const result = await runWarmLruLeg(
      deps({
        enforceCap: async () => ({
          evicted: 2,
          freedBytes: 110 * 1024 * 1024,
          evictedSessions: ["oldest", "middle"],
          warmBytesAfter: 60 * 1024 * 1024,
          errors: ["ENOSPC: no space left on device"],
        }),
      }),
      opts,
    );
    expect(result.assertion.passed).toBe(false);
    expect(result.assertion.detail).toContain("ENOSPC");
  });
});

describe("simulateWarmLruEviction (injected-capacity seam)", () => {
  const rows = [
    { sessionId: "oldest", bytes: 60 * 1024 * 1024, lastActivityMs: 1 },
    { sessionId: "middle", bytes: 50 * 1024 * 1024, lastActivityMs: 2 },
    { sessionId: "newest", bytes: 40 * 1024 * 1024, lastActivityMs: 3 },
  ];

  it("evicts oldest-first until the warm cap is met", () => {
    const result = simulateWarmLruEviction(rows, {
      maxWarmBytes: 80 * 1024 * 1024,
      diskUsedFraction: 0.1,
      diskAlertFraction: 0.8,
    });
    expect(result.evictedSessions).toEqual(["oldest", "middle"]);
    expect(result.warmBytesAfter).toBe(40 * 1024 * 1024);
    expect(result.errors).toEqual([]);
  });

  it("evicts on the disk-alert arm even when the cap is not exceeded", () => {
    const result = simulateWarmLruEviction(rows, {
      maxWarmBytes: 1024 * 1024 * 1024,
      diskUsedFraction: 0.95,
      diskAlertFraction: 0.8,
    });
    expect(result.evictedSessions.length).toBeGreaterThan(0);
    expect(result.evictedSessions[0]).toBe("oldest");
  });

  it("never throws on a full fake disk (no ENOSPC path)", () => {
    const result = simulateWarmLruEviction(rows, {
      maxWarmBytes: 0,
      diskUsedFraction: 1,
      diskAlertFraction: 0.8,
    });
    expect(result.errors).toEqual([]);
  });
});

describe("evaluateWarmLruOutcome", () => {
  it("uses a one-workspace tolerance on the warm cap", () => {
    const outcome = evaluateWarmLruOutcome({
      initialWarmBytes: 170 * 1024 * 1024,
      maxWarmBytes: 100 * 1024 * 1024,
      evictedSessions: ["oldest", "middle"],
      expectedOldestFirst: ["oldest", "middle"],
      warmBytesAfter: 105 * 1024 * 1024,
      largestRowBytes: 10 * 1024 * 1024,
      errors: [],
    });
    expect(outcome.passed).toBe(true);
  });

  it("fails when the tolerance is exceeded", () => {
    const outcome = evaluateWarmLruOutcome({
      initialWarmBytes: 170 * 1024 * 1024,
      maxWarmBytes: 100 * 1024 * 1024,
      evictedSessions: ["oldest", "middle"],
      expectedOldestFirst: ["oldest", "middle"],
      warmBytesAfter: 120 * 1024 * 1024,
      largestRowBytes: 10 * 1024 * 1024,
      errors: [],
    });
    expect(outcome.passed).toBe(false);
  });
});
