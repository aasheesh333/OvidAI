import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { readdir, statfs } from "node:fs/promises";
import { resolve } from "node:path";
import type {
  Assertion,
  ChaosContext,
  ChaosScenario,
  GateResult,
} from "../runner.js";

/**
 * disk-pressure — the backup free-space guard and the warm-LRU eviction path
 * under a simulated full disk.
 *
 * Safety (brief-pinned): the real host disk is NEVER filled. The staging leg
 * uses a 256 MB loopback ext4 image at `/mnt/ovid-pressure`
 * (`staging.sh pressure-mount`), and the LRU leg runs against an INJECTED
 * capacity seam. `pressureUnmount` deletes the image; the scenario records
 * host `df /` before/after and requires < 1 GB drift.
 *
 * Leg A (backup guard): the fixture is filled until free < BACKUP_MIN_FREE_MB;
 * the precondition gate proves that BEFORE the script runs. The script must
 * exit non-zero with the free-space abort and write no dump run directory
 * (the guard fires before `mkdir DEST`).
 *
 * Leg B (warm LRU): the SHIPPED `enforceWarmCap`
 * (`packages/storage/src/warmLru.ts`) is driven with an injected disk probe
 * and fake warm rows/queue seam. It is not a mirror of the selection logic:
 * a wrong victim, zero evictions, or an eviction error fails the scenario.
 * The capacity is injected (the brief permits that seam); nothing touches a
 * real filesystem.
 */

const MB = 1024 * 1024;
export const PRESSURE_MOUNT_PATH = "/mnt/ovid-pressure";
export const PRESSURE_IMAGE_MB = 256;
/** Leave this much free inside the fixture so the guard fires. */
export const FIXTURE_FREE_TARGET_MB = 130;
export const HOST_FREE_FLOOR_MB = 1024;
export const HOST_FREE_DRIFT_MB = 1024;
export const MAX_EVICTIONS_PER_PASS = 8;

/**
 * F1: `staging.sh` writes logs to stderr, so `pressure-mount`'s stdout is the
 * mount path alone. Parse defensively anyway: warnings may still be printed,
 * and a silent fallback would hide a regression (the review's F1 failure mode).
 */
export function parsePressureMountPath(stdout: string): string {
  const lines = stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line !== "");
  const found = [...lines]
    .reverse()
    .find((line) => line === PRESSURE_MOUNT_PATH);
  if (found === undefined) {
    throw new Error(
      `disk-pressure: pressure-mount did not report ${PRESSURE_MOUNT_PATH} on stdout ` +
        `(got ${JSON.stringify(stdout)}); refusing to continue without a proven fixture path`,
    );
  }
  return found;
}

/**
 * F10/F11: the disk scenario must prove it is pointed at staging, not at a
 * production backup target. The gateway URL is loopback-only (staging.sh
 * publishes loopback ports); a production host reached by IP or alias fails.
 */
export function evaluateDiskPressureTarget(
  env: Record<string, string>,
): string[] {
  const problems: string[] = [];
  const gateway = env.STAGING_GATEWAY_URL ?? "";
  if (gateway === "") {
    problems.push("STAGING_GATEWAY_URL is missing — refusing to guess a target");
  } else {
    let hostname = "";
    try {
      hostname = new URL(gateway).hostname;
    } catch {
      problems.push(`STAGING_GATEWAY_URL (${gateway}) is not a valid URL`);
    }
    if (
      hostname !== "" &&
      hostname !== "127.0.0.1" &&
      hostname !== "localhost" &&
      hostname !== "::1" &&
      hostname !== "[::1]"
    ) {
      problems.push(
        `STAGING_GATEWAY_URL host '${hostname}' is not loopback — refusing to run against a non-staging target`,
      );
    }
  }

  const container = env.STAGING_PG_CONTAINER ?? "";
  if (container !== "" && !container.toLowerCase().includes("staging")) {
    problems.push(
      `STAGING_PG_CONTAINER (${container}) is not staging-named — refusing to drive a production backup target`,
    );
  }

  return problems;
}

export interface DiskPressureGateState {
  mountPath: string;
  mounted: boolean;
  totalBytes: number;
  expectedTotalBytes: number;
  freeMb: number;
  /** The free-space target the scenario will fill to after the gate. */
  fillTargetMb: number;
  backupMinFreeMb: number;
  hostFreeBeforeMb: number;
  workerAlive: boolean;
  targetProblems: string[];
}

