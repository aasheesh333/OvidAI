import { and, asc, eq, inArray, isNull, lt, sql } from "drizzle-orm";
import {
  createRunOutboxStore,
  eventMirror,
  messages,
  RunOutboxError,
  runs,
  schema,
  toSessionEvent,
  type CollabMemberRow,
  type CollabRoomRow,
  type CollabSenderLeaseRow,
  type CollabTurnRow,
  type Db,
  type MessageRow,
  type RunAdmissionTransaction,
  type RunOutboxRecord,
  type RunRow,
  type SessionRow,
} from "@ovid/db";
import type { EventLog } from "@ovid/events";
import { collabAuthorityToken } from "@ovid/queue";
import {
  sessionEventSchema,
  type SessionEvent,
  type SessionEventType,
} from "@ovid/shared";

import type { CollabRunExecution } from "./collabRun.js";

/**
 * Root-Collab final writer and genuinely-active lease controllers.
 *
 * Canonical schema plus messages/runs/eventMirror/RunOutboxStore repositories
 * perform the writes. Narrow direct SQL covers only Collab turn/lease CAS and
 * the server-owned assistant primary-key append those APIs cannot express.
 * A writer is root-run scoped: descendants require their own authorized fence.
 *
 * Redis and Postgres are NOT one atomic transaction. Event append is invoked
 * while the canonical authority rows are locked, then the SAME event is put
 * and verified in the mirror before run/turn/outbox/lease commit. A crash or
 * mirror failure can therefore leave an unmirrored Redis event; it can never
 * produce a committed settled outbox without the canonical event. Retrying a
 * live writer reuses its cached event/seq. Cross-process recovery must supply
 * the original event or recover it from Redis; this module does not invent a
 * sequence or claim Redis/DB atomicity.
 */

type Tx = RunAdmissionTransaction;

export const COLLAB_RUN_HEARTBEAT_INTERVAL_MS = 10_000;
export const COLLAB_RUN_STALE_SWEEP_INTERVAL_MS = 10_000;
export const COLLAB_RUN_LEASE_STALE_AFTER_MS = 45_000;

export type CollabRunTerminalStatus = "completed" | "failed" | "cancelled";

export interface CollabRunTerminalOutcome {
  status: CollabRunTerminalStatus;
  lastError: string | null;
}

export type CollabRunLifecycleErrorCode =
  | "invalid_job"
  | "invalid_record"
  | "invalid_event"
  | "invalid_transition"
  | "not_member"
  | "session_closed"
  | "admission_denied"
  | "stale_authorization"
  | "publication_unresolved"
  | "durable_evidence_missing"
  | "event_conflict";

export class CollabRunLifecycleError extends Error {
  constructor(readonly code: CollabRunLifecycleErrorCode) {
    super(code);
    this.name = "CollabRunLifecycleError";
  }
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

/** The terminal event emitted by the actual engine/processor is the outcome. */
export function collabTerminalOutcome(
  type: SessionEventType,
  payload: Record<string, unknown>,
  rootRunId: string,
): CollabRunTerminalOutcome | null {
  if (payload.runId !== undefined && payload.runId !== rootRunId) {
    throw new CollabRunLifecycleError("invalid_event");
  }
  if (type === "run_completed") {
    return { status: "completed", lastError: null };
  }
  if (type === "run_cancelled") {
    return { status: "cancelled", lastError: "cancelled" };
  }
  if (type === "run_failed") {
    const code = payload.code;
    const detail = payload.lastError;
    if (!nonEmpty(code) || (detail !== undefined && !nonEmpty(detail))) {
      throw new CollabRunLifecycleError("invalid_event");
    }
    const lastError = nonEmpty(detail) ? detail : code;
    return code === "cancelled"
      ? { status: "cancelled", lastError }
      : { status: "failed", lastError };
  }
  return null;
}

function validDate(value: Date): Date {
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) {
    throw new CollabRunLifecycleError("invalid_record");
  }
  return new Date(value.getTime());
}

function validCadence(value: number, allowZero = false): number {
  if (!Number.isFinite(value) || (allowZero ? value < 0 : value <= 0)) {
    throw new CollabRunLifecycleError("invalid_job");
  }
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function canonical(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string" || typeof value === "boolean") return JSON.stringify(value) as string;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new CollabRunLifecycleError("invalid_record");
    return JSON.stringify(value) as string;
  }
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (!isRecord(value)) throw new CollabRunLifecycleError("invalid_record");
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
}

function sameOutcome(a: CollabRunTerminalOutcome, b: CollabRunTerminalOutcome): boolean {
  return a.status === b.status && a.lastError === b.lastError;
}

function sameEvent(a: SessionEvent, b: SessionEvent): boolean {
  return a.sessionId === b.sessionId && a.seq === b.seq && a.type === b.type &&
    a.ts === b.ts && canonical(a.payload) === canonical(b.payload);
}

export interface CollabHeartbeatController {
  readonly active: boolean;
  /** The initial conditional tick must prove running execution before a timer exists. */
  start(): Promise<boolean>;
  /** Stops future ticks immediately and drains an in-flight async tick. */
  stop(): Promise<void>;
  close(): Promise<void>;
}

