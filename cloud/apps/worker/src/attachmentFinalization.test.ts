import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import {
  attachments,
  createDb,
  migrate,
  newId,
  projectFileUsage,
  projectsRepo,
  runs,
  StorageReservationStore,
  type StorageReservationInput,
  type Db,
} from "@ovid/db";
import type { EventLog } from "@ovid/events";
import type { KeyResolver, SessionEvent } from "@ovid/shared";
import type { HeadResult, StorageAdapter } from "@ovid/storage";
import type { SandboxHandle, SandboxManager } from "@ovid/sandbox";
import { buildGateway } from "../../gateway/src/app.js";
import {
  authHeaders,
  noopEvents,
  stubKeys as stubGatewayKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
  type QueueAdd,
} from "../../gateway/src/test/stubs.js";
import {
  createMigrationScratch,
  type MigrationScratch,
} from "../../../packages/db/src/migrationTestKit.js";
import type { ModelTransport } from "./liteLlm.js";
import { createAgentRunProcessor, readRunAttachment } from "./runProcessor.js";
import { createToolRegistry } from "./tools/registry.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

interface StoredObject {
  body: Buffer;
  contentType: string | null;
}

function fakeStorage() {
  const objects = new Map<string, StoredObject>();
  const missingGet = new Set<string>();
  const headCalls: string[] = [];
  const getBufferCalls: string[] = [];
  const adapter: StorageAdapter = {
    kind: "fs",
    async put() { throw new Error("not used by this harness"); },
    async get() { return null; },
    async getBuffer(key) {
      getBufferCalls.push(key);
      return missingGet.has(key) ? null : objects.get(key)?.body ?? null;
    },
    async head(key): Promise<HeadResult | null> {
      headCalls.push(key);
      const object = objects.get(key);
      if (object === undefined) return null;
      return {
        bytes: object.body.length,
        contentType: object.contentType,
        sha256Hex: null,
        etag: null,
        metadata: {},
      };
    },
    async delete(key) { objects.delete(key); },
    async presignGet(key) { return `https://r2.test/get/${encodeURIComponent(key)}`; },
    async presignPut({ key }) { return `https://r2.test/put/${encodeURIComponent(key)}`; },
    async readerSpec() { return null; },
  };
  return { adapter, objects, missingGet, headCalls, getBufferCalls };
}

function memoryEventLog(): EventLog {
  let sequence = 0;
  const rows: SessionEvent[] = [];
  return {
    async append(sessionId, type, payload) {
      sequence += 1;
      const event: SessionEvent = {
        sessionId,
        seq: `${sequence}-0`,
        type,
        payload,
        ts: new Date().toISOString(),
      };
      rows.push(event);
      return event;
    },
    async readSince(sessionId, lastSeq, limit) {
      return rows
        .filter((row) => row.sessionId === sessionId)
        .filter((row) => lastSeq === null || Number(row.seq.split("-")[0]) > Number(lastSeq.split("-")[0]))
        .slice(0, limit);
    },
    async subscribe() { return async () => {}; },
  };
}

