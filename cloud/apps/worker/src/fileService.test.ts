/**
 * Task 11 — the internal file service, tested through Fastify's `inject()`
 * (no socket): token gate, warm live tree, warm/cold single-file reads, the
 * artifacts-backed redirect, traversal guards and warm-only writes.
 *
 * Gated on TEST_DATABASE_URL + TEST_REDIS_URL like the rest of the worker
 * suite: real Postgres (file_manifests / workspace_objects) and the real
 * Redis event ledger.
 */

import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Redis } from "ioredis";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  attachments as attachmentsRepo,
  assertSessionFileCapacity,
  createDb,
  createStorageQuotaRepos,
  eventMirror as eventMirrorRepo,
  fileManifests as fileManifestsRepo,
  migrate,
  newId,
  projectsRepo,
  runs as runsRepo,
  sessions as sessionsRepo,
  users,
  workspaceObjects as workspaceObjectsRepo,
  type Db,
} from "@ovid/db";
import { createRedisEventLog, type EventLog } from "@ovid/events";
import {
  createActivityTracker,
  createFsStorage,
  createNoopSandboxEviction,
  hibernateWorkspace,
  loadStorageEnv,
  workspaceDir,
  type ActivityTracker,
  type StorageAdapter,
} from "@ovid/storage";
import { uiManifestSchema } from "@ovid/shared";
import { buildFileService, type FileServiceDeps } from "./fileService.js";
import { loadWorkerEnv } from "./main.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

const TOKEN = "internal-test-token";
const INLINE_MAX = 1024 * 1024; // 1 MiB