export function createCollabHeartbeatController(options: {
  heartbeat: () => Promise<boolean>;
  intervalMs?: number;
  onError?: (error: unknown) => void;
}): CollabHeartbeatController {
  const intervalMs = validCadence(options.intervalMs ?? COLLAB_RUN_HEARTBEAT_INTERVAL_MS);
  let started = false;
  let closed = false;
  let active = false;
  let provedActive = false;
  let timer: ReturnType<typeof setInterval> | null = null;
  let inFlight: Promise<boolean> | null = null;

  const clear = (): void => {
    if (timer !== null) clearInterval(timer);
    timer = null;
  };

  const tick = (): Promise<boolean> => {
    if (!active || closed) return Promise.resolve(false);
    if (inFlight !== null) return inFlight;
    const current = (async () => {
      try {
        const valid = await options.heartbeat();
        if (valid) {
          provedActive = true;
        } else {
          active = false;
          clear();
        }
        return valid;
      } catch (error) {
        // A transient DB failure after the initial running proof must not make
        // a live execution permanently silent; later cadence ticks retry. The
        // initial proof itself still fails closed and installs no timer.
        options.onError?.(error);
        if (!provedActive) {
          active = false;
          clear();
        }
        return provedActive;
      }
    })();
    inFlight = current;
    void current.finally(() => {
      if (inFlight === current) inFlight = null;
    });
    return current;
  };

  const stop = async (): Promise<void> => {
    closed = true;
    active = false;
    clear();
    const pending = inFlight;
    if (pending !== null) await pending;
  };

  return {
    get active() {
      return active;
    },
    async start() {
      if (started || closed) return false;
      started = true;
      active = true;
      const valid = await tick();
      if (!valid || closed || !active) {
        active = false;
        clear();
        return false;
      }
      timer = setInterval(() => {
        void tick();
      }, intervalMs);
      timer.unref?.();
      return true;
    },
    stop,
    close: stop,
  };
}

export interface CollabStaleSweepController {
  start(): void;
  close(): Promise<void>;
}

/** Single-flight scheduler; the injected sweep remains the canonical DB operation. */
export function createCollabStaleSweepController(options: {
  sweep: () => Promise<unknown>;
  intervalMs?: number;
  onError?: (error: unknown) => void;
}): CollabStaleSweepController {
  const intervalMs = validCadence(options.intervalMs ?? COLLAB_RUN_STALE_SWEEP_INTERVAL_MS);
  let started = false;
  let closed = false;
  let timer: ReturnType<typeof setInterval> | null = null;
  let inFlight: Promise<void> | null = null;
  let closePromise: Promise<void> | null = null;

  const tick = (): Promise<void> => {
    if (closed) return Promise.resolve();
    if (inFlight !== null) return inFlight;
    const current = (async () => {
      try {
        await options.sweep();
      } catch (error) {
        options.onError?.(error);
      }
    })();
    inFlight = current;
    void current.finally(() => {
      if (inFlight === current) inFlight = null;
    });
    return current;
  };

  return {
    start() {
      if (started || closed) return;
      started = true;
      timer = setInterval(() => {
        void tick();
      }, intervalMs);
      timer.unref?.();
    },
    close() {
      closePromise ??= (async () => {
        closed = true;
        if (timer !== null) clearInterval(timer);
        timer = null;
        const pending = inFlight;
        if (pending !== null) await pending;
      })();
      return closePromise;
    },
  };
}

interface CollabLifecycleRows {
  message: MessageRow;
  run: RunRow;
  turn: CollabTurnRow;
  lease: CollabSenderLeaseRow;
  outbox: RunOutboxRecord;
}

interface LockedLifecycle {
  rows: CollabLifecycleRows;
  host: SessionRow | null;
  senderActive: boolean;
  room: CollabRoomRow | null;
  member: CollabMemberRow | null;
  latestLeaseGeneration: number;
  now: Date;
}

async function lockSenderKey(tx: Tx, actorUserId: string, key: string): Promise<void> {
  await tx.execute(sql`
    SELECT pg_advisory_xact_lock(hashtextextended(${`0033:run-admission:${actorUserId}:${key}`}, 0))`);
}

async function lockHostSession(tx: Tx, sessionId: string): Promise<SessionRow | null> {
  const rows = await tx.select().from(schema.sessions)
    .where(eq(schema.sessions.id, sessionId)).for("update").limit(1);
  return rows[0] ?? null;
}

async function lockSenderActive(tx: Tx, actorUserId: string): Promise<boolean> {
  const users = await tx.select({ uid: schema.users.uid, bannedAt: schema.users.bannedAt })
    .from(schema.users).where(eq(schema.users.uid, actorUserId)).for("update").limit(1);
  if (users[0] === undefined) return false;
  const deleting = await tx.execute(sql`
    SELECT 1 AS present FROM account_deletions
    WHERE uid = ${actorUserId} AND state IN ('pending','fenced','deleting','deleted')
    LIMIT 1`) as unknown as Array<{ present: number }>;
  return users[0].bannedAt === null && deleting.length === 0;
}

async function lockRoom(tx: Tx, roomId: string): Promise<CollabRoomRow | null> {
  const rows = await tx.select().from(schema.collabRooms)
    .where(eq(schema.collabRooms.id, roomId)).for("update").limit(1);
  return rows[0] ?? null;
}

async function lockMember(tx: Tx, roomId: string, actorUserId: string): Promise<CollabMemberRow | null> {
  const rows = await tx.select().from(schema.collabMembers)
    .where(and(eq(schema.collabMembers.roomId, roomId), eq(schema.collabMembers.userId, actorUserId)))
    .for("update").limit(1);
  return rows[0] ?? null;
}

async function latestLeaseGeneration(tx: Tx, roomId: string): Promise<number> {
  const rows = await tx.execute(sql`
    SELECT COALESCE(MAX(generation), 0) AS generation
    FROM collab_sender_leases WHERE room_id = ${roomId}`) as unknown as Array<{ generation: number | string }>;
  const generation = Number(rows[0]?.generation ?? 0);
  if (!Number.isSafeInteger(generation) || generation < 1) {
    throw new CollabRunLifecycleError("invalid_record");
  }
  return generation;
}

