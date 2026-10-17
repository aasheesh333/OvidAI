import { createHash, randomBytes } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Redis } from "ioredis";
import { artifactCreatedPayloadSchema } from "@ovid/shared";

// Relative-source imports (Task-8 precedent; wave-merger converts at the next
// lockfile touch). @ovid/storage consumes db/events through structural mirrors.
import { createDb, migrate, type Db } from "../../db/src/client.js";
import {
  eventMirror as eventMirrorRepo,
  newId,
  sessions as sessionsRepo,
  workspaceObjects as workspaceObjectsRepo,
} from "../../db/src/repos.js";
import { users as usersTable } from "../../db/src/schema.js";
import { createRedisEventLog } from "../../events/src/eventLog.js";

import type { StorageAdapter } from "./adapter.js";
import { StorageError } from "./errors.js";
import { createFsStorage } from "./fsAdapter.js";
import {
  registerArtifact,
  type ArtifactDeps,
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
    let db: Db;
    let redis: Redis;
    let storageRoot: string;
    let tempRoot: string;
    let storage: StorageAdapter;
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

    function makeDeps(nowMs: number = T0): ArtifactDeps {
      return {
        db,
        events: createRedisEventLog(redis),
        storage,
        presignTtlSeconds: TTL,
        clock: () => new Date(nowMs),
        workspaceObjects: workspaceObjectsRepo,
        eventMirror: eventMirrorRepo,
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

      expect(rec.key).toBe(r2Keys.artifact(uid, sid, rec.id, "notes.txt"));
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

    it("shouldPresign table (pinned)", () => {
      const MiB = 1024 * 1024;
      expect(shouldPresign("text/plain", 100, MiB)).toBe(false);
      expect(shouldPresign("application/json", 100, MiB)).toBe(false);
      expect(shouldPresign("image/png", 100, MiB)).toBe(true);
      expect(shouldPresign("text/plain", 2 * MiB, MiB)).toBe(true);
    });
  },
);
