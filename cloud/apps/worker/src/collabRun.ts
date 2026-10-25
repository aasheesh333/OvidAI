import { and, eq, isNull, sql } from "drizzle-orm";
import {
  AUTO_ALIASES,
  parseModelEffort,
} from "@ovid/agent-core";
import {
  schema,
  type CollabMemberRow,
  type CollabRoomRow,
  type CollabSenderLeaseRow,
  type CollabTurnRow,
  type Db,
  type MessageRow,
  type QuotaBillingClass,
  type RunAdmissionTransaction,
  type RunOutboxRecord,
  type RunRow,
  type SessionRow,
} from "@ovid/db";
import {
  agentRunJobSchema,
  collabAuthorityToken,
  type AgentRunCollab,
  type AgentRunCollabPublication,
  type AgentRunJob,
  type AgentRunModelContext,
} from "@ovid/queue";

/** Narrow worker adapter and execution-time fence; runProcessor composition is separate. */

type Tx = RunAdmissionTransaction;

export type CollabWorkerJob = AgentRunJob & {
  ownerUserId: string;
  actorUserId: string;
  source: "collab";
  modelContext: AgentRunModelContext;
  tier: string;
  collab: AgentRunCollab;
  collabPublication: AgentRunCollabPublication;
};

export interface CollabRunExecution {
  job: CollabWorkerJob;
  ownerUserId: string;
  actorUserId: string;
  workspaceTier: string;
  modelContext: AgentRunModelContext;
  billingClass: QuotaBillingClass;
  collab: AgentRunCollab;
  publication: AgentRunCollabPublication;
  /** Spread into the existing runKeyAdapter; no current/default key is consulted. */
  keySelection: {
    ctx: { unattended: boolean; byokKeyId: string | null };
    byokDefault: null;
    byokModel?: string;
    modelContext: AgentRunModelContext;
  };
}

export type CollabRunFenceErrorCode =
  | "invalid_job"
  | "invalid_record"
  | "not_member"
  | "session_closed"
  | "admission_denied"
  | "stale_authorization";

export class CollabRunFenceError extends Error {
  constructor(readonly code: CollabRunFenceErrorCode) {
    super(code);
    this.name = "CollabRunFenceError";
  }
}

export type CollabClaimResult =
  | { kind: "claimed"; execution: CollabRunExecution }
  | {
      kind: "fenced";
      code: Exclude<CollabRunFenceErrorCode, "invalid_job">;
    };

interface CollabClaimRows {
  message: MessageRow;
  run: RunRow;
  turn: CollabTurnRow;
  lease: CollabSenderLeaseRow;
  outbox: RunOutboxRecord;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function canonical(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string" || typeof value === "boolean") return JSON.stringify(value) as string;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new CollabRunFenceError("invalid_record");
    return JSON.stringify(value) as string;
  }
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (!isRecord(value)) throw new CollabRunFenceError("invalid_record");
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
}

function validDate(value: Date): Date {
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) {
    throw new CollabRunFenceError("invalid_record");
  }
  return new Date(value.getTime());
}