async function loadRows(tx: Tx, outboxId: string, forUpdate: boolean): Promise<CollabLifecycleRows | null> {
  const query = tx.select({
    message: schema.messages,
    run: schema.runs,
    turn: schema.collabTurns,
    lease: schema.collabSenderLeases,
    outbox: schema.runOutbox,
  }).from(schema.runOutbox)
    .innerJoin(schema.messages, eq(schema.messages.id, schema.runOutbox.userMessageId))
    .innerJoin(schema.runs, eq(schema.runs.id, schema.runOutbox.runId))
    .innerJoin(schema.collabTurns, eq(schema.collabTurns.runId, schema.runOutbox.runId))
    .innerJoin(schema.collabSenderLeases, eq(schema.collabSenderLeases.runId, schema.runOutbox.runId))
    .where(eq(schema.runOutbox.outboxId, outboxId));
  const rows = forUpdate ? await query.for("update").limit(1) : await query.limit(1);
  return rows[0] ?? null;
}

function requestAttachments(request: Record<string, unknown>): unknown[] {
  return request.attachmentIds === undefined ? [] : request.attachmentIds as unknown[];
}

/** Revalidate the delivered execution snapshot against the current durable bundle. */
function assertSnapshotMatches(execution: CollabRunExecution, rows: CollabLifecycleRows): void {
  const { job, publication } = execution;
  const { message, run, turn, lease, outbox } = rows;
  const request = outbox.requestPayload;
  const body = outbox.bodyPayload;
  if (
    !isRecord(request) || !isRecord(body) || !isRecord(body.modelContext) || !isRecord(body.collab) ||
    request.schemaVersion !== 1 ||
    request.idempotencyKey !== outbox.idempotencyKey ||
    request.text !== message.content ||
    message.id !== turn.userMessageId ||
    message.sessionId !== outbox.sessionId ||
    message.role !== "user" ||
    run.id !== turn.runId ||
    run.sessionId !== message.sessionId ||
    run.promptMessageId !== message.id ||
    turn.roomId !== job.collab.roomId ||
    turn.participantId !== job.collab.participantId ||
    turn.actorUserId !== job.actorUserId ||
    turn.actorUserId !== outbox.actorUserId ||
    turn.idempotencyKey !== outbox.idempotencyKey ||
    turn.model !== job.modelContext.requestedModel ||
    outbox.actorUserId !== job.actorUserId ||
    outbox.runId !== run.id ||
    outbox.userMessageId !== message.id ||
    outbox.jobId !== run.id ||
    lease.id !== job.collab.leaseId ||
    lease.roomId !== job.collab.roomId ||
    lease.holderParticipantId !== job.collab.participantId ||
    lease.holderUserId !== job.actorUserId ||
    lease.runId !== run.id ||
    job.runId !== run.id ||
    job.sessionId !== message.sessionId ||
    job.prompt !== message.content ||
    body.ownerUserId !== job.ownerUserId ||
    body.userId !== job.actorUserId ||
    body.sessionId !== message.sessionId ||
    body.runId !== run.id ||
    body.tier !== job.tier ||
    body.byokKeyId !== (job.byokKeyId ?? null) ||
    body.byokModel !== job.byokModel ||
    canonical(body.modelContext) !== canonical(job.modelContext) ||
    canonical(body.collab) !== canonical(job.collab) ||
    canonical(requestAttachments(request)) !== canonical(job.attachmentIds ?? []) ||
    (request.model !== undefined && body.requestedModel !== request.model) ||
    (request.model === undefined && body.requestedModel !== null && body.requestedModel !== undefined) ||
    publication.outboxStatus !== "published" ||
    (publication.leaseGeneration !== lease.generation && lease.releasedAt === null)
  ) throw new CollabRunLifecycleError("invalid_record");
}

export class CollabRunWriter {
  readonly db: Db;
  readonly events: EventLog;
  readonly heartbeat: CollabHeartbeatController;
  private terminalEvent: SessionEvent | null = null;

  constructor(
    readonly execution: CollabRunExecution,
    private readonly deps: {
      db: Db;
      events: EventLog;
      now: () => Date;
      staleAfterMs: number;
      heartbeatIntervalMs: number;
      onError?: (error: unknown) => void;
    },
    private readonly onClose: () => void,
  ) {
    this.db = this.assistantDedupingDb();
    this.events = {
      append: (sessionId, type, payload) => this.appendEvent(sessionId, type, payload),
      readSince: deps.events.readSince.bind(deps.events),
      subscribe: deps.events.subscribe.bind(deps.events),
    };
    this.heartbeat = createCollabHeartbeatController({
      heartbeat: () => this.heartbeatOnce(),
      intervalMs: deps.heartbeatIntervalMs,
      ...(deps.onError !== undefined ? { onError: deps.onError } : {}),
    });
  }

  private async locked<T>(
    fn: (tx: Tx, locked: LockedLifecycle) => Promise<T>,
  ): Promise<T> {
    const execution = this.execution;
    return this.deps.db.transaction<T>(async (dbTx) => {
      const tx = dbTx as Tx;
      // Unlocked rows are hints only. Authoritative reads follow the exact
      // sender-key -> host -> sender -> room -> member -> bundle claim order.
      const hint = await loadRows(tx, execution.collab.outboxId, false);
      if (hint === null) throw new CollabRunLifecycleError("invalid_record");
      await lockSenderKey(tx, hint.outbox.actorUserId, hint.outbox.idempotencyKey);
      const host = await lockHostSession(tx, execution.job.sessionId);
      const senderActive = await lockSenderActive(tx, execution.actorUserId);
      const room = await lockRoom(tx, execution.collab.roomId);
      const member = await lockMember(tx, execution.collab.roomId, execution.actorUserId);
      const rows = await loadRows(tx, execution.collab.outboxId, true);
      if (rows === null) throw new CollabRunLifecycleError("invalid_record");
      assertSnapshotMatches(execution, rows);
      return fn(tx, {
        rows,
        host,
        senderActive,
        room,
        member,
        latestLeaseGeneration: await latestLeaseGeneration(tx, execution.collab.roomId),
        now: validDate(this.deps.now()),
      });
    });
  }

