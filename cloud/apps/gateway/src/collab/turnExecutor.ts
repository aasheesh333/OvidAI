import { and, asc, eq, inArray, isNull, lt, sql } from "drizzle-orm";
import {
  createRunOutboxStore,
  newId,
  RunOutboxError,
  RunQuotaService,
  schema,
  type CollabAuthorization,
  type CollabMemberRow,
  type CollabRoomRow,
  type CollabSenderLeaseRow,
  type Db,
  type RunAdmissionTransaction,
  type RunOutboxStore,
  type SessionRow,
} from "@ovid/db";
import {
  AGENT_RUN_JOB_NAME,
  type AgentRunCollabPublication,
} from "@ovid/queue";
import {
  COLLAB_LEASE_STALE_AFTER_MS,
  CollabTurnError,
  acceptedCollabExecutionSnapshot,
  assertCollabTurnRecord,
  collabPublicationExpectationMatches,
  collabRunAdmissionInput,
  collabTurnJob,
  collabTurnJobsEqual,
  collabTurnReplay,
  collabTurnResult,
  normalizeCollabTurnRequest,
  planCollabPublication,
  resolveCollabModel,
  storedCollabBodyPayload,
  type CollabAgentRunJob,
  type CollabCurrentAuthority,
  type CollabModelCatalog,
  type CollabPublicationDecision,
  type CollabPublicationExpectation,
  type CollabTurnRecord,
  type CollabTurnRequest,
  type CollabTurnResult,
} from "./turnPlan.js";

/**
 * Narrow canonical-table executor for Task 4 admission/recovery primitives.
 * It is deliberately not route-composed. RunOutboxStore's current admit method
 * cannot accept membership's opaque participant IDs or join an outer turn/lease
 * transaction with caller-visible IDs, so this executor performs the same
 * canonical writes directly with the exact request/body/stored-payload shapes.
 * No casts are used to pass a richer body through that strict API.
 */

type Tx = RunAdmissionTransaction;

export type CollabQueueJobState =
  | "waiting"
  | "active"
  | "delayed"
  | "waiting-children"
  | "prioritized"
  | "completed"
  | "failed"
  | "unknown";

export interface CollabQueueJob {
  getState(): Promise<CollabQueueJobState>;
  updateData(data: CollabAgentRunJob): Promise<unknown>;
  /** Atomic expected-state retry; only completed/failed jobs may be retried. */
  retry(state: "completed" | "failed"): Promise<unknown>;
}

export interface CollabTurnQueue {
  add(
    name: "agent-run",
    data: CollabAgentRunJob,
    options: { jobId: string; priority: 1 | 2 },
  ): Promise<CollabQueueJob>;
  /** Actual BullMQ lookup used to distinguish live delivery from retained no-ops. */
  getJob(jobId: string): Promise<CollabQueueJob | undefined>;
}

export interface CollabTurnQuota {
  forTransaction(db: Db): Pick<RunQuotaService, "admitRun">;
}

export interface CollabTurnExecutorDeps {
  db: Db;
  queue: CollabTurnQueue;
  now?: () => Date;
  staleAfterMs?: number;
  /** Production uses the canonical service; tests may supply the same interface. */
  quota?: CollabTurnQuota;
  /** Settlement-only seam; admission/reconciliation never nests another transaction. */
  outbox?: Pick<RunOutboxStore, "markSettled">;
  /** Deterministic race harness: runs after decision commit and before pre-add CAS. */
  afterDecision?: (decision: CollabPublicationDecision) => Promise<void>;
}

export interface CollabTurnAdmissionInput {
  actorUserId: string;
  /** Preflight membership authority; every field is re-read after locking. */
  authorization: CollabAuthorization;
  request: CollabTurnRequest;
  /** Known/unknown catalog evidence, evaluated with post-lock sender facts. */
  catalog: CollabModelCatalog;
}

export type CollabTurnAdmission =
  | { kind: "admitted"; result: CollabTurnResult; outboxId: string }
  | { kind: "replay"; result: CollabTurnResult; outboxId: string };

export type CollabTurnPublicationResult =
  | { kind: "published"; outboxId: string }
  | { kind: "publish_unknown"; outboxId: string; error: "queue_outcome_unknown" }
  | { kind: "reconciled"; outboxId: string }
  | { kind: "settled"; outboxId: string }
  | { kind: "noop"; reason: "published" | "settled" }
  | {
      kind: "fenced";
      code: "not_member" | "session_closed" | "stale_authorization" | "admission_denied" | "terminal_outbox_unreconciled";
    };

export interface CollabHeartbeatInput {
  leaseId: string;
  generation: number;
  holderId: string;
  runId: string;
}

interface SenderAccountFacts {
  tier: string;
  preferences: Record<string, unknown>;
  active: boolean;
}

function validDate(value: Date): Date {
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) {
    throw new CollabTurnError("invalid_request");
  }
  return new Date(value.getTime());
}