/**
 * Pure gate (unit-tested): the fixture is the expected SEPARATE filesystem
 * and filling it can provably drive free space below the backup guard. The
 * fill itself happens AFTER the gate (F5) — a foreign mount must never be
 * written into.
 */
export function evaluateDiskPressureGate(
  state: DiskPressureGateState,
): GateResult {
  const problems: string[] = [];
  if (state.targetProblems.length > 0) problems.push(...state.targetProblems);
  if (state.mountPath !== PRESSURE_MOUNT_PATH) {
    problems.push(
      `pressure mount is ${state.mountPath}, expected ${PRESSURE_MOUNT_PATH} (host disk safety)`,
    );
  }
  if (!state.mounted) problems.push("the pressure fixture is not mounted");
  const tolerance = state.expectedTotalBytes * 0.05;
  if (
    state.expectedTotalBytes <= 0 ||
    Math.abs(state.totalBytes - state.expectedTotalBytes) > tolerance
  ) {
    problems.push(
      `fixture total ${Math.round(state.totalBytes / MB)}MB does not match the expected ${Math.round(state.expectedTotalBytes / MB)}MB (±5%)`,
    );
  }
  if (state.fillTargetMb >= state.backupMinFreeMb) {
    problems.push(
      `fill target ${state.fillTargetMb}MB is not below the backup guard (${state.backupMinFreeMb}MB) — the guard could not be made to fire`,
    );
  }
  if (state.totalBytes / MB <= state.fillTargetMb) {
    problems.push(
      `fixture total ${Math.round(state.totalBytes / MB)}MB is too small to hold the ${state.fillTargetMb}MB fill target`,
    );
  }
  if (state.hostFreeBeforeMb < HOST_FREE_FLOOR_MB) {
    problems.push(
      `host free ${state.hostFreeBeforeMb}MB is below the ${HOST_FREE_FLOOR_MB}MB safety floor — refusing to mount a fixture`,
    );
  }
  if (!state.workerAlive) {
    problems.push(
      "staging worker is not alive — an ENOSPC crash would be invisible and later scenarios need it",
    );
  }
  if (problems.length > 0) return { ok: false, detail: problems.join("; ") };
  return {
    ok: true,
    detail: `fixture ${Math.round(state.totalBytes / MB)}MB mounted with ${state.freeMb}MB free; filling to ${state.fillTargetMb}MB will cross the ${state.backupMinFreeMb}MB guard; host ${state.hostFreeBeforeMb}MB free; worker alive`,
  };
}

// ---------------------------------------------------------------------------
// Leg A — backup free-space guard
// ---------------------------------------------------------------------------

export interface BackupGuardDeps {
  runBackup(env: Record<string, string>): Promise<{
    exitCode: number;
    stdout: string;
    stderr: string;
  }>;
  listDumpRuns(dir: string): Promise<string[]>;
}

export interface BackupGuardOpts {
  backupDir: string;
  minFreeMb: number;
  container: string;
  scriptPath: string;
}

export async function runBackupGuardLeg(
  deps: BackupGuardDeps,
  opts: BackupGuardOpts,
): Promise<Assertion> {
  const env = {
    BACKUP_DIR: opts.backupDir,
    BACKUP_MIN_FREE_MB: String(opts.minFreeMb),
    PG_CONTAINER: opts.container,
    // Keep the chaos run out of the real backup lock.
    BACKUP_LOCK_FILE: "/tmp/ovid-pg-backup-chaos.lock",
  };
  let result: { exitCode: number; stdout: string; stderr: string };
  try {
    result = await deps.runBackup(env);
  } catch (err) {
    return {
      name: "backup-guard-fires",
      passed: false,
      detail: `backup script failed to run: ${err instanceof Error ? err.message : String(err)}`,
    };
  }
  const dumpRuns = await deps.listDumpRuns(opts.backupDir).catch(() => []);
  const guardText = /refusing to dump/i.test(result.stderr);
  const passed =
    result.exitCode !== 0 && guardText && dumpRuns.length === 0;
  return {
    name: "backup-guard-fires",
    passed,
    detail: passed
      ? `exit ${result.exitCode}, stderr contains the free-space abort, no dump run written`
      : [
          `exit ${result.exitCode} (expected non-zero)`,
          guardText
            ? "stderr contains the free-space abort"
            : "stderr does NOT contain 'refusing to dump'",
          dumpRuns.length === 0
            ? "no dump run written"
            : `dump run(s) written before the abort: ${dumpRuns.join(", ")}`,
        ].join("; "),
  };
}