  private requireLive(
    locked: LockedLifecycle,
    mode: "running" | "heartbeat" | "settle",
    outcome?: CollabRunTerminalOutcome,
  ): void {
    const { execution } = this;
    const { rows, host, room, member, now } = locked;
    const { lease, run, turn, outbox } = rows;
    if (!locked.senderActive) throw new CollabRunLifecycleError("admission_denied");
    if (
      host === null || host.id !== execution.job.sessionId ||
      host.userId !== execution.ownerUserId || host.deletedAt !== null ||
      room === null || room.id !== execution.collab.roomId ||
      room.sessionId !== execution.job.sessionId ||
      room.ownerUserId !== execution.ownerUserId ||
      member === null || member.roomId !== room.id ||
      member.userId !== execution.actorUserId ||
      member.participantId !== execution.collab.participantId ||
      member.status !== "active"
    ) throw new CollabRunLifecycleError("not_member");
    if (room.lifecycle !== "active") throw new CollabRunLifecycleError("session_closed");

    const heartbeatAt = lease.heartbeatAt.getTime();
    const timestamp = now.getTime();
    if (
      room.generation !== lease.roomGeneration ||
      member.generation !== lease.membershipGeneration ||
      member.generation !== execution.collab.membershipGeneration ||
      lease.generation !== execution.collab.leaseGeneration ||
      locked.latestLeaseGeneration !== lease.generation ||
      lease.releasedAt !== null ||
      !Number.isFinite(timestamp) || !Number.isFinite(heartbeatAt) ||
      timestamp < heartbeatAt || timestamp - heartbeatAt > this.deps.staleAfterMs ||
      outbox.status !== "published" ||
      outbox.attempts < execution.publication.outboxAttempts
    ) throw new CollabRunLifecycleError("stale_authorization");

    const expectedToken = collabAuthorityToken({
      roomId: room.id,
      sessionId: host.id,
      ownerUserId: execution.ownerUserId,
      actorUserId: execution.actorUserId,
      participantId: member.participantId,
      roomGeneration: room.generation,
      membershipGeneration: member.generation,
      leaseId: lease.id,
      leaseGeneration: lease.generation,
      rootRunId: execution.collab.rootRunId,
      turnId: turn.id,
    });
    if (expectedToken !== execution.publication.authorityToken) {
      throw new CollabRunLifecycleError("stale_authorization");
    }

    if (mode !== "settle") {
      if (
        run.status !== "running" || turn.status !== "running" ||
        run.cancelRequested || turn.cancelRequestedAt !== null || lease.cancelRequestedAt !== null
      ) throw new CollabRunLifecycleError("stale_authorization");
      return;
    }
    if (outcome === undefined) throw new CollabRunLifecycleError("invalid_job");
    if (outbox.publishedAt === null) throw new CollabRunLifecycleError("publication_unresolved");
    if (run.status !== turn.status || (run.status !== "queued" && run.status !== "running")) {
      throw new CollabRunLifecycleError("invalid_transition");
    }
    if (outcome.status === "completed" && (run.status !== "running" || run.startedAt === null)) {
      throw new CollabRunLifecycleError("durable_evidence_missing");
    }
    const cancelled = run.cancelRequested || turn.cancelRequestedAt !== null || lease.cancelRequestedAt !== null;
    if (outcome.status !== "cancelled" && cancelled) {
      throw new CollabRunLifecycleError("stale_authorization");
    }
  }

  /**
   * Truthful non-success reconciliation is not a fresh authorization to do
   * work. It persists only an actual failure/cancellation for this exact run.
   * Current membership/room/lease freshness may have been revoked by the stale
   * sweep; original durable lineage and publication/execution evidence remain
   * mandatory. A different or newer room lease is never mutated.
   */
  private requireNonSuccessSettlement(locked: LockedLifecycle): void {
    const { execution } = this;
    const { rows, host, room, member } = locked;
    const { lease, run, turn, outbox } = rows;
    if (
      host === null || host.id !== execution.job.sessionId ||
      host.userId !== execution.ownerUserId ||
      room === null || room.id !== execution.collab.roomId ||
      room.sessionId !== execution.job.sessionId ||
      room.ownerUserId !== execution.ownerUserId ||
      member === null || member.roomId !== room.id ||
      member.userId !== execution.actorUserId ||
      member.participantId !== execution.collab.participantId
    ) throw new CollabRunLifecycleError("not_member");

    const originalAuthority = collabAuthorityToken({
      roomId: lease.roomId,
      sessionId: host.id,
      ownerUserId: room.ownerUserId,
      actorUserId: turn.actorUserId,
      participantId: lease.holderParticipantId,
      roomGeneration: lease.roomGeneration,
      membershipGeneration: lease.membershipGeneration,
      leaseId: lease.id,
      leaseGeneration: execution.collab.leaseGeneration,
      rootRunId: execution.collab.rootRunId,
      turnId: turn.id,
    });
    if (originalAuthority !== execution.publication.authorityToken) {
      throw new CollabRunLifecycleError("stale_authorization");
    }
    if (outbox.publishedAt === null) throw new CollabRunLifecycleError("publication_unresolved");
    if (outbox.status !== "published" || outbox.attempts < execution.publication.outboxAttempts) {
      throw new CollabRunLifecycleError("stale_authorization");
    }
    if (run.status !== turn.status || (run.status !== "queued" && run.status !== "running")) {
      throw new CollabRunLifecycleError("invalid_transition");
    }
    if (run.status === "running" && run.startedAt === null) {
      throw new CollabRunLifecycleError("durable_evidence_missing");
    }

    const expected = execution.collab.leaseGeneration;
    if (
      (lease.generation !== expected && lease.generation !== expected + 1) ||
      (lease.generation === expected && lease.releasedAt !== null) ||
      (lease.generation === expected + 1 &&
        (lease.releasedAt === null || lease.cancelRequestedAt === null))
    ) throw new CollabRunLifecycleError("stale_authorization");
  }

