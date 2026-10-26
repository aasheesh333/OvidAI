import { createHmac, timingSafeEqual } from "node:crypto";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { FastifyInstance } from "fastify";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  StorageReservationStore,
  attachments,
  createDb,
  migrate,
  newId,
  projectFileUsage,
  projectsRepo,
  removeObject,
  schema,
  sessions,
  users,
  workspaceObjects,
  type Db,
} from "@ovid/db";
import {
  createStorage,
  type PresignGetOptions,
  type PresignPutInput,
  type StorageAdapter,
} from "@ovid/storage";
import { buildGateway } from "../app.js";
import type { AuthPrincipal } from "../auth.js";
import { createMigrationScratch, type MigrationScratch } from "../../../../packages/db/src/migrationTestKit.js";
// Package-boundary regression: shared recovery APIs come from @ovid/db.
import {
  CollabArtifactDeadline,
  CollabOrphanSweepScheduler,
  releaseCollabArtifactReservedAttempts,
  type CollabArtifactAttemptCursor,
} from "@ovid/db";
import {
  CollabArtifactRegistrar,
  collabArtifactErrorResponse,
  createCollabArtifactAuthorizationPort,
} from "../../../worker/src/collabArtifacts.js";
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
import { CollabMembership } from "./membership.js";
import { CollabProjection } from "./projection.js";
import {
  CollabObjectService,
  createCollabObjectAuthorizer,
  createCollabObjectStore,
  createCollabReservationPort,
  listCollabObjectArtifactAttempts,
  reconcileCollabObjectOrphans,
  type CollabAttachmentTicket,
  type CollabObjectRouteDeps,
  type CollabSessionObjectAuthority,
} from "./objects.js";

/**
 * UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
 * Source tests for a later authorized verification wave. No claim is made that
 * they pass/typecheck. Real R2 and /turns materialization remain separate gates.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const AUTHORITY_SECRET = "collab-task-5-objects-test-authority-secret";
const NOW = new Date("2026-10-25T12:00:00.000Z");

function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

async function yieldToRoutes(): Promise<void> {
  await new Promise<void>((resolve) => setImmediate(resolve));
}

async function delay(ms: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, ms));
}

async function waitFor(assertion: () => boolean | Promise<boolean>, message: string): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (await assertion()) return;
    await delay(5);
  }
  throw new Error(message);
}

function principal(uid: string): AuthPrincipal {
  return { uid, email: `${uid}@example.test`, authTime: 1_700_000_000 };
}

describe("Collab session-object authorization — UNEXECUTED", () => {
  const active = (viewerRole: "owner" | "participant"): CollabSessionObjectAuthority => ({
    lifecycle: "active",
    viewerRole,
    sessionDeleted: false,
    ownerAccountFenced: false,
    viewerAccountFenced: false,
  });

  it("returns owner/member only for live, unfenced active membership", async () => {
    let authority: CollabSessionObjectAuthority | null = active("participant");
    const authorize = createCollabObjectAuthorizer({
      sessionObjectAuthority: async () => authority,
    });
    const input = { sessionId: newId(), objectOwnerUid: "host", viewerUid: "guest" };
    await expect(authorize(input)).resolves.toBe("member");
    await expect(authorize({ ...input, viewerUid: "host" })).resolves.toBeNull();
    authority = active("owner");
    await expect(authorize({ ...input, viewerUid: "host" })).resolves.toBe("owner");
    await expect(authorize(input)).resolves.toBeNull();
    for (const fenced of [
      { ...active("participant"), lifecycle: "closing" as const },
      { ...active("participant"), lifecycle: "closed" as const },
      { ...active("participant"), sessionDeleted: true },
      { ...active("participant"), ownerAccountFenced: true },
      { ...active("participant"), viewerAccountFenced: true },
      null,
    ]) {
      authority = fenced;
      await expect(authorize(input)).resolves.toBeNull();
    }
  });
});

/** Real HTTP signed-PUT seam, not an R2 claim. Signature binds key/expiry/type. */
class SignedPutServer {
  private server: Server | null = null;
  private origin = "";
  private readonly secret = "collab-object-signed-put-test-secret";
  readonly uploads: Array<{ key: string; contentType: string; bytes: number }> = [];

  constructor(private readonly adapter: () => StorageAdapter) {}

  async start(): Promise<void> {
    this.server = createServer((request, response) => {
      void this.handle(request, response);
    });
    await new Promise<void>((resolve, reject) => {
      this.server!.once("error", reject);
      this.server!.listen(0, "127.0.0.1", () => resolve());
    });
    const address = this.server.address() as AddressInfo;
    this.origin = `http://127.0.0.1:${address.port}`;
  }

  async close(): Promise<void> {
    if (this.server === null) return;
    this.server.closeAllConnections();
    await new Promise<void>((resolve) => this.server!.close(() => resolve()));
    this.server = null;
  }

  presignPut(input: PresignPutInput): string {
    const expires = Math.floor(Date.now() / 1000) + input.ttlSeconds;
    const contentType = input.contentType ?? null;
    const signature = this.signature(input.key, expires, contentType);
    return `${this.origin}/upload?key=${encodeURIComponent(input.key)}&expires=${expires}&signature=${signature}`;
  }

  private signature(key: string, expires: number, contentType: string | null): string {
    return createHmac("sha256", this.secret)
      .update(JSON.stringify([key, expires, contentType]), "utf8")
      .digest("base64url");
  }

  private async handle(
    request: import("node:http").IncomingMessage,
    response: import("node:http").ServerResponse,
  ): Promise<void> {
    try {
      if (request.method !== "PUT" || request.url === undefined) {
        response.writeHead(405).end();
        return;
      }
      const url = new URL(request.url, this.origin);
      const key = url.searchParams.get("key") ?? "";
      const expires = Number(url.searchParams.get("expires"));
      const supplied = url.searchParams.get("signature") ?? "";
      const contentType = typeof request.headers["content-type"] === "string"
        ? request.headers["content-type"]
        : null;
      const expected = this.signature(key, expires, contentType);
      const validSignature = supplied.length === expected.length && timingSafeEqual(
        Buffer.from(supplied),
        Buffer.from(expected),
      );
      if (key === "" || !Number.isSafeInteger(expires) || expires < Math.floor(Date.now() / 1000) ||
          contentType === null || !validSignature) {
        response.writeHead(403).end();
        return;
      }
      const chunks: Buffer[] = [];
      let bytes = 0;
      for await (const chunk of request) {
        const value = Buffer.from(chunk as Uint8Array);
        bytes += value.byteLength;
        if (bytes > 25_000_000) {
          response.writeHead(413).end();
          return;
        }
        chunks.push(value);
      }
      await this.adapter().put(key, Buffer.concat(chunks), { contentType });
      this.uploads.push({ key, contentType, bytes });
      response.writeHead(200).end();
    } catch {
      if (!response.headersSent) response.writeHead(500).end();
    }
  }
}

