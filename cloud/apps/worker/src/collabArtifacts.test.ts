/**
 * UNEXECUTED review follow-up suite through round 4 under HEAVY-COMMANDS-PAUSED.md.
 * Real Postgres + real fs adapter only; no R2 or production service is used.
 * Package-boundary regression: shared recovery APIs must import from @ovid/db,
 * never from another application's rootDir/src tree.
 */
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { sql } from "drizzle-orm";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  CollabRepos,
  accountDeletions,
  artifactVault,
  createDb,
  migrate,
  newId,
  schema,
  sessions,
  StorageReservationStore,
  users,
  withUidLock,
  workspaceObjects,
  type Db,
} from "@ovid/db";
import { createFsStorage, type HeadResult, type StorageAdapter } from "@ovid/storage";
import { createMigrationScratch, type MigrationScratch } from "../../../packages/db/src/migrationTestKit.js";
import {
  CollabArtifactDeadline,
  classifyCollabArtifactAttemptHead,
  cleanupCollabArtifactAttemptWithShortFences,
  collabArtifactAttemptKey,
  collabArtifactAttemptMayDelete,
  collabOrphanSweepBudget,
  CollabOrphanSweepScheduler,
  listCollabArtifactAttemptOrphanCandidates,
  readCollabArtifactAttemptCleanupFence,
  reconcileCollabArtifactAttemptOrphans,
  releaseCollabArtifactReservedAttempts,
} from "@ovid/db";
import {
  CollabArtifactError,
  CollabArtifactRegistrar,
  collabArtifactErrorResponse,
  createCollabArtifactAuthorizationPort,
  type CollabArtifactAuthorizationPort,
  type CollabArtifactIdentity,
  type CollabArtifactRegisterInput,
  type CollabArtifactRegistrarDeps,
  type CollabArtifactReservationPort,
  type CollabArtifactWorkspaceObjectsPort,
} from "./collabArtifacts.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const AUTHORITY_SECRET = "collab-artifact-registrar-test-authority-secret-32";
const sha256 = (content: Buffer): string => createHash("sha256").update(content).digest("hex");

