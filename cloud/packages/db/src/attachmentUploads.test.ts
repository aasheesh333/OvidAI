import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "./client.js";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";
import { attachments, newId, sessions, users } from "./repos.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL)("attachment upload finalization (real Postgres)", () => {
  let scratch: MigrationScratch;
  let db: Db;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "contracts_task3_uploads");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 4 });
  }, 120_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  async function seedAttachment(
    opts: { size?: number; contentType?: string } = {},
  ): Promise<{ id: string; sessionId: string; userId: string; r2Key: string }> {
    const userId = newId();
    await users.ensure(db, userId, null);
    const session = await sessions.create(db, userId);
    const id = newId();
    const r2Key = `users/${userId}/sessions/${session.id}/uploads/${id}`;
    await attachments.create(db, {
      id,
      sessionId: session.id,
      userId,
      name: "evidence.bin",
      size: opts.size ?? 4,
      r2Key,
      ...(opts.contentType !== undefined ? { contentType: opts.contentType } : {}),
    });
    return { id, sessionId: session.id, userId, r2Key };
  }

  async function stored(id: string, sessionId: string) {
    const rows = await attachments.getForSession(db, sessionId, [id]);
    expect(rows).toHaveLength(1);
    return rows[0]!;
  }

  it("finalizes actual HEAD bytes/type once and repeats identical HEAD idempotently", async () => {
    const a = await seedAttachment({ contentType: "text/plain" });
    const input = {
      id: a.id,
      sessionId: a.sessionId,
      userId: a.userId,
      actualBytes: 4,
      actualContentType: "text/plain",
    };

    const first = await attachments.finalizeUpload(db, input);
    expect(first).toMatchObject({
      id: a.id,
      uploadStatus: "ready",
      size: 4,
      contentType: "text/plain",
      contentTypeDeclared: true,
      actualBytes: 4,
      actualContentType: "text/plain",
    });
    expect(first.finalizedAt).toBeInstanceOf(Date);

    const repeated = await attachments.finalizeUpload(db, input);
    expect(repeated).toEqual(first);
    expect((await stored(a.id, a.sessionId)).finalizedAt).toEqual(first.finalizedAt);
  });

  it("records legacy unsigned HEAD metadata without treating octet-stream as a declared MIME", async () => {
    const a = await seedAttachment();
    const ready = await attachments.finalizeUpload(db, {
      id: a.id,
      sessionId: a.sessionId,
      userId: a.userId,
      actualBytes: 4,
      actualContentType: "application/x-actual-storage-type",
    });

    expect(ready).toMatchObject({
      uploadStatus: "ready",
      contentType: "application/octet-stream",
      contentTypeDeclared: false,
      actualBytes: 4,
      actualContentType: "application/x-actual-storage-type",
    });
  });

  it("accepts an absent legacy HEAD type while keeping the declared type unknown", async () => {
    const a = await seedAttachment();
    const ready = await attachments.finalizeUpload(db, {
      id: a.id,
      sessionId: a.sessionId,
      userId: a.userId,
      actualBytes: 4,
      actualContentType: null,
    });

    expect(ready).toMatchObject({
      uploadStatus: "ready",
      contentType: "application/octet-stream",
      actualContentType: null,
    });
  });

  it("requires exact HEAD type equality for an explicitly declared octet-stream", async () => {
    const a = await seedAttachment({ contentType: "application/octet-stream" });
    const ready = await attachments.finalizeUpload(db, {
      id: a.id,
      sessionId: a.sessionId,
      userId: a.userId,
      actualBytes: 4,
      actualContentType: "application/octet-stream",
    });

    expect(ready).toMatchObject({
      uploadStatus: "ready",
      contentType: "application/octet-stream",
      contentTypeDeclared: true,
      actualContentType: "application/octet-stream",
    });
  });

  it.each(["text/plain", null])(
    "rejects explicit octet-stream when actual HEAD type is %s",
    async (actualContentType) => {
      const a = await seedAttachment({ contentType: "application/octet-stream" });
      await expect(attachments.finalizeUpload(db, {
        id: a.id,
        sessionId: a.sessionId,
        userId: a.userId,
        actualBytes: 4,
        actualContentType,
      })).rejects.toMatchObject({ code: "type_mismatch" });

      expect(await stored(a.id, a.sessionId)).toMatchObject({
        uploadStatus: "failed",
        contentType: "application/octet-stream",
        contentTypeDeclared: true,
        actualContentType,
        finalizedAt: null,
      });
    },
  );

  it("rejects a size mismatch and leaves a not-ready row", async () => {
    const a = await seedAttachment({ size: 4, contentType: "text/plain" });
    await expect(attachments.finalizeUpload(db, {
      id: a.id,
      sessionId: a.sessionId,
      userId: a.userId,
      actualBytes: 5,
      actualContentType: "text/plain",
    })).rejects.toMatchObject({ code: "size_mismatch" });

    expect(await stored(a.id, a.sessionId)).toMatchObject({
      uploadStatus: "failed",
      actualBytes: 5,
      actualContentType: "text/plain",
      finalizedAt: null,
    });
  });

  it("rejects an exact Content-Type mismatch and leaves a not-ready row", async () => {
    const a = await seedAttachment({ contentType: "application/pdf" });
    await expect(attachments.finalizeUpload(db, {
      id: a.id,
      sessionId: a.sessionId,
      userId: a.userId,
      actualBytes: 4,
      actualContentType: "text/plain",
    })).rejects.toMatchObject({ code: "type_mismatch" });

    expect(await stored(a.id, a.sessionId)).toMatchObject({
      uploadStatus: "failed",
      contentType: "application/pdf",
      actualContentType: "text/plain",
      finalizedAt: null,
    });
  });

  it("rejects a changed object after readiness instead of preserving a stale ready claim", async () => {
    const a = await seedAttachment({ contentType: "text/plain" });
    const input = {
      id: a.id,
      sessionId: a.sessionId,
      userId: a.userId,
      actualBytes: 4,
      actualContentType: "text/plain",
    };
    await attachments.finalizeUpload(db, input);

    await expect(attachments.finalizeUpload(db, {
      ...input,
      actualBytes: 6,
    })).rejects.toMatchObject({ code: "object_changed" });
    expect(await stored(a.id, a.sessionId)).toMatchObject({
      uploadStatus: "failed",
      actualBytes: 6,
      actualContentType: "text/plain",
      finalizedAt: null,
    });
  });

  it("fails closed for a missing attachment, wrong owner, or wrong session", async () => {
    const a = await seedAttachment({ contentType: "text/plain" });
    const base = {
      id: a.id,
      sessionId: a.sessionId,
      userId: a.userId,
      actualBytes: 4,
      actualContentType: "text/plain",
    };

    for (const input of [
      { ...base, id: newId() },
      { ...base, userId: newId() },
      { ...base, sessionId: newId() },
    ]) {
      await expect(attachments.finalizeUpload(db, input)).rejects.toMatchObject({ code: "not_found" });
    }
    expect((await stored(a.id, a.sessionId)).uploadStatus).toBe("pending");
  });
});
