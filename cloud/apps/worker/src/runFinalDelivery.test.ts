import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  createDb,
  devices,
  eventMirror,
  messages,
  migrate,
  notificationDeliveryClaims,
  runDeliveryOutboxRepo,
  runs,
  schema,
  sessions,
  users,
  type Db,
} from "@ovid/db";
import type { EventLog } from "@ovid/events";
import { eq, sql } from "drizzle-orm";
import { createNotifier, type PushMessage, type PushOutcome, type PushSender } from "./notify.js";
import { recoverRunFinalDeliveries, type SchedulerDeps } from "./schedulerTick.js";
import {
  createFinalDelivery,
  FINAL_DELIVERY_LEASE_MS,
  type FinalDeliveryDeps,
} from "./runFinalDelivery.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

/**
 * Recording EventLog: the delivery's idempotency lives in the Postgres mirror,
 * so an in-memory append is enough to count how many terminal events were
 * actually emitted (and to inject a poisoned append).
 */
function recordingEvents(poisonSessionIds: ReadonlySet<string> = new Set()): EventLog & {
  appended: Array<{ sessionId: string; type: string; payload: Record<string, unknown> }>;
} {
  const appended: Array<{ sessionId: string; type: string; payload: Record<string, unknown> }> = [];
  let seq = 0;
  return {
    appended,
    async append(sessionId, type, payload) {
      if (poisonSessionIds.has(sessionId)) throw new Error("event log unavailable");
      seq += 1;
      const event = {
        sessionId,
        seq: `${Date.now()}-${seq}`,
        type,
        payload,
        ts: new Date().toISOString(),
      };
      appended.push({ sessionId, type, payload });
      return event;
    },
    async readSince() {
      return [];
    },
    async subscribe() {
      return async () => {};
    },
  };
}

