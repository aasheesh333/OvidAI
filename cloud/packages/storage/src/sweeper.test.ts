/**
 * Task 10 idle sweeper tests.
 *
 * Same shared-dev-service discipline as warmLru.test.ts: migrate-only, unique
 * rows/keys, and every scan wrapped to THIS run's sessions (the landed
 * `listWarmForLru` is global; production wants that, tests must not).
 */

import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { Redis } from "ioredis";
import type { WorkspaceState } from "@ovid/shared";

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
import type {
  StuckHibernationRow,
  WarmWorkspaceEntry,
} from "./hibernate.js";
import { workspaceDir } from "./workspacePaths.js";
import { sweepWorkspaces } from "./sweeper.js";
import {
  IDLE_THRESHOLD_MS,
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

const T0 = 1_700_000_000_000;
const RUN_TAG = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
const ACTIVITY_PREFIX = `ovid-test-sweep-${RUN_TAG}:`;

const DISK_OK: DiskUsage = { totalBytes: 1000, freeBytes: 500, usedFraction: 0.5 };
const CFG: WarmConfig = { maxWarmBytes: 1_000_000, diskAlertFraction: 0.8 };

async function pathExists(p: string): Promise<boolean> {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "idle sweeper — reconcile, idle enqueue, pressure",
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
      storageRoot = await mkdtemp(join(tmpdir(), "ovid-sweep-store-"));
      wsRoot = await mkdtemp(join(tmpdir(), "ovid-sweep-ws-"));
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
      await db.insert(usersTable).values({ uid, email: `sweep-${uid.slice(0, 8)}@test.local` });
      return uid;
    }

    async function seedSession(uid: string): Promise<string> {
      const s = await sessionsRepo.create(db, uid, "sweeper-test");
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

    async function bumpAt(sid: string, ms: number): Promise<void> {
      await createActivityTracker(redis, {
        keyPrefix: ACTIVITY_PREFIX,
        clock: () => new Date(ms),
      }).bump(sid);
    }

    async function pinUpdatedAt(sid: string, ms: number): Promise<void> {
      await db.$client.unsafe(`UPDATE file_manifests SET updated_at = $1 WHERE session_id = $2`, [
        new Date(ms).toISOString(),
        sid,
      ]);
    }

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

    const warmFileManifests: WarmFileManifestsRepo = {
      ...fileManifestsRepo,
      async listWarmForLru(handle: unknown): Promise<WarmRowView[]> {
        const rows = await fileManifestsRepo.listWarmForLru(handle as Db);
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

    interface Harness {
      deps: WarmDeps;
      adds: AddRecord[];
    }

    function makeHarness(opts: {
      nowMs?: number;
      entries?: WarmWorkspaceEntry[];
      disk?: DiskUsage;
      authoritative?: boolean;
    } = {}): Harness {
      const adds: AddRecord[] = [];
      const nowMs = opts.nowMs ?? T0;
      const entries = opts.entries ?? [];
      const sandbox: WarmDeps["sandbox"] = {
        authoritative: opts.authoritative !== false,
        async listWarmWorkspaces(): Promise<WarmWorkspaceEntry[]> {
          return entries;
        },
        async evictWorkspace(): Promise<void> {},
      };
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
        sandboxUid: async (userId: string) => userId,
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
      };
      return { deps, adds };
    }

    function entry(uid: string, sid: string, bytes: number): WarmWorkspaceEntry {
      return { userId: uid, sessionId: sid, bytes, lastAccessMs: null };
    }

    // -- idle pass -----------------------------------------------------------

    it("enqueues idle hibernate for the stale session only", async () => {
      const uid = await seedUser();
      const s1 = await seedSession(uid);
      const s2 = await seedSession(uid);
      const s3 = await seedSession(uid);
      await seedWarmRow(uid, s1, 100);
      await seedWarmRow(uid, s2, 100);
      await seedWarmRow(uid, s3, 100);
      await bumpAt(s1, T0 - 10_000);
      await bumpAt(s2, T0 - 200_000);
      await bumpAt(s3, T0 - 50_000);

      const h = makeHarness({
        nowMs: T0,
        entries: [entry(uid, s1, 100), entry(uid, s2, 100), entry(uid, s3, 100)],
      });
      const out = await sweepWorkspaces(h.deps, CFG, { now: new Date(T0) });

      expect(out.registered).toBe(0);
      expect(out.enqueuedIdle).toBe(1);
      expect(out.enqueuedPressure).toBe(0);
      expect(h.adds).toHaveLength(1);
      expect(h.adds[0]!.name).toBe(HIBERNATE_JOB_NAME);
      expect(h.adds[0]!.job).toEqual({
        sessionId: s2,
        userId: uid,
        generation: 1,
        reason: "idle",
      });
      expect(h.adds[0]!.opts.jobId).toBe(storageJobId(s2, 1));
    });

    it("falls back to row.updatedAt when the activity key is missing", async () => {
      const uid = await seedUser();
      const s3 = await seedSession(uid);
      await seedWarmRow(uid, s3, 100);
      await pinUpdatedAt(s3, T0 - 200_000); // no activity bump at all

      const h = makeHarness({ nowMs: T0, entries: [entry(uid, s3, 100)] });
      const out = await sweepWorkspaces(h.deps, CFG, { now: new Date(T0) });

      expect(out.enqueuedIdle).toBe(1);
      expect(h.adds.map((a) => a.job.sessionId)).toEqual([s3]);
      expect(h.adds[0]!.job.reason).toBe("idle");
    });

    it("registers a fresh session and evaluates it in the SAME pass", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await mkdir(dir, { recursive: true });

      // A future "now" makes the row registered at DB now() already stale.
      const now = new Date(Date.now() + IDLE_THRESHOLD_MS + 5_000);
      const h = makeHarness({
        nowMs: now.getTime(),
        entries: [entry(uid, sid, 123)],
      });
      const out = await sweepWorkspaces(h.deps, CFG, { now });

      expect(out.registered).toBe(1);
      expect(out.enqueuedIdle).toBe(1);
      expect(h.adds).toHaveLength(1);
      expect(h.adds[0]!.job.sessionId).toBe(sid);
      expect(h.adds[0]!.job.reason).toBe("idle");
      expect((await fileManifestsRepo.get(db, sid))!.workspaceBytes).toBe(123);
    });

    // -- crash recovery ------------------------------------------------------

    it("delegates a stuck hibernating row with its dir present back to warm", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await mkdir(dir, { recursive: true });
      await writeFile(join(dir, "keep.txt"), "warm data");
      await seedWarmRow(uid, sid, 777);
      expect(await fileManifestsRepo.beginHibernation(db, sid)).toBe(true);
      await pinUpdatedAt(sid, T0 - 20 * 60_000); // > STUCK_STATE_MS

      const h = makeHarness({ nowMs: T0, entries: [] });
      const out = await sweepWorkspaces(h.deps, CFG, { now: new Date(T0) });

      expect(out.enqueuedIdle).toBe(0); // just restored; not idle yet
      const row = await fileManifestsRepo.get(db, sid);
      expect(row!.state).toBe("warm");
      expect(row!.workspaceBytes).toBe(777);
      expect(await pathExists(join(dir, "keep.txt"))).toBe(true);
    });

    it("resets a hard-crash 'hydrating' row to cold and wipes the partial dir (T9-I1)", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWarmRow(uid, sid, 123);
      await db.$client.unsafe(
        `UPDATE file_manifests SET state = 'hydrating', updated_at = $1 WHERE session_id = $2`,
        [new Date(T0 - 20 * 60_000).toISOString(), sid],
      );
      await mkdir(join(dir, "partial"), { recursive: true });
      await writeFile(join(dir, "partial", "half.txt"), "incomplete extraction");

      const h = makeHarness({ nowMs: T0, entries: [] });
      await sweepWorkspaces(h.deps, CFG, { now: new Date(T0) });

      const row = await fileManifestsRepo.get(db, sid);
      expect(row!.state).toBe("cold");
      expect(await pathExists(dir)).toBe(false);
      expect(h.adds).toHaveLength(0); // cold rows are not idle candidates
    });

    // -- never throws --------------------------------------------------------

    it("resolves and logs when the disk probe throws (setInterval caller safety)", async () => {
      const h = makeHarness({ nowMs: T0, entries: [] });
      h.deps.diskProbe = async () => {
        throw new Error("probe boom");
      };
      const error = vi.spyOn(console, "error").mockImplementation(() => {});
      try {
        const out = await sweepWorkspaces(h.deps, CFG, { now: new Date(T0) });
        expect(out).toEqual({ registered: 0, enqueuedIdle: 0, enqueuedPressure: 0 });
        expect(error).toHaveBeenCalled();
        const text = error.mock.calls.map((c) => String(c[0])).join("\n");
        expect(text).toMatch(/reconcileWarmRegistry failed/);
        expect(text).toMatch(/enforceWarmCap failed/);
      } finally {
        error.mockRestore();
      }
    });
  },
);
