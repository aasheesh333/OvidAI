import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { sql } from "drizzle-orm";
import { createDb, migrate, type Db } from "./client.js";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";
import { messages, newId, runs, sessions, userPreferences, users } from "./repos.js";
import {
  createOwnerRunAdmissionAuthorizer,
  createResponseWaitStore,
  createRunOutboxStore,
  createSystemRequestStore,
  type RunAdmissionInput,
  type SystemRequestKind,
} from "./systemRequests.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const T0 = new Date("2026-10-24T12:00:00.000Z");

interface Context {
  actorUserId: string;
  ownerUserId: string;
  sessionId: string;
  runId: string;
  promptMessageId: string;
}

describe.skipIf(!TEST_DATABASE_URL).sequential("0033 system request/outbox stores (isolated real Postgres)", () => {
  let scratch: MigrationScratch;
  let db: Db;
  let secondDb: Db;
  let now: Date;
  let requests: ReturnType<typeof createSystemRequestStore>;
  let secondRequests: ReturnType<typeof createSystemRequestStore>;
  let outbox: ReturnType<typeof createRunOutboxStore>;
  let secondOutbox: ReturnType<typeof createRunOutboxStore>;
  let responseWait: ReturnType<typeof createResponseWaitStore>;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "store_0033");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 24 });
    secondDb = createDb(scratch.url, { max: 24 });
    const clock = () => now;
    requests = createSystemRequestStore(db, { clock });
    secondRequests = createSystemRequestStore(secondDb, { clock });
    outbox = createRunOutboxStore(db, { clock, authorize: createOwnerRunAdmissionAuthorizer() });
    secondOutbox = createRunOutboxStore(secondDb, { clock, authorize: createOwnerRunAdmissionAuthorizer() });
    responseWait = createResponseWaitStore(db);
  }, 180_000);

  beforeEach(() => {
    now = new Date(T0);
  });

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await secondDb?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  async function context(actorUserId = `actor-${newId()}`, ownerUserId = actorUserId): Promise<Context> {
    await users.ensure(db, actorUserId, null);
    if (ownerUserId !== actorUserId) await users.ensure(db, ownerUserId, null);
    const session = await sessions.create(db, ownerUserId, "0033 contract");
    const prompt = await messages.append(db, { sessionId: session.id, role: "user", content: "prompt" });
    const run = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
    return {
      actorUserId,
      ownerUserId,
      sessionId: session.id,
      runId: run.id,
      promptMessageId: prompt.id,
    };
  }

  function requestInput(c: Context, kind: SystemRequestKind = "approval", sensitive = false) {
    return {
      requestId: newId(),
      userId: c.actorUserId,
      sessionId: c.sessionId,
      runId: c.runId,
      kind,
      safePayload: kind === "elicitation"
        ? { message: "Enter credentials", fields: [{ name: "password", type: "string" }] }
        : { tool: "bash", preview: "pwd" },
      sensitive,
      expiresAt: new Date(now.getTime() + 60_000),
    };
  }

  function admission(c: Context, idempotencyKey: string, text = "turn text"): RunAdmissionInput {
    return {
      actorUserId: c.actorUserId,
      sessionId: c.sessionId,
      idempotencyKey,
      content: text,
      requestPayload: { schemaVersion: 1, idempotencyKey, text },
      bodyPayload: { ownerUserId: c.ownerUserId, requestedModel: null },
      authorization: { ownerUserId: c.ownerUserId },
    };
  }

  it("create/get/listPending returns the approved DTO and enforces ownership and expiry visibility", async () => {
    const c = await context();
    const other = `other-${newId()}`;
    await users.ensure(db, other, null);
    const created = await requests.create(requestInput(c));
    expect(created).toEqual({
      requestId: expect.any(String) as string,
      userId: c.actorUserId,
      sessionId: c.sessionId,
      runId: c.runId,
      kind: "approval",
      safePayload: { tool: "bash", preview: "pwd" },
      sensitive: false,
      status: "pending",
      expiresAt: new Date(T0.getTime() + 60_000).toISOString(),
      response: null,
      version: 1,
    });
    expect(await requests.get({ userId: c.actorUserId, requestId: created.requestId })).toEqual(created);
    expect(await requests.get({ userId: other, requestId: created.requestId })).toBeNull();
    expect(await requests.listPending({ userId: other, sessionId: c.sessionId })).toEqual([]);
    expect(await requests.listPending({ userId: c.actorUserId, sessionId: c.sessionId })).toEqual([created]);

    now = new Date(T0.getTime() + 61_000);
    expect(await requests.listPending({ userId: c.actorUserId, sessionId: c.sessionId })).toEqual([]);
    // Reads never fabricate a durable expiry transition; expire() owns it.
    expect((await requests.get({ userId: c.actorUserId, requestId: created.requestId }))?.status).toBe("pending");
  });

  it("supports approval, sampling, and elicitation and refuses mismatched run/session/user identity", async () => {
    const c = await context();
    for (const kind of ["approval", "sampling", "elicitation"] as const) {
      expect((await requests.create(requestInput(c, kind))).kind).toBe(kind);
    }
    const other = await context();
    await expect(requests.create({ ...requestInput(c), runId: other.runId }))
      .rejects.toMatchObject({ code: "not_found" });
    await expect(requests.create({ ...requestInput(c), sessionId: other.sessionId }))
      .rejects.toMatchObject({ code: "not_found" });
  });

  it("respond is a version CAS with structurally identical replay and different-response conflict", async () => {
    const c = await context();
    const created = await requests.create(requestInput(c));
    const clientResponseId = `response-${newId()}`;
    const input = {
      userId: c.actorUserId,
      requestId: created.requestId,
      version: 1,
      response: { approve: true, allowDependencyScripts: false },
      clientResponseId,
    };
    const first = await requests.respond(input);
    expect(first).toEqual({
      requestId: created.requestId,
      userId: c.actorUserId,
      version: 1,
      response: { approve: true, allowDependencyScripts: false },
      clientResponseId,
      createdAt: T0.toISOString(),
    });
    expect(await requests.get({ userId: c.actorUserId, requestId: created.requestId })).toMatchObject({
      status: "resolved",
      response: { approve: true, allowDependencyScripts: false },
      version: 2,
    });

    // JSON object key order is not a semantic response change.
    expect(await secondRequests.respond({
      ...input,
      response: { allowDependencyScripts: false, approve: true },
    })).toEqual(first);
    // An identical response is also an idempotent replay if the client regenerated its retry ID.
    expect(await requests.respond({ ...input, clientResponseId: `different-${newId()}` })).toEqual(first);
    await expect(requests.respond({
      ...input,
      response: { approve: false, allowDependencyScripts: false },
      clientResponseId: `changed-${newId()}`,
    })).rejects.toMatchObject({ code: "response_conflict" });

    const pending = await requests.create(requestInput(c));
    await expect(requests.respond({
      userId: c.actorUserId,
      requestId: pending.requestId,
      version: 0,
      response: { approve: true },
      clientResponseId: `stale-${newId()}`,
    })).rejects.toMatchObject({ code: "version_conflict" });
    expect((await requests.get({ userId: c.actorUserId, requestId: pending.requestId }))?.status).toBe("pending");
  });

  it("cross-user response/expiry denial is non-enumerating and has no side effect", async () => {
    const c = await context();
    const other = `other-${newId()}`;
    await users.ensure(db, other, null);
    const created = await requests.create(requestInput(c));
    expect(await requests.respond({
      userId: other,
      requestId: created.requestId,
      version: 1,
      response: { approve: true },
      clientResponseId: `foreign-${newId()}`,
    })).toBeNull();
    expect(await requests.expire({ userId: other, requestId: created.requestId, version: 1 })).toBeNull();
    expect(await requests.get({ userId: c.actorUserId, requestId: created.requestId })).toMatchObject({
      status: "pending",
      version: 1,
      response: null,
    });
  });

  it("clientResponseId cannot be rebound, while its uniqueness is scoped to the owning user", async () => {
    const a = await context();
    const b = await context();
    const first = await requests.create(requestInput(a));
    const second = await requests.create(requestInput(a));
    const clientResponseId = `shared-response-${newId()}`;
    await requests.respond({
      userId: a.actorUserId,
      requestId: first.requestId,
      version: 1,
      response: { approve: true },
      clientResponseId,
    });
    await expect(requests.respond({
      userId: a.actorUserId,
      requestId: second.requestId,
      version: 1,
      response: { approve: true },
      clientResponseId,
    })).rejects.toMatchObject({ code: "client_response_conflict" });

    const foreign = await requests.create(requestInput(b));
    await expect(requests.respond({
      userId: b.actorUserId,
      requestId: foreign.requestId,
      version: 1,
      response: { approve: false },
      clientResponseId,
    })).resolves.toMatchObject({ requestId: foreign.requestId, clientResponseId });
  });

  it("expire and expired respond perform one durable transition without recording a response", async () => {
    const c = await context();
    const expiring = await requests.create(requestInput(c));
    now = new Date(T0.getTime() + 60_000);
    const expired = await requests.expire({ userId: c.actorUserId, requestId: expiring.requestId, version: 1 });
    expect(expired).toMatchObject({ status: "expired", version: 2, response: null });
    expect(await requests.expire({ userId: c.actorUserId, requestId: expiring.requestId, version: 1 }))
      .toEqual(expired);
    await expect(requests.respond({
      userId: c.actorUserId,
      requestId: expiring.requestId,
      version: 1,
      response: { approve: true },
      clientResponseId: `late-${newId()}`,
    })).rejects.toMatchObject({ code: "request_expired" });

    const late = await requests.create(requestInput(c));
    now = new Date(T0.getTime() + 120_001);
    await expect(requests.respond({
      userId: c.actorUserId,
      requestId: late.requestId,
      version: 1,
      response: { approve: true },
      clientResponseId: `late-${newId()}`,
    })).rejects.toMatchObject({ code: "request_expired" });
    expect(await requests.get({ userId: c.actorUserId, requestId: late.requestId })).toMatchObject({
      status: "expired",
      version: 2,
    });
    const responseRows = await scratch.client`
      SELECT count(*)::int AS count FROM system_request_responses
      WHERE request_id IN (${expiring.requestId}, ${late.requestId})`;
    expect(responseRows[0]?.count).toBe(0);
  });

  it("concurrent identical responses replay once and conflicting responses have exactly one CAS winner", async () => {
    const identicalContext = await context();
    const identical = await requests.create(requestInput(identicalContext));
    const clientResponseId = `race-same-${newId()}`;
    const same = await Promise.all(Array.from({ length: 12 }, () => secondRequests.respond({
      userId: identicalContext.actorUserId,
      requestId: identical.requestId,
      version: 1,
      response: { approve: true },
      clientResponseId,
    })));
    expect(new Set(same.map((row) => JSON.stringify(row))).size).toBe(1);

    const conflictContext = await context();
    const conflicted = await requests.create(requestInput(conflictContext));
    const outcomes = await Promise.allSettled([
      requests.respond({
        userId: conflictContext.actorUserId,
        requestId: conflicted.requestId,
        version: 1,
        response: { approve: true },
        clientResponseId: `race-a-${newId()}`,
      }),
      secondRequests.respond({
        userId: conflictContext.actorUserId,
        requestId: conflicted.requestId,
        version: 1,
        response: { approve: false },
        clientResponseId: `race-b-${newId()}`,
      }),
    ]);
    expect(outcomes.filter((outcome) => outcome.status === "fulfilled")).toHaveLength(1);
    const rejected = outcomes.find((outcome) => outcome.status === "rejected");
    expect(rejected?.status).toBe("rejected");
    if (rejected?.status === "rejected") {
      expect(rejected.reason).toMatchObject({ code: "response_conflict" });
      expect(String(rejected.reason)).not.toContain("approve");
    }
    const rows = await scratch.client`
      SELECT request_id, count(*)::int AS count FROM system_request_responses
      WHERE request_id IN (${identical.requestId}, ${conflicted.requestId}) GROUP BY request_id`;
    expect(rows).toHaveLength(2);
    expect(rows.every((row) => row.count === 1)).toBe(true);
  });

  it("sensitive delivery is explicitly blocked across publish failure, no subscriber, restart, and client re-entry", async () => {
    const c = await context();
    const created = await requests.create(requestInput(c, "elicitation", true));
    const secret = "0033-sensitive-blocker-canary-never-store";
    const input = {
      userId: c.actorUserId,
      requestId: created.requestId,
      version: 1,
      response: { action: "accept", content: { password: secret } },
      clientResponseId: `secret-${newId()}`,
    };
    let publishCalls = 0;
    const respondThenPublish = async (
      store: ReturnType<typeof createSystemRequestStore>,
      response: typeof input,
      publish: () => Promise<void>,
    ) => {
      const dto = await store.respond(response);
      publishCalls += 1;
      await publish();
      return dto;
    };

    // The current schema has no durable sealed value or acknowledged handoff.
    // A post-commit publish failure must never leave a fake resolved response.
    await expect(respondThenPublish(requests, input, async () => {
      throw new Error("publish_failed");
    })).rejects.toMatchObject({ code: "sensitive_delivery_unavailable" });
    expect(publishCalls).toBe(0);
    expect(await requests.get({ userId: c.actorUserId, requestId: created.requestId }))
      .toMatchObject({ status: "pending", version: 1, response: null });

    await expect(respondThenPublish(secondRequests, input, async () => {
      throw new Error("no_subscribers");
    })).rejects.toMatchObject({ code: "sensitive_delivery_unavailable" });
    expect(publishCalls).toBe(0);

    // A new store models process restart. The client may re-enter a different
    // secret because no earlier value was accepted or made non-recoverable.
    const restartedDb = createDb(scratch.url, { max: 2 });
    try {
      const restarted = createSystemRequestStore(restartedDb, { clock: () => now });
      await expect(respondThenPublish(restarted, {
        ...input,
        response: { action: "accept", content: { password: "re-entered-after-restart" } },
      }, async () => {
        throw new Error("restart_before_recovery");
      })).rejects.toMatchObject({ code: "sensitive_delivery_unavailable" });
    } finally {
      await restartedDb.$client.end({ timeout: 5 });
    }
    expect(publishCalls).toBe(0);
    expect(await requests.get({ userId: c.actorUserId, requestId: created.requestId }))
      .toMatchObject({ status: "pending", version: 1, response: null });
    const rows = await scratch.client`
      SELECT
        (SELECT count(*)::int FROM system_request_responses WHERE request_id = ${created.requestId}) AS responses,
        (SELECT row_to_json(system_requests)::text FROM system_requests WHERE request_id = ${created.requestId}) AS request_raw,
        (SELECT coalesce(string_agg(row_to_json(system_request_responses)::text, ''), '')
           FROM system_request_responses WHERE request_id = ${created.requestId}) AS response_raw`;
    expect(rows[0]?.responses).toBe(0);
    expect(rows[0]?.request_raw).not.toContain(secret);
    expect(rows[0]?.response_raw).not.toContain(secret);
  });

  it("responseWaitSeconds defaults to 45, persists 15..600, and preserves existing preferences", async () => {
    const uid = `preferences-${newId()}`;
    expect(await responseWait.get(uid)).toBe(45);
    await userPreferences.patch(db, uid, { memoryEnabled: false, showReasoning: false });
    expect(await responseWait.set(uid, 15)).toBe(15);
    expect(await responseWait.get(uid)).toBe(15);
    expect(await responseWait.set(uid, 600)).toBe(600);
    expect(await userPreferences.get(db, uid)).toEqual({
      memoryEnabled: false,
      shareSessionMemory: false,
      showReasoning: false,
    });
    for (const invalid of [14, 601, 15.5, Number.NaN]) {
      await expect(responseWait.set(uid, invalid)).rejects.toMatchObject({ code: "invalid_response_wait" });
    }
    expect(await responseWait.get(uid)).toBe(600);
  });

  it("outbox admit atomically creates one message/run/outbox and replays or conflicts by payload", async () => {
    const c = await context();
    const input = admission(c, `turn-${newId()}`);
    const first = await outbox.admit(input);
    expect(first).toMatchObject({
      actorUserId: c.actorUserId,
      sessionId: c.sessionId,
      idempotencyKey: input.idempotencyKey,
      status: "queued",
      requestPayload: input.requestPayload,
      bodyPayload: {
        ...input.bodyPayload,
        userId: c.actorUserId,
        sessionId: c.sessionId,
        runId: expect.any(String) as string,
      },
      attempts: 0,
      publishedAt: null,
      lastAttemptAt: null,
      settledAt: null,
      lastError: null,
    });
    expect(first.jobId).toBe(first.runId);
    expect(first.userMessageId).not.toBe(c.promptMessageId);
    expect(first.outboxId).not.toBe(first.runId);

    const replay = await secondOutbox.admit({
      ...input,
      requestPayload: { text: input.content, idempotencyKey: input.idempotencyKey, schemaVersion: 1 },
    });
    expect(replay).toEqual(first);
    await expect(outbox.admit({
      ...input,
      content: "changed",
      requestPayload: { ...input.requestPayload, text: "changed" },
    })).rejects.toMatchObject({ code: "request_already_used" });
    await expect(outbox.admit({
      ...input,
      bodyPayload: { ownerUserId: c.ownerUserId, requestedModel: "different/model" },
    })).rejects.toMatchObject({ code: "request_already_used" });

    const counts = await scratch.client`
      SELECT
        (SELECT count(*)::int FROM run_outbox WHERE actor_user_id = ${c.actorUserId} AND idempotency_key = ${input.idempotencyKey}) AS outbox,
        (SELECT count(*)::int FROM runs WHERE id = ${first.runId}) AS runs,
        (SELECT count(*)::int FROM messages WHERE id = ${first.userMessageId}) AS messages`;
    expect(counts[0]).toEqual({ outbox: 1, runs: 1, messages: 1 });
    const storedMessage = await messages.get(db, first.userMessageId);
    expect(storedMessage).toMatchObject({ sessionId: c.sessionId, role: "user", content: input.content });
  });

  it("concurrent outbox admission returns one job/run/message and no duplicate rows", async () => {
    const c = await context();
    const input = admission(c, `race-turn-${newId()}`);
    const admitted = await Promise.all(Array.from({ length: 16 }, (_, index) =>
      (index % 2 === 0 ? outbox : secondOutbox).admit(input),
    ));
    expect(new Set(admitted.map((row) => row.outboxId)).size).toBe(1);
    expect(new Set(admitted.map((row) => row.runId)).size).toBe(1);
    expect(new Set(admitted.map((row) => row.userMessageId)).size).toBe(1);
    const first = admitted[0]!;
    const counts = await scratch.client`
      SELECT
        (SELECT count(*)::int FROM run_outbox WHERE session_id = ${c.sessionId}) AS outbox,
        (SELECT count(*)::int FROM runs WHERE session_id = ${c.sessionId}) AS runs,
        (SELECT count(*)::int FROM messages WHERE session_id = ${c.sessionId} AND content = ${input.content}) AS messages`;
    // context() seeded one run; admission added exactly one more.
    expect(counts[0]).toEqual({ outbox: 1, runs: 2, messages: 1 });
    expect(await outbox.get({ outboxId: first.outboxId })).toEqual(first);
  });

  it("outbox idempotency is per actor, not a cross-participant session lock", async () => {
    const a = await context();
    const b = await context(undefined, a.ownerUserId);
    // Both participants use the same host session. The custom authorizer
    // verifies the real host session instead of assuming actor == owner.
    b.sessionId = a.sessionId;
    const sharedOutbox = createRunOutboxStore(db, {
      clock: () => now,
      authorize: async (tx, input) => {
        const rows = await tx.execute(sql`
          SELECT user_id FROM sessions WHERE id = ${input.sessionId} FOR UPDATE`) as unknown as Array<{ user_id: string }>;
        if (rows[0]?.user_id !== input.authorization.ownerUserId) {
          throw admissionError("not_found");
        }
      },
    });
    const key = `shared-turn-${newId()}`;
    const first = await sharedOutbox.admit(admission(a, key, "from A"));
    const second = await sharedOutbox.admit(admission(b, key, "from B"));
    expect(second.runId).not.toBe(first.runId);
    expect(second.userMessageId).not.toBe(first.userMessageId);
  });

  it("outbox retry rejects unsanitized error text without storing secret plaintext", async () => {
    const c = await context();
    const admitted = await outbox.admit(admission(c, `sanitized-error-${newId()}`));
    const secret = "0033-outbox-secret-canary-never-store";
    await expect(outbox.retry({
      outboxId: admitted.outboxId,
      error: `provider failed with ${secret}`,
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(await outbox.get({ outboxId: admitted.outboxId })).toMatchObject({
      status: "queued",
      attempts: 0,
      lastError: null,
    });
    const rows = await scratch.client`
      SELECT last_error, row_to_json(run_outbox)::text AS raw
      FROM run_outbox WHERE outbox_id = ${admitted.outboxId}`;
    expect(rows[0]?.last_error).toBeNull();
    expect(rows[0]?.raw).not.toContain(secret);
  });

  it("failed publication remains recoverable with the same job/run/message IDs", async () => {
    const c = await context();
    const admitted = await outbox.admit(admission(c, `failed-publish-${newId()}`));
    now = new Date(T0.getTime() + 1_000);
    const failed = await outbox.markPublished({
      outboxId: admitted.outboxId,
      error: "queue_unavailable",
    });
    expect(failed).toMatchObject({
      status: "failed",
      attempts: 1,
      publishedAt: null,
      lastAttemptAt: now,
      lastError: "queue_unavailable",
      jobId: admitted.jobId,
      runId: admitted.runId,
      userMessageId: admitted.userMessageId,
    });
    expect(await outbox.markPublished({
      outboxId: admitted.outboxId,
      error: "queue_unavailable",
    })).toEqual(failed);
    now = new Date(T0.getTime() + 2_000);
    expect(await outbox.retry({ outboxId: admitted.outboxId })).toMatchObject({
      status: "queued",
      attempts: 2,
      jobId: admitted.jobId,
    });
    now = new Date(T0.getTime() + 3_000);
    expect(await secondOutbox.markPublished({ outboxId: admitted.outboxId })).toMatchObject({
      status: "published",
      attempts: 3,
      jobId: admitted.jobId,
      runId: admitted.runId,
      userMessageId: admitted.userMessageId,
    });
  });

  it("publication, settlement, and queue retry preserve job ID and never duplicate admission", async () => {
    const c = await context();
    const first = await outbox.admit(admission(c, `publish-${newId()}`));
    now = new Date(T0.getTime() + 1_000);
    const published = await outbox.markPublished({ outboxId: first.outboxId });
    expect(published).toMatchObject({
      jobId: first.jobId,
      status: "published",
      attempts: 1,
      publishedAt: now,
      lastAttemptAt: now,
    });
    expect(await outbox.markPublished({ outboxId: first.outboxId })).toEqual(published);
    now = new Date(T0.getTime() + 2_000);
    const settled = await outbox.markSettled({ outboxId: first.outboxId });
    expect(settled).toMatchObject({ status: "settled", attempts: 1, settledAt: now });
    expect(await outbox.markSettled({ outboxId: first.outboxId })).toEqual(settled);
    await expect(outbox.retry({ outboxId: first.outboxId }))
      .rejects.toMatchObject({ code: "invalid_transition" });

    const recover = await outbox.admit(admission(c, `recover-${newId()}`));
    now = new Date(T0.getTime() + 3_000);
    const queued = await outbox.retry({ outboxId: recover.outboxId, error: "queue_unavailable" });
    expect(queued).toMatchObject({
      jobId: recover.jobId,
      runId: recover.runId,
      userMessageId: recover.userMessageId,
      status: "queued",
      attempts: 1,
      lastAttemptAt: now,
      lastError: "queue_unavailable",
    });
    now = new Date(T0.getTime() + 4_000);
    expect(await secondOutbox.markPublished({ outboxId: recover.outboxId })).toMatchObject({
      jobId: recover.jobId,
      status: "published",
      attempts: 2,
      lastError: null,
    });
    const counts = await scratch.client`
      SELECT count(*)::int AS count FROM run_outbox WHERE outbox_id = ${recover.outboxId}`;
    expect(counts[0]?.count).toBe(1);
    expect(await outbox.get({ outboxId: newId() })).toBeNull();
  });

  interface CollabAuthorizationFixture {
    roomId: string;
    participantId: string;
    membershipGeneration: number;
    leaseId: string;
    leaseGeneration: number;
  }

  type AuthorizedAdmission = RunAdmissionInput & {
    authorization: {
      ownerUserId: string;
      collab?: CollabAuthorizationFixture;
    };
  };
  type AdmissionTx = Parameters<Parameters<Db["transaction"]>[0]>[0];

  function withAuthorization(
    input: RunAdmissionInput,
    ownerUserId: string,
    collab?: CollabAuthorizationFixture,
  ): AuthorizedAdmission {
    return {
      ...input,
      authorization: { ownerUserId, ...(collab === undefined ? {} : { collab }) },
    };
  }

  function admissionError(code: string): Error {
    return Object.assign(new Error(code), { code });
  }

  it("outbox admission denies a wrong or unprovisioned actor without creating users/messages/runs", async () => {
    const c = await context();
    const store = createRunOutboxStore(db, {
      clock: () => now,
      authorize: async (tx: AdmissionTx, input: AuthorizedAdmission) => {
        const rows = await tx.execute(sql`
          SELECT user_id FROM sessions WHERE id = ${input.sessionId} FOR UPDATE`) as unknown as Array<{ user_id: string }>;
        if (
          rows[0]?.user_id !== input.authorization.ownerUserId ||
          input.actorUserId !== input.authorization.ownerUserId
        ) {
          throw admissionError("not_found");
        }
      },
    });
    const ghostActor = `ghost-${newId()}`;
    const input = withAuthorization(admission(c, `wrong-actor-${newId()}`), c.ownerUserId);
    input.actorUserId = ghostActor;
    const before = await scratch.client`
      SELECT
        (SELECT count(*)::int FROM messages WHERE session_id = ${c.sessionId}) AS messages,
        (SELECT count(*)::int FROM runs WHERE session_id = ${c.sessionId}) AS runs`;
    await expect(store.admit(input)).rejects.toMatchObject({ code: "not_found" });
    const after = await scratch.client`
      SELECT
        (SELECT count(*)::int FROM users WHERE uid = ${ghostActor}) AS users,
        (SELECT count(*)::int FROM messages WHERE session_id = ${c.sessionId}) AS messages,
        (SELECT count(*)::int FROM runs WHERE session_id = ${c.sessionId}) AS runs,
        (SELECT count(*)::int FROM run_outbox WHERE session_id = ${c.sessionId}) AS outbox`;
    expect(after[0]).toEqual({
      users: 0,
      messages: before[0]!.messages,
      runs: before[0]!.runs,
      outbox: 0,
    });
  });

  it("outbox authorization rejects revoked/stale membership and lease generations inside the admission transaction", async () => {
    const owner = await context();
    const c = await context(undefined, owner.ownerUserId);
    c.sessionId = owner.sessionId;
    await scratch.client`
      CREATE TABLE outbox_authorization_fixture (
        session_id char(36) PRIMARY KEY,
        owner_user_id text NOT NULL,
        actor_user_id text NOT NULL,
        room_id char(36) NOT NULL,
        participant_id char(36) NOT NULL,
        membership_generation integer NOT NULL,
        lease_id char(36) NOT NULL,
        lease_generation integer NOT NULL,
        revoked boolean NOT NULL
      )`;
    const collab: CollabAuthorizationFixture = {
      roomId: newId(),
      participantId: newId(),
      membershipGeneration: 3,
      leaseId: newId(),
      leaseGeneration: 7,
    };
    await scratch.client`
      INSERT INTO outbox_authorization_fixture
        (session_id, owner_user_id, actor_user_id, room_id, participant_id,
         membership_generation, lease_id, lease_generation, revoked)
      VALUES
        (${c.sessionId}, ${c.ownerUserId}, ${c.actorUserId}, ${collab.roomId},
         ${collab.participantId}, 3, ${collab.leaseId}, 7, false)`;
    let poisonRollback = false;
    const store = createRunOutboxStore(db, {
      clock: () => now,
      authorize: async (tx: AdmissionTx, input: AuthorizedAdmission) => {
        const auth = input.authorization.collab!;
        const rows = await tx.execute(sql`
          SELECT * FROM outbox_authorization_fixture
          WHERE session_id = ${input.sessionId} FOR UPDATE`) as unknown as Array<{
            owner_user_id: string;
            actor_user_id: string;
            room_id: string;
            participant_id: string;
            membership_generation: number;
            lease_id: string;
            lease_generation: number;
            revoked: boolean;
          }>;
        const row = rows[0];
        if (
          row === undefined ||
          row.owner_user_id !== input.authorization.ownerUserId ||
          row.actor_user_id !== input.actorUserId ||
          row.room_id !== auth.roomId ||
          row.participant_id !== auth.participantId
        ) {
          throw admissionError("not_found");
        }
        if (row.revoked) throw admissionError("admission_denied");
        if (row.membership_generation !== auth.membershipGeneration || row.lease_generation !== auth.leaseGeneration) {
          throw admissionError("stale_authorization");
        }
        if (poisonRollback) {
          await tx.execute(sql`
            UPDATE outbox_authorization_fixture SET membership_generation = 999
            WHERE session_id = ${input.sessionId}`);
          throw admissionError("stale_authorization");
        }
      },
    });

    const first = await store.admit(withAuthorization(admission(c, `collab-${newId()}`), c.ownerUserId, collab));
    expect(first.bodyPayload).toMatchObject({
      userId: c.actorUserId,
      sessionId: c.sessionId,
      runId: first.runId,
      collab: {
        ...collab,
        outboxId: first.outboxId,
        rootRunId: first.runId,
      },
    });
    // get remains the internal publisher/recovery read; no route is added.
    expect(await store.get({ outboxId: first.outboxId })).toEqual(first);

    await scratch.client`UPDATE outbox_authorization_fixture SET revoked = true WHERE session_id = ${c.sessionId}`;
    await expect(store.admit(withAuthorization(admission(c, `revoked-${newId()}`), c.ownerUserId, collab)))
      .rejects.toMatchObject({ code: "admission_denied" });
    await scratch.client`UPDATE outbox_authorization_fixture SET revoked = false WHERE session_id = ${c.sessionId}`;
    await expect(store.admit(withAuthorization(
      admission(c, `stale-member-${newId()}`),
      c.ownerUserId,
      { ...collab, membershipGeneration: 2 },
    ))).rejects.toMatchObject({ code: "stale_authorization" });
    await expect(store.admit(withAuthorization(
      admission(c, `stale-lease-${newId()}`),
      c.ownerUserId,
      { ...collab, leaseGeneration: 6 },
    ))).rejects.toMatchObject({ code: "stale_authorization" });

    poisonRollback = true;
    await expect(store.admit(withAuthorization(admission(c, `rollback-${newId()}`), c.ownerUserId, collab)))
      .rejects.toMatchObject({ code: "stale_authorization" });
    const rows = await scratch.client`
      SELECT
        (SELECT membership_generation FROM outbox_authorization_fixture WHERE session_id = ${c.sessionId}) AS generation,
        (SELECT count(*)::int FROM run_outbox WHERE session_id = ${c.sessionId}) AS outbox,
        (SELECT count(*)::int FROM runs WHERE session_id = ${c.sessionId}) AS runs,
        (SELECT count(*)::int FROM messages WHERE session_id = ${c.sessionId} AND content = 'turn text') AS messages`;
    expect(rows[0]).toEqual({ generation: 3, outbox: 1, runs: 2, messages: 1 });
  });

  it("outbox rejects unknown/secret payload fields and content/key/model inconsistencies without canaries", async () => {
    const c = await context();
    const store = createRunOutboxStore(db, { clock: () => now, authorize: async () => {} });
    const secret = "0033-outbox-payload-secret-canary";
    const variants: Array<(input: AuthorizedAdmission) => void> = [
      (input) => { input.requestPayload = { ...input.requestPayload, token: secret }; },
      (input) => { input.bodyPayload = { ...input.bodyPayload, byokKey: secret }; },
      (input) => { input.requestPayload = { ...input.requestPayload, text: "changed-content" }; },
      (input) => { input.requestPayload = { ...input.requestPayload, idempotencyKey: "changed-key" }; },
      (input) => { input.bodyPayload = { ownerUserId: c.ownerUserId, requestedModel: secret }; },
      (input) => { input.bodyPayload = { ...input.bodyPayload, collab: { leaseId: newId() } }; },
      (input) => { input.bodyPayload = { ownerUserId: `wrong-${newId()}`, requestedModel: null }; },
    ];
    for (const mutate of variants) {
      const input = withAuthorization(admission(c, `strict-${newId()}`), c.ownerUserId);
      mutate(input);
      await expect(store.admit(input)).rejects.toMatchObject({ code: "invalid_request" });
    }
    const rows = await scratch.client`
      SELECT count(*)::int AS count, coalesce(string_agg(row_to_json(run_outbox)::text, ''), '') AS raw
      FROM run_outbox WHERE session_id = ${c.sessionId}`;
    expect(rows[0]?.count).toBe(0);
    expect(rows[0]?.raw).not.toContain(secret);
  });

  it("outbox accepts the strict additive payload and derives trusted run/collab linkage", async () => {
    const c = await context();
    const store = createRunOutboxStore(db, {
      clock: () => now,
      authorize: async (tx: AdmissionTx, input: AuthorizedAdmission) => {
        const rows = await tx.execute(sql`
          SELECT user_id FROM sessions WHERE id = ${input.sessionId} FOR UPDATE`) as unknown as Array<{ user_id: string }>;
        if (rows[0]?.user_id !== c.ownerUserId || input.actorUserId !== c.ownerUserId) {
          throw admissionError("not_found");
        }
      },
    });
    const key = `strict-valid-${newId()}`;
    const attachmentId = newId();
    const input = withAuthorization({
      ...admission(c, key),
      requestPayload: {
        schemaVersion: 1,
        idempotencyKey: key,
        text: "turn text",
        model: "provider/model",
        attachmentIds: [attachmentId],
      },
      bodyPayload: { ownerUserId: c.ownerUserId, requestedModel: "provider/model" },
    }, c.ownerUserId);
    const row = await store.admit(input);
    expect(row.requestPayload).toEqual({
      schemaVersion: 1,
      idempotencyKey: key,
      text: "turn text",
      model: "provider/model",
      attachmentIds: [attachmentId],
    });
    expect(row.bodyPayload).toEqual({
      ownerUserId: c.ownerUserId,
      requestedModel: "provider/model",
      userId: c.actorUserId,
      sessionId: c.sessionId,
      runId: row.runId,
    });
    expect(row.jobId).toBe(row.runId);
  });
});
