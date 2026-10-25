import { createHash, randomBytes } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { Redis } from "ioredis";
import { artifactCreatedPayloadSchema, verifyInternalRequest } from "@ovid/shared";

// Relative-source imports (Task-8 precedent; wave-merger converts at the next
// lockfile touch). @ovid/storage consumes db/events through structural mirrors.
import { createDb, migrate, type Db } from "../../db/src/client.js";
import { createMigrationScratch, type MigrationScratch } from "../../db/src/migrationTestKit.js";
import { assertSessionFileCapacity, projectFileUsage } from "../../db/src/projectFiles.js";
import {
  attachments as attachmentsRepo,
  eventMirror as eventMirrorRepo,
  newId,
  projectsRepo,
  sessions as sessionsRepo,
  workspaceObjects as workspaceObjectsRepo,
} from "../../db/src/repos.js";
import { users as usersTable } from "../../db/src/schema.js";
import { createRedisEventLog } from "../../events/src/eventLog.js";

import type { StorageAdapter } from "./adapter.js";
import { StorageError } from "./errors.js";
import { createFsStorage } from "./fsAdapter.js";
import {
  ARTIFACT_GRANT_CREATE_PATH,
  createHttpArtifactGrantFactory,
  registerArtifact,
  type ArtifactDeps,
  type ArtifactQuota,
} from "./artifacts.js";
import { contentTypeFor, shouldPresign } from "./hydrate.js";
import { r2Keys } from "./keys.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

/** Fixed "now" (2023-11-14T22:13:20Z) for clock-injected pins. */
const T0 = 1_700_000_000_000;
const TTL = 3_600;