// ---------------------------------------------------------------------------
// Leg B — warm-LRU eviction (injected capacity seam)
// ---------------------------------------------------------------------------

export interface WarmLruResult {
  evicted: number;
  freedBytes: number;
  evictedSessions: string[];
  warmBytesAfter: number;
  errors: string[];
}

export interface WarmLruDeps {
  enforceCap(cfg: {
    maxWarmBytes: number;
    diskAlertFraction: number;
  }): Promise<WarmLruResult>;
}

export interface WarmLruOpts {
  maxWarmBytes: number;
  diskAlertFraction: number;
  initialWarmBytes: number;
  expectedOldestFirst?: string[];
  largestRowBytes?: number;
}

export interface WarmLruOutcomeState {
  initialWarmBytes: number;
  maxWarmBytes: number;
  evictedSessions: string[];
  expectedOldestFirst: string[];
  warmBytesAfter: number;
  largestRowBytes: number;
  errors: string[];
}

/** Pure outcome evaluator (unit-tested). */
export function evaluateWarmLruOutcome(
  state: WarmLruOutcomeState,
): Assertion {
  const problems: string[] = [];
  if (state.evictedSessions.length === 0) {
    problems.push("nothing was evicted under pressure");
  }
  if (
    state.expectedOldestFirst.length > 0 &&
    state.evictedSessions.some(
      (sessionId, index) => sessionId !== state.expectedOldestFirst[index],
    )
  ) {
    problems.push(
      `eviction is not oldest-first (got ${state.evictedSessions.join(", ")}, expected ${state.expectedOldestFirst.join(", ")})`,
    );
  }
  const capWithTolerance = state.maxWarmBytes + state.largestRowBytes;
  if (state.warmBytesAfter > capWithTolerance) {
    problems.push(
      `warm bytes after eviction ${Math.round(state.warmBytesAfter / MB)}MB exceed the cap ${Math.round(state.maxWarmBytes / MB)}MB + one-workspace tolerance ${Math.round(state.largestRowBytes / MB)}MB`,
    );
  }
  if (state.errors.length > 0) {
    problems.push(`eviction errors: ${state.errors.join("; ")}`);
  }
  return {
    name: "warm-lru-evicts",
    passed: problems.length === 0,
    detail:
      problems.length === 0
        ? `evicted ${state.evictedSessions.length} oldest-first, warm ${Math.round(state.warmBytesAfter / MB)}MB <= ${Math.round(state.maxWarmBytes / MB)}MB cap, no errors`
        : problems.join("; "),
  };
}

export async function runWarmLruLeg(
  deps: WarmLruDeps,
  opts: WarmLruOpts,
): Promise<{ assertion: Assertion; evictedSessions: string[] }> {
  const result = await deps.enforceCap({
    maxWarmBytes: opts.maxWarmBytes,
    diskAlertFraction: opts.diskAlertFraction,
  });
  const assertion = evaluateWarmLruOutcome({
    initialWarmBytes: opts.initialWarmBytes,
    maxWarmBytes: opts.maxWarmBytes,
    evictedSessions: result.evictedSessions,
    expectedOldestFirst: opts.expectedOldestFirst ?? [],
    warmBytesAfter: result.warmBytesAfter,
    largestRowBytes: opts.largestRowBytes ?? 0,
    errors: result.errors,
  });
  return { assertion, evictedSessions: result.evictedSessions };
}

export interface WarmRow {
  sessionId: string;
  bytes: number;
  lastActivityMs: number;
}

/**
 * Unit-test oracle only. This is NOT the scenario seam: `defaultWarmLruDeps`
 * drives the shipped `enforceWarmCap` (F4). Keeping the model lets the
 * evaluator's oldest-first/zero-eviction assertions be tested without a
 * build, but substituting it for the real engine would make the scenario
 * unable to detect the bug it exists for.
 */