function sha256(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "internal file service (buildFileService)",
  () => {
    let db: Db;
    let redis: Redis;
    let events: EventLog;
    let activity: ActivityTracker;
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
      activity = createActivityTracker(redis);
      storageRoot = await mkdtemp(join(tmpdir(), "ovid-file-svc-store-"));
      workspacesRoot = await mkdtemp(join(tmpdir(), "ovid-file-svc-ws-"));
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

    async function seedSession(): Promise<{ uid: string; sid: string }> {
      const uid = newId();
      createdUsers.push(uid);
      await users.ensure(db, uid, `file-svc-${uid.slice(0, 8)}@test.local`);
      const session = await sessionsRepo.create(db, uid);
      createdSessions.push(session.id);
      return { uid, sid: session.id };
    }

    /**
     * Pin a Free-cap plan (80) at position 0 for this user. The plans table is
     * owner-editable and shared by test files; without this pin a leftover
     * plan row at a lower position would map this user to another cap.
     */
    async function pinFreeCap(uid: string): Promise<void> {
      // `projectFileCap` maps the user's tier to the LIVE plan list ordered by
      // position. Pin the canonical `free` id first so the mapping is index 0
      // (80) regardless of leftover test plans at the same position.
      await db.$client.unsafe(
        `INSERT INTO plans (id, name, price_usd, enabled, aliases, window_hours, mult, slow_mode, auto_oss, position)
         VALUES ('free', 'Free', '0', true, '[]'::jsonb, 24, '1', false, false, -1000000)
         ON CONFLICT (id) DO UPDATE SET enabled = true, position = -1000000`,
      );
      await db.$client.unsafe(`UPDATE users SET tier = 'free' WHERE uid = $1`, [uid]);
    }

    function dirOf(uid: string, sid: string): string {
      return workspaceDir(workspacesRoot, uid, sid);
    }

    async function seedWarm(
      files: Record<string, Buffer | string>,
    ): Promise<{ uid: string; sid: string; dir: string }> {
      const { uid, sid } = await seedSession();
      const dir = dirOf(uid, sid);
      await mkdir(dir, { recursive: true });
      for (const [rel, content] of Object.entries(files)) {
        const full = join(dir, rel);
        await mkdir(join(full, ".."), { recursive: true });
        await writeFile(full, content);
      }
      await fileManifestsRepo.upsertWarm(db, {
        sessionId: sid,
        userId: uid,
        workspaceBytes: null,
      });
      return { uid, sid, dir };
    }

    function makeDeps(overrides: Partial<FileServiceDeps> = {}): FileServiceDeps {
      return {
        db,
        events,
        storage,
        workspacesRoot,
        sandboxUid: async (userId: string) => userId,
        activity,
        internalToken: TOKEN,
        inlineMaxBytes: INLINE_MAX,
        port: 0,
        fileManifests: fileManifestsRepo,
        runs: runsRepo,
        eventMirror: eventMirrorRepo,
        workspaceObjects: workspaceObjectsRepo,
        quota: createStorageQuotaRepos(db),
        assertProjectFileCapacity: assertSessionFileCapacity,
        ...overrides,
      };
    }

    function appFor(overrides: Partial<FileServiceDeps> = {}) {
      return buildFileService(makeDeps(overrides));
    }

    async function hibernate(uid: string, sid: string): Promise<void> {
      const res = await hibernateWorkspace(
        {
          db,
          events,
          storage,
          workspacesRoot,
          sandboxUid: async (userId: string) => userId,
          sandbox: createNoopSandboxEviction(),
          activity,
          fileManifests: fileManifestsRepo,
          workspaceObjects: workspaceObjectsRepo,
          runs: runsRepo,
          eventMirror: eventMirrorRepo,
          stuckHibernationScan: { listStuck: async () => [] },
        },
        { sessionId: sid, userId: uid, generation: 1, reason: "manual" },
      );
      expect(res.status).toBe("hibernated");
    }

    const headers = (uid: string, token: string | null = TOKEN) => ({
      ...(token !== null ? { "x-ovid-internal-token": token } : {}),
      "x-ovid-user-id": uid,
    });

    it("rejects a missing or wrong internal token with a 401 envelope", async () => {
      const app = appFor();
      try {
        const { uid, sid } = await seedWarm({ "a.txt": "hello" });

        const missing = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/tree`,
          headers: { "x-ovid-user-id": uid },
        });
        expect(missing.statusCode).toBe(401);
        expect(missing.json()).toMatchObject({ error: { code: "unauthenticated" } });

        const wrong = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/tree`,
          headers: headers(uid, "not-the-token"),
        });
        expect(wrong.statusCode).toBe(401);
        expect(wrong.json()).toMatchObject({ error: { code: "unauthenticated" } });
      } finally {
        await app.close();
      }
    });

    it("GET tree: 200 with a uiManifestSchema-valid live tree for a warm session", async () => {
      const app = appFor();
      try {
        const { uid, sid } = await seedWarm({
          "README.md": "# hi",
          "src/index.ts": "export {};",
        });

        const res = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/tree`,
          headers: headers(uid),
        });
        expect(res.statusCode).toBe(200);
        const body = res.json() as { tree: unknown };
        const tree = uiManifestSchema.parse(body.tree);
        expect(tree.totals.files).toBe(2);
        expect(tree.totals.dirs).toBeGreaterThanOrEqual(1);
      } finally {
        await app.close();
      }
    });

    it("GET file warm: kind content, exact base64 bytes, exact sha256", async () => {
      const app = appFor();
      try {
        const content = Buffer.from("warm file body\n");
        const { uid, sid } = await seedWarm({ "notes/a.txt": content });

        const res = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/file?path=notes/a.txt`,
          headers: headers(uid),
        });
        expect(res.statusCode).toBe(200);
        const body = res.json() as {
          kind: string;
          path: string;
          sizeBytes: number;
          sha256Hex: string;
          contentType: string;
          contentBase64: string;
          source: string;
        };
        expect(body.kind).toBe("content");
        expect(body.path).toBe("notes/a.txt");
        expect(body.sizeBytes).toBe(content.length);
        expect(body.sha256Hex).toBe(sha256(content));
        expect(body.contentType).toBe("text/plain");
        expect(body.source).toBe("warm");
        expect(Buffer.from(body.contentBase64, "base64")).toEqual(content);
      } finally {
        await app.close();
      }
    });

    it("GET file cold: reads the archive member and leaves the dir absent", async () => {
      const app = appFor();
      try {
        const content = Buffer.from("cold archive body\n");
        const { uid, sid, dir } = await seedWarm({ "notes/a.txt": content });
        await hibernate(uid, sid);
        await expect(stat(dir)).rejects.toBeTruthy();

        const res = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/file?path=notes/a.txt`,
          headers: headers(uid),
        });
        expect(res.statusCode).toBe(200);
        const body = res.json() as {
          kind: string;
          sha256Hex: string;
          contentBase64: string;
          source: string;
        };
        expect(body.kind).toBe("content");
        expect(body.source).toBe("archive");
        expect(body.sha256Hex).toBe(sha256(content));
        expect(Buffer.from(body.contentBase64, "base64")).toEqual(content);
        // Zero-extraction: the lazy read never materializes the workspace.
        await expect(stat(dir)).rejects.toBeTruthy();
      } finally {
        await app.close();
      }
    });

    it("GET ?path=../x → 400 bad_request; unknown path → 404 not_found", async () => {
      const app = appFor();
      try {
        const { uid, sid } = await seedWarm({ "a.txt": "hello" });

        const traversal = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/file?path=../x`,
          headers: headers(uid),
        });
        expect(traversal.statusCode).toBe(400);
        expect(traversal.json()).toMatchObject({ error: { code: "bad_request" } });

        const unknown = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/file?path=nope.txt`,
          headers: headers(uid),
        });
        expect(unknown.statusCode).toBe(404);
        expect(unknown.json()).toMatchObject({ error: { code: "not_found" } });
      } finally {
        await app.close();
      }
    });

    it("project chat at its file cap refuses the artifact redirect BEFORE storage/row; deleting one frees it", async () => {
      const app = appFor();
      try {
        const png = Buffer.alloc(2 * 1024 * 1024, 7);
        const { uid, sid } = await seedWarm({ "shot.png": png });
        await pinFreeCap(uid);
        const project = (await projectsRepo.create(db, uid, `File cap ${newId().slice(0, 8)}`))!;
        await projectsRepo.moveSession(db, uid, sid, project.id);

        // Fill the project budget (memory + uploads + active artifacts = 80).
        for (let i = 0; i < 80; i++) {
          await attachmentsRepo.create(db, {
            id: newId(),
            sessionId: sid,
            userId: uid,
            name: `seed-${i}.bin`,
            size: 1,
            r2Key: `file-svc-seed/${uid}/${i}/${newId()}`,
            projectId: project.id,
          });
        }

        const refused = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/file?path=shot.png`,
          headers: headers(uid),
        });
        expect(refused.statusCode).toBe(409);
        expect(refused.json()).toMatchObject({ error: { code: "project_file_limit" } });
        const before = (await db.$client.unsafe(
          `SELECT count(*)::int AS n FROM workspace_objects
            WHERE session_id = $1 AND kind = 'artifact'`,
          [sid],
        )) as Array<{ n: number }>;
        expect(before[0]!.n).toBe(0);

        // Deleting an upload frees the slot; the same read now registers.
        await db.$client.unsafe(
          `DELETE FROM attachments WHERE session_id = $1 AND name = 'seed-0.bin'`,
          [sid],
        );
        const accepted = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/file?path=shot.png`,
          headers: headers(uid),
        });
        expect(accepted.statusCode).toBe(200);
        expect((accepted.json() as { kind: string }).kind).toBe("redirect");
        const after = (await db.$client.unsafe(
          `SELECT count(*)::int AS n FROM workspace_objects
            WHERE session_id = $1 AND kind = 'artifact'`,
          [sid],
        )) as Array<{ n: number }>;
        expect(after[0]!.n).toBe(1);
      } finally {
        await app.close();
      }
    });

    it("GET cold binary/oversize file: kind redirect + artifact row, dir still absent", async () => {
      const app = appFor();
      try {
        const png = Buffer.alloc(2 * 1024 * 1024, 7);
        const { uid, sid, dir } = await seedWarm({ "shot.png": png });
        await hibernate(uid, sid);
        await expect(stat(dir)).rejects.toBeTruthy();

        const res = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/file?path=shot.png`,
          headers: headers(uid),
        });
        expect(res.statusCode).toBe(200);
        const body = res.json() as {
          kind: string;
          path: string;
          sizeBytes: number;
          contentType: string;
          downloadUrl: string;
          expiresAt: string;
        };
        expect(body.kind).toBe("redirect");
        expect(body.path).toBe("shot.png");
        expect(body.sizeBytes).toBe(png.length);
        expect(body.contentType).toBe("image/png");
        expect(body.downloadUrl).toMatch(/^file:\/\//);
        expect(Number.isNaN(Date.parse(body.expiresAt))).toBe(false);

        const rows = (await db.$client.unsafe(
          `SELECT kind, bytes, sha256, content_type FROM workspace_objects
           WHERE session_id = $1 AND kind = 'artifact'`,
          [sid],
        )) as Array<{ kind: string; bytes: number; sha256: string; content_type: string }>;
        expect(rows).toHaveLength(1);
        expect(rows[0]).toMatchObject({
          kind: "artifact",
          content_type: "image/png",
          sha256: sha256(png),
        });
        expect(Number(rows[0]!.bytes)).toBe(png.length);
        await expect(stat(dir)).rejects.toBeTruthy();
      } finally {
        await app.close();
      }
    });

    it("PUT warm: 200 with exact bytes read back", async () => {
      const app = appFor();
      try {
        const { uid, sid, dir } = await seedWarm({ "notes/a.txt": "old" });
        const content = Buffer.from("new contents\n");
        const res = await app.inject({
          method: "PUT",
          url: `/internal/sessions/${sid}/file?path=notes/a.txt`,
          headers: headers(uid),
          payload: { contentBase64: content.toString("base64") },
        });
        expect(res.statusCode).toBe(200);
        expect(res.json()).toMatchObject({
          path: "notes/a.txt",
          sizeBytes: content.length,
          sha256: sha256(content),
        });
        expect(await readFile(join(dir, "notes/a.txt"))).toEqual(content);
      } finally {
        await app.close();
      }
    });

    it("PUT cold (no dir) → 409 not_warm", async () => {
      const app = appFor();
      try {
        const { uid, sid } = await seedSession();
        const res = await app.inject({
          method: "PUT",
          url: `/internal/sessions/${sid}/file?path=a.txt`,
          headers: headers(uid),
          payload: { contentBase64: Buffer.from("x").toString("base64") },
        });
        expect(res.statusCode).toBe(409);
        expect(res.json()).toMatchObject({ error: { code: "not_warm" } });
      } finally {
        await app.close();
      }
    });

    it("PUT with invalid base64 → 400 bad_request", async () => {
      const app = appFor();
      try {
        const { uid, sid } = await seedWarm({ "a.txt": "old" });
        const res = await app.inject({
          method: "PUT",
          url: `/internal/sessions/${sid}/file?path=a.txt`,
          headers: headers(uid),
          payload: { contentBase64: "not base64!!!" },
        });
        expect(res.statusCode).toBe(400);
        expect(res.json()).toMatchObject({ error: { code: "bad_request" } });
      } finally {
        await app.close();
      }
    });

    // -- Wave 2 Studio (ST-003, ST-005, ST-007, ST-008, ST-015) ---------------

    it("GET tree for a workspace that was never created → 200 empty manifest (not 404)", async () => {
      const app = appFor();
      try {
        const { uid, sid } = await seedSession();
        const res = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/tree`,
          headers: headers(uid),
        });
        expect(res.statusCode).toBe(200);
        const tree = uiManifestSchema.parse((res.json() as { tree: unknown }).tree);
        expect(tree.roots).toEqual([]);
        expect(tree.totals).toEqual({ files: 0, dirs: 0, bytes: 0 });
        expect(tree.truncated).toBe(false);
      } finally {
        await app.close();
      }
    });

    it("GET tree?path=sub → that folder only, workspace-relative paths; missing folder → 404", async () => {
      const app = appFor();
      try {
        const { uid, sid } = await seedWarm({
          "src/a.ts": "a",
          "src/deep/b.ts": "b",
          "top.txt": "t",
        });
        const res = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/tree?path=src`,
          headers: headers(uid),
        });
        expect(res.statusCode).toBe(200);
        const tree = uiManifestSchema.parse((res.json() as { tree: unknown }).tree);
        expect(tree.roots.map((n) => n.path).sort()).toEqual(["src/a.ts", "src/deep"]);

        const missing = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/tree?path=nope`,
          headers: headers(uid),
        });
        expect(missing.statusCode).toBe(404);
        const bad = await app.inject({
          method: "GET",
          url: `/internal/sessions/${sid}/tree?path=../x`,
          headers: headers(uid),
        });
        expect(bad.statusCode).toBe(400);
      } finally {
        await app.close();
      }
    });

    it("PUT ifMatchSha256 stale → 409 baseline_mismatch, bytes untouched; fresh → 200", async () => {
      const app = appFor();
      try {
        const { uid, sid, dir } = await seedWarm({ "a.txt": "agent-wrote-this" });
        const stale = await app.inject({
          method: "PUT",
          url: `/internal/sessions/${sid}/file?path=a.txt`,
          headers: headers(uid),
          payload: {
            contentBase64: Buffer.from("draft").toString("base64"),
            ifMatchSha256: sha256(Buffer.from("old")),
          },
        });
        expect(stale.statusCode).toBe(409);
        expect(stale.json()).toMatchObject({ error: { code: "baseline_mismatch" } });
        expect(await readFile(join(dir, "a.txt"), "utf8")).toBe("agent-wrote-this");

        const fresh = await app.inject({
          method: "PUT",
          url: `/internal/sessions/${sid}/file?path=a.txt`,
          headers: headers(uid),
          payload: {
            contentBase64: Buffer.from("draft").toString("base64"),
            ifMatchSha256: sha256(Buffer.from("agent-wrote-this")),
          },
        });
        expect(fresh.statusCode).toBe(200);
        expect(await readFile(join(dir, "a.txt"), "utf8")).toBe("draft");
      } finally {
        await app.close();
      }
    });

    it("PUT ifNoneMatch on an existing file → 409 already_exists", async () => {
      const app = appFor();
      try {
        const { uid, sid, dir } = await seedWarm({ "README.md": "real" });
        const res = await app.inject({
          method: "PUT",
          url: `/internal/sessions/${sid}/file?path=README.md`,
          headers: headers(uid),
          payload: { contentBase64: "", ifNoneMatch: true },
        });
        expect(res.statusCode).toBe(409);
        expect(res.json()).toMatchObject({ error: { code: "already_exists" } });
        expect(await readFile(join(dir, "README.md"), "utf8")).toBe("real");
      } finally {
        await app.close();
      }
    });

    it("DELETE file / folder (recursive) and the not_empty / not_found / not_warm errors", async () => {
      const app = appFor();
      try {
        const { uid, sid, dir } = await seedWarm({ "a.txt": "x", "src/b.ts": "b" });
        const del = await app.inject({
          method: "DELETE",
          url: `/internal/sessions/${sid}/file?path=a.txt`,
          headers: headers(uid),
        });
        expect(del.statusCode).toBe(200);
        expect(del.json()).toEqual({ path: "a.txt", type: "file" });
        await expect(stat(join(dir, "a.txt"))).rejects.toBeTruthy();

        const notEmpty = await app.inject({
          method: "DELETE",
          url: `/internal/sessions/${sid}/file?path=src`,
          headers: headers(uid),
        });
        expect(notEmpty.statusCode).toBe(409);
        expect(notEmpty.json()).toMatchObject({ error: { code: "not_empty" } });

        const recursive = await app.inject({
          method: "DELETE",
          url: `/internal/sessions/${sid}/file?path=src&recursive=true`,
          headers: headers(uid),
        });
        expect(recursive.statusCode).toBe(200);
        expect(recursive.json()).toEqual({ path: "src", type: "dir" });

        const missing = await app.inject({
          method: "DELETE",
          url: `/internal/sessions/${sid}/file?path=src`,
          headers: headers(uid),
        });
        expect(missing.statusCode).toBe(404);

        const { uid: coldUid, sid: coldSid } = await seedSession();
        const cold = await app.inject({
          method: "DELETE",
          url: `/internal/sessions/${coldSid}/file?path=a.txt`,
          headers: headers(coldUid),
        });
        expect(cold.statusCode).toBe(409);
        expect(cold.json()).toMatchObject({ error: { code: "not_warm" } });
      } finally {
        await app.close();
      }
    });

    it("POST move renames without clobbering; POST mkdir creates folders", async () => {
      const app = appFor();
      try {
        const { uid, sid, dir } = await seedWarm({ "a.txt": "a", "b.txt": "b" });
        const clobber = await app.inject({
          method: "POST",
          url: `/internal/sessions/${sid}/move`,
          headers: headers(uid),
          payload: { from: "a.txt", to: "b.txt" },
        });
        expect(clobber.statusCode).toBe(409);
        expect(clobber.json()).toMatchObject({ error: { code: "already_exists" } });
        expect(await readFile(join(dir, "b.txt"), "utf8")).toBe("b");

        const moved = await app.inject({
          method: "POST",
          url: `/internal/sessions/${sid}/move`,
          headers: headers(uid),
          payload: { from: "a.txt", to: "docs/a.txt" },
        });
        expect(moved.statusCode).toBe(200);
        expect(moved.json()).toEqual({ from: "a.txt", to: "docs/a.txt" });
        expect(await readFile(join(dir, "docs/a.txt"), "utf8")).toBe("a");

        const bad = await app.inject({
          method: "POST",
          url: `/internal/sessions/${sid}/move`,
          headers: headers(uid),
          payload: { from: "../etc", to: "x" },
        });
        expect(bad.statusCode).toBe(400);

        const made = await app.inject({
          method: "POST",
          url: `/internal/sessions/${sid}/mkdir`,
          headers: headers(uid),
          payload: { path: "new/folder" },
        });
        expect(made.statusCode).toBe(200);
        expect(made.json()).toEqual({ path: "new/folder", created: true });
        expect((await stat(join(dir, "new/folder"))).isDirectory()).toBe(true);

        const overFile = await app.inject({
          method: "POST",
          url: `/internal/sessions/${sid}/mkdir`,
          headers: headers(uid),
          payload: { path: "b.txt" },
        });
        expect(overFile.statusCode).toBe(409);
        expect(overFile.json()).toMatchObject({ error: { code: "already_exists" } });
      } finally {
        await app.close();
      }
    });
  },
);

// ---------------------------------------------------------------------------
// Task 11 Step 5: env validation (no DB/redis needed — pure loaders)
// ---------------------------------------------------------------------------

describe("worker env validation (P7 Task 11)", () => {
  const baseEnv = (overrides: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv => ({
    DATABASE_URL: "postgres://postgres:ovid@127.0.0.1:5433/postgres",
    REDIS_Q_URL: "redis://127.0.0.1:6390",
    REDIS_MINT_URL: "redis://127.0.0.1:6390",
    OVID_INTERNAL_MINT_URL: "http://127.0.0.1:18092",
    OVID_INTERNAL_API_SECRET: "test-internal-secret-0123456789abcdef",
    OVID_LITELLM_BASE: "http://litellm.invalid",
    OVID_DEFAULT_MODEL: "ovid-default-model",
    OVID_INTERNAL_TOKEN: "shared-secret",
    ...overrides,
  });

  it("OVID_INTERNAL_TOKEN missing → throws naming the variable", () => {
    expect(() => loadWorkerEnv(baseEnv({ OVID_INTERNAL_TOKEN: "" }))).toThrow(
      /OVID_INTERNAL_TOKEN is required/,
    );
    expect(() => loadWorkerEnv(baseEnv({ OVID_INTERNAL_TOKEN: undefined }))).toThrow(
      /OVID_INTERNAL_TOKEN is required/,
    );
  });

  it("OVID_MAX_WARM_GB=\"x\" → throws naming the variable", () => {
    expect(() => loadWorkerEnv(baseEnv({ OVID_MAX_WARM_GB: "x" }))).toThrow(
      /OVID_MAX_WARM_GB/,
    );
  });

  it("NODE_ENV=production + fs backend → throws (loadStorageEnv)", () => {
    expect(() =>
      loadStorageEnv({
        NODE_ENV: "production",
        OVID_STORAGE_BACKEND: "fs",
        OVID_FS_STORAGE_ROOT: "/tmp/ovid-store",
      }),
    ).toThrow(/production/);
  });

  it("OVID_WORKER_FILE_PORT defaults to 8091", () => {
    const cfg = loadWorkerEnv(baseEnv());
    expect(cfg.workerFilePort).toBe(8091);
    expect(cfg.internalToken).toBe("shared-secret");
    expect(cfg.warmConfig.maxWarmBytes).toBe(8 * 1024 ** 3);
    expect(cfg.warmConfig.diskAlertFraction).toBeCloseTo(0.8);
  });
});
