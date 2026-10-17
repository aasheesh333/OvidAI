import { createHash, randomBytes } from "node:crypto";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  symlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { Redis } from "ioredis";
import type { WorkspaceState } from "@ovid/shared";

// Relative-source imports (Task-1/Task-8 precedent; wave-merger converts at
// the next lockfile touch). @ovid/storage takes no package edge on db/events:
// hydrate.ts consumes them only through structural mirrors.
import { createDb, migrate, type Db } from "../../db/src/client.js";
import {
  eventMirror as eventMirrorRepo,
  fileManifests as fileManifestsRepo,
  newId,
  sessions as sessionsRepo,
  workspaceObjects as workspaceObjectsRepo,
} from "../../db/src/repos.js";
import { users as usersTable } from "../../db/src/schema.js";
import { createRedisEventLog } from "../../events/src/eventLog.js";

import { createActivityTracker } from "./activity.js";
import type { StorageAdapter } from "./adapter.js";
import {
  KeyLayoutError,
  FileNotInArchiveError,
  FileTooLargeError,
  NotFoundError,
  WorkspaceStateError,
} from "./errors.js";
import { createFsStorage } from "./fsAdapter.js";
import { hibernateWorkspace, type HibernateDeps } from "./hibernate.js";
import {
  INDEX_CACHE_MAX_ENTRIES,
  awaitWarm,
  clearIndexCache,
  contentTypeFor,
  hydrateWorkspace,
  readWorkspaceFile,
  shouldPresign,
  writeWorkspaceFile,
  type HydrateDeps,
  type HydrateFileManifestsRepo,
  type HydrateJob,
} from "./hydrate.js";
import { r2Keys } from "./keys.js";
import { workspaceDir } from "./workspacePaths.js";
import { walkWorkspace } from "./archive/pack.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

/** Fixed "now" (2023-11-14T22:13:20Z) for clock-injected pins. */
const T0 = 1_700_000_000_000;
/** Deterministic file/dir mtime (seconds) so archive round-trips are exact. */
const META_T = 1_600_000_000;

const RUN_TAG = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
const ACTIVITY_PREFIX = `ovid-test-hyd-${RUN_TAG}:`;

