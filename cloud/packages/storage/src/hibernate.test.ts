import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Redis } from "ioredis";
import { uiManifestSchema, type WorkspaceState } from "@ovid/shared";

// Relative-source imports (Task-1 fix-round precedent; ledgered caveat:
// convert to real dev-dependencies at the next lockfile touch). @ovid/db and
// @ovid/events are NOT pnpm-linked into @ovid/storage — under the
// parallel-wave NO-lockfile rule this suite cannot declare them, so it pins
// the real packages' source directly. hibernate.ts itself consumes them only
// through structural mirrors (see its header), which the assignments below
// prove fit the real namespaces.
import { createDb, migrate, type Db } from "../../db/src/client.js";
import {
  eventMirror as eventMirrorRepo,
  fileManifests as fileManifestsRepo,
  newId,
  runs as runsRepo,
  sessions as sessionsRepo,
  workspaceObjects as workspaceObjectsRepo,
} from "../../db/src/repos.js";
import {
  runs as runsTable,
  users as usersTable,
  workspaceObjects as workspaceObjectsTable,
} from "../../db/src/schema.js";
import { createRedisEventLog } from "../../events/src/eventLog.js";

import { createActivityTracker } from "./activity.js";
import type { StorageAdapter } from "./adapter.js";
import { StorageError } from "./errors.js";
import {
  HIBERNATE_IDLE_MS,
  createNoopSandboxEviction,
  hibernateWorkspace,
  reconcileStuckHibernations,
  type HibernateDeps,
  type HibernateJobInput,
  type StuckHibernationRow,
} from "./hibernate.js";
import { r2Keys } from "./keys.js";
import { openReader } from "./rangeReader.js";
import {
  decodeIndexWire,
  encodeIndexWire,
  packToStorage,
  type ArchiveIndex,
} from "./archive/pack.js";
import { readIndex } from "./archive/readIndex.js";
import { uiTree } from "./archive/uiTree.js";
import { workspaceDir } from "./workspacePaths.js";
import { createFsStorage } from "./fsAdapter.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

/** Fixed "now" for clock-injected pins (2023-11-14T22:13:20Z). */
const T0 = 1_700_000_000_000;

const A_TXT = "alpha-alpha-alpha";
const B_TXT = "beta".repeat(100);
const RUN_SH = "#!/bin/sh\necho hibernate-ok\n";
/** a.txt, sub, sub/b.txt, run.sh, link — every member the index carries. */
const ENTRY_COUNT = 5;
const TOTAL_FILES = 3;
const TOTAL_DIRS = 1;
const TOTAL_BYTES =
  Buffer.byteLength(A_TXT) + Buffer.byteLength(B_TXT) + Buffer.byteLength(RUN_SH);

const RUN_TAG = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
const ACTIVITY_PREFIX = `ovid-test-hib-${RUN_TAG}:`;

