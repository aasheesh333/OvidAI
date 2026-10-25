import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { and, eq } from "drizzle-orm";
import {
  accountSettings,
  byokKeysRepo,
  createDb,
  newId,
  schema,
  type Db,
} from "@ovid/db";
import { manualModelsAllowed } from "@ovid/shared";
import {
  createAgentRunsWorker,
  createQueues,
} from "@ovid/queue";
import {
  createCollabTurnExecutor,
  type CollabQueueJobState,
  type CollabTurnQueue,
} from "./turnExecutor.js";
import type { CollabAgentRunJob, CollabTurnRequest } from "./turnPlan.js";
import { CollabMembership } from "./membership.js";
import type { AuthPrincipal } from "../auth.js";

// UNEXECUTED under HEAVY-COMMANDS-PAUSED.md. These are authored real-Postgres
// regressions for a later permitted gate, not runtime evidence or a pass claim.

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const AUTHORITY_SECRET = "collab-turn-executor-test-authority-secret-32bytes";
const T0 = new Date("2026-10-25T00:00:00.000Z");

class QueueFake implements CollabTurnQueue {
  readonly attempts: Array<{
    name: "agent-run";
    data: CollabAgentRunJob;
    options: { jobId: string; priority: 1 | 2 };
  }> = [];
  fail = false;
  onAdd?: () => Promise<void>;
  retried = 0;
  private job?: {
    state: CollabQueueJobState;
    getState(): Promise<CollabQueueJobState>;
    updateData(data: CollabAgentRunJob): Promise<void>;
    retry(state: "completed" | "failed"): Promise<void>;
  };

  async add(
    name: "agent-run",
    data: CollabAgentRunJob,
    options: { jobId: string; priority: 1 | 2 },
  ) {
    this.attempts.push({ name, data, options });
    if (this.job === undefined) {
      this.job = {
        state: "waiting",
        getState: async () => this.job!.state,
        updateData: async (_data) => {},
        retry: async (_state) => {
          this.job!.state = "waiting";
          this.retried += 1;
        },
      };
    }
    await this.onAdd?.();
    if (this.fail) throw new Error("queue offline");
    return this.job;
  }

  async getJob(_jobId: string) {
    return this.job;
  }

  settle(state: "completed" | "failed"): void {
    if (this.job === undefined) throw new Error("no delivered job to settle");
    this.job.state = state;
  }
}

function principal(uid: string): AuthPrincipal {
  return { uid, email: null, authTime: 1 };
}

function request(key = `turn-${newId()}`, text = "hello collaborators"): CollabTurnRequest {
  return {
    schemaVersion: 1,
    idempotencyKey: key,
    text,
    model: "provider/model",
  };
}