  private fullySettled(rows: CollabLifecycleRows, outcome: CollabRunTerminalOutcome): boolean {
    const expected = this.execution.collab.leaseGeneration;
    const leaseMatches = rows.lease.generation === expected ||
      (outcome.status !== "completed" && rows.lease.generation === expected + 1 &&
        rows.lease.cancelRequestedAt !== null);
    return rows.run.status === outcome.status && rows.run.finishedAt !== null &&
      rows.turn.status === outcome.status &&
      rows.run.lastError === outcome.lastError &&
      rows.outbox.status === "settled" && rows.outbox.settledAt !== null &&
      rows.outbox.publishedAt !== null && rows.lease.releasedAt !== null && leaseMatches;
  }

  private async terminalMirror(tx: Tx): Promise<SessionEvent | null> {
    const rows = await tx.select().from(schema.sessionEventMirror).where(and(
      eq(schema.sessionEventMirror.sessionId, this.execution.job.sessionId),
      inArray(schema.sessionEventMirror.type, ["run_completed", "run_failed", "run_cancelled"]),
      sql`${schema.sessionEventMirror.payload}->>'runId' = ${this.execution.job.runId}`,
    )).limit(2);
    if (rows.length > 1) throw new CollabRunLifecycleError("invalid_record");
    return rows[0] === undefined ? null : toSessionEvent(rows[0]);
  }

  private async completedEvidence(
    tx: Tx,
    assistantMessageId: string,
  ): Promise<{ assistant: MessageRow; event: SessionEvent }> {
    const sessionId = this.execution.job.sessionId;
    // The Collab turn's server-generated durable ID is also the final
    // assistant's primary key. Public send/import cannot choose messages.id;
    // no caller-controlled clientMsgId is consulted or reserved.
    const assistant = await messages.get(tx as unknown as Db, assistantMessageId);
    if (assistant === null || assistant.sessionId !== sessionId || assistant.role !== "assistant") {
      throw new CollabRunLifecycleError("durable_evidence_missing");
    }
    const rows = await tx.select().from(schema.sessionEventMirror).where(and(
      eq(schema.sessionEventMirror.sessionId, sessionId),
      eq(schema.sessionEventMirror.type, "message_completed"),
      sql`${schema.sessionEventMirror.payload}->>'messageId' = ${assistant.id}`,
    )).limit(2);
    if (rows.length !== 1) throw new CollabRunLifecycleError("durable_evidence_missing");
    const event = toSessionEvent(rows[0]!);
    if (event.payload.messageId !== assistant.id || event.payload.content !== assistant.content) {
      throw new CollabRunLifecycleError("durable_evidence_missing");
    }
    return { assistant, event };
  }

  private parseEvent(value: SessionEvent): SessionEvent {
    const event = sessionEventSchema.parse(value);
    if (!Number.isFinite(new Date(event.ts).getTime())) {
      throw new CollabRunLifecycleError("invalid_event");
    }
    if (event.sessionId !== this.execution.job.sessionId) {
      throw new CollabRunLifecycleError("invalid_event");
    }
    return event;
  }

  private async mirrorAndVerify(tx: Tx, event: SessionEvent): Promise<void> {
    await eventMirror.put(tx as unknown as Db, event);
    const rows = await tx.select().from(schema.sessionEventMirror).where(and(
      eq(schema.sessionEventMirror.sessionId, event.sessionId),
      eq(schema.sessionEventMirror.seq, event.seq),
    )).limit(1);
    const stored = rows[0];
    if (
      stored === undefined || stored.type !== event.type ||
      canonical(stored.payload) !== canonical(event.payload) ||
      stored.ts.toISOString() !== new Date(event.ts).toISOString()
    ) throw new CollabRunLifecycleError("event_conflict");
  }

