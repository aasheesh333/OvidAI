import { createHash } from "node:crypto";
import { chmod, lstat, mkdir, mkdtemp, readFile, readlink, rm, stat, symlink, utimes, writeFile } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";

import { Redis } from "ioredis";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import {
  createDb,
  eventMirror,
  fileManifests,
  migrate,
  runs,
  sessions,
  users,
  workspaceObjects,
  type Db,
} from "@ovid/db";
import { createRedisEventLog, createRedisSystemBus, type EventLog } from "@ovid/events";
import {
  createHibernateWorker,
  createHydrateWorker,
  createQueues,
  type QueueServices,
} from "@ovid/queue";
import {
  buildGateway,
  createTestVerifier,
  createTicketStore,
} from "@ovid/gateway";
import { buildFileService } from "@ovid/worker";
import {
  ACTIVITY_KEY_PREFIX,
  createActivityTracker,
  createFsStorage,
  du,
  hibernateWorkspace,
  hydrateWorkspace,
  r2Keys,
  reconcileWarmRegistry,
  registerArtifact,
  walkWorkspace,
  workspaceDir,
  type ActivityTracker,
  type HibernateDeps,
  type HydrateDeps,
  type SandboxEviction,
  type StorageAdapter,
  type WarmDeps,
  type WarmWorkspaceEntry,
} from "@ovid/storage";

/**
 * P7 Task 13 — storage state-hydrator e2e (spine.test.ts conventions).
 *
 * REAL gateway (REST) + REAL worker file service composed in one process over
 * REAL dev Postgres/Redis, with ephemeral ports and deterministic bounded
 * waits. Only the outermost boundaries are stubbed:
 *
 *  - SandboxEviction: a test-local fs-backed stub listing ONLY this suite's
 *    fixture dirs (ruling R1). It is `authoritative: false` on purpose: the
 *    dev database is shared with every other suite, and the authoritative
 *    "warm row with no seam entry" arm belongs to T10's own tests — asserting
 *    it here would close other lanes' rows. The registration arm (what flow
 *    (a) pins) is unaffected.
 *  - Gateway → worker transport: a tiny fetch client with the same headers
 *    the shipped WorkerClient uses (the gateway's index does not export it).
 *    The worker FILE SERVICE itself is real.
 *
 * Flows (one `it` each):
 *   a. create session (test auth) → seed workspace dir → sweeper
 *      reconcileWarmRegistry registers it via the stub → GET tree live.
 *   b. POST hibernate → poll cold → dir gone + archive/sidecar in fs storage
 *      + GET tree source:"manifest" with the stub-worker call counter at zero.
 *   c. GET file cold → bytes sha256-identical to the seeded file; tree still
 *      manifest-only; dir still absent.
 *   d. PUT file cold → 200 (or 202 then retry) → warm → GET returns NEW bytes
 *      → POST hibernate again → cold GET still returns the new bytes
 *      (generation 2).
 *   e. POST hydrate → warm → full-tree checksum identity.
 *   f. registerArtifact (worker-side) → artifact_created event (readSince)
 *      with url/expiresAt → GET /artifacts lists it → GET /:id/url presigns.
 *
 * Shared dev services: no FLUSHDB. Cleanup DELetes only this suite's stream /
 * activity keys and obliterates only this suite's prefixed queues.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

const INTERNAL_TOKEN = "storage-e2e-internal-token";
const INLINE_MAX_BYTES = 8 * 1024 * 1024;

const SEEDED_INDEX = "export const answer = 42;\n";
const SEEDED_README = "# e2e workspace\n";
const WRITTEN_COLD = "export const answer = 43; // written while cold\n";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForAsync(
  cond: () => Promise<boolean>,
  what: string,
  timeoutMs = 30_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (await cond()) return;
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(25);
  }
}

async function exists(p: string): Promise<boolean> {
  return stat(p).then(
    () => true,
    () => false,
  );
}

function sha256(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

interface TreeRec {
  type: 0 | 1 | 2;
  mode: number;
  mtime: number;
  size: number;
  sha256?: string;
  target?: string;
}

/**
 * Recursive identity map: content sha256 for files, target for symlinks,
 * mode/mtime for files and dirs. Symlink mtimes are excluded — Node's fs API
 * cannot set them (`utimes` follows the link; there is no portable lutimes)
 * and the archive format restores symlinks as target-only members.
 */