describe.skipIf(!TEST_DATABASE_URL).sequential("Collab canonical turn executor (UNEXECUTED)", () => {
  let db: Db;
  let secondDb: Db;
  let clock: Date;

  beforeAll(async () => {
    db = createDb(TEST_DATABASE_URL!, { max: 16 });
    secondDb = createDb(TEST_DATABASE_URL!, { max: 16 });
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await secondDb?.$client.end({ timeout: 5 });
  }, 30_000);

  async function fixture() {
    clock = new Date(T0);
    const owner = `owner-${newId()}`;
    const sender = `sender-${newId()}`;
    const membership = new CollabMembership(db, { authoritySecret: AUTHORITY_SECRET });
    const created = await membership.createRoom({
      principal: principal(owner), requestId: `create-${newId()}`,
    });
    const invite = await membership.createInvite({
      principal: principal(owner),
      token: created.sessionToken,
      idempotencyKey: `invite-${newId()}`,
      maxUses: 2,
      ttlSeconds: 60,
    });
    await membership.join({
      principal: principal(sender),
      token: created.sessionToken,
      inviteCode: invite.inviteCode,
      idempotencyKey: `join-${newId()}`,
    });
    const authorization = await membership.authorize({
      principal: principal(sender), token: created.sessionToken,
    });
    await db.update(schema.users).set({ tier: "plus" }).where(eq(schema.users.uid, sender));
    expect(manualModelsAllowed("plus")).toBe(true);
    return { owner, sender, created, authorization };
  }

  function executor(queue: QueueFake, connection: Db = db) {
    return createCollabTurnExecutor({ db: connection, queue, now: () => new Date(clock) });
  }

  async function counts(sessionId: string, actorUserId: string, key: string) {
    const rows = await db.$client`
      SELECT
        (SELECT count(*)::int FROM messages WHERE session_id = ${sessionId}) AS messages,
        (SELECT count(*)::int FROM runs WHERE session_id = ${sessionId}) AS runs,
        (SELECT count(*)::int FROM collab_turns WHERE room_id IN
          (SELECT id FROM collab_rooms WHERE session_id = ${sessionId})) AS turns,
        (SELECT count(*)::int FROM collab_sender_leases WHERE room_id IN
          (SELECT id FROM collab_rooms WHERE session_id = ${sessionId})) AS leases,
        (SELECT count(*)::int FROM run_outbox WHERE session_id = ${sessionId}) AS outbox,
        (SELECT count(*)::int FROM usage_run_admissions
          WHERE actor_user_id = ${actorUserId} AND idempotency_key = ${key}) AS admissions`;
    return rows[0]!;
  }

  it("admits exact canonical IDs/payload/result in one commit and publishes afterward", async () => {
    const f = await fixture();
    const queue = new QueueFake();
    const req = request();
    const admitted = await executor(queue).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: req,
      catalog: { state: "known", modelIds: ["provider/model"] },
    });

    expect(admitted.kind).toBe("admitted");
    expect(admitted.result).toEqual({
      schemaVersion: 1,
      turnId: expect.any(String) as string,
      runId: expect.any(String) as string,
      userMessageId: expect.any(String) as string,
      userEventId: `message:${admitted.result.userMessageId}`,
      status: "queued",
      model: "provider/model",
    });
    expect(queue.attempts).toEqual([]);

    const rows = await db.$client`
      SELECT o.*, m.role, m.content, r.prompt_message_id, t.participant_id,
             t.actor_user_id, l.id AS lease_id, l.generation AS lease_generation
        FROM run_outbox o
        JOIN messages m ON m.id = o.user_message_id
        JOIN runs r ON r.id = o.run_id
        JOIN collab_turns t ON t.run_id = o.run_id
        JOIN collab_sender_leases l ON l.run_id = o.run_id
       WHERE o.outbox_id = ${admitted.outboxId}`;
    const stored = rows[0]!;
    expect(stored).toMatchObject({
      actor_user_id: f.sender,
      session_id: f.created.session.sessionId,
      run_id: admitted.result.runId,
      user_message_id: admitted.result.userMessageId,
      idempotency_key: req.idempotencyKey,
      status: "queued",
      job_id: admitted.result.runId,
      role: "user",
      content: req.text,
      prompt_message_id: admitted.result.userMessageId,
      participant_id: f.authorization.participantId,
      actor_user_id: f.sender,
    });
    expect(stored.body_payload).toEqual({
      ownerUserId: f.owner,
      requestedModel: "provider/model",
      userId: f.sender,
      sessionId: f.created.session.sessionId,
      runId: admitted.result.runId,
      modelContext: {
        requestedModel: "provider/model",
        byokKeyId: null,
        temperature: null,
        actorUserId: f.sender,
      },
      byokKeyId: null,
      tier: "free",
      queuePriority: 1,
      collab: {
        roomId: f.authorization.roomId,
        participantId: f.authorization.participantId,
        membershipGeneration: f.authorization.membershipGeneration,
        leaseId: stored.lease_id,
        leaseGeneration: Number(stored.lease_generation),
        outboxId: admitted.outboxId,
        rootRunId: admitted.result.runId,
      },
    });
    expect(stored.body_payload).not.toHaveProperty("actorUserId");
    expect(f.authorization.participantId).toMatch(/^p[0-9a-f]{32}$/);
    expect(stored.body_payload).not.toHaveProperty("actorUserId");

    const replay = await executor(queue).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: req,
      catalog: { state: "unavailable" },
    });
    expect(replay).toEqual({ kind: "replay", result: admitted.result, outboxId: admitted.outboxId });
    expect(await counts(f.created.session.sessionId, f.sender, `run:${admitted.result.runId}:collab`))
      .toMatchObject({ messages: 1, runs: 1, turns: 1, leases: 1, outbox: 1, admissions: 1 });

    const published = await executor(queue).publish({ outboxId: admitted.outboxId });
    expect(published).toEqual({ kind: "published", outboxId: admitted.outboxId });
    expect(queue.attempts).toHaveLength(1);
    expect(queue.attempts[0]).toMatchObject({
      name: "agent-run",
      data: {
        runId: admitted.result.runId,
        sessionId: f.created.session.sessionId,
        userId: f.owner,
        ownerUserId: f.owner,
        actorUserId: f.sender,
        source: "collab",
        requestedModel: "provider/model",
        tier: "free",
        byokKeyId: null,
        modelContext: {
          requestedModel: "provider/model",
          byokKeyId: null,
          temperature: null,
          actorUserId: f.sender,
        },
        collabPublication: {
          outboxStatus: "published",
          outboxAttempts: 1,
          runStatus: "queued",
          turnStatus: "queued",
        },
        collab: {
          participantId: f.authorization.participantId,
          outboxId: admitted.outboxId,
          rootRunId: admitted.result.runId,
        },
      },
      options: { jobId: admitted.result.runId, priority: 1 },
    });
  });

  it("persists and recovers the accepted BYOK/model snapshot, sender priority and host tier", async () => {
    const f = await fixture();
    const acceptedKey = await byokKeysRepo.create(db, {
      userId: f.sender,
      providerId: "openai",
      endpoint: "https://api.openai.com/v1",
      wrappedDek: "wrapped",
      iv: "iv",
      ciphertext: "ciphertext",
      tag: "tag",
    });
    await accountSettings.patch(db, f.sender, {
      byokDefault: { keyId: acceptedKey.id, model: "gpt-4.1-mini" },
    });
    const admitted = await executor(new QueueFake()).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });

    // Mutable current settings are not recovery authority. The accepted sender
    // BYOK and priority plus the accepted host workspace tier must not drift.
    await accountSettings.patch(db, f.sender, { byokDefault: null });
    await db.update(schema.users).set({ tier: "free" }).where(eq(schema.users.uid, f.sender));
    await db.update(schema.users).set({ tier: "pro" }).where(eq(schema.users.uid, f.owner));

    const recoveryQueue = new QueueFake();
    expect(await executor(recoveryQueue, secondDb).publish({ outboxId: admitted.outboxId }))
      .toEqual({ kind: "published", outboxId: admitted.outboxId });
    expect(recoveryQueue.attempts).toHaveLength(1);
    expect(recoveryQueue.attempts[0]).toMatchObject({
      data: {
        userId: f.owner,
        ownerUserId: f.owner,
        actorUserId: f.sender,
        requestedModel: "provider/model",
        tier: "free",
        byokKeyId: acceptedKey.id,
        byokModel: "gpt-4.1-mini",
        modelContext: {
          requestedModel: "provider/model",
          byokKeyId: acceptedKey.id,
          byokModel: "gpt-4.1-mini",
          temperature: null,
          actorUserId: f.sender,
        },
      },
      options: { jobId: admitted.result.runId, priority: 1 },
    });
    const stored = await db.$client`SELECT body_payload FROM run_outbox WHERE outbox_id = ${admitted.outboxId}`;
    expect(stored[0]!.body_payload).toMatchObject({
      byokKeyId: acceptedKey.id,
      byokModel: "gpt-4.1-mini",
      tier: "free",
      queuePriority: 1,
      modelContext: {
        byokKeyId: acceptedKey.id,
        byokModel: "gpt-4.1-mini",
        actorUserId: f.sender,
      },
    });
  });

  it("rejects unknown model/catalog outage before any canonical write", async () => {
    const f = await fixture();
    const queue = new QueueFake();
    for (const catalog of [
      { state: "known", modelIds: ["another/model"] },
      { state: "known", modelIds: [] },
      { state: "unavailable" },
    ] as const) {
      await expect(executor(queue).admit({
        actorUserId: f.sender,
        authorization: f.authorization,
        request: request(),
        catalog,
      })).rejects.toMatchObject({
        code: catalog.state === "known" && catalog.modelIds.length > 0
          ? "model_unavailable"
          : "temporarily_unavailable",
      });
    }
    expect(await counts(f.created.session.sessionId, f.sender, "none"))
      .toMatchObject({ messages: 0, runs: 0, turns: 0, leases: 0, outbox: 0, admissions: 0 });
    expect(queue.attempts).toEqual([]);
  });

  it("re-reads changed sender plan and selected BYOK after the account lock", async () => {
    const planFixture = await fixture();
    let markPlanLocked!: () => void;
    const planLocked = new Promise<void>((resolve) => { markPlanLocked = resolve; });
    let releasePlan!: () => void;
    const planGate = new Promise<void>((resolve) => { releasePlan = resolve; });
    const planBlocker = secondDb.transaction(async (tx) => {
      await tx.select().from(schema.users).where(eq(schema.users.uid, planFixture.sender)).for("update");
      markPlanLocked();
      await planGate;
      await tx.update(schema.users).set({ tier: "free" }).where(eq(schema.users.uid, planFixture.sender));
    });
    await planLocked;
    const planAdmission = executor(new QueueFake()).admit({
      actorUserId: planFixture.sender,
      authorization: planFixture.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    releasePlan();
    await expect(planAdmission).rejects.toMatchObject({ code: "manual_model_not_allowed" });
    await planBlocker;

    const byokFixture = await fixture();
    const key = await byokKeysRepo.create(db, {
      userId: byokFixture.sender,
      providerId: "openai",
      endpoint: "https://api.openai.com/v1",
      wrappedDek: "wrapped",
      iv: "iv",
      ciphertext: "ciphertext",
      tag: "tag",
    });
    await accountSettings.patch(db, byokFixture.sender, {
      byokDefault: { keyId: key.id, model: "gpt-4.1-mini" },
    });
    let markKeyLocked!: () => void;
    const keyLocked = new Promise<void>((resolve) => { markKeyLocked = resolve; });
    let releaseKey!: () => void;
    const keyGate = new Promise<void>((resolve) => { releaseKey = resolve; });
    const keyBlocker = secondDb.transaction(async (tx) => {
      await tx.select().from(schema.users).where(eq(schema.users.uid, byokFixture.sender)).for("update");
      markKeyLocked();
      await keyGate;
      await tx.delete(schema.byokKeys).where(and(
        eq(schema.byokKeys.id, key.id), eq(schema.byokKeys.userId, byokFixture.sender),
      ));
    });
    await keyLocked;
    const byokAdmission = executor(new QueueFake()).admit({
      actorUserId: byokFixture.sender,
      authorization: byokFixture.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    releaseKey();
    await expect(byokAdmission).rejects.toMatchObject({ code: "key_not_minted" });
    await keyBlocker;
    expect(await counts(byokFixture.created.session.sessionId, byokFixture.sender, "none"))
      .toMatchObject({ messages: 0, runs: 0, turns: 0, leases: 0, outbox: 0 });
  });

  it("sender quota exhaustion rolls back message/run/turn/lease/outbox in the same transaction", async () => {
    const f = await fixture();
    const queue = new QueueFake();
    const exhausted = {
      forTransaction: () => ({
        admitRun: async () => ({ ok: false as const, window: "day" as const, resetsAt: T0 }),
      }),
    };
    const req = request();
    await expect(createCollabTurnExecutor({
      db, queue, quota: exhausted, now: () => clock,
    }).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: req,
      catalog: { state: "known", modelIds: ["provider/model"] },
    })).rejects.toMatchObject({ code: "quota_exceeded" });

    expect(await counts(f.created.session.sessionId, f.sender, "unused"))
      .toMatchObject({ messages: 0, runs: 0, turns: 0, leases: 0, outbox: 0, admissions: 0 });
    expect(queue.attempts).toEqual([]);
  });

  it("two gateways have one winner, same-key originals, and changed-payload conflict", async () => {
    const same = await fixture();
    const req = request();
    const results = await Promise.all([
      executor(new QueueFake(), db).admit({
        actorUserId: same.sender, authorization: same.authorization, request: req,
        catalog: { state: "known", modelIds: ["provider/model"] },
      }),
      executor(new QueueFake(), secondDb).admit({
        actorUserId: same.sender, authorization: same.authorization, request: req,
        catalog: { state: "known", modelIds: ["provider/model"] },
      }),
    ]);
    expect(results.map((result) => result.kind).sort()).toEqual(["admitted", "replay"]);
    expect(results[0]!.result).toEqual(results[1]!.result);
    expect(results[0]!.outboxId).toBe(results[1]!.outboxId);
    expect(await counts(same.created.session.sessionId, same.sender, `run:${results[0]!.result.runId}:collab`))
      .toMatchObject({ messages: 1, runs: 1, turns: 1, leases: 1, outbox: 1, admissions: 1 });

    const changed = await fixture();
    const key = `shared-${newId()}`;
    const conflict = await Promise.allSettled([
      executor(new QueueFake(), db).admit({
        actorUserId: changed.sender, authorization: changed.authorization, request: request(key, "original"),
        catalog: { state: "known", modelIds: ["provider/model"] },
      }),
      executor(new QueueFake(), secondDb).admit({
        actorUserId: changed.sender, authorization: changed.authorization, request: request(key, "changed"),
        catalog: { state: "known", modelIds: ["provider/model"] },
      }),
    ]);
    expect(conflict.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejected = conflict.find((result) => result.status === "rejected");
    expect(rejected).toMatchObject({ reason: { code: "request_already_used" } });
    expect(await counts(changed.created.session.sessionId, changed.sender, "unused"))
      .toMatchObject({ messages: 1, runs: 1, turns: 1, leases: 1, outbox: 1 });

    const busy = await fixture();
    const competing = await Promise.allSettled([
      executor(new QueueFake(), db).admit({
        actorUserId: busy.sender, authorization: busy.authorization, request: request(),
        catalog: { state: "known", modelIds: ["provider/model"] },
      }),
      executor(new QueueFake(), secondDb).admit({
        actorUserId: busy.sender, authorization: busy.authorization, request: request(),
        catalog: { state: "known", modelIds: ["provider/model"] },
      }),
    ]);
    expect(competing.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(competing.find((result) => result.status === "rejected"))
      .toMatchObject({ reason: { code: "sender_busy" } });
    expect(await counts(busy.created.session.sessionId, busy.sender, "unused"))
      .toMatchObject({ messages: 1, runs: 1, turns: 1, leases: 1, outbox: 1 });
  });

  it("replay rejects a tampered durable turn/message linkage without creating another run", async () => {
    const f = await fixture();
    const req = request();
    const admitted = await executor(new QueueFake()).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: req,
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    const otherMessage = newId();
    await db.insert(schema.messages).values({
      id: otherMessage,
      sessionId: f.created.session.sessionId,
      role: "user",
      content: "unrelated",
    });
    await db.update(schema.collabTurns).set({ userMessageId: otherMessage })
      .where(eq(schema.collabTurns.runId, admitted.result.runId));

    await expect(executor(new QueueFake(), secondDb).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: req,
      catalog: { state: "known", modelIds: ["provider/model"] },
    })).rejects.toMatchObject({ code: "invalid_record" });
    const runs = await db.$client`SELECT count(*)::int AS count FROM runs WHERE session_id = ${f.created.session.sessionId}`;
    expect(runs[0]).toEqual({ count: 1 });
  });

  it("post-decision revocation fails pre-add CAS without enqueueing stale work", async () => {
    const f = await fixture();
    const queue = new QueueFake();
    const membership = new CollabMembership(db, { authoritySecret: AUTHORITY_SECRET });
    let interleaved = 0;
    const service = createCollabTurnExecutor({
      db,
      queue,
      now: () => clock,
      afterDecision: async () => {
        interleaved += 1;
        await membership.remove({
          principal: principal(f.owner),
          token: f.created.sessionToken,
          participantId: f.authorization.participantId,
        });
      },
    });
    const admitted = await service.admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });

    expect(await service.publish({ outboxId: admitted.outboxId }))
      .toEqual({ kind: "fenced", code: "stale_authorization" });
    expect(interleaved).toBe(1);
    expect(queue.attempts).toEqual([]);
    const rows = await db.$client`
      SELECT o.status AS outbox_status, o.attempts, r.status AS run_status,
             t.cancel_requested_at, l.cancel_requested_at AS lease_cancel
        FROM run_outbox o
        JOIN runs r ON r.id = o.run_id
        JOIN collab_turns t ON t.run_id = o.run_id
        JOIN collab_sender_leases l ON l.run_id = o.run_id
       WHERE o.outbox_id = ${admitted.outboxId}`;
    expect(rows[0]).toMatchObject({
      outbox_status: "queued",
      attempts: 0,
      run_status: "queued",
    });
    expect(rows[0]!.cancel_requested_at).not.toBeNull();
    expect(rows[0]!.lease_cancel).not.toBeNull();
  });

  it("post-decision close, lease release and run/turn cancellation also suppress queue add", async () => {
    for (const scenario of ["close", "release", "cancel"] as const) {
      const f = await fixture();
      const queue = new QueueFake();
      const service = createCollabTurnExecutor({
        db,
        queue,
        now: () => clock,
        afterDecision: async () => {
          if (scenario === "close") {
            await db.update(schema.collabRooms)
              .set({ lifecycle: "closed", generation: f.authorization.roomGeneration + 1 })
              .where(eq(schema.collabRooms.id, f.authorization.roomId));
          } else if (scenario === "release") {
            await db.update(schema.collabSenderLeases)
              .set({ releasedAt: T0, cancelRequestedAt: T0, generation: 10 })
              .where(eq(schema.collabSenderLeases.runId, admitted.result.runId));
          } else {
            await db.update(schema.runs).set({ cancelRequested: true })
              .where(eq(schema.runs.id, admitted.result.runId));
            await db.update(schema.collabTurns).set({ cancelRequestedAt: T0 })
              .where(eq(schema.collabTurns.runId, admitted.result.runId));
          }
        },
      });
      const admitted = await service.admit({
        actorUserId: f.sender,
        authorization: f.authorization,
        request: request(),
        catalog: { state: "known", modelIds: ["provider/model"] },
      });

      expect(await service.publish({ outboxId: admitted.outboxId }))
        .toMatchObject({ kind: "fenced" });
      expect(queue.attempts).toEqual([]);
    }
  });

  it("queue failure/retry/restart preserves rows, job and one sender quota admission", async () => {
    const f = await fixture();
    const req = request();
    const firstQueue = new QueueFake();
    firstQueue.fail = true;
    const admitted = await executor(firstQueue).admit({
      actorUserId: f.sender, authorization: f.authorization, request: req,
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    expect(await executor(firstQueue).publish({ outboxId: admitted.outboxId }))
      .toEqual({ kind: "publish_unknown", outboxId: admitted.outboxId, error: "queue_outcome_unknown" });
    const unknown = await db.$client`
      SELECT status, attempts, published_at, last_error FROM run_outbox WHERE outbox_id = ${admitted.outboxId}`;
    expect(unknown[0]).toMatchObject({
      status: "published",
      attempts: 1,
      published_at: null,
      last_error: "queue_outcome_unknown",
    });

    const recoveryQueue = new QueueFake();
    const restarted = executor(recoveryQueue, secondDb);
    expect(await restarted.publish({ outboxId: admitted.outboxId }))
      .toEqual({ kind: "published", outboxId: admitted.outboxId });
    expect(recoveryQueue.attempts).toHaveLength(1);
    const firstAttempt = firstQueue.attempts[0]!;
    const recoveredAttempt = recoveryQueue.attempts[0]!;
    const { collabPublication: firstToken, ...firstExecution } = firstAttempt.data;
    const { collabPublication: recoveredToken, ...recoveredExecution } = recoveredAttempt.data;
    expect(recoveredExecution).toEqual(firstExecution);
    expect(recoveredToken).toMatchObject({
      ...firstToken!,
      outboxAttempts: firstToken!.outboxAttempts + 1,
    });
    expect(recoveredAttempt.options).toEqual(firstAttempt.options);
    expect(recoveredAttempt.options.jobId).toBe(admitted.result.runId);

    const beforeReplay = await counts(f.created.session.sessionId, f.sender, `run:${admitted.result.runId}:collab`);
    expect(beforeReplay).toMatchObject({ messages: 1, runs: 1, turns: 1, leases: 1, outbox: 1, admissions: 1 });
    expect(await restarted.publish({ outboxId: admitted.outboxId }))
      .toEqual({ kind: "noop", reason: "published" });
    expect(recoveryQueue.attempts).toHaveLength(1);
    expect(await counts(f.created.session.sessionId, f.sender, `run:${admitted.result.runId}:collab`))
      .toEqual(beforeReplay);
  });

  it("an ambiguous add stays unknown until running execution reconciles the marker", async () => {
    const f = await fixture();
    const queue = new QueueFake();
    queue.fail = true;
    queue.onAdd = async () => {
      await db.update(schema.runs).set({ status: "running", startedAt: T0 })
        .where(eq(schema.runs.id, admitted.result.runId));
      await db.update(schema.collabTurns).set({ status: "running" })
        .where(eq(schema.collabTurns.runId, admitted.result.runId));
    };
    const admitted = await executor(queue).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });

    expect(await executor(queue).publish({ outboxId: admitted.outboxId }))
      .toEqual({ kind: "publish_unknown", outboxId: admitted.outboxId, error: "queue_outcome_unknown" });
    expect(await executor(queue, secondDb).publish({ outboxId: admitted.outboxId }))
      .toEqual({ kind: "reconciled", outboxId: admitted.outboxId });
    const stored = await db.$client`
      SELECT status, attempts, published_at FROM run_outbox WHERE outbox_id = ${admitted.outboxId}`;
    expect(stored[0]).toMatchObject({ status: "published", attempts: 1 });
    expect(stored[0]!.published_at).not.toBeNull();
  });

  it("delivered-thrown add never confirms from retained dedupe; stale delivery is replaced before retry", async () => {
    const f = await fixture();
    const queue = new QueueFake();
    queue.fail = true;
    const admitted = await executor(queue).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });

    expect(await executor(queue).publish({ outboxId: admitted.outboxId }))
      .toEqual({ kind: "publish_unknown", outboxId: admitted.outboxId, error: "queue_outcome_unknown" });
    const unknown = await db.$client`
      SELECT status, attempts, published_at FROM run_outbox WHERE outbox_id = ${admitted.outboxId}`;
    expect(unknown[0]).toMatchObject({ status: "published", attempts: 1, published_at: null });

    // The delivered first attempt settles without claiming. Retained dedupe is
    // not live evidence; recovery must atomically retry it with the new token.
    queue.fail = false;
    queue.settle("completed");
    expect(await executor(queue, secondDb).publish({ outboxId: admitted.outboxId }))
      .toEqual({ kind: "published", outboxId: admitted.outboxId });
    expect(queue.retried).toBe(1);
    expect(queue.attempts).toHaveLength(2);
    expect(queue.attempts[1]!.options.jobId).toBe(admitted.result.runId);
    expect(queue.attempts[1]!.data.collabPublication?.outboxAttempts).toBe(2);
    const recovered = await db.$client`
      SELECT status, attempts, published_at FROM run_outbox WHERE outbox_id = ${admitted.outboxId}`;
    expect(recovered[0]).toMatchObject({ status: "published", attempts: 2 });
    expect(recovered[0]!.published_at).not.toBeNull();
  });

  it.skipIf(!TEST_REDIS_URL)("real BullMQ delivered-throw, settled no-op, retained dedupe and valid retry (UNEXECUTED)", async () => {
    const f = await fixture();
    const admitted = await executor(new QueueFake()).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    const prefix = `collab-turn-recovery-${newId()}`;
    const queues = createQueues({ url: TEST_REDIS_URL! }, { prefix });
    let throwAfterDelivery = true;
    const queue: CollabTurnQueue = {
      add: async (name, data, options) => {
        const job = await queues.agentRuns.add(name, data, options);
        if (throwAfterDelivery) {
          throwAfterDelivery = false;
          throw new Error("delivery acknowledged locally, ack lost to caller");
        }
        return job;
      },
      getJob: (jobId) => queues.agentRuns.getJob(jobId),
    };

    try {
      expect(await executor(queue).publish({ outboxId: admitted.outboxId }))
        .toEqual({ kind: "publish_unknown", outboxId: admitted.outboxId, error: "queue_outcome_unknown" });

      const worker = createAgentRunsWorker({ url: TEST_REDIS_URL! }, async () => {}, { prefix });
      try {
        await new Promise<void>((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error("first delivered job did not settle")), 10_000);
          worker.once("completed", () => {
            clearTimeout(timer);
            resolve();
          });
          worker.once("error", (error) => {
            clearTimeout(timer);
            reject(error);
          });
        });
      } finally {
        await worker.close();
      }
      // The no-op processor settled without claiming, so the canonical run is
      // still queued. Re-adding the retained job would only dedupe, not execute.
      expect(await executor(queue, secondDb).publish({ outboxId: admitted.outboxId }))
        .toEqual({ kind: "published", outboxId: admitted.outboxId });
      const retained = await queues.agentRuns.getJob(admitted.result.runId);
      expect(["waiting", "prioritized"]).toContain(await retained!.getState());
      const stored = await db.$client`
        SELECT status, attempts, published_at FROM run_outbox WHERE outbox_id = ${admitted.outboxId}`;
      expect(stored[0]).toMatchObject({ status: "published", attempts: 2 });
      expect(stored[0]!.published_at).not.toBeNull();
    } finally {
      await queues.agentRuns.obliterate({ force: true });
      await Promise.all([
        queues.agentRuns.close(),
        queues.hibernate.close(),
        queues.hydrate.close(),
        queues.schedules.close(),
      ]);
    }
  });

  it("confirmed delivery that later settles without a run is reopened, not a published noop", async () => {
    const f = await fixture();
    const queue = new QueueFake();
    const admitted = await executor(queue).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    expect(await executor(queue).publish({ outboxId: admitted.outboxId }))
      .toEqual({ kind: "published", outboxId: admitted.outboxId });

    queue.settle("completed");
    expect(await executor(queue, secondDb).publish({ outboxId: admitted.outboxId }))
      .toEqual({ kind: "published", outboxId: admitted.outboxId });
    expect(queue.retried).toBe(1);
    const stored = await db.$client`
      SELECT status, attempts, published_at FROM run_outbox WHERE outbox_id = ${admitted.outboxId}`;
    expect(stored[0]).toMatchObject({ status: "published", attempts: 2 });
    expect(stored[0]!.published_at).not.toBeNull();
  });

  it("two recovery publishers cannot let an ambiguous failure overwrite a successful add", async () => {
    const f = await fixture();
    const admitted = await executor(new QueueFake()).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    // Simulate the crash window after reservation but before queue delivery.
    await db.update(schema.runOutbox).set({
      status: "published",
      attempts: 1,
      publishedAt: null,
      lastAttemptAt: T0,
    }).where(eq(schema.runOutbox.outboxId, admitted.outboxId));

    let arrived = 0;
    let release!: () => void;
    const bothDecided = new Promise<void>((resolve) => { release = resolve; });
    const afterDecision = async () => {
      arrived += 1;
      if (arrived === 2) release();
      await bothDecided;
    };
    const successQueue = new QueueFake();
    const failureQueue = new QueueFake();
    failureQueue.fail = true;
    const successService = createCollabTurnExecutor({
      db,
      queue: successQueue,
      now: () => clock,
      afterDecision,
    });
    const results = await Promise.all([
      successService.publish({ outboxId: admitted.outboxId }),
      createCollabTurnExecutor({ db: secondDb, queue: failureQueue, now: () => clock, afterDecision })
        .publish({ outboxId: admitted.outboxId }),
    ]);
    if (!results.some((result) => result.kind === "published")) {
      // A thrown winner is UNKNOWN, not a terminal failure. A later publisher
      // with a live queue may advance the attempt and complete recovery.
      results.push(await successService.publish({ outboxId: admitted.outboxId }));
    }

    expect(results.some((result) => result.kind === "published")).toBe(true);
    expect(results.every((result) =>
      result.kind === "published" || result.kind === "publish_unknown" || result.kind === "fenced"
    )).toBe(true);
    const stored = await db.$client`
      SELECT status, attempts, published_at FROM run_outbox WHERE outbox_id = ${admitted.outboxId}`;
    expect(stored[0]!.status).toBe("published");
    expect(Number(stored[0]!.attempts)).toBeGreaterThanOrEqual(2);
    expect(stored[0]!.published_at).not.toBeNull();
    for (const attempt of [...successQueue.attempts, ...failureQueue.attempts]) {
      expect(attempt.options.jobId).toBe(admitted.result.runId);
    }
  });

  it("running-outbox reconciliation uses one lock/CAS without an independent markPublished lock cycle", async () => {
    const f = await fixture();
    const admitted = await executor(new QueueFake()).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    await db.update(schema.runs).set({ status: "running", startedAt: T0 })
      .where(eq(schema.runs.id, admitted.result.runId));
    await db.update(schema.collabTurns).set({ status: "running" })
      .where(eq(schema.collabTurns.runId, admitted.result.runId));

    const results = await Promise.all([
      executor(new QueueFake(), db).publish({ outboxId: admitted.outboxId }),
      executor(new QueueFake(), secondDb).publish({ outboxId: admitted.outboxId }),
    ]);
    expect(results.every((result) => result.kind === "reconciled" || result.kind === "noop")).toBe(true);
    const stored = await db.$client`
      SELECT status, attempts, published_at FROM run_outbox WHERE outbox_id = ${admitted.outboxId}`;
    expect(stored[0]).toMatchObject({ status: "published", attempts: 1 });
    expect(stored[0]!.published_at).not.toBeNull();
  });

  it("durable running/terminal state distinguishes marker reconciliation, settlement and fencing", async () => {
    const runningFixture = await fixture();
    const runningQueue = new QueueFake();
    const running = await executor(runningQueue).admit({
      actorUserId: runningFixture.sender,
      authorization: runningFixture.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    await db.update(schema.runs).set({ status: "running", startedAt: T0 })
      .where(eq(schema.runs.id, running.result.runId));
    await db.update(schema.collabTurns).set({ status: "running" })
      .where(eq(schema.collabTurns.runId, running.result.runId));
    expect(await executor(runningQueue, secondDb).publish({ outboxId: running.outboxId }))
      .toEqual({ kind: "reconciled", outboxId: running.outboxId });
    expect(runningQueue.attempts).toEqual([]);

    await db.update(schema.runs).set({ status: "completed", finishedAt: T0 })
      .where(eq(schema.runs.id, running.result.runId));
    await db.update(schema.collabTurns).set({ status: "completed" })
      .where(eq(schema.collabTurns.runId, running.result.runId));
    await db.update(schema.collabSenderLeases).set({ releasedAt: T0 })
      .where(eq(schema.collabSenderLeases.runId, running.result.runId));
    expect(await executor(runningQueue, secondDb).publish({ outboxId: running.outboxId }))
      .toEqual({ kind: "settled", outboxId: running.outboxId });
    expect(runningQueue.attempts).toEqual([]);

    const terminalFixture = await fixture();
    const terminalQueue = new QueueFake();
    const terminal = await executor(terminalQueue).admit({
      actorUserId: terminalFixture.sender,
      authorization: terminalFixture.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    await db.update(schema.runs).set({ status: "completed", finishedAt: T0 })
      .where(eq(schema.runs.id, terminal.result.runId));
    await db.update(schema.collabTurns).set({ status: "completed" })
      .where(eq(schema.collabTurns.runId, terminal.result.runId));
    expect(await executor(terminalQueue, secondDb).publish({ outboxId: terminal.outboxId }))
      .toEqual({ kind: "fenced", code: "terminal_outbox_unreconciled" });
    expect(terminalQueue.attempts).toEqual([]);
  });

  it("heartbeat is conditional and stale recovery increments/fences without inventing timeout", async () => {
    const f = await fixture();
    const queue = new QueueFake();
    const admitted = await executor(queue).admit({
      actorUserId: f.sender, authorization: f.authorization, request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    const leaseRows = await db.$client`
      SELECT id, generation, holder_participant_id FROM collab_sender_leases WHERE run_id = ${admitted.result.runId}`;
    const lease = leaseRows[0]!;
    clock = new Date(T0.getTime() + 10_000);
    expect(await executor(queue).heartbeat({
      leaseId: lease.id,
      generation: Number(lease.generation),
      holderId: lease.holder_participant_id,
      runId: admitted.result.runId,
    })).toBe(true);
    expect(await executor(queue).heartbeat({
      leaseId: lease.id,
      generation: Number(lease.generation) - 1,
      holderId: lease.holder_participant_id,
      runId: admitted.result.runId,
    })).toBe(false);
    clock = new Date(T0.getTime() + 45_000);
    expect(await executor(queue).recoverStaleLeases()).toEqual([]);

    clock = new Date(T0.getTime() + 56_000);
    expect(await executor(queue).recoverStaleLeases()).toEqual([lease.id]);
    const fenced = await db.$client`
      SELECT l.generation, l.released_at, l.cancel_requested_at,
             r.cancel_requested, r.status AS run_status, t.status AS turn_status,
             t.cancel_requested_at AS turn_cancel
        FROM collab_sender_leases l
        JOIN runs r ON r.id = l.run_id
        JOIN collab_turns t ON t.run_id = l.run_id
       WHERE l.id = ${lease.id}`;
    expect(Number(fenced[0]!.generation)).toBeGreaterThan(Number(lease.generation));
    expect(fenced[0]).toMatchObject({
      cancel_requested: true,
      run_status: "queued",
      turn_status: "queued",
    });
    expect(fenced[0]!.released_at).not.toBeNull();
    expect(fenced[0]!.cancel_requested_at).not.toBeNull();
    expect(fenced[0]!.turn_cancel).not.toBeNull();
    expect(await executor(queue).publish({ outboxId: admitted.outboxId }))
      .toMatchObject({ kind: "fenced", code: "stale_authorization" });
    expect(await executor(queue).heartbeat({
      leaseId: lease.id,
      generation: Number(lease.generation),
      holderId: lease.holder_participant_id,
      runId: admitted.result.runId,
    })).toBe(false);

    const next = await executor(queue).admit({
      actorUserId: f.sender,
      authorization: f.authorization,
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    });
    expect(next.kind).toBe("admitted");
    const active = await db.$client`
      SELECT count(*)::int AS count FROM collab_sender_leases
      WHERE room_id = ${f.authorization.roomId} AND released_at IS NULL`;
    expect(active[0]).toEqual({ count: 1 });
    expect(queue.attempts).toEqual([]);
  });

  it("host deletion/wrong owner and sender account fences reject before writes", async () => {
    const deleted = await fixture();
    await db.update(schema.sessions).set({ deletedAt: T0 })
      .where(eq(schema.sessions.id, deleted.created.session.sessionId));
    await expect(executor(new QueueFake()).admit({
      actorUserId: deleted.sender, authorization: deleted.authorization, request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    })).rejects.toMatchObject({ code: "not_member" });
    expect(await counts(deleted.created.session.sessionId, deleted.sender, "unused"))
      .toMatchObject({ messages: 0, runs: 0, turns: 0, leases: 0, outbox: 0 });

    const wrongOwner = await fixture();
    const other = `other-${newId()}`;
    await secondDb.insert(schema.users).values({ uid: other }).onConflictDoNothing();
    await db.update(schema.sessions).set({ userId: other })
      .where(eq(schema.sessions.id, wrongOwner.created.session.sessionId));
    await expect(executor(new QueueFake()).admit({
      actorUserId: wrongOwner.sender, authorization: wrongOwner.authorization, request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    })).rejects.toMatchObject({ code: "not_member" });

    const banned = await fixture();
    await db.update(schema.users).set({ bannedAt: T0 }).where(eq(schema.users.uid, banned.sender));
    await expect(executor(new QueueFake()).admit({
      actorUserId: banned.sender, authorization: banned.authorization, request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    })).rejects.toMatchObject({ code: "admission_denied" });
    expect(await counts(banned.created.session.sessionId, banned.sender, "unused"))
      .toMatchObject({ messages: 0, runs: 0, turns: 0, leases: 0, outbox: 0 });

    const deleting = await fixture();
    await db.insert(schema.accountDeletions).values({
      uid: deleting.sender,
      state: "pending",
      deleteAfter: T0.getTime() / 1_000,
      record: {},
    });
    await expect(executor(new QueueFake()).admit({
      actorUserId: deleting.sender, authorization: deleting.authorization, request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
    })).rejects.toMatchObject({ code: "admission_denied" });
    expect(await counts(deleting.created.session.sessionId, deleting.sender, "unused"))
      .toMatchObject({ messages: 0, runs: 0, turns: 0, leases: 0, outbox: 0 });
  });
});