describe.skipIf(!TEST_DATABASE_URL).sequential("Collab objects through buildGateway — UNEXECUTED real Postgres/fs", () => {
  let scratch: MigrationScratch;
  let db: Db;
  let fsRoot: string;
  let adapter: StorageAdapter;
  let membership: CollabMembership;
  let signedPuts: SignedPutServer;
  const built: FastifyInstance[] = [];

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "collab_objects_fix_1");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 20 });
    membership = new CollabMembership(db, { authoritySecret: AUTHORITY_SECRET });
    fsRoot = await mkdtemp(join(tmpdir(), "collab-objects-"));
    adapter = createStorage({ backend: "fs", fsRoot });
    signedPuts = new SignedPutServer(() => adapter);
    await signedPuts.start();
  }, 180_000);

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
    // Recovery discovery is global. Reset only the attempt namespace used by
    // this suite so exact-limit/cursor regressions cannot inherit candidates.
    await db.$client`
      DELETE FROM storage_reservations
       WHERE id ~ '^[0-9a-fA-F-]{36}:collab-attempt:[1-9][0-9]*$'`;
    await db.$client`DELETE FROM attachments`;
    await db.$client`DELETE FROM workspace_objects`;
    await db.$client`DELETE FROM storage_reservations`;
  });

  afterAll(async () => {
    await signedPuts?.close();
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
    await rm(fsRoot, { recursive: true, force: true }).catch(() => {});
  }, 30_000);

  async function fixture(options: {
    storageBytes?: number;
    uploads?: number;
    failPresign?: number;
    orphanSweepMs?: number;
    orphanRescanMs?: number;
    recoveryDeadlineMs?: number;
    recoveryBatchLimit?: number;
    recoveryReservedGroupsPerPass?: number;
    recoveryReservedReleaseLimit?: number;
    reservedRelease?: typeof releaseCollabArtifactReservedAttempts;
    pauseNextSweep?: { gate: Promise<void>; entered: () => void };
  } = {}) {
    const ownerUid = newId();
    const guestUid = newId();
    const strangerUid = newId();
    await users.ensure(db, strangerUid, null);
    const created = await membership.createRoom({
      principal: principal(ownerUid), requestId: `create-${newId()}`,
    });
    const invite = await membership.createInvite({
      principal: principal(ownerUid), token: created.sessionToken,
      idempotencyKey: `invite-${newId()}`, maxUses: 5, ttlSeconds: 3600,
    });
    const joined = await membership.join({
      principal: principal(guestUid), token: created.sessionToken,
      inviteCode: invite.inviteCode, idempotencyKey: `join-${newId()}`,
    });
    const quotaOptions = () => ({
      now: () => NOW,
      storageBytes: options.storageBytes ?? 100,
      uploads: { count: options.uploads ?? 2, windowHours: 24 },
    });
    const controls = {
      failAfterFinalize: false,
      failDebit: 0,
      failRelease: 0,
      failDelete: 0,
      // Key-scoped variant: a live scheduler can consume a global counter on
      // an unrelated candidate, so seeding arms the exact key it will delete.
      failDeleteKeys: new Set<string>(),
      pauseFinalize: null as null | { gate: Promise<void>; entered: () => void },
      pauseNextSweep: options.pauseNextSweep ?? (null as null | { gate: Promise<void>; entered: () => void }),
    };
    const reservationStore = new StorageReservationStore(db, quotaOptions());
    const reservations = createCollabReservationPort(db, {
      reserve: (input) => reservationStore.reserve(input),
      finalize: (input) => reservationStore.finalize(input),
      release: async (input) => {
        if (controls.failRelease > 0) {
          controls.failRelease -= 1;
          throw new Error("injected release failure");
        }
        await reservationStore.release(input);
      },
    }, { now: () => NOW });
    const objects = createCollabObjectStore(db, {
      now: () => NOW,
      removeObject: async (tx, input) => {
        if (controls.failDebit > 0) {
          controls.failDebit -= 1;
          throw new Error("injected finalized-debit failure");
        }
        return removeObject(tx, input, { now: () => NOW });
      },
      reservationStore: (tx) => {
        const inner = new StorageReservationStore(tx, quotaOptions());
        return {
          reserve: (input) => inner.reserve(input),
          finalize: async (input) => {
            const pause = controls.pauseFinalize;
            if (pause !== null) {
              controls.pauseFinalize = null;
              pause.entered();
              await pause.gate;
            }
            const result = await inner.finalize(input);
            if (controls.failAfterFinalize) {
              controls.failAfterFinalize = false;
              throw new Error("injected ambiguous late settlement failure");
            }
            return result;
          },
          release: (input) => inner.release(input),
        };
      },
    });
    const sweepCalls: number[] = [];
    const sweepBefores: Array<CollabArtifactAttemptCursor | undefined> = [];
    const recoveryEvents: string[] = [];
    const attemptOutcomes: Array<{ id: string; outcome: string }> = [];
    const cleanupArtifactAttempt = objects.cleanupArtifactAttempt;
    objects.cleanupArtifactAttempt = async (input) => {
      const outcome = await cleanupArtifactAttempt(input);
      attemptOutcomes.push({ id: input.candidate.id, outcome });
      return outcome;
    };
    const listOrphanCandidates = objects.listOrphanCandidates;
    objects.listOrphanCandidates = async (limit, before, sequence) => {
      sweepCalls.push(limit);
      sweepBefores.push(before);
      recoveryEvents.push("orphan-discovery");
      const pause = controls.pauseNextSweep;
      if (pause !== null) {
        controls.pauseNextSweep = null;
        pause.entered();
        await pause.gate;
      }
      return listOrphanCandidates(limit, before, sequence);
    };
    const signCalls: PresignPutInput[] = [];
    const mintKeys: string[] = [];
    const mintOptions: Array<PresignGetOptions | undefined> = [];
    const deleteCalls: string[] = [];
    const putCalls: string[] = [];
    let failedPresigns = 0;
    const fullStorage: StorageAdapter = {
      ...adapter,
      put: async (key, body, putOptions) => {
        putCalls.push(key);
        return adapter.put(key, body, putOptions);
      },
      presignPut: async (input) => {
        signCalls.push(input);
        if (failedPresigns < (options.failPresign ?? 0)) {
          failedPresigns += 1;
          throw new Error("injected transient signer failure");
        }
        return signedPuts.presignPut(input);
      },
      presignGet: async (key, ttlSeconds, presignOptions) => {
        mintKeys.push(key);
        mintOptions.push(presignOptions);
        return adapter.presignGet(key, ttlSeconds, presignOptions);
      },
      delete: async (key) => {
        if (controls.failDeleteKeys.delete(key)) {
          throw new Error("injected delete failure");
        }
        if (controls.failDelete > 0) {
          controls.failDelete -= 1;
          throw new Error("injected delete failure");
        }
        deleteCalls.push(key);
        await adapter.delete(key);
      },
    };
    const reservedRelease = options.reservedRelease ?? (async (
      input: Parameters<typeof releaseCollabArtifactReservedAttempts>[0],
    ) => {
      recoveryEvents.push(`reserved-release:${input.artifactId}`);
      const result = await releaseCollabArtifactReservedAttempts(input);
      recoveryEvents.push(`reserved-release-result:${input.artifactId}:${result.remaining}`);
      return result;
    });
    const deps: CollabObjectRouteDeps = {
      membership,
      objects,
      reservations,
      storage: fullStorage,
      clock: () => NOW,
      downloadTtlSeconds: 300,
      ...(options.orphanRescanMs !== undefined ? { orphanRescanMs: options.orphanRescanMs } : {}),
      ...(options.recoveryDeadlineMs !== undefined ? { recoveryDeadlineMs: options.recoveryDeadlineMs } : {}),
      ...(options.recoveryBatchLimit !== undefined ? { recoveryBatchLimit: options.recoveryBatchLimit } : {}),
    };
    // C1 regression: the actual buildGateway root Collab composition, not a
    // bare Fastify/manual registerCollabObjectRoutes fixture.
    const app = buildGateway({
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      system: stubSystemBus(),
      storage: fullStorage,
      clock: () => NOW,
      presignTtlSeconds: 300,
      collab: {
        membership,
        projection: new CollabProjection(db),
        objects,
        reservations,
        reservedRelease,
        ...(options.orphanSweepMs !== undefined ? { orphanSweepMs: options.orphanSweepMs } : {}),
        ...(options.orphanRescanMs !== undefined ? { orphanRescanMs: options.orphanRescanMs } : {}),
        ...(options.recoveryDeadlineMs !== undefined ? { recoveryDeadlineMs: options.recoveryDeadlineMs } : {}),
        ...(options.recoveryBatchLimit !== undefined ? { recoveryBatchLimit: options.recoveryBatchLimit } : {}),
        ...(options.recoveryReservedGroupsPerPass !== undefined
          ? { recoveryReservedGroupsPerPass: options.recoveryReservedGroupsPerPass }
          : {}),
        ...(options.recoveryReservedReleaseLimit !== undefined
          ? { recoveryReservedReleaseLimit: options.recoveryReservedReleaseLimit }
          : {}),
      },
    });
    await app.ready();
    built.push(app);
    return {
      app, deps, objects, reservations, reservationStore, controls,
      ownerUid, guestUid, strangerUid,
      sessionId: created.session.sessionId,
      token: created.sessionToken,
      guestParticipantId: joined.member.participantId,
      signCalls, mintKeys, mintOptions, deleteCalls, putCalls, sweepCalls,
      sweepBefores, recoveryEvents, attemptOutcomes, storage: fullStorage,
    };
  }

  type Fixture = Awaited<ReturnType<typeof fixture>>;

  function headers(uid: string): Record<string, string> {
    return authHeaders(uid);
  }

  function createBody(idempotencyKey: string, overrides: Record<string, unknown> = {}) {
    return {
      schemaVersion: 1,
      idempotencyKey,
      name: "proof.txt",
      size: 5,
      contentType: "text/plain",
      ...overrides,
    };
  }

  async function createUpload(
    f: Fixture,
    uid: string,
    idempotencyKey: string,
    overrides: Record<string, unknown> = {},
  ) {
    return f.app.inject({
      method: "POST",
      url: `/chat/${f.token}/attachments`,
      headers: headers(uid),
      payload: createBody(idempotencyKey, overrides),
    });
  }

  async function putTicket(ticket: CollabAttachmentTicket, body: string, contentType?: string) {
    return fetch(ticket.uploadUrl, {
      method: "PUT",
      headers: contentType === undefined
        ? ticket.requiredHeaders
        : { ...ticket.requiredHeaders, "Content-Type": contentType },
      body: Buffer.from(body, "utf8"),
    });
  }

  async function putDirect(f: Fixture, attachmentId: string, body: string, contentType = "text/plain") {
    const [row] = await attachments.getForSession(db, f.sessionId, [attachmentId]);
    expect(row).toBeDefined();
    await f.storage.put(row!.r2Key, Buffer.from(body, "utf8"), { contentType });
    return row!;
  }

  async function finalizeUpload(f: Fixture, uid: string, attachmentId: string) {
    return f.app.inject({
      method: "POST",
      url: `/chat/${f.token}/attachments/${attachmentId}/finalize`,
      headers: headers(uid),
      payload: { schemaVersion: 1 },
    });
  }

  async function counters(ownerUid: string, actorUid: string) {
    const storageRows = await db.$client`
      SELECT used_bytes::int, reserved_bytes::int FROM storage_usage_counters
       WHERE owner_user_id = ${ownerUid}`;
    const uploadRows = await db.$client`
      SELECT used_uploads, reserved_uploads FROM upload_window_counters
       WHERE actor_user_id = ${actorUid}`;
    return { storageRows, uploadRows };
  }

  async function makeProject(f: Fixture) {
    const project = await projectsRepo.create(db, f.ownerUid, `cap-${newId()}`);
    expect(project).not.toBeNull();
    expect(await projectsRepo.moveSession(db, f.ownerUid, f.sessionId, project!.id)).not.toBeNull();
    return project!;
  }

  async function fillProject(f: Fixture, projectId: string, count = 80) {
    await db.insert(schema.attachments).values(Array.from({ length: count }, (_, index) => ({
      id: newId(),
      sessionId: f.sessionId,
      userId: f.ownerUid,
      projectId,
      name: `seed-${index}.txt`,
      size: 1,
      r2Key: `users/${f.ownerUid}/sessions/${f.sessionId}/seed/${index}`,
      contentType: "text/plain",
      contentTypeDeclared: true,
      uploadStatus: "pending" as const,
    })));
    expect((await projectFileUsage(db, f.ownerUid, projectId)).used).toBe(count);
  }

  async function seedFailedOrdinaryAttachment(f: Fixture, name: string) {
    const id = newId();
    const key = `users/${f.ownerUid}/sessions/${f.sessionId}/uploads/${id}`;
    await db.insert(schema.attachments).values({
      id,
      sessionId: f.sessionId,
      userId: f.ownerUid,
      name,
      size: 1,
      r2Key: key,
      contentType: "text/plain",
      contentTypeDeclared: true,
      uploadStatus: "failed",
      actualBytes: null,
      actualContentType: null,
      finalizedAt: null,
    });
    return { id, key };
  }

  function registrar(f: Fixture): CollabArtifactRegistrar {
    return new CollabArtifactRegistrar({
      db,
      storage: f.storage,
      authorization: createCollabArtifactAuthorizationPort(),
      workspaceDir: async () => {
        throw new Error("content-based registrar test must not resolve a workspace");
      },
      reservationStore: (tx) => new StorageReservationStore(tx, {
        now: () => NOW,
        storageBytes: 100,
        uploads: { count: 80, windowHours: 24 },
      }),
    });
  }

  async function failedArtifactAttempt(f: Fixture, idempotencyKey = "artifact-attempt-orphan") {
    const originalPut = f.storage.put;
    // Arm the failure for the bytes this seed writes (its key is only known at
    // put time); a global counter would race the mounted sweep scheduler.
    f.storage.put = async (key, _body, putOptions) => {
      f.controls.failDeleteKeys.add(key);
      return originalPut(key, Buffer.from("bbbb", "utf8"), putOptions);
    };
    const input = {
      actorUserId: f.guestUid,
      ownerUserId: f.ownerUid,
      sessionId: f.sessionId,
      name: "orphan.txt",
      contentType: "text/plain",
      content: Buffer.from("aaaa", "utf8"),
      idempotencyKey,
    };
    await expect(registrar(f).register(input)).rejects.toMatchObject({ code: "artifact_changed" });
    const rows = await db.$client<Array<{
      id: string;
      r2_key: string;
      status: string;
      attempt_reservation_id: string;
    }>>`
      SELECT id, r2_key, status, meta->>'attemptReservationId' AS attempt_reservation_id
        FROM workspace_objects
       WHERE session_id = ${f.sessionId} AND kind = 'artifact'
         AND meta->>'idempotencyKey' = ${idempotencyKey}`;
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ status: "pending" });
    const attemptReservationId = rows[0]!.attempt_reservation_id;
    expect(attemptReservationId).toMatch(/:collab-attempt:1$/);
    const key = rows[0]!.r2_key;
    expect(await db.$client`SELECT state, object_id FROM storage_reservations WHERE id = ${attemptReservationId}`)
      .toEqual([{ state: "released", object_id: key }]);
    const actual = await adapter.head(key);
    expect(actual).not.toBeNull();
    expect(actual!.metadata).toMatchObject({
      "ovid-collab-artifact": rows[0]!.id,
      "ovid-collab-attempt": attemptReservationId,
    });
    return {
      input,
      originalPut,
      artifactId: rows[0]!.id,
      key,
      attemptReservationId,
    };
  }

  async function attemptCandidateFor(
    f: Fixture,
    seed: Awaited<ReturnType<typeof failedArtifactAttempt>>,
  ) {
    const page = await f.objects.listOrphanCandidates(100);
    const candidate = page.rows.find((row) =>
      row.kind === "artifact_attempt" && row.id === seed.artifactId &&
      row.attemptReservationId === seed.attemptReservationId);
    if (candidate?.kind !== "artifact_attempt") {
      throw new Error("canonical artifact attempt candidate was not discovered");
    }
    return candidate;
  }

  function attemptLockFixture(attemptIoDeadlineMs = 15_000) {
    const artifactId = newId();
    const sessionId = newId();
    const key = `users/host/artifacts/${sessionId}/${artifactId}-attempt-1-${"a".repeat(16)}-orphan.txt`;
    const candidate = {
      kind: "artifact_attempt" as const,
      id: artifactId,
      sessionId,
      ownerUid: "host",
      actorUid: "guest",
      key,
      attempt: 1,
      attemptReservationId: `${artifactId}:collab-attempt:1`,
      declaredBytes: 4,
      createdAt: NOW,
    };
    const artifact = {
      id: artifactId,
      session_id: sessionId,
      owner_uid: "host",
      creator_uid: "guest",
      meta: { name: "orphan.txt", attempt: 1, attemptReservationId: candidate.attemptReservationId },
      bytes: 4,
      sha256: "a".repeat(64),
      r2_key: key,
      content_type: "text/plain",
      status: "pending" as "pending" | "active" | "deleted" | "rowless",
      reservation_state: null,
      created_at: NOW,
    };
    const reservation = {
      id: candidate.attemptReservationId,
      actor_user_id: "guest",
      owner_user_id: "host",
      session_id: sessionId,
      object_id: key,
      declared_bytes: 4,
      actual_bytes: null,
      actual_content_type: null,
      etag: null,
      state: "released" as "reserved" | "finalized" | "released",
    };
    let activeTransactions = 0;
    let maxActiveTransactions = 0;
    let transactions = 0;
    let reservationMissing = false;
    let sessionDeletedAt: Date | null = null;
    const statements: string[] = [];
    const fakeDb = {
      transaction: async <T>(callback: (tx: Db) => Promise<T>): Promise<T> => {
        activeTransactions += 1;
        maxActiveTransactions = Math.max(maxActiveTransactions, activeTransactions);
        transactions += 1;
        try {
          return await callback(fakeDb as unknown as Db);
        } finally {
          activeTransactions -= 1;
        }
      },
      execute: async (statement: unknown) => {
        expect(activeTransactions).toBe(1);
        const text = JSON.stringify(statement);
        statements.push(text);
        if (text.includes("SET LOCAL") || text.includes("pg_advisory_xact_lock")) return [];
        if (text.includes("FROM sessions")) return [{ deleted_at: sessionDeletedAt }];
        if (text.includes("FROM account_deletions")) return [];
        if (text.includes("FROM workspace_objects object")) {
          return artifact.status === "rowless" ? [] : [{ ...artifact }];
        }
        if (text.includes("FROM storage_reservations")) {
          return reservationMissing ? [] : [{ ...reservation }];
        }
        throw new Error("unexpected transactional fake query");
      },
    };
    return {
      candidate,
      artifact,
      reservation,
      store: createCollabObjectStore(fakeDb as unknown as Db, { attemptIoDeadlineMs }),
      activeTransactions: () => activeTransactions,
      maxActiveTransactions: () => maxActiveTransactions,
      transactions: () => transactions,
      statements,
      markReservationMissing: () => { reservationMissing = true; },
      markSessionDeleted: () => { sessionDeletedAt = NOW; },
    };
  }

  it("mounts through buildGateway and performs create → real HTTP signed PUT → HEAD finalize → member mint with exact-once host/sender accounting", async () => {
    const f = await fixture();
    const service = new CollabObjectService(f.deps);
    await expect(service.authorizeSessionObject({
      sessionId: f.sessionId, objectOwnerUid: f.ownerUid, viewerUid: f.ownerUid,
    })).resolves.toBe("owner");
    await expect(service.authorizeSessionObject({
      sessionId: f.sessionId, objectOwnerUid: f.ownerUid, viewerUid: f.guestUid,
    })).resolves.toBe("member");
    const body = createBody("upload-once");
    const first = await f.app.inject({
      method: "POST", url: `/chat/${f.token}/attachments`, headers: headers(f.guestUid), payload: body,
    });
    const replay = await f.app.inject({
      method: "POST", url: `/chat/${f.token}/attachments`, headers: headers(f.guestUid), payload: body,
    });
    expect(first.statusCode).toBe(201);
    expect(replay.statusCode).toBe(201);
    const ticket = first.json() as CollabAttachmentTicket;
    expect(replay.json().attachmentId).toBe(ticket.attachmentId);
    expect(ticket).toMatchObject({
      schemaVersion: 1,
      contentType: "text/plain",
      requiredHeaders: { "Content-Type": "text/plain" },
      uploadHeaders: { "Content-Type": "text/plain" },
    });
    expect(first.headers["cache-control"]).toBe("private, no-store");
    const [pending] = await attachments.getForSession(db, f.sessionId, [ticket.attachmentId]);
    expect(pending).toMatchObject({
      userId: f.ownerUid,
      uploadStatus: "pending",
      r2Key: `users/${f.ownerUid}/sessions/${f.sessionId}/uploads/${ticket.attachmentId}`,
    });
    expect((await counters(f.ownerUid, f.guestUid)).storageRows)
      .toEqual([{ used_bytes: 0, reserved_bytes: 5 }]);

    const uploaded = await putTicket(ticket, "hello");
    expect(uploaded.status).toBe(200);
    expect(signedPuts.uploads.at(-1)).toEqual({
      key: pending!.r2Key,
      contentType: "text/plain",
      bytes: 5,
    });
    const finalized = await finalizeUpload(f, f.guestUid, ticket.attachmentId);
    const finalizedReplay = await finalizeUpload(f, f.guestUid, ticket.attachmentId);
    expect(finalized.statusCode).toBe(200);
    expect(finalizedReplay.json()).toEqual(finalized.json());
    expect(finalized.json()).toEqual({
      schemaVersion: 1,
      attachmentId: ticket.attachmentId,
      status: "ready",
      size: 5,
      contentType: "text/plain",
    });
    f.controls.failAfterFinalize = true;
    const ambiguousReplay = await finalizeUpload(f, f.guestUid, ticket.attachmentId);
    expect(ambiguousReplay.statusCode).toBe(200);
    expect(ambiguousReplay.json()).toEqual(finalized.json());
    expect(await adapter.head(pending!.r2Key)).not.toBeNull();
    expect(await counters(f.ownerUid, f.guestUid)).toEqual({
      storageRows: [{ used_bytes: 5, reserved_bytes: 0 }],
      uploadRows: [{ used_uploads: 1, reserved_uploads: 0 }],
    });
    expect(await db.$client`SELECT count(*)::int AS count FROM storage_reservations WHERE object_id = ${ticket.attachmentId}`)
      .toEqual([{ count: 1 }]);

    const listed = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/attachments`, headers: headers(f.guestUid),
    });
    expect(listed.statusCode).toBe(200);
    expect(listed.json()).toMatchObject({
      schemaVersion: 1,
      items: [{ attachmentId: ticket.attachmentId, sizeBytes: 5, status: "ready" }],
      nextCursor: null,
    });
    expect(JSON.stringify(listed.json())).not.toContain(pending!.r2Key);
    const mint = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/attachments/${ticket.attachmentId}/url`, headers: headers(f.guestUid),
    });
    expect(mint.statusCode).toBe(200);
    expect(mint.json()).toMatchObject({ schemaVersion: 1, expiresAt: "2026-10-25T12:05:00.000Z" });
    expect(f.mintKeys).toEqual([pending!.r2Key]);
    const denied = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/attachments/${ticket.attachmentId}/url`, headers: headers(f.strangerUid),
    });
    expect(denied.statusCode).toBe(403);
    expect(f.mintKeys).toHaveLength(1);
    expect((await createUpload(f, f.guestUid, "upload-once", { name: "changed.txt" })).statusCode).toBe(409);
    expect((await createUpload(f, f.guestUid, "forged", { ownerUserId: f.guestUid })).statusCode).toBe(400);
  });

  it("reuses one pending identity after transient signer failure without duplicate row or reservation", async () => {
    const f = await fixture({ failPresign: 1 });
    const failed = await createUpload(f, f.guestUid, "signer-retry");
    expect(failed.statusCode).toBe(503);
    expect(failed.json().uploadUrl).toBeUndefined();
    const [pending] = await attachments.getForSession(db, f.sessionId);
    expect(pending).toMatchObject({ uploadStatus: "pending", userId: f.ownerUid });
    const retry = await createUpload(f, f.guestUid, "signer-retry");
    expect(retry.statusCode).toBe(201);
    expect(retry.json().attachmentId).toBe(pending!.id);
    expect(await attachments.getForSession(db, f.sessionId)).toHaveLength(1);
    expect(await db.$client`SELECT count(*)::int AS count FROM storage_reservations WHERE object_id = ${pending!.id}`)
      .toEqual([{ count: 1 }]);
    expect((await counters(f.ownerUid, f.guestUid)).storageRows)
      .toEqual([{ used_bytes: 0, reserved_bytes: 5 }]);
  });

  it("releases pending HEAD failures and deletes the failed host row so project slots are reclaimed", async () => {
    const f = await fixture();
    const project = await makeProject(f);
    const created = await createUpload(f, f.guestUid, "wrong-size");
    const id = created.json().attachmentId as string;
    const stored = await putDirect(f, id, "four");
    expect((await projectFileUsage(db, f.ownerUid, project.id)).used).toBe(1);
    const response = await finalizeUpload(f, f.guestUid, id);
    expect(response.statusCode).toBe(409);
    expect(response.json().code).toBe("attachment_size_mismatch");
    expect(await attachments.getForSession(db, f.sessionId, [id])).toHaveLength(0);
    expect(await adapter.head(stored.r2Key)).toBeNull();
    expect((await projectFileUsage(db, f.ownerUid, project.id)).used).toBe(0);
    expect(await counters(f.ownerUid, f.guestUid)).toEqual({
      storageRows: [{ used_bytes: 0, reserved_bytes: 0 }],
      uploadRows: [{ used_uploads: 0, reserved_uploads: 0 }],
    });
    const retry = await finalizeUpload(f, f.guestUid, id);
    expect(retry.statusCode).toBe(404);
    expect(retry.json().code).toBe("object_not_found");
    expect((await projectFileUsage(db, f.ownerUid, project.id)).used).toBe(0);
  });

  it("maps project_file_limit to HTTP 409 before reservation/signing, never 413", async () => {
    const f = await fixture();
    const project = await makeProject(f);
    await fillProject(f, project.id);
    const beforeSigns = f.signCalls.length;
    const response = await createUpload(f, f.guestUid, "project-full");
    expect(response.statusCode).toBe(409);
    expect(response.statusCode).not.toBe(413);
    expect(response.json()).toMatchObject({ schemaVersion: 1, code: "project_file_limit" });
    expect(f.signCalls).toHaveLength(beforeSigns);
    expect(f.putCalls).toHaveLength(0);
    expect(await db.$client`SELECT count(*)::int AS count FROM storage_reservations WHERE session_id = ${f.sessionId}`)
      .toEqual([{ count: 0 }]);
    expect((await projectFileUsage(db, f.ownerUid, project.id)).used).toBe(80);
  });

  it("rolls back ready and charge on generic late settlement failure, with no downloadable unsettled-ready row", async () => {
    const f = await fixture();
    const created = await createUpload(f, f.guestUid, "late-finalize-failure");
    const id = created.json().attachmentId as string;
    await putDirect(f, id, "hello");
    f.controls.failAfterFinalize = true;
    const response = await finalizeUpload(f, f.guestUid, id);
    expect(response.statusCode).toBe(500);
    expect(await attachments.getForSession(db, f.sessionId, [id])).toHaveLength(0);
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${id}`)
      .toEqual([{ state: "released" }]);
    expect(await counters(f.ownerUid, f.guestUid)).toEqual({
      storageRows: [{ used_bytes: 0, reserved_bytes: 0 }],
      uploadRows: [{ used_uploads: 0, reserved_uploads: 0 }],
    });
    const listed = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/attachments`, headers: headers(f.guestUid),
    });
    expect(listed.json().items).toEqual([]);
    const mint = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/attachments/${id}/url`, headers: headers(f.guestUid),
    });
    expect(mint.statusCode).toBe(404);
    expect(f.mintKeys).toHaveLength(0);
  });

  it("keeps cleanup retryable after release and byte-delete failures", async () => {
    const releaseFailure = await fixture();
    const first = await createUpload(releaseFailure, releaseFailure.guestUid, "release-failure");
    const firstId = first.json().attachmentId as string;
    const firstStored = await putDirect(releaseFailure, firstId, "four");
    releaseFailure.controls.failRelease = 1;
    const failed = await finalizeUpload(releaseFailure, releaseFailure.guestUid, firstId);
    expect(failed.statusCode).toBe(503);
    expect(failed.json().code).toBe("object_cleanup_required");
    expect(await adapter.head(firstStored.r2Key)).not.toBeNull();
    expect((await attachments.getForSession(db, releaseFailure.sessionId, [firstId]))[0])
      .toMatchObject({ uploadStatus: "failed" });
    const retried = await finalizeUpload(releaseFailure, releaseFailure.guestUid, firstId);
    expect(retried.statusCode).toBe(409);
    expect(retried.json().code).toBe("attachment_size_mismatch");
    expect(await attachments.getForSession(db, releaseFailure.sessionId, [firstId])).toHaveLength(0);
    expect(await adapter.head(firstStored.r2Key)).toBeNull();

    const deleteFailure = await fixture();
    const second = await createUpload(deleteFailure, deleteFailure.guestUid, "delete-failure");
    const secondId = second.json().attachmentId as string;
    const secondStored = await putDirect(deleteFailure, secondId, "four");
    deleteFailure.controls.failDelete = 1;
    const deleteFailed = await finalizeUpload(deleteFailure, deleteFailure.guestUid, secondId);
    expect(deleteFailed.statusCode).toBe(503);
    expect(deleteFailed.json().code).toBe("object_cleanup_required");
    expect(await adapter.head(secondStored.r2Key)).not.toBeNull();
    const deleteRetried = await finalizeUpload(deleteFailure, deleteFailure.guestUid, secondId);
    expect(deleteRetried.statusCode).toBe(409);
    expect(deleteRetried.json().code).toBe("attachment_size_mismatch");
    expect(await attachments.getForSession(db, deleteFailure.sessionId, [secondId])).toHaveLength(0);
    expect(await adapter.head(secondStored.r2Key)).toBeNull();
  });

  it("serializes a finalize scheduled after create's initial read and reconciles the late PUT", async () => {
    const f = await fixture();
    const created = await createUpload(f, f.guestUid, "race-after-read");
    const ticket = created.json() as CollabAttachmentTicket;
    expect((await putTicket(ticket, "four")).status).toBe(200);

    const originalGet = f.objects.getAttachment;
    const initialRead = deferred();
    const allowInitialRead = deferred();
    let reads = 0;
    f.objects.getAttachment = async (input) => {
      const row = await originalGet(input);
      reads += 1;
      if (reads === 1) {
        initialRead.resolve();
        await allowInitialRead.promise;
      }
      return row;
    };
    const retryPromise = createUpload(f, f.guestUid, "race-after-read");
    await initialRead.promise;

    const originalLock = f.objects.withAttachmentLock;
    const finalizeStarted = deferred();
    f.objects.withAttachmentLock = async (attachmentId, fn) => {
      finalizeStarted.resolve();
      return originalLock(attachmentId, fn);
    };
    const finalizePromise = finalizeUpload(f, f.guestUid, ticket.attachmentId);
    await finalizeStarted.promise;
    await yieldToRoutes();
    // The finalizer has really been scheduled, but cannot read while create's
    // post-read transaction still owns the per-attachment lock.
    expect(reads).toBe(1);
    allowInitialRead.resolve();
    expect((await retryPromise).statusCode).toBe(201);
    const finalized = await finalizePromise;
    expect(finalized.statusCode).toBe(409);
    expect(finalized.json().code).toBe("attachment_size_mismatch");

    const late = await putTicket(ticket, "hello");
    expect(late.status).toBe(200);
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${ticket.attachmentId}`)
      .toEqual([{ state: "released" }]);
    const key = `users/${f.ownerUid}/sessions/${f.sessionId}/uploads/${ticket.attachmentId}`;
    expect(await adapter.head(key)).not.toBeNull();
    const swept = await reconcileCollabObjectOrphans(f.deps);
    expect(swept.failed).toBe(0);
    expect(await adapter.head(key)).toBeNull();
    expect((await f.app.inject({
      method: "GET", url: `/chat/${f.token}/attachments/${ticket.attachmentId}/url`, headers: headers(f.guestUid),
    })).statusCode).toBe(404);
    expect(f.mintKeys).toHaveLength(0);
  });

  it("blocks a competing finalize scheduled inside the signing fence before any stale read", async () => {
    const f = await fixture();
    const created = await createUpload(f, f.guestUid, "race-inside-signing");
    const ticket = created.json() as CollabAttachmentTicket;
    expect((await putTicket(ticket, "four")).status).toBe(200);

    const originalFence = f.objects.withAttachmentSigningFence;
    const signing = deferred();
    const allowSigning = deferred();
    f.objects.withAttachmentSigningFence = async (input) => originalFence({
      ...input,
      sign: async () => {
        const url = await input.sign();
        signing.resolve();
        await allowSigning.promise;
        return url;
      },
    });
    const retryPromise = createUpload(f, f.guestUid, "race-inside-signing");
    await signing.promise;
    const signaturesWhileLocked = f.signCalls.length;

    const originalGet = f.objects.getAttachment;
    const originalLock = f.objects.withAttachmentLock;
    const finalizeStarted = deferred();
    let finalizeRead = false;
    f.objects.getAttachment = async (input) => {
      finalizeRead = true;
      return originalGet(input);
    };
    f.objects.withAttachmentLock = async (attachmentId, fn) => {
      finalizeStarted.resolve();
      return originalLock(attachmentId, fn);
    };
    const finalizePromise = finalizeUpload(f, f.guestUid, ticket.attachmentId);
    await finalizeStarted.promise;
    await yieldToRoutes();
    expect(finalizeRead).toBe(false);
    expect(f.signCalls).toHaveLength(signaturesWhileLocked);

    allowSigning.resolve();
    expect((await retryPromise).statusCode).toBe(201);
    expect((await finalizePromise).statusCode).toBe(409);
    expect(finalizeRead).toBe(true);
    expect(f.signCalls).toHaveLength(signaturesWhileLocked);
  });

  it("blocks create retry inside finalization until settled state prevents another signature", async () => {
    const f = await fixture();
    const created = await createUpload(f, f.guestUid, "race-inside-finalize");
    const ticket = created.json() as CollabAttachmentTicket;
    expect((await putTicket(ticket, "hello")).status).toBe(200);

    const finalizing = deferred();
    const allowFinalize = deferred();
    f.controls.pauseFinalize = {
      gate: allowFinalize.promise,
      entered: () => finalizing.resolve(),
    };
    const finalizePromise = finalizeUpload(f, f.guestUid, ticket.attachmentId);
    await finalizing.promise;

    const originalGet = f.objects.getAttachment;
    const originalLock = f.objects.withAttachmentLock;
    const createStarted = deferred();
    let createRead = false;
    f.objects.getAttachment = async (input) => {
      createRead = true;
      return originalGet(input);
    };
    f.objects.withAttachmentLock = async (attachmentId, fn) => {
      createStarted.resolve();
      return originalLock(attachmentId, fn);
    };
    const signaturesBeforeRetry = f.signCalls.length;
    const retryPromise = createUpload(f, f.guestUid, "race-inside-finalize");
    await createStarted.promise;
    await yieldToRoutes();
    expect(createRead).toBe(false);
    expect(f.signCalls).toHaveLength(signaturesBeforeRetry);

    allowFinalize.resolve();
    expect((await finalizePromise).statusCode).toBe(200);
    const retry = await retryPromise;
    expect(retry.statusCode).toBe(409);
    expect(retry.json().code).toBe("attachment_changed");
    expect(createRead).toBe(true);
    expect(f.signCalls).toHaveLength(signaturesBeforeRetry);
    expect((await counters(f.ownerUid, f.guestUid)).storageRows)
      .toEqual([{ used_bytes: 5, reserved_bytes: 0 }]);
  });

  it("runs the production scheduler without overlap and aborts a blocked pass on close", async () => {
    const productionIndex = await readFile(new URL("../index.ts", import.meta.url), "utf8");
    expect(productionIndex).toMatch(/orphanSweepMs:\s*30_000/);

    const firstGate = deferred();
    const firstEntered = deferred();
    const f = await fixture({
      orphanSweepMs: 5,
      recoveryDeadlineMs: 10_000,
      pauseNextSweep: {
        gate: firstGate.promise,
        entered: () => firstEntered.resolve(),
      },
    });
    await firstEntered.promise;
    expect(f.sweepCalls).toEqual([50]);
    await delay(20);
    expect(f.sweepCalls).toHaveLength(1);

    const secondGate = deferred();
    const secondEntered = deferred();
    f.controls.pauseNextSweep = {
      gate: secondGate.promise,
      entered: () => secondEntered.resolve(),
    };
    firstGate.resolve();
    await secondEntered.promise;
    expect(f.sweepCalls).toEqual([50, 50]);

    let closed = false;
    const closing = f.app.close().then(() => { closed = true; });
    const closeVerdict = await Promise.race([
      closing.then(() => "closed" as const),
      delay(100).then(() => "timeout" as const),
    ]);
    // Close must cancel the overall pass, not wait for this otherwise-unreleased
    // cleanup-port gate or for the much longer configured deadline.
    secondGate.resolve();
    await closing;
    expect(closeVerdict).toBe("closed");
    expect(closed).toBe(true);
    expect(f.sweepCalls).toHaveLength(2);
    await delay(20);
    expect(f.sweepCalls).toHaveLength(2);
    const index = built.indexOf(f.app);
    if (index >= 0) built.splice(index, 1);
  });

  it("reconciles late HEAD loss/mutation after readiness and removes finalized charges before any later mint", async () => {
    const missing = await fixture();
    const first = await createUpload(missing, missing.guestUid, "ready-missing");
    const firstId = first.json().attachmentId as string;
    const firstStored = await putDirect(missing, firstId, "hello");
    expect((await finalizeUpload(missing, missing.guestUid, firstId)).statusCode).toBe(200);
    await adapter.delete(firstStored.r2Key);
    const lost = await finalizeUpload(missing, missing.guestUid, firstId);
    expect(lost.statusCode).toBe(409);
    expect(lost.json().code).toBe("attachment_not_uploaded");
    expect(await counters(missing.ownerUid, missing.guestUid)).toEqual({
      storageRows: [{ used_bytes: 0, reserved_bytes: 0 }],
      // Canonical deletion retains the successful-upload rate-window fact.
      uploadRows: [{ used_uploads: 1, reserved_uploads: 0 }],
    });
    expect(await attachments.getForSession(db, missing.sessionId, [firstId])).toHaveLength(0);

    const changed = await fixture();
    const second = await createUpload(changed, changed.guestUid, "ready-changed");
    const secondId = second.json().attachmentId as string;
    const secondStored = await putDirect(changed, secondId, "hello");
    expect((await finalizeUpload(changed, changed.guestUid, secondId)).statusCode).toBe(200);
    await changed.storage.put(secondStored.r2Key, Buffer.from("changed", "utf8"), { contentType: "text/plain" });
    const mint = await changed.app.inject({
      method: "GET", url: `/chat/${changed.token}/attachments/${secondId}/url`, headers: headers(changed.guestUid),
    });
    expect(mint.statusCode).toBe(409);
    expect(mint.json().code).toBe("attachment_changed");
    expect(changed.mintKeys).toHaveLength(0);
    expect(await counters(changed.ownerUid, changed.guestUid)).toEqual({
      storageRows: [{ used_bytes: 0, reserved_bytes: 0 }],
      uploadRows: [{ used_uploads: 1, reserved_uploads: 0 }],
    });
    expect(await attachments.getForSession(db, changed.sessionId, [secondId])).toHaveLength(0);
    expect(await adapter.head(secondStored.r2Key)).toBeNull();
  });

  it("keeps a failed tombstone after debit failure and reconciles the finalized charge on the next sweep", async () => {
    const f = await fixture();
    const created = await createUpload(f, f.guestUid, "debit-retry");
    const id = created.json().attachmentId as string;
    const stored = await putDirect(f, id, "hello");
    expect((await finalizeUpload(f, f.guestUid, id)).statusCode).toBe(200);
    await adapter.delete(stored.r2Key);
    f.controls.failDebit = 1;
    const failed = await finalizeUpload(f, f.guestUid, id);
    expect(failed.statusCode).toBe(503);
    expect(failed.json().code).toBe("object_cleanup_required");
    expect((await attachments.getForSession(db, f.sessionId, [id]))[0])
      .toMatchObject({ uploadStatus: "failed" });
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${id}`)
      .toEqual([{ state: "finalized" }]);
    expect((await counters(f.ownerUid, f.guestUid)).storageRows)
      .toEqual([{ used_bytes: 5, reserved_bytes: 0 }]);
    const mint = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/attachments/${id}/url`, headers: headers(f.guestUid),
    });
    expect(mint.statusCode).toBe(404);
    expect(f.mintKeys).toHaveLength(0);

    const swept = await reconcileCollabObjectOrphans(f.deps);
    expect(swept.failed).toBe(0);
    expect(await attachments.getForSession(db, f.sessionId, [id])).toHaveLength(0);
    expect(await counters(f.ownerUid, f.guestUid)).toEqual({
      storageRows: [{ used_bytes: 0, reserved_bytes: 0 }],
      uploadRows: [{ used_uploads: 1, reserved_uploads: 0 }],
    });
  });

  it("serializes concurrent host reservations independently of the sender upload window", async () => {
    const capped = await fixture({ storageBytes: 100, uploads: 80 });
    const results = await Promise.all([
      createUpload(capped, capped.guestUid, "cap-a", { size: 60 }),
      createUpload(capped, capped.guestUid, "cap-b", { size: 60 }),
    ]);
    expect(results.map((response) => response.statusCode).sort()).toEqual([201, 409]);
    expect(results.find((response) => response.statusCode === 409)!.json().code)
      .toBe("storage_quota_exceeded");
    expect((await counters(capped.ownerUid, capped.guestUid)).storageRows)
      .toEqual([{ used_bytes: 0, reserved_bytes: 60 }]);

    const limited = await fixture({ storageBytes: 100, uploads: 2 });
    expect((await createUpload(limited, limited.guestUid, "rate-a", { size: 1 })).statusCode).toBe(201);
    expect((await createUpload(limited, limited.guestUid, "rate-b", { size: 1 })).statusCode).toBe(201);
    expect((await createUpload(limited, limited.guestUid, "rate-c", { size: 1 })).statusCode).toBe(429);
    expect((await createUpload(limited, limited.ownerUid, "host-independent", { size: 1 })).statusCode).toBe(201);
    expect((await counters(limited.ownerUid, limited.guestUid)).storageRows)
      .toEqual([{ used_bytes: 0, reserved_bytes: 3 }]);
  });

  it("discovers and reconciles a pending released artifact attempt using exact attempt metadata", async () => {
    const f = await fixture();
    const seed = await failedArtifactAttempt(f);
    expect((await f.objects.listOrphanCandidates(1)).rows).toHaveLength(1);
    const candidates = (await f.objects.listOrphanCandidates(100)).rows;
    const candidate = candidates.find((row) =>
      row.kind === "artifact_attempt" && row.id === seed.artifactId &&
      row.attemptReservationId === seed.attemptReservationId);
    expect(candidate).toMatchObject({
      kind: "artifact_attempt",
      id: seed.artifactId,
      key: seed.key,
      actorUid: f.guestUid,
      attempt: 1,
      attemptReservationId: seed.attemptReservationId,
      declaredBytes: 4,
    });

    const swept = await reconcileCollabObjectOrphans(f.deps);
    expect(swept.failed).toBe(0);
    expect(await adapter.head(seed.key)).toBeNull();
    const [row] = await db.$client`SELECT status FROM workspace_objects WHERE id = ${seed.artifactId}`;
    expect(row).toMatchObject({ status: "pending" });
    const deleteCount = f.deleteCalls.length;
    const repeated = await reconcileCollabObjectOrphans(f.deps);
    expect(repeated.failed).toBe(0);
    expect(f.deleteCalls).toHaveLength(deleteCount);
  });

  it("deletes only older released attempts and preserves the newer immutable active key", async () => {
    const f = await fixture();
    const seed = await failedArtifactAttempt(f);
    f.storage.put = seed.originalPut;
    // Keep attempt 1 orphaned when the real registrar's own best-effort retry
    // cleanup runs after publishing attempt 2.
    f.controls.failDelete = 1;
    const recovered = await registrar(f).register(seed.input);
    expect(recovered.id).toBe(seed.artifactId);
    expect(recovered.key).not.toBe(seed.key);
    expect(recovered.key).toContain("-attempt-2-");
    const active = await workspaceObjects.getArtifact(db, recovered.id, f.ownerUid);
    expect(active).toMatchObject({ status: "active", r2Key: recovered.key });
    expect(await adapter.head(seed.key)).not.toBeNull();

    const swept = await reconcileCollabObjectOrphans(f.deps);
    expect(swept.failed).toBe(0);
    // The current-active attempt may occupy one bounded pass as a permanent
    // skip, but its cursor advances and the older genuine orphan is reclaimed.
    expect(swept.skipped).toBe(1);
    expect(await adapter.head(seed.key)).toBeNull();
    expect(await adapter.head(recovered.key)).not.toBeNull();
    expect(f.deleteCalls).not.toContain(recovered.key);
    expect(await workspaceObjects.getArtifact(db, recovered.id, f.ownerUid))
      .toMatchObject({ status: "active", r2Key: recovered.key });
  });

  it("never deletes a pending attempt object with foreign artifact or attempt metadata", async () => {
    const f = await fixture();
    const seed = await failedArtifactAttempt(f);
    await f.storage.put(seed.key, Buffer.from("ffff", "utf8"), {
      contentType: "text/plain",
      metadata: {
        "ovid-collab-artifact": "not-the-canonical-artifact",
        "ovid-collab-attempt": seed.attemptReservationId,
      },
    });
    const swept = await reconcileCollabObjectOrphans(f.deps);
    expect(swept.failed).toBe(0);
    expect(swept.skipped).toBeGreaterThanOrEqual(1);
    expect(await adapter.head(seed.key)).not.toBeNull();
    expect(f.deleteCalls).not.toContain(seed.key);
  });

  it("skips an attempt-only metadata mismatch without deleting or adopting the object", async () => {
    const f = await fixture();
    const seed = await failedArtifactAttempt(f);
    await f.storage.put(seed.key, Buffer.from("ffff", "utf8"), {
      contentType: "text/plain",
      metadata: {
        "ovid-collab-artifact": seed.artifactId,
        "ovid-collab-attempt": `${seed.artifactId}:collab-attempt:999`,
      },
    });
    const swept = await reconcileCollabObjectOrphans(f.deps);
    expect(swept.failed).toBe(0);
    expect(swept.skipped).toBeGreaterThanOrEqual(1);
    expect((await adapter.head(seed.key))?.bytes).toBe(4);
    expect(f.deleteCalls).not.toContain(seed.key);
  });

  it("quarantines an artifact-prefixed unsafe key without aborting discovery or ordinary cleanup", async () => {
    const f = await fixture();
    const ordinary = await seedFailedOrdinaryAttachment(f, "malformed-key-ordinary.txt");
    const seed = await failedArtifactAttempt(f, "malformed-discovery-genuine");
    const malformedReservationId = `${newId()}:collab-attempt:1`;
    const malformedKey = `users/${f.ownerUid}/artifacts/${f.sessionId}/../escape`;
    await db.$client`
      INSERT INTO storage_reservations
        (id, actor_user_id, owner_user_id, session_id, object_id, state,
         declared_bytes, reserved_at, released_at, created_at, updated_at)
      VALUES
        (${malformedReservationId}, ${f.guestUid}, ${f.ownerUid}, ${f.sessionId},
         ${malformedKey}, 'released', 0, ${new Date(1800, 0, 1).toISOString()}::timestamptz,
         ${new Date(1800, 0, 2).toISOString()}::timestamptz, ${new Date(1800, 0, 1).toISOString()}::timestamptz, ${new Date(1800, 0, 2).toISOString()}::timestamptz)`;
    const page = await listCollabObjectArtifactAttempts(db, { limit: 1 });
    expect(page.rows).toEqual([]);
    expect(page.quarantined).toBe(1);
    expect(page.nextCursor).toEqual({
      createdAt: new Date(1800, 0, 1),
      attemptReservationId: malformedReservationId,
    });
    const next = await listCollabObjectArtifactAttempts(db, {
      limit: 1,
      before: page.nextCursor ?? undefined,
    });
    expect(next.rows.map((row) => row.id)).toContain(seed.artifactId);
    expect(next.nextCursor).toBeNull();
    expect(f.deleteCalls).not.toContain(malformedKey);
    const outcome = await reconcileCollabObjectOrphans(f.deps, 2);
    expect(outcome.failed).toBe(0);
    expect(outcome.quarantined).toBe(1);
    expect(outcome.cleaned).toBeGreaterThanOrEqual(1);
    expect(await attachments.getForSession(db, f.sessionId, [ordinary.id])).toHaveLength(0);
  });

  it("quarantines legacy artifact-id attempt intents without guessing or deleting their keys", async () => {
    const f = await fixture();
    const seed = await failedArtifactAttempt(f);
    const candidate = await attemptCandidateFor(f, seed);
    await db.$client`
      UPDATE storage_reservations SET object_id = ${seed.artifactId}
       WHERE id = ${seed.attemptReservationId}`;
    expect((await f.objects.listOrphanCandidates(100)).rows.some((row) =>
      row.kind === "artifact_attempt" && row.attemptReservationId === seed.attemptReservationId,
    )).toBe(false);
    const outcome = await f.objects.cleanupArtifactAttempt({
      candidate,
      inspect: async () => "owned",
      remove: (key) => f.storage.delete(key),
    });
    expect(outcome).toBe("skipped");
    expect(f.deleteCalls).not.toContain(seed.key);
    expect(await adapter.head(seed.key)).not.toBeNull();
  });

  it("rejects a safe noncanonical released attempt key before HEAD or DELETE", async () => {
    const f = await fixture();
    const seed = await failedArtifactAttempt(f, "safe-noncanonical-attempt-key");
    const noncanonicalKey = `users/${f.ownerUid}/artifacts/${f.sessionId}/not-an-immutable-attempt-key`;
    await db.$client`
      UPDATE storage_reservations SET object_id = ${noncanonicalKey}
       WHERE id = ${seed.attemptReservationId}`;
    const candidate = await attemptCandidateFor(f, seed);
    expect(candidate.key).toBe(noncanonicalKey);
    let inspections = 0;
    let removals = 0;
    const outcome = await f.objects.cleanupArtifactAttempt({
      candidate,
      inspect: async () => {
        inspections += 1;
        return "owned";
      },
      remove: async () => { removals += 1; },
    });
    expect(outcome).toBe("skipped");
    expect(inspections).toBe(0);
    expect(removals).toBe(0);
    expect(await adapter.head(seed.key)).not.toBeNull();
  });

  it("excludes live reserved attempts from discovery and skips them again at the destructive fence", async () => {
    const f = await fixture();
    const seed = await failedArtifactAttempt(f);
    const candidate = await attemptCandidateFor(f, seed);
    await db.$client`
      UPDATE storage_reservations
         SET state = 'reserved', released_at = NULL
       WHERE id = ${seed.attemptReservationId}`;
    expect((await f.objects.listOrphanCandidates(100)).rows.some((row) =>
      row.kind === "artifact_attempt" && row.attemptReservationId === seed.attemptReservationId,
    )).toBe(false);
    const outcome = await f.objects.cleanupArtifactAttempt({
      candidate,
      inspect: async () => "owned",
      remove: (key) => f.storage.delete(key),
    });
    expect(outcome).toBe("skipped");
    expect(f.deleteCalls).not.toContain(seed.key);
    expect(await adapter.head(seed.key)).not.toBeNull();
  });

  it("commits each DB claim before HEAD and DELETE and never holds a transaction across storage I/O", async () => {
    const f = attemptLockFixture();
    const calls: string[] = [];
    const outcome = await f.store.cleanupArtifactAttempt({
      candidate: f.candidate,
      inspect: async () => {
        expect(f.activeTransactions()).toBe(0);
        calls.push("head-without-locks");
        return "owned";
      },
      remove: async () => {
        expect(f.activeTransactions()).toBe(0);
        calls.push("delete-without-locks");
      },
    });
    expect(outcome).toBe("cleaned");
    expect(calls).toEqual(["head-without-locks", "delete-without-locks"]);
    expect(f.statements.some((text) => text.includes("714031") && text.includes("host"))).toBe(true);
    expect(f.statements.some((text) => text.includes("714031") && text.includes("guest"))).toBe(true);
    expect(f.statements.some((text) => text.includes("ovid-collab-artifact:host:") && text.includes(f.candidate.id))).toBe(true);
    expect(f.statements.some((text) => text.includes("FROM sessions"))).toBe(true);
    expect(f.statements.some((text) => text.includes("FROM account_deletions"))).toBe(true);
    expect(f.transactions()).toBe(3);
    expect(f.maxActiveTransactions()).toBe(1);
  });

  it("applies one overall deadline to cleanup-port DB work and lock-free storage callbacks", async () => {
    const dbHung = attemptLockFixture();
    const dbStore = createCollabObjectStore({
      transaction: () => new Promise<never>(() => {}),
    } as unknown as Db, { attemptIoDeadlineMs: 5 });
    const dbOutcome = await Promise.race([
      dbStore.cleanupArtifactAttempt({
        candidate: dbHung.candidate,
        inspect: async () => "owned",
        remove: async () => {},
      }).catch((error: unknown) => error),
      delay(100).then(() => "timeout" as const),
    ]);
    expect(dbOutcome).toMatchObject({ code: "storage_timeout" });

    const storageHung = attemptLockFixture(5);
    const storageOutcome = await Promise.race([
      storageHung.store.cleanupArtifactAttempt({
        candidate: storageHung.candidate,
        inspect: async () => {
          expect(storageHung.activeTransactions()).toBe(0);
          return new Promise<never>(() => {});
        },
        remove: async () => {},
      }).catch((error: unknown) => error),
      delay(100).then(() => "timeout" as const),
    ]);
    expect(storageOutcome).toMatchObject({ code: "storage_timeout" });
    expect(storageHung.transactions()).toBe(1);
  });

  it("detects a rowless lifecycle change after HEAD instead of comparing an empty baseline as unchanged", async () => {
    const f = attemptLockFixture();
    f.artifact.status = "rowless";
    let deletes = 0;
    const outcome = await f.store.cleanupArtifactAttempt({
      candidate: f.candidate,
      inspect: async () => {
        f.markSessionDeleted();
        return "owned";
      },
      remove: async () => { deletes += 1; },
    });
    expect(outcome).toBe("skipped");
    expect(deletes).toBe(0);
    expect(f.transactions()).toBe(2);
  });

  it("detects a rowless lifecycle change after DELETE instead of reporting cleaned", async () => {
    const f = attemptLockFixture();
    f.artifact.status = "rowless";
    let deletes = 0;
    const outcome = await f.store.cleanupArtifactAttempt({
      candidate: f.candidate,
      inspect: async () => "owned",
      remove: async () => {
        deletes += 1;
        f.markReservationMissing();
      },
    });
    expect(outcome).toBe("skipped");
    expect(deletes).toBe(1);
    expect(f.transactions()).toBe(3);
  });

  it("rechecks generation after lock-free HEAD and refuses deletion when the attempt became active", async () => {
    const f = attemptLockFixture();
    let deletes = 0;
    const outcome = await f.store.cleanupArtifactAttempt({
      candidate: f.candidate,
      inspect: async () => {
        expect(f.activeTransactions()).toBe(0);
        // The claim transaction has committed and HEAD is being inspected.
        // Becoming active here must be seen by the fresh pre-DELETE fence.
        f.artifact.status = "active";
        return "owned";
      },
      remove: async () => { deletes += 1; },
    });
    expect(outcome).toBe("skipped");
    expect(deletes).toBe(0);
    expect(f.transactions()).toBe(2);
  });

  it("detects a generation transition at the cleanup commit after lock-free DELETE", async () => {
    const f = attemptLockFixture();
    let deletes = 0;
    const outcome = await f.store.cleanupArtifactAttempt({
      candidate: f.candidate,
      inspect: async () => {
        expect(f.activeTransactions()).toBe(0);
        return "owned";
      },
      remove: async () => {
        expect(f.activeTransactions()).toBe(0);
        deletes += 1;
        // A later publication-shaped generation change cannot be undone by a
        // status report. It must at least be detected, never reported cleaned.
        f.artifact.status = "active";
      },
    });
    expect(outcome).toBe("skipped");
    expect(deletes).toBe(1);
    expect(f.transactions()).toBe(3);
  });

  it("releases bounded reserved attempts before orphan discovery through the composed scheduler", async () => {
    const firstGate = deferred();
    const firstEntered = deferred();
    const f = await fixture({
      orphanSweepMs: 5,
      recoveryBatchLimit: 1,
      recoveryDeadlineMs: 10_000,
      recoveryReservedReleaseLimit: 1,
      pauseNextSweep: {
        gate: firstGate.promise,
        entered: () => firstEntered.resolve(),
      },
    });
    await firstEntered.promise;
    const seed = await failedArtifactAttempt(f, "scheduled-reserved-release");
    const attemptReservationIds = [2, 3].map((attempt) => `${seed.artifactId}:collab-attempt:${attempt}`);
    await db.$client`
      INSERT INTO storage_reservations
        (id, actor_user_id, owner_user_id, session_id, object_id, state,
         declared_bytes, reserved_at, created_at, updated_at)
      VALUES
        (${attemptReservationIds[0]}, ${f.guestUid}, ${f.ownerUid}, ${f.sessionId},
         ${"users/not-canonical"}, 'reserved', 2, ${new Date(1800, 0, 1).toISOString()}::timestamptz,
         ${new Date(1800, 0, 1).toISOString()}::timestamptz, ${new Date(1800, 0, 1).toISOString()}::timestamptz),
        (${attemptReservationIds[1]}, ${f.guestUid}, ${f.ownerUid}, ${f.sessionId},
         ${"users/not-canonical"}, 'reserved', 2, ${new Date(1800, 0, 1).toISOString()}::timestamptz,
         ${new Date(1800, 0, 1).toISOString()}::timestamptz, ${new Date(1800, 0, 1).toISOString()}::timestamptz)`;
    // Canonical release subtracts declared_bytes. Model the corresponding
    // nonnegative host reservation before asking it to settle the two rows.
    await db.$client`
      INSERT INTO storage_usage_counters (owner_user_id, used_bytes, reserved_bytes)
      VALUES (${f.ownerUid}, 0, 4)
      ON CONFLICT (owner_user_id) DO UPDATE
      SET reserved_bytes = storage_usage_counters.reserved_bytes + 4`;
    firstGate.resolve();
    await waitFor(async () => {
      const rows = await db.$client`
        SELECT state FROM storage_reservations WHERE id = ANY(${attemptReservationIds})`;
      return rows.length === 2 && rows.every((row) => row.state === "released");
    }, "the mounted scheduler did not drain both reserved attempts");
    const finalReleaseEvent = `reserved-release-result:${seed.artifactId}:0`;
    await waitFor(() => {
      const finalReleaseIndex = f.recoveryEvents.lastIndexOf(finalReleaseEvent);
      return finalReleaseIndex >= 0 &&
        f.recoveryEvents.some((event, index) => event === "orphan-discovery" && index > finalReleaseIndex) &&
        f.attemptOutcomes.some((entry) => entry.id === seed.artifactId);
    }, "reserved release was not followed by attempt discovery/cleanup");
    const remainingResults = f.recoveryEvents
      .filter((event) => event.startsWith("reserved-release-result:"))
      .map((event) => Number(event.split(":").at(-1)));
    expect(remainingResults).toEqual([1, 0]);
    const releaseIndex = f.recoveryEvents.lastIndexOf(finalReleaseEvent);
    const discoveryIndex = f.recoveryEvents.findIndex((event, index) =>
      event === "orphan-discovery" && index > releaseIndex);
    expect(releaseIndex).toBeGreaterThanOrEqual(0);
    expect(discoveryIndex).toBeGreaterThan(releaseIndex);
    expect(f.deleteCalls).not.toContain("users/not-canonical");
    expect((await counters(f.ownerUid, f.guestUid)).storageRows)
      .toEqual([{ used_bytes: 0, reserved_bytes: 0 }]);
    await f.app.close();
    const index = built.indexOf(f.app);
    if (index >= 0) built.splice(index, 1);
  });

  it("advances reserved-group follow-up past eight permanently failing oldest groups to the ninth", async () => {
    const f = await fixture({
      uploads: 80,
      recoveryBatchLimit: 1,
      recoveryDeadlineMs: 10_000,
      recoveryReservedGroupsPerPass: 8,
      recoveryReservedReleaseLimit: 1,
    });
    // Stable group-key order matches the explicitly oldest-to-newest fixture.
    // Two rows in each failing group also catch raw-row cursor reselection.
    const groupSuffix = newId().slice(8);
    const groups = Array.from({ length: 9 }, (_, index) =>
      `${String(index + 1).padStart(8, "0")}${groupSuffix}`);
    const failing = groups.slice(0, 8);
    const ninth = groups[8]!;
    const attempts = groups.flatMap((artifactId, index) =>
      Array.from({ length: index === 8 ? 1 : 2 }, (_, attemptIndex) => ({
        artifactId,
        attempt: attemptIndex + 1,
        reservationId: `${artifactId}:collab-attempt:${attemptIndex + 1}`,
        createdAt: new Date(1800, 0, index * 2 + attemptIndex + 1),
        declaredBytes: index === 8 ? 4 : 0,
      })));
    for (const attempt of attempts) {
      await f.reservationStore.reserve({
        reservationId: attempt.reservationId,
        ownerUserId: f.ownerUid,
        uploaderUserId: f.guestUid,
        sessionId: f.sessionId,
        objectId: `users/${f.ownerUid}/artifacts/${f.sessionId}/${attempt.artifactId}-attempt-${attempt.attempt}-${"a".repeat(16)}-orphan.txt`,
        declaredBytes: attempt.declaredBytes,
      });
      await db.$client`
        UPDATE storage_reservations SET created_at = ${attempt.createdAt.toISOString()}::timestamptz
         WHERE id = ${attempt.reservationId}`;
    }
    expect((await counters(f.ownerUid, f.guestUid)).storageRows)
      .toEqual([{ used_bytes: 0, reserved_bytes: 4 }]);
    const releaseCalls: string[] = [];
    const ninthKey = `users/${f.ownerUid}/artifacts/${f.sessionId}/${ninth}-attempt-1-${"a".repeat(16)}-orphan.txt`;
    await f.storage.put(ninthKey, Buffer.from("bbbb", "utf8"), {
      contentType: "text/plain",
      metadata: {
        "ovid-collab-artifact": ninth,
        "ovid-collab-attempt": `${ninth}:collab-attempt:1`,
      },
    });
    const wrapper: typeof releaseCollabArtifactReservedAttempts = async (input) => {
      releaseCalls.push(input.artifactId);
      if (failing.includes(input.artifactId)) throw new Error("permanently failing reserved group");
      const result = await releaseCollabArtifactReservedAttempts(input);
      f.recoveryEvents.push(`reserved-release-result:${input.artifactId}:${result.remaining}`);
      return result;
    };
    // This wrapper must travel through the real GatewayDeps.collab composition.
    // Rebuild with it rather than placing it only in the local deps object.
    await f.app.close();
    const previousIndex = built.indexOf(f.app);
    if (previousIndex >= 0) built.splice(previousIndex, 1);
    const app = buildGateway({
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      system: stubSystemBus(),
      storage: f.storage,
      clock: () => NOW,
      presignTtlSeconds: 300,
      collab: {
        membership,
        projection: new CollabProjection(db),
        objects: f.objects,
        reservations: f.reservations,
        reservedRelease: wrapper,
        orphanSweepMs: 5,
        recoveryBatchLimit: 1,
        recoveryDeadlineMs: 10_000,
        recoveryReservedGroupsPerPass: 8,
        recoveryReservedReleaseLimit: 1,
      },
    });
    built.push(app);
    await app.ready();
    const ninthReservationId = `${ninth}:collab-attempt:1`;
    const ninthReleasedEvent = `reserved-release-result:${ninth}:0`;
    await waitFor(async () =>
      (await db.$client`SELECT state FROM storage_reservations WHERE id = ${ninthReservationId}`)[0]?.state === "released" &&
      f.recoveryEvents.includes(ninthReleasedEvent),
    "the ninth reserved group was starved by the eight permanently failing oldest groups");
    expect(releaseCalls.slice(0, 9)).toEqual([...failing, ninth]);
    const states = await db.$client`
      SELECT id, state FROM storage_reservations
       WHERE id = ANY(${attempts.map((attempt) => attempt.reservationId)})`;
    expect(states).toHaveLength(17);
    expect(states.filter((row) => row.id !== ninthReservationId)
      .every((row) => row.state === "reserved")).toBe(true);
    expect(states.find((row) => row.id === ninthReservationId))
      .toMatchObject({ state: "released" });
    expect((await counters(f.ownerUid, f.guestUid)).storageRows)
      .toEqual([{ used_bytes: 0, reserved_bytes: 0 }]);
    expect(f.recoveryEvents).toContain(ninthReleasedEvent);
    await app.close();
    const index = built.indexOf(app);
    if (index >= 0) built.splice(index, 1);
  });

  it("periodically rescans from the head and reclaims an old HEAD-null attempt after its late PUT", async () => {
    const firstGate = deferred();
    const firstEntered = deferred();
    const f = await fixture({
      orphanSweepMs: 5,
      orphanRescanMs: 50,
      recoveryBatchLimit: 1,
      recoveryDeadlineMs: 10_000,
      pauseNextSweep: {
        gate: firstGate.promise,
        entered: () => firstEntered.resolve(),
      },
    });
    await firstEntered.promise;
    const old = await failedArtifactAttempt(f, "periodic-old-head-null");
    await db.$client`
      UPDATE storage_reservations SET created_at = ${new Date(1800, 0, 1).toISOString()}::timestamptz
       WHERE id = ${old.attemptReservationId}`;
    await adapter.delete(old.key);

    const newer = [];
    for (const [index, key] of ["periodic-new-a", "periodic-new-b", "periodic-new-c"].entries()) {
      const seed = await failedArtifactAttempt(f, key);
      newer.push(seed);
      await db.$client`
        UPDATE storage_reservations SET created_at = ${new Date(2000, 0, index + 1).toISOString()}::timestamptz
         WHERE id = ${seed.attemptReservationId}`;
    }
    firstGate.resolve();
    await waitFor(
      () => f.attemptOutcomes.some((entry) => entry.id === old.artifactId && entry.outcome === "missing"),
      "the first old HEAD-null cleanup was not observed",
    );

    // The old reservation is now behind the cursor while newer attempts keep
    // later pages non-empty. Only a guaranteed head rescan will revisit it.
    await adapter.put(old.key, Buffer.from("bbbb", "utf8"), {
      contentType: "text/plain",
      metadata: {
        "ovid-collab-artifact": old.artifactId,
        "ovid-collab-attempt": old.attemptReservationId,
      },
    });
    await failedArtifactAttempt(f, "periodic-sustained-new-attempt");
    await waitFor(
      () => f.sweepBefores.some((before) => before !== undefined),
      "the scheduler never advanced to a cursor-based pass",
    );
    await waitFor(async () => {
      if ((await adapter.head(old.key)) !== null) return false;
      return f.sweepBefores.some((before, index) =>
        before === undefined && f.sweepBefores.slice(0, index).some((previous) => previous !== undefined));
    }, "the periodic head rescan did not reclaim the late old PUT");
    expect(newer).toHaveLength(3);
    expect(f.sweepBefores[0]).toBeUndefined();
    await f.app.close();
    const index = built.indexOf(f.app);
    if (index >= 0) built.splice(index, 1);
  });

  it("alternates ordinary and attempt cleanup at limit one under sustained ordinary backlog", async () => {
    const f = await fixture();
    const seed = await failedArtifactAttempt(f);
    const ordinary = await seedFailedOrdinaryAttachment(f, "limit-one-ordinary.txt");
    const ordinarySecond = await seedFailedOrdinaryAttachment(f, "limit-one-second.txt");
    const first = await reconcileCollabObjectOrphans(f.deps, 1, undefined, undefined, 0);
    expect(first.examined).toBe(1);
    expect(first.cleaned).toBe(1);
    expect(await attachments.getForSession(db, f.sessionId, [ordinary.id])).toHaveLength(0);
    expect(await adapter.head(seed.key)).not.toBeNull();
    const second = await reconcileCollabObjectOrphans(f.deps, 1, first.nextCursor ?? undefined, undefined, 1);
    expect(second.examined).toBe(1);
    expect(second.cleaned).toBeGreaterThanOrEqual(1);
    expect(await adapter.head(seed.key)).toBeNull();
    expect(await attachments.getForSession(db, f.sessionId, [ordinarySecond.id])).toHaveLength(1);
    const third = await reconcileCollabObjectOrphans(f.deps, 1, second.nextCursor ?? undefined, undefined, 0);
    expect(third.examined).toBe(1);
    expect(third.cleaned).toBeGreaterThanOrEqual(1);
    expect(await attachments.getForSession(db, f.sessionId, [ordinarySecond.id])).toHaveLength(0);
  });

  it("preserves forward attempt cursor after a forced head scan", async () => {
    let now = 1_000;
    const scheduler = new CollabOrphanSweepScheduler({
      rescanDelayMs: 10,
      now: () => now,
    });
    const first = scheduler.nextPlan(2);
    expect(first.forceHead).toBe(true);
    scheduler.complete(first, {
      createdAt: new Date(1_100),
      attemptReservationId: `${newId()}:collab-attempt:1`,
    });
    const second = scheduler.nextPlan(2);
    expect(second.forceHead).toBe(false);
    const forward = second.attemptCursor;
    expect(forward).toBeDefined();
    scheduler.complete(second, forward ?? null);
    now += 10;
    const head = scheduler.nextPlan(2);
    expect(head.forceHead).toBe(true);
    scheduler.complete(head, null);
    const afterHead = scheduler.nextPlan(2);
    expect(afterHead.forceHead).toBe(false);
    expect(afterHead.attemptCursor).toEqual(forward);
  });

  it("reserves ordinary cleanup progress at the exact page limit with permanent foreign attempts", async () => {
    const f = await fixture();
    const foreign = await failedArtifactAttempt(f, "ordinary-budget-foreign");
    await f.storage.put(foreign.key, Buffer.from("ffff", "utf8"), {
      contentType: "text/plain",
      metadata: {
        "ovid-collab-artifact": foreign.artifactId,
        "ovid-collab-attempt": `${foreign.artifactId}:collab-attempt:999`,
      },
    });
    const firstOrdinary = await seedFailedOrdinaryAttachment(f, "ordinary-one.txt");
    const secondOrdinary = await seedFailedOrdinaryAttachment(f, "ordinary-two.txt");

    const first = await reconcileCollabObjectOrphans(f.deps, 2);
    expect(first).toMatchObject({ examined: 2, cleaned: 1, failed: 0, skipped: 1 });
    expect(await db.$client`SELECT id FROM attachments WHERE id IN (${firstOrdinary.id}, ${secondOrdinary.id})`)
      .toHaveLength(1);
    expect(await adapter.head(foreign.key)).not.toBeNull();

    const second = await reconcileCollabObjectOrphans(f.deps, 2);
    expect(second).toMatchObject({ examined: 2, cleaned: 1, failed: 0, skipped: 1 });
    expect(await db.$client`SELECT id FROM attachments WHERE id IN (${firstOrdinary.id}, ${secondOrdinary.id})`)
      .toHaveLength(0);
    expect(await adapter.head(foreign.key)).not.toBeNull();
  });

  it("deterministically advances bounded pages past permanent skips to the genuine later orphan", async () => {
    const f = await fixture();
    const active = await registrar(f).register({
      actorUserId: f.guestUid,
      ownerUserId: f.ownerUid,
      sessionId: f.sessionId,
      name: "active.txt",
      contentType: "text/plain",
      content: Buffer.from("active", "utf8"),
      idempotencyKey: "active-before-skips",
    });
    const foreign = [];
    for (const key of ["foreign-page-a", "foreign-page-b", "foreign-page-c"]) {
      foreign.push(await failedArtifactAttempt(f, key));
    }
    for (const seed of foreign) {
      await f.storage.put(seed.key, Buffer.from("ffff", "utf8"), {
        contentType: "text/plain",
        metadata: {
          "ovid-collab-artifact": seed.artifactId,
          "ovid-collab-attempt": `${seed.artifactId}:collab-attempt:999`,
        },
      });
    }
    const genuine = await failedArtifactAttempt(f, "genuine-after-skips");

    // Every controlled reservation precedes every earlier suite reservation,
    // regardless of shared fixed NOW or UUID ordering in the same database.
    const activeAttemptId = `${active.id}:collab-attempt:1`;
    await db.$client`
      UPDATE storage_reservations SET created_at = ${new Date(1999, 0, 1).toISOString()}::timestamptz
       WHERE id = ${activeAttemptId}`;
    for (const [index, seed] of foreign.entries()) {
      await db.$client`
        UPDATE storage_reservations SET created_at = ${new Date(2000, 0, index + 1).toISOString()}::timestamptz
         WHERE id = ${seed.attemptReservationId}`;
    }
    await db.$client`
      UPDATE storage_reservations SET created_at = ${new Date(2000, 0, 10).toISOString()}::timestamptz
       WHERE id = ${genuine.attemptReservationId}`;

    const all = await f.objects.listOrphanCandidates(100);
    expect(all.rows.some((row) =>
      row.kind === "artifact_attempt" && row.attemptReservationId === activeAttemptId,
    )).toBe(true);
    const firstPage = await f.objects.listOrphanCandidates(2);
    expect(firstPage.rows.map((row) => row.id)).toEqual([
      active.id,
      foreign[0]!.artifactId,
    ]);
    expect(firstPage.nextCursor).toEqual({
      createdAt: new Date(2000, 0, 1),
      attemptReservationId: foreign[0]!.attemptReservationId,
    });

    const first = await reconcileCollabObjectOrphans(f.deps, 2);
    expect(first).toMatchObject({ examined: 2, cleaned: 0, failed: 0, skipped: 2 });
    expect(first.nextCursor).toEqual(firstPage.nextCursor);
    const secondPage = await f.objects.listOrphanCandidates(2, first.nextCursor ?? undefined);
    expect(secondPage.rows.map((row) => row.id)).toEqual([
      foreign[1]!.artifactId,
      foreign[2]!.artifactId,
    ]);
    expect(secondPage.nextCursor).toEqual({
      createdAt: new Date(2000, 0, 3),
      attemptReservationId: foreign[2]!.attemptReservationId,
    });
    const second = await reconcileCollabObjectOrphans(f.deps, 2, first.nextCursor ?? undefined);
    expect(second).toMatchObject({ examined: 2, cleaned: 0, failed: 0, skipped: 2 });
    expect(second.nextCursor).toEqual(secondPage.nextCursor);

    const thirdPage = await f.objects.listOrphanCandidates(2, second.nextCursor ?? undefined);
    expect(thirdPage.rows.map((row) => row.id)).toEqual([genuine.artifactId]);
    expect(thirdPage.nextCursor).toBeNull();
    const third = await reconcileCollabObjectOrphans(f.deps, 2, second.nextCursor ?? undefined);
    expect(third).toMatchObject({ examined: 1, cleaned: 1, failed: 0, skipped: 0 });
    expect(await adapter.head(genuine.key)).toBeNull();
    expect(await adapter.head(active.key)).not.toBeNull();
    expect(f.deleteCalls).not.toContain(active.key);
    expect(f.sweepCalls).toEqual([100, 2, 2, 2, 2, 2, 2]);
  });

  it("uses the real CollabArtifactRegistrar before member artifact list/read/mint", async () => {
    const f = await fixture();
    const record = await registrar(f).register({
      actorUserId: f.guestUid,
      ownerUserId: f.ownerUid,
      sessionId: f.sessionId,
      name: "answer.txt",
      contentType: "text/plain",
      content: Buffer.from("actual generated artifact", "utf8"),
      idempotencyKey: "real-registrar-integration",
    });
    const stored = await workspaceObjects.getArtifact(db, record.id, f.ownerUid);
    expect(stored).toMatchObject({ userId: f.ownerUid, sessionId: f.sessionId, bytes: record.sizeBytes });
    expect(stored!.meta).toMatchObject({ creatorUserId: f.guestUid });
    expect((await counters(f.ownerUid, f.guestUid)).storageRows)
      .toEqual([{ used_bytes: record.sizeBytes, reserved_bytes: 0 }]);
    const listed = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/artifacts`, headers: headers(f.guestUid),
    });
    expect(listed.statusCode).toBe(200);
    expect(listed.json()).toMatchObject({
      schemaVersion: 1,
      items: [{ artifactId: record.id, name: "answer.txt", sizeBytes: record.sizeBytes }],
    });
    const mint = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/artifacts/${record.id}/url`, headers: headers(f.guestUid),
    });
    expect(mint.statusCode).toBe(200);
    expect(f.mintKeys).toEqual([record.key]);
  });

  it("requires generated-artifact project capacity before PUT/finalization and preserves 409 project_file_limit semantics", async () => {
    const f = await fixture();
    const project = await makeProject(f);
    await fillProject(f, project.id);
    const operation = registrar(f).register({
      actorUserId: f.guestUid,
      ownerUserId: f.ownerUid,
      sessionId: f.sessionId,
      name: "over-cap.txt",
      contentType: "text/plain",
      content: Buffer.from("must not be put", "utf8"),
      idempotencyKey: "artifact-project-cap",
    });
    const error = await operation.then(
      () => { throw new Error("over-cap artifact unexpectedly registered"); },
      (caught: unknown) => caught,
    );
    expect(error).toMatchObject({ code: "project_file_limit" });
    expect(collabArtifactErrorResponse(error)).toMatchObject({
      status: 409,
      code: "project_file_limit",
    });
    expect(collabArtifactErrorResponse(error).status).not.toBe(413);
    expect(f.putCalls).toHaveLength(0);
    expect(f.deleteCalls).toHaveLength(0);
    expect(await db.$client`SELECT count(*)::int AS count FROM storage_reservations WHERE session_id = ${f.sessionId}`)
      .toEqual([{ count: 0 }]);
    expect(await db.$client`SELECT count(*)::int AS count FROM workspace_objects WHERE session_id = ${f.sessionId} AND kind = 'artifact'`)
      .toEqual([{ count: 0 }]);
    expect((await projectFileUsage(db, f.ownerUid, project.id)).used).toBe(80);
  });

  it("rolls back publication and deletes the owned orphan when project capacity closes after the artifact PUT", async () => {
    const f = await fixture();
    const project = await makeProject(f);
    await fillProject(f, project.id, 79);
    let uploadedKey = "";
    const originalPut = f.storage.put;
    f.storage.put = async (key, body, putOptions) => {
      const result = await originalPut(key, body, putOptions);
      uploadedKey = key;
      // Consume the last slot after the pending artifact's initial capacity
      // check but before its publication-time locked backstop.
      await db.insert(schema.attachments).values({
        id: newId(),
        sessionId: f.sessionId,
        userId: f.ownerUid,
        projectId: project.id,
        name: "capacity-race.txt",
        size: 1,
        r2Key: `users/${f.ownerUid}/sessions/${f.sessionId}/seed/capacity-race`,
        contentType: "text/plain",
        contentTypeDeclared: true,
        uploadStatus: "pending",
      });
      return result;
    };
    const operation = registrar(f).register({
      actorUserId: f.guestUid,
      ownerUserId: f.ownerUid,
      sessionId: f.sessionId,
      name: "capacity-race-artifact.txt",
      contentType: "text/plain",
      content: Buffer.from("owned orphan bytes", "utf8"),
      idempotencyKey: "artifact-capacity-race",
    });
    const error = await operation.then(
      () => { throw new Error("capacity-race artifact unexpectedly published"); },
      (caught: unknown) => caught,
    );
    expect(collabArtifactErrorResponse(error)).toMatchObject({
      status: 409,
      code: "project_file_limit",
    });
    expect(uploadedKey).not.toBe("");
    expect(await adapter.head(uploadedKey)).toBeNull();
    const artifactRows = await db.$client`
      SELECT status FROM workspace_objects WHERE session_id = ${f.sessionId} AND kind = 'artifact'`;
    expect(artifactRows).toEqual([{ status: "pending" }]);
    const reservationRows = await db.$client`
      SELECT state, count(*)::int AS count FROM storage_reservations
       WHERE session_id = ${f.sessionId} GROUP BY state`;
    expect(reservationRows).toEqual([{ state: "released", count: 1 }]);
    expect((await counters(f.ownerUid, f.guestUid)).storageRows)
      .toEqual([{ used_bytes: 0, reserved_bytes: 0 }]);
    expect((await projectFileUsage(db, f.ownerUid, project.id)).used).toBe(80);
  });

  it("HEAD-checks artifact mints, forces active content to attachment, and reconciles changed bytes", async () => {
    const f = await fixture();
    const record = await registrar(f).register({
      actorUserId: f.ownerUid,
      ownerUserId: f.ownerUid,
      sessionId: f.sessionId,
      name: "active.html",
      contentType: "text/html",
      content: Buffer.from("<p>inert fixture</p>", "utf8"),
      idempotencyKey: "active-artifact",
    });
    const mint = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/artifacts/${record.id}/url`, headers: headers(f.guestUid),
    });
    expect(mint.statusCode).toBe(200);
    expect(f.mintOptions).toEqual([{
      disposition: "attachment", filename: "active.html", contentType: "text/html",
    }]);
    await f.storage.put(record.key, Buffer.from("changed", "utf8"), { contentType: "text/html" });
    const changed = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/artifacts/${record.id}/url`, headers: headers(f.guestUid),
    });
    expect(changed.statusCode).toBe(409);
    expect(changed.json().code).toBe("artifact_incomplete");
    expect(f.mintKeys).toHaveLength(1);
    expect(await workspaceObjects.getArtifact(db, record.id, f.ownerUid))
      .toMatchObject({ status: "deleted" });
    expect((await counters(f.ownerUid, f.ownerUid)).storageRows)
      .toEqual([{ used_bytes: 0, reserved_bytes: 0 }]);
    expect(await adapter.head(record.key)).toBeNull();
  });

  it("returns artifact_unavailable for a distinct missing HEAD and removes the finalized charge without minting", async () => {
    const f = await fixture();
    const record = await registrar(f).register({
      actorUserId: f.guestUid,
      ownerUserId: f.ownerUid,
      sessionId: f.sessionId,
      name: "missing.txt",
      contentType: "text/plain",
      content: Buffer.from("artifact bytes", "utf8"),
      idempotencyKey: "missing-artifact-head",
    });
    await adapter.delete(record.key);
    const response = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/artifacts/${record.id}/url`, headers: headers(f.guestUid),
    });
    expect(response.statusCode).toBe(404);
    expect(response.json().code).toBe("artifact_unavailable");
    expect(f.mintKeys).toHaveLength(0);
    expect(await workspaceObjects.getArtifact(db, record.id, f.ownerUid))
      .toMatchObject({ status: "deleted" });
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${record.id}`)
      .toEqual([{ state: "released" }]);
    expect((await counters(f.ownerUid, f.guestUid)).storageRows)
      .toEqual([{ used_bytes: 0, reserved_bytes: 0 }]);
  });

  it("fences revoked/closed/deleted access without another artifact mint", async () => {
    const f = await fixture();
    const record = await registrar(f).register({
      actorUserId: f.guestUid,
      ownerUserId: f.ownerUid,
      sessionId: f.sessionId,
      name: "answer.txt",
      contentType: "text/plain",
      content: Buffer.from("artifact", "utf8"),
      idempotencyKey: "fenced-artifact",
    });
    await membership.remove({
      principal: principal(f.ownerUid), token: f.token, participantId: f.guestParticipantId,
    });
    const revoked = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/artifacts/${record.id}/url`, headers: headers(f.guestUid),
    });
    expect(revoked.statusCode).toBe(403);
    expect(f.mintKeys).toHaveLength(0);
    await membership.close({
      principal: principal(f.ownerUid), token: f.token, idempotencyKey: `close-${newId()}`,
    });
    const closed = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/artifacts/${record.id}/url`, headers: headers(f.ownerUid),
    });
    expect(closed.statusCode).toBe(409);
    expect(f.mintKeys).toHaveLength(0);

    const deleted = await fixture();
    const other = await registrar(deleted).register({
      actorUserId: deleted.guestUid,
      ownerUserId: deleted.ownerUid,
      sessionId: deleted.sessionId,
      name: "answer.txt",
      contentType: "text/plain",
      content: Buffer.from("artifact", "utf8"),
      idempotencyKey: "deleted-artifact",
    });
    await db.$client`
      INSERT INTO account_deletions (uid, state, delete_after, record)
      VALUES (${deleted.guestUid}, 'pending', 1, '{"uid":"collab-object-deletion-test"}'::jsonb)`;
    const account = await deleted.app.inject({
      method: "GET", url: `/chat/${deleted.token}/artifacts/${other.id}/url`, headers: headers(deleted.guestUid),
    });
    expect(account.statusCode).toBe(403);
    await sessions.softDelete(db, deleted.sessionId, deleted.ownerUid);
    const session = await deleted.app.inject({
      method: "GET", url: `/chat/${deleted.token}/artifacts/${other.id}/url`, headers: headers(deleted.ownerUid),
    });
    expect(session.statusCode).toBe(403);
    expect(deleted.mintKeys).toHaveLength(0);
  });

  it("keeps size, body, and query validation strict before storage side effects", async () => {
    const f = await fixture();
    const oversized = await createUpload(f, f.guestUid, "too-large", { size: 25_000_001 });
    expect(oversized.statusCode).toBe(400);
    expect(oversized.json().code).toBe("attachment_too_large");
    expect(await db.$client`SELECT count(*)::int AS count FROM storage_reservations WHERE session_id = ${f.sessionId}`)
      .toEqual([{ count: 0 }]);
    const created = await createUpload(f, f.guestUid, "strict-read");
    const id = created.json().attachmentId as string;
    const badFinalize = await f.app.inject({
      method: "POST",
      url: `/chat/${f.token}/attachments/${id}/finalize`,
      headers: headers(f.guestUid),
      payload: { schemaVersion: 1, actualBytes: 0 },
    });
    expect(badFinalize.statusCode).toBe(400);
    const badList = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/attachments?cursor=not-a-uuid`, headers: headers(f.guestUid),
    });
    expect(badList.statusCode).toBe(400);
    const badMint = await f.app.inject({
      method: "GET", url: `/chat/${f.token}/attachments/${id}/url?cache=public`, headers: headers(f.guestUid),
    });
    expect(badMint.statusCode).toBe(400);
    expect(f.mintKeys).toHaveLength(0);
  });

  it("keeps /turns explicitly unavailable without fake admission or attachment materialization claims", async () => {
    const f = await fixture();
    const created = await createUpload(f, f.guestUid, "turn-gate");
    const id = created.json().attachmentId as string;
    await putDirect(f, id, "hello");
    expect((await finalizeUpload(f, f.guestUid, id)).statusCode).toBe(200);
    const turn = await f.app.inject({
      method: "POST",
      url: `/chat/${f.token}/turns`,
      headers: headers(f.guestUid),
      payload: {
        schemaVersion: 1,
        idempotencyKey: `turn-${newId()}`,
        text: "materialize only through real Task 4",
        attachmentIds: [id],
      },
    });
    expect(turn.statusCode).toBe(503);
    expect(turn.json()).toMatchObject({ schemaVersion: 1, code: "temporarily_unavailable" });
    const counts = await db.$client`
      SELECT
        (SELECT count(*)::int FROM messages WHERE session_id = ${f.sessionId}) AS messages,
        (SELECT count(*)::int FROM runs WHERE session_id = ${f.sessionId}) AS runs,
        (SELECT count(*)::int FROM run_outbox WHERE session_id = ${f.sessionId}) AS outbox`;
    expect(counts).toEqual([{ messages: 0, runs: 0, outbox: 0 }]);
    // Task 4 acceptance must replace this refusal assertion with real turn
    // admission + attachment materialization. No fake writer is introduced here.
  });
});