async function pathExists(p: string): Promise<boolean> {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Pure helpers — no services needed.
// ---------------------------------------------------------------------------

describe("contentTypeFor / shouldPresign", () => {
  it("maps the pinned text-ish and binary extensions", () => {
    expect(contentTypeFor("a.ts")).toBe("text/plain");
    expect(contentTypeFor("a.js")).toBe("text/javascript");
    expect(contentTypeFor("a.mjs")).toBe("text/javascript");
    expect(contentTypeFor("a.json")).toBe("application/json");
    expect(contentTypeFor("a.md")).toBe("text/markdown");
    expect(contentTypeFor("a.txt")).toBe("text/plain");
    expect(contentTypeFor("a.html")).toBe("text/html");
    expect(contentTypeFor("a.css")).toBe("text/css");
    expect(contentTypeFor("a.csv")).toBe("text/csv");
    expect(contentTypeFor("a.log")).toBe("text/plain");
    expect(contentTypeFor("shot.png")).toBe("image/png");
    expect(contentTypeFor("shot.JPG")).toBe("image/jpeg");
    expect(contentTypeFor("a.webp")).toBe("image/webp");
    expect(contentTypeFor("a.gif")).toBe("image/gif");
    expect(contentTypeFor("a.pdf")).toBe("application/pdf");
    expect(contentTypeFor("a.zip")).toBe("application/zip");
    expect(contentTypeFor("a.tar")).toBe("application/x-tar");
    expect(contentTypeFor("a.gz")).toBe("application/gzip");
    expect(contentTypeFor("a.so")).toBe("application/octet-stream");
    expect(contentTypeFor("README")).toBe("application/octet-stream");
  });

  it("shouldPresign: inline text/json/svg stay inline; binary or oversize redirect", () => {
    const MiB = 1024 * 1024;
    expect(shouldPresign("text/plain", 100, MiB)).toBe(false);
    expect(shouldPresign("application/json", 100, MiB)).toBe(false);
    expect(shouldPresign("application/javascript", 100, MiB)).toBe(false);
    expect(shouldPresign("application/xml", 100, MiB)).toBe(false);
    expect(shouldPresign("image/svg+xml", 100, MiB)).toBe(false);
    expect(shouldPresign("text/plain; charset=utf-8", 100, MiB)).toBe(false);
    expect(shouldPresign("image/png", 100, MiB)).toBe(true);
    expect(shouldPresign("application/octet-stream", 100, MiB)).toBe(true);
    expect(shouldPresign("text/plain", 2 * MiB, MiB)).toBe(true);
    expect(shouldPresign("text/plain", MiB, MiB)).toBe(false); // exactly at the cap is inline
  });

  it("pins the index cache budget", () => {
    expect(INDEX_CACHE_MAX_ENTRIES).toBe(8);
  });
});

// ---------------------------------------------------------------------------
// Gated harness — real postgres + real redis + fs storage over mkdtemp.
// Same migrate-only, only-our-rows discipline as Task 8 (parallel wave).
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "hydration engine — full extract, lazy single-file, warm writes",
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
      storageRoot = await mkdtemp(join(tmpdir(), "ovid-hyd-store-"));
      wsRoot = await mkdtemp(join(tmpdir(), "ovid-hyd-ws-"));
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
          await db.$client.unsafe(
            `DELETE FROM workspace_objects WHERE session_id = ANY($1)`,
            [createdSids],
          );
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

    beforeEach(() => {
      clearIndexCache();
    });

    // -- fixtures ------------------------------------------------------------

    async function seedUser(): Promise<string> {
      const uid = newId();
      createdUids.push(uid);
      await db.insert(usersTable).values({ uid, email: `hyd-${uid.slice(0, 8)}@test.local` });
      return uid;
    }

    async function seedSession(uid: string): Promise<string> {
      const s = await sessionsRepo.create(db, uid, "hydrate-test");
      createdSids.push(s.id);
      return s.id;
    }

    /** Full round-trip fixture: nested dirs, exec bit, symlink, empty file. */
    async function seedWorkspace(dir: string): Promise<void> {
      await mkdir(join(dir, "sub", "deep"), { recursive: true });
      await mkdir(join(dir, "empty-dir"), { recursive: true });
      await writeFile(join(dir, "a.txt"), "alpha-alpha-alpha");
      await writeFile(join(dir, "sub", "b.txt"), "beta".repeat(100));
      await writeFile(join(dir, "sub", "deep", "c.txt"), "gamma");
      await writeFile(join(dir, "run.sh"), "#!/bin/sh\necho hydrate-ok\n");
      await writeFile(join(dir, "empty.bin"), Buffer.alloc(0));
      await chmod(join(dir, "run.sh"), 0o755);
      await chmod(join(dir, "sub"), 0o750);
      await symlink("a.txt", join(dir, "link"));
      // Deterministic metadata: files first, dirs last (writes touch dir mtimes).
      const entries = await walkWorkspace(dir);
      for (const e of entries) {
        if (e.type === 0) await utimes(e.abs, META_T, META_T);
      }
      for (const e of entries) {
        if (e.type === 1) await utimes(e.abs, META_T, META_T);
      }
    }

    async function seedWarmRow(
      uid: string,
      sid: string,
      workspaceBytes: number | null = 4096,
    ): Promise<void> {
      await fileManifestsRepo.upsertWarm(db, { sessionId: sid, userId: uid, workspaceBytes });
    }

    /** Hibernate helper — the Task-8 engine is the only producer of archives. */
    async function hibernateFixture(uid: string, sid: string): Promise<void> {
      const activity = createActivityTracker(redis, {
        keyPrefix: ACTIVITY_PREFIX,
        clock: () => new Date(T0),
      });
      const hdeps: HibernateDeps = {
        db,
        events: createRedisEventLog(redis),
        storage: baseStorage,
        workspacesRoot: wsRoot,
        sandboxUid: async (userId: string) => userId,
        sandbox: { listWarmWorkspaces: async () => [], evictWorkspace: async () => {} },
        activity,
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

    /** markColdRetry mirror: the wiring layer supplies this (no db-package edit). */
    const hydrateFileManifests: HydrateFileManifestsRepo = {
      ...fileManifestsRepo,
      async markColdRetry(handle: unknown, sessionId: string): Promise<void> {
        // State re-check (T6 carry): only a row still in OUR claim flips back.
        await (handle as Db).$client.unsafe(
          `UPDATE file_manifests
              SET state = 'cold', updated_at = now()
            WHERE session_id = $1 AND state = 'hydrating'`,
          [sessionId],
        );
      },
    };

    interface Harness {
      deps: HydrateDeps;
      storage: StorageAdapter;
      activity: ReturnType<typeof createActivityTracker>;
    }

    function makeHarness(opts: { storage?: StorageAdapter; nowMs?: number } = {}): Harness {
      const storage = opts.storage ?? baseStorage;
      const activity = createActivityTracker(redis, {
        keyPrefix: ACTIVITY_PREFIX,
        clock: () => new Date(opts.nowMs ?? T0),
      });
      const deps: HydrateDeps = {
        db,
        events: createRedisEventLog(redis),
        storage,
        workspacesRoot: wsRoot,
        sandboxUid: async (userId: string) => userId,
        activity,
        clock: () => new Date(opts.nowMs ?? T0),
        fileManifests: hydrateFileManifests,
        eventMirror: eventMirrorRepo,
      };
      return { deps, storage, activity };
    }

    function jobFor(uid: string, sid: string, generation: number): HydrateJob {
      return { sessionId: sid, userId: uid, generation, reason: "manual" };
    }

    /** Structural snapshot used by the round-trip pin. */
    interface TreeSnap {
      type: number;
      size: number;
      mode: number;
      mtime?: number;
      target?: string;
      sha256?: string;
    }

    async function snapshotTree(dir: string): Promise<Map<string, TreeSnap>> {
      const entries = await walkWorkspace(dir);
      const map = new Map<string, TreeSnap>();
      for (const e of entries) {
        const snap: TreeSnap = { type: e.type, size: e.size, mode: e.mode };
        // Symlink mtimes are not restored by the v1 extractor (it recreates
        // the link; the format carries the value but only files/dirs restore
        // metadata). Every other member must round-trip mtime exactly.
        if (e.type !== 2) snap.mtime = e.mtime;
        if (e.type === 2) snap.target = e.target;
        if (e.type === 0) {
          snap.sha256 = createHash("sha256").update(await readFile(e.abs)).digest("hex");
        }
        map.set(e.path, snap);
      }
      return map;
    }

    async function manifestState(sid: string): Promise<WorkspaceState | null> {
      const row = await fileManifestsRepo.get(db, sid);
      return row?.state ?? null;
    }

    async function hydratedEvents(sid: string) {
      const evs = await createRedisEventLog(redis).readSince(sid, null, 10);
      return evs.filter((e) => e.type === "workspace_hydrated");
    }

    // -- full hydrate --------------------------------------------------------

    it("round-trips: hibernate → hydrate is checksum/mode/mtime identical, warm, event + du", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);
      const before = await snapshotTree(dir);

      await hibernateFixture(uid, sid);
      expect(await pathExists(dir)).toBe(false);
      const cold = await fileManifestsRepo.get(db, sid);
      expect(cold!.state).toBe("cold");
      expect(cold!.generation).toBe(1);

      const h = makeHarness({ nowMs: T0 });
      const res = await hydrateWorkspace(h.deps, jobFor(uid, sid, 1), { workers: 1 });

      expect(res.status).toBe("hydrated");
      expect(res.files).toBe(
        [...before.values()].filter((s) => s.type !== 1).length,
      ); // files + symlinks (dirs excluded)
      expect(res.ms).toBe(0); // frozen clock

      const after = await snapshotTree(dir);
      expect(after).toEqual(before);

      const row = await fileManifestsRepo.get(db, sid);
      expect(row!.state).toBe("warm");
      expect(row!.generation).toBe(1);
      // du = sum of regular-file bytes (symlink targets excluded)
      const expectedBytes = [...before.values()]
        .filter((s) => s.type === 0)
        .reduce((n, s) => n + s.size, 0);
      expect(row!.workspaceBytes).toBe(expectedBytes);
      // the archive ledger survives re-warming (a re-hibernate bumps in place)
      expect(row!.archiveKey).toBe(r2Keys.workspaceArchive(uid, sid));

      const evs = await hydratedEvents(sid);
      expect(evs).toHaveLength(1);
      expect(evs[0]!.payload).toEqual({ generation: 1, ms: 0 });
      const mirrored = await eventMirrorRepo.readSince(db, sid, null, 10);
      expect(mirrored.filter((e) => e.type === "workspace_hydrated")).toHaveLength(1);
    });

    // -- skips ---------------------------------------------------------------

    it("skips already_warm when the row is warm", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      await seedWarmRow(uid, sid);
      const h = makeHarness();
      const res = await hydrateWorkspace(h.deps, jobFor(uid, sid, 0));
      expect(res).toEqual({ status: "skipped", reason: "already_warm" });
    });

    it("skips already_warm while another job owns a hydrating row", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      await seedWarmRow(uid, sid);
      await db.$client.unsafe(
        `UPDATE file_manifests SET state = 'hydrating' WHERE session_id = $1`,
        [sid],
      );
      const h = makeHarness();
      const res = await hydrateWorkspace(h.deps, jobFor(uid, sid, 0));
      expect(res).toEqual({ status: "skipped", reason: "already_warm" });
    });

    it("skips stale_generation when the job generation is behind the row", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);
      await hibernateFixture(uid, sid);
      const h = makeHarness();
      const res = await hydrateWorkspace(h.deps, jobFor(uid, sid, 0));
      expect(res).toEqual({ status: "skipped", reason: "stale_generation" });
      expect(await pathExists(dir)).toBe(false); // never extracted
    });

    it("skips no_archive when the session has no row", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const h = makeHarness();
      const res = await hydrateWorkspace(h.deps, jobFor(uid, sid, 0));
      expect(res).toEqual({ status: "skipped", reason: "no_archive" });
    });

    // -- crash remnant -------------------------------------------------------

    it("wipes a crash-remnant dir before extracting (T8 dir-reclaim carry)", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);
      const before = await snapshotTree(dir);
      await hibernateFixture(uid, sid);

      // post-markCold crash residue: cold row, but the old dir is still there
      await mkdir(join(dir, "junk"), { recursive: true });
      await writeFile(join(dir, "junk", "stale.txt"), "must not survive");
      await writeFile(join(dir, "stale-root.txt"), "must not survive either");

      const h = makeHarness();
      const res = await hydrateWorkspace(h.deps, jobFor(uid, sid, 1), { workers: 1 });
      expect(res.status).toBe("hydrated");
      expect(await pathExists(join(dir, "junk"))).toBe(false);
      expect(await pathExists(join(dir, "stale-root.txt"))).toBe(false);
      expect(await snapshotTree(dir)).toEqual(before);
    });

    // -- failure path --------------------------------------------------------

    it("restores cold and removes the partial dir when the archive is corrupt", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);
      await hibernateFixture(uid, sid);

      // Flip one byte in the stored archive (the mid-point lands in a frame
      // for this fixture; the index/footer tail is untouched).
      const archivePath = join(storageRoot, r2Keys.workspaceArchive(uid, sid));
      const bytes = await readFile(archivePath);
      bytes[Math.floor(bytes.length / 2)] ^= 0x01;
      await writeFile(archivePath, bytes);

      const h = makeHarness();
      await expect(
        hydrateWorkspace(h.deps, jobFor(uid, sid, 1), { workers: 1 }),
      ).rejects.toThrowError(/HASH MISMATCH|corrupt|Data corruption|truncated/i);

      expect(await manifestState(sid)).toBe("cold");
      expect(await pathExists(dir)).toBe(false); // no partial tree
      expect((await hydratedEvents(sid))).toHaveLength(0);
    });

    // -- awaitWarm -----------------------------------------------------------

    it("awaitWarm dedupes concurrent callers on the jobId and resolves once warm", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);
      await hibernateFixture(uid, sid);

      const added = new Map<string, HydrateJob>();
      const queue = {
        add(name: string, job: HydrateJob, opts: { jobId: string }): unknown {
          expect(name).toBe("hydrate-workspace");
          if (!added.has(opts.jobId)) added.set(opts.jobId, job);
          return { id: opts.jobId };
        },
      };
      const ref = { sessionId: sid, userId: uid };
      const p1 = awaitWarm(db, queue, ref, { reason: "open", timeoutMs: 5_000, pollMs: 20 });
      const p2 = awaitWarm(db, queue, ref, { reason: "run", timeoutMs: 5_000, pollMs: 20 });
      await new Promise((r) => setTimeout(r, 50)); // both callers observe cold

      const h = makeHarness();
      await hydrateWorkspace(h.deps, jobFor(uid, sid, 1), { workers: 1 });
      const [r1, r2] = await Promise.all([p1, p2]);

      expect(added.size).toBe(1);
      expect([...added.keys()][0]).toBe(`${sid}~1`);
      expect(r1).toEqual({ generation: 1 });
      expect(r2).toEqual({ generation: 1 });
    });

    it("awaitWarm times out with WorkspaceStateError code hydrate_timeout", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);
      await hibernateFixture(uid, sid);

      const queue = { add: () => ({}) };
      const err = await awaitWarm(db, queue, { sessionId: sid, userId: uid }, {
        reason: "open",
        timeoutMs: 120,
        pollMs: 20,
      }).catch((e: unknown) => e);
      expect(err).toBeInstanceOf(WorkspaceStateError);
      expect((err as WorkspaceStateError).code).toBe("hydrate_timeout");
    });

    it("awaitWarm resolves a warm row without adding a job", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      await seedWarmRow(uid, sid);
      let adds = 0;
      const queue = {
        add: () => {
          adds++;
          return {};
        },
      };
      const res = await awaitWarm(db, queue, { sessionId: sid, userId: uid }, {
        reason: "open",
        timeoutMs: 500,
        pollMs: 20,
      });
      expect(res).toEqual({ generation: 0 });
      expect(adds).toBe(0);
    });

    // -- lazy single-file reads ---------------------------------------------

    it("reads 20 random files from the archive and leaves the dir absent", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await mkdir(dir, { recursive: true });
      const fixtures = new Map<string, Buffer>();
      for (let i = 0; i < 20; i++) {
        const name = `f${String(i).padStart(2, "0")}.bin`;
        const content = randomBytes(256 + i * 37);
        fixtures.set(name, content);
        await writeFile(join(dir, name), content);
      }
      await seedWarmRow(uid, sid);
      await hibernateFixture(uid, sid);
      expect(await pathExists(dir)).toBe(false);

      const h = makeHarness();
      for (const [name, content] of fixtures) {
        const out = await readWorkspaceFile(h.deps, { userId: uid, sessionId: sid, path: name });
        expect(out.bytes.equals(content)).toBe(true);
        expect(out.sizeBytes).toBe(content.length);
        expect(out.sha256Hex).toBe(createHash("sha256").update(content).digest("hex"));
        expect(out.source).toBe("archive");
        expect(out.contentType).toBe("application/octet-stream");
        // zero-extraction pin: every read is a range read, never a warm dir
        expect(await pathExists(dir)).toBe(false);
      }
    });

    it("rejects traversal and absolute paths with KeyLayoutError", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const h = makeHarness();
      await expect(
        readWorkspaceFile(h.deps, { userId: uid, sessionId: sid, path: "../escape" }),
      ).rejects.toThrowError(KeyLayoutError);
      await expect(
        readWorkspaceFile(h.deps, { userId: uid, sessionId: sid, path: "/etc/passwd" }),
      ).rejects.toThrowError(KeyLayoutError);
    });

    it("rejects a warm-dir symlink that escapes the workspace with NotFoundError", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await mkdir(dir, { recursive: true });
      await symlink("/etc/hostname", join(dir, "evil"));
      await seedWarmRow(uid, sid);
      const h = makeHarness();
      await expect(
        readWorkspaceFile(h.deps, { userId: uid, sessionId: sid, path: "evil" }),
      ).rejects.toThrowError(NotFoundError);
    });

    it("rejects oversize reads with FileTooLargeError carrying sizeBytes", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await mkdir(dir, { recursive: true });
      await writeFile(join(dir, "big.txt"), "x".repeat(100));
      await seedWarmRow(uid, sid);
      const h = makeHarness();
      const err = await readWorkspaceFile(h.deps, {
        userId: uid,
        sessionId: sid,
        path: "big.txt",
      }, { maxBytes: 10 }).catch((e: unknown) => e);
      expect(err).toBeInstanceOf(FileTooLargeError);
      expect((err as FileTooLargeError).sizeBytes).toBe(100);
    });

    it("rejects an unknown cold path with FileNotInArchiveError", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);
      await hibernateFixture(uid, sid);
      const h = makeHarness();
      await expect(
        readWorkspaceFile(h.deps, { userId: uid, sessionId: sid, path: "nope.txt" }),
      ).rejects.toThrowError(FileNotInArchiveError);
    });

    it("caches the index: two cold reads call the sidecar once; clearIndexCache resets", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);
      await hibernateFixture(uid, sid);

      const manifestKey = r2Keys.workspaceManifest(uid, sid);
      let sidecarReads = 0;
      const counting: StorageAdapter = {
        ...baseStorage,
        async getBuffer(key: string) {
          if (key === manifestKey) sidecarReads++;
          return baseStorage.getBuffer(key);
        },
      };
      const h = makeHarness({ storage: counting });

      await readWorkspaceFile(h.deps, { userId: uid, sessionId: sid, path: "a.txt" });
      await readWorkspaceFile(h.deps, { userId: uid, sessionId: sid, path: "sub/b.txt" });
      expect(sidecarReads).toBe(1);

      clearIndexCache();
      await readWorkspaceFile(h.deps, { userId: uid, sessionId: sid, path: "a.txt" });
      expect(sidecarReads).toBe(2);
    });

    // -- warm writes ---------------------------------------------------------

    it("writes into a warm workspace atomically and reads the exact bytes back", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await mkdir(join(dir, "nested"), { recursive: true });
      await seedWarmRow(uid, sid);
      const h = makeHarness();

      const content = Buffer.from("written by the file service\n");
      const res = await writeWorkspaceFile(h.deps, {
        userId: uid,
        sessionId: sid,
        path: "nested/new.txt",
      }, content);

      expect(res.path).toBe("nested/new.txt");
      expect(res.sizeBytes).toBe(content.length);
      expect(res.sha256Hex).toBe(createHash("sha256").update(content).digest("hex"));
      expect(await readFile(join(dir, "nested", "new.txt"))).toEqual(content);
      expect((await stat(join(dir, "nested", "new.txt"))).mode & 0o777).toBe(0o644);
      const back = await readWorkspaceFile(h.deps, {
        userId: uid,
        sessionId: sid,
        path: "nested/new.txt",
      });
      expect(back.bytes.equals(content)).toBe(true);
      expect(back.source).toBe("warm");
      expect(back.contentType).toBe("text/plain");
    });

    it("refuses writes when the workspace is cold (code not_warm)", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await seedWorkspace(dir);
      await seedWarmRow(uid, sid);
      await hibernateFixture(uid, sid);
      expect(await pathExists(dir)).toBe(false);

      const h = makeHarness();
      const err = await writeWorkspaceFile(h.deps, {
        userId: uid,
        sessionId: sid,
        path: "x.txt",
      }, Buffer.from("nope")).catch((e: unknown) => e);
      expect(err).toBeInstanceOf(WorkspaceStateError);
      expect((err as WorkspaceStateError).code).toBe("not_warm");
    });

    it("writeWorkspaceFile rejects traversal paths before touching disk", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      await mkdir(dir, { recursive: true });
      const h = makeHarness();
      await expect(
        writeWorkspaceFile(h.deps, { userId: uid, sessionId: sid, path: `..${sep}x` }, Buffer.from("v")),
      ).rejects.toThrowError(KeyLayoutError);
    });

    it("writeWorkspaceFile refuses a symlinked parent that escapes the workspace", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const dir = workspaceDir(wsRoot, uid, sid);
      const outside = await mkdtemp(join(tmpdir(), "ovid-hyd-escape-"));
      await mkdir(dir, { recursive: true });
      await symlink(outside, join(dir, "escape"));
      const h = makeHarness();
      await expect(
        writeWorkspaceFile(h.deps, {
          userId: uid,
          sessionId: sid,
          path: "escape/pwn.txt",
        }, Buffer.from("v")),
      ).rejects.toThrowError(NotFoundError);
      expect(await pathExists(join(outside, "pwn.txt"))).toBe(false);
      await rm(outside, { recursive: true, force: true });
    });
  },
);