export function modelWarmLruEvictionForTests(
  rows: WarmRow[],
  cfg: {
    maxWarmBytes: number;
    diskUsedFraction: number;
    diskAlertFraction: number;
  },
): WarmLruResult {
  const sorted = [...rows].sort(
    (a, b) =>
      a.lastActivityMs - b.lastActivityMs ||
      a.sessionId.localeCompare(b.sessionId),
  );
  let total = sorted.reduce((sum, row) => sum + row.bytes, 0);
  const evictedSessions: string[] = [];
  let freedBytes = 0;
  const overDisk = cfg.diskUsedFraction >= cfg.diskAlertFraction;
  for (const row of sorted) {
    if (
      evictedSessions.length >= MAX_EVICTIONS_PER_PASS ||
      !(total > cfg.maxWarmBytes || overDisk)
    ) {
      break;
    }
    evictedSessions.push(row.sessionId);
    freedBytes += row.bytes;
    total -= row.bytes;
  }
  return {
    evicted: evictedSessions.length,
    freedBytes,
    evictedSessions,
    warmBytesAfter: total,
    errors: [],
  };
}

export interface WarmRowInput {
  sessionId: string;
  userId?: string;
  bytes: number;
  lastActivityMs: number;
}

/** Fake rows with distinct activity timestamps (oldest first = array order). */
export const DEFAULT_WARM_ROWS: WarmRowInput[] = [
  { sessionId: "warm-a", bytes: 60 * MB, lastActivityMs: 1_000 },
  { sessionId: "warm-b", bytes: 50 * MB, lastActivityMs: 2_000 },
  { sessionId: "warm-c", bytes: 40 * MB, lastActivityMs: 3_000 },
  { sessionId: "warm-d", bytes: 20 * MB, lastActivityMs: 4_000 },
];

/**
 * The shipped module, loaded from its build output. `@ovid/load` does not
 * declare `@ovid/storage` (its package.json is outside this task's pathspec),
 * so the dependency is resolved by path. If the build is missing we FAIL
 * LOUD — never fall back to the test model.
 */
const SHIPPED_WARM_LRU_URL = new URL(
  "../../../../../packages/storage/dist/warmLru.js",
  import.meta.url,
);

type ShippedEnforceWarmCap = (
  deps: Record<string, unknown>,
  cfg: { maxWarmBytes: number; diskAlertFraction: number },
  opts?: { maxEvictions?: number },
) => Promise<{ evicted: number; freedBytes: number }>;

async function loadShippedEnforceWarmCap(): Promise<ShippedEnforceWarmCap> {
  let mod: unknown;
  try {
    mod = await import(SHIPPED_WARM_LRU_URL.href);
  } catch (err) {
    throw new Error(
      `disk-pressure leg B: the shipped @ovid/storage warm LRU is not built at ` +
        `${SHIPPED_WARM_LRU_URL.pathname} (${err instanceof Error ? err.message : String(err)}); ` +
        "run `pnpm --filter @ovid/storage build` — refusing to substitute a mirror",
    );
  }
  const fn = (mod as { enforceWarmCap?: unknown }).enforceWarmCap;
  if (typeof fn !== "function") {
    throw new Error(
      "disk-pressure leg B: the shipped module does not export enforceWarmCap — refusing to substitute a mirror",
    );
  }
  return fn as ShippedEnforceWarmCap;
}

/**
 * F4: drive the REAL `enforceWarmCap` with an injected disk probe, fake warm
 * rows, and a fake hibernate queue. The engine's selection, oldest-first
 * ordering, per-pass bound, disk-alert arm and dedup check all execute.
 */
