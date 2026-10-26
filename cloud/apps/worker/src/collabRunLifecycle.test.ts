import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { and, eq, sql } from "drizzle-orm";
import {
  createDb,
  messages,
  migrate,
  newId,
  schema,
  type Db,
  type MessageRow,
} from "@ovid/db";
import type { EventLog } from "@ovid/events";
import {
  collabAuthorityToken,
  type AgentRunCollab,
  type AgentRunCollabPublication,
  type AgentRunJob,
} from "@ovid/queue";
import { sendMessageBodySchema, type SessionEvent, type SessionEventType } from "@ovid/shared";

import {
  COLLAB_RUN_HEARTBEAT_INTERVAL_MS,
  COLLAB_RUN_LEASE_STALE_AFTER_MS,
  COLLAB_RUN_STALE_SWEEP_INTERVAL_MS,
  CollabRunLifecycleError,
  collabTerminalOutcome,
  createCollabHeartbeatController,
  createCollabRunLifecycle,
  createCollabStaleSweepController,
} from "./collabRunLifecycle.js";
import { collabRunExecution, type CollabRunExecution } from "./collabRun.js";

// UNEXECUTED under HEAVY-COMMANDS-PAUSED.md. These are authored pure and
// real-Postgres specifications, not compilation, test-pass, race, or runtime
// evidence. The Postgres suite is skipped unless TEST_DATABASE_URL is set.

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const T0 = new Date("2026-10-25T00:00:00.000Z");
const lifecycles: Array<ReturnType<typeof createCollabRunLifecycle>> = [];

function deferred<T = void>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

afterEach(async () => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  await Promise.all(lifecycles.splice(0).map((lifecycle) => lifecycle.close()));
});

describe("Collab lifecycle pure regressions (UNEXECUTED)", () => {
  it("pins the active heartbeat, stale sweep, and configurable stale-policy defaults", () => {
    expect(COLLAB_RUN_HEARTBEAT_INTERVAL_MS).toBe(10_000);
    expect(COLLAB_RUN_STALE_SWEEP_INTERVAL_MS).toBe(10_000);
    expect(COLLAB_RUN_LEASE_STALE_AFTER_MS).toBe(45_000);
  });

  it("derives terminal outcome only from the actual root terminal event", () => {
    expect(collabTerminalOutcome("run_completed", { runId: "r1" }, "r1")).toEqual({
      status: "completed",
      lastError: null,
    });
    expect(collabTerminalOutcome("run_failed", { runId: "r1", code: "model_terminal" }, "r1")).toEqual({
      status: "failed",
      lastError: "model_terminal",
    });
    expect(collabTerminalOutcome("run_failed", {
      runId: "r1",
      code: "model_terminal",
      lastError: "legacy terminal detail",
    }, "r1")).toEqual({ status: "failed", lastError: "legacy terminal detail" });
    expect(collabTerminalOutcome("run_cancelled", { runId: "r1" }, "r1")).toEqual({
      status: "cancelled",
      lastError: "cancelled",
    });
    expect(collabTerminalOutcome("run_failed", { code: "cancelled" }, "r1")).toEqual({
      status: "cancelled",
      lastError: "cancelled",
    });
    expect(collabTerminalOutcome("message_completed", { runId: "r1" }, "r1")).toBeNull();
    expect(() => collabTerminalOutcome("run_completed", { runId: "r2" }, "r1"))
      .toThrow(CollabRunLifecycleError);
    expect(() => collabTerminalOutcome("run_failed", { runId: "r1" }, "r1"))
      .toThrow(CollabRunLifecycleError);
  });

  it("does not make a queued but unclaimed job look active", async () => {
    vi.useFakeTimers();
    const heartbeat = vi.fn(async () => false);
    const controller = createCollabHeartbeatController({ heartbeat });

    expect(await controller.start()).toBe(false);
    expect(controller.active).toBe(false);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(heartbeat).toHaveBeenCalledTimes(1);
    await controller.close();
  });

  it("heartbeats an executing claim at 10_000 ms with single-flight async ticks", async () => {
    vi.useFakeTimers();
    const firstTick = deferred<boolean>();
    let calls = 0;
    const heartbeat = vi.fn(() => {
      calls += 1;
      return calls === 1 ? Promise.resolve(true) : firstTick.promise;
    });
    const controller = createCollabHeartbeatController({ heartbeat });
    expect(await controller.start()).toBe(true);

    await vi.advanceTimersByTimeAsync(10_000);
    expect(heartbeat).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(heartbeat).toHaveBeenCalledTimes(2);

    firstTick.resolve(true);
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(heartbeat).toHaveBeenCalledTimes(3);
    firstTick.resolve(true);
    await controller.close();
  });

  it("drains an in-flight heartbeat before terminal settlement and never ticks after stop", async () => {
    vi.useFakeTimers();
    const order: string[] = [];
    const tick = deferred<boolean>();
    let calls = 0;
    const controller = createCollabHeartbeatController({
      heartbeat: () => {
        calls += 1;
        if (calls === 1) return Promise.resolve(true);
        order.push("heartbeat-start");
        return tick.promise.then((value) => {
          order.push("heartbeat-end");
          return value;
        });
      },
    });
    await controller.start();
    await vi.advanceTimersByTimeAsync(10_000);

    const stopped = controller.stop();
    const settlement = (async () => {
      await stopped;
      order.push("settlement");
    })();
    tick.resolve(true);
    await settlement;
    expect(order).toEqual(["heartbeat-start", "heartbeat-end", "settlement"]);

    await vi.advanceTimersByTimeAsync(30_000);
    expect(calls).toBe(2);
    expect(await controller.start()).toBe(false);
  });

  it("close drains an active tick and is idempotent", async () => {
    vi.useFakeTimers();
    const tick = deferred<boolean>();
    let calls = 0;
    const controller = createCollabHeartbeatController({
      heartbeat: () => {
        calls += 1;
        return calls === 1 ? Promise.resolve(true) : tick.promise;
      },
    });
    await controller.start();
    await vi.advanceTimersByTimeAsync(10_000);
    const firstClose = controller.close();
    const secondClose = controller.close();
    tick.resolve(true);
    await Promise.all([firstClose, secondClose]);
    expect(calls).toBe(2);
  });

  it("runs the stale sweep at 10_000 ms without overlap and drains on close", async () => {
    vi.useFakeTimers();
    const pass = deferred<string[]>();
    const sweep = vi.fn(() => pass.promise);
    const controller = createCollabStaleSweepController({ sweep });
    controller.start();

    await vi.advanceTimersByTimeAsync(9_999);
    expect(sweep).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(sweep).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(sweep).toHaveBeenCalledTimes(1);

    const closed = controller.close();
    pass.resolve(["stale-lease"]);
    await closed;
    await vi.advanceTimersByTimeAsync(30_000);
    expect(sweep).toHaveBeenCalledTimes(1);
  });
});