  private async settleTerminal(
    type: SessionEventType,
    payload: Record<string, unknown>,
    outcome: CollabRunTerminalOutcome,
  ): Promise<SessionEvent> {
    return this.locked(async (tx, locked) => {
      const existing = await this.terminalMirror(tx);
      if (this.fullySettled(locked.rows, outcome)) {
        if (existing === null) throw new CollabRunLifecycleError("invalid_record");
        const actual = collabTerminalOutcome(existing.type, existing.payload, this.execution.job.runId);
        if (actual === null || !sameOutcome(actual, outcome) || existing.type !== type ||
          canonical(existing.payload) !== canonical(payload)) {
          throw new CollabRunLifecycleError("invalid_transition");
        }
        if (outcome.status === "completed") await this.completedEvidence(tx, locked.rows.turn.id);
        this.terminalEvent = existing;
        return existing;
      }
      if (
        (locked.rows.run.status !== "queued" && locked.rows.run.status !== "running") ||
        (locked.rows.turn.status !== "queued" && locked.rows.turn.status !== "running") ||
        locked.rows.outbox.status === "settled" || locked.rows.outbox.settledAt !== null
      ) throw new CollabRunLifecycleError("invalid_transition");
      if (existing !== null &&
        (this.terminalEvent === null || !sameEvent(existing, this.terminalEvent))) {
        throw new CollabRunLifecycleError("event_conflict");
      }

      if (outcome.status === "completed") {
        // Fresh success always requires the current unreleased fresh authority.
        this.requireLive(locked, "settle", outcome);
        await this.completedEvidence(tx, locked.rows.turn.id);
      } else {
        // Failure/cancellation is truthful terminal reconciliation, never a
        // fresh success authorization, including after the stale sweep.
        this.requireNonSuccessSettlement(locked);
      }

      let event = this.terminalEvent;
      if (event !== null) {
        const cachedOutcome = collabTerminalOutcome(event.type, event.payload, this.execution.job.runId);
        if (cachedOutcome === null || !sameOutcome(cachedOutcome, outcome) ||
          event.type !== type || canonical(event.payload) !== canonical(payload)) {
          throw new CollabRunLifecycleError("invalid_transition");
        }
      } else {
        // The only external side effect occurs after every durable fence and
        // while those same rows remain locked. See the non-atomicity note above.
        event = this.parseEvent(await this.deps.events.append(
          this.execution.job.sessionId,
          type,
          payload,
        ));
        if (event.type !== type || canonical(event.payload) !== canonical(payload)) {
          throw new CollabRunLifecycleError("invalid_event");
        }
        this.terminalEvent = event;
      }
      await this.mirrorAndVerify(tx, event);

      const fromStatus = locked.rows.run.status as "queued" | "running";
      const finished = await runs.finish(
        tx as unknown as Db,
        this.execution.job.runId,
        outcome.status,
        outcome.lastError,
      );
      if (!finished) throw new CollabRunLifecycleError("invalid_transition");
      const turns = await tx.update(schema.collabTurns).set({
        status: outcome.status,
        updatedAt: locked.now,
      }).where(and(
        eq(schema.collabTurns.id, locked.rows.turn.id),
        eq(schema.collabTurns.runId, this.execution.job.runId),
        eq(schema.collabTurns.roomId, locked.rows.turn.roomId),
        eq(schema.collabTurns.status, fromStatus),
      )).returning({ id: schema.collabTurns.id });
      if (turns.length !== 1) throw new CollabRunLifecycleError("invalid_transition");

      // Reuse the canonical transition on THIS outer transaction (savepoint),
      // after explicitly requiring confirmed publication above. The stock
      // store alone cannot express the Collab authority/turn/lease CAS.
      const outbox = createRunOutboxStore(tx as unknown as Db, {
        clock: () => locked.now,
        authorize: async () => {
          throw new RunOutboxError("authorization_required");
        },
      });
      const settled = await outbox.markSettled({ outboxId: locked.rows.outbox.outboxId });
      if (settled === null || settled.status !== "settled" || settled.publishedAt === null) {
        throw new CollabRunLifecycleError("invalid_transition");
      }

      if (locked.rows.lease.releasedAt !== null) {
        // The stale sweep already released exactly this old lease. Re-lock and
        // compare its released/cancel fence, but do not write releasedAt again,
        // resurrect it, or touch any newer room lease.
        if (
          outcome.status === "completed" ||
          locked.rows.lease.generation !== this.execution.collab.leaseGeneration + 1 ||
          locked.rows.lease.cancelRequestedAt === null
        ) throw new CollabRunLifecycleError("stale_authorization");
        const guarded = await tx.select({ id: schema.collabSenderLeases.id })
          .from(schema.collabSenderLeases)
          .where(and(
            eq(schema.collabSenderLeases.id, locked.rows.lease.id),
            eq(schema.collabSenderLeases.runId, this.execution.job.runId),
            eq(schema.collabSenderLeases.generation, locked.rows.lease.generation),
            eq(schema.collabSenderLeases.releasedAt, locked.rows.lease.releasedAt!),
            eq(schema.collabSenderLeases.cancelRequestedAt, locked.rows.lease.cancelRequestedAt!),
          )).for("update").limit(1);
        if (guarded.length !== 1) throw new CollabRunLifecycleError("stale_authorization");
      } else {
        const released = await tx.update(schema.collabSenderLeases).set({
          releasedAt: locked.now,
        }).where(and(
          eq(schema.collabSenderLeases.id, locked.rows.lease.id),
          eq(schema.collabSenderLeases.generation, this.execution.collab.leaseGeneration),
          eq(schema.collabSenderLeases.runId, this.execution.job.runId),
          isNull(schema.collabSenderLeases.releasedAt),
        )).returning({ id: schema.collabSenderLeases.id });
        if (released.length !== 1) throw new CollabRunLifecycleError("stale_authorization");
      }
      return event;
    });
  }

  private async appendLiveEvent(
    type: SessionEventType,
    payload: Record<string, unknown>,
  ): Promise<SessionEvent> {
    return this.locked(async (tx, locked) => {
      if (type === "message_completed") {
        const assistant = await messages.get(tx as unknown as Db, locked.rows.turn.id);
        if (assistant === null || assistant.sessionId !== this.execution.job.sessionId ||
          assistant.role !== "assistant" ||
          payload.messageId !== assistant.id || payload.content !== assistant.content) {
          throw new CollabRunLifecycleError("durable_evidence_missing");
        }
        const existing = await tx.select().from(schema.sessionEventMirror).where(and(
          eq(schema.sessionEventMirror.sessionId, this.execution.job.sessionId),
          eq(schema.sessionEventMirror.type, "message_completed"),
          sql`${schema.sessionEventMirror.payload}->>'messageId' = ${assistant.id}`,
        )).limit(2);
        if (existing.length > 1) throw new CollabRunLifecycleError("invalid_record");
        if (existing[0] !== undefined) {
          const event = toSessionEvent(existing[0]);
          if (canonical(event.payload) !== canonical(payload)) {
            throw new CollabRunLifecycleError("event_conflict");
          }
          if (!this.fullySettled(locked.rows, { status: "completed", lastError: null })) {
            this.requireLive(locked, "running");
          }
          return event;
        }
      }
      this.requireLive(locked, "running");
      const event = this.parseEvent(await this.deps.events.append(
        this.execution.job.sessionId,
        type,
        payload,
      ));
      if (event.type !== type || canonical(event.payload) !== canonical(payload)) {
        throw new CollabRunLifecycleError("invalid_event");
      }
      await this.mirrorAndVerify(tx, event);
      return event;
    });
  }