async function lockSenderKey(tx: Tx, actorUserId: string, key: string): Promise<void> {
  // Exact scope/lock function used by RunOutboxStore.admit.
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

function assertHost(session: SessionRow | null, sessionId: string, ownerUserId: string): SessionRow {
  if (
    session === null ||
    session.id !== sessionId ||
    session.userId !== ownerUserId ||
    session.deletedAt !== null
  ) throw new CollabTurnError("not_member");
  return session;
}

async function lockSenderAccount(tx: Tx, actorUserId: string): Promise<SenderAccountFacts | null> {
  const rows = await tx
    .select({
      uid: schema.users.uid,
      tier: schema.users.tier,
      preferences: schema.users.preferences,
      bannedAt: schema.users.bannedAt,
    })
    .from(schema.users)
    .where(eq(schema.users.uid, actorUserId))
    .for("update")
    .limit(1);
  const row = rows[0];
  if (row === undefined) return null;
  const deleting = await tx.execute(sql`
    SELECT 1 AS present FROM account_deletions
    WHERE uid = ${actorUserId} AND state IN ('pending','fenced','deleting','deleted')
    LIMIT 1`) as unknown as Array<{ present: number }>;
  return {
    tier: row.tier,
    preferences: row.preferences,
    active: row.bannedAt === null && deleting.length === 0,
  };
}

async function lockWorkspaceTier(tx: Tx, ownerUserId: string): Promise<string | null> {
  const rows = await tx
    .select({ tier: schema.users.tier })
    .from(schema.users)
    .where(eq(schema.users.uid, ownerUserId))
    .for("update")
    .limit(1);
  return rows[0]?.tier ?? null;
}

async function lockAdmissionAccounts(
  tx: Tx,
  actorUserId: string,
  ownerUserId: string,
): Promise<{ sender: SenderAccountFacts | null; hostWorkspaceTier: string | null }> {
  let sender: SenderAccountFacts | null = null;
  let hostWorkspaceTier: string | null = null;
  // Same sorted-account lock discipline as RunQuotaService.lockUsers, avoiding
  // opposite host/sender lock order across rooms owned by two participants.
  for (const uid of [...new Set([actorUserId, ownerUserId])].sort()) {
    if (uid === actorUserId) {
      sender = await lockSenderAccount(tx, uid);
    } else {
      // Host workspace quota needs tier only; never read host BYOK/model settings.
      hostWorkspaceTier = await lockWorkspaceTier(tx, uid);
    }
  }
  if (actorUserId === ownerUserId) hostWorkspaceTier = sender?.tier ?? null;
  return { sender, hostWorkspaceTier };
}

function selectedByok(preferences: Record<string, unknown>): { keyId: string; model: string } | null {
  const raw = preferences.byokDefault;
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const value = raw as Record<string, unknown>;
  return typeof value.keyId === "string" && value.keyId !== "" &&
    typeof value.model === "string" && value.model !== ""
    ? { keyId: value.keyId, model: value.model }
    : null;
}

async function senderEligibility(tx: Tx, actorUserId: string, account: SenderAccountFacts) {
  const selected = selectedByok(account.preferences);
  if (selected === null) return { tier: account.tier, byokDefault: null };
  const keys = await tx
    .select({ id: schema.byokKeys.id, status: schema.byokKeys.status })
    .from(schema.byokKeys)
    .where(and(eq(schema.byokKeys.id, selected.keyId), eq(schema.byokKeys.userId, actorUserId)))
    .for("update")
    .limit(1);
  return {
    tier: account.tier,
    byokDefault: {
      ...selected,
      available: keys[0]?.status === "active",
    },
  };
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

function assertMembership(input: {
  authorization: CollabAuthorization;
  actorUserId: string;
  room: CollabRoomRow | null;
  member: CollabMemberRow | null;
}): { room: CollabRoomRow; member: CollabMemberRow } {
  const { authorization: expected, room, member } = input;
  if (
    room === null || member === null ||
    room.id !== expected.roomId ||
    room.sessionId !== expected.sessionId ||
    room.ownerUserId !== expected.ownerUserId ||
    member.roomId !== expected.roomId ||
    member.userId !== input.actorUserId ||
    member.participantId !== expected.participantId ||
    member.role !== expected.role ||
    member.status !== "active"
  ) throw new CollabTurnError("not_member");
  if (room.lifecycle !== "active") throw new CollabTurnError("session_closed");
  if (
    room.generation !== expected.roomGeneration ||
    member.generation !== expected.membershipGeneration
  ) throw new CollabTurnError("stale_authorization");
  return { room, member };
}

async function latestLeaseGeneration(tx: Tx, roomId: string): Promise<number> {
  const rows = await tx.execute(sql`
    SELECT COALESCE(MAX(generation), 0) AS generation
    FROM collab_sender_leases WHERE room_id = ${roomId}`) as unknown as Array<{ generation: number | string }>;
  const generation = Number(rows[0]?.generation ?? 0);
  if (!Number.isSafeInteger(generation) || generation < 0) {
    throw new CollabTurnError("invalid_record");
  }
  return generation;
}

async function loadRecord(
  tx: Tx,
  outboxId: string,
  forUpdate: boolean,
): Promise<CollabTurnRecord | null> {
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
  const rows = forUpdate
    ? await query.for("update").limit(1)
    : await query.limit(1);
  const row = rows[0];
  if (row === undefined) return null;
  const record = { message: row.message, run: row.run, turn: row.turn, lease: row.lease, outbox: row.outbox };
  assertCollabTurnRecord(record);
  return record;
}

async function existingRecord(
  tx: Tx,
  input: CollabTurnAdmissionInput,
): Promise<CollabTurnRecord | null> {
  const senderRows = await tx
    .select({ outboxId: schema.runOutbox.outboxId, runId: schema.runOutbox.runId })
    .from(schema.runOutbox)
    .where(and(
      eq(schema.runOutbox.actorUserId, input.actorUserId),
      eq(schema.runOutbox.idempotencyKey, input.request.idempotencyKey),
    ))
    .for("update")
    .limit(1);
  const roomRows = await tx
    .select({ runId: schema.collabTurns.runId })
    .from(schema.collabTurns)
    .where(and(
      eq(schema.collabTurns.roomId, input.authorization.roomId),
      eq(schema.collabTurns.idempotencyKey, input.request.idempotencyKey),
    ))
    .for("update")
    .limit(1);
  const sender = senderRows[0];
  const room = roomRows[0];
  if (sender === undefined && room === undefined) return null;
  if (sender !== undefined && room !== undefined && sender.runId !== room.runId) {
    throw new CollabTurnError("request_already_used");
  }
  if (sender !== undefined) {
    const record = await loadRecord(tx, sender.outboxId, true);
    if (record === null) throw new CollabTurnError("request_already_used");
    return record;
  }
  const outboxRows = await tx
    .select({ outboxId: schema.runOutbox.outboxId })
    .from(schema.runOutbox)
    .where(eq(schema.runOutbox.runId, room!.runId))
    .for("update")
    .limit(1);
  if (outboxRows[0] === undefined) throw new CollabTurnError("request_already_used");
  const record = await loadRecord(tx, outboxRows[0].outboxId, true);
  if (record === null) throw new CollabTurnError("request_already_used");
  return record;
}

async function assertAttachments(
  tx: Tx,
  sessionId: string,
  attachmentIds: readonly string[],
): Promise<void> {
  if (attachmentIds.length === 0) return;
  const ids = [...new Set(attachmentIds)];
  const rows = await tx
    .select({ id: schema.attachments.id })
    .from(schema.attachments)
    .where(and(eq(schema.attachments.sessionId, sessionId), inArray(schema.attachments.id, ids)))
    .for("update");
  if (rows.length !== ids.length) throw new CollabTurnError("invalid_request");
}

function requiredTransition<T>(value: T | null): T {
  if (value === null) throw new CollabTurnError("temporarily_unavailable");
  return value;
}

function isUniqueViolation(error: unknown): boolean {
  let current = error;
  for (let depth = 0; current instanceof Error && depth < 5; depth += 1) {
    if ((current as { code?: unknown }).code === "23505") return true;
    current = (current as { cause?: unknown }).cause;
  }
  return false;
}

export function createCollabTurnExecutor(deps: CollabTurnExecutorDeps) {
  const db = deps.db;
  const clock = deps.now ?? (() => new Date());
  const staleAfterMs = deps.staleAfterMs ?? COLLAB_LEASE_STALE_AFTER_MS;
  if (!Number.isFinite(staleAfterMs) || staleAfterMs < 0) {
    throw new CollabTurnError("invalid_request");
  }
  const quota = deps.quota ?? new RunQuotaService(db, { now: () => validDate(clock()) });
  const publication = deps.outbox ?? createRunOutboxStore(db, {
    // This store is used only for its existing publication transitions. The
    // canonical collab admission below never invokes this independent callback.
    authorize: async () => {
      throw new RunOutboxError("authorization_required");
    },
  });

  function now(): Date {
    return validDate(clock());
  }

  async function admitTransaction(
    tx: Tx,
    input: CollabTurnAdmissionInput,
    request: CollabTurnRequest,
  ): Promise<CollabTurnAdmission> {
    await lockSenderKey(tx, input.actorUserId, request.idempotencyKey);
    assertHost(
      await lockHostSession(tx, input.authorization.sessionId),
      input.authorization.sessionId,
      input.authorization.ownerUserId,
    );
    const accounts = await lockAdmissionAccounts(
      tx,
      input.actorUserId,
      input.authorization.ownerUserId,
    );
    const account = accounts.sender;
    if (account === null || accounts.hostWorkspaceTier === null) {
      throw new CollabTurnError("not_member");
    }
    if (!account.active) throw new CollabTurnError("admission_denied");
    const { room, member } = assertMembership({
      authorization: input.authorization,
      actorUserId: input.actorUserId,
      room: await lockRoom(tx, input.authorization.roomId),
      member: await lockMember(tx, input.authorization.roomId, input.actorUserId),
    });

    // Both unique scopes are read before any insert. Same-key replay never
    // depends on model/BYOK/quota/current-lease prechecks or fresh IDs.
    const existing = await existingRecord(tx, { ...input, request });
    if (existing !== null) {
      return {
        kind: "replay",
        result: collabTurnReplay({
          record: existing,
          request,
          actorUserId: input.actorUserId,
          authorization: input.authorization,
        }),
        outboxId: existing.outbox.outboxId,
      };
    }

    // Paid/model/BYOK authority is a post-lock decision, not input preflight.
    const eligibility = await senderEligibility(tx, input.actorUserId, account);
    const model = resolveCollabModel({ request, catalog: input.catalog, sender: eligibility });
    if (!model.ok) throw new CollabTurnError(model.code);

    const timestamp = now();
    const activeLeases = await tx
      .select()
      .from(schema.collabSenderLeases)
      .where(and(eq(schema.collabSenderLeases.roomId, room.id), isNull(schema.collabSenderLeases.releasedAt)))
      .for("update")
      .limit(1);
    const active = activeLeases[0];
    const latest = await latestLeaseGeneration(tx, room.id);
    if (active !== undefined) {
      const age = timestamp.getTime() - active.heartbeatAt.getTime();
      if (
        active.cancelRequestedAt !== null ||
        active.roomGeneration !== room.generation ||
        active.membershipGeneration !== member.generation ||
        latest !== active.generation ||
        age < 0 || age > staleAfterMs
      ) throw new CollabTurnError("stale_authorization");
      throw new CollabTurnError("sender_busy");
    }

    const attachmentIds = request.attachmentIds ?? [];
    await assertAttachments(tx, room.sessionId, attachmentIds);

    // Canonical IDs come from the same UUIDv7 generator inside this one outer
    // transaction. No independent RunOutboxStore commit can precede turn/lease.
    const userMessageId = newId();
    const runId = newId();
    const outboxId = newId();
    const turnId = newId();
    const leaseId = newId();
    const leaseGeneration = latest + 1;
    if (!Number.isSafeInteger(leaseGeneration)) throw new CollabTurnError("invalid_record");
    const lease: CollabSenderLeaseRow = {
      id: leaseId,
      roomId: room.id,
      holderParticipantId: member.participantId,
      holderUserId: input.actorUserId,
      runId,
      generation: leaseGeneration,
      roomGeneration: room.generation,
      membershipGeneration: member.generation,
      startedAt: timestamp,
      heartbeatAt: timestamp,
      releasedAt: null,
      cancelRequestedAt: null,
    };
    const admissionInput = collabRunAdmissionInput({
      actorUserId: input.actorUserId,
      authorization: input.authorization,
      request,
      lease,
    });
    const execution = acceptedCollabExecutionSnapshot({
      actorUserId: input.actorUserId,
      resolution: model,
      sender: eligibility,
      hostWorkspaceTier: accounts.hostWorkspaceTier,
    });
    const bodyPayload = storedCollabBodyPayload(admissionInput, outboxId, runId, execution);

    const [message] = await tx.insert(schema.messages).values({
      id: userMessageId,
      sessionId: room.sessionId,
      role: "user",
      content: request.text,
      createdAt: timestamp,
    }).returning();
    if (attachmentIds.length > 0) {
      await tx.update(schema.attachments)
        .set({ messageId: userMessageId })
        .where(and(
          eq(schema.attachments.sessionId, room.sessionId),
          inArray(schema.attachments.id, [...new Set(attachmentIds)]),
        ));
    }
    const [run] = await tx.insert(schema.runs).values({
      id: runId,
      sessionId: room.sessionId,
      status: "queued",
      promptMessageId: userMessageId,
      createdAt: timestamp,
    }).returning();
    const [turn] = await tx.insert(schema.collabTurns).values({
      id: turnId,
      roomId: room.id,
      participantId: member.participantId,
      actorUserId: input.actorUserId,
      runId,
      userMessageId,
      idempotencyKey: request.idempotencyKey,
      model: model.requestedModel,
      status: "queued",
      createdAt: timestamp,
      updatedAt: timestamp,
    }).returning();
    const [insertedLease] = await tx.insert(schema.collabSenderLeases).values(lease).returning();

    // forTransaction receives the outer Tx (Drizzle nested transaction is a
    // savepoint). Exhaustion throws below and rolls back every canonical write.
    const admitted = await quota.forTransaction(tx as unknown as Db).admitRun({
      actorUserId: input.actorUserId,
      source: "collab",
      runId,
      idempotencyKey: `run:${runId}:collab`,
      billingClass: model.billingClass,
    });
    if (!admitted.ok) throw new CollabTurnError("quota_exceeded");

    const [outbox] = await tx.insert(schema.runOutbox).values({
      outboxId,
      actorUserId: input.actorUserId,
      sessionId: room.sessionId,
      runId,
      userMessageId,
      idempotencyKey: request.idempotencyKey,
      status: "queued",
      requestPayload: admissionInput.requestPayload,
      bodyPayload,
      jobId: runId,
      attempts: 0,
      createdAt: timestamp,
      updatedAt: timestamp,
    }).returning();
    const record: CollabTurnRecord = {
      message: message!,
      run: run!,
      turn: turn!,
      lease: insertedLease!,
      outbox: outbox!,
    };
    return { kind: "admitted", result: collabTurnResult(record), outboxId };
  }

  async function admit(input: CollabTurnAdmissionInput): Promise<CollabTurnAdmission> {
    const request = normalizeCollabTurnRequest(input.request);
    // A non-cooperating writer can still hit a unique backstop. PostgreSQL has
    // aborted that transaction, so only a fresh transaction may re-read/replan.
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        return await db.transaction((tx) => admitTransaction(tx as Tx, input, request));
      } catch (error) {
        if (!isUniqueViolation(error) || attempt === 1) throw error;
      }
    }
    throw new CollabTurnError("temporarily_unavailable");
  }

  async function publicationDecision(outboxId: string): Promise<CollabPublicationDecision> {
    return db.transaction<CollabPublicationDecision>(async (tx) => {
      // Unlocked data is only a lock-order hint. Every authoritative row is
      // re-read FOR UPDATE after sender/host/room locks in admission order.
      const hint = await loadRecord(tx as Tx, outboxId, false);
      if (hint === null) throw new CollabTurnError("not_found");
      await lockSenderKey(tx as Tx, hint.outbox.actorUserId, hint.outbox.idempotencyKey);
      const host = await lockHostSession(tx as Tx, hint.message.sessionId);
      const account = await lockSenderAccount(tx as Tx, hint.outbox.actorUserId);
      const room = await lockRoom(tx as Tx, hint.turn.roomId);
      const member = await lockMember(tx as Tx, hint.turn.roomId, hint.outbox.actorUserId);
      const record = await loadRecord(tx as Tx, outboxId, true);
      if (record === null) throw new CollabTurnError("not_found");
      if (host === null || room === null || member === null) {
        return { kind: "fenced", code: "not_member" };
      }
      const current: CollabCurrentAuthority = {
        room,
        member,
        hostSession: host,
        latestLeaseGeneration: await latestLeaseGeneration(tx as Tx, room.id),
        senderActive: account?.active ?? false,
        now: now(),
        staleAfterMs,
      };
      return planCollabPublication({ record, current });
    });
  }

  function publicToken(expectation: CollabPublicationExpectation): AgentRunCollabPublication {
    return {
      outboxStatus: expectation.outboxStatus,
      outboxAttempts: expectation.outboxAttempts,
      runStatus: expectation.runStatus,
      turnStatus: expectation.turnStatus,
      leaseGeneration: expectation.leaseGeneration,
      authorityToken: expectation.authorityToken,
    };
  }

  async function reservePublication(
    decision: Extract<CollabPublicationDecision, { kind: "publish" }>,
  ): Promise<boolean> {
    const expectation = decision.expectation;
    try {
      return await db.transaction(async (tx) => {
        const hint = await loadRecord(tx as Tx, decision.outboxId, false);
        if (hint === null) throw new CollabTurnError("not_found");
        await lockSenderKey(tx as Tx, hint.outbox.actorUserId, hint.outbox.idempotencyKey);
        const host = await lockHostSession(tx as Tx, hint.message.sessionId);
        const account = await lockSenderAccount(tx as Tx, hint.outbox.actorUserId);
        const room = await lockRoom(tx as Tx, hint.turn.roomId);
        const member = await lockMember(tx as Tx, hint.turn.roomId, hint.outbox.actorUserId);
        const record = await loadRecord(tx as Tx, decision.outboxId, true);
        if (record === null) throw new CollabTurnError("not_found");
        if (host === null || room === null || member === null) return false;
        const current: CollabCurrentAuthority = {
          room,
          member,
          hostSession: host,
          latestLeaseGeneration: await latestLeaseGeneration(tx as Tx, room.id),
          senderActive: account?.active ?? false,
          now: now(),
          staleAfterMs,
        };
        if (!collabPublicationExpectationMatches({ expectation, record, current })) return false;
        const expectedJob = collabTurnJob(record, publicToken(expectation));
        if (!collabTurnJobsEqual(decision.job, expectedJob)) return false;

        const timestamp = now();
        const heartbeat = await tx
          .update(schema.collabSenderLeases)
          .set({ heartbeatAt: timestamp })
          .where(and(
            eq(schema.collabSenderLeases.id, record.lease.id),
            eq(schema.collabSenderLeases.generation, expectation.leaseGeneration),
            eq(schema.collabSenderLeases.runId, record.run.id),
            isNull(schema.collabSenderLeases.releasedAt),
            isNull(schema.collabSenderLeases.cancelRequestedAt),
          ))
          .returning({ id: schema.collabSenderLeases.id });
        if (heartbeat.length !== 1) throw new CollabTurnError("stale_authorization");

        const updated = await tx
          .update(schema.runOutbox)
          .set({
            // Published is a recoverable publication intent until confirmation;
            // jobId dedupe plus the worker fence resolves every crash window.
            status: "published",
            attempts: expectation.outboxAttempts,
            publishedAt: null,
            lastAttemptAt: timestamp,
            lastError: null,
            updatedAt: timestamp,
          })
          .where(and(
            eq(schema.runOutbox.outboxId, decision.outboxId),
            eq(schema.runOutbox.status, expectation.fromStatus),
            eq(schema.runOutbox.attempts, expectation.fromAttempts),
            expectation.fromPublishedAt === null
              ? isNull(schema.runOutbox.publishedAt)
              : eq(schema.runOutbox.publishedAt, new Date(expectation.fromPublishedAt)),
            eq(schema.runOutbox.runId, record.run.id),
            eq(schema.runOutbox.jobId, record.run.id),
          ))
          .returning({ outboxId: schema.runOutbox.outboxId });
        if (updated.length !== 1) throw new CollabTurnError("stale_authorization");
        return true;
      });
    } catch (error) {
      if (error instanceof CollabTurnError && error.code === "stale_authorization") return false;
      throw error;
    }
  }

  async function recordPublicationUnknown(
    decision: Extract<CollabPublicationDecision, { kind: "publish" }>,
  ): Promise<void> {
    const token = decision.job.collabPublication;
    if (token === undefined) throw new CollabTurnError("invalid_record");
    const timestamp = now();
    // A thrown add is UNKNOWN, not failed. Keep status=published and
    // publishedAt=null so an actually delivered worker can still claim.
    await db
      .update(schema.runOutbox)
      .set({
        lastAttemptAt: timestamp,
        lastError: "queue_outcome_unknown",
        updatedAt: timestamp,
      })
      .where(and(
        eq(schema.runOutbox.outboxId, decision.outboxId),
        eq(schema.runOutbox.status, "published"),
        eq(schema.runOutbox.attempts, token.outboxAttempts),
        eq(schema.runOutbox.runId, decision.job.runId),
        eq(schema.runOutbox.jobId, decision.job.runId),
        isNull(schema.runOutbox.publishedAt),
      ));
  }

  function unknownPublication(outboxId: string): CollabTurnPublicationResult {
    return { kind: "publish_unknown", outboxId, error: "queue_outcome_unknown" };
  }

  async function confirmPublication(
    decision: Extract<CollabPublicationDecision, { kind: "publish" }>,
  ): Promise<void> {
    const token = decision.job.collabPublication;
    if (token === undefined) throw new CollabTurnError("invalid_record");
    const timestamp = now();
    const confirmed = await db
      .update(schema.runOutbox)
      .set({
        status: "published",
        attempts: token.outboxAttempts,
        publishedAt: timestamp,
        lastAttemptAt: timestamp,
        lastError: null,
        updatedAt: timestamp,
      })
      .where(and(
        eq(schema.runOutbox.outboxId, decision.outboxId),
        inArray(schema.runOutbox.status, ["published", "failed"]),
        eq(schema.runOutbox.attempts, token.outboxAttempts),
        eq(schema.runOutbox.runId, decision.job.runId),
        eq(schema.runOutbox.jobId, decision.job.runId),
        isNull(schema.runOutbox.publishedAt),
      ))
      .returning({ outboxId: schema.runOutbox.outboxId });
    if (confirmed.length === 1) return;
    const current = await db
      .select({
        status: schema.runOutbox.status,
        attempts: schema.runOutbox.attempts,
        publishedAt: schema.runOutbox.publishedAt,
      })
      .from(schema.runOutbox)
      .where(eq(schema.runOutbox.outboxId, decision.outboxId))
      .limit(1);
    const row = current[0];
    if (
      row === undefined ||
      row.status !== "published" ||
      row.attempts !== token.outboxAttempts ||
      row.publishedAt === null
    ) throw new CollabTurnError("temporarily_unavailable");
  }

  const LIVE_QUEUE_STATES = new Set<CollabQueueJobState>([
    "waiting",
    "active",
    "delayed",
    "waiting-children",
    "prioritized",
  ]);

  async function runAndTurnQueued(runId: string): Promise<boolean> {
    const rows = await db
      .select({ runStatus: schema.runs.status, turnStatus: schema.collabTurns.status })
      .from(schema.runs)
      .innerJoin(schema.collabTurns, eq(schema.collabTurns.runId, schema.runs.id))
      .where(eq(schema.runs.id, runId))
      .limit(1);
    return rows[0]?.runStatus === "queued" && rows[0].turnStatus === "queued";
  }

  async function hasExecutionEvidence(runId: string): Promise<boolean> {
    const rows = await db
      .select({ runStatus: schema.runs.status, turnStatus: schema.collabTurns.status })
      .from(schema.runs)
      .innerJoin(schema.collabTurns, eq(schema.collabTurns.runId, schema.runs.id))
      .where(eq(schema.runs.id, runId))
      .limit(1);
    const row = rows[0];
    if (row === undefined) return false;
    if (row.runStatus === "running" && row.turnStatus === "running") return true;
    return (row.runStatus === "completed" && row.turnStatus === "completed") ||
      (row.runStatus === "failed" && row.turnStatus === "failed") ||
      (row.runStatus === "cancelled" && ["cancelled", "interrupted"].includes(row.turnStatus));
  }

  async function discardSettledDeliveryWithoutExecution(
    decision: Extract<CollabPublicationDecision, { kind: "publish" }>,
    supplied?: CollabQueueJob,
  ): Promise<void> {
    const job = supplied ?? await deps.queue.getJob(decision.options.jobId);
    if (job === undefined) return;
    const state = await job.getState();
    if ((state === "completed" || state === "failed") && await runAndTurnQueued(decision.job.runId)) {
      // attempts:1 means this delivery has settled. A queued canonical run
      // proves no live execution. Update before atomic expected-state retry;
      // never remove a newer delivery by racing a delete/re-add.
      await job.updateData(decision.job);
      await job.retry(state);
    }
  }

  async function evidenceAfterAdd(
    decision: Extract<CollabPublicationDecision, { kind: "publish" }>,
    added: CollabQueueJob,
  ): Promise<"execution" | "queue" | "settled" | "unknown"> {
    if (await hasExecutionEvidence(decision.job.runId)) return "execution";
    const state = await added.getState();
    if (LIVE_QUEUE_STATES.has(state)) return "queue";
    if (state === "completed" || state === "failed") return "settled";
    return "unknown";
  }

  async function reopenConfirmedDeliveryForRetry(outboxId: string): Promise<"retry" | "live" | "unknown"> {
    const rows = await db
      .select({
        runId: schema.runOutbox.runId,
        jobId: schema.runOutbox.jobId,
        attempts: schema.runOutbox.attempts,
      })
      .from(schema.runOutbox)
      .where(eq(schema.runOutbox.outboxId, outboxId))
      .limit(1);
    const row = rows[0];
    if (row === undefined) throw new CollabTurnError("not_found");
    if (!(await runAndTurnQueued(row.runId))) return "live";
    const job = await deps.queue.getJob(row.jobId);
    if (job !== undefined) {
      const state = await job.getState();
      if (LIVE_QUEUE_STATES.has(state)) return "live";
      if (state !== "completed" && state !== "failed") return "unknown";
    }
    const timestamp = now();
    const reopened = await db
      .update(schema.runOutbox)
      .set({
        publishedAt: null,
        lastAttemptAt: timestamp,
        lastError: "queue_outcome_unknown",
        updatedAt: timestamp,
      })
      .where(and(
        eq(schema.runOutbox.outboxId, outboxId),
        eq(schema.runOutbox.status, "published"),
        eq(schema.runOutbox.attempts, row.attempts),
        sql`${schema.runOutbox.publishedAt} IS NOT NULL`,
        sql`EXISTS (
          SELECT 1 FROM runs r
          JOIN collab_turns t ON t.run_id = r.id
          WHERE r.id = ${row.runId}
            AND r.status = 'queued'
            AND t.status = 'queued'
        )`,
      ))
      .returning({ outboxId: schema.runOutbox.outboxId });
    return reopened.length === 1 ? "retry" : "unknown";
  }

  async function reconcilePublication(outboxId: string): Promise<void> {
    await db.transaction(async (tx) => {
      const rows = await tx
        .select()
        .from(schema.runOutbox)
        .where(eq(schema.runOutbox.outboxId, outboxId))
        .for("update")
        .limit(1);
      const row = rows[0];
      if (row === undefined) throw new CollabTurnError("not_found");
      if (row.status === "published" && row.publishedAt !== null) return;
      const timestamp = now();
      const attempts = row.status === "published" ? row.attempts : row.attempts + 1;
      const reconciled = await tx
        .update(schema.runOutbox)
        .set({
          status: "published",
          attempts,
          publishedAt: timestamp,
          lastAttemptAt: timestamp,
          lastError: null,
          updatedAt: timestamp,
        })
        .where(and(
          eq(schema.runOutbox.outboxId, outboxId),
          eq(schema.runOutbox.status, row.status),
          eq(schema.runOutbox.attempts, row.attempts),
          row.publishedAt === null
            ? isNull(schema.runOutbox.publishedAt)
            : eq(schema.runOutbox.publishedAt, row.publishedAt),
          sql`EXISTS (
            SELECT 1 FROM runs r
            JOIN collab_turns t ON t.run_id = r.id
            WHERE r.id = ${row.runId}
              AND r.status = 'running'
              AND t.status = 'running'
          )`,
        ))
        .returning({ outboxId: schema.runOutbox.outboxId });
      if (reconciled.length !== 1) throw new CollabTurnError("temporarily_unavailable");
    });
  }

  async function publish(input: { outboxId: string }): Promise<CollabTurnPublicationResult> {
    let firstDecision = true;
    // Bounded only to clear a settled no-op and retry once; every iteration
    // re-reads current authority and advances the durable publication attempt.
    for (let round = 0; round < 3; round += 1) {
      const decision = await publicationDecision(input.outboxId);
      if (decision.kind === "fenced") return decision;
      if (decision.kind === "noop") {
        if (decision.reason === "published") {
          try {
            const recovered = await reopenConfirmedDeliveryForRetry(input.outboxId);
            if (recovered === "retry") continue;
            if (recovered === "unknown") return unknownPublication(input.outboxId);
          } catch {
            return unknownPublication(input.outboxId);
          }
        }
        return decision;
      }
      if (decision.kind === "settle") {
        requiredTransition(await publication.markSettled({ outboxId: decision.outboxId }));
        return { kind: "settled", outboxId: decision.outboxId };
      }
      if (decision.kind === "mark_published") {
        await reconcilePublication(decision.outboxId);
        return { kind: "reconciled", outboxId: decision.outboxId };
      }

      if (firstDecision) {
        firstDecision = false;
        await deps.afterDecision?.(decision);
      }
      if (!(await reservePublication(decision))) {
        return { kind: "fenced", code: "stale_authorization" };
      }
      try {
        await discardSettledDeliveryWithoutExecution(decision);
      } catch {
        await recordPublicationUnknown(decision);
        return unknownPublication(decision.outboxId);
      }

      let added: CollabQueueJob;
      try {
        added = await deps.queue.add(AGENT_RUN_JOB_NAME, decision.job, decision.options);
      } catch {
        await recordPublicationUnknown(decision);
        return unknownPublication(decision.outboxId);
      }

      let evidence: "execution" | "queue" | "settled" | "unknown";
      try {
        evidence = await evidenceAfterAdd(decision, added);
      } catch {
        await recordPublicationUnknown(decision);
        return unknownPublication(decision.outboxId);
      }
      if (evidence === "execution" || evidence === "queue") {
        await confirmPublication(decision);
        return { kind: "published", outboxId: decision.outboxId };
      }
      if (evidence === "unknown") {
        await recordPublicationUnknown(decision);
        return unknownPublication(decision.outboxId);
      }
      // A settled delivery with a still-queued run is not live evidence. Loop
      // once for an expected-state retry; never set publishedAt from dedupe alone.
    }
    return unknownPublication(input.outboxId);
  }

  async function heartbeat(input: CollabHeartbeatInput): Promise<boolean> {
    const hints = await db
      .select({ roomId: schema.collabSenderLeases.roomId, runId: schema.collabSenderLeases.runId })
      .from(schema.collabSenderLeases)
      .where(eq(schema.collabSenderLeases.id, input.leaseId))
      .limit(1);
    const hint = hints[0];
    if (hint === undefined) return false;
    const runHints = await db
      .select({ sessionId: schema.runs.sessionId })
      .from(schema.runs)
      .where(eq(schema.runs.id, hint.runId))
      .limit(1);
    const runHint = runHints[0];
    if (runHint === undefined) return false;
    return db.transaction(async (tx) => {
      // Host precedes room exactly as in admission/recovery; taking these in
      // the opposite order would deadlock a heartbeat against a fresh turn.
      const host = await lockHostSession(tx as Tx, runHint.sessionId);
      const room = await lockRoom(tx as Tx, hint.roomId);
      const leases = await tx
        .select()
        .from(schema.collabSenderLeases)
        .where(eq(schema.collabSenderLeases.id, input.leaseId))
        .for("update")
        .limit(1);
      const lease = leases[0];
      if (room === null || lease === undefined) return false;
      const member = await lockMember(tx as Tx, lease.roomId, lease.holderUserId);
      const runs = await tx
        .select()
        .from(schema.runs)
        .where(eq(schema.runs.id, input.runId))
        .for("update")
        .limit(1);
      const run = runs[0];
      const turns = await tx
        .select()
        .from(schema.collabTurns)
        .where(eq(schema.collabTurns.runId, input.runId))
        .for("update")
        .limit(1);
      const turn = turns[0];
      const latest = await latestLeaseGeneration(tx as Tx, lease.roomId);
      if (
        room.lifecycle !== "active" ||
        room.generation !== lease.roomGeneration ||
        member === null ||
        member.status !== "active" ||
        member.participantId !== lease.holderParticipantId ||
        member.generation !== lease.membershipGeneration ||
        lease.generation !== input.generation ||
        lease.runId !== input.runId ||
        lease.holderParticipantId !== input.holderId ||
        lease.releasedAt !== null ||
        lease.cancelRequestedAt !== null ||
        latest !== lease.generation ||
        run === undefined ||
        (run.status !== "queued" && run.status !== "running") ||
        turn === undefined ||
        (turn.status !== "queued" && turn.status !== "running") ||
        turn.cancelRequestedAt !== null ||
        host === null ||
        host.id !== run.sessionId ||
        host.deletedAt !== null ||
        host.userId !== room.ownerUserId
      ) return false;

      const timestamp = now();
      // Never move the durable heartbeat backwards across gateway clock skew.
      if (timestamp.getTime() < lease.heartbeatAt.getTime()) return true;
      const updated = await tx
        .update(schema.collabSenderLeases)
        .set({ heartbeatAt: timestamp })
        .where(and(
          eq(schema.collabSenderLeases.id, input.leaseId),
          eq(schema.collabSenderLeases.generation, input.generation),
          eq(schema.collabSenderLeases.runId, input.runId),
          isNull(schema.collabSenderLeases.releasedAt),
          isNull(schema.collabSenderLeases.cancelRequestedAt),
        ))
        .returning({ id: schema.collabSenderLeases.id });
      return updated.length === 1;
    });
  }

  async function fenceStaleLease(leaseId: string, roomId: string, timestamp: Date): Promise<boolean> {
    return db.transaction(async (tx) => {
      await lockRoom(tx as Tx, roomId);
      const leases = await tx
        .select()
        .from(schema.collabSenderLeases)
        .where(eq(schema.collabSenderLeases.id, leaseId))
        .for("update")
        .limit(1);
      const lease = leases[0];
      if (
        lease === undefined ||
        lease.roomId !== roomId ||
        lease.releasedAt !== null ||
        timestamp.getTime() - lease.heartbeatAt.getTime() <= staleAfterMs
      ) return false;
      const latest = await latestLeaseGeneration(tx as Tx, roomId);
      if (latest !== lease.generation) return false;
      const nextGeneration = latest + 1;
      if (!Number.isSafeInteger(nextGeneration)) throw new CollabTurnError("invalid_record");
      const fenced = await tx
        .update(schema.collabSenderLeases)
        .set({
          generation: nextGeneration,
          releasedAt: timestamp,
          cancelRequestedAt: timestamp,
        })
        .where(and(
          eq(schema.collabSenderLeases.id, leaseId),
          eq(schema.collabSenderLeases.generation, lease.generation),
          isNull(schema.collabSenderLeases.releasedAt),
        ))
        .returning({ id: schema.collabSenderLeases.id });
      if (fenced.length !== 1) return false;
      await tx
        .update(schema.collabTurns)
        .set({ cancelRequestedAt: timestamp, updatedAt: timestamp })
        .where(and(
          eq(schema.collabTurns.runId, lease.runId),
          inArray(schema.collabTurns.status, ["queued", "running"]),
        ));
      await tx
        .update(schema.runs)
        .set({ cancelRequested: true })
        .where(and(eq(schema.runs.id, lease.runId), inArray(schema.runs.status, ["queued", "running"])));
      return true;
    });
  }

  async function recoverStaleLeases(): Promise<string[]> {
    const timestamp = now();
    const cutoff = new Date(timestamp.getTime() - staleAfterMs);
    const candidates = await db
      .select({ id: schema.collabSenderLeases.id, roomId: schema.collabSenderLeases.roomId })
      .from(schema.collabSenderLeases)
      .where(and(isNull(schema.collabSenderLeases.releasedAt), lt(schema.collabSenderLeases.heartbeatAt, cutoff)))
      .orderBy(asc(schema.collabSenderLeases.roomId), asc(schema.collabSenderLeases.id));
    const fenced: string[] = [];
    // Each room follows room -> lease lock order; a competing sweeper re-reads
    // and loses cleanly. Statuses stay queued/running: no timeout is invented.
    for (const candidate of candidates) {
      if (await fenceStaleLease(candidate.id, candidate.roomId, timestamp)) fenced.push(candidate.id);
    }
    return fenced;
  }

  return { admit, publish, heartbeat, recoverStaleLeases };
}