export function createRealWarmLruDeps(
  rows: WarmRowInput[] = DEFAULT_WARM_ROWS,
): WarmLruDeps {
  return {
    async enforceCap(cfg) {
      const enforceWarmCap = await loadShippedEnforceWarmCap();
      const evictedSessions: string[] = [];
      const errors: string[] = [];
      const base = 1_700_000_000_000;
      const warmRows = rows.map((row, index) => ({
        sessionId: row.sessionId,
        userId: row.userId ?? `chaos-${row.sessionId}`,
        generation: 0,
        workspaceBytes: row.bytes,
        updatedAt: new Date(base + index),
      }));
      const activity = new Map(
        rows.map((row) => [row.sessionId, row.lastActivityMs]),
      );
      const initialWarmBytes = rows.reduce((sum, row) => sum + row.bytes, 0);
      const deps: Record<string, unknown> = {
        db: {},
        workspacesRoot: "/nonexistent/chaos-warm-root",
        // The injected-capacity seam: the pressure fixture is nearly full.
        diskProbe: async () => ({
          totalBytes: 1000,
          freeBytes: 50,
          usedFraction: 0.95,
        }),
        fileManifests: {
          listWarmForLru: async () => warmRows,
        },
        activity: {
          readMany: async (ids: string[]) =>
            new Map(
              ids
                .filter((id) => activity.has(id))
                .map((id) => [id, activity.get(id)!]),
            ),
        },
        queues: {
          hibernate: {
            add: async (
              _name: string,
              job: { sessionId?: string },
            ): Promise<{ id?: string; timestamp: number }> => {
              if (typeof job.sessionId === "string") {
                evictedSessions.push(job.sessionId);
              }
              // Newer than `addStartedMs` → counted as a real (non-deduped) add.
              return { id: job.sessionId, timestamp: Date.now() + 1 };
            },
          },
        },
        events: {
          append: async (sessionId: string, type: string, payload: unknown) => ({
            sessionId,
            type,
            payload,
            seq: "0",
            ts: new Date().toISOString(),
          }),
        },
        eventMirror: { put: async () => undefined },
        stuckHydrationScan: {
          listStuckHydrating: async () => [],
        },
      };

      let result: { evicted: number; freedBytes: number };
      try {
        result = await enforceWarmCap(deps, {
          maxWarmBytes: cfg.maxWarmBytes,
          diskAlertFraction: cfg.diskAlertFraction,
        });
      } catch (err) {
        errors.push(err instanceof Error ? err.message : String(err));
        return {
          evicted: 0,
          freedBytes: 0,
          evictedSessions,
          warmBytesAfter: initialWarmBytes,
          errors,
        };
      }

      return {
        evicted: result.evicted,
        freedBytes: result.freedBytes,
        evictedSessions,
        warmBytesAfter: Math.max(0, initialWarmBytes - result.freedBytes),
        errors,
      };
    },
  };
}

/** The scenario's LRU seam: the shipped engine, injected capacity. */
export function defaultWarmLruDeps(): WarmLruDeps {
  return createRealWarmLruDeps();
}

// ---------------------------------------------------------------------------
// Staging harness
// ---------------------------------------------------------------------------

export interface DiskUsage {
  totalBytes: number;
  freeBytes: number;
}

async function usage(path: string): Promise<DiskUsage> {
  const st = await statfs(path);
  return {
    totalBytes: Number(st.bsize) * Number(st.blocks),
    freeBytes: Number(st.bsize) * Number(st.bavail),
  };
}

export interface DiskHarness {
  mountPath: string;
  mount(mb: number): Promise<string>;
  unmount(): Promise<void>;
  mountUsage(): Promise<DiskUsage>;
  hostFreeMb(): Promise<number>;
  fillToFreeMb(targetMb: number): Promise<void>;
  runBackup(env: Record<string, string>): Promise<{
    exitCode: number;
    stdout: string;
    stderr: string;
  }>;
  listDumpRuns(dir: string): Promise<string[]>;
}

function execText(
  command: string,
  args: string[],
  env: NodeJS.ProcessEnv = process.env,
  timeoutMs = 120_000,
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  return new Promise((resolvePromise) => {
    execFile(
      command,
      args,
      { encoding: "utf8", timeout: timeoutMs, env },
      (err, stdout, stderr) => {
        const exitCode =
          err === null
            ? 0
            : typeof (err as { code?: unknown }).code === "number"
              ? ((err as { code: number }).code)
              : 1;
        resolvePromise({ exitCode, stdout: stdout ?? "", stderr: stderr ?? "" });
      },
    );
  });
}

export function resolveBackupScript(explicit?: string): string {
  const candidates = [
    explicit,
    process.env.PG_BACKUP_SCRIPT,
    resolve(process.cwd(), "deploy/backup/pg_backup.sh"),
    resolve(process.cwd(), "cloud/deploy/backup/pg_backup.sh"),
    resolve(process.cwd(), "../../deploy/backup/pg_backup.sh"),
  ].filter((candidate): candidate is string => typeof candidate === "string");
  const found = candidates.find((candidate) => existsSync(candidate));
  if (found === undefined) {
    throw new Error(
      "disk-pressure: pg_backup.sh not found — run from cloud/ or set PG_BACKUP_SCRIPT",
    );
  }
  return found;
}