function deferred() {
  let resolve!: () => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<void>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

interface HarnessOptions {
  db?: Db;
  authorization?: CollabArtifactAuthorizationPort;
  reservationStore?(db: Db): CollabArtifactReservationPort;
  workspaceObjects?: CollabArtifactWorkspaceObjectsPort;
  workspaceDir?(ownerUserId: string, sessionId: string): Promise<string>;
  put?: StorageAdapter["put"];
  head?: StorageAdapter["head"];
  get?: StorageAdapter["get"];
  delete?: StorageAdapter["delete"];
  cancelBackend?(backendPid: number): Promise<unknown>;
  timeouts?: Partial<Pick<CollabArtifactRegistrarDeps,
    "operationDeadlineMs" | "dbLockTimeoutMs" | "dbStatementTimeoutMs" | "pendingWaitMs" | "storageDeadlineMs" | "cleanupDeadlineMs">>;
}

describe("CollabArtifactRegistrar response mapping — UNEXECUTED", () => {
  it("maps public statuses, conflicts, retry timing and quota classes", () => {
    const now = new Date("2026-10-25T00:00:00.000Z");
    expect(collabArtifactErrorResponse(new CollabArtifactError("invalid_request"), now))
      .toEqual({ status: 400, code: "invalid_request", retryable: false, retryAfterSeconds: null });
    expect(collabArtifactErrorResponse(new CollabArtifactError("source_outside_workspace"), now).status).toBe(400);
    expect(collabArtifactErrorResponse(new CollabArtifactError("not_member"), now))
      .toEqual({ status: 403, code: "not_member", retryable: false, retryAfterSeconds: null });
    expect(collabArtifactErrorResponse(new CollabArtifactError("idempotency_conflict"), now))
      .toEqual({ status: 409, code: "request_already_used", retryable: false, retryAfterSeconds: null });
    expect(collabArtifactErrorResponse(new CollabArtifactError("artifact_deleted"), now).status).toBe(410);
    expect(collabArtifactErrorResponse(new CollabArtifactError("artifact_changed"), now))
      .toMatchObject({ status: 409, code: "artifact_changed", retryable: false });
    expect(collabArtifactErrorResponse(new CollabArtifactError("storage_quota_exceeded"), now))
      .toMatchObject({ status: 409, retryable: false });
    expect(collabArtifactErrorResponse(new CollabArtifactError("project_file_limit"), now))
      .toMatchObject({ status: 409, code: "project_file_limit", retryable: false });
    expect(collabArtifactErrorResponse(
      new CollabArtifactError("upload_limit_reached", new Date("2026-10-25T00:00:10.250Z"), true),
      now,
    )).toEqual({ status: 429, code: "upload_limit_reached", retryable: true, retryAfterSeconds: 11 });
    expect(collabArtifactErrorResponse(new CollabArtifactError("storage_timeout"), now))
      .toEqual({ status: 503, code: "temporarily_unavailable", retryable: true, retryAfterSeconds: 1 });
    expect(collabArtifactErrorResponse(new CollabArtifactError("db_timeout"), now))
      .toEqual({ status: 503, code: "temporarily_unavailable", retryable: true, retryAfterSeconds: 1 });
    expect(collabArtifactErrorResponse(new CollabArtifactError("cancelled"), now))
      .toEqual({ status: 499, code: "cancelled", retryable: false, retryAfterSeconds: null });
  });

  it("maps raw infrastructure failures without exposing their text", () => {
    const response = collabArtifactErrorResponse(new Error("secret adapter payload"));
    expect(response).toEqual({
      status: 503,
      code: "temporarily_unavailable",
      retryable: true,
      retryAfterSeconds: 1,
    });
    expect(JSON.stringify(response)).not.toContain("secret adapter payload");
    expect(collabArtifactErrorResponse(Object.assign(new Error("locked"), { code: "55P03" })))
      .toMatchObject({ status: 503, code: "temporarily_unavailable", retryable: true });
  });
});

describe("Collab orphan sweep fairness and delayed rescan — UNEXECUTED", () => {
  it("reserves ordinary work at the exact production limit and alternates limit-one passes", () => {
    const scheduler = new CollabOrphanSweepScheduler({ rescanDelayMs: 30_000, now: () => 0 });
    const plan = scheduler.nextPlan(50);
    // Exactly 50 permanent foreign attempts can consume only half the pass;
    // failed attachments/deleted artifacts retain the other half every pass.
    expect(plan).toMatchObject({ ordinary: 25, attempts: 25, forceHead: true });
    expect(collabOrphanSweepBudget(50, 1)).toEqual({ ordinary: 25, attempts: 25 });
    expect(collabOrphanSweepBudget(1, 0)).toEqual({ ordinary: 1, attempts: 0 });
    expect(collabOrphanSweepBudget(1, 1)).toEqual({ ordinary: 0, attempts: 1 });
  });

  it("preserves bidirectional limit-one fairness under persistent ordinary and attempt backlogs", () => {
    const scheduler = new CollabOrphanSweepScheduler({ rescanDelayMs: 1_000, now: () => 0 });
    const cursor = {
      createdAt: new Date(0),
      attemptReservationId: `${newId()}:collab-attempt:1`,
    };
    const plans: ReturnType<CollabOrphanSweepScheduler["nextPlan"]>[] = [];
    for (let pass = 0; pass < 4; pass += 1) {
      const plan = scheduler.nextPlan(1);
      plans.push(plan);
      // Every pass may contain permanent work. Attempt continuation is still
      // retained when an attempt-budgeted pass completes with more work pending.
      scheduler.complete(plan, cursor);
    }
    expect(plans.map((plan) => ({ ordinary: plan.ordinary, attempts: plan.attempts }))).toEqual([
      { ordinary: 1, attempts: 0 },
      { ordinary: 0, attempts: 1 },
      { ordinary: 1, attempts: 0 },
      { ordinary: 0, attempts: 1 },
    ]);
    const nextAttemptPass = scheduler.nextPlan(1);
    expect(nextAttemptPass).toMatchObject({ ordinary: 1, attempts: 0 });
    const followingAttemptPass = scheduler.nextPlan(1);
    expect(followingAttemptPass).toMatchObject({ ordinary: 0, attempts: 1 });
    expect(followingAttemptPass.attemptCursor).toEqual(cursor);
  });

  it("forces a delayed head rescan even while resumed pages remain full of new attempts", () => {
    let now = 0;
    const scheduler = new CollabOrphanSweepScheduler({ rescanDelayMs: 30, now: () => now });
    const first = scheduler.nextPlan(50);
    const cursor = {
      createdAt: new Date(0),
      attemptReservationId: `${newId()}:collab-attempt:50`,
    };
    scheduler.complete(first, cursor);
    now = 1;
    const resumed = scheduler.nextPlan(50);
    expect(resumed.forceHead).toBe(false);
    expect(resumed.attemptCursor).toEqual(cursor);
    scheduler.complete(resumed, {
      createdAt: new Date(1),
      attemptReservationId: `${newId()}:collab-attempt:51`,
    });
    now = 31;
    const delayed = scheduler.nextPlan(50);
    expect(delayed.forceHead).toBe(true);
    expect(delayed.attemptCursor).toBeUndefined();
    expect(delayed.ordinary).toBeGreaterThan(0);
    expect(delayed.attempts).toBeGreaterThan(0);
  });

  it("repeated head rescans preserve later-page continuation progress", () => {
    let now = 0;
    const scheduler = new CollabOrphanSweepScheduler({ rescanDelayMs: 30, now: () => now });
    const cursor = (attempt: number) => ({
      createdAt: new Date(attempt),
      attemptReservationId: `${newId()}:collab-attempt:${attempt}`,
    });
    const first = scheduler.nextPlan(50);
    scheduler.complete(first, cursor(1));
    now = 1;
    const forward = scheduler.nextPlan(50);
    expect(forward.forceHead).toBe(false);
    scheduler.complete(forward, cursor(2));

    now = 31;
    const rescue = scheduler.nextPlan(50);
    expect(rescue.forceHead).toBe(true);
    expect(rescue.attemptCursor).toBeUndefined();
    scheduler.complete(rescue, cursor(1));
    now = 32;
    const continued = scheduler.nextPlan(50);
    expect(continued.forceHead).toBe(false);
    expect(continued.attemptCursor).toEqual(cursor(2));
    scheduler.complete(continued, cursor(3));

    now = 62;
    const secondRescue = scheduler.nextPlan(50);
    expect(secondRescue.forceHead).toBe(true);
    scheduler.complete(secondRescue, cursor(1));
    now = 63;
    const afterSecond = scheduler.nextPlan(50);
    expect(afterSecond.attemptCursor).toEqual(cursor(3));
  });
});

describe.skipIf(!TEST_DATABASE_URL).sequential("CollabArtifactRegistrar review follow-ups — UNEXECUTED real Postgres/fs", () => {
  let scratch: MigrationScratch;
  let db: Db;
  const temporaryRoots: string[] = [];

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "collab_artifact_registrar_fix1");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 12 });
  }, 120_000);

  afterEach(async () => {
    while (temporaryRoots.length > 0) {
      await rm(temporaryRoots.pop()!, { recursive: true, force: true });
    }
  });

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  async function makeHarness(options: HarnessOptions = {}) {
    const workspaceRoot = await mkdtemp(join(tmpdir(), "ovid-collab-artifact-workspace-"));
    const storageRoot = await mkdtemp(join(tmpdir(), "ovid-collab-artifact-storage-"));
    temporaryRoots.push(workspaceRoot, storageRoot);
    const base = createFsStorage(storageRoot);
    const calls = { put: 0, head: 0, get: 0, delete: 0, authorize: 0, workspaceDir: 0 };
    const storage: Pick<StorageAdapter, "put" | "head" | "get" | "delete"> = {
      async put(key, body, putOptions) {
        calls.put += 1;
        return options.put !== undefined ? options.put(key, body, putOptions) : base.put(key, body, putOptions);
      },
      async head(key): Promise<HeadResult | null> {
        calls.head += 1;
        return options.head !== undefined ? options.head(key) : base.head(key);
      },
      async get(key) {
        calls.get += 1;
        return options.get !== undefined ? options.get(key) : base.get(key);
      },
      async delete(key) {
        calls.delete += 1;
        return options.delete !== undefined ? options.delete(key) : base.delete(key);
      },
    };
    const productionAuthorization = createCollabArtifactAuthorizationPort();
    const authorization: CollabArtifactAuthorizationPort = options.authorization ?? {
      async authorize(input, tx) {
        calls.authorize += 1;
        return productionAuthorization.authorize(input, tx);
      },
    };
    const deps: CollabArtifactRegistrarDeps = {
      db: options.db ?? db,
      storage,
      authorization,
      workspaceDir: async (ownerUserId, sessionId) => {
        calls.workspaceDir += 1;
        return options.workspaceDir !== undefined
          ? options.workspaceDir(ownerUserId, sessionId)
          : workspaceRoot;
      },
      ...(options.workspaceObjects !== undefined ? { workspaceObjects: options.workspaceObjects } : {}),
      ...(options.reservationStore !== undefined ? { reservationStore: options.reservationStore } : {}),
      ...(options.cancelBackend !== undefined ? { cancelBackend: options.cancelBackend } : {}),
      operationDeadlineMs: 5_000,
      dbLockTimeoutMs: 100,
      dbStatementTimeoutMs: 2_000,
      pendingWaitMs: 25,
      storageDeadlineMs: 3_000,
      cleanupDeadlineMs: 500,
      ...options.timeouts,
    };
    const registrar = new CollabArtifactRegistrar(deps);
    return { registrar, deps, storage, base, calls, workspaceRoot, storageRoot };
  }

  async function identities(actorIsOwner = false) {
    const ownerUserId = newId();
    const actorUserId = actorIsOwner ? ownerUserId : newId();
    await users.ensure(db, ownerUserId, null);
    const sessionId = (await sessions.create(db, ownerUserId, "collab artifact fix1")).id;
    const repos = new CollabRepos(db, { authoritySecret: AUTHORITY_SECRET });
    const room = await repos.createRoom({
      uid: ownerUserId,
      requestId: `create-${newId()}`,
      sessionId,
    });
    let participantId = room.member.participantId;
    if (actorUserId !== ownerUserId) {
      const invite = await repos.createInvite({
        uid: ownerUserId,
        token: room.sessionToken,
        idempotencyKey: `invite-${newId()}`,
        maxUses: 1,
        ttlSeconds: 600,
      });
      const joined = await repos.join({
        uid: actorUserId,
        token: room.sessionToken,
        inviteCode: invite.inviteCode,
        idempotencyKey: `join-${newId()}`,
      });
      participantId = joined.member.participantId;
    }
    return {
      identity: { actorUserId, ownerUserId, sessionId },
      actorUserId,
      ownerUserId,
      sessionId,
      repos,
      room,
      participantId,
    };
  }

  async function requestAccountDeletion(uid: string): Promise<void> {
    // Use the exact production UID lock/upsert seam, not merely a pre-seeded
    // account_deletions row. This covers the initially-absent-row race.
    await withUidLock(db, uid, async (locked) => {
      await accountDeletions.save(locked, {
        uid,
        state: "pending",
        deleteAfter: Date.now() / 1000 + 3600,
        record: { request_id: `delete-${newId()}` },
      });
    });
  }

  function inputFor(
    identity: CollabArtifactIdentity,
    overrides: Partial<CollabArtifactRegisterInput> = {},
  ): CollabArtifactRegisterInput {
    return {
      ...identity,
      name: "result.txt",
      contentType: "text/plain",
      content: Buffer.from("actual host bytes"),
      idempotencyKey: `artifact-${newId()}`,
      ...overrides,
    };
  }

  async function usage(userId: string) {
    const rows = await db.$client<{ used_bytes: number | string; reserved_bytes: number | string }[]>`
      SELECT used_bytes, reserved_bytes FROM storage_usage_counters WHERE owner_user_id = ${userId}`;
    return {
      usedBytes: Number(rows[0]?.used_bytes ?? 0),
      reservedBytes: Number(rows[0]?.reserved_bytes ?? 0),
    };
  }

  async function rowsFor(sessionId: string) {
    return db.$client<Array<Record<string, unknown>>>`
      SELECT * FROM workspace_objects WHERE session_id = ${sessionId}`;
  }

  async function activeCount(sessionId: string): Promise<number> {
    const rows = await rowsFor(sessionId);
    return rows.filter((row) => row.status === "active").length;
  }

  async function reservation(artifactId: string) {
    const rows = await db.$client<Array<Record<string, unknown>>>`
      SELECT * FROM storage_reservations WHERE id = ${artifactId}`;
    return rows[0];
  }

  async function attemptReservations(artifactId: string, ownerUserId: string, sessionId: string) {
    return db.$client<Array<Record<string, unknown>>>`
      SELECT * FROM storage_reservations
       WHERE id LIKE ${`${artifactId}:collab-attempt:%`}
         AND owner_user_id = ${ownerUserId}
         AND session_id = ${sessionId}
       ORDER BY id`;
  }

  async function insertAttemptHistory(input: {
    fixture: Awaited<ReturnType<typeof identities>>;
    artifactId: string;
    attempt: number;
    state: "reserved" | "released";
    objectId: string | null;
    declaredBytes?: number;
  }) {
    const declaredBytes = input.declaredBytes ?? 0;
    await db.insert(schema.storageReservations).values({
      id: `${input.artifactId}:collab-attempt:${input.attempt}`,
      actorUserId: input.fixture.actorUserId,
      ownerUserId: input.fixture.ownerUserId,
      sessionId: input.fixture.sessionId,
      objectId: input.objectId,
      state: input.state,
      declaredBytes,
      releasedAt: input.state === "released" ? new Date() : null,
    });
    if (input.state === "reserved" && declaredBytes > 0) {
      // Direct history fixtures must model the counter delta that the real
      // reserve API would have committed; otherwise release tests go negative.
      await db.insert(schema.storageUsageCounters).values({
        ownerUserId: input.fixture.ownerUserId,
        reservedBytes: declaredBytes,
      }).onConflictDoUpdate({
        target: schema.storageUsageCounters.ownerUserId,
        set: { reservedBytes: sql`${schema.storageUsageCounters.reservedBytes} + ${declaredBytes}` },
      });
    }
  }

  async function reservationsForSession(sessionId: string) {
    return db.$client<Array<Record<string, unknown>>>`
      SELECT * FROM storage_reservations WHERE session_id = ${sessionId} ORDER BY id`;
  }

  it("creates a host-owned active row/object, separates sender, and replays without another PUT or charge", async () => {
    const fixture = await identities();
    const harness = await makeHarness();
    const input = inputFor(fixture.identity, { idempotencyKey: "same-artifact-request" });
    const content = input.content!;

    const first = await harness.registrar.register(input);
    const replay = await harness.registrar.register(input);

    expect(replay).toEqual(first);
    expect(harness.calls.put).toBe(1);
    expect(harness.calls.get).toBeGreaterThanOrEqual(2);
    expect(first.key).toContain(`${first.id}-attempt-1-${sha256(content).slice(0, 16)}-result.txt`);
    expect(first.key.startsWith(`users/${fixture.ownerUserId}/artifacts/${fixture.sessionId}/`)).toBe(true);
    expect((await readFile(join(harness.storageRoot, first.key))).equals(content)).toBe(true);
    const row = await workspaceObjects.getArtifact(db, first.id, fixture.ownerUserId);
    expect(row).toMatchObject({
      id: first.id,
      userId: fixture.ownerUserId,
      sessionId: fixture.sessionId,
      kind: "artifact",
      status: "active",
      r2Key: first.key,
      bytes: content.length,
      sha256: sha256(content),
      contentType: "text/plain",
      meta: {
        name: "result.txt",
        creatorUserId: fixture.actorUserId,
        idempotencyKey: "same-artifact-request",
        attempt: 1,
        attemptReservationId: `${first.id}:collab-attempt:1`,
      },
    });
    expect(await workspaceObjects.getArtifact(db, first.id, fixture.actorUserId)).toBeNull();
    expect(await activeCount(fixture.sessionId)).toBe(1);
    expect(await reservation(first.id)).toMatchObject({
      actor_user_id: fixture.actorUserId,
      owner_user_id: fixture.ownerUserId,
      session_id: fixture.sessionId,
      object_id: first.id,
      state: "finalized",
      declared_bytes: content.length,
      actual_bytes: content.length,
      actual_content_type: "text/plain",
    });
    expect(await attemptReservations(first.id, fixture.ownerUserId, fixture.sessionId)).toHaveLength(1);
    expect((await attemptReservations(first.id, fixture.ownerUserId, fixture.sessionId))[0]).toMatchObject({
      state: "released",
      object_id: first.key,
    });
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: content.length, reservedBytes: 0 });
    expect(await usage(fixture.actorUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  it("converges concurrent identical calls to one PUT, active row, public reservation and charge", async () => {
    const fixture = await identities();
    const harness = await makeHarness({ timeouts: { pendingWaitMs: 10_000, storageDeadlineMs: 20_000 } });
    const input = inputFor(fixture.identity, { idempotencyKey: "concurrent-replay" });

    const records = await Promise.all(Array.from({ length: 8 }, () => harness.registrar.register(input)));

    expect(new Set(records.map((record) => record.id)).size).toBe(1);
    expect(new Set(records.map((record) => record.key)).size).toBe(1);
    expect(harness.calls.put).toBe(1);
    expect(await activeCount(fixture.sessionId)).toBe(1);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: input.content!.length, reservedBytes: 0 });
  });

  it("rejects changed content for a completed idempotency identity before another write", async () => {
    const fixture = await identities();
    const harness = await makeHarness();
    const input = inputFor(fixture.identity, { idempotencyKey: "payload-is-bound" });
    const first = await harness.registrar.register(input);

    await expect(harness.registrar.register({ ...input, content: Buffer.from("changed host bytes") }))
      .rejects.toMatchObject({ code: "idempotency_conflict" });
    expect(harness.calls.put).toBe(1);
    expect(await activeCount(fixture.sessionId)).toBe(1);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: first.sizeBytes, reservedBytes: 0 });
  });

  it("requires exactly one content source before any intent or object write", async () => {
    const fixture = await identities();
    const harness = await makeHarness();
    const base = inputFor(fixture.identity);

    await expect(harness.registrar.register({ ...base, content: undefined, sourcePath: undefined }))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(harness.registrar.register({ ...base, sourcePath: "also-present.txt" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    expect(harness.calls.put).toBe(0);
    expect(await rowsFor(fixture.sessionId)).toEqual([]);
    expect(await reservationsForSession(fixture.sessionId)).toEqual([]);
  });

  it("large released-attempt history uses bounded discovery and preserves the next generation", async () => {
    const fixture = await identities();
    let failFirstPut = true;
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      put: async (key, body, options) => {
        if (failFirstPut) {
          failFirstPut = false;
          throw new Error("leave pending intent for history test");
        }
        return createFsStorage(harness.storageRoot).put(key, body, options);
      },
      timeouts: { pendingWaitMs: 0 },
    });
    const input = inputFor(fixture.identity, { idempotencyKey: "large-attempt-history" });
    await expect(harness.registrar.register(input)).rejects.toMatchObject({ code: "temporarily_unavailable" });
    const rows = await rowsFor(fixture.sessionId);
    const artifactId = rows[0]!.id as string;
    const baseKey = rows[0]!.r2_key as string;
    const values = Array.from({ length: 69 }, (_, index) => {
      const attempt = index + 2;
      return {
        id: `${artifactId}:collab-attempt:${attempt}`,
        actorUserId: fixture.actorUserId,
        ownerUserId: fixture.ownerUserId,
        sessionId: fixture.sessionId,
        objectId: `${baseKey}-history-${attempt}`,
        state: "released" as const,
        declaredBytes: 0,
        releasedAt: new Date(),
      };
    });
    await db.insert(schema.storageReservations).values(values);
    const recovered = await harness.registrar.register(input);
    const active = await workspaceObjects.getArtifact(db, recovered.id, fixture.ownerUserId);
    expect(active).toMatchObject({ status: "active", meta: { attempt: 71 } });
    expect(recovered.key).toContain("-attempt-71-");
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: input.content!.length, reservedBytes: 0 });
  });

  it("quarantines malformed artifact-prefixed discovery rows without aborting bounded cursor progress", async () => {
    const fixture = await identities();
    const harness = await makeHarness({
      put: async () => { throw new Error("leave released discovery fixture"); },
      timeouts: { pendingWaitMs: 0 },
    });
    await expect(harness.registrar.register(inputFor(fixture.identity, {
      idempotencyKey: "malformed-prefix-discovery",
    }))).rejects.toMatchObject({ code: "temporarily_unavailable" });
    const rows = await rowsFor(fixture.sessionId);
    const artifactId = rows[0]!.id as string;
    await insertAttemptHistory({
      fixture,
      artifactId,
      attempt: 2,
      state: "released",
      objectId: `users/${fixture.ownerUserId}/artifacts/${fixture.sessionId}/../poison`,
      declaredBytes: 0,
    });
    await insertAttemptHistory({
      fixture,
      artifactId,
      attempt: 3,
      state: "released",
      objectId: collabArtifactAttemptKey({
        ownerUserId: fixture.ownerUserId,
        sessionId: fixture.sessionId,
        artifactId,
        attempt: 3,
        sha256Hex: sha256(Buffer.from("actual host bytes")),
        name: "result.txt",
      }),
      declaredBytes: 0,
    });

    const first = await listCollabArtifactAttemptOrphanCandidates(db, { limit: 1 });
    expect(first.rows.map((row) => row.attempt)).toEqual([1]);
    const malformedPage = await listCollabArtifactAttemptOrphanCandidates(db, {
      limit: 1,
      before: first.nextCursor ?? undefined,
    });
    expect(malformedPage.rows).toEqual([]);
    expect(malformedPage.quarantined).toBe(1);
    expect(malformedPage.nextCursor?.attemptReservationId)
      .toBe(`${artifactId}:collab-attempt:2`);
    const following = await listCollabArtifactAttemptOrphanCandidates(db, {
      limit: 1,
      before: malformedPage.nextCursor ?? undefined,
    });
    expect(following.rows.map((row) => row.attempt)).toEqual([3]);
    expect(following.nextCursor).toBeNull();
  });

  it("drains 65+ mixed reserved generations before publish and active replay, then finds a late old-key PUT", async () => {
    const fixture = await identities();
    let failFirstPut = true;
    const releasedIds: string[] = [];
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      put: async (key, body, options) => {
        if (failFirstPut) {
          failFirstPut = false;
          throw new Error("leave the initial pending attempt");
        }
        return createFsStorage(harness.storageRoot).put(key, body, options);
      },
      reservationStore: (tx) => {
        const store = new StorageReservationStore(tx);
        return {
          reserve: (reservation) => store.reserve(reservation),
          finalize: (reservation) => store.finalize(reservation),
          release: async (reservation) => {
            releasedIds.push(reservation.reservationId);
            await store.release(reservation);
          },
        };
      },
      timeouts: { pendingWaitMs: 0 },
    });
    const input = inputFor(fixture.identity, { idempotencyKey: "mixed-reserved-history" });
    await expect(harness.registrar.register(input)).rejects.toMatchObject({ code: "temporarily_unavailable" });
    const pendingRows = await rowsFor(fixture.sessionId);
    const artifactId = pendingRows[0]!.id as string;
    const historyKey = (attempt: number) => collabArtifactAttemptKey({
      ownerUserId: fixture.ownerUserId,
      sessionId: fixture.sessionId,
      artifactId,
      attempt,
      sha256Hex: sha256(input.content!),
      name: input.name,
    });
    // Attempt 1 is released by the failed call; attempts 2..66 are 65 reserved
    // generations, deliberately spanning the old 64-row page boundary.
    for (let attempt = 2; attempt <= 66; attempt += 1) {
      await insertAttemptHistory({
        fixture,
        artifactId,
        attempt,
        state: "reserved",
        objectId: historyKey(attempt),
        declaredBytes: input.content!.length,
      });
    }
    // No scheduled pre-drain: the registrar itself must page through all 65
    // reserved generations before it may publish attempt 67.
    const releasesBeforeRecovery = releasedIds.length;
    const recovered = await harness.registrar.register(input);
    expect(recovered.id).toBe(artifactId);
    expect(recovered.key).toContain("-attempt-67-");
    expect(releasedIds.slice(releasesBeforeRecovery).filter((id) => {
      const attempt = Number(id.slice(`${artifactId}:collab-attempt:`.length));
      return attempt >= 2 && attempt <= 66;
    })).toHaveLength(65);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: input.content!.length, reservedBytes: 0 });
    const remainingReserved = await db.$client<{ count: number | string }[]>`
      SELECT count(*)::int AS count FROM storage_reservations
       WHERE id LIKE ${`${artifactId}:collab-attempt:%`} AND state = 'reserved'`;
    expect(Number(remainingReserved[0]!.count)).toBe(0);

    // Active replay also reconciles a genuinely older reserved generation
    // (attempt 2 behind active attempt 67), not merely a later generation.
    await db.delete(schema.storageReservations).where(
      sql`${schema.storageReservations.id} = ${`${artifactId}:collab-attempt:2`}`,
    );
    await insertAttemptHistory({
      fixture,
      artifactId,
      attempt: 2,
      state: "reserved",
      objectId: historyKey(2),
      declaredBytes: input.content!.length,
    });
    const replay = await harness.registrar.register(input);
    expect(replay).toEqual(recovered);
    expect(harness.calls.put).toBe(2);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: input.content!.length, reservedBytes: 0 });

    // A late PUT for the oldest formerly reserved generation is discoverable
    // after release, but cannot displace the newer active key.
    await harness.base.put(historyKey(2), input.content!, {
      contentType: "text/plain",
      sha256Hex: sha256(input.content!),
      metadata: {
        "ovid-collab-artifact": artifactId,
        "ovid-collab-attempt": `${artifactId}:collab-attempt:2`,
      },
    });
    const candidates = await listCollabArtifactAttemptOrphanCandidates(db, { limit: 100 });
    const late = candidates.rows.find((candidate) =>
      candidate.attemptReservationId === `${artifactId}:collab-attempt:2`);
    expect(late).toBeDefined();
    const cleanupDeadline = new CollabArtifactDeadline(1_000);
    expect(await cleanupCollabArtifactAttemptWithShortFences({
      db,
      storage: harness.storage,
      candidate: late!,
      deadline: cleanupDeadline,
    })).toBe("cleaned");
    cleanupDeadline.close();
    expect(await harness.base.head(historyKey(2))).toBeNull();
    expect(await harness.base.head(recovered.key)).not.toBeNull();
    expect(await activeCount(fixture.sessionId)).toBe(1);
  });

  it("bounded scheduled reserved-release is composable and reports remaining progress without storage I/O", async () => {
    const fixture = await identities();
    const harness = await makeHarness({
      put: async () => { throw new Error("leave scheduled-release fixture"); },
      timeouts: { pendingWaitMs: 0 },
    });
    await expect(harness.registrar.register(inputFor(fixture.identity, {
      idempotencyKey: "scheduled-reserved-release",
    }))).rejects.toMatchObject({ code: "temporarily_unavailable" });
    const rows = await rowsFor(fixture.sessionId);
    const artifactId = rows[0]!.id as string;
    for (const attempt of [2, 3]) {
      await insertAttemptHistory({
        fixture,
        artifactId,
        attempt,
        state: "reserved",
        objectId: rows[0]!.r2_key as string,
        declaredBytes: 1,
      });
    }
    const beforeCalls = { ...harness.calls };
    const deadline = new CollabArtifactDeadline(1_000);
    try {
      const first = await releaseCollabArtifactReservedAttempts({
        db,
        ownerUserId: fixture.ownerUserId,
        sessionId: fixture.sessionId,
        artifactId,
        limit: 1,
        deadline,
      });
      expect(first).toEqual({ released: 1, remaining: 1 });
      const second = await releaseCollabArtifactReservedAttempts({
        db,
        ownerUserId: fixture.ownerUserId,
        sessionId: fixture.sessionId,
        artifactId,
        limit: 1,
        deadline,
      });
      expect(second).toEqual({ released: 1, remaining: 0 });
    } finally {
      deadline.close();
    }
    expect(harness.calls).toEqual(beforeCalls);
  });

  it("never adopts a poisoned same-length orphan after cleanup failure; restored source uses a fenced new key", async () => {
    const fixture = await identities();
    const attemptedKeys: string[] = [];
    let sourcePath = "";
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      workspaceDir: async () => harness.workspaceRoot,
      put: async (key, body, options) => {
        attemptedKeys.push(key);
        // Same length, different bytes; fs/R2 metadata still receives hash(aaaa).
        await writeFile(sourcePath, "bbbb");
        return harness.base.put(key, body, options);
      },
      delete: async () => { throw new Error("orphan cleanup unavailable"); },
    });
    sourcePath = join(harness.workspaceRoot, "mutable.txt");
    await writeFile(sourcePath, "aaaa");
    const input = inputFor(fixture.identity, {
      content: undefined,
      sourcePath: "mutable.txt",
      idempotencyKey: "mutation-recovery",
    });

    await expect(harness.registrar.register(input)).rejects.toMatchObject({ code: "artifact_changed" });
    expect(await activeCount(fixture.sessionId)).toBe(0);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    expect(attemptedKeys).toHaveLength(1);

    await writeFile(sourcePath, "aaaa");
    const recovered = await harness.registrar.register(input);
    expect(attemptedKeys).toHaveLength(2);
    expect(recovered.key).not.toBe(attemptedKeys[0]);
    expect(recovered.key).toBe(attemptedKeys[1]);
    expect((await readFile(join(harness.storageRoot, attemptedKeys[0]!))).toString()).toBe("bbbb");
    expect((await readFile(join(harness.storageRoot, recovered.key))).toString()).toBe("aaaa");
    const active = await workspaceObjects.getArtifact(db, recovered.id, fixture.ownerUserId);
    expect(active).toMatchObject({ status: "active", r2Key: recovered.key, sha256: sha256(Buffer.from("aaaa")) });
    expect(active!.r2Key).not.toBe(attemptedKeys[0]);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 4, reservedBytes: 0 });
  });

  it("legacy null and artifactId object ids are accounting-only canaries, never guessed HEAD/DELETE keys", async () => {
    const fixture = await identities();
    let failFirstPut = true;
    const legacyHeadKeys: string[] = [];
    const legacyDeleteKeys: string[] = [];
    let legacyArtifactId = "";
    const legacyMalformedKey = `users/${fixture.ownerUserId}/artifacts/${fixture.sessionId}/../poison`;
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      put: async (key, body, options) => {
        if (failFirstPut) {
          failFirstPut = false;
          throw new Error("leave a legacy pending attempt");
        }
        return createFsStorage(harness.storageRoot).put(key, body, options);
      },
      head: async (key) => {
        if (key === legacyArtifactId || key === "users/not-canonical" || key === legacyMalformedKey) {
          legacyHeadKeys.push(key);
          throw new Error("legacy artifactId must not be used as a storage key");
        }
        return createFsStorage(harness.storageRoot).head(key);
      },
      delete: async (key) => {
        if (key === legacyArtifactId || key === "users/not-canonical" || key === legacyMalformedKey) {
          legacyDeleteKeys.push(key);
          throw new Error("legacy artifactId must not be deleted as a storage key");
        }
        return createFsStorage(harness.storageRoot).delete(key);
      },
      timeouts: { pendingWaitMs: 0 },
    });
    const input = inputFor(fixture.identity, { idempotencyKey: "legacy-canary" });
    await expect(harness.registrar.register(input)).rejects.toMatchObject({ code: "temporarily_unavailable" });
    const rows = await rowsFor(fixture.sessionId);
    const artifactId = rows[0]!.id as string;
    legacyArtifactId = artifactId;
    await db.update(schema.storageReservations)
      .set({ objectId: artifactId, state: "reserved", releasedAt: null })
      .where(sql`${schema.storageReservations.id} = ${`${artifactId}:collab-attempt:1`}`);
    await db.update(schema.storageUsageCounters)
      .set({ reservedBytes: sql`${schema.storageUsageCounters.reservedBytes} + ${input.content!.length}` })
      .where(sql`${schema.storageUsageCounters.ownerUserId} = ${fixture.ownerUserId}`);
    await insertAttemptHistory({
      fixture,
      artifactId,
      attempt: 2,
      state: "reserved",
      objectId: null,
      declaredBytes: 0,
    });
    // R4 reserved-noncanonical canary: reservation identity is valid for
    // accounting release even though this is never a safe physical object key.
    await insertAttemptHistory({
      fixture,
      artifactId,
      attempt: 3,
      state: "reserved",
      objectId: "users/not-canonical",
      declaredBytes: 0,
    });
    await insertAttemptHistory({
      fixture,
      artifactId,
      attempt: 4,
      state: "reserved",
      objectId: legacyMalformedKey,
      declaredBytes: 0,
    });

    const recovered = await harness.registrar.register(input);
    expect(recovered.id).toBe(artifactId);
    expect(recovered.key).toContain("-attempt-5-");
    expect(legacyHeadKeys).toEqual([]);
    expect(legacyDeleteKeys).toEqual([]);
    expect(harness.calls.delete).toBe(0);
    expect((await attemptReservations(artifactId, fixture.ownerUserId, fixture.sessionId))
      .filter((row) => [
        `${artifactId}:collab-attempt:1`,
        `${artifactId}:collab-attempt:2`,
        `${artifactId}:collab-attempt:3`,
        `${artifactId}:collab-attempt:4`,
      ].includes(row.id as string)))
      .toEqual([
        expect.objectContaining({ state: "released", object_id: artifactId }),
        expect.objectContaining({ state: "released", object_id: null }),
        expect.objectContaining({ state: "released", object_id: "users/not-canonical" }),
        expect.objectContaining({ state: "released", object_id: legacyMalformedKey }),
      ]);
    expect(await activeCount(fixture.sessionId)).toBe(1);
    expect(await usage(fixture.ownerUserId)).toEqual({
      usedBytes: input.content!.length,
      reservedBytes: 0,
    });
  });

  it("stored-stream verification rejects same-length adapter bytes even when HEAD carries the expected hash", async () => {
    const fixture = await identities();
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      put: async (key, _body, options) => {
        // Bypass the source meter: the adapter itself writes B while metadata
        // still declares sha256(A), exactly what an R2 HEAD would report.
        return createFsStorage(harness.storageRoot).put(key, Buffer.from("bbbb"), options);
      },
    });

    await expect(harness.registrar.register(inputFor(fixture.identity, {
      content: Buffer.from("aaaa"),
    }))).rejects.toMatchObject({ code: "artifact_changed" });
    expect(await activeCount(fixture.sessionId)).toBe(0);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  it("a DB-loss stale worker cannot delete or publish over a newer committed attempt", async () => {
    const fixture = await identities();
    const putPublished = deferred();
    const allowPutReturn = deferred();
    let dbLost = false;
    const connectionLoss = Object.assign(new Error("injected DB connection loss"), { code: "08006" });
    const faultDb = {
      transaction: async <T>(callback: (tx: Db) => Promise<T>): Promise<T> => {
        if (dbLost) throw connectionLoss;
        return db.transaction((tx) => callback(tx as unknown as Db));
      },
    } as unknown as Db;
    const firstKeys: string[] = [];
    const stale = await makeHarness({
      db: faultDb,
      put: async (key, body, options) => {
        firstKeys.push(key);
        const result = await createFsStorage(stale.storageRoot).put(key, body, options);
        dbLost = true;
        putPublished.resolve();
        await allowPutReturn.promise;
        return result;
      },
    });
    const first = stale.registrar.register(inputFor(fixture.identity, { idempotencyKey: "db-loss-race" }));
    await putPublished.promise;

    const newerStorage: Pick<StorageAdapter, "put" | "head" | "get" | "delete"> = {
      put: (key, body, options) => stale.base.put(key, body, options),
      head: (key) => stale.base.head(key),
      get: (key) => stale.base.get(key),
      delete: async () => { throw new Error("leave old object for stale-worker assertion"); },
    };
    const newer = new CollabArtifactRegistrar({
      db,
      storage: newerStorage,
      authorization: createCollabArtifactAuthorizationPort(),
      workspaceDir: async () => stale.workspaceRoot,
      pendingWaitMs: 0,
      storageDeadlineMs: 3_000,
      cleanupDeadlineMs: 100,
      dbLockTimeoutMs: 100,
    });
    const committed = await newer.register(inputFor(fixture.identity, { idempotencyKey: "db-loss-race" }));
    allowPutReturn.resolve();

    await expect(first).rejects.toMatchObject({ code: "temporarily_unavailable" });
    expect(firstKeys).toHaveLength(1);
    expect(committed.key).not.toBe(firstKeys[0]);
    expect((await readFile(join(stale.storageRoot, committed.key))).toString()).toBe("actual host bytes");
    const active = await workspaceObjects.getArtifact(db, committed.id, fixture.ownerUserId);
    expect(active).toMatchObject({ status: "active", r2Key: committed.key });
    expect(await activeCount(fixture.sessionId)).toBe(1);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: committed.sizeBytes, reservedBytes: 0 });
  });

  it.each(["bytes", "hash", "type"] as const)(
    "HEAD %s mismatch prevents finalization and leaves no active row or host charge",
    async (mutation) => {
      const fixture = await identities();
      let corruptNextStoredHead = true;
      const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
        head: async (key) => {
          const head = await createFsStorage(harness.storageRoot).head(key);
          if (head !== null && corruptNextStoredHead) {
            corruptNextStoredHead = false;
            if (mutation === "bytes") return { ...head, bytes: head.bytes + 1 };
            if (mutation === "hash") return { ...head, sha256Hex: "0".repeat(64) };
            return { ...head, contentType: "application/octet-stream" };
          }
          return head;
        },
      });

      await expect(harness.registrar.register(inputFor(fixture.identity)))
        .rejects.toMatchObject({ code: "artifact_changed" });
      expect(await activeCount(fixture.sessionId)).toBe(0);
      expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
      expect((await rowsFor(fixture.sessionId)).every((row) => row.status !== "active")).toBe(true);
    },
  );

  it("replay rehashes actual bytes and rejects a same-length object mutation despite original HEAD metadata", async () => {
    const fixture = await identities();
    const harness = await makeHarness();
    const input = inputFor(fixture.identity);
    const record = await harness.registrar.register(input);
    const mutated = Buffer.alloc(input.content!.length, 0x58);
    await writeFile(join(harness.storageRoot, record.key), mutated);

    await expect(harness.registrar.register(input)).rejects.toMatchObject({ code: "artifact_changed" });
    expect(harness.calls.put).toBe(1);
    expect(await activeCount(fixture.sessionId)).toBe(1);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: record.sizeBytes, reservedBytes: 0 });
  });

  it("deleted replay refuses resurrection before another reservation or object write", async () => {
    const fixture = await identities();
    const harness = await makeHarness();
    const input = inputFor(fixture.identity);
    const record = await harness.registrar.register(input);
    const before = await reservationsForSession(fixture.sessionId);
    expect(await artifactVault.remove(db, fixture.ownerUserId, record.id, "generated")).not.toBeNull();

    await expect(harness.registrar.register(input)).rejects.toMatchObject({ code: "artifact_deleted" });
    expect(harness.calls.put).toBe(1);
    expect(await workspaceObjects.getArtifact(db, record.id, fixture.ownerUserId))
      .toMatchObject({ status: "deleted", r2Key: record.key });
    expect(await reservationsForSession(fixture.sessionId)).toEqual(before);
    expect(await activeCount(fixture.sessionId)).toBe(0);
  });

  it.each(["revoked", "closed", "deleted", "deleted_account", "non_member"] as const)(
    "real %s authority denies before reservation, intent, or object writes",
    async (reason) => {
      const fixture = await identities();
      const harness = await makeHarness();
      let input = inputFor(fixture.identity);
      if (reason === "revoked") {
        await fixture.repos.remove({
          uid: fixture.ownerUserId,
          token: fixture.room.sessionToken,
          participantId: fixture.participantId,
        });
      } else if (reason === "closed") {
        await fixture.repos.close({
          uid: fixture.ownerUserId,
          token: fixture.room.sessionToken,
          idempotencyKey: `close-${newId()}`,
        });
      } else if (reason === "deleted") {
        await db.update(schema.sessions).set({ deletedAt: new Date() })
          .where(sql`${schema.sessions.id} = ${fixture.sessionId}`);
      } else if (reason === "deleted_account") {
        await db.insert(schema.accountDeletions).values({
          uid: fixture.actorUserId,
          state: "pending",
          deleteAfter: Date.now() / 1000 + 3600,
          record: {},
        });
      } else {
        const stranger = newId();
        await users.ensure(db, stranger, null);
        input = inputFor({ ...fixture.identity, actorUserId: stranger });
      }

      await expect(harness.registrar.register(input)).rejects.toMatchObject({ code: "not_member" });
      expect(harness.calls.put).toBe(0);
      expect(await rowsFor(fixture.sessionId)).toEqual([]);
      expect(await reservationsForSession(fixture.sessionId)).toEqual([]);
      expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    },
  );

  it.each(["owner", "actor"] as const)(
    "real %s account-deletion request wins the race before reservation",
    async (party) => {
      const fixture = await identities();
      const uid = party === "owner" ? fixture.ownerUserId : fixture.actorUserId;
      let transactions = 0;
      const deletionDb = {
        transaction: async <T>(callback: (tx: Db) => Promise<T>): Promise<T> => {
          transactions += 1;
          if (transactions === 2) await requestAccountDeletion(uid);
          return db.transaction((tx) => callback(tx as unknown as Db));
        },
      } as unknown as Db;
      const harness = await makeHarness({ db: deletionDb });

      await expect(harness.registrar.register(inputFor(fixture.identity)))
        .rejects.toMatchObject({ code: "not_member" });
      expect(transactions).toBeGreaterThanOrEqual(2);
      expect(harness.calls.put).toBe(0);
      expect(await rowsFor(fixture.sessionId)).toEqual([]);
      expect(await reservationsForSession(fixture.sessionId)).toEqual([]);
      expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    },
  );

  it.each(["owner", "actor"] as const)(
    "real %s account-deletion request wins the race immediately before activation",
    async (party) => {
      const fixture = await identities();
      const uid = party === "owner" ? fixture.ownerUserId : fixture.actorUserId;
      let transactions = 0;
      const deletionDb = {
        transaction: async <T>(callback: (tx: Db) => Promise<T>): Promise<T> => {
          transactions += 1;
          // preflight=1, intent=2, pre-PUT=3; the next transaction is publish.
          if (transactions === 4) await requestAccountDeletion(uid);
          return db.transaction((tx) => callback(tx as unknown as Db));
        },
      } as unknown as Db;
      const harness = await makeHarness({ db: deletionDb });

      await expect(harness.registrar.register(inputFor(fixture.identity)))
        .rejects.toMatchObject({ code: "not_member" });
      expect(transactions).toBeGreaterThanOrEqual(4);
      expect(await activeCount(fixture.sessionId)).toBe(0);
      const rows = await rowsFor(fixture.sessionId);
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ status: "pending" });
      expect(await reservation(rows[0]!.id as string)).toBeUndefined();
      expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    },
  );

  it("revocation during collision HEAD is re-fenced immediately before PUT", async () => {
    const fixture = await identities();
    const enteredHead = deferred();
    const finishHead = deferred();
    let firstHead = true;
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      head: async (key) => {
        if (firstHead) {
          firstHead = false;
          enteredHead.resolve();
          await finishHead.promise;
        }
        return createFsStorage(harness.storageRoot).head(key);
      },
    });
    const pending = harness.registrar.register(inputFor(fixture.identity));
    await enteredHead.promise;
    await fixture.repos.remove({
      uid: fixture.ownerUserId,
      token: fixture.room.sessionToken,
      participantId: fixture.participantId,
    });
    finishHead.resolve();

    await expect(pending).rejects.toMatchObject({ code: "not_member" });
    expect(harness.calls.put).toBe(0);
    expect(await activeCount(fixture.sessionId)).toBe(0);
    expect(await reservation((await rowsFor(fixture.sessionId))[0]!.id as string)).toBeUndefined();
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  it("a real room/member generation advance fences an in-flight attempt even when the sender remains active", async () => {
    const fixture = await identities();
    const enteredHead = deferred();
    const finishHead = deferred();
    let firstHead = true;
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      head: async (key) => {
        if (firstHead) {
          firstHead = false;
          enteredHead.resolve();
          await finishHead.promise;
        }
        return createFsStorage(harness.storageRoot).head(key);
      },
    });
    const pending = harness.registrar.register(inputFor(fixture.identity));
    await enteredHead.promise;
    const third = newId();
    const invite = await fixture.repos.createInvite({
      uid: fixture.ownerUserId,
      token: fixture.room.sessionToken,
      idempotencyKey: `invite-${newId()}`,
      maxUses: 1,
      ttlSeconds: 600,
    });
    await fixture.repos.join({
      uid: third,
      token: fixture.room.sessionToken,
      inviteCode: invite.inviteCode,
      idempotencyKey: `join-${newId()}`,
    });
    finishHead.resolve();

    await expect(pending).rejects.toMatchObject({ code: "membership_changed" });
    expect(harness.calls.put).toBe(0);
    expect(await activeCount(fixture.sessionId)).toBe(0);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  it("close during PUT cannot publish a committed row or canonical charge", async () => {
    const fixture = await identities();
    const enteredPut = deferred();
    const finishPut = deferred();
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      put: async (key, body, options) => {
        const result = await createFsStorage(harness.storageRoot).put(key, body, options);
        enteredPut.resolve();
        await finishPut.promise;
        return result;
      },
    });
    const pending = harness.registrar.register(inputFor(fixture.identity));
    await enteredPut.promise;
    await fixture.repos.close({
      uid: fixture.ownerUserId,
      token: fixture.room.sessionToken,
      idempotencyKey: `close-${newId()}`,
    });
    finishPut.resolve();

    await expect(pending).rejects.toMatchObject({ code: "not_member" });
    expect(await activeCount(fixture.sessionId)).toBe(0);
    const rows = await rowsFor(fixture.sessionId);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ status: "pending" });
    expect(await artifactVault.get(db, fixture.ownerUserId, rows[0]!.id as string, "generated")).toBeNull();
    expect(await reservation(rows[0]!.id as string)).toBeUndefined();
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  it("session deletion during stored-stream verification fences DB publication and cleans only the attempt object", async () => {
    const fixture = await identities();
    const enteredGet = deferred();
    const finishGet = deferred();
    let firstGet = true;
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      get: async (key) => {
        if (firstGet) {
          firstGet = false;
          enteredGet.resolve();
          await finishGet.promise;
        }
        return createFsStorage(harness.storageRoot).get(key);
      },
    });
    const pending = harness.registrar.register(inputFor(fixture.identity));
    await enteredGet.promise;
    await db.update(schema.sessions).set({ deletedAt: new Date() })
      .where(sql`${schema.sessions.id} = ${fixture.sessionId}`);
    finishGet.resolve();

    await expect(pending).rejects.toMatchObject({ code: "not_member" });
    expect(await activeCount(fixture.sessionId)).toBe(0);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    const attempts = await attemptReservations(
      (await rowsFor(fixture.sessionId))[0]!.id as string,
      fixture.ownerUserId,
      fixture.sessionId,
    );
    expect(attempts).toHaveLength(1);
    expect(attempts[0]).toMatchObject({ state: "released" });
    expect(attempts[0]!.object_id).toBe((await rowsFor(fixture.sessionId))[0]!.r2_key);
  });

  it("rollback after publish callback leaves no false active row/charge and retries with a new fenced key", async () => {
    const fixture = await identities();
    const crash = new Error("injected publish rollback");
    let crashOnPublish = false;
    let armCrash = true;
    const crashDb = {
      transaction: async <T>(callback: (tx: Db) => Promise<T>): Promise<T> => {
        return db.transaction(async (tx) => {
          const result = await callback(tx as unknown as Db);
          if (crashOnPublish) {
            crashOnPublish = false;
            throw crash;
          }
          return result;
        });
      },
    } as unknown as Db;
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      db: crashDb,
      get: async (key) => {
        const stream = await createFsStorage(harness.storageRoot).get(key);
        if (stream !== null && armCrash) {
          armCrash = false;
          crashOnPublish = true;
        }
        return stream;
      },
    });
    const input = inputFor(fixture.identity, { idempotencyKey: "publish-rollback" });

    await expect(harness.registrar.register(input)).rejects.toMatchObject({ code: "temporarily_unavailable" });
    const pendingRows = await rowsFor(fixture.sessionId);
    expect(pendingRows).toHaveLength(1);
    expect(pendingRows[0]).toMatchObject({ status: "pending" });
    const artifactId = pendingRows[0]!.id as string;
    expect(await reservation(artifactId)).toBeUndefined();
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    const firstKey = pendingRows[0]!.r2_key as string;
    expect(await harness.base.head(firstKey)).toBeNull();

    const recovered = await harness.registrar.register(input);
    expect(recovered.id).toBe(artifactId);
    expect(recovered.key).not.toBe(firstKey);
    expect(await activeCount(fixture.sessionId)).toBe(1);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: input.content!.length, reservedBytes: 0 });
  });

  it("a response loss after commit replays the same active object without another PUT or charge", async () => {
    const fixture = await identities();
    const responseLoss = new Error("injected response loss after commit");
    let loseResponse = false;
    let armLoss = true;
    const lossDb = {
      transaction: async <T>(callback: (tx: Db) => Promise<T>): Promise<T> => {
        const result = await db.transaction((tx) => callback(tx as unknown as Db));
        if (loseResponse) {
          loseResponse = false;
          throw responseLoss;
        }
        return result;
      },
    } as unknown as Db;
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      db: lossDb,
      get: async (key) => {
        const stream = await createFsStorage(harness.storageRoot).get(key);
        if (stream !== null && armLoss) {
          armLoss = false;
          loseResponse = true;
        }
        return stream;
      },
    });
    const input = inputFor(fixture.identity, { idempotencyKey: "response-loss-after-commit" });

    await expect(harness.registrar.register(input)).rejects.toMatchObject({ code: "temporarily_unavailable" });
    expect(await activeCount(fixture.sessionId)).toBe(1);
    const replay = await harness.registrar.register(input);
    expect(harness.calls.put).toBe(1);
    expect(await activeCount(fixture.sessionId)).toBe(1);
    expect(await reservation(replay.id)).toMatchObject({ state: "finalized", actual_bytes: replay.sizeBytes });
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: replay.sizeBytes, reservedBytes: 0 });
  });

  it("late PUT after cleanup is a bounded discoverable orphan and scheduled recovery never touches a newer active key", async () => {
    const fixture = await identities();
    const putStarted = deferred();
    const allowPut = deferred();
    const latePublished = deferred();
    const harness = await makeHarness({
      put: async (key, body, options) => {
        putStarted.resolve();
        await allowPut.promise;
        const result = await createFsStorage(harness.storageRoot).put(key, body, options);
        latePublished.resolve();
        return result;
      },
      timeouts: { storageDeadlineMs: 20, cleanupDeadlineMs: 20, pendingWaitMs: 0 },
    });
    const input = inputFor(fixture.identity, { idempotencyKey: "late-put-orphan" });
    const pending = harness.registrar.register(input);
    await putStarted.promise;
    await expect(pending).rejects.toMatchObject({ code: "storage_timeout" });
    // No identical retry is made. The late adapter completion happens after
    // the failure cleanup has already observed a missing key.
    allowPut.resolve();
    await latePublished.promise;

    const candidates = await listCollabArtifactAttemptOrphanCandidates(db, { limit: 1 });
    expect(candidates.rows).toHaveLength(1);
    const candidate = candidates.rows[0]!;
    expect(candidate.attemptReservationId).toBe(`${candidate.id}:collab-attempt:1`);
    expect(candidate.key).toContain(`${candidate.id}-attempt-1-`);
    expect(classifyCollabArtifactAttemptHead(await harness.base.head(candidate.key), candidate)).toBe("owned");
    expect(await activeCount(fixture.sessionId)).toBe(0);
    expect(collabArtifactAttemptMayDelete({
      reservationState: "released",
      reservationObjectId: candidate.key,
      candidateKey: candidate.key,
      candidateAttempt: candidate.attempt,
      current: { status: "active", r2Key: candidate.key, attempt: candidate.attempt + 1 },
    })).toBe(false);
    expect(collabArtifactAttemptMayDelete({
      reservationState: "released",
      reservationObjectId: candidate.key,
      candidateKey: candidate.key,
      candidateAttempt: candidate.attempt,
      current: { status: "active", r2Key: "newer-active-key", attempt: candidate.attempt + 1 },
    })).toBe(true);

    let activeTransactions = 0;
    const ioDuringTransaction: string[] = [];
    const trackingDb = {
      transaction: async <T>(callback: (tx: Db) => Promise<T>): Promise<T> => {
        activeTransactions += 1;
        try {
          return await db.transaction((tx) => callback(tx as unknown as Db));
        } finally {
          activeTransactions -= 1;
        }
      },
    } as unknown as Db;
    const lockFreeStorage: Pick<StorageAdapter, "put" | "head" | "get" | "delete"> = {
      put: (key, body, options) => harness.base.put(key, body, options),
      head: async (key) => {
        if (activeTransactions > 0) ioDuringTransaction.push("head");
        return harness.base.head(key);
      },
      get: (key) => harness.base.get(key),
      delete: async (key) => {
        if (activeTransactions > 0) ioDuringTransaction.push("delete");
        return harness.base.delete(key);
      },
    };
    const fenceDeadline = new CollabArtifactDeadline(1_000);
    const fence = await readCollabArtifactAttemptCleanupFence(trackingDb, candidate, fenceDeadline);
    fenceDeadline.close();
    expect(fence.allowed).toBe(true);
    expect(fence.sessionDeleted).toBe(false);

    const result = await reconcileCollabArtifactAttemptOrphans({
      db: trackingDb,
      storage: lockFreeStorage,
      limit: 1,
      deadline: new CollabArtifactDeadline(1_000),
    });
    expect(result).toMatchObject({ examined: 1, cleaned: 1, failed: 0, deadlineExceeded: false });
    expect(ioDuringTransaction).toEqual([]);
    expect(await harness.base.head(candidate.key)).toBeNull();
    expect(await activeCount(fixture.sessionId)).toBe(0);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  it("overall recovery deadline includes cleanup-port DB work", async () => {
    const fixture = await identities();
    const harness = await makeHarness({
      put: async () => { throw new Error("leave released recovery candidate"); },
      timeouts: { pendingWaitMs: 0 },
    });
    await expect(harness.registrar.register(inputFor(fixture.identity)))
      .rejects.toMatchObject({ code: "temporarily_unavailable" });
    const deadline = new CollabArtifactDeadline(20);
    const started = Date.now();
    const result = await reconcileCollabArtifactAttemptOrphans({
      db,
      storage: harness.storage,
      limit: 1,
      deadline,
      cleanup: async () => new Promise<never>(() => {}),
    });
    deadline.close();
    expect(Date.now() - started).toBeLessThan(2_000);
    expect(result.deadlineExceeded).toBe(true);
    expect(result.failed).toBe(1);
    expect(result.cleaned).toBe(0);
  });

  it("DB pool acquisition is bounded by the overall operation deadline", async () => {
    const fixture = await identities();
    const acquisition = deferred();
    const acquisitionDb = {
      transaction: () => {
        acquisition.resolve();
        return new Promise<never>(() => {});
      },
    } as unknown as Db;
    const harness = await makeHarness({
      db: acquisitionDb,
      timeouts: { operationDeadlineMs: 20 },
    });
    const started = Date.now();
    const pending = harness.registrar.register(inputFor(fixture.identity));
    await acquisition.promise;

    await expect(pending).rejects.toMatchObject({ code: "db_timeout" });
    expect(Date.now() - started).toBeLessThan(2_000);
    expect(harness.calls.put).toBe(0);
    expect(await rowsFor(fixture.sessionId)).toEqual([]);
  });

  it("cumulative DB work uses one operation deadline and requests backend cancellation", async () => {
    const fixture = await identities();
    let transactions = 0;
    const cancelCalls: number[] = [];
    const stalledDb = {
      transaction: async <T>(callback: (tx: Db) => Promise<T>): Promise<T> => {
        transactions += 1;
        return db.transaction(async (tx) => {
          if (transactions === 2) {
            // Start the callback so pg_backend_pid is known, then hold the
            // transaction open. Only the overall operation signal ends this
            // cumulative wait; the per-statement timeout is not the gate.
            const pending = callback(tx as unknown as Db);
            await new Promise<void>((resolve) => setTimeout(resolve, 200));
            return pending;
          }
          return callback(tx as unknown as Db);
        });
      },
    } as unknown as Db;
    const harness = await makeHarness({
      db: stalledDb,
      cancelBackend: async (pid) => { cancelCalls.push(pid); },
      timeouts: { operationDeadlineMs: 25, dbStatementTimeoutMs: 2_000 },
    });
    const started = Date.now();

    await expect(harness.registrar.register(inputFor(fixture.identity)))
      .rejects.toMatchObject({ code: "db_timeout" });
    expect(Date.now() - started).toBeLessThan(2_000);
    expect(transactions).toBe(2);
    expect(cancelCalls.length).toBeGreaterThan(0);
    expect(harness.calls.put).toBe(0);
  });

  it("caller cancellation interrupts DB waiting before an intent write", async () => {
    const fixture = await identities();
    const entered = deferred();
    const controller = new AbortController();
    const waitingDb = {
      transaction: () => {
        entered.resolve();
        return new Promise<never>(() => {});
      },
    } as unknown as Db;
    const harness = await makeHarness({ db: waitingDb, timeouts: { operationDeadlineMs: 5_000 } });
    const pending = harness.registrar.register(inputFor(fixture.identity, { signal: controller.signal }));
    await entered.promise;
    controller.abort();

    await expect(pending).rejects.toMatchObject({ code: "cancelled" });
    expect(harness.calls.put).toBe(0);
    expect(await rowsFor(fixture.sessionId)).toEqual([]);
  });

  it("storage waits have an overall deadline and never publish after timeout", async () => {
    const fixture = await identities();
    const never = new Promise<never>(() => {});
    const harness = await makeHarness({
      put: () => never,
      timeouts: { storageDeadlineMs: 20, cleanupDeadlineMs: 50, pendingWaitMs: 0 },
    });
    const started = Date.now();

    await expect(harness.registrar.register(inputFor(fixture.identity)))
      .rejects.toMatchObject({ code: "storage_timeout" });
    expect(Date.now() - started).toBeLessThan(2_000);
    expect(await activeCount(fixture.sessionId)).toBe(0);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  it("caller cancellation aborts storage waiting without a committed row", async () => {
    const fixture = await identities();
    const enteredPut = deferred();
    const controller = new AbortController();
    const harness = await makeHarness({
      put: async () => {
        enteredPut.resolve();
        return new Promise<never>(() => {});
      },
    });
    const pending = harness.registrar.register(inputFor(fixture.identity, { signal: controller.signal }));
    await enteredPut.promise;
    controller.abort();

    await expect(pending).rejects.toMatchObject({ code: "cancelled" });
    expect(await activeCount(fixture.sessionId)).toBe(0);
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  it("an already-cancelled call performs no DB intent or storage write", async () => {
    const fixture = await identities();
    const harness = await makeHarness();
    const controller = new AbortController();
    controller.abort();

    await expect(harness.registrar.register(inputFor(fixture.identity, { signal: controller.signal })))
      .rejects.toMatchObject({ code: "cancelled" });
    expect(harness.calls.put).toBe(0);
    expect(await rowsFor(fixture.sessionId)).toEqual([]);
    expect(await reservationsForSession(fixture.sessionId)).toEqual([]);
  });

  it("a contended DB row lock fails within lock_timeout instead of waiting indefinitely", async () => {
    const fixture = await identities();
    const harness = await makeHarness({
      put: async () => { throw new Error("leave durable pending intent"); },
      timeouts: { dbLockTimeoutMs: 20, pendingWaitMs: 0 },
    });
    const input = inputFor(fixture.identity);
    await expect(harness.registrar.register(input)).rejects.toMatchObject({ code: "temporarily_unavailable" });
    const rows = await rowsFor(fixture.sessionId);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ status: "pending" });
    const artifactId = rows[0]!.id as string;
    const locked = deferred();
    const release = deferred();
    const holder = db.transaction(async (tx) => {
      await tx.execute(sql`SELECT id FROM workspace_objects WHERE id = ${artifactId} FOR UPDATE`);
      locked.resolve();
      await release.promise;
    });
    await locked.promise;
    try {
      await expect(harness.registrar.register(input)).rejects.toMatchObject({ code: "lock_timeout" });
    } finally {
      release.resolve();
      await holder;
    }
    expect(await activeCount(fixture.sessionId)).toBe(0);
  });

  it("a collision at a new attempt key is never overwritten or destructively cleaned", async () => {
    const fixture = await identities();
    const harness = await makeHarness({
      head: async () => ({
        bytes: 1,
        sha256Hex: "0".repeat(64),
        etag: "unknown",
        contentType: "application/octet-stream",
        metadata: {},
      }),
    });

    await expect(harness.registrar.register(inputFor(fixture.identity)))
      .rejects.toMatchObject({ code: "artifact_changed" });
    expect(harness.calls.put).toBe(0);
    expect(harness.calls.delete).toBe(0);
    expect(await activeCount(fixture.sessionId)).toBe(0);
  });

  it("uses the host workspace and rejects lexical, absolute, final and ancestor symlink escapes", async () => {
    const fixture = await identities();
    const workspaceOwners: string[] = [];
    const harness: Awaited<ReturnType<typeof makeHarness>> = await makeHarness({
      workspaceDir: async (ownerUserId) => {
        workspaceOwners.push(ownerUserId);
        return harness.workspaceRoot;
      },
    });
    const inside = join(harness.workspaceRoot, "nested", "source.txt");
    await mkdir(dirname(inside), { recursive: true });
    await writeFile(inside, "confined source bytes");
    const outsideRoot = await mkdtemp(join(tmpdir(), "ovid-collab-artifact-outside-"));
    temporaryRoots.push(outsideRoot);
    const outside = join(outsideRoot, "outside.txt");
    await writeFile(outside, "outside must not be uploaded");
    await symlink(outside, join(harness.workspaceRoot, "escape.txt"));
    await symlink(outsideRoot, join(harness.workspaceRoot, "escape-dir"));

    const record = await harness.registrar.register(inputFor(fixture.identity, {
      content: undefined,
      sourcePath: "nested/source.txt",
    }));
    expect(workspaceOwners).toEqual([fixture.ownerUserId]);
    expect((await readFile(join(harness.storageRoot, record.key))).toString()).toBe("confined source bytes");

    for (const sourcePath of ["../outside.txt", outside, "escape.txt", "escape-dir/outside.txt"]) {
      await expect(harness.registrar.register(inputFor(fixture.identity, {
        content: undefined,
        sourcePath,
      }))).rejects.toMatchObject({ code: "source_outside_workspace" });
    }
    expect(harness.calls.put).toBe(1);
    expect(await activeCount(fixture.sessionId)).toBe(1);
  });

  it("keeps concurrent host usage within the actual-byte cap", async () => {
    const fixture = await identities();
    const harness = await makeHarness({
      reservationStore: (tx) => new StorageReservationStore(tx, {
        storageBytes: 10,
        uploads: { count: 20, windowHours: 24 },
      }),
      timeouts: { pendingWaitMs: 5_000 },
    });
    const first = inputFor(fixture.identity, { content: Buffer.from("111111"), idempotencyKey: "cap-one" });
    const second = inputFor(fixture.identity, { content: Buffer.from("222222"), idempotencyKey: "cap-two" });

    const outcomes = await Promise.allSettled([
      harness.registrar.register(first),
      harness.registrar.register(second),
    ]);

    expect(outcomes.filter((outcome) => outcome.status === "fulfilled")).toHaveLength(1);
    expect(outcomes.find((outcome) => outcome.status === "rejected"))
      .toMatchObject({ reason: { code: "storage_quota_exceeded" } });
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: 6, reservedBytes: 0 });
    expect(await activeCount(fixture.sessionId)).toBe(1);
  });

  it("applies the sender upload window independently from host byte accounting", async () => {
    const fixture = await identities();
    const otherActor = newId();
    const invite = await fixture.repos.createInvite({
      uid: fixture.ownerUserId,
      token: fixture.room.sessionToken,
      idempotencyKey: `invite-${newId()}`,
      maxUses: 1,
      ttlSeconds: 600,
    });
    await fixture.repos.join({
      uid: otherActor,
      token: fixture.room.sessionToken,
      inviteCode: invite.inviteCode,
      idempotencyKey: `join-${newId()}`,
    });
    const harness = await makeHarness({
      reservationStore: (tx) => new StorageReservationStore(tx, {
        storageBytes: 1_000,
        uploads: { count: 1, windowHours: 24 },
      }),
    });
    // A room generation change between independent register calls is fine; each
    // call captures and fences its own fresh authorization snapshot.
    const first = await harness.registrar.register(inputFor(fixture.identity, {
      content: Buffer.from("first"),
      idempotencyKey: "sender-window-one",
    }));

    await expect(harness.registrar.register(inputFor(fixture.identity, {
      content: Buffer.from("second"),
      idempotencyKey: "sender-window-two",
    }))).rejects.toMatchObject({ code: "upload_limit_reached" });
    expect(await usage(fixture.ownerUserId)).toEqual({ usedBytes: first.sizeBytes, reservedBytes: 0 });

    const otherSender = await harness.registrar.register(inputFor({
      ...fixture.identity,
      actorUserId: otherActor,
    }, {
      content: Buffer.from("other"),
      idempotencyKey: "sender-window-other",
    }));
    expect(otherSender.actorUserId).toBe(otherActor);
    expect(otherSender.ownerUserId).toBe(fixture.ownerUserId);
    expect(await usage(fixture.ownerUserId)).toEqual({
      usedBytes: first.sizeBytes + otherSender.sizeBytes,
      reservedBytes: 0,
    });
    expect(await usage(otherActor)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });
});