/** Parse the actual queue contract and derive the existing worker adapters. */
export function collabRunExecution(value: AgentRunJob): CollabRunExecution {
  const parsed = agentRunJobSchema.safeParse(value);
  if (!parsed.success) throw new CollabRunFenceError("invalid_job");
  const job = parsed.data;
  const context = job.modelContext;
  const collab = job.collab;
  const publication = job.collabPublication;
  if (
    job.source !== "collab" ||
    !nonEmpty(job.ownerUserId) ||
    job.userId !== job.ownerUserId ||
    !nonEmpty(job.actorUserId) ||
    !nonEmpty(job.tier) ||
    context === undefined ||
    context.actorUserId !== job.actorUserId ||
    collab === undefined ||
    collab.rootRunId !== job.runId ||
    publication === undefined ||
    publication.leaseGeneration !== collab.leaseGeneration ||
    (context.requestedModel === null
      ? job.requestedModel !== undefined
      : job.requestedModel !== context.requestedModel) ||
    (job.byokKeyId ?? null) !== context.byokKeyId ||
    job.byokModel !== context.byokModel ||
    (context.byokKeyId !== null && !nonEmpty(context.byokModel)) ||
    (context.byokKeyId === null && context.byokModel !== undefined)
  ) throw new CollabRunFenceError("invalid_job");

  const workerJob = job as CollabWorkerJob;
  return {
    job: workerJob,
    ownerUserId: workerJob.ownerUserId,
    actorUserId: workerJob.actorUserId,
    workspaceTier: workerJob.tier,
    modelContext: context,
    billingClass: context.byokKeyId === null ? "ovid_allowance" : "byok",
    collab,
    publication,
    keySelection: {
      ctx: {
        unattended: workerJob.unattended ?? workerJob.schedule !== undefined,
        byokKeyId: context.byokKeyId,
      },
      // A Collab snapshot is authoritative. Never substitute the sender's new
      // default or the host's key/model when an accepted key cannot resolve.
      byokDefault: null,
      ...(context.byokModel !== undefined ? { byokModel: context.byokModel } : {}),
      modelContext: context,
    },
  };
}

/** Exact effective model produced by runKeyAdapter for an accepted Collab snapshot. */
export function collabEffectiveModel(
  execution: Pick<CollabRunExecution, "modelContext">,
  defaultModel: string,
): string {
  const context = execution.modelContext;
  // Accepted BYOK provider model is authoritative even for Auto/manual input;
  // mirror agentKeyFor's alias/default behavior on that exact captured value.
  if (context.byokModel !== undefined) {
    const requested = context.byokModel.trim();
    return requested === "" || (AUTO_ALIASES as readonly string[]).includes(requested)
      ? defaultModel
      : requested;
  }
  if (context.requestedModel === null) return defaultModel;
  const requested = parseModelEffort(context.requestedModel).model;
  return requested === "" || (AUTO_ALIASES as readonly string[]).includes(requested)
    ? defaultModel
    : requested;
}

async function lockSenderKey(tx: Tx, actorUserId: string, key: string): Promise<void> {
  await tx.execute(sql`
    SELECT pg_advisory_xact_lock(hashtextextended(${`0033:run-admission:${actorUserId}:${key}`}, 0))`);
}

async function lockHostSession(tx: Tx, sessionId: string): Promise<SessionRow | null> {
  const rows = await tx
    .select()
    .from(schema.sessions)
    .where(eq(schema.sessions.id, sessionId))
    .for("update")
    .limit(1);
  return rows[0] ?? null;
}

async function lockSenderActive(tx: Tx, actorUserId: string): Promise<boolean> {
  const users = await tx
    .select({ uid: schema.users.uid, bannedAt: schema.users.bannedAt })
    .from(schema.users)
    .where(eq(schema.users.uid, actorUserId))
    .for("update")
    .limit(1);
  if (users[0] === undefined) return false;
  const deleting = await tx.execute(sql`
    SELECT 1 AS present FROM account_deletions
    WHERE uid = ${actorUserId} AND state IN ('pending','fenced','deleting','deleted')
    LIMIT 1`) as unknown as Array<{ present: number }>;
  return users[0].bannedAt === null && deleting.length === 0;
}

async function lockRoom(tx: Tx, roomId: string): Promise<CollabRoomRow | null> {
  const rows = await tx
    .select()
    .from(schema.collabRooms)
    .where(eq(schema.collabRooms.id, roomId))
    .for("update")
    .limit(1);
  return rows[0] ?? null;
}

async function lockMember(tx: Tx, roomId: string, actorUserId: string): Promise<CollabMemberRow | null> {
  const rows = await tx
    .select()
    .from(schema.collabMembers)
    .where(and(eq(schema.collabMembers.roomId, roomId), eq(schema.collabMembers.userId, actorUserId)))
    .for("update")
    .limit(1);
  return rows[0] ?? null;
}