  private async appendEvent(
    sessionId: string,
    type: SessionEventType,
    payload: Record<string, unknown>,
  ): Promise<SessionEvent> {
    // Descendant sessions are deliberately outside this root writer's claim.
    // Their indirect fence is a separately documented composition blocker.
    if (sessionId !== this.execution.job.sessionId) {
      return this.deps.events.append(sessionId, type, payload);
    }
    const outcome = collabTerminalOutcome(type, payload, this.execution.job.runId);
    if (outcome === null) return this.appendLiveEvent(type, payload);
    // Stop and drain BEFORE terminal evidence/outbox/lease settlement. A late
    // heartbeat can therefore never extend the just-released lease.
    await this.heartbeat.stop();
    const terminalPayload = payload.runId === undefined ? { ...payload, runId: this.execution.job.runId } : payload;
    return this.settleTerminal(type, terminalPayload, outcome);
  }

  private async appendAssistant(input: {
    content: string;
    reasoning?: string | null;
  }): Promise<MessageRow> {
    const expectedReasoning = input.reasoning ?? null;
    return this.locked(async (tx, locked) => {
      const assistantMessageId = locked.rows.turn.id;
      const validate = (assistant: MessageRow): MessageRow => {
        if (assistant.sessionId !== this.execution.job.sessionId ||
          assistant.role !== "assistant" || assistant.content !== input.content ||
          assistant.reasoning !== expectedReasoning) {
          throw new CollabRunLifecycleError("invalid_record");
        }
        if (!this.fullySettled(locked.rows, { status: "completed", lastError: null })) {
          this.requireLive(locked, "running");
        }
        return assistant;
      };

      const existing = await messages.get(tx as unknown as Db, assistantMessageId);
      if (existing !== null) return validate(existing);
      this.requireLive(locked, "running");

      // Canonical messages.append generates a fresh ID and cannot express this
      // server-owned idempotency identity. Use the same canonical table/columns
      // with the already-durable Collab turn ID as the assistant primary key.
      // The PK (not public clientMsgId) is the unique backstop and replay read.
      const inserted = await tx.insert(schema.messages).values({
        id: assistantMessageId,
        sessionId: this.execution.job.sessionId,
        role: "assistant",
        content: input.content,
        createdAt: locked.now,
        ...(input.reasoning !== undefined ? { reasoning: input.reasoning } : {}),
      }).onConflictDoNothing({ target: schema.messages.id }).returning();
      if (inserted[0] !== undefined) return inserted[0];
      const replay = await messages.get(tx as unknown as Db, assistantMessageId);
      if (replay === null) throw new CollabRunLifecycleError("invalid_record");
      return validate(replay);
    });
  }

  private assistantDedupingDb(): Db {
    // agent-core imports the canonical repository directly, so the composition
    // seam is its Db argument. Intercept only the exact root assistant insert
    // shape used by messages.append; every other operation remains canonical.
    const base = this.deps.db;
    const writer = this;
    return new Proxy(base, {
      get(target, property) {
        if (property === "insert") {
          return (table: unknown) => {
            const insert = target.insert(table as never);
            if (table !== schema.messages) return insert;
            return {
              values(value: unknown) {
                if (!isRecord(value) || value.sessionId !== writer.execution.job.sessionId ||
                  value.role !== "assistant" || !nonEmpty(value.content) && value.content !== "") {
                  return insert.values(value as never);
                }
                return {
                  async returning() {
                    return [await writer.appendAssistant({
                      content: value.content as string,
                      ...(value.reasoning !== undefined
                        ? { reasoning: value.reasoning as string | null }
                        : {}),
                    })];
                  },
                };
              },
            };
          };
        }
        const value = Reflect.get(target, property, target) as unknown;
        return typeof value === "function" ? value.bind(target) : value;
      },
    }) as Db;
  }

  private async heartbeatOnce(): Promise<boolean> {
    try {
      return await this.locked(async (tx, locked) => {
        this.requireLive(locked, "heartbeat");
        const updated = await tx.update(schema.collabSenderLeases).set({
          heartbeatAt: locked.now,
        }).where(and(
          eq(schema.collabSenderLeases.id, this.execution.collab.leaseId),
          eq(schema.collabSenderLeases.generation, this.execution.collab.leaseGeneration),
          eq(schema.collabSenderLeases.runId, this.execution.job.runId),
          isNull(schema.collabSenderLeases.releasedAt),
          isNull(schema.collabSenderLeases.cancelRequestedAt),
        )).returning({ id: schema.collabSenderLeases.id });
        return updated.length === 1;
      });
    } catch (error) {
      if (error instanceof CollabRunLifecycleError) return false;
      throw error;
    }
  }

  /**
   * Retry/recover with the ORIGINAL terminal event and Redis sequence. No new
   * external append occurs. Run/turn must be active (including stale-swept
   * non-success recovery) or exactly fully settled for replay; partial terminal
   * states left by other writers are rejected rather than overwritten.
   */
  async settle(value: SessionEvent): Promise<SessionEvent> {
    const event = this.parseEvent(value);
    if (event.payload.runId !== this.execution.job.runId) {
      throw new CollabRunLifecycleError("invalid_event");
    }
    const outcome = collabTerminalOutcome(event.type, event.payload, this.execution.job.runId);
    if (outcome === null) throw new CollabRunLifecycleError("invalid_event");
    if (this.terminalEvent !== null && !sameEvent(event, this.terminalEvent)) {
      throw new CollabRunLifecycleError("invalid_transition");
    }
    await this.heartbeat.stop();
    this.terminalEvent = event;
    return this.settleTerminal(event.type, event.payload, outcome);
  }

