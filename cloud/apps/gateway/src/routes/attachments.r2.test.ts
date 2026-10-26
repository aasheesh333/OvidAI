import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { attachments, createDb, migrate, StorageReservationStore, type Db } from "@ovid/db";
import type { StorageAdapter } from "@ovid/storage";
import { createR2Storage, loadR2Config } from "@ovid/storage";
import { buildGateway } from "../app.js";
import { createMigrationScratch, type MigrationScratch } from "../../../../packages/db/src/migrationTestKit.js";
import { TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";

/**
 * REAL R2 acceptance for typed attachment storage.
 *
 * Gated on both a real Postgres (TEST_DATABASE_URL) and a complete OVID_R2_*
 * configuration; with either missing the whole file skips, so the committed
 * baseline stays green without credentials. Every object this file writes is
 * scoped to a per-run `users/<test-uid>/...` prefix and deleted in afterEach —
 * it never touches production user data.
 */
const R2_VARS = [
  "OVID_R2_ACCOUNT_ID",
  "OVID_R2_ACCESS_KEY_ID",
  "OVID_R2_SECRET_ACCESS_KEY",
  "OVID_R2_BUCKET",
] as const;
const r2Configured = R2_VARS.every((name) => (process.env[name] ?? "") !== "");

describe.skipIf(!TEST_DATABASE_URL || !r2Configured)(
  "gateway attachments against real R2 (env-gated)",
  () => {
    let scratch: MigrationScratch;
    let db: Db;
    let storage: StorageAdapter;
    const built: FastifyInstance[] = [];
    const writtenKeys: string[] = [];

    beforeAll(async () => {
      scratch = await createMigrationScratch(TEST_DATABASE_URL!, "gateway_attachments_r2");
      await migrate(scratch.url);
      db = createDb(scratch.url, { max: 8 });
      storage = createR2Storage(loadR2Config(process.env));
    }, 180_000);

    afterEach(async () => {
      while (built.length > 0) await built.pop()!.close();
      while (writtenKeys.length > 0) {
        await storage.delete(writtenKeys.pop()!).catch(() => {});
      }
    });

    afterAll(async () => {
      await db?.$client.end({ timeout: 5 });
      await scratch?.close();
    }, 30_000);

    function makeApp(): FastifyInstance {
      const app = buildGateway({
        system: stubSystemBus(),
        db,
        queues: stubQueues().queues,
        verifier: stubVerifier(),
        tickets: stubTickets(),
        keys: stubKeys(),
        mint: stubMint(),
        events: noopEvents,
        storage,
      });
      built.push(app);
      return app;
    }

    async function createSession(app: FastifyInstance, uid: string): Promise<string> {
      const res = await app.inject({
        method: "POST",
        url: "/cloud/v1/sessions",
        headers: authHeaders(uid),
        payload: {},
      });
      expect(res.statusCode).toBe(201);
      return res.json().id as string;
    }

    /** PUT the real bytes to the presigned URL the route returned. */
    async function putRealBytes(
      app: FastifyInstance,
      uid: string,
      sessionId: string,
      body: { name: string; size: number; contentType?: string },
      bytes: Buffer,
    ): Promise<{ attachmentId: string; statusCode: number }> {
      const created = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sessionId}/attachments`,
        headers: authHeaders(uid),
        payload: body,
      });
      expect(created.statusCode).toBe(201);
      const { attachmentId, uploadUrl, uploadHeaders } = created.json() as {
        attachmentId: string;
        uploadUrl: string;
        uploadHeaders: Record<string, string>;
      };
      writtenKeys.push(`users/${uid}/sessions/${sessionId}/uploads/${attachmentId}`);
      const put = await fetch(uploadUrl, {
        method: "PUT",
        headers: uploadHeaders,
        body: bytes,
      });
      expect([200, 204]).toContain(put.status);
      return { attachmentId, statusCode: put.status };
    }

    function finalize(app: FastifyInstance, uid: string, sessionId: string, attachmentId: string) {
      return app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sessionId}/attachments/${attachmentId}/finalize`,
        headers: authHeaders(uid),
        payload: {},
      });
    }

    async function counters(uid: string) {
      return db.$client`
        SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
          FROM storage_usage_counters WHERE owner_user_id = ${uid}`;
    }

    it("presign → real PUT → HEAD → finalize settles real bytes once", async () => {
      const app = makeApp();
      const uid = testUid("att-r2-ok");
      const sid = await createSession(app, uid);
      const bytes = Buffer.from("real r2 attachment payload", "utf8");
      const { attachmentId } = await putRealBytes(
        app,
        uid,
        sid,
        { name: "real.txt", size: bytes.length, contentType: "text/plain" },
        bytes,
      );

      // The object really exists in R2 with the declared type.
      const head = await storage.head(`users/${uid}/sessions/${sid}/uploads/${attachmentId}`);
      expect(head).toMatchObject({ bytes: bytes.length, contentType: "text/plain" });

      const finalized = await finalize(app, uid, sid, attachmentId);
      expect(finalized.statusCode).toBe(200);
      expect(finalized.json()).toMatchObject({
        status: "ready",
        size: bytes.length,
        contentType: "text/plain",
      });
      expect(await counters(uid)).toEqual([{ used: bytes.length, reserved: 0 }]);

      const replay = await finalize(app, uid, sid, attachmentId);
      expect(replay.statusCode).toBe(200);
      expect(replay.json()).toEqual(finalized.json());
      expect(await counters(uid)).toEqual([{ used: bytes.length, reserved: 0 }]);
      expect(await db.$client`
        SELECT used_uploads, reserved_uploads FROM upload_window_counters
         WHERE actor_user_id = ${uid}`)
        .toEqual([{ used_uploads: 1, reserved_uploads: 0 }]);
    }, 120_000);

    it("refuses a declared/actual size mismatch against real R2 bytes before settlement", async () => {
      const app = makeApp();
      const uid = testUid("att-r2-mismatch");
      const sid = await createSession(app, uid);
      const bytes = Buffer.from("four", "utf8");
      const { attachmentId } = await putRealBytes(
        app,
        uid,
        sid,
        { name: "mismatch.txt", size: bytes.length + 3, contentType: "text/plain" },
        bytes,
      );

      const res = await finalize(app, uid, sid, attachmentId);
      expect(res.statusCode).toBe(409);
      expect(res.json().error.code).toBe("attachment_size_mismatch");
      expect(await counters(uid)).toEqual([{ used: 0, reserved: 0 }]);
      expect(await db.$client`
        SELECT state FROM storage_reservations WHERE object_id = ${attachmentId}`)
        .toEqual([{ state: "released" }]);
      expect((await attachments.getForSession(db, sid, [attachmentId]))[0])
        .toMatchObject({ uploadStatus: "failed" });
    }, 120_000);

    it("detects a deleted real object and releases the charge exactly once", async () => {
      const app = makeApp();
      const uid = testUid("att-r2-deleted");
      const sid = await createSession(app, uid);
      const bytes = Buffer.from("delete me", "utf8");
      const { attachmentId } = await putRealBytes(
        app,
        uid,
        sid,
        { name: "deleted.txt", size: bytes.length, contentType: "text/plain" },
        bytes,
      );
      expect((await finalize(app, uid, sid, attachmentId)).statusCode).toBe(200);
      expect(await counters(uid)).toEqual([{ used: bytes.length, reserved: 0 }]);

      // Real deletion out of band.
      const key = `users/${uid}/sessions/${sid}/uploads/${attachmentId}`;
      await storage.delete(key);
      writtenKeys.splice(writtenKeys.indexOf(key), 1);
      expect(await storage.head(key)).toBeNull();

      for (let attempt = 0; attempt < 2; attempt++) {
        const res = await finalize(app, uid, sid, attachmentId);
        expect(res.statusCode).toBe(409);
        expect(res.json().error.code).toBe("attachment_not_uploaded");
      }
      expect(await counters(uid)).toEqual([{ used: 0, reserved: 0 }]);
      expect(await db.$client`
        SELECT count(*)::int AS count FROM storage_reservations
         WHERE object_id = ${attachmentId} AND state = 'finalized'`)
        .toEqual([{ count: 0 }]);
    }, 120_000);

    it("never lets a cross-owner session reach the object (real HEAD is not called)", async () => {
      const app = makeApp();
      const owner = testUid("att-r2-owner");
      const stranger = testUid("att-r2-stranger");
      const ownerSession = await createSession(app, owner);
      const strangerSession = await createSession(app, stranger);
      const bytes = Buffer.from("owned", "utf8");
      const { attachmentId } = await putRealBytes(
        app,
        owner,
        ownerSession,
        { name: "owned.txt", size: bytes.length, contentType: "text/plain" },
        bytes,
      );

      const res = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${strangerSession}/attachments/${attachmentId}/finalize`,
        headers: authHeaders(stranger),
        payload: {},
      });
      expect(res.statusCode).toBe(404);
      expect(res.json().error.code).toBe("not_found");
      expect((await attachments.getForSession(db, ownerSession, [attachmentId]))[0])
        .toMatchObject({ uploadStatus: "pending" });
      expect(await counters(owner)).toEqual([{ used: 0, reserved: bytes.length }]);

      // The owner still finalizes normally afterwards.
      expect((await finalize(app, owner, ownerSession, attachmentId)).statusCode).toBe(200);
      expect(await counters(owner)).toEqual([{ used: bytes.length, reserved: 0 }]);
    }, 120_000);
  },
);