async function latestLeaseGeneration(tx: Tx, roomId: string): Promise<number> {
  const rows = await tx.execute(sql`
    SELECT COALESCE(MAX(generation), 0) AS generation
    FROM collab_sender_leases WHERE room_id = ${roomId}`) as unknown as Array<{ generation: number | string }>;
  const generation = Number(rows[0]?.generation ?? 0);
  if (!Number.isSafeInteger(generation) || generation < 1) {
    throw new CollabRunFenceError("invalid_record");
  }
  return generation;
}

async function loadRows(
  tx: Tx,
  outboxId: string,
  forUpdate: boolean,
): Promise<CollabClaimRows | null> {
  const query = tx
    .select({
      message: schema.messages,
      run: schema.runs,
      turn: schema.collabTurns,
      lease: schema.collabSenderLeases,
      outbox: schema.runOutbox,
    })
    .from(schema.runOutbox)
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

/** Equality-check the queue snapshot against the durable accepted snapshot. */
function assertSnapshotMatches(execution: CollabRunExecution, rows: CollabClaimRows): void {
  const { job, publication } = execution;
  const { message, run, turn, lease, outbox } = rows;
  const request = outbox.requestPayload;
  const body = outbox.bodyPayload;
  if (
    !isRecord(request) ||
    !isRecord(body) ||
    !isRecord(body.modelContext) ||
    !isRecord(body.collab) ||
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
    (request.model === undefined && body.requestedModel !== null && body.requestedModel !== undefined)
  ) throw new CollabRunFenceError("invalid_record");
}

function requireAuthority(input: {
  execution: CollabRunExecution;
  rows: CollabClaimRows;
  host: SessionRow | null;
  senderActive: boolean;
  room: CollabRoomRow | null;
  member: CollabMemberRow | null;
  latestLeaseGeneration: number;
  now: Date;
  staleAfterMs: number;
}): void {
  const { execution, rows, host, room, member, now } = input;
  const { job, publication } = execution;
  const { lease } = rows;
  if (!input.senderActive) throw new CollabRunFenceError("admission_denied");
  if (
    host === null ||
    host.id !== job.sessionId ||
    host.userId !== job.ownerUserId ||
    host.deletedAt !== null ||
    room === null ||
    room.id !== job.collab.roomId ||
    room.sessionId !== job.sessionId ||
    room.ownerUserId !== job.ownerUserId ||
    member === null ||
    member.roomId !== room.id ||
    member.userId !== job.actorUserId ||
    member.participantId !== job.collab.participantId ||
    member.status !== "active"
  ) throw new CollabRunFenceError("not_member");
  if (room.lifecycle !== "active") throw new CollabRunFenceError("session_closed");
  const heartbeat = lease.heartbeatAt.getTime();
  const timestamp = now.getTime();
  if (
    !Number.isFinite(timestamp) ||
    !Number.isFinite(heartbeat) ||
    !Number.isFinite(input.staleAfterMs) ||
    input.staleAfterMs < 0 ||
    rows.outbox.status !== publication.outboxStatus ||
    rows.outbox.attempts < publication.outboxAttempts ||
    rows.run.status !== publication.runStatus ||
    rows.turn.status !== publication.turnStatus ||
    rows.run.cancelRequested ||
    rows.turn.cancelRequestedAt !== null ||
    lease.releasedAt !== null ||
    lease.cancelRequestedAt !== null ||
    lease.generation !== publication.leaseGeneration ||
    room.generation !== lease.roomGeneration ||
    member.generation !== lease.membershipGeneration ||
    member.generation !== job.collab.membershipGeneration ||
    input.latestLeaseGeneration !== lease.generation ||
    timestamp < heartbeat ||
    timestamp - heartbeat > input.staleAfterMs
  ) throw new CollabRunFenceError("stale_authorization");
  const expectedToken = collabAuthorityToken({
    roomId: room.id,
    sessionId: host.id,
    ownerUserId: job.ownerUserId,
    actorUserId: job.actorUserId,
    participantId: member.participantId,
    roomGeneration: room.generation,
    membershipGeneration: member.generation,
    leaseId: lease.id,
    leaseGeneration: lease.generation,
    rootRunId: job.collab.rootRunId,
    turnId: rows.turn.id,
  });
  if (expectedToken !== publication.authorityToken) {
    throw new CollabRunFenceError("stale_authorization");
  }
}

/**
 * Claim exactly once at execution time. A stale queue delivery can never pass
 * the current authority/snapshot checks; conditional run/turn updates decide
 * the single winner even when two workers pass the prechecks together.
 */
export async function claimCollabRun(
  db: Db,
  value: AgentRunJob,
  options: { now?: () => Date; staleAfterMs?: number } = {},
): Promise<CollabClaimResult> {
  const execution = collabRunExecution(value);
  const now = options.now ?? (() => new Date());
  const staleAfterMs = options.staleAfterMs ?? 45_000;
  try {
    return await db.transaction<CollabClaimResult>(async (tx) => {
      const hint = await loadRows(tx as Tx, execution.collab.outboxId, false);
      if (hint === null) throw new CollabRunFenceError("invalid_record");
      await lockSenderKey(tx as Tx, hint.outbox.actorUserId, hint.outbox.idempotencyKey);
      const host = await lockHostSession(tx as Tx, execution.job.sessionId);
      const senderActive = await lockSenderActive(tx as Tx, execution.actorUserId);
      const room = await lockRoom(tx as Tx, execution.collab.roomId);
      const member = await lockMember(tx as Tx, execution.collab.roomId, execution.actorUserId);
      const rows = await loadRows(tx as Tx, execution.collab.outboxId, true);
      if (rows === null) throw new CollabRunFenceError("invalid_record");
      assertSnapshotMatches(execution, rows);
      const timestamp = validDate(now());
      requireAuthority({
        execution,
        rows,
        host,
        senderActive,
        room,
        member,
        latestLeaseGeneration: await latestLeaseGeneration(tx as Tx, execution.collab.roomId),
        now: timestamp,
        staleAfterMs,
      });

      const claimedRuns = await tx
        .update(schema.runs)
        .set({ status: "running", startedAt: timestamp, lastActiveAt: timestamp })
        .where(and(
          eq(schema.runs.id, execution.job.runId),
          eq(schema.runs.status, "queued"),
          eq(schema.runs.cancelRequested, false),
        ))
        .returning({ id: schema.runs.id });
      if (claimedRuns.length !== 1) throw new CollabRunFenceError("stale_authorization");
      const claimedTurns = await tx
        .update(schema.collabTurns)
        .set({ status: "running", updatedAt: timestamp })
        .where(and(
          eq(schema.collabTurns.runId, execution.job.runId),
          eq(schema.collabTurns.status, "queued"),
          isNull(schema.collabTurns.cancelRequestedAt),
        ))
        .returning({ id: schema.collabTurns.id });
      if (claimedTurns.length !== 1) throw new CollabRunFenceError("stale_authorization");
      const heartbeat = await tx
        .update(schema.collabSenderLeases)
        .set({ heartbeatAt: timestamp })
        .where(and(
          eq(schema.collabSenderLeases.id, execution.collab.leaseId),
          eq(schema.collabSenderLeases.generation, execution.publication.leaseGeneration),
          eq(schema.collabSenderLeases.runId, execution.job.runId),
          isNull(schema.collabSenderLeases.releasedAt),
          isNull(schema.collabSenderLeases.cancelRequestedAt),
        ))
        .returning({ id: schema.collabSenderLeases.id });
      if (heartbeat.length !== 1) throw new CollabRunFenceError("stale_authorization");
      return { kind: "claimed", execution };
    });
  } catch (error) {
    if (error instanceof CollabRunFenceError && error.code !== "invalid_job") {
      return { kind: "fenced", code: error.code };
    }
    throw error;
  }
}
