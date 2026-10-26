import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { attachments, createDb, migrate, newId, projectFileUsage, projectsRepo, StorageReservationStore, type Db, type StorageReservationInput } from "@ovid/db";
import {
  attachmentUploadResponseSchema,
  type AttachmentUploadResponse,
} from "@ovid/shared";
import { buildGateway } from "../app.js";
import type { HeadResult, StorageAdapter } from "@ovid/storage";
import type { AttachmentPresigner } from "./attachments.js";
import { createMigrationScratch, type MigrationScratch } from "../../../../packages/db/src/migrationTestKit.js";
import { TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubTickets,
  stubVerifier,
  stubSystemBus,
} from "../test/stubs.js";

const UUIDV7_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/**
 * Fake presigner injected via deps (the P8-Q3 seam): captures every
 * (key, ttlSeconds) pair and answers a deterministic URL derived from the key,
 * so the route's key-layout pin is exact.
 */
interface PresignCall {
  key: string;
  ttlSeconds: number;
  contentType?: string;
}

function stubPresigner(behavior: { fail?: boolean; head?: HeadResult | null } = {}): AttachmentPresigner & {
  calls: PresignCall[];
  deleted: string[];
  setHead(head: HeadResult | null): void;
} {
  const calls: PresignCall[] = [];
  const deleted: string[] = [];
  let currentHead = behavior.head;
  return {
    calls,
    deleted,
    setHead(head) {
      currentHead = head;
    },
    async presignPut(input) {
      calls.push({ ...input });
      if (behavior.fail) throw new Error("presigner unavailable");
      return `https://r2.test/bucket/${encodeURIComponent(input.key)}?X-Signature=stub`;
    },
    async delete(key) {
      deleted.push(key);
    },
    ...(behavior.head !== undefined
      ? { head: async () => currentHead ?? null }
      : {}),
  };
}

const built: FastifyInstance[] = [];

