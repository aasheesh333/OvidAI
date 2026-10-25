import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { storageBytes } from "@ovid/shared";
import { createDb, migrate, type Db } from "./client.js";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";
import { attachments, newId, sessions, users, workspaceObjects } from "./repos.js";
import { sweepAbandonedStorageReservations } from "./quotaService.js";
import {
  cleanupStorageObjectRace,
  createStorageQuotaRepos,
  storageUsage,
  type StorageQuotaRepos,
} from "./index.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const NOW = new Date("2026-10-24T12:00:00.000Z");

describe.skipIf(!TEST_DATABASE_URL).sequential("transactional storage quota repos (isolated Postgres)", () => {
  let scratch: MigrationScratch;
  let db: Db;
  let clock = NOW;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "storage_quota_repos");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 16 });
  }, 180_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  function repos(): StorageQuotaRepos {
    return createStorageQuotaRepos(db, { now: () => clock });
  }

  async function identity(tier = "free") {
    const ownerUserId = newId();
    const actorUserId = newId();
    await users.ensure(db, ownerUserId, null);
    await users.ensure(db, actorUserId, null);
    await db.$client`UPDATE users SET tier = ${tier} WHERE uid = ${ownerUserId}`;
    const session = await sessions.create(db, ownerUserId, "storage quota");
    return { ownerUserId, actorUserId, sessionId: session.id };
  }

  it.each([
    ["free", 3],
    ["go", 5],
    ["plus", 15],
    ["pro", 75],
  ] as const)("admits only one concurrent reservation over the %s %i GiB boundary", async (tier, gib) => {
    const { ownerUserId, actorUserId, sessionId } = await identity(tier);
    const declaredBytes = storageBytes(tier) / 2 + 1;
    const service = repos();
    const results = await Promise.all([
      service.reserveUpload({
        actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes,
      }),
      service.reserveUpload({
        actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes,
      }),
    ]);
    expect(results.filter((result) => result.ok)).toHaveLength(1);
    expect(results.find((result) => !result.ok)).toMatchObject({ ok: false, scope: "storage" });
    expect(storageBytes(tier)).toBe(gib * 1024 ** 3);
    expect(await storageUsage(db, ownerUserId)).toEqual({
      usedBytes: 0,
      reservedBytes: declaredBytes,
    });
  });

  it("enforces exactly 50 Free uploads in a rolling 24 hour actor window", async () => {
    clock = NOW;
    const { ownerUserId, actorUserId, sessionId } = await identity("free");
    const service = repos();
    const admitted = await Promise.all(Array.from({ length: 50 }, () => service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes: 1,
    })));
    expect(admitted.every((result) => result.ok)).toBe(true);
    expect(await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes: 1,
    })).toEqual({
      ok: false,
      scope: "upload",
      resetsAt: new Date("2026-10-25T12:00:00.000Z"),
    });
    clock = new Date("2026-10-25T12:00:00.001Z");
    expect((await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes: 1,
    })).ok).toBe(true);
    clock = NOW;
  });

  it("enforces exactly 80 paid uploads in a rolling 3 hour actor window", async () => {
    clock = NOW;
    const { ownerUserId, actorUserId, sessionId } = await identity("go");
    await db.$client`UPDATE users SET tier = 'go' WHERE uid = ${actorUserId}`;
    const service = repos();
    const admitted = await Promise.all(Array.from({ length: 80 }, () => service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes: 1,
    })));
    expect(admitted.every((result) => result.ok)).toBe(true);
    expect(await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes: 1,
    })).toEqual({
      ok: false,
      scope: "upload",
      resetsAt: new Date("2026-10-24T15:00:00.000Z"),
    });
    clock = new Date("2026-10-24T15:00:00.001Z");
    expect((await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes: 1,
    })).ok).toBe(true);
    clock = NOW;
  });

  it("finalizes actual HEAD bytes once and keeps collab actor/host accounting separate", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const service = repos();
    const attachmentId = newId();
    const reserved = await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId, declaredBytes: 99,
    });
    if (!reserved.ok) throw new Error("unexpected quota exhaustion");
    expect(reserved.reservationId).toBe(attachmentId);
    expect(await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId, declaredBytes: 99,
    })).toEqual(reserved);
    await service.finalizeUpload({
      reservationId: reserved.reservationId,
      actualBytes: 11,
      actualContentType: "text/plain",
      etag: "e1",
    });
    await service.finalizeUpload({
      reservationId: reserved.reservationId,
      actualBytes: 11,
      actualContentType: "text/plain",
      etag: "e1",
    });
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 11, reservedBytes: 0 });
    expect(await storageUsage(db, actorUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    expect(await scratch.client`
      SELECT used_uploads, reserved_uploads FROM upload_window_counters
       WHERE actor_user_id = ${actorUserId}`)
      .toEqual([{ used_uploads: 1, reserved_uploads: 0 }]);
    expect(await scratch.client`
      SELECT count(*)::int AS count FROM upload_window_counters
       WHERE actor_user_id = ${ownerUserId}`)
      .toEqual([{ count: 0 }]);
    await expect(service.finalizeUpload({
      reservationId: reserved.reservationId,
      actualBytes: 12,
      actualContentType: "text/plain",
      etag: "e1",
    })).rejects.toMatchObject({ code: "idempotency_conflict" });
  });

  it("releases failed uploads idempotently and restores actor and owner allowance", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const service = repos();
    const attachmentId = newId();
    const reserved = await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId, declaredBytes: 60,
    });
    if (!reserved.ok) throw new Error("unexpected quota exhaustion");
    await service.releaseUpload({ reservationId: reserved.reservationId });
    await service.releaseUpload({ reservationId: reserved.reservationId });
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    await expect(service.finalizeUpload({
      reservationId: reserved.reservationId,
      actualBytes: 60,
      actualContentType: null,
      etag: null,
    })).rejects.toMatchObject({ code: "reservation_released" });
  });

  it("rejects actual bytes over the cap without converting the reservation to usage", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity("free");
    const service = repos();
    const reserved = await service.reserveUpload({
      actorUserId,
      ownerUserId,
      sessionId,
      attachmentId: newId(),
      declaredBytes: storageBytes("free") - 1,
    });
    if (!reserved.ok) throw new Error("unexpected quota exhaustion");
    expect(await service.finalizeUpload({
      reservationId: reserved.reservationId,
      actualBytes: storageBytes("free") + 1,
      actualContentType: null,
      etag: null,
    })).toMatchObject({ ok: false, scope: "storage" });
    expect(await storageUsage(db, ownerUserId)).toEqual({
      usedBytes: 0,
      reservedBytes: storageBytes("free") - 1,
    });
  });

  it("debits deletion only on the first real finalized-to-released transition", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const service = repos();
    const artifactId = newId();
    const reserved = await service.reserveArtifact({
      actorUserId, ownerUserId, sessionId, artifactId, declaredBytes: 4,
    });
    if (!reserved.ok) throw new Error("unexpected quota exhaustion");
    await service.finalizeUpload({
      reservationId: reserved.reservationId,
      actualBytes: 4,
      actualContentType: "application/octet-stream",
      etag: "artifact-etag",
    });
    expect(await service.removeObject({ reservationId: reserved.reservationId }))
      .toEqual({ removed: true, freedBytes: 4 });
    expect(await service.removeObject({ reservationId: reserved.reservationId }))
      .toEqual({ removed: false, freedBytes: 0 });
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    // UNEXECUTED round-1 regression: successful upload history survives delete.
    const next = await service.reserveArtifact({
      actorUserId, ownerUserId, sessionId, artifactId: newId(), declaredBytes: 1,
    });
    expect(next.ok).toBe(true);
    expect(await scratch.client`
      SELECT used_uploads, reserved_uploads FROM upload_window_counters
       WHERE actor_user_id = ${actorUserId}`)
      .toEqual([{ used_uploads: 1, reserved_uploads: 1 }]);
  });

  // UNEXECUTED round-1 regression under the heavy-command pause.
  it("excludes immutable share grants and charges from the actor upload window", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const service = repos();
    const first = await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes: 1,
    });
    if (!first.ok) throw new Error("unexpected quota exhaustion");
    await service.finalizeUpload({
      reservationId: first.reservationId, actualBytes: 1, actualContentType: null, etag: null,
    });
    await service.removeObject({ reservationId: first.reservationId });
    const hash = "a".repeat(64);
    const key = `users/${ownerUserId}/artifact-shares/${newId()}/sha256-${hash}/object`;
    const chargeId = `artifact-share:${newId()}:${hash}`;
    await scratch.client`
      INSERT INTO storage_reservations
        (id, actor_user_id, owner_user_id, session_id, object_id, state,
         declared_bytes, actual_bytes, reserved_at, finalized_at, created_at, updated_at)
      VALUES
        (${chargeId}, ${actorUserId}, ${ownerUserId}, ${sessionId}, ${`charge:${key}`},
         'finalized', 5, 5, ${NOW.toISOString()}::timestamptz, ${NOW.toISOString()}::timestamptz,
         ${NOW.toISOString()}::timestamptz, ${NOW.toISOString()}::timestamptz),
        (${newId()}, ${actorUserId}, ${ownerUserId}, ${sessionId}, ${key},
         'finalized', 0, 0, ${NOW.toISOString()}::timestamptz, ${NOW.toISOString()}::timestamptz,
         ${NOW.toISOString()}::timestamptz, ${NOW.toISOString()}::timestamptz)`;
    const second = await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes: 1,
    });
    expect(second.ok).toBe(true);
    expect(await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes: 1,
    })).toMatchObject({ ok: false, scope: "upload" });
  });

  // UNEXECUTED round-1 regression under the heavy-command pause.
  it("backfills actual ready legacy bytes and sweeps abandoned reservations", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const attachmentId = newId();
    await attachments.create(db, {
      id: attachmentId, userId: ownerUserId, sessionId,
      name: "legacy.txt", size: 99, r2Key: `legacy/${attachmentId}`,
      contentType: "text/plain",
    });
    await db.$client`
      UPDATE attachments SET upload_status = 'ready', actual_bytes = 7,
        actual_content_type = 'text/plain', finalized_at = NOW()
       WHERE id = ${attachmentId}`;
    const artifactId = newId();
    await workspaceObjects.registerArtifact(db, {
      id: artifactId, userId: ownerUserId, sessionId,
      r2Key: `legacy/${artifactId}`, bytes: 5, sha256: "b".repeat(64),
      contentType: "application/octet-stream", meta: { name: "legacy.bin" },
    });
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 12, reservedBytes: 0 });
    // Actual public usage includes one finalized immutable-share copy charge,
    // never a second charge for its independent zero-byte grant.
    const shareHash = "c".repeat(64);
    const shareKey = `users/${ownerUserId}/artifact-shares/${artifactId}/sha256-${shareHash}/object`;
    await scratch.client`
      INSERT INTO storage_reservations
        (id, actor_user_id, owner_user_id, session_id, object_id, state,
         declared_bytes, actual_bytes, reserved_at, finalized_at, created_at, updated_at)
      VALUES
        (${`artifact-share:${artifactId}:${shareHash}`}, ${actorUserId}, ${ownerUserId}, ${sessionId},
         ${`charge:${shareKey}`}, 'finalized', 3, 3,
         ${NOW.toISOString()}::timestamptz, ${NOW.toISOString()}::timestamptz,
         ${NOW.toISOString()}::timestamptz, ${NOW.toISOString()}::timestamptz),
        (${newId()}, ${actorUserId}, ${ownerUserId}, ${sessionId}, ${shareKey},
         'finalized', 0, 0, ${NOW.toISOString()}::timestamptz, ${NOW.toISOString()}::timestamptz,
         ${NOW.toISOString()}::timestamptz, ${NOW.toISOString()}::timestamptz)`;
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 15, reservedBytes: 0 });

    const service = repos();
    const abandoned = await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId: newId(), declaredBytes: 9,
    });
    if (!abandoned.ok) throw new Error("unexpected quota exhaustion");
    clock = new Date("2026-10-24T14:00:00.000Z");
    expect((await sweepAbandonedStorageReservations(db, {
      now: clock, olderThanMs: 3_600_000, ownerUserId,
    })).map((row) => row.reservationId)).toEqual([abandoned.reservationId]);
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 15, reservedBytes: 0 });
    clock = NOW;
  });

  // UNEXECUTED R4-2: legacy status and reservation share one transaction.
  it("fails reservationless pending/missing-HEAD rows instead of treating not-found as clean", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const attachmentId = newId();
    await attachments.create(db, {
      id: attachmentId,
      userId: ownerUserId,
      sessionId,
      name: "legacy-missing.txt",
      size: 9,
      r2Key: `legacy/${attachmentId}`,
    });
    await expect(repos().reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId,
      declaredBytes: 9, head: null,
    })).resolves.toEqual({
      ok: false, scope: "attachment", code: "attachment_failed", resetsAt: null,
    });
    expect((await attachments.getForSession(db, sessionId, [attachmentId]))[0])
      .toMatchObject({ uploadStatus: "failed", actualBytes: null, finalizedAt: null });
    expect(await scratch.client`
      SELECT state, declared_bytes::int AS declared FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([{ state: "released", declared: 0 }]);
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  it("preserves verified pre-0038 ready actual facts without fabricating bytes", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const attachmentId = newId();
    await attachments.create(db, {
      id: attachmentId,
      userId: ownerUserId,
      sessionId,
      name: "legacy-ready.txt",
      size: 11,
      r2Key: `legacy/${attachmentId}`,
      contentType: "text/plain",
    });
    const finalizedAt = "2020-01-02T03:04:05.000Z";
    await db.$client`
      UPDATE attachments SET upload_status = 'ready', actual_bytes = 11,
        actual_content_type = 'text/plain', finalized_at = ${finalizedAt}::timestamptz
       WHERE id = ${attachmentId}`;
    expect(await repos().reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId,
      declaredBytes: 11,
      head: { bytes: 11, contentType: "text/plain", etag: "legacy-etag" },
    })).toEqual({ ok: true, reservationId: attachmentId });
    expect(await scratch.client`
      SELECT state, declared_bytes::int AS declared, actual_bytes::int AS actual,
             actual_content_type, etag, finalized_at
        FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([{
        state: "finalized",
        declared: 11,
        actual: 11,
        actual_content_type: "text/plain",
        etag: "legacy-etag",
        finalized_at: new Date(finalizedAt),
      }]);
    expect((await attachments.getForSession(db, sessionId, [attachmentId]))[0])
      .toMatchObject({ uploadStatus: "ready", actualBytes: 11, actualContentType: "text/plain" });
    expect(await scratch.client`
      SELECT used_uploads, reserved_uploads FROM upload_window_counters
       WHERE actor_user_id = ${actorUserId}`)
      .toEqual([{ used_uploads: 1, reserved_uploads: 0 }]);
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 11, reservedBytes: 0 });
  });

  it("fails a reservationless ready row when HEAD cannot verify its actual evidence", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const attachmentId = newId();
    await attachments.create(db, {
      id: attachmentId,
      userId: ownerUserId,
      sessionId,
      name: "legacy-unverified.txt",
      size: 11,
      r2Key: `legacy/${attachmentId}`,
      contentType: "text/plain",
    });
    await db.$client`
      UPDATE attachments SET upload_status = 'ready', actual_bytes = 11,
        actual_content_type = 'text/plain', finalized_at = NOW()
       WHERE id = ${attachmentId}`;
    await expect(repos().reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId,
      declaredBytes: 11,
      head: { bytes: 11, contentType: "application/octet-stream", etag: "unverifiable-ready" },
    })).resolves.toEqual({
      ok: false, scope: "attachment", code: "attachment_failed", resetsAt: null,
    });
    expect((await attachments.getForSession(db, sessionId, [attachmentId]))[0])
      .toMatchObject({ uploadStatus: "failed", actualBytes: null, finalizedAt: null });
    expect(await scratch.client`
      SELECT state, declared_bytes::int AS declared FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([{ state: "released", declared: 0 }]);
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  // UNEXECUTED R5-2: failed+finalized stale HEAD is terminal before charging.
  it("refuses failed row plus finalized reservation without charging or ready resurrection", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const service = repos();
    const attachmentId = newId();
    await attachments.create(db, {
      id: attachmentId,
      userId: ownerUserId,
      sessionId,
      name: "failed-finalized.txt",
      size: 4,
      r2Key: `legacy/${attachmentId}`,
    });
    const reserved = await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId, declaredBytes: 4,
    });
    if (!reserved.ok) throw new Error("unexpected quota exhaustion");
    await service.finalizeUpload({
      reservationId: attachmentId,
      actualBytes: 4,
      actualContentType: null,
      etag: "stale-head",
      attachment: true,
    });
    await db.$client`
      UPDATE attachments SET upload_status = 'failed', actual_bytes = NULL,
        actual_content_type = NULL, finalized_at = NULL WHERE id = ${attachmentId}`;
    await expect(service.finalizeUpload({
      reservationId: attachmentId,
      actualBytes: 4,
      actualContentType: null,
      etag: "stale-head",
      attachment: true,
    })).rejects.toMatchObject({ code: "attachment_failed" });
    // The finalized reservation remains present here: canonical ready must
    // independently refuse failed → ready even with otherwise valid proof.
    await expect(attachments.finalizeUpload(db, {
      id: attachmentId,
      sessionId,
      userId: ownerUserId,
      actualBytes: 4,
      actualContentType: null,
    })).rejects.toMatchObject({ code: "attachment_failed" });
    expect(await service.removeObject({ reservationId: attachmentId }))
      .toEqual({ removed: true, freedBytes: 4 });
    expect((await attachments.getForSession(db, sessionId, [attachmentId]))[0]?.uploadStatus)
      .toBe("failed");
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  // UNEXECUTED R5-2: missing attachment must not be charged during finalize.
  it("refuses vanished-row finalize without stranding a charge", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const service = repos();
    const attachmentId = newId();
    await attachments.create(db, {
      id: attachmentId,
      userId: ownerUserId,
      sessionId,
      name: "vanished-finalize.txt",
      size: 4,
      r2Key: `legacy/${attachmentId}`,
    });
    const reserved = await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId, declaredBytes: 4,
    });
    if (!reserved.ok) throw new Error("unexpected quota exhaustion");
    await db.$client`DELETE FROM attachments WHERE id = ${attachmentId}`;
    await expect(service.finalizeUpload({
      reservationId: attachmentId,
      actualBytes: 4,
      actualContentType: null,
      etag: null,
      attachment: true,
    })).rejects.toMatchObject({ code: "attachment_not_found" });
    expect(await service.releaseUpload({ reservationId: attachmentId })).resolves.toBeUndefined();
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  // UNEXECUTED R5-2: release holds users + attachment before finalize starts.
  // The real lock fence must then refuse finalize without reaching ready.
  it("serializes concurrent finalize and release without deadlock or ready resurrection", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const attachmentId = newId();
    let signalReleaseAttachmentLocked!: () => void;
    const releaseAttachmentLocked = new Promise<void>((resolve) => {
      signalReleaseAttachmentLocked = resolve;
    });
    let signalFinalizeStarted!: () => void;
    const finalizeStarted = new Promise<void>((resolve) => {
      signalFinalizeStarted = resolve;
    });
    const service = createStorageQuotaRepos(db, {
      now: () => clock,
      afterAttachmentLock: async (operation, reservationId) => {
        if (operation !== "release" || reservationId !== attachmentId) return;
        signalReleaseAttachmentLocked();
        await finalizeStarted;
      },
    });
    await attachments.create(db, {
      id: attachmentId,
      userId: ownerUserId,
      sessionId,
      name: "lock-order.txt",
      size: 4,
      r2Key: `legacy/${attachmentId}`,
    });
    const reserved = await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId, declaredBytes: 4,
    });
    if (!reserved.ok) throw new Error("unexpected quota exhaustion");

    const order: string[] = [];
    let canonicalReadyCalls = 0;
    let observedRelease: Promise<PromiseSettledResult<void>[]> | undefined;
    let observedFinalize: Promise<PromiseSettledResult<unknown>[]> | undefined;
    try {
      const release = service.releaseUpload({ reservationId: attachmentId }).then(() => {
        order.push("release_committed");
      });
      const releaseSettled = Promise.allSettled([release]);
      observedRelease = releaseSettled;

      // If the hook is absent or release fails before reaching it, fail rather
      // than waiting forever on the barrier. The real release must be paused.
      const releaseSettledBeforeBarrier = await Promise.race([
        releaseAttachmentLocked.then(() => false),
        releaseSettled.then(() => true),
      ]);
      if (releaseSettledBeforeBarrier) {
        throw new Error("release settled before the controlled attachment-lock barrier");
      }

      const finalize = service.finalizeUpload({
        reservationId: attachmentId,
        actualBytes: 4,
        actualContentType: null,
        etag: null,
        attachment: true,
      }).then(
        (result) => {
          order.push("finalize_succeeded");
          return result;
        },
        (error: unknown) => {
          order.push("finalize_rejected");
          throw error;
        },
      );
      const ready = finalize.then(() => {
        canonicalReadyCalls += 1;
        return attachments.finalizeUpload(db, {
          id: attachmentId,
          sessionId,
          userId: ownerUserId,
          actualBytes: 4,
          actualContentType: null,
        });
      });
      const finalizeSettled = Promise.allSettled([finalize, ready]);
      observedFinalize = finalizeSettled;

      signalFinalizeStarted();
      const [releaseOutcome] = await releaseSettled;
      expect(releaseOutcome?.status).toBe("fulfilled");
      const [finalizeOutcome, readyOutcome] = await finalizeSettled;
      expect(finalizeOutcome).toMatchObject({
        status: "rejected",
        reason: { code: "attachment_failed" },
      });
      expect(readyOutcome).toMatchObject({
        status: "rejected",
        reason: { code: "attachment_failed" },
      });
      expect(order).toEqual(["release_committed", "finalize_rejected"]);
      expect(canonicalReadyCalls).toBe(0);
    } finally {
      // Also releases cleanup's hook if an assertion fails before the normal
      // signal. Observed promises are all-settled, so cleanup cannot rethrow.
      signalFinalizeStarted();
      if (observedRelease !== undefined) await observedRelease;
      if (observedFinalize !== undefined) await observedFinalize;
    }

    await cleanupStorageObjectRace({
      removeObject: () => service.removeObject({ reservationId: attachmentId }),
      releaseUpload: () => service.releaseUpload({ reservationId: attachmentId }),
      deleteObject: async () => {},
      deleteRow: async () => {
        await db.$client`DELETE FROM attachments WHERE id = ${attachmentId}`;
      },
    });
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([{ state: "released" }]);
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    expect(await attachments.getForSession(db, sessionId, [attachmentId])).toEqual([]);
  });

  // UNEXECUTED R5-3: reserved→finalized cleanup retries debit, never double-charges.
  it("bounded cleanup handles reserved-to-finalized transition exactly once", async () => {
    const { ownerUserId, actorUserId, sessionId } = await identity();
    const service = repos();
    const attachmentId = newId();
    await attachments.create(db, {
      id: attachmentId,
      userId: ownerUserId,
      sessionId,
      name: "cleanup-race.txt",
      size: 7,
      r2Key: `legacy/${attachmentId}`,
    });
    const reserved = await service.reserveUpload({
      actorUserId, ownerUserId, sessionId, attachmentId, declaredBytes: 7,
    });
    if (!reserved.ok) throw new Error("unexpected quota exhaustion");
    const originalRemove = service.removeObject;
    let removeCalls = 0;
    let releaseCalls = 0;
    const removed: string[] = [];
    const result = await cleanupStorageObjectRace({
      removeObject: async () => {
        removeCalls += 1;
        if (removeCalls === 1) {
          let observed: unknown;
          try {
            await originalRemove({ reservationId: attachmentId });
          } catch (error) {
            observed = error;
          }
          expect(observed).toMatchObject({ code: "invalid_reservation_state" });
          // Controlled race: the real remove observed reserved, then a real
          // finalizer commits before cleanup attempts its real release.
          await service.finalizeUpload({
            reservationId: attachmentId,
            actualBytes: 7,
            actualContentType: null,
            etag: null,
            attachment: true,
          });
          throw observed;
        }
        return originalRemove({ reservationId: attachmentId });
      },
      releaseUpload: async () => {
        releaseCalls += 1;
        await service.releaseUpload({ reservationId: attachmentId });
      },
      deleteObject: async () => { removed.push("object"); },
      deleteRow: async () => {
        removed.push("row");
        await db.$client`DELETE FROM attachments WHERE id = ${attachmentId}`;
      },
      maxAttempts: 3,
    });
    expect(result.state).toBe("released");
    expect(result.freedBytes).toBe(7);
    expect(removeCalls).toBe(2);
    expect(releaseCalls).toBe(1);
    expect(removed).toEqual(["object", "row"]);
    expect(await attachments.getForSession(db, sessionId, [attachmentId])).toEqual([]);
    expect(await storageUsage(db, ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });
});