async function treeMap(dir: string): Promise<Map<string, TreeRec>> {
  const entries = await walkWorkspace(dir);
  const map = new Map<string, TreeRec>();
  for (const e of entries) {
    const rec: TreeRec = { type: e.type, mode: e.mode, mtime: e.mtime, size: e.size };
    if (e.type === 0) rec.sha256 = sha256(await readFile(e.abs));
    if (e.type === 2) rec.target = e.target;
    map.set(e.path, rec);
  }
  return map;
}

function diffTrees(
  expected: Map<string, TreeRec>,
  actual: Map<string, TreeRec>,
): string[] {
  const problems: string[] = [];
  for (const [path, a] of expected) {
    const b = actual.get(path);
    if (b === undefined) {
      problems.push(`missing: ${path}`);
      continue;
    }
    if (a.type !== b.type) problems.push(`type: ${path}`);
    if (a.mode !== b.mode) problems.push(`mode: ${path} ${a.mode}/${b.mode}`);
    if (a.type !== 2 && a.mtime !== b.mtime) {
      problems.push(`mtime: ${path} ${a.mtime}/${b.mtime}`);
    }
    if (a.type === 0 && a.sha256 !== b.sha256) problems.push(`content: ${path}`);
    if (a.type === 2 && a.target !== b.target) problems.push(`target: ${path}`);
  }
  for (const path of actual.keys()) {
    if (!expected.has(path)) problems.push(`unexpected: ${path}`);
  }
  return problems;
}

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "storage statehydrator e2e (real gateway + real worker file service)",
  () => {
    let db: Db;
    let redis: Redis;
    let events: EventLog;
    let storage: StorageAdapter;
    let activity: ActivityTracker;
    let queues: QueueServices;
    let hibWorker: ReturnType<typeof createHibernateWorker>;
    let hydWorker: ReturnType<typeof createHydrateWorker>;
    let app: ReturnType<typeof buildGateway>;
    let fileService: ReturnType<typeof buildFileService>;
    let baseUrl: string;
    let fileBaseUrl: string;

    let tmpRoot: string;
    let workspacesRoot: string;
    let uid: string;
    let sid: string;
    let dir: string;

    let expectedTree: Map<string, TreeRec>;

    const createdSids: string[] = [];
    const workerCalls = { tree: 0, file: 0, put: 0 };

    const QUEUE_PREFIX = process.env.OVID_TEST_QUEUE_PREFIX
      ? `${process.env.OVID_TEST_QUEUE_PREFIX}-storage-e2e`
      : "ovid-test-storage-e2e";

    /** Entries this suite's stub may report (ruling R1: only its own dirs). */
    const sandboxEntries = new Map<string, WarmWorkspaceEntry>();
    const sandbox: SandboxEviction & {
      register(e: WarmWorkspaceEntry): void;
    } = {
      // See the header: shared dev DB → the destructive "row without a seam
      // entry" arm must stay inert; registration (flow a) is unaffected.
      authoritative: false,
      async listWarmWorkspaces() {
        const out: WarmWorkspaceEntry[] = [];
        for (const entry of sandboxEntries.values()) {
          const d = workspaceDir(workspacesRoot, entry.userId, entry.sessionId);
          if (await exists(d)) out.push({ ...entry });
        }
        return out;
      },
      async evictWorkspace(userId, sessionId) {
        const d = workspaceDir(workspacesRoot, userId, sessionId);
        if (!d.startsWith(workspacesRoot + "/")) {
          throw new Error(`refusing to evict outside the e2e root: ${d}`);
        }
        // Pack-safe destroy: kill jail/PTY (none here), LEAVE the files for
        // the hibernation engine — the production P2 seam's contract.
      },
      register(entry) {
        sandboxEntries.set(entry.sessionId, entry);
      },
    };

    // ---- HTTP helpers -----------------------------------------------------

    interface HttpResult {
      status: number;
      body: any;
    }

    async function api(
      method: string,
      path: string,
      opts: { body?: unknown; user?: string } = {},
    ): Promise<HttpResult> {
      const headers: Record<string, string> = {
        authorization: `Bearer test:${opts.user ?? uid}`,
      };
      if (opts.body !== undefined) headers["content-type"] = "application/json";
      const res = await fetch(`${baseUrl}${path}`, {
        method,
        headers,
        body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
      });
      const text = await res.text();
      let body: unknown = null;
      try {
        body = text === "" ? null : JSON.parse(text);
      } catch {
        body = text;
      }
      return { status: res.status, body };
    }

    /**
     * Minimal gateway→worker transport with the SAME headers/timeout the
     * shipped WorkerClient uses. Counts calls so flow (b) can pin "zero
     * worker calls" on the manifest path.
     */
    async function workerCall(
      method: "GET" | "PUT",
      path: string,
      user: string,
      body?: unknown,
    ): Promise<{ ok: true; value: any } | { ok: false; status: number; error: any }> {
      const res = await fetch(`${fileBaseUrl}${path}`, {
        method,
        headers: {
          "x-ovid-internal-token": INTERNAL_TOKEN,
          "x-ovid-user-id": user,
          ...(body !== undefined ? { "content-type": "application/json" } : {}),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(10_000),
      });
      const json: any = await res.json().catch(() => null);
      if (!res.ok) {
        return {
          ok: false,
          status: res.status,
          error: json ?? { error: { code: "internal", message: "unparseable body" } },
        };
      }
      return { ok: true, value: json };
    }

    const workerClient = {
      async getTree(user: string, sessionId: string) {
        workerCalls.tree += 1;
        return workerCall("GET", `/internal/sessions/${sessionId}/tree`, user);
      },
      async getFile(user: string, sessionId: string, path: string) {
        workerCalls.file += 1;
        return workerCall(
          "GET",
          `/internal/sessions/${sessionId}/file?path=${encodeURIComponent(path)}`,
          user,
        );
      },
      async putFile(user: string, sessionId: string, path: string, contentBase64: string) {
        workerCalls.put += 1;
        return workerCall(
          "PUT",
          `/internal/sessions/${sessionId}/file?path=${encodeURIComponent(path)}`,
          user,
          { contentBase64 },
        );
      },
    };

    // ---- seeding ----------------------------------------------------------

    const FIXED_MTIME = new Date("2026-10-16T12:00:00.000Z");

    async function seedWorkspace(root: string): Promise<void> {
      const files: Record<string, Buffer | string> = {
        "app/src/index.ts": SEEDED_INDEX,
        "app/README.md": SEEDED_README,
        "app/data/blob.bin": Buffer.from(
          Array.from({ length: 4096 }, (_, i) => i % 251),
        ),
        "app/node_modules/@fake/lib/index.js": "module.exports = 1;\n",
      };
      for (const [rel, content] of Object.entries(files)) {
        const abs = join(root, rel);
        await mkdir(dirname(abs), { recursive: true });
        await writeFile(abs, content);
        await chmod(abs, 0o644);
        await utimes(abs, FIXED_MTIME, FIXED_MTIME);
      }
      await symlink("src/index.ts", join(root, "app", "link.ts"));
    }

    beforeAll(async () => {
      console.error(
        "[storage-e2e] execArgv=",
        JSON.stringify(process.execArgv),
        "parallelism=",
        (await import("node:os")).availableParallelism(),
      );
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      redis = new Redis(TEST_REDIS_URL!);
      events = createRedisEventLog(redis);
      activity = createActivityTracker(redis);

      tmpRoot = await mkdtemp(join(tmpdir(), "ovid-storage-e2e-"));
      const storageRoot = join(tmpRoot, "storage");
      workspacesRoot = join(tmpRoot, "workspaces");
      await mkdir(storageRoot, { recursive: true });
      await mkdir(workspacesRoot, { recursive: true });
      storage = createFsStorage(storageRoot);

      uid = `storage-e2e-${Date.now().toString(36)}-${process.pid}`;
      await users.ensure(db, uid, null);
      const session = await sessions.create(db, uid, "storage e2e");
      sid = session.id;
      createdSids.push(sid);

      dir = workspaceDir(workspacesRoot, uid, sid);
      await mkdir(join(workspacesRoot, uid, "sessions"), { recursive: true });
      await seedWorkspace(dir);
      sandbox.register({
        userId: uid,
        sessionId: sid,
        bytes: await du(dir),
        lastAccessMs: Date.now(),
      });

      const hibernateDeps: HibernateDeps = {
        db,
        events,
        storage,
        workspacesRoot,
        sandbox,
        activity,
        fileManifests,
        workspaceObjects,
        runs,
        eventMirror,
        stuckHibernationScan: { listStuck: async () => [] },
      };
      const hydrateDeps: HydrateDeps = {
        db,
        events,
        storage,
        workspacesRoot,
        activity,
        fileManifests,
        eventMirror,
      };

      const connection = { url: TEST_REDIS_URL! };
      queues = createQueues(connection, { prefix: QUEUE_PREFIX });
      hibWorker = createHibernateWorker(
        connection,
        async (job) => {
          await hibernateWorkspace(hibernateDeps, job.data);
        },
        { prefix: QUEUE_PREFIX },
      );
      hydWorker = createHydrateWorker(
        connection,
        async (job) => {
          console.error("[storage-e2e] hydrate start", job.id, job.data);
          const r = await hydrateWorkspace(hydrateDeps, job.data);
          console.error("[storage-e2e] hydrate done", job.id, r);
        },
        { prefix: QUEUE_PREFIX },
      );
      // Loud worker failures: a silently-retrying storage job would otherwise
      // surface only as an awaitWarm timeout.
      hibWorker.on("failed", (job, err) => {
        console.error(`[storage-e2e] hibernate job ${job?.id} failed:`, err);
      });
      hydWorker.on("failed", (job, err) => {
        console.error(`[storage-e2e] hydrate job ${job?.id} failed:`, err);
      });
      hibWorker.on("error", (err) => {
        console.error("[storage-e2e] hibernate worker error:", err);
      });
      hydWorker.on("error", (err) => {
        console.error("[storage-e2e] hydrate worker error:", err);
      });

      fileService = buildFileService({
        db,
        events,
        storage,
        workspacesRoot,
        activity,
        internalToken: INTERNAL_TOKEN,
        inlineMaxBytes: INLINE_MAX_BYTES,
        port: 0,
        fileManifests,
        eventMirror,
        workspaceObjects,
      });
      await fileService.listen({ host: "127.0.0.1", port: 0 });
      fileBaseUrl = `http://127.0.0.1:${
        (fileService.server.address() as AddressInfo).port
      }`;

      app = buildGateway({

        system: createRedisSystemBus(redis),
        db,
        queues,
        verifier: createTestVerifier(),
        tickets: createTicketStore(redis),
        keys: { getKeyForUser: async () => "test-key" },
        mint: { ensureKey: async () => ({ key: "test-key" }) },
        events,
        worker: workerClient as any,
        storage,
        activity,
        // Generous ceiling: the hydrate worker must win the race so the PUT
        // exercises the synchronous 200 write-through path (202 is accepted
        // too, see flow d).
        hydrateWaitMs: 30_000,
      });
      await app.listen({ host: "127.0.0.1", port: 0 });
      baseUrl = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`;
    }, 60_000);

    afterAll(async () => {
      await hibWorker?.close().catch(() => {});
      await hydWorker?.close().catch(() => {});
      await app?.close().catch(() => {});
      await fileService?.close().catch(() => {});

      if (queues) {
        await queues.hibernate.obliterate({ force: true }).catch(() => {});
        await queues.hydrate.obliterate({ force: true }).catch(() => {});
        await queues.agentRuns.close().catch(() => {});
        await queues.hibernate.close().catch(() => {});
        await queues.hydrate.close().catch(() => {});
        await queues.schedules.close().catch(() => {});
      }

      if (redis && createdSids.length > 0) {
        await redis
          .del(createdSids.map((id) => `sess:${id}:events`))
          .catch(() => {});
        await redis
          .del(createdSids.map((id) => `${ACTIVITY_KEY_PREFIX}${id}`))
          .catch(() => {});
      }

      redis?.disconnect();
      await db?.$client.end({ timeout: 5 }).catch(() => {});
      if (tmpRoot) await rm(tmpRoot, { recursive: true, force: true }).catch(() => {});
    }, 60_000);

    // ---- flows ------------------------------------------------------------

    it("(a) sweeper registers the seeded warm dir; GET tree is live", async () => {
      const warmDeps: WarmDeps = {
        db,
        events,
        storage,
        workspacesRoot,
        sandbox,
        activity,
        fileManifests,
        workspaceObjects,
        runs,
        eventMirror,
        stuckHibernationScan: { listStuck: async () => [] },
        stuckHydrationScan: { listStuckHydrating: async () => [] },
        queues: { hibernate: queues.hibernate as any },
        diskProbe: async () => ({
          totalBytes: 193 * 1024 ** 3,
          freeBytes: 130 * 1024 ** 3,
          usedFraction: 0.33,
        }),
      };

      const reconciled = await reconcileWarmRegistry(warmDeps, {
        maxWarmBytes: 8 * 1024 ** 3,
        diskAlertFraction: 0.8,
      });
      expect(reconciled.registered).toBe(1);

      const row = await fileManifests.get(db, sid);
      expect(row?.state).toBe("warm");
      expect(row?.workspaceBytes).toBeGreaterThan(0);

      const res = await api("GET", `/cloud/v1/sessions/${sid}/workspace/tree`);
      expect(res.status).toBe(200);
      expect(res.body.source).toBe("live");
      expect(res.body.state).toBe("warm");
      expect(res.body.tree.totals.files).toBeGreaterThanOrEqual(4);
    });

    it("(b) POST hibernate → cold: dir gone, archive+sidecar stored, manifest tree with zero worker calls", async () => {
      const res = await api("POST", `/cloud/v1/sessions/${sid}/workspace/hibernate`);
      expect(res.status).toBe(202);

      await waitForAsync(
        async () =>
          (await fileManifests.get(db, sid))?.state === "cold" &&
          !(await exists(dir)),
        "session cold + local dir evicted after hibernate",
      );
      expect(await exists(dir)).toBe(false);

      const row = await fileManifests.get(db, sid);
      expect(row?.generation).toBe(1);
      expect(row?.archiveKey).toBe(r2Keys.workspaceArchive(uid, sid));
      expect(row?.archiveSha256).toMatch(/^[0-9a-f]{64}$/);

      const archive = await storage.head(r2Keys.workspaceArchive(uid, sid));
      const sidecar = await storage.head(r2Keys.workspaceManifest(uid, sid));
      expect(archive).not.toBeNull();
      expect(sidecar).not.toBeNull();
      expect(archive!.bytes).toBe(row?.archiveBytes);

      const callsBefore = workerCalls.tree;
      const tree = await api("GET", `/cloud/v1/sessions/${sid}/workspace/tree`);
      expect(tree.status).toBe(200);
      expect(tree.body.source).toBe("manifest");
      expect(tree.body.state).toBe("cold");
      expect(tree.body.generation).toBe(1);
      expect(workerCalls.tree).toBe(callsBefore);
    });

    it("(c) GET file cold: bytes sha256-identical; tree stays manifest-only; dir absent", async () => {
      const res = await api(
        "GET",
        `/cloud/v1/sessions/${sid}/workspace/file?path=app/src/index.ts`,
      );
      expect(res.status).toBe(200);
      expect(res.body.encoding).toBe("utf8");
      expect(res.body.content).toBe(SEEDED_INDEX);
      expect(sha256(Buffer.from(res.body.content, "utf8"))).toBe(
        sha256(Buffer.from(SEEDED_INDEX, "utf8")),
      );

      const tree = await api("GET", `/cloud/v1/sessions/${sid}/workspace/tree`);
      expect(tree.body.source).toBe("manifest");
      expect(await exists(dir)).toBe(false);
    });

    it("(d) PUT cold writes through; the write survives re-hibernation (generation 2)", async () => {
      const put = await api(
        "PUT",
        `/cloud/v1/sessions/${sid}/workspace/file`,
        { body: { path: "app/src/index.ts", contentUtf8: WRITTEN_COLD } },
      );
      // 200 = hydrated within hydrateWaitMs; 202 = still hydrating (retry).
      expect([200, 202]).toContain(put.status);
      if (put.status === 202) {
        await waitForAsync(
          async () => (await fileManifests.get(db, sid))?.state === "warm",
          "warm after PUT-triggered hydrate",
        );
        const retry = await api(
          "PUT",
          `/cloud/v1/sessions/${sid}/workspace/file`,
          { body: { path: "app/src/index.ts", contentUtf8: WRITTEN_COLD } },
        );
        expect(retry.status).toBe(200);
      }

      await waitForAsync(
        async () => (await fileManifests.get(db, sid))?.state === "warm",
        "warm after PUT",
      );
      const warmGet = await api(
        "GET",
        `/cloud/v1/sessions/${sid}/workspace/file?path=app/src/index.ts`,
      );
      expect(warmGet.status).toBe(200);
      expect(warmGet.body.content).toBe(WRITTEN_COLD);

      // Ground truth for flow (e): capture the full tree while it is warm.
      expectedTree = await treeMap(dir);

      const hib = await api("POST", `/cloud/v1/sessions/${sid}/workspace/hibernate`);
      expect(hib.status).toBe(202);
      await waitForAsync(
        async () =>
          (await fileManifests.get(db, sid))?.state === "cold" &&
          !(await exists(dir)),
        "cold + local dir evicted after second hibernate",
      );
      expect((await fileManifests.get(db, sid))?.generation).toBe(2);
      expect(await exists(dir)).toBe(false);

      const coldGet = await api(
        "GET",
        `/cloud/v1/sessions/${sid}/workspace/file?path=app/src/index.ts`,
      );
      expect(coldGet.status).toBe(200);
      expect(coldGet.body.content).toBe(WRITTEN_COLD);
      expect(sha256(Buffer.from(coldGet.body.content, "utf8"))).toBe(
        sha256(Buffer.from(WRITTEN_COLD, "utf8")),
      );
      expect(await exists(dir)).toBe(false);
    });

    it("(e) POST hydrate → warm with full-tree checksum identity", async () => {
      const res = await api("POST", `/cloud/v1/sessions/${sid}/workspace/hydrate`);
      expect(res.status).toBe(202);

      await waitForAsync(
        async () => (await fileManifests.get(db, sid))?.state === "warm",
        "warm after hydrate",
      );

      const actual = await treeMap(dir);
      expect(diffTrees(expectedTree, actual)).toEqual([]);
      // Symlink identity explicitly (the tree map compares targets).
      const target = await readlink(join(dir, "app", "link.ts"));
      expect(target).toBe("src/index.ts");
      expect((await lstat(join(dir, "app", "link.ts"))).isSymbolicLink()).toBe(true);
    });

    it("(f) registerArtifact → artifact_created event, list, presigned URL", async () => {
      const content = Buffer.from("artifact bytes from the worker\n", "utf8");
      const rec = await registerArtifact(
        { db, events, storage, workspaceObjects, eventMirror },
        {
          userId: uid,
          sessionId: sid,
          name: "report.txt",
          contentType: "text/plain",
          content,
        },
      );

      const stream = await events.readSince(sid, null, 200);
      const created = stream.find((e) => e.type === "artifact_created");
      expect(created).toBeDefined();
      expect(created!.payload.artifactId).toBe(rec.id);
      expect(created!.payload.name).toBe("report.txt");
      expect(typeof created!.payload.url).toBe("string");
      expect(created!.payload.url).toBe(rec.url);
      expect(typeof created!.payload.expiresAt).toBe("string");
      expect(new Date(created!.payload.expiresAt as string).getTime()).toBeGreaterThan(
        Date.now(),
      );

      const list = await api("GET", `/cloud/v1/sessions/${sid}/artifacts`);
      expect(list.status).toBe(200);
      expect(list.body.items.some((i: { id: string }) => i.id === rec.id)).toBe(true);

      const url = await api(
        "GET",
        `/cloud/v1/sessions/${sid}/artifacts/${rec.id}/url`,
      );
      expect(url.status).toBe(200);
      expect(typeof url.body.url).toBe("string");
      expect(url.body.url.length).toBeGreaterThan(0);
      expect(typeof url.body.expiresAt).toBe("string");
    });
  },
);