async function pathExists(p: string): Promise<boolean> {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Pre-P2 stand-in — pure, no services needed.
// ---------------------------------------------------------------------------

describe("createNoopSandboxEviction (pre-P2 stand-in)", () => {
  it("HIBERNATE_IDLE_MS is the G7 3-minute idle threshold", () => {
    expect(HIBERNATE_IDLE_MS).toBe(180_000);
  });

  it("lists nothing, logs the empty list exactly once, and resolves evicts with TODO(P2) markers", async () => {
    const lines: string[] = [];
    const eviction = createNoopSandboxEviction((m) => lines.push(m));
    expect(await eviction.listWarmWorkspaces()).toEqual([]);
    await eviction.listWarmWorkspaces(); // second call stays silent
    expect(lines.filter((l) => l.includes("listWarmWorkspaces"))).toHaveLength(1);
    await eviction.evictWorkspace("u1", "s1");
    expect(
      lines.some((l) => l.includes("TODO(P2)") && l.includes("u1") && l.includes("s1")),
    ).toBe(true);
  });

  it("works without a logger", async () => {
    const eviction = createNoopSandboxEviction();
    await expect(eviction.listWarmWorkspaces()).resolves.toEqual([]);
    await expect(eviction.evictWorkspace("u", "s")).resolves.toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// Gated harness — real postgres + real redis + fs storage over mkdtemp.
//
// This suite NEVER drops/recreates the shared dev schema (unlike @ovid/db's
// own suites): parallel-wave agents run their own DB tests against the same
// TEST_DATABASE_URL, and a DROP would destroy their in-flight state. Instead
// migrate() is applied (idempotent) and every row/key this suite creates is
// uniquely keyed and deleted in afterAll.
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "hibernation engine — pack, verified upload, crash-safe evict",
  () => {
    let db: Db;
    let redis: Redis;
    let storageRoot: string;
    let wsRoot: string;
    let baseStorage: StorageAdapter;
    const createdSids: string[] = [];
    const createdUids: string[] = [];

    beforeAll(async () => {
      // drizzle's client wrapper overwrites postgres.js's Date serializer, so
      // unsafe() params below pass ISO STRINGS (never Date objects); migrate()
      // is retried — parallel-wave agents mutate this shared dev DB live.
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
      storageRoot = await mkdtemp(join(tmpdir(), "ovid-hib-store-"));
      wsRoot = await mkdtemp(join(tmpdir(), "ovid-hib-ws-"));
      baseStorage = createFsStorage(storageRoot);
    }, 120_000);

    afterAll(async () => {
      // Redis: only this run's stream + activity keys (shared dev redis —
      // FLUSHDB and other suites' keys are off-limits).
      if (redis) {
        const keys = createdSids.flatMap((sid) => [
          `sess:${sid}:events`,
          `${ACTIVITY_PREFIX}${sid}`,
        ]);
        if (keys.length > 0) await redis.del(...keys).catch(() => {});
        await redis.quit().catch(() => {});
      }
      // Postgres: only this run's rows, children first (no FK cascades).
      if (db && createdSids.length > 0) {
        try {
          await db.$client.unsafe(
            `DELETE FROM session_event_mirror WHERE session_id = ANY($1)`,
            [createdSids],
          );
          await db.$client.unsafe(`DELETE FROM runs WHERE session_id = ANY($1)`, [createdSids]);
          await db.$client.unsafe(`DELETE FROM messages WHERE session_id = ANY($1)`, [
            createdSids,
          ]);
          await db.$client.unsafe(`DELETE FROM file_manifests WHERE session_id = ANY($1)`, [
            createdSids,
          ]);
          await db.$client.unsafe(`DELETE FROM workspace_objects WHERE session_id = ANY($1)`, [
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

    // -- fixtures ------------------------------------------------------------

    async function seedUser(): Promise<string> {
      const uid = newId();
      createdUids.push(uid);
      await db.insert(usersTable).values({ uid, email: `hib-${uid.slice(0, 8)}@test.local` });
      return uid;
    }

    async function seedSession(uid: string): Promise<string> {
      const s = await sessionsRepo.create(db, uid, "hibernate-test");
      createdSids.push(s.id);
      return s.id;
    }

    async function seedWorkspace(dir: string): Promise<void> {
      await mkdir(join(dir, "sub"), { recursive: true });
      await writeFile(join(dir, "a.txt"), A_TXT);
      await writeFile(join(dir, "sub", "b.txt"), B_TXT);
      await writeFile(join(dir, "run.sh"), RUN_SH);
      await chmod(join(dir, "run.sh"), 0o755); // exec bit rides through the archive
      await symlink("a.txt", join(dir, "link"));
    }

    async function seedWarmRow(
      uid: string,
      sid: string,
      workspaceBytes: number | null = 4096,
    ): Promise<void> {
      await fileManifestsRepo.upsertWarm(db, { sessionId: sid, userId: uid, workspaceBytes });
    }

    function jobFor(
      uid: string,
      sid: string,
      generation: number,
      reason: HibernateJobInput["reason"] = "idle",
    ): HibernateJobInput {
      return { sessionId: sid, userId: uid, generation, reason };
    }

    /** The real-repo stuck-row scan injected into the deps (raw SQL — the test cannot import drizzle-orm, and @ovid/db has no such repo yet). */
    async function listStuck(dbHandle: Db, olderThan: Date): Promise<StuckHibernationRow[]> {
      const rows = (await dbHandle.$client.unsafe(
        `SELECT session_id AS "sessionId", user_id AS "userId", generation, state,
                archive_key AS "archiveKey", workspace_bytes AS "workspaceBytes",
                updated_at AS "updatedAt"
           FROM file_manifests
          WHERE state = 'hibernating' AND updated_at < $1`,
        [olderThan.toISOString()],
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

    interface Harness {
      deps: HibernateDeps;
      evictCalls: Array<[string, string]>;
      opsLog: string[];
      storage: StorageAdapter;
      activity: ReturnType<typeof createActivityTracker>;
    }

    function makeHarness(opts: { storage?: StorageAdapter; nowMs?: number; bumpAtMs?: number } = {}): Harness {
      const evictCalls: Array<[string, string]> = [];
      const opsLog: string[] = [];
      const storage: StorageAdapter =
        opts.storage ??
        ({
          ...baseStorage,
          async put(key: string, body: NodeJS.ReadableStream | Buffer | Uint8Array, putOpts?: Parameters<StorageAdapter["put"]>[2]) {
            opsLog.push(`put:${key}`);
            return baseStorage.put(key, body, putOpts);
          },
          async get(key: string) {
            opsLog.push(`get:${key}`);
            return baseStorage.get(key);
          },
        } as StorageAdapter);
      const activity = createActivityTracker(redis, {
        keyPrefix: ACTIVITY_PREFIX,
        ...(opts.bumpAtMs !== undefined ? { clock: () => new Date(opts.bumpAtMs!) } : {}),
      });
      const deps: HibernateDeps = {
        db,
        events: createRedisEventLog(redis),
        storage,
        workspacesRoot: wsRoot,
        sandbox: {
          listWarmWorkspaces: async () => [],
          evictWorkspace: async (userId: string, sessionId: string) => {
            opsLog.push("evict");
            evictCalls.push([userId, sessionId]);
          },
        },
        activity,
        ...(opts.nowMs !== undefined ? { clock: () => new Date(opts.nowMs!) } : {}),
        fileManifests: fileManifestsRepo,
        workspaceObjects: workspaceObjectsRepo,
        runs: runsRepo,
        eventMirror: eventMirrorRepo,
        stuckHibernationScan: { listStuck },
      };
      return { deps, evictCalls, opsLog, storage, activity };
    }

    /** Adapter whose get() of one key replays the object with one flipped byte. */
    function flippingGetStorage(base: StorageAdapter, targetKey: string): StorageAdapter {
      return {
        ...base,
        async get(key: string): Promise<NodeJS.ReadableStream | null> {
          const stream = await base.get(key);
          if (stream === null || key !== targetKey) return stream;
          const chunks: Buffer[] = [];
          for await (const c of stream) chunks.push(c as Buffer);
          const buf = Buffer.concat(chunks);
          const mid = Math.floor(buf.length / 2);
          buf[mid] = (buf[mid] ?? 0) ^ 0x01;
          return Readable.from(buf);
        },
      } as StorageAdapter;
    }

    async function workspaceObjectRows(sid: string) {
      const all = await db.select().from(workspaceObjectsTable);
      return all.filter((r) => r.sessionId === sid);
    }

    async function hibernatedEvents(sid: string) {
      const evs = await createRedisEventLog(redis).readSince(sid, null, 10);
      return evs.filter((e) => e.type === "workspace_hibernated");
    }

    async function pinUpdatedAt(sid: string, ms: number): Promise<void> {
      // ISO string, never a Date (drizzle patches the postgres.js Date serializer)
      await db.$client.unsafe(`UPDATE file_manifests SET updated_at = $1 WHERE session_id = $2`, [
        new Date(ms).toISOString(),
        sid,
      ]);
    }

    /**
     * Re-warm rows a CRASHED earlier run of THIS suite may have stranded.
     * Scoped to sessions this suite family creates (title "hibernate-test")
     * so a parallel-wave suite's in-flight 'hibernating' rows on this shared
     * dev DB are never touched — the same only-our-rows discipline as the
     * afterAll cleanup.
     */
    async function clearStuckRows(): Promise<void> {
      await db.$client.unsafe(
        `UPDATE file_manifests SET state = 'warm'
          WHERE state = 'hibernating'
            AND session_id IN (SELECT id FROM sessions WHERE title = 'hibernate-test')`,
      );
    }

    // -- happy path ----------------------------------------------------------

    it("packs, verifies, and evicts: exact spec keys, cold row, event, dir gone", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);

      // activity aged 200 s (tracker bumped at T0, engine clock T0+200 s)
      const h = makeHarness({ bumpAtMs: T0, nowMs: T0 + 200_000 });
      const res = await hibernateWorkspace(h.deps, jobFor(uid, sid, 1));

      expect(res.status).toBe("hibernated");
      expect(res.generation).toBe(1);
      expect(res.archiveBytes).toBeGreaterThan(0);
      expect(res.ms).toBe(0); // frozen clock: elapsed pinned deterministically

      // eviction seam: exactly once, exact ids, BEFORE the first byte is put
      expect(h.evictCalls).toEqual([[uid, sid]]);
      const evictAt = h.opsLog.indexOf("evict");
      const firstPutAt = h.opsLog.findIndex((e) => e.startsWith("put:"));
      expect(evictAt).toBeGreaterThanOrEqual(0);
      expect(firstPutAt).toBeGreaterThan(evictAt);

      // archive + sidecar exist under the EXACT spec keys
      const archiveKey = r2Keys.workspaceArchive(uid, sid);
      const manifestKey = r2Keys.workspaceManifest(uid, sid);
      const stored = await readFile(join(storageRoot, archiveKey));
      const storedSha = createHash("sha256").update(stored).digest("hex");
      const sidecar = await readFile(join(storageRoot, manifestKey));

      // sidecar holds the SAME compact-array index JSON the footer hashes
      const spec = await baseStorage.readerSpec(archiveKey);
      expect(spec).not.toBeNull();
      const reader = await openReader(spec!);
      const index: ArchiveIndex = await readIndex(reader);
      await reader.close();
      expect(decodeIndexWire(sidecar)).toEqual(index);

      // workspace_objects: archive row bytes/sha match an independent hash of
      // the stored file; manifest row carries the SIDECAR's own digest
      const objRows = await workspaceObjectRows(sid);
      expect(objRows).toHaveLength(2);
      const archiveRow = objRows.find((r) => r.kind === "workspace_archive")!;
      expect(archiveRow.r2Key).toBe(archiveKey);
      expect(archiveRow.bytes).toBe(stored.length);
      expect(archiveRow.sha256).toBe(storedSha);
      expect(archiveRow.generation).toBe(1);
      expect(archiveRow.meta).toEqual({ entryCount: ENTRY_COUNT, zstdLevel: 9 });
      const manifestRow = objRows.find((r) => r.kind === "workspace_manifest")!;
      expect(manifestRow.r2Key).toBe(manifestKey);
      expect(manifestRow.bytes).toBe(sidecar.length);
      expect(manifestRow.sha256).toBe(createHash("sha256").update(sidecar).digest("hex"));

      // file_manifests: cold, generation 1, schema-valid uiTree
      const row = await fileManifestsRepo.get(db, sid);
      expect(row!.state).toBe("cold");
      expect(row!.generation).toBe(1);
      expect(row!.archiveKey).toBe(archiveKey);
      expect(row!.archiveBytes).toBe(stored.length);
      expect(row!.archiveSha256).toBe(storedSha);
      expect(row!.entryCount).toBe(ENTRY_COUNT);
      expect(row!.workspaceBytes).toBeNull(); // warm du dropped on cold
      const tree = uiManifestSchema.parse(row!.uiTree);
      expect(tree.version).toBe(1);
      expect(tree.truncated).toBe(false);
      expect(tree.totals).toEqual({ files: TOTAL_FILES, dirs: TOTAL_DIRS, bytes: TOTAL_BYTES });

      // local data is GONE — deleted strictly after the verified upload
      expect(await pathExists(dir)).toBe(false);

      // event readable via readSince with the exact payload + durable mirror
      const hibEvents = await hibernatedEvents(sid);
      expect(hibEvents).toHaveLength(1);
      expect(hibEvents[0]!.payload).toEqual({
        generation: 1,
        archiveBytes: stored.length,
        ms: 0,
      });
      const mirrored = await eventMirrorRepo.readSince(db, sid, null, 10);
      const mirroredHib = mirrored.filter((e) => e.type === "workspace_hibernated");
      expect(mirroredHib).toHaveLength(1);
      expect(mirroredHib[0]!.seq).toBe(hibEvents[0]!.seq);
      expect(mirroredHib[0]!.payload).toEqual(hibEvents[0]!.payload);
    });

    // -- verify-blocks -------------------------------------------------------

    it("skips active_run (AG1): a session with a running run is never evicted", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);
      await db.insert(runsTable).values({
        id: newId(),
        sessionId: sid,
        status: "running",
        startedAt: new Date(),
      });

      const h = makeHarness({ nowMs: T0 + 200_000 });
      const res = await hibernateWorkspace(h.deps, jobFor(uid, sid, 1));

      expect(res).toEqual({ status: "skipped", reason: "active_run" });
      expect(await pathExists(dir)).toBe(true);
      expect(h.evictCalls).toHaveLength(0);
    });

    it("skips recent_activity: a bump 10 s old beats the 3-minute idle threshold", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);

      const h = makeHarness({ bumpAtMs: T0, nowMs: T0 + 10_000 });
      await h.activity.bump(sid); // last activity at T0; "now" is T0 + 10 s
      const res = await hibernateWorkspace(h.deps, jobFor(uid, sid, 1));

      expect(res).toEqual({ status: "skipped", reason: "recent_activity" });
      expect(await pathExists(dir)).toBe(true);
      expect(h.evictCalls).toHaveLength(0);
    });

    it("manual reason bypasses recent_activity: an explicit hibernate right after a write still packs", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);

      // The user's PUT (and the hydrate that served it) bumped activity 10 s
      // ago. The sweeper would skip, but the explicit control must not: the
      // manual POST hibernate is the user overriding the idle policy.
      const h = makeHarness({ bumpAtMs: T0, nowMs: T0 + 10_000 });
      await h.activity.bump(sid);
      const res = await hibernateWorkspace(h.deps, jobFor(uid, sid, 1, "manual"));

      expect(res.status).toBe("hibernated");
      expect(res.generation).toBe(1);
      expect(await pathExists(dir)).toBe(false);
      expect((await fileManifestsRepo.get(db, sid))!.state).toBe("cold");
    });

    it("skips stale_generation: a job two generations ahead dedupes re-deliveries", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid); // generation 0

      const h = makeHarness({ nowMs: T0 + 200_000 });
      const res = await hibernateWorkspace(h.deps, jobFor(uid, sid, 2)); // row.generation + 2

      expect(res).toEqual({ status: "skipped", reason: "stale_generation", generation: 0 });
      expect(await pathExists(dir)).toBe(true);
      expect(h.evictCalls).toHaveLength(0);
      expect((await fileManifestsRepo.get(db, sid))!.state).toBe("warm");
    });

    it("skips not_warm when there is neither a dir nor a row", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);

      const h = makeHarness({ nowMs: T0 + 200_000 });
      const res = await hibernateWorkspace(h.deps, jobFor(uid, sid, 1));

      expect(res).toEqual({ status: "skipped", reason: "not_warm" });
      expect(h.evictCalls).toHaveLength(0);
    });

    it("a verify failure (one flipped byte on re-download) rejects StorageError and leaves everything intact", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid, 1234);

      const archiveKey = r2Keys.workspaceArchive(uid, sid);
      const h = makeHarness({
        storage: flippingGetStorage(baseStorage, archiveKey),
        nowMs: T0 + 200_000,
      });
      await expect(hibernateWorkspace(h.deps, jobFor(uid, sid, 1))).rejects.toBeInstanceOf(
        StorageError,
      );

      // row back to warm with the prior du; no cold marker anywhere
      const row = await fileManifestsRepo.get(db, sid);
      expect(row!.state).toBe("warm");
      expect(row!.workspaceBytes).toBe(1234);
      expect(row!.generation).toBe(0);
      expect(row!.archiveKey).toBeNull();
      expect(await workspaceObjectRows(sid)).toHaveLength(0);
      expect(await hibernatedEvents(sid)).toHaveLength(0);

      // dir INTACT — local data is never destroyed on an unverified upload
      expect(await pathExists(dir)).toBe(true);
      expect(await readFile(join(dir, "a.txt"), "utf8")).toBe(A_TXT);
    });

    it("idempotent re-delivery: the same job twice → second is skipped already_cold", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);

      const h = makeHarness({ nowMs: T0 + 200_000 });
      const first = await hibernateWorkspace(h.deps, jobFor(uid, sid, 1));
      expect(first.status).toBe("hibernated");
      const opsAfterFirst = h.opsLog.length;

      const second = await hibernateWorkspace(h.deps, jobFor(uid, sid, 1));
      expect(second).toEqual({ status: "skipped", reason: "already_cold" });
      expect(h.evictCalls).toHaveLength(1); // the seam never fires twice
      expect(h.opsLog.length).toBe(opsAfterFirst); // no re-pack, no re-upload
    });

    // -- crash recovery ------------------------------------------------------

    it("reconcile: stuck hibernating + dir present → back to warm (re-pack later)", async () => {
      await clearStuckRows();
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid, 777);
      expect(await fileManifestsRepo.beginHibernation(db, sid)).toBe(true);
      await pinUpdatedAt(sid, T0 - 20 * 60_000); // crash: 20 min in 'hibernating'

      const h = makeHarness({ nowMs: T0 });
      const out = await reconcileStuckHibernations(h.deps, { stuckAfterMs: 15 * 60_000 });
      expect(out).toEqual({ resetToWarm: 1, closedToCold: 0 });

      const row = await fileManifestsRepo.get(db, sid);
      expect(row!.state).toBe("warm");
      expect(row!.workspaceBytes).toBe(777); // prior du restored
      expect(await pathExists(dir)).toBe(true);
    });

    it("reconcile: stuck hibernating + dir gone + verified archive → closed cold with rebuilt ledger", async () => {
      await clearStuckRows();
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);
      expect(await fileManifestsRepo.beginHibernation(db, sid)).toBe(true);

      // Crash AFTER upload, BEFORE the Postgres flip: the archive + sidecar
      // are in storage, the dir is already gone.
      const archiveKey = r2Keys.workspaceArchive(uid, sid);
      const report = await packToStorage(dir, baseStorage, archiveKey);
      const manifestJson = encodeIndexWire(report.index);
      await baseStorage.put(r2Keys.workspaceManifest(uid, sid), manifestJson, {
        contentType: "application/json",
      });
      await rm(dir, { recursive: true, force: true });
      await pinUpdatedAt(sid, T0 - 20 * 60_000);

      const h = makeHarness({ nowMs: T0 });
      const out = await reconcileStuckHibernations(h.deps, { stuckAfterMs: 15 * 60_000 });
      expect(out).toEqual({ resetToWarm: 0, closedToCold: 1 });

      const row = await fileManifestsRepo.get(db, sid);
      expect(row!.state).toBe("cold");
      expect(row!.generation).toBe(1); // row.generation + 1
      expect(row!.archiveKey).toBe(archiveKey);
      expect(row!.archiveBytes).toBe(report.bytes);
      expect(row!.archiveSha256).toBe(report.sha256Hex);
      expect(row!.entryCount).toBe(report.index.files.length);
      expect(row!.workspaceBytes).toBeNull();
      // uiTree rebuilt from the archive's own index
      const rebuilt = uiTree(report.index);
      expect(row!.uiTree.totals).toEqual(rebuilt.totals);
      expect(row!.uiTree.roots).toEqual(rebuilt.roots);

      const objRows = await workspaceObjectRows(sid);
      expect(objRows).toHaveLength(2);
      const archiveRow = objRows.find((r) => r.kind === "workspace_archive")!;
      expect(archiveRow.bytes).toBe(report.bytes);
      expect(archiveRow.sha256).toBe(report.sha256Hex);
      expect(archiveRow.generation).toBe(1);
      const manifestRow = objRows.find((r) => r.kind === "workspace_manifest")!;
      expect(manifestRow.bytes).toBe(manifestJson.length);
      expect(manifestRow.sha256).toBe(createHash("sha256").update(manifestJson).digest("hex"));
    });

    it("reconcile: stuck hibernating + dir gone + no archive → row removed + workspace_lost note", async () => {
      await clearStuckRows();
      const uid = await seedUser();
      const sid = await seedSession(uid);
      // no dir, no archive — the row was claimed and everything vanished
      await seedWarmRow(uid, sid);
      expect(await fileManifestsRepo.beginHibernation(db, sid)).toBe(true);
      await pinUpdatedAt(sid, T0 - 20 * 60_000);

      const h = makeHarness({ nowMs: T0 });
      const out = await reconcileStuckHibernations(h.deps, { stuckAfterMs: 15 * 60_000 });
      expect(out).toEqual({ resetToWarm: 0, closedToCold: 0 });

      expect(await fileManifestsRepo.get(db, sid)).toBeNull();
      const evs = await createRedisEventLog(redis).readSince(sid, null, 10);
      const note = evs.find((e) => e.type === "system_note");
      expect(note).toBeDefined();
      expect(note!.payload).toEqual({ code: "workspace_lost" });
      const mirrored = await eventMirrorRepo.readSince(db, sid, null, 10);
      expect(
        mirrored.some(
          (e) =>
            e.type === "system_note" &&
            (e.payload as { code?: string }).code === "workspace_lost",
        ),
      ).toBe(true);
    });
  },
);