interface MemoryEventLog extends EventLog {
  appended: SessionEvent[];
  failNext: boolean;
}

function memoryEventLog(sessionId: string, sequenceStart = 1000): MemoryEventLog {
  const appended: SessionEvent[] = [];
  return {
    appended,
    failNext: false,
    async append(sid, type: SessionEventType, payload: Record<string, unknown>) {
      if (this.failNext) {
        this.failNext = false;
        throw new Error("event append failed");
      }
      const event: SessionEvent = {
        sessionId: sid,
        seq: `${sequenceStart}-${appended.length + 1}`,
        type,
        payload,
        ts: T0.toISOString(),
      };
      appended.push(event);
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

describe.skipIf(!TEST_DATABASE_URL).sequential("Collab lifecycle real Postgres (UNEXECUTED)", () => {
  let db: Db;
  let secondDb: Db;
  let observerDb: Db;
  const createdSessionIds: string[] = [];

  // Global stale sweeps scan every lease in the database, so each fixture's
  // session must not outlive its test (session deletes cascade to runs,
  // rooms, turns, leases, and the outbox).
  afterEach(async () => {
    if (createdSessionIds.length > 0) {
      for (const sessionId of createdSessionIds) {
        // Delete in dependency order: `messages.session_id` has no cascade,
        // and the sweep must never see another test's stale lease.
        await db.$client`DELETE FROM run_outbox WHERE session_id = ${sessionId}`;
        await db.$client`
          DELETE FROM collab_sender_leases
           WHERE run_id IN (SELECT id FROM runs WHERE session_id = ${sessionId})`;
        await db.$client`
          DELETE FROM collab_turns
           WHERE run_id IN (SELECT id FROM runs WHERE session_id = ${sessionId})`;
        await db.$client`DELETE FROM messages WHERE session_id = ${sessionId}`;
        await db.$client`DELETE FROM runs WHERE session_id = ${sessionId}`;
        await db.$client`DELETE FROM collab_rooms WHERE session_id = ${sessionId}`;
        await db.$client`DELETE FROM sessions WHERE id = ${sessionId}`;
      }
      createdSessionIds.length = 0;
    }
  });

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!, { max: 12 });
    secondDb = createDb(TEST_DATABASE_URL!, { max: 12 });
    observerDb = createDb(TEST_DATABASE_URL!, { max: 4 });
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await secondDb?.$client.end({ timeout: 5 });
    await observerDb?.$client.end({ timeout: 5 });
  }, 30_000);

  async function fixture(options: { status?: "queued" | "running"; publishedAt?: Date | null } = {}) {
    const status = options.status ?? "running";
    const ids = {
      roomId: newId(),
      sessionId: newId(),
      turnId: newId(),
      runId: newId(),
      messageId: newId(),
      outboxId: newId(),
      leaseId: newId(),
    };
    createdSessionIds.push(ids.sessionId);
    const suffix = newId().replaceAll("-", "");
    const participantId = `p${suffix}`;
    const ownerParticipantId = `p${newId().replaceAll("-", "")}`;
    const ownerUserId = `host-${newId()}`;
    const actorUserId = `sender-${newId()}`;
    const idempotencyKey = `turn-${suffix}`;
    const collab: AgentRunCollab = {
      roomId: ids.roomId,
      participantId,
      membershipGeneration: 4,
      leaseId: ids.leaseId,
      leaseGeneration: 9,
      outboxId: ids.outboxId,
      rootRunId: ids.runId,
    };
    const publication: AgentRunCollabPublication = {
      outboxStatus: "published",
      outboxAttempts: 1,
      runStatus: "queued",
      turnStatus: "queued",
      leaseGeneration: 9,
      authorityToken: collabAuthorityToken({
        roomId: ids.roomId,
        sessionId: ids.sessionId,
        ownerUserId,
        actorUserId,
        participantId,
        roomGeneration: 4,
        membershipGeneration: 4,
        leaseId: ids.leaseId,
        leaseGeneration: 9,
        rootRunId: ids.runId,
        turnId: ids.turnId,
      }),
    };
    const job: AgentRunJob = {
      runId: ids.runId,
      sessionId: ids.sessionId,
      userId: ownerUserId,
      ownerUserId,
      actorUserId,
      source: "collab",
      prompt: "hello lifecycle",
      requestedModel: "provider/model",
      tier: "free",
      modelContext: {
        requestedModel: "provider/model",
        byokKeyId: null,
        temperature: null,
        actorUserId,
      },
      collab,
      collabPublication: publication,
    };

    await db.insert(schema.users).values([
      { uid: ownerUserId, tier: "free" },
      { uid: actorUserId, tier: "plus" },
    ]);
    await db.insert(schema.sessions).values({ id: ids.sessionId, userId: ownerUserId });
    await db.insert(schema.collabRooms).values({
      id: ids.roomId,
      tokenHash: `${suffix}${suffix}`,
      sessionId: ids.sessionId,
      ownerUserId,
      requestId: `room-${suffix}`,
      lifecycle: "active",
      generation: 4,
    });
    await db.insert(schema.collabMembers).values([
      {
        roomId: ids.roomId,
        userId: ownerUserId,
        participantId: ownerParticipantId,
        role: "owner",
        status: "active",
        generation: 1,
      },
      {
        roomId: ids.roomId,
        userId: actorUserId,
        participantId,
        role: "participant",
        status: "active",
        generation: 4,
      },
    ]);
    await db.insert(schema.messages).values({
      id: ids.messageId,
      sessionId: ids.sessionId,
      role: "user",
      content: job.prompt,
      createdAt: T0,
    });
    await db.insert(schema.runs).values({
      id: ids.runId,
      sessionId: ids.sessionId,
      status,
      promptMessageId: ids.messageId,
      startedAt: status === "running" ? T0 : null,
      lastActiveAt: status === "running" ? T0 : null,
      createdAt: T0,
    });
    await db.insert(schema.collabTurns).values({
      id: ids.turnId,
      roomId: ids.roomId,
      participantId,
      actorUserId,
      runId: ids.runId,
      userMessageId: ids.messageId,
      idempotencyKey,
      model: "provider/model",
      status,
      createdAt: T0,
      updatedAt: T0,
    });
    await db.insert(schema.collabSenderLeases).values({
      id: ids.leaseId,
      roomId: ids.roomId,
      holderParticipantId: participantId,
      holderUserId: actorUserId,
      runId: ids.runId,
      generation: 9,
      roomGeneration: 4,
      membershipGeneration: 4,
      startedAt: T0,
      heartbeatAt: T0,
    });
    await db.insert(schema.runOutbox).values({
      outboxId: ids.outboxId,
      actorUserId,
      sessionId: ids.sessionId,
      runId: ids.runId,
      userMessageId: ids.messageId,
      idempotencyKey,
      status: "published",
      attempts: 1,
      publishedAt: options.publishedAt === undefined ? T0 : options.publishedAt,
      lastAttemptAt: T0,
      requestPayload: {
        schemaVersion: 1,
        idempotencyKey,
        text: job.prompt,
        model: "provider/model",
      },
      bodyPayload: {
        ownerUserId,
        requestedModel: "provider/model",
        userId: actorUserId,
        sessionId: ids.sessionId,
        runId: ids.runId,
        modelContext: job.modelContext,
        byokKeyId: null,
        tier: "free",
        queuePriority: 1,
        collab,
      },
      jobId: ids.runId,
      createdAt: T0,
      updatedAt: T0,
    });
    return {
      ...ids,
      participantId,
      ownerUserId,
      actorUserId,
      idempotencyKey,
      job,
      collab,
      publication,
      execution: collabRunExecution(job),
    };
  }

  function lifecycle(now: () => Date = () => T0) {
    const value = createCollabRunLifecycle({ db, now, staleAfterMs: 45_000 });
    lifecycles.push(value);
    return value;
  }

  function writer(execution: CollabRunExecution, log = memoryEventLog(execution.job.sessionId)) {
    return { writer: lifecycle().writer(execution, log), log };
  }

  async function appendAssistant(w: ReturnType<typeof writer>["writer"], content = "canonical answer"): Promise<MessageRow> {
    return messages.append(w.db, {
      sessionId: w.execution.job.sessionId,
      role: "assistant",
      content,
    });
  }

  async function durableCompletedPrefix(w: ReturnType<typeof writer>["writer"], content = "canonical answer") {
    const assistant = await appendAssistant(w, content);
    await w.events.append(w.execution.job.sessionId, "message_completed", {
      messageId: assistant.id,
      content,
    });
    return assistant;
  }

  async function state(runId: string) {
    const rows = await db.$client`
      SELECT r.status AS run_status, r.cancel_requested AS run_cancel,
             t.status AS turn_status, t.cancel_requested_at AS turn_cancel,
             o.status AS outbox_status, o.settled_at, o.published_at,
             l.released_at, l.cancel_requested_at AS lease_cancel,
             l.generation, l.heartbeat_at
        FROM runs r
        JOIN collab_turns t ON t.run_id = r.id
        JOIN run_outbox o ON o.run_id = r.id
        JOIN collab_sender_leases l ON l.run_id = r.id
       WHERE r.id = ${runId}`;
    const row = rows[0]!;
    // Drizzle installs transparent timestamp parsers on the raw client, so
    // raw rows carry text; normalize back to the Date contract used below.
    const asDate = (value: unknown): Date | null =>
      value === null || value === undefined ? null : value instanceof Date ? value : new Date(value as string);
    return {
      ...row,
      generation: Number(row.generation),
      turn_cancel: asDate(row.turn_cancel),
      settled_at: asDate(row.settled_at),
      published_at: asDate(row.published_at),
      released_at: asDate(row.released_at),
      lease_cancel: asDate(row.lease_cancel),
      heartbeat_at: asDate(row.heartbeat_at),
    };
  }

  type LockRelation = "collab_members" | "collab_rooms";

  function trackTransactionBackend(base: Db) {
    const waiting = new Set<(pid: number) => void>();
    const tracked = new Proxy(base, {
      get(target, property) {
        if (property === "transaction") {
          return (callback: (tx: Db) => Promise<unknown>) => {
            const transaction = Reflect.get(target, property, target) as (
              callback: (tx: Db) => Promise<unknown>,
            ) => Promise<unknown>;
            return transaction.call(target, async (tx: Db) => {
              const rows = await tx.execute(sql`SELECT pg_backend_pid() AS pid`) as unknown as Array<{
                pid: number | string;
              }>;
              const pid = Number(rows[0]?.pid);
              if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error("invalid backend pid");
              for (const notify of waiting) notify(pid);
              waiting.clear();
              return callback(tx);
            });
          };
        }
        const current = Reflect.get(target, property, target) as unknown;
        return typeof current === "function" ? current.bind(target) : current;
      },
    }) as Db;
    return {
      db: tracked,
      nextBackend(): Promise<number> {
        // Register immediately before the intended lifecycle operation. The
        // resolver runs on that operation's own transaction connection, before
        // its callback can issue any lock statement.
        return new Promise((resolve) => waiting.add(resolve));
      },
    };
  }

  async function waitForLifecycleLockWait(
    backendPid: number,
    holderPid: number,
    relation: LockRelation,
  ): Promise<void> {
    // backendPid belongs to the exact tracked settlement/heartbeat transaction;
    // holderPid belongs to the transaction holding this fixture's row lock.
    // Require the intended waiter, its actual lock-blocker, and its current
    // single-row FOR UPDATE statement. An unrelated relation waiter cannot pass.
    for (let attempt = 0; attempt < 200; attempt += 1) {
      const rows = await observerDb.$client`
        SELECT a.pid
          FROM pg_stat_activity a
         WHERE a.pid = ${backendPid}
           AND a.datname = current_database()
           AND a.state = 'active'
           AND a.wait_event_type = 'Lock'
           AND a.query ILIKE ${`%from "${relation}"%`}
           AND a.query ILIKE '%for update%'
           AND ${holderPid} = ANY (pg_blocking_pids(a.pid))
         LIMIT 1`;
      if (rows.length === 1 && rows[0]!.pid === backendPid) return;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error(
      `backend ${backendPid} was not blocked by ${holderPid} in ${relation} FOR UPDATE`,
    );
  }

  function countingUpdates(base: Db) {
    const counts = { outbox: 0, lease: 0 };
    const wrap = (value: Db): Db => new Proxy(value, {
      get(target, property) {
        if (property === "update") {
          return (table: unknown) => {
            if (table === schema.runOutbox) counts.outbox += 1;
            if (table === schema.collabSenderLeases) counts.lease += 1;
            const update = Reflect.get(target, property, target) as (table: unknown) => unknown;
            return update.call(target, table);
          };
        }
        if (property === "transaction") {
          return (callback: (tx: Db) => Promise<unknown>) => {
            const transaction = Reflect.get(target, property, target) as (
              callback: (tx: Db) => Promise<unknown>,
            ) => Promise<unknown>;
            return transaction.call(target, (tx: Db) => callback(wrap(tx)));
          };
        }
        const current = Reflect.get(target, property, target) as unknown;
        return typeof current === "function" ? current.bind(target) : current;
      },
    }) as Db;
    return { db: wrap(base), counts };
  }

  it("settles completed run and turn once after durable assistant and events, then replays without duplicates", async () => {
    const f = await fixture();
    const { writer: w, log } = writer(f.execution);
    const assistant = await durableCompletedPrefix(w);
    const order: string[] = [];
    const stop = w.heartbeat.stop.bind(w.heartbeat);
    vi.spyOn(w.heartbeat, "stop").mockImplementation(async () => {
      order.push("stop");
      await stop();
    });
    const append = log.append.bind(log);
    vi.spyOn(log, "append").mockImplementation(async (sessionId, type, payload) => {
      if (type === "run_completed") order.push("terminal-append");
      return append(sessionId, type, payload);
    });
    const terminal = await w.events.append(f.sessionId, "run_completed", { runId: f.runId });
    expect(order).toEqual(["stop", "terminal-append"]);

    expect(await state(f.runId)).toMatchObject({
      run_status: "completed",
      turn_status: "completed",
      outbox_status: "settled",
    });
    expect((await state(f.runId)).released_at).toEqual(T0);
    const replay = await w.events.append(f.sessionId, "run_completed", { runId: f.runId });
    expect(replay).toEqual(terminal);
    expect(log.appended).toHaveLength(2);

    const assistantAgain = await appendAssistant(w);
    expect(assistantAgain.id).toBe(assistant.id);
    const messageReplay = await w.events.append(f.sessionId, "message_completed", {
      messageId: assistant.id,
      content: "canonical answer",
    });
    expect(messageReplay.type).toBe("message_completed");
    expect(log.appended).toHaveLength(2);
    const counts = await db.$client`
      SELECT
        (SELECT count(*)::int FROM messages WHERE session_id = ${f.sessionId} AND role = 'assistant') AS assistants,
        (SELECT count(*)::int FROM session_event_mirror WHERE session_id = ${f.sessionId} AND type = 'run_completed') AS terminals`;
    expect(counts[0]).toEqual({ assistants: 1, terminals: 1 });
  });

  it("settles failed and cancelled outcomes from their actual terminal events", async () => {
    const failed = await fixture();
    const failedWriter = writer(failed.execution).writer;
    await failedWriter.events.append(failed.sessionId, "run_failed", {
      runId: failed.runId,
      code: "model_terminal",
      message: "safe failure",
    });
    expect(await state(failed.runId)).toMatchObject({ run_status: "failed", turn_status: "failed" });

    const cancelled = await fixture();
    const cancelledWriter = writer(cancelled.execution).writer;
    await cancelledWriter.events.append(cancelled.sessionId, "run_cancelled", { runId: cancelled.runId });
    expect(await state(cancelled.runId)).toMatchObject({ run_status: "cancelled", turn_status: "cancelled" });

    const queued = await fixture({ status: "queued" });
    const queuedWriter = writer(queued.execution).writer;
    await queuedWriter.events.append(queued.sessionId, "run_failed", {
      runId: queued.runId,
      code: "run_queue_wait_timeout",
    });
    expect(await state(queued.runId)).toMatchObject({ run_status: "failed", turn_status: "failed" });
    expect(queuedWriter.heartbeat.active).toBe(false);
  });

  it("dedupes concurrent and retry assistant appends but refuses changed replay content", async () => {
    const f = await fixture();
    const first = writer(f.execution);
    const second = writer(f.execution, memoryEventLog(f.sessionId));
    const appended = await Promise.all([
      appendAssistant(first.writer),
      appendAssistant(second.writer),
    ]);
    expect(appended[0]!.id).toBe(appended[1]!.id);
    expect(appended[0]!.id).toBe(f.turnId);
    expect(appended[0]!.clientMsgId).toBeNull();
    await expect(appendAssistant(first.writer, "changed answer"))
      .rejects.toMatchObject({ code: "invalid_record" });
    const rows = await db.select().from(schema.messages).where(and(
      eq(schema.messages.sessionId, f.sessionId),
      eq(schema.messages.id, f.turnId),
    ));
    expect(rows).toHaveLength(1);
  });

  it("public send cannot occupy or impersonate the server-owned final assistant identity", async () => {
    const f = await fixture();
    const legacyPredictableKey = `collab-run:${f.runId}:assistant`;
    // Actual public body schema plus the exact canonical write used by its
    // route: the caller controls clientMsgId, never messages.id.
    const publicInput = sendMessageBodySchema.parse({
      content: "public send collision",
      clientMsgId: legacyPredictableKey,
    });
    const publicUser = await messages.append(db, {
      sessionId: f.sessionId,
      role: "user",
      content: publicInput.content,
      clientMsgId: publicInput.clientMsgId,
    });
    const { writer: w } = writer(f.execution);
    const assistant = await durableCompletedPrefix(w);

    expect(assistant.id).toBe(f.turnId);
    expect(assistant.id).not.toBe(publicUser.id);
    expect(assistant.clientMsgId).toBeNull();
    await w.events.append(f.sessionId, "run_completed", { runId: f.runId });
    expect(await state(f.runId)).toMatchObject({
      run_status: "completed",
      turn_status: "completed",
      outbox_status: "settled",
    });
  });

  it("history-imported user and assistant collisions cannot block or impersonate finalization", async () => {
    for (const role of ["user", "assistant"] as const) {
      const f = await fixture();
      const legacyPredictableKey = `collab-run:${f.runId}:assistant`;
      // Exact canonical repository used by POST /import/sessions. A matching
      // imported assistant must not be mistaken for this run's final answer.
      const report = await messages.importBulk(db, f.sessionId, [{
        clientMsgId: legacyPredictableKey,
        role,
        content: role === "assistant" ? "canonical answer" : "imported user collision",
        createdAt: T0,
      }]);
      expect(report).toEqual({ imported: 1, skipped: 0 });
      const imported = await messages.findByClientMsgId(db, f.sessionId, legacyPredictableKey);
      expect(imported?.role).toBe(role);

      const { writer: w } = writer(f.execution);
      const assistant = await durableCompletedPrefix(w);
      expect(assistant.id).toBe(f.turnId);
      expect(assistant.id).not.toBe(imported?.id);
      expect(assistant.clientMsgId).toBeNull();
      await w.events.append(f.sessionId, "run_completed", { runId: f.runId });
      expect(await state(f.runId)).toMatchObject({
        run_status: "completed",
        turn_status: "completed",
        outbox_status: "settled",
      });
      if (role === "assistant") {
        const impersonatedEvents = await db.$client`
          SELECT count(*)::int AS count FROM session_event_mirror
           WHERE session_id = ${f.sessionId}
             AND type = 'message_completed'
             AND payload->>'messageId' = ${imported!.id}`;
        expect(impersonatedEvents[0]).toEqual({ count: 0 });
      }
    }
  });

  it("serializes two terminal settlers to one event, outbox transition, and lease release", async () => {
    const f = await fixture();
    const counted = countingUpdates(db);
    const manager = createCollabRunLifecycle({ db: counted.db, now: () => T0, staleAfterMs: 45_000 });
    lifecycles.push(manager);
    const firstLog = memoryEventLog(f.sessionId);
    const secondLog = memoryEventLog(f.sessionId, 2000);
    const first = { writer: manager.writer(f.execution, firstLog), log: firstLog };
    const second = { writer: manager.writer(f.execution, secondLog), log: secondLog };
    await durableCompletedPrefix(first.writer);

    const terminals = await Promise.all([
      first.writer.events.append(f.sessionId, "run_completed", { runId: f.runId }),
      second.writer.events.append(f.sessionId, "run_completed", { runId: f.runId }),
    ]);
    expect(terminals[0]).toEqual(terminals[1]);
    expect(first.log.appended.length + second.log.appended.length).toBe(2);
    expect(counted.counts).toEqual({ outbox: 1, lease: 1 });
    const current = await state(f.runId);
    expect(current).toMatchObject({ run_status: "completed", turn_status: "completed", outbox_status: "settled" });
    const mirrors = await db.select().from(schema.sessionEventMirror).where(and(
      eq(schema.sessionEventMirror.sessionId, f.sessionId),
      eq(schema.sessionEventMirror.type, "run_completed"),
    ));
    expect(mirrors).toHaveLength(1);
  });

  it("fences stale and released leases before completed settlement without emitting success", async () => {
    for (const kind of ["stale", "released"] as const) {
      const f = await fixture();
      const { writer: w, log } = writer(f.execution);
      await durableCompletedPrefix(w);
      if (kind === "stale") {
        await db.update(schema.collabSenderLeases).set({ heartbeatAt: new Date(T0.getTime() - 45_001) })
          .where(eq(schema.collabSenderLeases.id, f.leaseId));
      } else {
        await db.update(schema.collabSenderLeases).set({ releasedAt: T0 })
          .where(eq(schema.collabSenderLeases.id, f.leaseId));
      }
      const before = log.appended.length;
      await expect(w.events.append(f.sessionId, "run_completed", { runId: f.runId }))
        .rejects.toMatchObject({ code: "stale_authorization" });
      expect(log.appended).toHaveLength(before);
      expect(await state(f.runId)).toMatchObject({ run_status: "running", turn_status: "running", outbox_status: "published" });
    }
  });

  it("fences membership revocation before and while settlement waits for the same lock", async () => {
    const before = await fixture();
    const beforeWriter = writer(before.execution).writer;
    await durableCompletedPrefix(beforeWriter);
    await db.update(schema.collabMembers).set({ status: "revoked", generation: 5 }).where(and(
      eq(schema.collabMembers.roomId, before.roomId),
      eq(schema.collabMembers.userId, before.actorUserId),
    ));
    await expect(beforeWriter.events.append(before.sessionId, "run_completed", { runId: before.runId }))
      .rejects.toMatchObject({ code: "not_member" });

    const during = await fixture();
    const tracked = trackTransactionBackend(db);
    const duringManager = createCollabRunLifecycle({ db: tracked.db, now: () => T0, staleAfterMs: 45_000 });
    lifecycles.push(duringManager);
    const duringWriter = duringManager.writer(during.execution, memoryEventLog(during.sessionId));
    await durableCompletedPrefix(duringWriter);
    const entered = deferred<number>();
    const release = deferred();
    const revoking = secondDb.transaction(async (tx) => {
      await tx.update(schema.collabMembers).set({ status: "revoked", generation: 5 }).where(and(
        eq(schema.collabMembers.roomId, during.roomId),
        eq(schema.collabMembers.userId, during.actorUserId),
      ));
      const holder = await tx.execute(sql`SELECT pg_backend_pid() AS pid`) as unknown as Array<{
        pid: number | string;
      }>;
      entered.resolve(Number(holder[0]!.pid));
      await release.promise;
    });
    const holderPid = await entered.promise;
    const backend = tracked.nextBackend();
    const settling = duringWriter.events.append(during.sessionId, "run_completed", { runId: during.runId });
    const waiterPid = await backend;
    await waitForLifecycleLockWait(waiterPid, holderPid, "collab_members");
    release.resolve();
    await expect(settling).rejects.toMatchObject({ code: "not_member" });
    await revoking;
    expect(await state(during.runId)).toMatchObject({ run_status: "running", turn_status: "running", outbox_status: "published" });
  });

  it("does not settle when Redis append or canonical event persistence fails", async () => {
    const appendFailure = await fixture();
    const failed = writer(appendFailure.execution);
    failed.log.failNext = true;
    await expect(failed.writer.events.append(appendFailure.sessionId, "run_failed", {
      runId: appendFailure.runId,
      code: "model_terminal",
    })).rejects.toThrow("event append failed");
    expect(await state(appendFailure.runId)).toMatchObject({ run_status: "running", turn_status: "running", outbox_status: "published" });

    const mirrorConflict = await fixture();
    const conflicted = writer(mirrorConflict.execution);
    await db.insert(schema.sessionEventMirror).values({
      sessionId: mirrorConflict.sessionId,
      seq: "1000-1",
      type: "system_note",
      payload: { runId: mirrorConflict.runId, code: "different" },
      ts: T0,
    });
    await expect(conflicted.writer.events.append(mirrorConflict.sessionId, "run_failed", {
      runId: mirrorConflict.runId,
      code: "model_terminal",
    })).rejects.toMatchObject({ code: "event_conflict" });
    expect(await state(mirrorConflict.runId)).toMatchObject({ run_status: "running", turn_status: "running", outbox_status: "published" });

    await db.delete(schema.sessionEventMirror).where(and(
      eq(schema.sessionEventMirror.sessionId, mirrorConflict.sessionId),
      eq(schema.sessionEventMirror.seq, "1000-1"),
    ));
    expect(conflicted.log.appended).toHaveLength(1);
    const originalEvent = conflicted.log.appended[0]!;
    const freshProcess = writer(mirrorConflict.execution, memoryEventLog(mirrorConflict.sessionId, 3000));
    await freshProcess.writer.settle(originalEvent);
    expect(conflicted.log.appended).toHaveLength(1);
    expect(freshProcess.log.appended).toHaveLength(0);
    expect(await state(mirrorConflict.runId)).toMatchObject({
      run_status: "failed",
      turn_status: "failed",
      outbox_status: "settled",
    });
  });

  it("requires completed assistant evidence and confirmed publication before any terminal transition", async () => {
    const missing = await fixture();
    const missingWriter = writer(missing.execution);
    await expect(missingWriter.writer.events.append(missing.sessionId, "run_completed", { runId: missing.runId }))
      .rejects.toMatchObject({ code: "durable_evidence_missing" });
    expect(missingWriter.log.appended).toHaveLength(0);

    const unresolved = await fixture({ publishedAt: null });
    const unresolvedWriter = writer(unresolved.execution);
    await durableCompletedPrefix(unresolvedWriter.writer);
    const before = unresolvedWriter.log.appended.length;
    await expect(unresolvedWriter.writer.events.append(unresolved.sessionId, "run_completed", { runId: unresolved.runId }))
      .rejects.toMatchObject({ code: "publication_unresolved" });
    expect(unresolvedWriter.log.appended).toHaveLength(before);
    expect(await state(unresolved.runId)).toMatchObject({ run_status: "running", turn_status: "running", outbox_status: "published" });
  });

  it("heartbeats only a claimed running run and never extends a queued or released lease", async () => {
    const at = new Date(T0.getTime() + 10_000);
    const queued = await fixture({ status: "queued" });
    const queuedWriter = lifecycle(() => at).writer(queued.execution, memoryEventLog(queued.sessionId));
    await db.update(schema.collabSenderLeases).set({ heartbeatAt: T0 }).where(eq(schema.collabSenderLeases.id, queued.leaseId));
    expect(await queuedWriter.startHeartbeat()).toBe(false);
    expect((await state(queued.runId)).heartbeat_at).toEqual(T0);

    const running = await fixture();
    const runningWriter = lifecycle(() => at).writer(running.execution, memoryEventLog(running.sessionId));
    expect(await runningWriter.startHeartbeat()).toBe(true);
    expect((await state(running.runId)).heartbeat_at).toEqual(at);

    const released = await fixture();
    const releasedWriter = lifecycle(() => at).writer(released.execution, memoryEventLog(released.sessionId));
    await db.update(schema.collabSenderLeases).set({ releasedAt: T0 }).where(eq(schema.collabSenderLeases.id, released.leaseId));
    expect(await releasedWriter.startHeartbeat()).toBe(false);
    expect((await state(released.runId)).heartbeat_at).toEqual(T0);
  });

  it("drains an actual in-flight Postgres heartbeat before terminal settlement", async () => {
    const f = await fixture();
    const oldHeartbeat = new Date(T0.getTime() - 10_000);
    await db.update(schema.collabSenderLeases).set({ heartbeatAt: oldHeartbeat })
      .where(eq(schema.collabSenderLeases.id, f.leaseId));
    const tracked = trackTransactionBackend(db);
    const manager = createCollabRunLifecycle({ db: tracked.db, now: () => T0, staleAfterMs: 45_000 });
    lifecycles.push(manager);
    // Use the underlying log for append observation, not the lifecycle facade.
    const memoryLog = memoryEventLog(f.sessionId);
    const trackedWriter = manager.writer(f.execution, memoryLog);
    await durableCompletedPrefix(trackedWriter);
    const roomLocked = deferred<number>();
    const releaseRoom = deferred();
    const holder = secondDb.transaction(async (tx) => {
      await tx.select().from(schema.collabRooms)
        .where(eq(schema.collabRooms.id, f.roomId)).for("update").limit(1);
      const holder = await tx.execute(sql`SELECT pg_backend_pid() AS pid`) as unknown as Array<{
        pid: number | string;
      }>;
      roomLocked.resolve(Number(holder[0]!.pid));
      await releaseRoom.promise;
    });
    const holderPid = await roomLocked.promise;

    const backend = tracked.nextBackend();
    const heartbeatStart = trackedWriter.startHeartbeat();
    const waiterPid = await backend;
    await waitForLifecycleLockWait(waiterPid, holderPid, "collab_rooms");
    let heartbeatAtTerminal: Date | null = null;
    let runStatusAtTerminal: string | null = null;
    const append = memoryLog.append.bind(memoryLog);
    vi.spyOn(memoryLog, "append").mockImplementation(async (sessionId, type, payload) => {
      if (type === "run_completed") {
        const observed = await db.$client`
          SELECT l.heartbeat_at, r.status AS run_status
            FROM collab_sender_leases l JOIN runs r ON r.id = l.run_id
           WHERE l.id = ${f.leaseId}`;
        heartbeatAtTerminal = observed[0]!.heartbeat_at === null
          ? null
          : new Date(observed[0]!.heartbeat_at as string);
        runStatusAtTerminal = observed[0]!.run_status;
      }
      return append(sessionId, type, payload);
    });

    const terminal = trackedWriter.events.append(f.sessionId, "run_completed", { runId: f.runId });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(memoryLog.appended).toHaveLength(1);
    expect(heartbeatAtTerminal).toBeNull();

    releaseRoom.resolve();
    expect(await heartbeatStart).toBe(false);
    await terminal;
    await holder;
    expect(heartbeatAtTerminal).toEqual(T0);
    expect(runStatusAtTerminal).toBe("running");
    expect(await state(f.runId)).toMatchObject({
      run_status: "completed",
      turn_status: "completed",
      outbox_status: "settled",
      heartbeat_at: T0,
    });
  });

  it("stale sweep uses the configured 45_000 ms policy, cancels without inventing terminal outcomes, and leaves fresh work", async () => {
    const stale = await fixture();
    const fresh = await fixture();
    await db.update(schema.collabSenderLeases).set({ heartbeatAt: new Date(T0.getTime() + 45_001) })
      .where(eq(schema.collabSenderLeases.id, fresh.leaseId));
    const manager = lifecycle(() => new Date(T0.getTime() + 45_001));
    expect(await manager.sweepNow()).toEqual([stale.leaseId]);
    expect(await state(stale.runId)).toMatchObject({
      run_status: "running",
      turn_status: "running",
      outbox_status: "published",
      run_cancel: true,
      generation: 10,
    });
    expect((await state(stale.runId)).released_at).not.toBeNull();
    expect((await state(stale.runId)).turn_cancel).not.toBeNull();
    expect(await state(fresh.runId)).toMatchObject({ run_cancel: false, generation: 9 });
    expect(await manager.sweepNow()).toEqual([]);
  });

  it("reconciles stale-sweep cancellation without resurrecting the old lease or touching a newer lease", async () => {
    const f = await fixture();
    const sweptAt = new Date(T0.getTime() + 45_001);
    let now = T0;
    const manager = lifecycle(() => now);
    const w = manager.writer(f.execution, memoryEventLog(f.sessionId));
    await durableCompletedPrefix(w);
    now = sweptAt;
    expect(await manager.sweepNow()).toEqual([f.leaseId]);
    await expect(w.events.append(f.sessionId, "run_completed", { runId: f.runId }))
      .rejects.toMatchObject({ code: "stale_authorization" });

    const newerRunId = newId();
    await db.insert(schema.runs).values({
      id: newerRunId,
      sessionId: f.sessionId,
      status: "queued",
      promptMessageId: f.messageId,
      createdAt: sweptAt,
    });
    const newerLeaseId = newId();
    await db.insert(schema.collabSenderLeases).values({
      id: newerLeaseId,
      roomId: f.roomId,
      holderParticipantId: f.participantId,
      holderUserId: f.actorUserId,
      runId: newerRunId,
      generation: 11,
      roomGeneration: 4,
      membershipGeneration: 4,
      startedAt: sweptAt,
      heartbeatAt: sweptAt,
    });

    await w.events.append(f.sessionId, "run_cancelled", { runId: f.runId });
    const recovered = await state(f.runId);
    expect(recovered).toMatchObject({
      run_status: "cancelled",
      turn_status: "cancelled",
      outbox_status: "settled",
      generation: 10,
      released_at: sweptAt,
      lease_cancel: sweptAt,
    });
    expect(recovered.settled_at).toEqual(sweptAt);
    const newer = await db.select().from(schema.collabSenderLeases)
      .where(eq(schema.collabSenderLeases.id, newerLeaseId)).limit(1);
    expect(newer[0]).toMatchObject({
      generation: 11,
      releasedAt: null,
      cancelRequestedAt: null,
      heartbeatAt: sweptAt,
    });
    const mirrors = await db.select().from(schema.sessionEventMirror).where(and(
      eq(schema.sessionEventMirror.sessionId, f.sessionId),
      eq(schema.sessionEventMirror.type, "run_cancelled"),
    ));
    expect(mirrors).toHaveLength(1);
    expect(mirrors[0]!.payload.runId).toBe(f.runId);
  });

  it("recovers stale-sweep cancellation from the original event and sequence on a fresh writer", async () => {
    const f = await fixture();
    const sweptAt = new Date(T0.getTime() + 45_001);
    const manager = lifecycle(() => sweptAt);
    expect(await manager.sweepNow()).toEqual([f.leaseId]);
    const fenced = await state(f.runId);

    const newerRunId = newId();
    await db.insert(schema.runs).values({
      id: newerRunId,
      sessionId: f.sessionId,
      status: "queued",
      promptMessageId: f.messageId,
      createdAt: sweptAt,
    });
    const newerLeaseId = newId();
    await db.insert(schema.collabSenderLeases).values({
      id: newerLeaseId,
      roomId: f.roomId,
      holderParticipantId: f.participantId,
      holderUserId: f.actorUserId,
      runId: newerRunId,
      generation: 11,
      roomGeneration: 4,
      membershipGeneration: 4,
      startedAt: sweptAt,
      heartbeatAt: sweptAt,
    });

    // The engine appended its actual cancellation, then the original process
    // disappeared before mirror/settlement. This new writer has no cached event.
    const originalLog = memoryEventLog(f.sessionId, 4000);
    const original = await originalLog.append(f.sessionId, "run_cancelled", {
      runId: f.runId,
      reason: "stale_authorization",
    });
    const freshProcessLog = memoryEventLog(f.sessionId, 5000);
    const fresh = { writer: manager.writer(f.execution, freshProcessLog), log: freshProcessLog };
    const recoveredEvent = await fresh.writer.settle(original);

    expect(recoveredEvent).toEqual(original);
    expect(originalLog.appended).toHaveLength(1);
    expect(freshProcessLog.appended).toHaveLength(0);
    expect(await state(f.runId)).toMatchObject({
      run_status: "cancelled",
      turn_status: "cancelled",
      outbox_status: "settled",
      run_cancel: true,
      generation: 10,
      released_at: fenced.released_at,
      turn_cancel: fenced.turn_cancel,
      lease_cancel: fenced.lease_cancel,
      settled_at: sweptAt,
    });
    const mirror = await db.select().from(schema.sessionEventMirror).where(and(
      eq(schema.sessionEventMirror.sessionId, f.sessionId),
      eq(schema.sessionEventMirror.seq, original.seq),
    ));
    expect(mirror).toHaveLength(1);
    expect(mirror[0]).toMatchObject({
      seq: original.seq,
      type: "run_cancelled",
      payload: original.payload,
      ts: new Date(original.ts),
    });
    const newer = await db.select().from(schema.collabSenderLeases)
      .where(eq(schema.collabSenderLeases.id, newerLeaseId)).limit(1);
    expect(newer[0]).toMatchObject({
      generation: 11,
      releasedAt: null,
      cancelRequestedAt: null,
      heartbeatAt: sweptAt,
    });
  });

  it("recovers a genuine failure after stale sweep from the original event on a fresh writer", async () => {
    const f = await fixture();
    const sweptAt = new Date(T0.getTime() + 45_001);
    const manager = lifecycle(() => sweptAt);
    expect(await manager.sweepNow()).toEqual([f.leaseId]);

    // The engine appended the genuine outcome, then this process disappeared
    // before mirror/settlement. The fresh writer has no cached terminalEvent.
    const originalLog = memoryEventLog(f.sessionId);
    const original = await originalLog.append(f.sessionId, "run_failed", {
      runId: f.runId,
      code: "model_terminal",
      message: "safe failure",
    });
    const freshProcessLog = memoryEventLog(f.sessionId, 3000);
    const fresh = { writer: manager.writer(f.execution, freshProcessLog), log: freshProcessLog };
    await fresh.writer.settle(original);

    expect(originalLog.appended).toHaveLength(1);
    expect(freshProcessLog.appended).toHaveLength(0);
    expect(await state(f.runId)).toMatchObject({
      run_status: "failed",
      turn_status: "failed",
      outbox_status: "settled",
      run_cancel: true,
      generation: 10,
      released_at: sweptAt,
      lease_cancel: sweptAt,
      settled_at: sweptAt,
    });
    const mirror = await db.select().from(schema.sessionEventMirror).where(and(
      eq(schema.sessionEventMirror.sessionId, f.sessionId),
      eq(schema.sessionEventMirror.seq, original.seq),
    ));
    expect(mirror).toHaveLength(1);
    expect(mirror[0]).toMatchObject({ type: "run_failed", payload: original.payload });
    await expect(fresh.writer.events.append(f.sessionId, "run_cancelled", { runId: f.runId }))
      .rejects.toMatchObject({ code: "invalid_transition" });
    expect(freshProcessLog.appended).toHaveLength(0);
    expect(await state(f.runId)).toMatchObject({ run_status: "failed", turn_status: "failed" });
  });
});