describe.skipIf(!TEST_DATABASE_URL)("attachment HEAD finalization and legacy linked runs", () => {
  let scratch: MigrationScratch;
  let db: Db;
  const apps: FastifyInstance[] = [];
  const workspaces: string[] = [];

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "contracts_task3_worker");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 4 });
  }, 120_000);

  afterEach(async () => {
    while (apps.length > 0) await apps.pop()!.close();
    while (workspaces.length > 0) {
      await rm(workspaces.pop()!, { recursive: true, force: true });
    }
  });

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  function makeHarness(opts: { storageOnly?: boolean } = {}) {
    const storage = fakeStorage();
    const queue = stubQueues();
    const events = memoryEventLog();
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: queue.queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubGatewayKeys(),
      mint: stubMint(),
      events: noopEvents,
      storage: storage.adapter,
      ...(opts.storageOnly ? {} : { presigner: storage.adapter }),
    });
    apps.push(app);
    return { app, storage, queue, events };
  }

  async function createSession(app: FastifyInstance, uid: string): Promise<string> {
    const response = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
      payload: {},
    });
    expect(response.statusCode).toBe(201);
    return response.json().id as string;
  }

  async function createTicket(
    app: FastifyInstance,
    uid: string,
    sessionId: string,
    body: Record<string, unknown>,
  ) {
    const response = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sessionId}/attachments`,
      headers: authHeaders(uid),
      payload: body,
    });
    expect(response.statusCode).toBe(201);
    return response.json() as {
      attachmentId: string;
      uploadUrl: string;
      path: string;
      expiresAt: string;
      contentType?: string;
      uploadHeaders?: Record<string, string>;
    };
  }

  function finalize(
    app: FastifyInstance,
    uid: string,
    sessionId: string,
    attachmentId: string,
    payload: unknown = {},
  ) {
    return app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sessionId}/attachments/${attachmentId}/finalize`,
      headers: authHeaders(uid),
      payload: payload as object,
    });
  }

  async function processJob(
    job: QueueAdd,
    harness: ReturnType<typeof makeHarness>,
  ): Promise<{ providerCalls: number; workspaceDir: string }> {
    const workspaceDir = await mkdtemp(join(tmpdir(), "ovid-task3-worker-"));
    workspaces.push(workspaceDir);
    const handle = {
      userId: job.data.userId,
      uid: 200_001,
      workspaceDir,
      homeDir: join(workspaceDir, ".home"),
      jailWorkspaceDir: "/workspace",
      exec: async () => ({
        exitCode: 0,
        stdout: "",
        stderr: "",
        timedOut: false,
        truncated: false,
        blocked: false,
        refusal: null,
      }),
    } as unknown as SandboxHandle;
    const sandbox = {
      attach: async () => handle,
    } as unknown as SandboxManager;
    let providerCalls = 0;
    const transport: ModelTransport = {
      async stream(_request, handlers) {
        providerCalls += 1;
        handlers.onDelta("done");
        return { finishReason: "stop", toolCalls: [] };
      },
    };
    const keys: KeyResolver = {
      resolveForRun: async () => ({ kind: "litellm", key: "sk-task3", baseUrl: "" }),
    };
    await createAgentRunProcessor({
      db,
      events: harness.events,
      keys,
      transport,
      litellmBaseUrl: "http://litellm.invalid",
      defaultModel: "text-only-test-model",
      sandbox,
      tools: createToolRegistry(),
      storage: harness.storage.adapter,
      sleep: async () => {},
    })({ data: job.data });
    return { providerCalls, workspaceDir };
  }

  it("uses the composed storage adapter for signing as well as HEAD", async () => {
    const harness = makeHarness({ storageOnly: true });
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const ticket = await createTicket(harness.app, uid, sessionId, {
      name: "composed.txt",
      size: 4,
      contentType: "text/plain",
    });
    expect(ticket.uploadHeaders).toEqual({ "Content-Type": "text/plain" });
  });

  it("HEAD success returns the finalized DTO and an identical retry is idempotent", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const ticket = await createTicket(harness.app, uid, sessionId, {
      name: "proof.txt",
      size: 4,
      contentType: "text/plain",
    });
    const key = `users/${uid}/sessions/${sessionId}/uploads/${ticket.attachmentId}`;
    harness.storage.objects.set(key, { body: Buffer.from("text"), contentType: "text/plain" });

    const first = await finalize(harness.app, uid, sessionId, ticket.attachmentId);
    expect(first.statusCode).toBe(200);
    expect(first.json()).toEqual({
      attachmentId: ticket.attachmentId,
      status: "ready",
      size: 4,
      contentType: "text/plain",
    });
    const ready = (await attachments.getForSession(db, sessionId, [ticket.attachmentId]))[0]!;
    expect(ready.finalizedAt).toBeInstanceOf(Date);

    const repeated = await finalize(harness.app, uid, sessionId, ticket.attachmentId);
    expect(repeated.statusCode).toBe(200);
    expect(repeated.json()).toEqual(first.json());
    expect((await attachments.getForSession(db, sessionId, [ticket.attachmentId]))[0]!)
      .toEqual(ready);
  });

  it("missing objects and signed size/type mismatches never produce a ready row", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);

    const missing = await createTicket(harness.app, uid, sessionId, { name: "missing.txt", size: 1 });
    const missingResult = await finalize(harness.app, uid, sessionId, missing.attachmentId);
    expect(missingResult.statusCode).toBe(409);
    expect(missingResult.json().error.code).toBe("attachment_not_uploaded");

    const wrongSize = await createTicket(harness.app, uid, sessionId, {
      name: "size.txt",
      size: 4,
      contentType: "text/plain",
    });
    const sizeKey = `users/${uid}/sessions/${sessionId}/uploads/${wrongSize.attachmentId}`;
    harness.storage.objects.set(sizeKey, { body: Buffer.from("too-long"), contentType: "text/plain" });
    const sizeResult = await finalize(harness.app, uid, sessionId, wrongSize.attachmentId);
    expect(sizeResult.statusCode).toBe(409);
    expect(sizeResult.json().error.code).toBe("attachment_size_mismatch");

    const wrongType = await createTicket(harness.app, uid, sessionId, {
      name: "type.pdf",
      size: 4,
      contentType: "application/pdf",
    });
    const typeKey = `users/${uid}/sessions/${sessionId}/uploads/${wrongType.attachmentId}`;
    harness.storage.objects.set(typeKey, { body: Buffer.from("text"), contentType: "text/plain" });
    const typeResult = await finalize(harness.app, uid, sessionId, wrongType.attachmentId);
    expect(typeResult.statusCode).toBe(409);
    expect(typeResult.json().error.code).toBe("attachment_type_mismatch");

    const rows = await attachments.getForSession(db, sessionId);
    expect(rows.every((row) => row.uploadStatus !== "ready" && row.finalizedAt === null)).toBe(true);
    expect(rows.find((row) => row.id === wrongType.attachmentId)).toMatchObject({
      contentType: "application/pdf",
      actualContentType: "text/plain",
    });
  });

  it("explicit octet-stream requires exact HEAD type; omitted legacy type remains unknown", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const cases = [
      { name: "missing-type.bin", actual: null, expectedStatus: 409 },
      { name: "wrong-type.bin", actual: "text/plain", expectedStatus: 409 },
      { name: "exact-type.bin", actual: "application/octet-stream", expectedStatus: 200 },
    ] as const;
    for (const item of cases) {
      const ticket = await createTicket(harness.app, uid, sessionId, {
        name: item.name,
        size: 4,
        contentType: "application/octet-stream",
      });
      const key = `users/${uid}/sessions/${sessionId}/uploads/${ticket.attachmentId}`;
      harness.storage.objects.set(key, { body: Buffer.from("body"), contentType: item.actual });
      const result = await finalize(harness.app, uid, sessionId, ticket.attachmentId);
      expect(result.statusCode, item.name).toBe(item.expectedStatus);
      if (item.expectedStatus === 409) {
        expect(result.json().error.code).toBe("attachment_type_mismatch");
      }
    }

    const rows = await attachments.getForSession(db, sessionId);
    expect(rows.map((row) => row.contentTypeDeclared)).toEqual([true, true, true]);
    expect(rows.map((row) => row.uploadStatus)).toEqual(["failed", "failed", "ready"]);

    const legacy = await createTicket(harness.app, uid, sessionId, {
      name: "omitted.bin",
      size: 4,
    });
    const legacyKey = `users/${uid}/sessions/${sessionId}/uploads/${legacy.attachmentId}`;
    harness.storage.objects.set(legacyKey, { body: Buffer.from("body"), contentType: "text/plain" });
    expect((await finalize(harness.app, uid, sessionId, legacy.attachmentId)).statusCode).toBe(200);
    expect((await attachments.getForSession(db, sessionId, [legacy.attachmentId]))[0])
      .toMatchObject({ contentTypeDeclared: false, actualContentType: "text/plain" });
  });

  it("strictly requires an empty finalize body and hides wrong-owner/unknown attachments before HEAD", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const ticket = await createTicket(harness.app, uid, sessionId, { name: "private.txt", size: 1 });
    const key = `users/${uid}/sessions/${sessionId}/uploads/${ticket.attachmentId}`;
    harness.storage.objects.set(key, { body: Buffer.from("x"), contentType: null });

    const badBody = await finalize(harness.app, uid, sessionId, ticket.attachmentId, { force: true });
    expect(badBody.statusCode).toBe(400);
    const stranger = await finalize(harness.app, newId(), sessionId, ticket.attachmentId);
    expect(stranger.statusCode).toBe(404);
    const unknown = await finalize(harness.app, uid, sessionId, newId());
    expect(unknown.statusCode).toBe(404);
    expect(harness.storage.headCalls).toEqual([]);
    expect((await attachments.getForSession(db, sessionId))[0]!.uploadStatus).toBe("pending");
  });

  it("a changed object conflicts and revokes the stale ready state", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const ticket = await createTicket(harness.app, uid, sessionId, {
      name: "change.txt",
      size: 4,
      contentType: "text/plain",
    });
    const key = `users/${uid}/sessions/${sessionId}/uploads/${ticket.attachmentId}`;
    harness.storage.objects.set(key, { body: Buffer.from("one!"), contentType: "text/plain" });
    expect((await finalize(harness.app, uid, sessionId, ticket.attachmentId)).statusCode).toBe(200);

    harness.storage.objects.set(key, { body: Buffer.from("two-long"), contentType: "text/plain" });
    const changed = await finalize(harness.app, uid, sessionId, ticket.attachmentId);
    expect(changed.statusCode).toBe(409);
    expect(changed.json().error.code).toBe("attachment_changed");
    expect((await attachments.getForSession(db, sessionId))[0]).toMatchObject({
      uploadStatus: "failed",
      finalizedAt: null,
    });
  });

  it("an old no-finalize send materializes through worker HEAD and a subsequent linked run is idempotent", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const ticket = await createTicket(harness.app, uid, sessionId, {
      name: "legacy.bin",
      size: 5,
    });
    expect(ticket.uploadHeaders).toEqual({});
    const key = `users/${uid}/sessions/${sessionId}/uploads/${ticket.attachmentId}`;
    harness.storage.objects.set(key, { body: Buffer.from("hello"), contentType: null });

    const firstSend = await harness.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sessionId}/messages`,
      headers: authHeaders(uid),
      payload: { content: "read the legacy upload", attachmentIds: [ticket.attachmentId] },
    });
    expect(firstSend.statusCode).toBe(202);
    expect(harness.queue.adds).toHaveLength(1);
    const pending = (await attachments.getForSession(db, sessionId))[0]!;
    expect(pending).toMatchObject({
      uploadStatus: "pending",
      contentType: "application/octet-stream",
      messageId: firstSend.json().userMessageId,
    });

    const firstRun = await processJob(harness.queue.adds[0]!, harness);
    expect(firstRun.providerCalls).toBe(1);
    expect(await readFile(join(firstRun.workspaceDir, "uploads", "legacy.bin"), "utf8")).toBe("hello");
    const ready = (await attachments.getForSession(db, sessionId))[0]!;
    expect(ready).toMatchObject({
      uploadStatus: "ready",
      contentType: "application/octet-stream",
      actualBytes: 5,
      actualContentType: null,
      messageId: firstSend.json().userMessageId,
    });
    expect(await runs.get(db, firstSend.json().runId, uid)).toMatchObject({ status: "completed" });
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${ticket.attachmentId}`)
      .toEqual([{ state: "finalized" }]);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 5, reserved: 0 }]);

    const secondSend = await harness.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sessionId}/messages`,
      headers: authHeaders(uid),
      payload: { content: "read it again", attachmentIds: [ticket.attachmentId] },
    });
    expect(secondSend.statusCode).toBe(202);
    const secondRun = await processJob(harness.queue.adds[1]!, harness);
    expect(secondRun.providerCalls).toBe(1);
    expect(await readFile(join(secondRun.workspaceDir, "uploads", "legacy.bin"), "utf8")).toBe("hello");
    const afterSecond = (await attachments.getForSession(db, sessionId))[0]!;
    expect(afterSecond).toMatchObject({
      uploadStatus: "ready",
      messageId: secondSend.json().userMessageId,
      finalizedAt: ready.finalizedAt,
    });
    expect(harness.storage.headCalls).toEqual([key, key]);
    expect(harness.storage.getBufferCalls).toEqual([key, key]);
    expect(await runs.get(db, secondSend.json().runId, uid)).toMatchObject({ status: "completed" });
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 5, reserved: 0 }]);
  });

  // UNEXECUTED N1: mismatch releases quota and the failed project slot.
  it("the legacy worker fence refuses a HEAD size mismatch before download or provider call", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const project = await projectsRepo.create(db, uid, "worker-mismatch");
    expect(project).not.toBeNull();
    expect(await projectsRepo.moveSession(db, uid, sessionId, project!.id)).not.toBeNull();
    const ticket = await createTicket(harness.app, uid, sessionId, {
      name: "wrong.bin",
      size: 5,
    });
    const key = `users/${uid}/sessions/${sessionId}/uploads/${ticket.attachmentId}`;
    harness.storage.objects.set(key, { body: Buffer.from("no"), contentType: null });
    const sent = await harness.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sessionId}/messages`,
      headers: authHeaders(uid),
      payload: { content: "try the mismatched upload", attachmentIds: [ticket.attachmentId] },
    });
    expect(sent.statusCode).toBe(202);

    const result = await processJob(harness.queue.adds[0]!, harness);
    expect(result.providerCalls).toBe(0);
    expect(harness.storage.getBufferCalls).toEqual([]);
    expect(await attachments.getForSession(db, sessionId)).toEqual([]);
    expect(harness.storage.objects.has(key)).toBe(false);
    expect(await projectFileUsage(db, uid, project!.id)).toMatchObject({ used: 0 });
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${ticket.attachmentId}`)
      .toEqual([{ state: "released" }]);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
    expect(await runs.get(db, sent.json().runId, uid)).toMatchObject({
      status: "failed",
      lastError: "attachment_unavailable",
    });
  });

  // UNEXECUTED round-2 worker missing-HEAD lifecycle regression.
  it("releases missing worker uploads without materializing or charging them", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const ticket = await createTicket(harness.app, uid, sessionId, {
      name: "missing-worker.bin",
      size: 5,
    });
    const sent = await harness.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sessionId}/messages`,
      headers: authHeaders(uid),
      payload: { content: "missing upload", attachmentIds: [ticket.attachmentId] },
    });
    expect(sent.statusCode).toBe(202);
    const result = await processJob(harness.queue.adds[0]!, harness);
    expect(result.providerCalls).toBe(0);
    expect(harness.storage.getBufferCalls).toEqual([]);
    expect(await attachments.getForSession(db, sessionId)).toEqual([]);
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${ticket.attachmentId}`)
      .toEqual([{ state: "released" }]);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
  });

  // UNEXECUTED round-3: legacy reservationless missing HEAD is not clean.
  it("fails and removes a reservationless pending legacy upload on missing HEAD", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const attachmentId = newId();
    await attachments.create(db, {
      id: attachmentId,
      sessionId,
      userId: uid,
      name: "legacy-worker-missing.bin",
      size: 5,
      r2Key: `users/${uid}/sessions/${sessionId}/uploads/${attachmentId}`,
    });
    const [row] = await attachments.getForSession(db, sessionId, [attachmentId]);
    const result = await readRunAttachment(db, harness.storage.adapter, row!);
    expect(result.buffer).toBeNull();
    expect(result.error).toContain("attachment object not found");
    expect(await attachments.getForSession(db, sessionId)).toEqual([]);
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([{ state: "released" }]);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
  });

  // UNEXECUTED R4-2: row deletion cannot strand a stale finalized charge.
  it("serializes worker valid-HEAD reservation against missing-HEAD row deletion", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const attachmentId = newId();
    const key = `users/${uid}/sessions/${sessionId}/uploads/${attachmentId}`;
    await attachments.create(db, {
      id: attachmentId,
      sessionId,
      userId: uid,
      name: "legacy-worker-race.bin",
      size: 5,
      r2Key: key,
    });
    harness.storage.objects.set(key, { body: Buffer.from("hello"), contentType: null });
    const [row] = await attachments.getForSession(db, sessionId, [attachmentId]);
    const originalReserve = StorageReservationStore.prototype.reserve;
    let firstValidHeadCall = true;
    let entered!: () => void;
    let proceed!: () => void;
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
      const valid = readRunAttachment(db, harness.storage.adapter, row!);
      await reserveEntered;
      harness.storage.objects.delete(key);
      const missing = await readRunAttachment(db, harness.storage.adapter, row!);
      expect(missing.error).toContain("attachment object not found");
      proceed();
      expect((await valid).error).not.toBeNull();
    } finally {
      proceed();
      reserve.mockRestore();
    }
    expect(await attachments.getForSession(db, sessionId)).toEqual([]);
    expect(harness.storage.objects.has(key)).toBe(false);
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${attachmentId}`)
      .toEqual([{ state: "released" }]);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
  });

  it("retries debit when cleanup observes reserved and release observes finalized", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const ticket = await createTicket(harness.app, uid, sessionId, {
      name: "reserved-finalized-cleanup-race.bin",
      size: 5,
    });
    const key = `users/${uid}/sessions/${sessionId}/uploads/${ticket.attachmentId}`;
    harness.storage.objects.set(key, { body: Buffer.from("hello"), contentType: null });
    const [row] = await attachments.getForSession(db, sessionId, [ticket.attachmentId]);
    const originalFinalize = StorageReservationStore.prototype.finalize;
    const originalRelease = StorageReservationStore.prototype.release;
    let firstFinalize = true;
    let interveningRelease = false;
    const finalize = vi.spyOn(StorageReservationStore.prototype, "finalize")
      .mockImplementation(async function (this: StorageReservationStore, input: Parameters<StorageReservationStore["finalize"]>[0]) {
        if (firstFinalize && input.reservationId === ticket.attachmentId) {
          firstFinalize = false;
          throw new Error("injected settle failure");
        }
        return originalFinalize.call(this, input);
      });
    const release = vi.spyOn(StorageReservationStore.prototype, "release")
      .mockImplementation(async function (this: StorageReservationStore, input: Parameters<StorageReservationStore["release"]>[0]) {
        if (!interveningRelease && input.reservationId === ticket.attachmentId) {
          interveningRelease = true;
          await originalFinalize.call(this, {
            reservationId: ticket.attachmentId,
            actualBytes: 5,
            contentType: null,
            etag: null,
            attachment: true,
          });
        }
        return originalRelease.call(this, input);
      });
    try {
      await expect(readRunAttachment(db, harness.storage.adapter, row!))
        .rejects.toThrow("injected settle failure");
    } finally {
      finalize.mockRestore();
      release.mockRestore();
    }
    expect(interveningRelease).toBe(true);
    expect(await attachments.getForSession(db, sessionId)).toEqual([]);
    expect(harness.storage.objects.has(key)).toBe(false);
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${ticket.attachmentId}`)
      .toEqual([{ state: "released" }]);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
  });

  // UNEXECUTED R3-1: the shared read used by both materialization loops.
  it("debits/releases ready state and the project row when GET is null after HEAD", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const ticket = await createTicket(harness.app, uid, sessionId, {
      name: "get-null-after-ready.bin",
      size: 5,
    });
    const key = `users/${uid}/sessions/${sessionId}/uploads/${ticket.attachmentId}`;
    harness.storage.objects.set(key, { body: Buffer.from("hello"), contentType: null });
    harness.storage.missingGet.add(key);
    const [row] = await attachments.getForSession(db, sessionId, [ticket.attachmentId]);
    const result = await readRunAttachment(db, harness.storage.adapter, row!);
    expect(result.buffer).toBeNull();
    expect(result.error).toContain("attachment object not found");
    expect(await attachments.getForSession(db, sessionId)).toEqual([]);
    expect(harness.storage.objects.has(key)).toBe(false);
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${ticket.attachmentId}`)
      .toEqual([{ state: "released" }]);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
  });

  // UNEXECUTED R4-2: cleanup still releases a reservation after the row is gone.
  it("debits an existing finalized reservation when the attachment row disappears", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const ticket = await createTicket(harness.app, uid, sessionId, {
      name: "deleted-after-ready.bin",
      size: 5,
    });
    const key = `users/${uid}/sessions/${sessionId}/uploads/${ticket.attachmentId}`;
    harness.storage.objects.set(key, { body: Buffer.from("hello"), contentType: null });
    const [row] = await attachments.getForSession(db, sessionId, [ticket.attachmentId]);
    expect((await readRunAttachment(db, harness.storage.adapter, row!)).error).toBeNull();
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 5, reserved: 0 }]);
    await db.$client`DELETE FROM attachments WHERE id = ${ticket.attachmentId}`;
    const result = await readRunAttachment(db, harness.storage.adapter, row!);
    expect(result.error).not.toBeNull();
    expect(harness.storage.objects.has(key)).toBe(false);
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${ticket.attachmentId}`)
      .toEqual([{ state: "released" }]);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
  });

  // UNEXECUTED R3-1: generic failure after actual-byte settlement but during ready.
  it("reconciles a generic post-reservation ready-write failure", async () => {
    const harness = makeHarness();
    const uid = newId();
    const sessionId = await createSession(harness.app, uid);
    const ticket = await createTicket(harness.app, uid, sessionId, {
      name: "generic-ready-failure.bin",
      size: 5,
    });
    const key = `users/${uid}/sessions/${sessionId}/uploads/${ticket.attachmentId}`;
    harness.storage.objects.set(key, { body: Buffer.from("hello"), contentType: null });
    const [row] = await attachments.getForSession(db, sessionId, [ticket.attachmentId]);
    const readyWrite = vi.spyOn(attachments, "finalizeUpload")
      .mockRejectedValue(new Error("ready-write failed"));
    try {
      await expect(readRunAttachment(db, harness.storage.adapter, row!))
        .rejects.toThrow("ready-write failed");
    } finally {
      readyWrite.mockRestore();
    }
    expect(await attachments.getForSession(db, sessionId)).toEqual([]);
    expect(harness.storage.objects.has(key)).toBe(false);
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${ticket.attachmentId}`)
      .toEqual([{ state: "released" }]);
    expect(await db.$client`
      SELECT used_bytes::int AS used, reserved_bytes::int AS reserved
        FROM storage_usage_counters WHERE owner_user_id = ${uid}`)
      .toEqual([{ used: 0, reserved: 0 }]);
  });
});