describe.skipIf(!TEST_DATABASE_URL)("gateway attachment routes (real postgres)", () => {
  let scratch: MigrationScratch;
  let db: Db;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "gateway_attachments");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 8 });
  }, 180_000);

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  /**
   * Fresh gateway per test with the fake presigner injected (or deliberately
   * absent when `noPresigner` — the loud-fallback pin).
   */
  function makeApp(opts: {
    noPresigner?: boolean;
    failPresign?: boolean;
    head?: HeadResult | null;
    /** Compose the artifact vault/CDN routes with a storage adapter. */
    withStorage?: boolean;
  } = {}):
    { app: FastifyInstance; presigner: AttachmentPresigner & {
      calls: PresignCall[];
      deleted: string[];
      setHead(head: HeadResult | null): void;
    } } {
    const presigner = stubPresigner({ fail: opts.failPresign, head: opts.head });
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      ...(opts.noPresigner ? {} : { presigner }),
      ...(opts.withStorage === true ? { storage: presigner as unknown as StorageAdapter } : {}),
    });
    built.push(app);
    return { app, presigner };
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

  function postAttachment(
    app: FastifyInstance,
    uid: string,
    sessionId: string,
    body: unknown,
    headers: Record<string, string> | null = null,
  ) {
    return app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sessionId}/attachments`,
      headers: headers ?? authHeaders(uid),
      payload: body as object,
    });
  }

  /** Pin the canonical Free plan first so the project cap is deterministically 80. */
  async function pinFreeCap(uid: string): Promise<void> {
    await db.$client.unsafe(
      `INSERT INTO plans (id, name, price_usd, enabled, aliases, window_hours, mult, slow_mode, auto_oss, position)
       VALUES ('free', 'Free', '0', true, '[]'::jsonb, 24, '1', false, false, -1000000)
       ON CONFLICT (id) DO UPDATE SET enabled = true, position = -1000000`,
    );
    await db.$client.unsafe(`UPDATE users SET tier = 'free' WHERE uid = $1`, [uid]);
  }

  it("create → 201 with attachmentId/uploadUrl/path/expiresAt, key layout pinned, db row written", async () => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-ok");
    const sid = await createSession(app, uid);

    const res = await postAttachment(app, uid, sid, { name: "photo 1.png", size: 1234 });
    expect(res.statusCode).toBe(201);
    const body = attachmentUploadResponseSchema.parse(res.json()) as AttachmentUploadResponse;
    expect(body.attachmentId).toMatch(UUIDV7_RE);

    // Key layout pin (brief): users/{uid}/sessions/{sessionId}/uploads/{attachmentId}
    const expectedKey = `users/${uid}/sessions/${sid}/uploads/${body.attachmentId}`;
    expect(presigner.calls).toEqual([{ key: expectedKey, ttlSeconds: 900 }]);
    expect(body.uploadUrl).toBe(`https://r2.test/bucket/${encodeURIComponent(expectedKey)}?X-Signature=stub`);
    // The old {name,size} request persists the unknown-type fallback but does
    // not sign or require a Content-Type header, even for a .png filename.
    expect(body.contentType).toBe("application/octet-stream");
    expect(body.uploadHeaders).toEqual({});

    // path is the workspace-relative uploads/{sanitizedName}
    expect(body.path).toBe("uploads/photo_1.png");

    // expiresAt is a parseable ISO timestamp ~15 min in the future.
    const ms = Date.parse(body.expiresAt);
    expect(ms).not.toBeNaN();
    expect(ms).toBeGreaterThan(Date.now());

    // The db row: one attachment for the session with the exact r2Key/name/size/user.
    const rows = await attachments.getForSession(db, sid);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      id: body.attachmentId,
      sessionId: sid,
      userId: uid,
      name: "photo 1.png",
      size: 1234,
      r2Key: expectedKey,
      contentType: "application/octet-stream",
      contentTypeDeclared: false,
      uploadStatus: "pending",
      actualBytes: null,
      actualContentType: null,
      finalizedAt: null,
    });
  });

  it.each([
    ["Application/PDF", "application/pdf"],
    ["application/x-ovid-unknown", "application/x-ovid-unknown"],
  ])("normalizes %s and binds the identical type to signing and exact upload headers", async (declared, canonical) => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-typed");
    const sid = await createSession(app, uid);

    const res = await postAttachment(app, uid, sid, {
      name: "misleading-extension.txt",
      size: 2048,
      contentType: declared,
    });
    expect(res.statusCode).toBe(201);
    const body = attachmentUploadResponseSchema.parse(res.json()) as AttachmentUploadResponse;
    expect(body.contentType).toBe(canonical);
    expect(body.uploadHeaders).toEqual({ "Content-Type": canonical });
    expect(presigner.calls).toEqual([{
      key: `users/${uid}/sessions/${sid}/uploads/${body.attachmentId}`,
      ttlSeconds: 900,
      contentType: canonical,
    }]);
    const rows = await attachments.getForSession(db, sid);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      contentType: canonical,
      contentTypeDeclared: true,
      uploadStatus: "pending",
    });
  });

  it("size over the 25 MB cap → 400 attachment_too_large; exactly 25_000_000 is allowed; nothing written over the cap", async () => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-big");
    const sid = await createSession(app, uid);

    const over = await postAttachment(app, uid, sid, { name: "big.bin", size: 25_000_001 });
    expect(over.statusCode).toBe(400);
    expect(over.json()).toEqual({
      error: {
        code: "attachment_too_large",
        message: expect.any(String) as string,
      },
    });

    // The boundary itself passes, and the cap check happens before the
    // presigner (no wasted signing) and before any write.
    expect(presigner.calls).toHaveLength(0);
    const atCap = await postAttachment(app, uid, sid, { name: "edge.bin", size: 25_000_000 });
    expect(atCap.statusCode).toBe(201);
    expect(await attachments.getForSession(db, sid)).toHaveLength(1);
  });

  it("malformed bodies → 400 bad_request: missing/empty name, non-integer or non-positive size, unknown keys", async () => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-bad");
    const sid = await createSession(app, uid);

    for (const body of [
      { size: 10 },
      { name: "", size: 10 },
      { name: "ok" },
      { name: "ok", size: 0 },
      { name: "ok", size: -5 },
      { name: "ok", size: 1.5 },
      { name: "ok", size: "10" },
      { name: "ok", size: 10, extra: 1 },
    ]) {
      const res = await postAttachment(app, uid, sid, body);
      expect(res.statusCode, JSON.stringify(body)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
    expect(presigner.calls).toHaveLength(0);
    expect(await attachments.getForSession(db, sid)).toEqual([]);
  });

  it("invalid contentType values are rejected before signing or attachment writes", async () => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-bad-mime");
    const sid = await createSession(app, uid);
    const invalid = [
      "",
      `${"a".repeat(128)}/${"b".repeat(127)}`,
      "text/plain; charset=utf-8",
      "text/*",
      "*/plain",
      "text/plain\r\nX-Injected: yes",
      "text/\u2028plain",
      "text/\u2029plain",
      "text/pläin",
      " text/plain ",
    ];

    for (const contentType of invalid) {
      const res = await postAttachment(app, uid, sid, { name: "ok.bin", size: 10, contentType });
      expect(res.statusCode, JSON.stringify(contentType)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
    expect(presigner.calls).toEqual([]);
    expect(await attachments.getForSession(db, sid)).toEqual([]);
  });

  it("non-owner session, unknown session, malformed :id → 404 not_found (checked BEFORE body validation and signing)", async () => {
    const { app, presigner } = makeApp();
    const owner = testUid("att-owner");
    const stranger = testUid("att-stranger");
    const sid = await createSession(app, owner);

    // A stranger with a VALID body gets the same 404 as one with garbage —
    // no existence leaks through validation behavior.
    for (const body of [{ name: "sneak.txt", size: 1 }, { name: "" }]) {
      const res = await postAttachment(app, stranger, sid, body);
      expect(res.statusCode, JSON.stringify(body)).toBe(404);
      expect(res.json().error.code).toBe("not_found");
    }
    const unknown = await postAttachment(app, owner, newId(), { name: "x.txt", size: 1 });
    expect(unknown.statusCode).toBe(404);
    for (const bad of ["not-a-uuid", "1234567"]) {
      const res = await postAttachment(app, owner, bad, { name: "x.txt", size: 1 });
      expect(res.statusCode, bad).toBe(404);
      expect(res.statusCode, bad).not.toBe(500);
    }
    expect(presigner.calls).toHaveLength(0);
    expect(await attachments.getForSession(db, sid)).toEqual([]);
  });

  it("no presigner configured → loud 503 attachments_not_configured (never a silent no-op, never a 500)", async () => {
    const { app } = makeApp({ noPresigner: true });
    const uid = testUid("att-nopresign");
    const sid = await createSession(app, uid);

    const res = await postAttachment(app, uid, sid, { name: "x.txt", size: 1 });
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({
      error: {
        code: "attachments_not_configured",
        message: expect.any(String) as string,
      },
    });
    expect(await attachments.getForSession(db, sid)).toEqual([]);
  });

  it("presigner rejection → 500 internal, no attachment row left behind (sign happens BEFORE the insert)", async () => {
    const { app } = makeApp({ failPresign: true });
    const uid = testUid("att-fail");
    const sid = await createSession(app, uid);

    const res = await postAttachment(app, uid, sid, { name: "x.txt", size: 1 });
    expect(res.statusCode).toBe(500);
    expect(res.json().error.code).toBe("internal");
    expect(await attachments.getForSession(db, sid)).toEqual([]);
  });

  it("reserves before signing, finalizes only actual HEAD bytes, and releases a failed declaration", async () => {
    const head: HeadResult = {
      bytes: 11,
      contentType: "text/plain",
      sha256Hex: "a".repeat(64),
      etag: "etag-1",
      metadata: {},
    };
    const { app } = makeApp({ head, withStorage: true });
    const uid = testUid("att-quota");
    const sid = await createSession(app, uid);
    const created = await postAttachment(app, uid, sid, { name: "actual.txt", size: 11 });
    expect(created.statusCode).toBe(201);
    const attachmentId = created.json().attachmentId as string;
    expect(await db.$client`
      SELECT declared_bytes::int AS declared, state FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([{ declared: 11, state: "reserved" }]);

    const finalized = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/attachments/${attachmentId}/finalize`,
      headers: authHeaders(uid),
      payload: {},
    });
    expect(finalized.statusCode).toBe(200);
    expect(finalized.json()).toMatchObject({ status: "ready", size: 11, contentType: "text/plain" });
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 11, reserved: 0 }]);

    const mismatched = await postAttachment(app, uid, sid, { name: "declared.txt", size: 99 });
    const mismatchId = mismatched.json().attachmentId as string;
    const mismatch = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/attachments/${mismatchId}/finalize`,
      headers: authHeaders(uid),
      payload: {},
    });
    expect(mismatch.statusCode).toBe(409);
    expect(mismatch.json().error.code).toBe("attachment_size_mismatch");
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 11, reserved: 0 }]);
    expect(await db.$client`
      SELECT state FROM storage_reservations WHERE id = ${mismatchId}`)
      .toEqual([{ state: "released" }]);
    // UNEXECUTED round-1 regression: failed/mismatched rows never mint.
    for (const url of [
      `/cloud/v1/sessions/${sid}/attachments/${mismatchId}/cdn-url`,
      `/cloud/v1/artifacts/${mismatchId}/url?source=uploaded`,
    ]) {
      expect((await app.inject({ method: "GET", url, headers: authHeaders(uid) })).statusCode)
        .toBe(404);
    }
  });

  it("releases the reservation when signing fails", async () => {
    const { app } = makeApp({ failPresign: true });
    const uid = testUid("att-fail-release");
    const sid = await createSession(app, uid);
    const res = await postAttachment(app, uid, sid, { name: "x.txt", size: 7 });
    expect(res.statusCode).toBe(500);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
    expect(await db.$client`
      SELECT state FROM storage_reservations WHERE owner_user_id = ${uid}`)
      .toEqual([{ state: "released" }]);
  });

  // UNEXECUTED under the 2026-10-25 heavy-verification pause.
  it("repairs a legacy pending row with a reservation before actual-byte finalization", async () => {
    const head: HeadResult = {
      bytes: 11,
      contentType: "text/plain",
      sha256Hex: "b".repeat(64),
      etag: "legacy-etag",
      metadata: {},
    };
    const { app } = makeApp({ head });
    const uid = testUid("att-legacy-reservation");
    const sid = await createSession(app, uid);
    const attachmentId = newId();
    await attachments.create(db, {
      id: attachmentId,
      sessionId: sid,
      userId: uid,
      name: "legacy.txt",
      size: 11,
      r2Key: `users/${uid}/sessions/${sid}/uploads/${attachmentId}`,
      contentType: "text/plain",
    });
    expect(await db.$client`SELECT id FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([]);
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/attachments/${attachmentId}/finalize`,
      headers: authHeaders(uid),
      payload: {},
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ status: "ready", size: 11 });
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 11, reserved: 0 }]);
  });

  // UNEXECUTED under the 2026-10-25 heavy-verification pause.
  it("releases a pending reservation when HEAD proves the upload is absent", async () => {
    const { app } = makeApp({ head: null });
    const uid = testUid("att-missing-release");
    const sid = await createSession(app, uid);
    const created = await postAttachment(app, uid, sid, { name: "missing.txt", size: 9 });
    expect(created.statusCode).toBe(201);
    const attachmentId = created.json().attachmentId as string;
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/attachments/${attachmentId}/finalize`,
      headers: authHeaders(uid),
      payload: {},
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("attachment_not_uploaded");
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([{ state: "released" }]);
  });

  // UNEXECUTED R6-1: a late object and host row must be compensated when the
  // post-release missing-HEAD status write fails, including after finalization.
  it.each([false, true])(
    "compensates missing-HEAD status-write failure (already finalized: %s)",
    async (alreadyFinalized) => {
      const actualHead: HeadResult = {
        bytes: 4,
        contentType: "text/plain",
        sha256Hex: null,
        etag: "before-missing-head",
        metadata: {},
      };
      const { app, presigner } = makeApp({ head: alreadyFinalized ? actualHead : null });
      const uid = testUid(`att-missing-status-write-${alreadyFinalized}`);
      const sid = await createSession(app, uid);
      const created = await postAttachment(app, uid, sid, {
        name: "missing-status-write.txt",
        size: 4,
        contentType: "text/plain",
      });
      expect(created.statusCode).toBe(201);
      const attachmentId = created.json().attachmentId as string;
      const r2Key = `users/${uid}/sessions/${sid}/uploads/${attachmentId}`;
      const finalize = () => app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sid}/attachments/${attachmentId}/finalize`,
        headers: authHeaders(uid),
        payload: {},
      });
      if (alreadyFinalized) {
        expect((await finalize()).statusCode).toBe(200);
        expect((await attachments.getForSession(db, sid, [attachmentId]))[0]?.uploadStatus)
          .toBe("ready");
        expect(await db.$client`
          SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
            FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
          .toEqual([{ used: 4, reserved: 0 }]);
      }

      presigner.setHead(null);
      const originalHead = presigner.head!;
      let lateObjectInstalled = false;
      presigner.head = async (key) => {
        const current = await originalHead.call(presigner, key);
        if (current === null && !lateObjectInstalled) {
          // The object becomes visible immediately after the missing HEAD, as
          // a late PUT can. Full compensation must still delete that key.
          lateObjectInstalled = true;
          presigner.setHead({ ...actualHead, etag: "late-after-missing-head" });
        }
        return current;
      };

      const suffix = attachmentId.replaceAll("-", "");
      const functionName = `fail_status_${suffix}`;
      const triggerName = `fail_status_row_${suffix}`;
      try {
        await db.$client.unsafe(`
          CREATE FUNCTION ${functionName}() RETURNS trigger AS $status_failure$
          BEGIN
            -- Let the reservation's pending → failed update commit. Fail only
            -- the later route status write (ready/failed → failed).
            IF NEW.id = '${attachmentId}'::text
               AND NEW.upload_status = 'failed'
               AND OLD.upload_status IN ('ready', 'failed') THEN
              RAISE EXCEPTION 'injected missing-HEAD status-write failure';
            END IF;
            RETURN NEW;
          END;
          $status_failure$ LANGUAGE plpgsql`);
        await db.$client.unsafe(`
          CREATE TRIGGER ${triggerName} BEFORE UPDATE ON attachments
          FOR EACH ROW EXECUTE FUNCTION ${functionName}()`);
        const response = await finalize();
        expect(response.statusCode).toBe(500);
      } finally {
        presigner.head = originalHead;
        try {
          await db.$client.unsafe(`DROP TRIGGER IF EXISTS ${triggerName} ON attachments`);
        } finally {
          await db.$client.unsafe(`DROP FUNCTION IF EXISTS ${functionName}()`);
        }
      }

      expect(lateObjectInstalled).toBe(true);
      expect(presigner.deleted).toEqual([r2Key]);
      expect(await attachments.getForSession(db, sid, [attachmentId])).toEqual([]);
      expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${attachmentId}`)
        .toEqual([{ state: "released" }]);
      expect(await db.$client`
        SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
          FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
        .toEqual([{ used: 0, reserved: 0 }]);
    },
  );

  // UNEXECUTED round-1 regression: late bytes never revive a released row.
  it("fences late PUT finalization, worker ready, and both download routes", async () => {
    const { app, presigner } = makeApp({ head: null, withStorage: true });
    const uid = testUid("att-late-put");
    const sid = await createSession(app, uid);
    const created = await postAttachment(app, uid, sid, { name: "late.txt", size: 4 });
    const attachmentId = created.json().attachmentId as string;
    const finalize = () => app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/attachments/${attachmentId}/finalize`,
      headers: authHeaders(uid),
      payload: {},
    });
    expect((await finalize()).statusCode).toBe(409);
    expect((await attachments.getForSession(db, sid, [attachmentId]))[0])
      .toMatchObject({ uploadStatus: "failed", actualBytes: null });

    presigner.setHead({
      bytes: 4,
      contentType: "application/octet-stream",
      sha256Hex: null,
      etag: "late-etag",
      metadata: {},
    });
    const late = await finalize();
    expect(late.statusCode).toBe(409);
    expect(late.json().error.code).toBe("attachment_changed");
    await expect(attachments.finalizeUpload(db, {
      id: attachmentId,
      sessionId: sid,
      userId: uid,
      actualBytes: 4,
      actualContentType: "application/octet-stream",
    })).rejects.toMatchObject({ code: "attachment_failed" });
    expect((await attachments.getForSession(db, sid, [attachmentId]))[0]?.uploadStatus)
      .toBe("failed");
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([{ state: "released" }]);
    for (const url of [
      `/cloud/v1/sessions/${sid}/attachments/${attachmentId}/cdn-url`,
      `/cloud/v1/artifacts/${attachmentId}/url?source=uploaded`,
    ]) {
      const response = await app.inject({ method: "GET", url, headers: authHeaders(uid) });
      expect(response.statusCode).toBe(404);
    }
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
  });

  // UNEXECUTED N1: failed ordinary uploads do not retain project-file slots.
  it("reclaims the project slot after a missing-HEAD upload failure", async () => {
    const { app } = makeApp({ head: null });
    const uid = testUid("att-failed-project-slot");
    await pinFreeCap(uid);
    const sid = await createSession(app, uid);
    const project = await projectsRepo.create(db, uid, "failed-upload-slot");
    expect(project).not.toBeNull();
    expect(await projectsRepo.moveSession(db, uid, sid, project!.id)).not.toBeNull();
    const created = await postAttachment(app, uid, sid, { name: "missing.txt", size: 9 });
    expect(created.statusCode).toBe(201);
    const attachmentId = created.json().attachmentId as string;
    expect((await projectFileUsage(db, uid, project!.id)).used).toBe(1);
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/attachments/${attachmentId}/finalize`,
      headers: authHeaders(uid),
      payload: {},
    });
    expect(res.statusCode).toBe(409);
    expect((await projectFileUsage(db, uid, project!.id)).used).toBe(0);
  });

  // UNEXECUTED round-3: reservationless legacy rows cannot revive on late PUT.
  it("fails a reservationless pending legacy row on missing HEAD and denies late PUT", async () => {
    const { app, presigner } = makeApp({ head: null });
    const uid = testUid("att-legacy-missing");
    const sid = await createSession(app, uid);
    const attachmentId = newId();
    await attachments.create(db, {
      id: attachmentId,
      sessionId: sid,
      userId: uid,
      name: "legacy-pending.txt",
      size: 4,
      r2Key: `users/${uid}/sessions/${sid}/uploads/${attachmentId}`,
    });
    expect(await db.$client`SELECT id FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([]);
    const finalize = () => app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/attachments/${attachmentId}/finalize`,
      headers: authHeaders(uid),
      payload: {},
    });
    expect((await finalize()).statusCode).toBe(409);
    expect((await attachments.getForSession(db, sid, [attachmentId]))[0])
      .toMatchObject({ uploadStatus: "failed", actualBytes: null });
    presigner.setHead({
      bytes: 4,
      contentType: "application/octet-stream",
      sha256Hex: null,
      etag: "late-legacy-etag",
      metadata: {},
    });
    expect((await finalize()).statusCode).toBe(409);
    expect((await attachments.getForSession(db, sid, [attachmentId]))[0]?.uploadStatus)
      .toBe("failed");
    expect((await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/attachments/${attachmentId}/cdn-url`,
      headers: authHeaders(uid),
    })).statusCode).toBe(404);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
  });

  // UNEXECUTED R4-2: valid stale HEAD cannot beat the missing-HEAD failure.
  it("serializes legacy valid-HEAD reserve against missing-HEAD failure without ready resurrection", async () => {
    const { app, presigner } = makeApp({ head: null });
    const uid = testUid("att-legacy-race");
    const sid = await createSession(app, uid);
    const attachmentId = newId();
    await attachments.create(db, {
      id: attachmentId,
      sessionId: sid,
      userId: uid,
      name: "legacy-race.txt",
      size: 4,
      r2Key: `users/${uid}/sessions/${sid}/uploads/${attachmentId}`,
    });
    presigner.setHead({
      bytes: 4,
      contentType: "application/octet-stream",
      sha256Hex: null,
      etag: "valid-before-delete",
      metadata: {},
    });
    const finalize = () => app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/attachments/${attachmentId}/finalize`,
      headers: authHeaders(uid),
      payload: {},
    });
    const originalReserve = StorageReservationStore.prototype.reserve;
    let entered!: () => void;
    let proceed!: () => void;
    let firstValidHeadCall = true;
    const reserveEntered = new Promise<void>((resolve) => { entered = resolve; });
    const proceedReserve = new Promise<void>((resolve) => { proceed = resolve; });
    const reserve = vi.spyOn(StorageReservationStore.prototype, "reserve")
      .mockImplementation(async function (this: StorageReservationStore, input: StorageReservationInput) {
        if (firstValidHeadCall && input.head !== undefined && input.head !== null) {
          firstValidHeadCall = false;
          entered();
          await proceedReserve;
        }
        return originalReserve.call(this, input);
      });
    try {
      const valid = finalize();
      await reserveEntered;
      presigner.setHead(null);
      expect((await finalize()).statusCode).toBe(409);
      proceed();
      // The stale valid request must not turn B's failed row back to ready or
      // return success after B has reconciled the missing object.
      expect((await valid).statusCode).toBe(409);
      // A repeated missing-HEAD request hits the failed/released identity and
      // must retain the same deterministic refusal rather than escaping 500.
      expect((await finalize()).statusCode).toBe(409);
    } finally {
      proceed();
      reserve.mockRestore();
    }
    expect((await attachments.getForSession(db, sid, [attachmentId]))[0])
      .toMatchObject({ uploadStatus: "failed", actualBytes: null, finalizedAt: null });
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([{ state: "released" }]);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
  });

  // UNEXECUTED R5-4: generic ready-write failure compensates every transition.
  it("compensates a generic post-settlement ready-write failure with zero charge and no orphan row", async () => {
    const { app, presigner } = makeApp({
      head: {
        bytes: 4,
        contentType: "text/plain",
        sha256Hex: null,
        etag: "ready-failure",
        metadata: {},
      },
    });
    const uid = testUid("att-ready-write-failure");
    const sid = await createSession(app, uid);
    const created = await postAttachment(app, uid, sid, {
      name: "ready-failure.txt",
      size: 4,
      contentType: "text/plain",
    });
    const attachmentId = created.json().attachmentId as string;
    const readyWrite = vi.spyOn(attachments, "finalizeUpload")
      .mockRejectedValueOnce(new Error("generic ready-write failure"));
    try {
      const response = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sid}/attachments/${attachmentId}/finalize`,
        headers: authHeaders(uid),
        payload: {},
      });
      expect(response.statusCode).toBe(500);
    } finally {
      readyWrite.mockRestore();
    }
    expect(await attachments.getForSession(db, sid, [attachmentId])).toEqual([]);
    expect(presigner.deleted).toEqual([
      `users/${uid}/sessions/${sid}/uploads/${attachmentId}`,
    ]);
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([{ state: "released" }]);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
  });

  it("hostile names sanitize into a safe single uploads/ segment for `path`", async () => {
    const { app } = makeApp();
    const uid = testUid("att-sanitize");
    const sid = await createSession(app, uid);

    const cases: Array<[string, string]> = [
      // "../../etc/passwd": both "/" runs → "_", leading dots stripped, the
      // interior ".." run collapsed → three underscores then "etc_passwd".
      ["../../etc/passwd", "___etc_passwd"],
      ["..", "attachment"],
      ["a..b", "a_b"],
      [".hidden", "hidden"],
    ];
    for (const [name, expected] of cases) {
      const res = await postAttachment(app, uid, sid, { name, size: 1 });
      expect(res.statusCode, name).toBe(201);
      expect((res.json() as AttachmentUploadResponse).path).toBe(`uploads/${expected}`);
    }
    // The raw name is stored verbatim in the row (sanitization is a
    // workspace-path concern, never a display rewrite).
    const rows = await attachments.getForSession(db, sid);
    expect(rows.map((r) => r.name)).toEqual(cases.map(([name]) => name));
  });

  it("project chat: cap 80 counts uploads; the 81st is refused BEFORE presign, deleting one frees it; standalone is unaffected", async () => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-project-cap");
    await pinFreeCap(uid);
    const sid = await createSession(app, uid);

    const projectRes = await app.inject({
      method: "POST",
      url: "/cloud/v1/projects",
      headers: authHeaders(uid),
      payload: { name: "Cap project" },
    });
    expect(projectRes.statusCode).toBe(201);
    const projectId = projectRes.json().id as string;
    const moved = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/project`,
      headers: authHeaders(uid),
      payload: { projectId },
    });
    expect(moved.statusCode).toBe(200);

    // Fill the project's budget directly (the route's own enforcement is what
    // this test exercises; the seed goes through the same repo check).
    for (let i = 0; i < 80; i++) {
      await attachments.create(db, {
        id: newId(),
        sessionId: sid,
        userId: uid,
        name: `f${i}.bin`,
        size: 1,
        r2Key: `seed/${uid}/${i}/${newId()}`,
        projectId,
      });
    }
    expect(await attachments.getForSession(db, sid)).toHaveLength(80);

    const refused = await postAttachment(app, uid, sid, { name: "81.bin", size: 1 });
    expect(refused.statusCode).toBe(409);
    expect(refused.json()).toEqual({
      error: { code: "project_file_limit", message: expect.any(String) as string },
    });
    // Refused before signing and before any row: no presign call, still 80.
    expect(presigner.calls).toEqual([]);
    expect(await attachments.getForSession(db, sid)).toHaveLength(80);

    // Deleting a file frees exactly one slot.
    const [oldest] = await attachments.getForSession(db, sid);
    await db.$client`delete from attachments where id = ${oldest!.id}`;
    const accepted = await postAttachment(app, uid, sid, { name: "again.bin", size: 1 });
    expect(accepted.statusCode).toBe(201);
    expect(presigner.calls).toHaveLength(1);
    expect(await attachments.getForSession(db, sid)).toHaveLength(80);

    // A standalone chat in the same account is not subject to the project cap.
    const standalone = await createSession(app, uid);
    const standaloneRes = await postAttachment(app, uid, standalone, { name: "free.bin", size: 1 });
    expect(standaloneRes.statusCode).toBe(201);
  });

  it("attachment routes answer 401 unauthenticated with the shared envelope", async () => {
    const { app } = makeApp();
    const uid = testUid("att-401");
    const sid = await createSession(app, uid);
    const res = await postAttachment(app, uid, sid, { name: "x.txt", size: 1 }, {});
    expect(res.statusCode).toBe(401);
    expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
  });
});