describe.skipIf(!TEST_DATABASE_URL)("run final delivery outbox (real postgres)", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  // Recovery is a GLOBAL scan by design (a real worker recovers every run in
  // the deployment), so each test starts from an empty outbox: rows left
  // pending by another test would otherwise be counted in its report.
  beforeEach(async () => {
    await db.delete(schema.runDeliveryOutbox);
  });

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function seedRun(): Promise<{
    uid: string;
    sessionId: string;
    runId: string;
  }> {
    const uid = `fd-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    await users.ensure(db, uid, `${uid}@test.local`);
    // A registered device makes the completion fan-out actually send, so the
    // "exactly one push" assertions observe a real send.
    await devices.upsert(db, { token: `tok-${uid}`, userId: uid, platform: "android" });
    const session = await sessions.create(db, uid);
    const prompt = await messages.append(db, {
      sessionId: session.id,
      role: "user",
      content: `prompt-${session.id.slice(-8)}`,
    });
    const run = await runs.create(db, {
      sessionId: session.id,
      promptMessageId: prompt.id,
    });
    await runs.claimNext(db, run.id);
    return { uid, sessionId: session.id, runId: run.id };
  }

  function deps(
    events: EventLog,
    notifier?: FinalDeliveryDeps["notifier"],
  ): FinalDeliveryDeps {
    return { db, events, ...(notifier !== undefined ? { notifier } : {}) };
  }

  function stubPush(outcome: PushOutcome = { ok: true }): {
    sent: PushMessage[];
    push: PushSender;
  } {
    const sent: PushMessage[] = [];
    return {
      sent,
      push: {
        async send(msg) {
          sent.push(msg);
          return outcome;
        },
      },
    };
  }

  async function assistantRows(sessionId: string) {
    const rows = await db.select().from(schema.messages).where(eq(schema.messages.sessionId, sessionId));
    return rows.filter((row) => row.role === "assistant");
  }

  async function mirrorEvents(sessionId: string, type: string) {
    const rows = await db
      .select()
      .from(schema.sessionEventMirror)
      .where(eq(schema.sessionEventMirror.sessionId, sessionId));
    return rows.filter((row) => row.type === type);
  }

  it("crash BEFORE commit: the aborted transaction leaves no phantom answer and no intent", async () => {
    const seeded = await seedRun();
    const events = recordingEvents();
    const delivery = createFinalDelivery(deps(events), {
      userId: seeded.uid,
      scheduled: false,
    });

    // The assistant row is written first and the intent insert then fails
    // inside the SAME transaction (an unserializable jsonb payload stands in
    // for any failure — a process death before COMMIT has identical
    // consequences). Postgres rolls the whole transaction back.
    await expect(
      delivery.deliverForRun({
        runId: seeded.runId,
        sessionId: seeded.sessionId,
        content: "the answer that must not survive",
        // BigInt cannot be serialized to jsonb: the intent insert throws after
        // the assistant row insert has already run in this transaction.
        completionPayload: { runId: seeded.runId, usage: 1n },
      }),
    ).rejects.toThrow();

    expect(await assistantRows(seeded.sessionId)).toHaveLength(0);
    expect(await runDeliveryOutboxRepo.get(db, seeded.runId)).toBeNull();
    expect(events.appended).toHaveLength(0);
    expect(await mirrorEvents(seeded.sessionId, "run_completed")).toHaveLength(0);

    // Recovery finds nothing to replay, and the run is still running.
    const report = await createFinalDelivery(deps(events)).recover();
    expect(report).toEqual({ delivered: 0, failed: 0, pending: 0 });
    expect((await runs.getById(db, seeded.runId))?.status).toBe("running");
  });

  it("crash AFTER commit, before notification: recovery delivers exactly once", async () => {
    const seeded = await seedRun();
    const events = recordingEvents();
    const { sent, push } = stubPush();
    const notifier = createNotifier({ db, push });

    // The commit half of the run: answer + intent, then the process dies.
    const row = await runDeliveryOutboxRepo.record(db, {
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      userId: seeded.uid,
      content: "recovered answer",
      completionPayload: { runId: seeded.runId },
      scheduled: false,
    });
    expect(row.status).toBe("pending");
    expect(events.appended).toHaveLength(0);

    // A NEW process (fresh delivery instance, same Postgres) recovers it.
    const report = await createFinalDelivery(deps(events, notifier)).recover();
    expect(report).toEqual({ delivered: 1, failed: 0, pending: 0 });

    const assistants = await assistantRows(seeded.sessionId);
    expect(assistants).toHaveLength(1);
    expect(assistants[0]!.id).toBe(row.messageId);
    expect(assistants[0]!.content).toBe("recovered answer");

    expect(events.appended.map((e) => e.type)).toEqual(["message_completed", "run_completed"]);
    expect(events.appended[0]!.payload).toEqual({
      messageId: row.messageId,
      content: "recovered answer",
    });
    expect(events.appended[1]!.payload).toEqual({ runId: seeded.runId });

    expect((await runs.getById(db, seeded.runId))?.status).toBe("completed");
    expect((await runDeliveryOutboxRepo.get(db, seeded.runId))?.status).toBe("delivered");
    expect(
      await notificationDeliveryClaims.state(db, {
        userId: seeded.uid,
        kind: "agentFinished",
        runId: seeded.runId,
      }),
    ).toBe("delivered");
    expect(sent).toHaveLength(1);
    expect(sent[0]!.data).toMatchObject({ kind: "agentFinished", runId: seeded.runId });
  });

  it("replay of the SAME intent twice never duplicates the message row, the events, or the push", async () => {
    const seeded = await seedRun();
    const events = recordingEvents();
    const { sent, push } = stubPush();
    const notifier = createNotifier({ db, push });
    const delivery = createFinalDelivery(deps(events, notifier), {
      userId: seeded.uid,
      scheduled: false,
    });

    await delivery.deliverForRun({
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      content: "delivered once",
      completionPayload: { runId: seeded.runId },
    });
    expect(events.appended).toHaveLength(2);

    // Crash between "terminal state written" and "markDelivered": the row is
    // still pending while every side effect already landed. Move the attempt
    // timestamp back so the backoff has elapsed and recovery picks it up.
    await db
      .update(schema.runDeliveryOutbox)
      .set({ status: "pending", lastAttemptAt: new Date(0) })
      .where(eq(schema.runDeliveryOutbox.runId, seeded.runId));
    const report = await delivery.recover();
    expect(report).toEqual({ delivered: 1, failed: 0, pending: 0 });

    // Replaying the intent a third time (a fresh process) is a no-op.
    expect(await createFinalDelivery(deps(events, notifier)).recover()).toEqual({
      delivered: 0,
      failed: 0,
      pending: 0,
    });

    expect(await assistantRows(seeded.sessionId)).toHaveLength(1);
    expect(events.appended.map((e) => e.type)).toEqual(["message_completed", "run_completed"]);
    expect(await mirrorEvents(seeded.sessionId, "message_completed")).toHaveLength(1);
    expect(await mirrorEvents(seeded.sessionId, "run_completed")).toHaveLength(1);
    expect(sent).toHaveLength(1);
  });

  it("records the intent ONCE for a replayed run (unique run id, same message row)", async () => {
    const seeded = await seedRun();
    const input = {
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      userId: seeded.uid,
      content: "same answer",
      completionPayload: { runId: seeded.runId },
      scheduled: false,
    };
    const first = await runDeliveryOutboxRepo.record(db, input);
    const second = await runDeliveryOutboxRepo.record(db, input);

    expect(second.outboxId).toBe(first.outboxId);
    expect(second.messageId).toBe(first.messageId);
    expect(await assistantRows(seeded.sessionId)).toHaveLength(1);
  });

  it("an unconfirmed completion push leaves the row pending — never reported delivered", async () => {
    const seeded = await seedRun();
    const events = recordingEvents();
    // The real notifier's retry path reports "retry" (claim released, push
    // owed). The outbox must not call that delivered.
    const notifier = {
      async notifyAgentFinished(): Promise<"delivered" | "retry"> {
        return "retry";
      },
    };

    await createFinalDelivery(deps(events, notifier), {
      userId: seeded.uid,
      scheduled: false,
    }).deliverForRun({
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      content: "answer with an unconfirmed push",
      completionPayload: { runId: seeded.runId },
    });

    const row = await runDeliveryOutboxRepo.get(db, seeded.runId);
    expect(row?.status).toBe("pending");
    expect(row?.deliveredAt).toBeNull();
    expect(row?.lastError).toContain("reported retry");
    // The answer and the terminal state are still truthful.
    expect(await assistantRows(seeded.sessionId)).toHaveLength(1);
    expect((await runs.getById(db, seeded.runId))?.status).toBe("completed");
  });

  it("a notifier reporting retry is never reported delivered", async () => {
    const seeded = await seedRun();
    const events = recordingEvents();
    // A confirmed delivered outcome is required; any retry keeps the intent
    // pending so a later pass can finish the fan-out.
    const notifier = {
      async notifyAgentFinished(): Promise<"delivered" | "retry"> {
        return "retry";
      },
    };

    await createFinalDelivery(deps(events, notifier), {
      userId: seeded.uid,
      scheduled: false,
    }).deliverForRun({
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      content: "answer with a retry",
      completionPayload: { runId: seeded.runId },
    });

    const row = await runDeliveryOutboxRepo.get(db, seeded.runId);
    expect(row?.status).toBe("pending");
    expect(row?.lastError).toContain("reported retry");
  });

  it("a poisoned item does not block the batch (terminal verdict + per-item continuation)", async () => {
    const healthy = await seedRun();
    const poisoned = await seedRun();
    const otherSession = await seedRun();

    const events = recordingEvents();
    const { push } = stubPush();
    const notifier = createNotifier({ db, push });

    const healthyRow = await runDeliveryOutboxRepo.record(db, {      runId: healthy.runId,
      sessionId: healthy.sessionId,
      userId: healthy.uid,
      content: "healthy answer",
      completionPayload: { runId: healthy.runId },
      scheduled: false,
    });
    const poisonedRow = await runDeliveryOutboxRepo.record(db, {
      runId: poisoned.runId,
      sessionId: poisoned.sessionId,
      userId: poisoned.uid,
      content: "poisoned answer",
      completionPayload: { runId: poisoned.runId },
      scheduled: false,
    });
    // Poison: the intent now points at a DIFFERENT session's message (the FK
    // still holds, the identity does not). It can never be delivered, so it
    // must become a truthful `failed` row — and the healthy rows must still go.
    const foreignMessage = await messages.append(db, {
      sessionId: otherSession.sessionId,
      role: "assistant",
      content: "not this run's answer",
    });
    await db
      .update(schema.runDeliveryOutbox)
      .set({ messageId: foreignMessage.id })
      .where(eq(schema.runDeliveryOutbox.outboxId, poisonedRow.outboxId));

    // Order matters: the poisoned row sorts first (oldest) so "the batch
    // continues past it" is actually exercised in list order.
    await db
      .update(schema.runDeliveryOutbox)
      .set({ createdAt: new Date(Date.now() - 60_000) })
      .where(eq(schema.runDeliveryOutbox.outboxId, poisonedRow.outboxId));
    const listed = await runDeliveryOutboxRepo.listDue(db, 50, new Date());
    expect(listed.map((row) => row.runId)).toEqual([poisoned.runId, healthy.runId]);

    const report = await createFinalDelivery(deps(events, notifier)).recover();
    expect(report.delivered).toBe(1);
    expect(report.failed).toBe(1);
    expect(report.pending).toBe(0);

    const failed = await runDeliveryOutboxRepo.get(db, poisoned.runId);
    expect(failed?.status).toBe("failed");
    expect(failed?.lastError).toContain("another session");
    expect(await mirrorEvents(poisoned.sessionId, "run_completed")).toHaveLength(0);
    expect((await runs.getById(db, poisoned.runId))?.status).toBe("running");

    const delivered = await runDeliveryOutboxRepo.get(db, healthy.runId);
    expect(delivered?.status).toBe("delivered");
    expect(await mirrorEvents(healthy.sessionId, "run_completed")).toHaveLength(1);
    expect((await runs.getById(db, healthy.runId))?.status).toBe("completed");
  });

  it("a run terminalized as failed before delivery is not given a run_completed", async () => {
    const seeded = await seedRun();
    const events = recordingEvents();
    await runDeliveryOutboxRepo.record(db, {
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      userId: seeded.uid,
      content: "late answer",
      completionPayload: { runId: seeded.runId },
      scheduled: false,
    });
    // The stale-run sweeper won the race (crash + > stale window).
    await runs.finish(db, seeded.runId, "failed", "run_lost");

    const report = await createFinalDelivery(deps(events)).recover();
    expect(report.failed).toBe(1);
    expect((await runDeliveryOutboxRepo.get(db, seeded.runId))?.status).toBe("failed");
    expect(events.appended).toHaveLength(0);
    expect(await mirrorEvents(seeded.sessionId, "run_completed")).toHaveLength(0);
    expect((await runs.getById(db, seeded.runId))?.lastError).toBe("run_lost");
  });

  it("a dead worker's 'delivering' lease is reclaimed; a live lease is left alone", async () => {
    const seeded = await seedRun();
    const events = recordingEvents();
    const row = await runDeliveryOutboxRepo.record(db, {
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      userId: seeded.uid,
      content: "leased answer",
      completionPayload: { runId: seeded.runId },
      scheduled: false,
    });

    const now = new Date();
    // Live lease: another worker owns it right now → not even listed.
    await db
      .update(schema.runDeliveryOutbox)
      .set({ status: "delivering", lastAttemptAt: now })
      .where(eq(schema.runDeliveryOutbox.outboxId, row.outboxId));
    expect(await runDeliveryOutboxRepo.listDue(db, 50, new Date(now.getTime() - FINAL_DELIVERY_LEASE_MS)))
      .toHaveLength(0);

    // Expired lease: the owner is gone → reclaimed and delivered.
    await db
      .update(schema.runDeliveryOutbox)
      .set({ lastAttemptAt: new Date(now.getTime() - FINAL_DELIVERY_LEASE_MS - 1_000) })
      .where(eq(schema.runDeliveryOutbox.outboxId, row.outboxId));
    const report = await createFinalDelivery(deps(events)).recover();
    expect(report.delivered).toBe(1);
    expect((await runDeliveryOutboxRepo.get(db, seeded.runId))?.attempts).toBeGreaterThan(0);
  });

  it("scheduled runs never fan out agentFinished", async () => {
    const seeded = await seedRun();
    const events = recordingEvents();
    const { sent, push } = stubPush();
    const notifier = createNotifier({ db, push });

    await createFinalDelivery(deps(events, notifier), {
      userId: seeded.uid,
      scheduled: true,
    }).deliverForRun({
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      content: "scheduled answer",
      completionPayload: { runId: seeded.runId },
    });

    expect(sent).toHaveLength(0);
    expect((await runDeliveryOutboxRepo.get(db, seeded.runId))?.status).toBe("delivered");
    expect(await notificationDeliveryClaims.state(db, {
      userId: seeded.uid,
      kind: "agentFinished",
      runId: seeded.runId,
    })).toBeNull();
  });

  it("two concurrent recoveries deliver a row once (single-writer claim)", async () => {
    const seeded = await seedRun();
    const events = recordingEvents();
    const { push } = stubPush();
    const notifier = createNotifier({ db, push });
    await runDeliveryOutboxRepo.record(db, {
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      userId: seeded.uid,
      content: "raced answer",
      completionPayload: { runId: seeded.runId },
      scheduled: false,
    });

    const [a, b] = await Promise.all([
      createFinalDelivery(deps(events, notifier)).recover(),
      createFinalDelivery(deps(events, notifier)).recover(),
    ]);
    expect(a.delivered + b.delivered).toBe(1);
    expect(await assistantRows(seeded.sessionId)).toHaveLength(1);
    expect(await mirrorEvents(seeded.sessionId, "run_completed")).toHaveLength(1);
  });

  it("keeps a retryable failure pending with a bounded error, then delivers on the next pass", async () => {
    const seeded = await seedRun();
    const poisonedEvents = recordingEvents(new Set([seeded.sessionId]));
    const delivery = createFinalDelivery(deps(poisonedEvents), {
      userId: seeded.uid,
      scheduled: false,
    });

    await delivery.deliverForRun({
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      content: "answer behind a broken event log",
      completionPayload: { runId: seeded.runId },
    });
    const pending = await runDeliveryOutboxRepo.get(db, seeded.runId);
    expect(pending?.status).toBe("pending");
    expect(pending?.lastError).toContain("event log unavailable");

    // The event log is healthy again → the next pass finishes the delivery once
    // the retry backoff has elapsed.
    await db
      .update(schema.runDeliveryOutbox)
      .set({ lastAttemptAt: new Date(0) })
      .where(eq(schema.runDeliveryOutbox.runId, seeded.runId));
    const events = recordingEvents();
    expect(await createFinalDelivery(deps(events)).recover()).toMatchObject({ delivered: 1 });
    expect(await mirrorEvents(seeded.sessionId, "run_completed")).toHaveLength(1);
    expect(await assistantRows(seeded.sessionId)).toHaveLength(1);
  });

  it("the scheduler-tick recovery seam replays pending intents (and is a no-op without it)", async () => {
    const seeded = await seedRun();
    const events = recordingEvents();
    await runDeliveryOutboxRepo.record(db, {
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      userId: seeded.uid,
      content: "recovered by the tick",
      completionPayload: { runId: seeded.runId },
      scheduled: false,
    });

    // No seam composed → the pass must not touch the outbox.
    await recoverRunFinalDeliveries({ db } as unknown as SchedulerDeps);
    expect((await runDeliveryOutboxRepo.get(db, seeded.runId))?.status).toBe("pending");

    await recoverRunFinalDeliveries({
      db,
      finalDelivery: createFinalDelivery(deps(events)),
    } as unknown as SchedulerDeps);
    expect((await runDeliveryOutboxRepo.get(db, seeded.runId))?.status).toBe("delivered");
    expect(await mirrorEvents(seeded.sessionId, "run_completed")).toHaveLength(1);
  });

  it("the outbox row is the only delivery ledger: one row per run under a duplicate insert race", async () => {
    const seeded = await seedRun();
    const input = {
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      userId: seeded.uid,
      content: "raced record",
      completionPayload: { runId: seeded.runId },
      scheduled: false,
    };
    const rows = await Promise.all([
      runDeliveryOutboxRepo.record(db, input),
      runDeliveryOutboxRepo.record(db, input),
    ]);
    expect(rows[0]!.outboxId).toBe(rows[1]!.outboxId);
    const count = await db
      .select({ n: sql<number>`count(*)::int` })
      .from(schema.runDeliveryOutbox)
      .where(eq(schema.runDeliveryOutbox.runId, seeded.runId));
    expect(count[0]!.n).toBe(1);
    expect(await assistantRows(seeded.sessionId)).toHaveLength(1);
    // Both callers observe the SAME message identity (no orphan row).
    expect(rows[0]!.messageId).toBe(rows[1]!.messageId);
    expect(await eventMirror.hasPayloadValue(db, seeded.sessionId, "run_completed", "runId", seeded.runId))
      .toBe(false);
  });

  it("recovery does not starve behind a full batch of retrying rows", async () => {
    const events = recordingEvents();
    const retryRunIds: string[] = [];

    // 60 rows that have already been retried once and are now inside cooldown.
    for (let i = 0; i < 60; i++) {
      const run = await seedRun();
      const row = await runDeliveryOutboxRepo.record(db, {
        runId: run.runId,
        sessionId: run.sessionId,
        userId: run.uid,
        content: "retrying answer",
        completionPayload: { runId: run.runId },
        scheduled: false,
      });
      await db
        .update(schema.runDeliveryOutbox)
        .set({ attempts: 1, lastAttemptAt: new Date() })
        .where(eq(schema.runDeliveryOutbox.outboxId, row.outboxId));
      retryRunIds.push(run.runId);
    }

    // A fresh pending intent that should be reachable despite the batch head.
    const fresh = await seedRun();
    await runDeliveryOutboxRepo.record(db, {
      runId: fresh.runId,
      sessionId: fresh.sessionId,
      userId: fresh.uid,
      content: "fresh answer",
      completionPayload: { runId: fresh.runId },
      scheduled: false,
    });

    const notifier = {
      async notifyAgentFinished(a: { runId: string }): Promise<"delivered" | "retry"> {
        return a.runId === fresh.runId ? "delivered" : "retry";
      },
    };

    const report = await createFinalDelivery(deps(events, notifier)).recover();
    expect(report.delivered).toBe(1);
    expect(report.pending).toBe(0);
    expect(report.failed).toBe(0);

    expect((await runDeliveryOutboxRepo.get(db, fresh.runId))?.status).toBe("delivered");
    for (const runId of retryRunIds) {
      const row = await runDeliveryOutboxRepo.get(db, runId);
      expect(row?.status).toBe("pending");
      expect(row?.attempts).toBe(1);
    }
  });

  it("a retried row is not selected again until its backoff has elapsed", async () => {
    const seeded = await seedRun();
    const afterRetry = new Date();
    const row = await runDeliveryOutboxRepo.record(db, {
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      userId: seeded.uid,
      content: "backoff answer",
      completionPayload: { runId: seeded.runId },
      scheduled: false,
    });
    await db
      .update(schema.runDeliveryOutbox)
      .set({ attempts: 1, lastAttemptAt: afterRetry })
      .where(eq(schema.runDeliveryOutbox.outboxId, row.outboxId));

    // Inside the 30s cooldown (attempts=1): not due.
    expect(await runDeliveryOutboxRepo.listDue(db, 50, new Date(0))).toHaveLength(0);

    // Move last_attempt_at past the cooldown window.
    await db
      .update(schema.runDeliveryOutbox)
      .set({ lastAttemptAt: new Date(afterRetry.getTime() - 31_000) })
      .where(eq(schema.runDeliveryOutbox.outboxId, row.outboxId));
    const due = await runDeliveryOutboxRepo.listDue(db, 50, new Date(0));
    expect(due).toHaveLength(1);
    expect(due[0]!.runId).toBe(seeded.runId);
  });

  it("listDue puts a fresh row ahead of a retried one", async () => {
    const seededFresh = await seedRun();
    const seededRetry = await seedRun();

    const retryRow = await runDeliveryOutboxRepo.record(db, {
      runId: seededRetry.runId,
      sessionId: seededRetry.sessionId,
      userId: seededRetry.uid,
      content: "retry answer",
      completionPayload: { runId: seededRetry.runId },
      scheduled: false,
    });
    // Older creation time, but already attempted and now past its cooldown.
    await db
      .update(schema.runDeliveryOutbox)
      .set({
        createdAt: new Date(Date.now() - 60_000),
        attempts: 1,
        lastAttemptAt: new Date(Date.now() - 60_000),
      })
      .where(eq(schema.runDeliveryOutbox.outboxId, retryRow.outboxId));

    const freshRow = await runDeliveryOutboxRepo.record(db, {
      runId: seededFresh.runId,
      sessionId: seededFresh.sessionId,
      userId: seededFresh.uid,
      content: "fresh answer",
      completionPayload: { runId: seededFresh.runId },
      scheduled: false,
    });

    const due = await runDeliveryOutboxRepo.listDue(db, 50, new Date(0));
    expect(due.map((r) => r.outboxId)).toEqual([freshRow.outboxId, retryRow.outboxId]);

    // claim also accepts the fresh row while the retried one is not selected first.
    const claimed = await runDeliveryOutboxRepo.claim(db, freshRow.outboxId, new Date(0), new Date());
    expect(claimed).not.toBeNull();
    expect(claimed!.runId).toBe(seededFresh.runId);
  });

  it("a stale owner cannot overwrite a delivered row", async () => {
    const seeded = await seedRun();
    const row = await runDeliveryOutboxRepo.record(db, {
      runId: seeded.runId,
      sessionId: seeded.sessionId,
      userId: seeded.uid,
      content: "fenced answer",
      completionPayload: { runId: seeded.runId },
      scheduled: false,
    });

    const now = Date.now();
    const liveLeaseCutoff = new Date(now - 1000);

    // First worker claims the row (attempts becomes 1).
    const claimed = await runDeliveryOutboxRepo.claim(db, row.outboxId, liveLeaseCutoff, new Date(now));
    expect(claimed?.attempts).toBe(1);

    // New owner reclaims after lease expiry and finishes the row (attempts 2, delivered).
    await db
      .update(schema.runDeliveryOutbox)
      .set({ lastAttemptAt: new Date(now - 2000) })
      .where(eq(schema.runDeliveryOutbox.outboxId, row.outboxId));
    const reclaimed = await runDeliveryOutboxRepo.claim(
      db,
      row.outboxId,
      new Date(now - 1500),
      new Date(now),
    );
    expect(reclaimed?.attempts).toBe(2);
    await runDeliveryOutboxRepo.markDelivered(db, row.outboxId, 2, new Date(now));

    // Stale first worker tries to markPending with its old attempt count.
    await runDeliveryOutboxRepo.markPending(
      db,
      row.outboxId,
      new Error("stale retry"),
      1,
      new Date(now),
    );
    const after = await runDeliveryOutboxRepo.get(db, seeded.runId);
    expect(after?.status).toBe("delivered");
    expect(after?.lastError).toBeNull();
  });
});
