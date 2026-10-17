/**
 * Task 10 warm-cache LRU tests.
 *
 * Harness discipline (same as Tasks 8/9): real Postgres + real Redis over the
 * SHARED dev services, migrate-only, every row/key uniquely owned and deleted
 * in afterAll. The warm-row scan is wrapped to THIS run's sessions — the
 * landed `fileManifests.listWarmForLru` is global (correct in production) and
 * would otherwise see parallel-wave suites' rows.
 *
 * Ruling R1: the suite never enumerates workspace directories. "Warm on
 * disk" is represented by the injected `SandboxEviction` seam; `du` is the
 * only fs walk and it is pointed at a mkdtemp fixture.
 */

import { mkdir, mkdtemp, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { Redis } from "ioredis";
import type { WorkspaceState } from "@ovid/shared";

// Relative-source imports (Task-8/9 precedent; wave-merger converts at the
// next lockfile touch). @ovid/storage has no package edge on db/events/queue.
import { createDb, migrate, type Db } from "../../db/src/client.js";
import {
  eventMirror as eventMirrorRepo,
  fileManifests as fileManifestsRepo,
  newId,
  runs as runsRepo,
  sessions as sessionsRepo,
  workspaceObjects as workspaceObjectsRepo,
} from "../../db/src/repos.js";
import { users as usersTable } from "../../db/src/schema.js";
import { createRedisEventLog } from "../../events/src/eventLog.js";
import { HIBERNATE_JOB_NAME, storageJobId } from "../../queue/src/queues.js";

import { createActivityTracker } from "./activity.js";
import type { StorageAdapter } from "./adapter.js";
import { createFsStorage } from "./fsAdapter.js";
import {
  createNoopSandboxEviction,
  hibernateWorkspace,
  type FileManifestRowView,
  type HibernateDeps,
  type StuckHibernationRow,
  type WarmWorkspaceEntry,
} from "./hibernate.js";
import { r2Keys } from "./keys.js";
import { workspaceDir } from "./workspacePaths.js";
import {
  DISK_ALERT_PCT_DEFAULT,
  MAX_WARM_GB_DEFAULT,
  SWEEP_INTERVAL_MS,
  IDLE_THRESHOLD_MS,
  STUCK_STATE_MS,
  WARM_DU_REFRESH_MS,
  diskAlertFractionFromEnv,
  du,
  enforceWarmCap,
  maxWarmBytesFromEnv,
  reconcileWarmRegistry,
  resetDiskAlertStateForTests,
  type DiskUsage,
  type HibernateQueue,
  type StuckHydrationScan,
  type WarmConfig,
  type WarmDeps,
  type WarmFileManifestsRepo,
  type WarmRowView,
} from "./warmLru.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

/** Fixed "now" (2023-11-14T22:13:20Z) for clock-injected pins. */
const T0 = 1_700_000_000_000;

const RUN_TAG = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
const ACTIVITY_PREFIX = `ovid-test-warm-${RUN_TAG}:`;

const DISK_OK: DiskUsage = { totalBytes: 1000, freeBytes: 500, usedFraction: 0.5 };
const DISK_ALERT: DiskUsage = { totalBytes: 1000, freeBytes: 150, usedFraction: 0.85 };

const CFG: WarmConfig = { maxWarmBytes: 1_000_000, diskAlertFraction: 0.8 };

async function pathExists(p: string): Promise<boolean> {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Pure helpers / env knobs — no services needed.
// ---------------------------------------------------------------------------

describe("warm-disk knobs", () => {
  it("pins the task constants", () => {
    expect(MAX_WARM_GB_DEFAULT).toBe(8);
    expect(DISK_ALERT_PCT_DEFAULT).toBe(80);
    expect(SWEEP_INTERVAL_MS).toBe(30_000);
    expect(IDLE_THRESHOLD_MS).toBe(180_000);
    expect(STUCK_STATE_MS).toBe(900_000);
    expect(WARM_DU_REFRESH_MS).toBe(600_000);
  });

  it("maxWarmBytesFromEnv: default 8 GB, positive integer GB only", () => {
    expect(maxWarmBytesFromEnv({})).toBe(8 * 1024 ** 3);
    expect(maxWarmBytesFromEnv({ OVID_MAX_WARM_GB: "12" })).toBe(12 * 1024 ** 3);
    expect(maxWarmBytesFromEnv({ OVID_MAX_WARM_GB: "1" })).toBe(1024 ** 3);
    for (const bad of ["0", "x", "-1", "1.5", " 12", "01"]) {
      expect(() => maxWarmBytesFromEnv({ OVID_MAX_WARM_GB: bad })).toThrow(
        /OVID_MAX_WARM_GB/,
      );
    }
  });

  it("diskAlertFractionFromEnv: default 0.80, integer 1..99 only", () => {
    expect(diskAlertFractionFromEnv({})).toBe(0.8);
    expect(diskAlertFractionFromEnv({ OVID_DISK_ALERT_PCT: "75" })).toBe(0.75);
    expect(diskAlertFractionFromEnv({ OVID_DISK_ALERT_PCT: "1" })).toBe(0.01);
    expect(diskAlertFractionFromEnv({ OVID_DISK_ALERT_PCT: "99" })).toBe(0.99);
    for (const bad of ["0", "100", "x", "80.5", "-5"]) {
      expect(() => diskAlertFractionFromEnv({ OVID_DISK_ALERT_PCT: bad })).toThrow(
        /OVID_DISK_ALERT_PCT/,
      );
    }
  });
});

describe("du", () => {
  it("sums regular-file bytes exactly (nested, symlink target excluded)", async () => {
    const dir = await mkdtemp(join(tmpdir(), "ovid-du-"));
    try {
      await mkdir(join(dir, "sub", "deep"), { recursive: true });
      await writeFile(join(dir, "a.txt"), "alpha"); // 5
      await writeFile(join(dir, "sub", "b.bin"), Buffer.alloc(17));
      await writeFile(join(dir, "sub", "deep", "c.txt"), "1234567890"); // 10
      await symlink("a.txt", join(dir, "link")); // target bytes NOT counted
      expect(await du(dir)).toBe(5 + 17 + 10);
      expect(Number.isSafeInteger(await du(dir))).toBe(true);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

// ---------------------------------------------------------------------------
// Gated harness
// ---------------------------------------------------------------------------

interface AddRecord {
  name: string;
  job: {
    sessionId: string;
    userId: string;
    generation: number;
    reason: "idle" | "pressure" | "manual";
  };
  opts: { jobId: string };
}

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "warm-cache LRU — registry reconcile, pressure eviction",
  () => {
    let db: Db;
    let redis: Redis;
    let storageRoot: string;
    let wsRoot: string;
    let baseStorage: StorageAdapter;
    const createdSids: string[] = [];
    const createdUids: string[] = [];

    beforeAll(async () => {
      const url = TEST_DATABASE_URL!;
      let lastErr: unknown;
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          await migrate(url);
          lastErr = null;
          break;
        } catch (err) {
          lastErr = err;
          await new Promise((r) => setTimeout(r, 5_000));
        }
      }
      if (lastErr !== null) throw lastErr;
      db = createDb(url);
      redis = new Redis(TEST_REDIS_URL!);
      storageRoot = await mkdtemp(join(tmpdir(), "ovid-warm-store-"));
      wsRoot = await mkdtemp(join(tmpdir(), "ovid-warm-ws-"));
      baseStorage = createFsStorage(storageRoot);
    }, 120_000);

    afterAll(async () => {
      if (redis) {
        const keys = createdSids.flatMap((sid) => [
          `sess:${sid}:events`,
          `${ACTIVITY_PREFIX}${sid}`,
        ]);
        if (keys.length > 0) await redis.del(...keys).catch(() => {});
        await redis.quit().catch(() => {});
      }
      if (db && createdSids.length > 0) {
        try {
          await db.$client.unsafe(
            `DELETE FROM session_event_mirror WHERE session_id = ANY($1)`,
            [createdSids],
          );
          await db.$client.unsafe(`DELETE FROM workspace_objects WHERE session_id = ANY($1)`, [
            createdSids,
          ]);
          await db.$client.unsafe(`DELETE FROM file_manifests WHERE session_id = ANY($1)`, [
            createdSids,
          ]);
          await db.$client.unsafe(`DELETE FROM sessions WHERE id = ANY($1)`, [createdSids]);
          if (createdUids.length > 0) {
            await db.$client.unsafe(`DELETE FROM users WHERE uid = ANY($1)`, [createdUids]);
          }
        } catch {
          // best-effort dev hygiene only
        }
      }
      await db?.$client.end({ timeout: 5 });
      if (storageRoot) await rm(storageRoot, { recursive: true, force: true });
      if (wsRoot) await rm(wsRoot, { recursive: true, force: true });
    });

    beforeEach(async () => {
      resetDiskAlertStateForTests();
      // Independent cases: drop prior cases' rows/keys (this suite's only).
      if (createdSids.length > 0) {
        await db.$client.unsafe(`DELETE FROM session_event_mirror WHERE session_id = ANY($1)`, [
          createdSids,
        ]);
        await db.$client.unsafe(`DELETE FROM workspace_objects WHERE session_id = ANY($1)`, [
          createdSids,
        ]);
        await db.$client.unsafe(`DELETE FROM file_manifests WHERE session_id = ANY($1)`, [
          createdSids,
        ]);
        await redis
          .del(
            ...createdSids.flatMap((sid) => [
              `sess:${sid}:events`,
              `${ACTIVITY_PREFIX}${sid}`,
            ]),
          )
          .catch(() => {});
      }
    });

    // -- fixtures ------------------------------------------------------------

    async function seedUser(): Promise<string> {
      const uid = newId();
      createdUids.push(uid);
      await db.insert(usersTable).values({ uid, email: `warm-${uid.slice(0, 8)}@test.local` });
      return uid;
    }

    async function seedSession(uid: string): Promise<string> {
      const s = await sessionsRepo.create(db, uid, "warmlru-test");
      createdSids.push(s.id);
      return s.id;
    }

    async function seedWarmRow(
      uid: string,
      sid: string,
      workspaceBytes: number | null,
    ): Promise<void> {
      await fileManifestsRepo.upsertWarm(db, { sessionId: sid, userId: uid, workspaceBytes });
    }

    async function seedWorkspace(dir: string): Promise<void> {
      await mkdir(join(dir, "sub"), { recursive: true });
      await writeFile(join(dir, "a.txt"), "alpha-alpha-alpha");
      await writeFile(join(dir, "sub", "b.txt"), "beta".repeat(100));
    }

    async function pinUpdatedAt(sid: string, ms: number): Promise<void> {
      // ISO string, never a Date (drizzle patches postgres.js's serializer).
      await db.$client.unsafe(`UPDATE file_manifests SET updated_at = $1 WHERE session_id = $2`, [
        new Date(ms).toISOString(),
        sid,
      ]);
    }

    /**
     * Task-8 engine, used only to produce a real verified archive + sidecar
     * (the reconcile cold-close path needs one). The session ends COLD.
     */
    async function hibernateFixture(uid: string, sid: string): Promise<void> {
      const hdeps: HibernateDeps = {
        db,
        events: createRedisEventLog(redis),
        storage: baseStorage,
        workspacesRoot: wsRoot,
        sandbox: { listWarmWorkspaces: async () => [], evictWorkspace: async () => {} },
        activity: createActivityTracker(redis, {
          keyPrefix: ACTIVITY_PREFIX,
          clock: () => new Date(T0),
        }),
        clock: () => new Date(T0 + 200_000),
        fileManifests: fileManifestsRepo,
        workspaceObjects: workspaceObjectsRepo,
        runs: { activeForSession: async () => null },
        eventMirror: eventMirrorRepo,
        stuckHibernationScan: { listStuck: async () => [] },
      };
      const res = await hibernateWorkspace(hdeps, {
        sessionId: sid,
        userId: uid,
        generation: 1,
        reason: "idle",
      });
      expect(res.status).toBe("hibernated");
    }

    /** Scoped scans — the shared dev DB has parallel-wave rows. */
    async function listStuck(
      handle: Db,
      olderThan: Date,
    ): Promise<StuckHibernationRow[]> {
      const rows = (await handle.$client.unsafe(
        `SELECT session_id AS "sessionId", user_id AS "userId", generation, state,
                archive_key AS "archiveKey", workspace_bytes AS "workspaceBytes",
                updated_at AS "updatedAt"
           FROM file_manifests
          WHERE state = 'hibernating' AND updated_at < $1`,
        [olderThan.toISOString()],
      )) as Array<Record<string, unknown>>;
      return rows
        .filter((r) => createdSids.includes(String(r.sessionId)))
        .map((r) => ({
          sessionId: String(r.sessionId),
          userId: String(r.userId),
          generation: Number(r.generation),
          state: String(r.state) as WorkspaceState,
          archiveKey: r.archiveKey === null ? null : String(r.archiveKey),
          workspaceBytes: r.workspaceBytes === null ? null : Number(r.workspaceBytes),
          updatedAt: r.updatedAt as Date,
        }));
    }

    async function listStuckHydrating(
      handle: Db,
      olderThan: Date,
    ): Promise<WarmRowView[]> {
      const rows = (await handle.$client.unsafe(
        `SELECT session_id AS "sessionId", user_id AS "userId", generation,
                workspace_bytes AS "workspaceBytes", updated_at AS "updatedAt"
           FROM file_manifests
          WHERE state = 'hydrating' AND updated_at < $1`,
        [olderThan.toISOString()],
      )) as Array<Record<string, unknown>>;
      return rows
        .filter((r) => createdSids.includes(String(r.sessionId)))
        .map((r) => ({
          sessionId: String(r.sessionId),
          userId: String(r.userId),
          generation: Number(r.generation),
          workspaceBytes: r.workspaceBytes === null ? null : Number(r.workspaceBytes),
          updatedAt: r.updatedAt as Date,
        }));
    }

    /** T8-F1 cold-row residue scan (T11 wiring mirror). */
    async function listColdRows(
      handle: Db,
      opts: { limit: number },
    ): Promise<FileManifestRowView[]> {
      if (createdSids.length === 0) return [];
      const rows = (await handle.$client.unsafe(
        `SELECT session_id AS "sessionId", user_id AS "userId", generation, state,
                archive_key AS "archiveKey", workspace_bytes AS "workspaceBytes",
                updated_at AS "updatedAt"
           FROM file_manifests
          WHERE state = 'cold' AND session_id = ANY($1)
          ORDER BY updated_at DESC
          LIMIT $2`,
        [createdSids, opts.limit],
      )) as Array<Record<string, unknown>>;
      return rows.map((r) => ({
        sessionId: String(r.sessionId),
        userId: String(r.userId),
        generation: Number(r.generation),
        state: String(r.state) as WorkspaceState,
        archiveKey: r.archiveKey === null ? null : String(r.archiveKey),
        workspaceBytes: r.workspaceBytes === null ? null : Number(r.workspaceBytes),
        updatedAt: r.updatedAt as Date,
      }));
    }

    /** `markColdRetry` is the T11/P4 wiring mirror (state-rechecked). */
    const warmFileManifests: WarmFileManifestsRepo = {
      ...fileManifestsRepo,
      async listWarmForLru(handle: unknown): Promise<WarmRowView[]> {
        const rows = await fileManifestsRepo.listWarmForLru(handle as Db);
        // Only this run's rows: the real scan is global by design.
        return rows.filter((r) => createdSids.includes(r.sessionId));
      },
      async markColdRetry(handle: unknown, sessionId: string): Promise<void> {
        await (handle as Db).$client.unsafe(
          `UPDATE file_manifests
              SET state = 'cold', updated_at = now()
            WHERE session_id = $1 AND state = 'hydrating'`,
          [sessionId],
        );
      },
    };

    interface Harness {
      deps: WarmDeps;
      adds: AddRecord[];
      evictCalls: Array<[string, string]>;
    }

    function makeHarness(opts: {
      nowMs?: number;
      entries?: WarmWorkspaceEntry[];
      disk?: DiskUsage;
      authoritative?: boolean;
      sandbox?: WarmDeps["sandbox"];
    } = {}): Harness {
      const adds: AddRecord[] = [];
      const evictCalls: Array<[string, string]> = [];
      const nowMs = opts.nowMs ?? T0;
      const entries = opts.entries ?? [];
      const sandbox =
        opts.sandbox ??
        ({
          authoritative: opts.authoritative !== false,
          async listWarmWorkspaces(): Promise<WarmWorkspaceEntry[]> {
            return entries;
          },
          async evictWorkspace(userId: string, sessionId: string): Promise<void> {
            evictCalls.push([userId, sessionId]);
          },
        } as WarmDeps["sandbox"]);

      const hibernateQueue: HibernateQueue = {
        add(name, job, addOpts) {
          adds.push({ name, job, opts: addOpts });
          return { id: addOpts.jobId };
        },
      };
      const hydrationScan: StuckHydrationScan = { listStuckHydrating };

      const deps: WarmDeps = {
        db,
        events: createRedisEventLog(redis),
        storage: baseStorage,
        workspacesRoot: wsRoot,
        sandbox,
        activity: createActivityTracker(redis, {
          keyPrefix: ACTIVITY_PREFIX,
          clock: () => new Date(nowMs),
        }),
        clock: () => new Date(nowMs),
        fileManifests: warmFileManifests,
        workspaceObjects: workspaceObjectsRepo,
        runs: runsRepo,
        eventMirror: eventMirrorRepo,
        stuckHibernationScan: { listStuck },
        queues: { hibernate: hibernateQueue },
        diskProbe: async () => opts.disk ?? DISK_OK,
        stuckHydrationScan: hydrationScan,
        coldRowScan: { listColdRows },
      };
      return { deps, adds, evictCalls };
    }

    function entry(uid: string, sid: string, bytes: number): WarmWorkspaceEntry {
      return { userId: uid, sessionId: sid, bytes, lastAccessMs: null };
    }

    async function systemNotes(sid: string) {
      const events = await createRedisEventLog(redis).readSince(sid, null, 50);
      return events.filter((e) => e.type === "system_note");
    }

    // -- reconcile -----------------------------------------------------------

    it("registers seam entries as warm rows with exact bytes, idempotently", async () => {
      const sids: string[] = [];
      const entries: WarmWorkspaceEntry[] = [];
      for (const bytes of [100, 200, 300]) {
        const uid = await seedUser();
        const sid = await seedSession(uid);
        sids.push(sid);
        entries.push(entry(uid, sid, bytes));
      }

      const h = makeHarness({ entries });
      const first = await reconcileWarmRegistry(h.deps, CFG, { now: new Date(T0) });

      expect(first.registered).toBe(3);
      expect(first.reset).toBe(0);
      expect(first.totalWarmBytes).toBe(600);
      expect(first.disk).toEqual(DISK_OK);

      for (let i = 0; i < sids.length; i++) {
        const row = await fileManifestsRepo.get(db, sids[i]!);
        expect(row!.state).toBe("warm");
        expect(row!.workspaceBytes).toBe(entries[i]!.bytes);
      }

      const second = await reconcileWarmRegistry(h.deps, CFG, { now: new Date(T0) });
      expect(second.registered).toBe(0);
      expect(second.totalWarmBytes).toBe(600);
    });

    it("refreshes a stale warm row's workspaceBytes from the seam (10-min guard)", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      await seedWarmRow(uid, sid, 111);
      await pinUpdatedAt(sid, T0 - WARM_DU_REFRESH_MS - 1_000);

      const h = makeHarness({ entries: [entry(uid, sid, 999)] });
      const out = await reconcileWarmRegistry(h.deps, CFG, { now: new Date(T0) });

      expect(out.registered).toBe(0);
      expect(out.totalWarmBytes).toBe(999);
      expect((await fileManifestsRepo.get(db, sid))!.workspaceBytes).toBe(999);
    });

    it("closes a warm row with no seam entry cold from its verified archive", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid, 4096);
      await hibernateFixture(uid, sid);
      // Post-hydrate truth: warm again, archive ledger retained.
      await fileManifestsRepo.markWarm(db, { sessionId: sid, workspaceBytes: 4096 });

      const h = makeHarness({ entries: [] });
      const out = await reconcileWarmRegistry(h.deps, CFG, { now: new Date(T0) });

      expect(out.registered).toBe(0);
      const row = await fileManifestsRepo.get(db, sid);
      expect(row!.state).toBe("cold");
      expect(row!.generation).toBe(1);
      expect(row!.archiveKey).toBe(r2Keys.workspaceArchive(uid, sid));
      expect(row!.uiTree.totals.files).toBe(2);
      expect(row!.workspaceBytes).toBeNull();
    });

    it("removes a warm row with no seam entry and no archive + workspace_lost note", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      await seedWarmRow(uid, sid, 42);

      const h = makeHarness({ entries: [] });
      await reconcileWarmRegistry(h.deps, CFG, { now: new Date(T0) });

      expect(await fileManifestsRepo.get(db, sid)).toBeNull();
      const notes = await systemNotes(sid);
      expect(notes).toHaveLength(1);
      expect(notes[0]!.payload).toEqual({ code: "workspace_lost" });
      const mirrored = await eventMirrorRepo.readSince(db, sid, null, 50);
      expect(
        mirrored.some(
          (e) =>
            e.type === "system_note" &&
            (e.payload as { code?: string }).code === "workspace_lost",
        ),
      ).toBe(true);
    });

    it("pre-P2 noop seam is non-authoritative: [] never archives registered rows", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      await seedWarmRow(uid, sid, 42);

      const lines: string[] = [];
      const h = makeHarness({
        sandbox: createNoopSandboxEviction((m) => lines.push(m)),
      });
      const out = await reconcileWarmRegistry(h.deps, CFG, { now: new Date(T0) });

      expect(out.registered).toBe(0);
      expect(out.totalWarmBytes).toBe(42);
      expect((await fileManifestsRepo.get(db, sid))!.state).toBe("warm");
      expect(await systemNotes(sid)).toHaveLength(0);
    });

    it("reclaims a cold row's leftover dir when the archive is present (T8-F1)", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid, 4096);
      await hibernateFixture(uid, sid); // row cold, dir gone
      // Crash after markCold, before fs.rm: the old dir is still there, and
      // the seam no longer lists the session (hibernate already evicted it).
      await mkdir(join(dir, "junk"), { recursive: true });
      await writeFile(join(dir, "junk", "stale.txt"), "must not survive");

      const h = makeHarness({ entries: [] });
      await reconcileWarmRegistry(h.deps, CFG, { now: new Date(T0) });

      expect(await pathExists(dir)).toBe(false);
      expect((await fileManifestsRepo.get(db, sid))!.state).toBe("cold");
    });

    it("leaves cold residue alone when the archive is missing (never the last copy)", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid, 4096);
      await hibernateFixture(uid, sid);
      await baseStorage.delete(r2Keys.workspaceArchive(uid, sid));
      await mkdir(dir, { recursive: true });
      await writeFile(join(dir, "keep.txt"), "only copy");

      const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
      try {
        const h = makeHarness({ entries: [] });
        await reconcileWarmRegistry(h.deps, CFG, { now: new Date(T0) });
      } finally {
        warn.mockRestore();
      }

      expect(await pathExists(join(dir, "keep.txt"))).toBe(true);
      expect((await fileManifestsRepo.get(db, sid))!.state).toBe("cold");
    });

    // -- enforceWarmCap ------------------------------------------------------

    it("evicts the least-recently-active session once the byte cap is exceeded", async () => {
      const uid = await seedUser();
      const s1 = await seedSession(uid);
      const s2 = await seedSession(uid);
      await seedWarmRow(uid, s1, 100);
      await seedWarmRow(uid, s2, 200);

      // s2 is oldest; cap = 1.5 × the 100-byte smallest entry = 150.
      const activity = createActivityTracker(redis, {
        keyPrefix: ACTIVITY_PREFIX,
        clock: () => new Date(T0 - 10_000),
      });
      await activity.bump(s1);
      await createActivityTracker(redis, {
        keyPrefix: ACTIVITY_PREFIX,
        clock: () => new Date(T0 - 200_000),
      }).bump(s2);

      const h = makeHarness({ nowMs: T0 });
      const out = await enforceWarmCap(
        h.deps,
        { maxWarmBytes: 150, diskAlertFraction: 0.8 },
        {},
      );

      expect(out).toEqual({ evicted: 1, freedBytes: 200 });
      expect(h.adds).toHaveLength(1);
      expect(h.adds[0]!.name).toBe(HIBERNATE_JOB_NAME);
      expect(h.adds[0]!.job).toEqual({
        sessionId: s2,
        userId: uid,
        generation: 1,
        reason: "pressure",
      });
      expect(h.adds[0]!.opts.jobId).toBe(storageJobId(s2, 1));
    });

    it("disk alert evicts the oldest even under the byte cap", async () => {
      const uid = await seedUser();
      const s1 = await seedSession(uid);
      const s2 = await seedSession(uid);
      await seedWarmRow(uid, s1, 100);
      await seedWarmRow(uid, s2, 100);

      await createActivityTracker(redis, {
        keyPrefix: ACTIVITY_PREFIX,
        clock: () => new Date(T0 - 10_000),
      }).bump(s1);
      await createActivityTracker(redis, {
        keyPrefix: ACTIVITY_PREFIX,
        clock: () => new Date(T0 - 200_000),
      }).bump(s2);

      const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
      try {
        const h = makeHarness({ nowMs: T0, disk: DISK_ALERT });
        const out = await enforceWarmCap(
          h.deps,
          { maxWarmBytes: 1_000_000, diskAlertFraction: 0.8 },
          { maxEvictions: 1 },
        );

        expect(out.evicted).toBe(1);
        expect(h.adds[0]!.job.sessionId).toBe(s2);
        expect(h.adds[0]!.job.reason).toBe("pressure");
        expect(warn).toHaveBeenCalledTimes(1);

        // ONE disk_pressure note on the first crossing, with an integer pct.
        const notes = await systemNotes(s2);
        expect(notes).toHaveLength(1);
        expect(notes[0]!.payload).toEqual({ code: "disk_pressure", usedPct: 85 });

        // A second pass is not a first crossing: no new warning/note.
        await enforceWarmCap(
          h.deps,
          { maxWarmBytes: 1_000_000, diskAlertFraction: 0.8 },
          { maxEvictions: 1 },
        );
        expect(warn).toHaveBeenCalledTimes(1);
        expect(await systemNotes(s2)).toHaveLength(1);
      } finally {
        warn.mockRestore();
      }
    });

    it("maxEvictions bounds the pass (anti-thrash)", async () => {
      const uid = await seedUser();
      const sids: string[] = [];
      for (const bytes of [10, 20, 30]) {
        const sid = await seedSession(uid);
        sids.push(sid);
        await seedWarmRow(uid, sid, bytes);
      }

      const h = makeHarness({ nowMs: T0 });
      const out = await enforceWarmCap(
        h.deps,
        { maxWarmBytes: 0, diskAlertFraction: 0.8 },
        { maxEvictions: 2 },
      );

      expect(out.evicted).toBe(2);
      expect(h.adds).toHaveLength(2);
      expect(new Set(h.adds.map((a) => a.job.sessionId))).toEqual(
        new Set(sids.slice(0, 2)),
      );
    });
  },
);
