import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_WARM_ROWS,
  createRealWarmLruDeps,
  evaluateDiskPressureGate,
  evaluateDiskPressureTarget,
  evaluateWarmLruOutcome,
  modelWarmLruEvictionForTests,
  parsePressureMountPath,
  runBackupGuardLeg,
  runWarmLruLeg,
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
  freeMb: 240,
  fillTargetMb: 130,
  backupMinFreeMb: 200,
  hostFreeBeforeMb: 50_000,
  workerAlive: true,
  targetProblems: [] as string[],
};

describe("parsePressureMountPath (F1)", () => {
  it("extracts the path from stdout even when warnings precede it", () => {
    expect(
      parsePressureMountPath(
        "[staging] creating 256MB loopback ext4\n[staging] mounted\n/mnt/ovid-pressure\n",
      ),
    ).toBe("/mnt/ovid-pressure");
  });

  it("extracts the path when a warning is printed after it", () => {
    expect(
      parsePressureMountPath("/mnt/ovid-pressure\n[staging] warning: loop devices\n"),
    ).toBe("/mnt/ovid-pressure");
  });

  it("fails loud instead of silently substituting the constant", () => {
    expect(() => parsePressureMountPath("[staging] nothing printed")).toThrow(
      /did not report/,
    );
    expect(() => parsePressureMountPath("")).toThrow(/did not report/);
  });

  it("rejects a foreign mount path", () => {
    expect(() => parsePressureMountPath("/mnt/not-ovid\n")).toThrow(
      /did not report/,
    );
  });

  it("staging.sh sends log() to stderr so stdout is machine-readable", () => {
    const here = dirname(fileURLToPath(import.meta.url));
    const script = readFileSync(
      resolve(here, "../../../../../scripts/staging.sh"),
      "utf8",
    );
    expect(script).toMatch(/log\(\) \{ printf '\[staging\] %s\\n' "\$\*" >&2; \}/);
  });
});

describe("evaluateDiskPressureTarget (F10/F11)", () => {
  it("accepts a loopback gateway and a staging-named container", () => {
    expect(
      evaluateDiskPressureTarget({
        STAGING_GATEWAY_URL: "http://127.0.0.1:18082",
        STAGING_PG_CONTAINER: "ovid-cloud-staging-postgres-1",
      }),
    ).toEqual([]);
  });

  it("rejects a non-loopback gateway reached by IP or alias", () => {
    const problems = evaluateDiskPressureTarget({
      STAGING_GATEWAY_URL: "https://203.0.113.10",
    });
    expect(problems.join(" ")).toContain("loopback");
  });

  it("rejects a non-staging Postgres container", () => {
    const problems = evaluateDiskPressureTarget({
      STAGING_GATEWAY_URL: "http://127.0.0.1:18082",
      STAGING_PG_CONTAINER: "ovid-prod-postgres-1",
    });
    expect(problems.join(" ")).toContain("staging");
  });
});

describe("evaluateDiskPressureGate", () => {
  it("passes when the fixture can be filled below the guard", () => {
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

  it("rejects a fill target that cannot cross the backup guard", () => {
    const result = evaluateDiskPressureGate({
      ...healthyGate,
      fillTargetMb: 250,
    });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("fill target");
  });

  it("rejects a fixture too small for the fill target", () => {
    expect(
      evaluateDiskPressureGate({
        ...healthyGate,
        totalBytes: 100 * 1024 * 1024,
        expectedTotalBytes: 100 * 1024 * 1024,
        fillTargetMb: 130,
      }).ok,
    ).toBe(false);
  });

  it("refuses to run when the host is nearly full", () => {
    expect(
      evaluateDiskPressureGate({ ...healthyGate, hostFreeBeforeMb: 200 }).ok,
    ).toBe(false);
  });

  it("rejects a dead worker (an ENOSPC crash would be invisible)", () => {
    expect(
      evaluateDiskPressureGate({ ...healthyGate, workerAlive: false }).ok,
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

describe("modelWarmLruEvictionForTests (unit oracle, not the scenario seam)", () => {
  const rows = [
    { sessionId: "oldest", bytes: 60 * 1024 * 1024, lastActivityMs: 1 },
    { sessionId: "middle", bytes: 50 * 1024 * 1024, lastActivityMs: 2 },
    { sessionId: "newest", bytes: 40 * 1024 * 1024, lastActivityMs: 3 },
  ];

  it("evicts oldest-first until the warm cap is met", () => {
    const result = modelWarmLruEvictionForTests(rows, {
      maxWarmBytes: 80 * 1024 * 1024,
      diskUsedFraction: 0.1,
      diskAlertFraction: 0.8,
    });
    expect(result.evictedSessions).toEqual(["oldest", "middle"]);
    expect(result.warmBytesAfter).toBe(40 * 1024 * 1024);
    expect(result.errors).toEqual([]);
  });

  it("evicts on the disk-alert arm even when the cap is not exceeded", () => {
    const result = modelWarmLruEvictionForTests(rows, {
      maxWarmBytes: 1024 * 1024 * 1024,
      diskUsedFraction: 0.95,
      diskAlertFraction: 0.8,
    });
    expect(result.evictedSessions.length).toBeGreaterThan(0);
    expect(result.evictedSessions[0]).toBe("oldest");
  });

  it("never throws on a full fake disk (no ENOSPC path)", () => {
    const result = modelWarmLruEvictionForTests(rows, {
      maxWarmBytes: 0,
      diskUsedFraction: 1,
      diskAlertFraction: 0.8,
    });
    expect(result.errors).toEqual([]);
  });
});

describe("the scenario seam drives the shipped enforceWarmCap (F4)", () => {
  const storageUrl = new URL(
    "../../../../../packages/storage/dist/warmLru.js",
    import.meta.url,
  );
  const built = existsSync(fileURLToPath(storageUrl));

  it.skipIf(!built)("evicts oldest-first through the real engine", async () => {
    const result = await runWarmLruLeg(createRealWarmLruDeps(), {
      maxWarmBytes: 100 * 1024 * 1024,
      diskAlertFraction: 0.8,
      initialWarmBytes: 170 * 1024 * 1024,
      expectedOldestFirst: DEFAULT_WARM_ROWS.map((row) => row.sessionId),
      largestRowBytes: 60 * 1024 * 1024,
    });
    expect(result.assertion.passed).toBe(true);
    expect(result.evictedSessions).toEqual(
      DEFAULT_WARM_ROWS.map((row) => row.sessionId),
    );
  });

  it("defaultWarmLruDeps references the shipped engine, not the test model", () => {
    const here = dirname(fileURLToPath(import.meta.url));
    const source = readFileSync(resolve(here, "./diskPressure.ts"), "utf8");
    const seam = source.slice(
      source.indexOf("export function defaultWarmLruDeps"),
      source.indexOf("export function defaultWarmLruDeps") + 200,
    );
    expect(seam).toContain("createRealWarmLruDeps");
    expect(seam).not.toContain("modelWarmLruEvictionForTests");
    expect(source).toContain("packages/storage/dist/warmLru.js");
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