  async startHeartbeat(): Promise<boolean> {
    return this.heartbeat.start();
  }

  async close(): Promise<void> {
    await this.heartbeat.close();
    this.onClose();
  }
}

async function fenceStaleLease(
  db: Db,
  candidate: { id: string; roomId: string },
  timestamp: Date,
  staleAfterMs: number,
): Promise<boolean> {
  return db.transaction(async (dbTx) => {
    const tx = dbTx as Tx;
    // Preserve the existing gateway sweeper's room -> lease order. Settlement
    // and heartbeat use the longer admission order above and lock this room
    // before the lease bundle as well, so the orders compose.
    await lockRoom(tx, candidate.roomId);
    const leases = await tx.select().from(schema.collabSenderLeases)
      .where(eq(schema.collabSenderLeases.id, candidate.id)).for("update").limit(1);
    const lease = leases[0];
    if (
      lease === undefined || lease.roomId !== candidate.roomId || lease.releasedAt !== null ||
      timestamp.getTime() < lease.heartbeatAt.getTime() ||
      timestamp.getTime() - lease.heartbeatAt.getTime() <= staleAfterMs
    ) return false;
    const latest = await latestLeaseGeneration(tx, candidate.roomId);
    if (latest !== lease.generation) return false;
    const nextGeneration = latest + 1;
    if (!Number.isSafeInteger(nextGeneration)) throw new CollabRunLifecycleError("invalid_record");
    const fenced = await tx.update(schema.collabSenderLeases).set({
      generation: nextGeneration,
      releasedAt: timestamp,
      cancelRequestedAt: timestamp,
    }).where(and(
      eq(schema.collabSenderLeases.id, lease.id),
      eq(schema.collabSenderLeases.generation, lease.generation),
      isNull(schema.collabSenderLeases.releasedAt),
    )).returning({ id: schema.collabSenderLeases.id });
    if (fenced.length !== 1) return false;
    await tx.update(schema.collabTurns).set({
      cancelRequestedAt: timestamp,
      updatedAt: timestamp,
    }).where(and(
      eq(schema.collabTurns.runId, lease.runId),
      inArray(schema.collabTurns.status, ["queued", "running"]),
    ));
    await tx.update(schema.runs).set({ cancelRequested: true }).where(and(
      eq(schema.runs.id, lease.runId),
      inArray(schema.runs.status, ["queued", "running"]),
    ));
    // No run/turn terminal status or outbox settlement is invented here.
    return true;
  });
}

export async function sweepStaleCollabLeases(
  db: Db,
  options: { now?: () => Date; staleAfterMs?: number } = {},
): Promise<string[]> {
  const now = options.now ?? (() => new Date());
  const staleAfterMs = validCadence(options.staleAfterMs ?? COLLAB_RUN_LEASE_STALE_AFTER_MS, true);
  const timestamp = validDate(now());
  const cutoff = new Date(timestamp.getTime() - staleAfterMs);
  const candidates = await db.select({
    id: schema.collabSenderLeases.id,
    roomId: schema.collabSenderLeases.roomId,
  }).from(schema.collabSenderLeases).where(and(
    isNull(schema.collabSenderLeases.releasedAt),
    lt(schema.collabSenderLeases.heartbeatAt, cutoff),
  )).orderBy(asc(schema.collabSenderLeases.roomId), asc(schema.collabSenderLeases.id));
  const fenced: string[] = [];
  for (const candidate of candidates) {
    if (await fenceStaleLease(db, candidate, timestamp, staleAfterMs)) fenced.push(candidate.id);
  }
  return fenced;
}

export interface CollabRunLifecycleDeps {
  db: Db;
  now?: () => Date;
  staleAfterMs?: number;
  heartbeatIntervalMs?: number;
  staleSweepIntervalMs?: number;
  onError?: (error: unknown) => void;
}

export function createCollabRunLifecycle(deps: CollabRunLifecycleDeps) {
  const now = deps.now ?? (() => new Date());
  const staleAfterMs = validCadence(deps.staleAfterMs ?? COLLAB_RUN_LEASE_STALE_AFTER_MS, true);
  const heartbeatIntervalMs = validCadence(deps.heartbeatIntervalMs ?? COLLAB_RUN_HEARTBEAT_INTERVAL_MS);
  const staleSweepIntervalMs = validCadence(deps.staleSweepIntervalMs ?? COLLAB_RUN_STALE_SWEEP_INTERVAL_MS);
  const writers = new Set<CollabRunWriter>();
  let staleSweep: CollabStaleSweepController | null = null;
  let closePromise: Promise<void> | null = null;

  const sweepNow = (): Promise<string[]> => sweepStaleCollabLeases(deps.db, { now, staleAfterMs });

  return {
    writer(execution: CollabRunExecution, events: EventLog): CollabRunWriter {
      const writer = new CollabRunWriter(execution, {
        db: deps.db,
        events,
        now,
        staleAfterMs,
        heartbeatIntervalMs,
        ...(deps.onError !== undefined ? { onError: deps.onError } : {}),
      }, () => writers.delete(writer));
      writers.add(writer);
      return writer;
    },

    startStaleSweep(): void {
      staleSweep ??= createCollabStaleSweepController({
        sweep: sweepNow,
        intervalMs: staleSweepIntervalMs,
        ...(deps.onError !== undefined ? { onError: deps.onError } : {}),
      });
      staleSweep.start();
    },

    sweepNow,

    close(): Promise<void> {
      closePromise ??= (async () => {
        await staleSweep?.close();
        await Promise.all([...writers].map((writer) => writer.close()));
      })();
      return closePromise;
    },
  };
}

export type CollabRunLifecycle = ReturnType<typeof createCollabRunLifecycle>;
