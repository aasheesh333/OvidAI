/**
 * Task 11 follow-up (P7-T10 review carry): the worker's storage scans are the
 * production wiring for the engines' injected structural mirrors. This pins
 * the T8-F1 cold-row residue path END TO END: a real hibernate leaves a cold
 * row, a simulated crash leaves its warm dir behind, and the real
 * `createColdRowScan` + `reconcileWarmRegistry` reclaim it — without any raw
 * workspace-tree walk (ruling R1).
 */

import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Redis } from "ioredis";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createDb,
  eventMirror as eventMirrorRepo,
  fileManifests as fileManifestsRepo,
  migrate,
  newId,
  runs as runsRepo,
  sessions as sessionsRepo,
  users,
  workspaceObjects as workspaceObjectsRepo,
  type Db,
} from "@ovid/db";
import { createRedisEventLog, type EventLog } from "@ovid/events";
import {
  createFsStorage,
  createNoopSandboxEviction,
  hibernateWorkspace,
  reconcileWarmRegistry,
  workspaceDir,
  type StorageAdapter,
  type WarmConfig,
  type WarmDeps,
} from "@ovid/storage";
import { createColdRowScan, createStuckHydrationScan } from "./storageScans.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "storageScans — cold-row residue reclaim (T8-F1)",
  () => {
    let db: Db;
    let redis: Redis;
    let events: EventLog;
    let storage: StorageAdapter;
    let storageRoot: string;
    let workspacesRoot: string;
    const createdSessions: string[] = [];
    const createdUsers: string[] = [];

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      redis = new Redis(TEST_REDIS_URL!);
      events = createRedisEventLog(redis);
      storageRoot = await mkdtemp(join(tmpdir(), "ovid-scans-store-"));
      workspacesRoot = await mkdtemp(join(tmpdir(), "ovid-scans-ws-"));
      storage = createFsStorage(storageRoot);
    }, 120_000);

    afterAll(async () => {
      if (redis && createdSessions.length > 0) {
        await redis
          .del(...createdSessions.map((sid) => `sess:${sid}:events`))
          .catch(() => {});
      }
      if (db && createdSessions.length > 0) {
        try {
          await db.$client.unsafe(
            `DELETE FROM session_event_mirror WHERE session_id = ANY($1)`,
            [createdSessions],
          );
          await db.$client.unsafe(
            `DELETE FROM workspace_objects WHERE session_id = ANY($1)`,
            [createdSessions],
          );
          await db.$client.unsafe(`DELETE FROM file_manifests WHERE session_id = ANY($1)`, [
            createdSessions,
          ]);
          await db.$client.unsafe(`DELETE FROM sessions WHERE id = ANY($1)`, [createdSessions]);
          if (createdUsers.length > 0) {
            await db.$client.unsafe(`DELETE FROM users WHERE uid = ANY($1)`, [createdUsers]);
          }
        } catch {
          // best-effort dev hygiene
        }
      }
      redis?.disconnect();
      await db?.$client.end({ timeout: 5 });
      if (storageRoot) await rm(storageRoot, { recursive: true, force: true });
      if (workspacesRoot) await rm(workspacesRoot, { recursive: true, force: true });
    });

    const cfg: WarmConfig = {
      maxWarmBytes: 8 * 1024 ** 3,
      diskAlertFraction: 0.8,
    };

    function makeWarmDeps(): WarmDeps {
      return {
        db,
        events,
        storage,
        workspacesRoot,
        sandboxUid: async (userId: string) => userId,
        sandbox: createNoopSandboxEviction(),
        activity: {
          async bump() {},
          async read() {
            return null;
          },
          async readMany() {
            return new Map();
          },
        },
        fileManifests: fileManifestsRepo,
        workspaceObjects: workspaceObjectsRepo,
        runs: runsRepo,
        eventMirror: eventMirrorRepo,
        stuckHibernationScan: { listStuck: async () => [] },
        queues: { hibernate: { add: () => undefined } },
        stuckHydrationScan: createStuckHydrationScan(),
        coldRowScan: createColdRowScan(),
        diskProbe: async () => ({
          totalBytes: 100,
          freeBytes: 50,
          usedFraction: 0.5,
        }),
      };
    }

    it("reclaims a cold row's crash-leftover dir (real scan + reconcile)", async () => {
      const uid = newId();
      createdUsers.push(uid);
      await users.ensure(db, uid, `scans-${uid.slice(0, 8)}@test.local`);
      const session = await sessionsRepo.create(db, uid);
      createdSessions.push(session.id);
      const sid = session.id;
      const dir = workspaceDir(workspacesRoot, uid, sid);

      // Warm the session and hibernate it: the row goes cold, the dir is gone.
      await mkdir(join(dir, "notes"), { recursive: true });
      await writeFile(join(dir, "notes", "a.txt"), "residue payload\n");
      await fileManifestsRepo.upsertWarm(db, {
        sessionId: sid,
        userId: uid,
        workspaceBytes: null,
      });
      const hib = await hibernateWorkspace(makeWarmDeps(), {
        sessionId: sid,
        userId: uid,
        generation: 1,
        reason: "manual",
      });
      expect(hib.status).toBe("hibernated");
      await expect(stat(dir)).rejects.toBeTruthy();

      // Simulate the crash window: markCold committed, fs.rm never ran.
      await mkdir(join(dir, "notes"), { recursive: true });
      await writeFile(join(dir, "notes", "a.txt"), "residue payload\n");
      expect((await fileManifestsRepo.get(db, sid))?.state).toBe("cold");

      // The production scan sees it and the reconcile reclaims it.
      const cold = await createColdRowScan().listColdRows(db, { limit: 200 });
      expect(cold.some((r) => r.sessionId === sid)).toBe(true);

      const out = await reconcileWarmRegistry(makeWarmDeps(), cfg);
      expect(out).toBeDefined();
      await expect(stat(dir)).rejects.toBeTruthy();

      const after = await fileManifestsRepo.get(db, sid);
      expect(after?.state).toBe("cold");
      expect(after?.archiveKey).not.toBeNull();
    });
  },
);