const RUN_TAG = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "artifacts pipeline — storage object + row + event",
  () => {
    let scratch: MigrationScratch;
    let db: Db;
    let redis: Redis;
    let storageRoot: string;
    let tempRoot: string;
    let storage: StorageAdapter;
    const createdSids: string[] = [];
    const createdUids: string[] = [];

    beforeAll(async () => {
      scratch = await createMigrationScratch(TEST_DATABASE_URL!, "storage_artifacts");
      await migrate(scratch.url);
      db = createDb(scratch.url, { max: 8 });
      redis = new Redis(TEST_REDIS_URL!);
      storageRoot = await mkdtemp(join(tmpdir(), "ovid-art-store-"));
      tempRoot = await mkdtemp(join(tmpdir(), "ovid-art-tmp-"));
      storage = createFsStorage(storageRoot);
    }, 120_000);

    afterAll(async () => {
      if (redis) {
        const keys = createdSids.map((sid) => `sess:${sid}:events`);
        if (keys.length > 0) await redis.del(...keys).catch(() => {});
        await redis.quit().catch(() => {});
      }
      await db?.$client.end({ timeout: 5 });
      await scratch?.close();
      if (storageRoot) await rm(storageRoot, { recursive: true, force: true });
      if (tempRoot) await rm(tempRoot, { recursive: true, force: true });
    });

    async function seedUser(): Promise<string> {
      const uid = newId();
      createdUids.push(uid);
      await db.insert(usersTable).values({ uid, email: `art-${uid.slice(0, 8)}@test.local` });
      return uid;
    }

    async function seedSession(uid: string): Promise<string> {
      const s = await sessionsRepo.create(db, uid, "artifacts-test");
      createdSids.push(s.id);
      return s.id;
    }

    function makeDeps(nowMs: number = T0, overrides: Partial<ArtifactDeps> = {}): ArtifactDeps {
      return {
        db,
        events: createRedisEventLog(redis),
        storage,
        presignTtlSeconds: TTL,
        clock: () => new Date(nowMs),
        workspaceObjects: workspaceObjectsRepo,
        eventMirror: eventMirrorRepo,
        assertProjectFileCapacity: assertSessionFileCapacity,
        quota: {
          reserveArtifact: async (input) => ({ ok: true as const, reservationId: input.artifactId }),
          finalizeUpload: async (input) => ({ ok: true as const, reservationId: input.reservationId }),
          releaseUpload: async () => {},
          removeObject: async () => ({ removed: true, freedBytes: 0 }),
        },
        ...overrides,
      };
    }

    async function artifactEvents(sid: string) {
      const evs = await createRedisEventLog(redis).readSince(sid, null, 50);
      return evs.filter((e) => e.type === "artifact_created");
    }

    it("registers a Buffer: exact key, row bytes/sha, schema-valid event, presigned url", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const content = Buffer.from("artifact-buffer-body");

      const rec = await registerArtifact(makeDeps(), {
        userId: uid,
        sessionId: sid,
        name: "notes.txt",
        content,
      });

      expect(rec.key).toBe(
        r2Keys.contentAddressedArtifact(
          uid,
          sid,
          rec.id,
          createHash("sha256").update(content).digest("hex"),
          "notes.txt",
        ),
      );
      expect(rec.id).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
      );
      expect(rec.sizeBytes).toBe(content.length);
      expect(rec.sha256Hex).toBe(createHash("sha256").update(content).digest("hex"));
      expect(rec.contentType).toBe("text/plain");
      expect(rec.url.startsWith("file://")).toBe(true);
      expect(rec.expiresAt).toBe(new Date(T0 + TTL * 1000).toISOString());

      // object exists at the exact key
      const stored = await readFile(join(storageRoot, rec.key));
      expect(stored.equals(content)).toBe(true);

      // row
      const row = await workspaceObjectsRepo.getArtifact(db, rec.id, uid);
      expect(row).not.toBeNull();
      expect(row!.kind).toBe("artifact");
      expect(row!.r2Key).toBe(rec.key);
      expect(row!.bytes).toBe(content.length);
      expect(row!.sha256).toBe(rec.sha256Hex);
      expect(row!.contentType).toBe("text/plain");
      expect(row!.meta).toEqual({ name: "notes.txt" });
      expect(row!.status).toBe("active");

      // event payload validates against the shared schema + mirror agrees
      const evs = await artifactEvents(sid);
      expect(evs).toHaveLength(1);
      const payload = artifactCreatedPayloadSchema.parse(evs[0]!.payload);
      expect(payload).toEqual({
        artifactId: rec.id,
        name: "notes.txt",
        sessionId: sid,
        sizeBytes: content.length,
        contentType: "text/plain",
        url: rec.url,
        expiresAt: rec.expiresAt,
      });
      const mirrored = await eventMirrorRepo.readSince(db, sid, null, 10);
      const mirroredArtifacts = mirrored.filter((e) => e.type === "artifact_created");
      expect(mirroredArtifacts).toHaveLength(1);
      expect(mirroredArtifacts[0]!.seq).toBe(evs[0]!.seq);
    });

    it("registers from sourcePath with identical bytes/sha (streamed)", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const content = randomBytes(4096 + 17);
      const sourcePath = join(tempRoot, `src-${randomBytes(4).toString("hex")}.bin`);
      await writeFile(sourcePath, content);

      const rec = await registerArtifact(makeDeps(), {
        userId: uid,
        sessionId: sid,
        name: "shot.png",
        sourcePath,
      });

      expect(rec.contentType).toBe("image/png"); // default from contentTypeFor
      expect(rec.sizeBytes).toBe(content.length);
      expect(rec.sha256Hex).toBe(createHash("sha256").update(content).digest("hex"));
      const stored = await readFile(join(storageRoot, rec.key));
      expect(stored.equals(content)).toBe(true);

      const row = await workspaceObjectsRepo.getArtifact(db, rec.id, uid);
      expect(row!.bytes).toBe(content.length);
      expect(row!.sha256).toBe(rec.sha256Hex);
      expect(row!.meta).toEqual({ name: "shot.png" });
    });

    it("requires exactly one of sourcePath | content", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const both = await registerArtifact(makeDeps(), {
        userId: uid,
        sessionId: sid,
        name: "x.txt",
        content: Buffer.from("a"),
        sourcePath: join(tempRoot, "x.txt"),
      }).catch((e: unknown) => e);
      expect(both).toBeInstanceOf(StorageError);
      expect((both as StorageError).code).toBe("invalid_arg");

      const neither = await registerArtifact(makeDeps(), {
        userId: uid,
        sessionId: sid,
        name: "x.txt",
      }).catch((e: unknown) => e);
      expect(neither).toBeInstanceOf(StorageError);
      expect((neither as StorageError).code).toBe("invalid_arg");
    });

    it("defaults contentType from the name (shot.png → image/png)", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const rec = await registerArtifact(makeDeps(), {
        userId: uid,
        sessionId: sid,
        name: "shot.png",
        content: Buffer.from("png-bytes"),
      });
      expect(rec.contentType).toBe("image/png");
      expect(rec.contentType).toBe(contentTypeFor("shot.png"));
    });

    it("honors an explicit contentType over the extension map", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const rec = await registerArtifact(makeDeps(), {
        userId: uid,
        sessionId: sid,
        name: "data.bin",
        contentType: "application/x-custom",
        content: Buffer.from("v"),
      });
      expect(rec.contentType).toBe("application/x-custom");
    });

    it("listArtifacts / getArtifact return the registered row (ownership scoped)", async () => {
      const uid = await seedUser();
      const otherUid = await seedUser();
      const sid = await seedSession(uid);
      const a = await registerArtifact(makeDeps(), {
        userId: uid,
        sessionId: sid,
        name: "a.txt",
        content: Buffer.from("a"),
      });
      const b = await registerArtifact(makeDeps(), {
        userId: uid,
        sessionId: sid,
        name: "b.txt",
        content: Buffer.from("b"),
      });

      const { rows, nextCursor } = await workspaceObjectsRepo.listArtifacts(db, sid, {
        limit: 10,
      });
      expect(nextCursor).toBeNull();
      const ids = rows.map((r) => r.id);
      expect(ids).toContain(a.id);
      expect(ids).toContain(b.id);
      // UUIDv7 order: newest (b) first
      expect(ids.indexOf(b.id)).toBeLessThan(ids.indexOf(a.id));

      expect((await workspaceObjectsRepo.getArtifact(db, a.id, uid))!.r2Key).toBe(a.key);
      expect(await workspaceObjectsRepo.getArtifact(db, a.id, otherUid)).toBeNull();
    });

    it("reserves actor/host artifact bytes and finalizes from actual HEAD metadata", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const content = Buffer.from("quota-artifact");
      const reserveInputs: Parameters<ArtifactQuota["reserveArtifact"]>[0][] = [];
      const finalizeInputs: Parameters<ArtifactQuota["finalizeUpload"]>[0][] = [];
      const quota: ArtifactQuota = {
        async reserveArtifact(input) {
          reserveInputs.push(input);
          return { ok: true, reservationId: input.artifactId };
        },
        async finalizeUpload(input) {
          finalizeInputs.push(input);
          return { ok: true, reservationId: input.reservationId };
        },
        async releaseUpload() {},
        async removeObject() {
          return { removed: true, freedBytes: content.length };
        },
      };
      const rec = await registerArtifact(makeDeps(T0, { quota }), {
        userId: uid,
        ownerUserId: uid,
        actorUserId: "collab-actor",
        sessionId: sid,
        name: "quota.txt",
        contentType: "text/plain",
        content,
      });
      expect(reserveInputs).toEqual([{
        actorUserId: "collab-actor",
        ownerUserId: uid,
        sessionId: sid,
        artifactId: rec.id,
        declaredBytes: content.length,
      }]);
      const head = await storage.head(rec.key);
      expect(finalizeInputs).toEqual([{
        reservationId: rec.id,
        actualBytes: head!.bytes,
        actualContentType: head!.contentType,
        etag: head!.etag,
      }]);
    });

    it("releases and removes an unregistered object when actual-byte finalization is exhausted", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const releases: string[] = [];
      const remove = vi.spyOn(storage, "delete");
      const quota: ArtifactQuota = {
        async reserveArtifact(input) {
          return { ok: true, reservationId: input.artifactId };
        },
        async finalizeUpload() {
          return { ok: false, scope: "storage", resetsAt: null };
        },
        async releaseUpload({ reservationId }) {
          releases.push(reservationId);
        },
        async removeObject() {
          throw new Error("a non-finalized reservation must not be removed as usage");
        },
      };
      await expect(registerArtifact(makeDeps(T0, { quota }), {
        userId: uid,
        sessionId: sid,
        name: "capped.txt",
        content: Buffer.from("cap"),
      })).rejects.toMatchObject({ code: "storage_quota_exceeded" });
      expect(releases).toHaveLength(1);
      const rows = await db.$client<{ r2_key: string }[]>`
        SELECT r2_key FROM workspace_objects WHERE session_id = ${sid}`;
      expect(rows).toEqual([]);
      expect(remove).toHaveBeenCalledTimes(1);
    });

    // UNEXECUTED round-1 regression for the production-compatible HTTP factory.
    it("mints through the signed HTTP grant factory and frozen version", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const grantSecret = "g".repeat(32);
      const grantKey = `users/${uid}/artifact-shares/frozen/sha256-${"a".repeat(64)}/object`;
      const fetchImpl = vi.fn(async () => new Response(JSON.stringify({
        grantId: "grant-artifact-1",
        key: grantKey,
      }), { status: 201, headers: { "content-type": "application/json" } }));
      const rec = await registerArtifact(makeDeps(T0, {
        cdn: { baseUrl: "https://cdn.test", secret: "s".repeat(32), ttlSeconds: 900 },
        grantFactory: createHttpArtifactGrantFactory({
          baseUrl: "http://gateway.internal",
          secret: grantSecret,
          fetchImpl: fetchImpl as unknown as typeof fetch,
          now: () => T0,
        }),
      }), {
        userId: uid,
        sessionId: sid,
        name: "frozen.png",
        content: Buffer.from("png"),
      });
      const url = new URL(rec.url);
      expect(url.searchParams.get("g")).toBe("grant-artifact-1");
      expect(url.searchParams.get("v")).toBe(rec.sha256Hex);
      const [requestUrl, init] = fetchImpl.mock.calls[0] as unknown as [URL, RequestInit];
      expect(requestUrl.toString()).toBe(`http://gateway.internal${ARTIFACT_GRANT_CREATE_PATH}`);
      expect(JSON.parse(String(init.body))).toEqual({
        actorUserId: uid,
        artifactId: rec.id,
        displayName: "frozen.png",
      });
      const headers = init.headers as Record<string, string>;
      expect(verifyInternalRequest(
        grantSecret,
        "POST",
        ARTIFACT_GRANT_CREATE_PATH,
        `${uid}:${rec.id}`,
        headers["X-Ovid-Timestamp"]!,
        headers["X-Ovid-Signature"]!,
        Math.floor(T0 / 1000),
      )).toBe(true);
    });

    it("uses short presigned URLs when the grant service is absent and forces active downloads", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const presign = vi.spyOn(storage, "presignGet");
      const rec = await registerArtifact(makeDeps(T0, {
        cdn: { baseUrl: "https://cdn.test", secret: "s".repeat(32), ttlSeconds: 900 },
      }), {
        userId: uid,
        sessionId: sid,
        name: "active.html",
        contentType: "text/html",
        content: Buffer.from("<h1>x</h1>"),
      });
      expect(rec.url).toMatch(/^file:/);
      expect(presign).toHaveBeenCalledWith(rec.key, TTL, {
        disposition: "attachment",
        filename: "active.html",
        contentType: "text/html",
      });
    });

    // UNEXECUTED N2: project capacity is checked before reservation or PUT.
    it("preserves project_file_limit before generic artifact storage and reservation", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const project = await projectsRepo.create(db, uid, "artifact-cap");
      expect(project).not.toBeNull();
      await db.$client`UPDATE sessions SET project_id = ${project!.id} WHERE id = ${sid}`;
      for (let index = 0; index < 80; index++) {
        await attachmentsRepo.create(db, {
          id: newId(), sessionId: sid, userId: uid, projectId: project!.id,
          name: `seed-${index}.txt`, size: 1, r2Key: `seed/${uid}/${index}`,
        });
      }
      expect((await projectFileUsage(db, uid, project!.id)).used).toBe(80);
      const reserveArtifact = vi.fn();
      const put = vi.spyOn(storage, "put");
      put.mockClear();
      await expect(registerArtifact(makeDeps(T0, {
        quota: {
          reserveArtifact,
          finalizeUpload: vi.fn(),
          releaseUpload: vi.fn(),
          removeObject: vi.fn(),
        },
      }), {
        userId: uid,
        sessionId: sid,
        name: "over-cap.txt",
        content: Buffer.from("must-not-store"),
      })).rejects.toMatchObject({ code: "project_file_limit" });
      expect(reserveArtifact).not.toHaveBeenCalled();
      expect(put).not.toHaveBeenCalled();
    });

    // UNEXECUTED round-1 regression: incomplete composition is explicitly off.
    it("refuses publication without a quota service before object or row creation", async () => {
      const uid = await seedUser();
      const sid = await seedSession(uid);
      const put = vi.spyOn(storage, "put");
      await expect(registerArtifact(makeDeps(T0, { quota: undefined }), {
        userId: uid,
        sessionId: sid,
        name: "disabled.txt",
        content: Buffer.from("must-not-publish"),
      })).rejects.toMatchObject({ code: "storage_quota_not_configured" });
      expect(put).not.toHaveBeenCalled();
      expect(await db.$client`SELECT id FROM workspace_objects WHERE session_id = ${sid}`)
        .toEqual([]);
    });

    it("shouldPresign table (pinned)", () => {
      const MiB = 1024 * 1024;
      expect(shouldPresign("text/plain", 100, MiB)).toBe(false);
      expect(shouldPresign("application/json", 100, MiB)).toBe(false);
      expect(shouldPresign("image/png", 100, MiB)).toBe(true);
      expect(shouldPresign("text/plain", 2 * MiB, MiB)).toBe(true);
    });
  },
);