export function createStagingDiskHarness(ctx: ChaosContext): DiskHarness {
  const scriptPath = resolveBackupScript(ctx.env.PG_BACKUP_SCRIPT);
  return {
    mountPath: PRESSURE_MOUNT_PATH,
    async mount(mb) {
      // F1: stdout is the path only (staging.sh logs to stderr); parse
      // defensively and fail loud if the script ever stops reporting it.
      const stdout = await ctx.staging.pressureMount(mb);
      return parsePressureMountPath(stdout);
    },
    async unmount() {
      await ctx.staging.pressureUnmount();
    },
    mountUsage() {
      return usage(PRESSURE_MOUNT_PATH);
    },
    async hostFreeMb() {
      return (await usage("/")).freeBytes / MB;
    },
    async fillToFreeMb(targetMb) {
      const current = await usage(PRESSURE_MOUNT_PATH);
      const targetBytes = targetMb * MB;
      const toWrite = current.freeBytes - targetBytes;
      if (toWrite <= 0) return;
      const count = Math.max(1, Math.floor(toWrite / MB));
      const result = await execText("dd", [
        "if=/dev/zero",
        `of=${PRESSURE_MOUNT_PATH}/filler.bin`,
        "bs=1M",
        `count=${count}`,
        "status=none",
      ]);
      if (result.exitCode !== 0) {
        throw new Error(
          `disk-pressure: filler write failed (${result.stderr.trim() || `exit ${result.exitCode}`})`,
        );
      }
    },
    runBackup(env) {
      return execText(
        "bash",
        [scriptPath],
        { ...process.env, ...env },
        180_000,
      );
    },
    async listDumpRuns(dir) {
      try {
        return (await readdir(dir)).filter((name) => /^\d{8}-\d{6}$/.test(name));
      } catch {
        return [];
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Scenario
// ---------------------------------------------------------------------------

interface Prepared {
  harness: DiskHarness;
  mounted: boolean;
  mountPath: string;
  hostFreeBeforeMb: number;
  backupDir: string;
  minFreeMb: number;
  container: string;
  targetProblems: string[];
  backupAssertion: Assertion | null;
  warmAssertion: Assertion | null;
}

export const diskPressureScenario: ChaosScenario<Prepared> = {
  name: "disk-pressure",
  precondition:
    "the 256MB loopback fixture is mounted at /mnt/ovid-pressure as a separate filesystem, filling it can provably drive free space below BACKUP_MIN_FREE_MB, the host has at least 1GB free, the target is proven staging, and the worker is alive",

  async prepare(ctx: ChaosContext): Promise<Prepared> {
    const harness = createStagingDiskHarness(ctx);
    let mounted = false;
    try {
      const mountPath = await harness.mount(PRESSURE_IMAGE_MB);
      mounted = true;
      const hostFreeBeforeMb = await harness.hostFreeMb();
      const targetProblems = evaluateDiskPressureTarget(ctx.env);

      // F5: NO fill here. The gate proves the fixture is ours and fillable;
      // only `inject` writes into it, after the gate passed.
      const backupDir = `${mountPath}/backups`;
      return {
        harness,
        mounted,
        mountPath,
        hostFreeBeforeMb,
        backupDir,
        minFreeMb: Number(ctx.env.BACKUP_MIN_FREE_MB ?? "200"),
        container: ctx.env.STAGING_PG_CONTAINER ?? "ovid-cloud-staging-postgres-1",
        targetProblems,
        backupAssertion: null,
        warmAssertion: null,
      };
    } catch (err) {
      // The runner does not call cleanup when prepare throws — never leave
      // the loopback mounted.
      if (mounted) await harness.unmount().catch(() => {});
      throw err;
    }
  },

  async gate(ctx: ChaosContext, prepared: Prepared): Promise<GateResult> {
    let mounted = prepared.mounted;
    let mountUsage = { totalBytes: 0, freeBytes: 0 };
    try {
      mountUsage = await prepared.harness.mountUsage();
    } catch {
      mounted = false;
    }
    return evaluateDiskPressureGate({
      mountPath: prepared.mountPath,
      mounted,
      totalBytes: mountUsage.totalBytes,
      expectedTotalBytes: PRESSURE_IMAGE_MB * MB,
      freeMb: mountUsage.freeBytes / MB,
      fillTargetMb: FIXTURE_FREE_TARGET_MB,
      backupMinFreeMb: prepared.minFreeMb,
      hostFreeBeforeMb: prepared.hostFreeBeforeMb,
      workerAlive: await ctx.staging.workerAlive().catch(() => false),
      targetProblems: prepared.targetProblems,
    });
  },

  async inject(_ctx: ChaosContext, prepared: Prepared): Promise<void> {
    // F5: the write happens only after the gate proved the fixture is the
    // expected separate filesystem. Re-prove the vulnerable state before the
    // backup script runs.
    await prepared.harness.fillToFreeMb(FIXTURE_FREE_TARGET_MB);
    const usage = await prepared.harness.mountUsage();
    const freeMb = usage.freeBytes / MB;
    if (freeMb >= prepared.minFreeMb) {
      throw new Error(
        `disk-pressure: fixture free ${Math.round(freeMb)}MB is not below the backup guard (${prepared.minFreeMb}MB) after filling — the guard would not fire`,
      );
    }

    prepared.backupAssertion = await runBackupGuardLeg(
      {
        runBackup: (env) => prepared.harness.runBackup(env),
        listDumpRuns: (dir) => prepared.harness.listDumpRuns(dir),
      },
      {
        backupDir: prepared.backupDir,
        minFreeMb: prepared.minFreeMb,
        container: prepared.container,
        scriptPath: resolveBackupScript(),
      },
    );

    const warm = await runWarmLruLeg(defaultWarmLruDeps(), {
      maxWarmBytes: 100 * MB,
      diskAlertFraction: 0.8,
      initialWarmBytes: 170 * MB,
      expectedOldestFirst: DEFAULT_WARM_ROWS.map((row) => row.sessionId),
      largestRowBytes: 60 * MB,
    });
    prepared.warmAssertion = warm.assertion;
  },

  async verify(ctx: ChaosContext, prepared: Prepared): Promise<Assertion[]> {
    const assertions: Assertion[] = [];
    assertions.push(
      prepared.backupAssertion ?? {
        name: "backup-guard-fires",
        passed: false,
        detail: "leg A did not run",
      },
    );
    assertions.push(
      prepared.warmAssertion ?? {
        name: "warm-lru-evicts",
        passed: false,
        detail: "leg B did not run",
      },
    );

    // F10: the fixture is nearly full, so a worker that crashed with ENOSPC
    // (or died for any reason) is the available ground truth. The gate
    // required it alive before injection.
    const workerAliveAfter = await ctx.staging.workerAlive().catch(() => false);
    assertions.push({
      name: "no-enospc-crash",
      passed: workerAliveAfter,
      detail: workerAliveAfter
        ? "staging worker is still alive after the pressure legs"
        : "staging worker is not alive after the pressure legs — possible ENOSPC crash",
    });

    // Unmount and prove the host disk is back where it started.
    let unmounted = false;
    try {
      await prepared.harness.unmount();
      unmounted = true;
      prepared.mounted = false;
    } catch (err) {
      assertions.push({
        name: "fixture-unmounted",
        passed: false,
        detail: err instanceof Error ? err.message : String(err),
      });
    }
    if (unmounted) {
      const hostFreeAfterMb = await prepared.harness.hostFreeMb();
      const drift = Math.abs(hostFreeAfterMb - prepared.hostFreeBeforeMb);
      assertions.push({
        name: "host-disk-unchanged",
        passed: drift <= HOST_FREE_DRIFT_MB,
        detail: `host free before ${Math.round(prepared.hostFreeBeforeMb)}MB, after ${Math.round(hostFreeAfterMb)}MB (drift ${Math.round(drift)}MB, tolerance ${HOST_FREE_DRIFT_MB}MB)`,
      });
    }

    return assertions;
  },

  async cleanup(_ctx: ChaosContext, prepared: Prepared | undefined): Promise<void> {
    // F8: the runner calls cleanup(ctx, undefined) when prepare throws; the
    // prepare catch already unmounted in that path.
    if (prepared === undefined) return;
    if (prepared.mounted) {
      await prepared.harness.unmount().catch(() => {});
      prepared.mounted = false;
    }
  },
};
