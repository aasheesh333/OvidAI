import { manualModelsAllowed } from "@ovid/shared";
import type {
  CollabAuthorization,
  CollabMemberRow,
  CollabRoomRow,
  CollabSenderLeaseRow,
  CollabTurnRow,
  MessageRow,
  QuotaBillingClass,
  RunAdmissionInput,
  RunOutboxRecord,
  RunRow,
  SessionRow,
} from "@ovid/db";
import {
  collabAuthorityToken,
  type AgentRunCollab,
  type AgentRunCollabPublication,
  type AgentRunJob,
  type AgentRunModelContext,
} from "@ovid/queue";

/** Pure validation/derivation only. Transaction execution lives in turnExecutor.ts. */

export type CollabTurnErrorCode =
  | "invalid_request"
  | "invalid_record"
  | "not_found"
  | "not_member"
  | "session_closed"
  | "request_already_used"
  | "model_unavailable"
  | "manual_model_not_allowed"
  | "key_not_minted"
  | "sender_busy"
  | "stale_authorization"
  | "admission_denied"
  | "quota_exceeded"
  | "temporarily_unavailable"
  | "terminal_outbox_unreconciled";

export class CollabTurnError extends Error {
  constructor(readonly code: CollabTurnErrorCode) {
    super(code);
    this.name = "CollabTurnError";
  }
}

export interface CollabTurnRequest {
  schemaVersion: 1;
  idempotencyKey: string;
  text: string;
  model?: string;
  attachmentIds?: string[];
}

export type CollabTurnResultStatus =
  | "queued"
  | "completed"
  | "failed"
  | "cancelled"
  | "interrupted";

/** Task 4 result; userEventId is the existing projection's canonical source ID. */
export interface CollabTurnResult {
  schemaVersion: 1;
  turnId: string;
  runId: string;
  userMessageId: string;
  userEventId: string;
  status: CollabTurnResultStatus;
  model: string;
}

/** The canonical rows, not a second response/job/record format. */
export interface CollabTurnRecord {
  message: MessageRow;
  run: RunRow;
  turn: CollabTurnRow;
  lease: CollabSenderLeaseRow;
  outbox: RunOutboxRecord;
}

export type CollabRunLineage = AgentRunCollab;

export interface CollabAcceptedExecutionSnapshot {
  /** Secret-free accepted model/BYOK snapshot consumed by the current worker. */
  modelContext: AgentRunModelContext;
  byokKeyId: string | null;
  byokModel?: string;
  /** Host workspace tier, not the sender's plan. */
  tier: string;
  /** Sender-derived queue priority; this is not a workspace entitlement. */
  queuePriority: 1 | 2;
}

/**
 * Current worker convention: userId/ownerUserId are the host workspace owner;
 * actorUserId is the sender. Publication carries its CAS/fence token in-band.
 */
export type CollabAgentRunJob = AgentRunJob & {
  ownerUserId: string;
  actorUserId: string;
  source: "collab";
  requestedModel?: string;
  modelContext: AgentRunModelContext;
  tier: string;
  collab: CollabRunLineage;
  collabPublication?: AgentRunCollabPublication;
};

export interface CollabPublicationExpectation extends AgentRunCollabPublication {
  fromStatus: "queued" | "failed" | "published";
  fromAttempts: number;
  fromPublishedAt: string | null;
}

export interface CollabSenderEligibility {
  /** Read from the locked sender users row, never supplied by the client/host. */
  tier: string;
  /** Null means Ovid allowance; availability is checked against sender-owned BYOK. */
  byokDefault: { keyId: string; model: string; available: boolean } | null;
}

export type CollabModelCatalog =
  | { state: "known"; modelIds: readonly string[] }
  | { state: "unavailable" };

export type CollabModelResolution =
  | {
      ok: true;
      /** Effective run model; null means Auto. */
      requestedModel: string | null;
      /** Exact value required by RunOutboxStore's request/body equality rule. */
      bodyRequestedModel: string | null;
      resultModel: string;
      billingClass: QuotaBillingClass;
    }
  | {
      ok: false;
      code: "manual_model_not_allowed" | "model_unavailable" | "key_not_minted" | "temporarily_unavailable";
    };

export interface CollabCurrentAuthority {
  room: CollabRoomRow;
  member: CollabMemberRow;
  hostSession: SessionRow;
  latestLeaseGeneration: number;
  senderActive: boolean;
  now: Date;
  staleAfterMs: number;
}

export type CollabPublicationDecision =
  | {
      kind: "publish";
      outboxId: string;
      job: CollabAgentRunJob;
      options: { jobId: string; priority: 1 | 2 };
      expectation: CollabPublicationExpectation;
    }
  | { kind: "mark_published"; outboxId: string }
  | { kind: "settle"; outboxId: string }
  | { kind: "noop"; reason: "published" | "settled" }
  | {
      kind: "fenced";
      code: "not_member" | "session_closed" | "stale_authorization" | "admission_denied" | "terminal_outbox_unreconciled";
    };

export type CollabDescendantLeasePlan =
  | { kind: "inherit"; collab: CollabRunLineage; writes: readonly [] }
  | {
      kind: "refuse";
      code: "not_member" | "session_closed" | "stale_authorization" | "admission_denied";
      writes: readonly [];
    };

export const COLLAB_LEASE_STALE_AFTER_MS = 45_000;

const REQUEST_KEYS = new Set(["schemaVersion", "idempotencyKey", "text", "model", "attachmentIds"]);
const BODY_KEYS = new Set([
  "ownerUserId",
  "requestedModel",
  "userId",
  "sessionId",
  "runId",
  "collab",
  "modelContext",
  "byokKeyId",
  "byokModel",
  "tier",
  "queuePriority",
]);
const MODEL_CONTEXT_KEYS = new Set([
  "requestedModel",
  "byokKeyId",
  "byokModel",
  "temperature",
  "actorUserId",
]);
const COLLAB_KEYS = new Set([
  "roomId",
  "participantId",
  "membershipGeneration",
  "leaseId",
  "leaseGeneration",
  "outboxId",
  "rootRunId",
]);
const IDEMPOTENCY_RE = /^[A-Za-z0-9_-]{1,64}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MODEL_RE = /^[^\u0000-\u001f\u007f]+$/;
const SECRET_MODEL_RE = /(?:secret|password|api[_-]?key|byok|bearer|sk-)/i;
const EFFORT_SUFFIX = /·\s*(low|medium|high)$/i;
const AUTO_ALIASES = new Set(["auto", "ovid-cloud/auto"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function validModel(value: unknown): value is string {
  return typeof value === "string" &&
    value.length > 0 &&
    value.length <= 160 &&
    value.trim() !== "" &&
    MODEL_RE.test(value) &&
    !SECRET_MODEL_RE.test(value);
}

function canonical(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string" || typeof value === "boolean") return JSON.stringify(value) as string;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new CollabTurnError("invalid_record");
    return JSON.stringify(value) as string;
  }
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (!isRecord(value)) throw new CollabTurnError("invalid_record");
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
}

function sameRequest(a: CollabTurnRequest, b: CollabTurnRequest): boolean {
  return canonical(a) === canonical(b);
}

export function normalizeCollabTurnRequest(value: unknown): CollabTurnRequest {
  if (!isRecord(value) || Object.keys(value).some((key) => !REQUEST_KEYS.has(key))) {
    throw new CollabTurnError("invalid_request");
  }
  if (value.schemaVersion !== 1) throw new CollabTurnError("invalid_request");
  if (typeof value.idempotencyKey !== "string" || !IDEMPOTENCY_RE.test(value.idempotencyKey)) {
    throw new CollabTurnError("invalid_request");
  }
  if (typeof value.text !== "string" || value.text.trim() === "") {
    throw new CollabTurnError("invalid_request");
  }
  if (value.model !== undefined && !validModel(value.model)) throw new CollabTurnError("invalid_request");
  if (value.attachmentIds !== undefined && (
    !Array.isArray(value.attachmentIds) ||
    value.attachmentIds.some((id) => typeof id !== "string" || !UUID_RE.test(id))
  )) throw new CollabTurnError("invalid_request");
  return {
    schemaVersion: 1,
    idempotencyKey: value.idempotencyKey,
    text: value.text,
    ...(value.model !== undefined ? { model: value.model as string } : {}),
    ...(value.attachmentIds !== undefined
      ? { attachmentIds: [...(value.attachmentIds as string[])] }
      : {}),
  };
}

function baseModelId(raw: string): string {
  const match = EFFORT_SUFFIX.exec(raw);
  return (match === null ? raw : raw.slice(0, match.index)).trim();
}

function isAuto(raw: string): boolean {
  const base = baseModelId(raw);
  return base === "" || AUTO_ALIASES.has(base.toLowerCase());
}

/** Evaluate only the sender facts read after the sender account lock. */
export function resolveCollabModel(input: {
  request: CollabTurnRequest;
  catalog: CollabModelCatalog;
  sender: CollabSenderEligibility;
}): CollabModelResolution {
  const request = normalizeCollabTurnRequest(input.request);
  const byok = input.sender.byokDefault;
  if (byok !== null && (!byok.available || !validModel(byok.model))) {
    return { ok: false, code: "key_not_minted" };
  }
  const billingClass: QuotaBillingClass = byok === null ? "ovid_allowance" : "byok";
  if (request.model === undefined) {
    return {
      ok: true,
      requestedModel: null,
      bodyRequestedModel: null,
      resultModel: "auto",
      billingClass,
    };
  }
  const raw = request.model.trim();
  if (isAuto(raw)) {
    return {
      ok: true,
      requestedModel: null,
      bodyRequestedModel: request.model,
      resultModel: "auto",
      billingClass,
    };
  }
  if (!manualModelsAllowed(input.sender.tier)) return { ok: false, code: "manual_model_not_allowed" };
  if (input.catalog.state === "unavailable" || input.catalog.modelIds.length === 0) {
    return { ok: false, code: "temporarily_unavailable" };
  }
  const known = new Set(input.catalog.modelIds.map((id) => id.trim().toLowerCase()));
  if (!known.has(baseModelId(raw).toLowerCase())) return { ok: false, code: "model_unavailable" };
  return {
    ok: true,
    requestedModel: raw,
    bodyRequestedModel: request.model,
    resultModel: raw,
    billingClass,
  };
}

/** Capture the exact accepted execution facts inside the durable outbox body. */
export function acceptedCollabExecutionSnapshot(input: {
  actorUserId: string;
  resolution: Extract<CollabModelResolution, { ok: true }>;
  sender: CollabSenderEligibility;
  hostWorkspaceTier: string;
}): CollabAcceptedExecutionSnapshot {
  if (
    !nonEmpty(input.actorUserId) ||
    !nonEmpty(input.hostWorkspaceTier) ||
    !nonEmpty(input.sender.tier) ||
    !input.resolution.ok
  ) throw new CollabTurnError("invalid_request");
  const byok = input.sender.byokDefault;
  if (
    (byok === null && input.resolution.billingClass !== "ovid_allowance") ||
    (byok !== null && (
      input.resolution.billingClass !== "byok" ||
      !byok.available ||
      !nonEmpty(byok.keyId) ||
      !validModel(byok.model)
    ))
  ) throw new CollabTurnError("key_not_minted");
  const modelContext: AgentRunModelContext = {
    requestedModel: input.resolution.requestedModel,
    byokKeyId: byok?.keyId ?? null,
    ...(byok !== null ? { byokModel: byok.model } : {}),
    temperature: null,
    actorUserId: input.actorUserId,
  };
  return {
    modelContext,
    byokKeyId: modelContext.byokKeyId,
    ...(modelContext.byokModel !== undefined ? { byokModel: modelContext.byokModel } : {}),
    tier: input.hostWorkspaceTier,
    queuePriority: input.sender.tier === "free" ? 2 : 1,
  };
}

/** Current RunOutboxStore input shape, including its two-key body allowlist. */
export function collabRunAdmissionInput(input: {
  actorUserId: string;
  authorization: CollabAuthorization;
  request: CollabTurnRequest;
  lease: CollabSenderLeaseRow;
}): RunAdmissionInput {
  const request = normalizeCollabTurnRequest(input.request);
  return {
    actorUserId: input.actorUserId,
    sessionId: input.authorization.sessionId,
    idempotencyKey: request.idempotencyKey,
    content: request.text,
    requestPayload: { ...request },
    bodyPayload: {
      ownerUserId: input.authorization.ownerUserId,
      requestedModel: request.model ?? null,
    },
    authorization: {
      ownerUserId: input.authorization.ownerUserId,
      collab: {
        roomId: input.authorization.roomId,
        participantId: input.authorization.participantId,
        membershipGeneration: input.lease.membershipGeneration,
        leaseId: input.lease.id,
        leaseGeneration: input.lease.generation,
      },
    },
  };
}

/** Byte-for-byte field equivalent of RunOutboxStore.storedBodyPayload. */
export function storedCollabBodyPayload(
  input: RunAdmissionInput,
  outboxId: string,
  runId: string,
  execution?: CollabAcceptedExecutionSnapshot,
): Record<string, unknown> {
  const collab = input.authorization.collab;
  return {
    ...input.bodyPayload,
    userId: input.actorUserId,
    sessionId: input.sessionId,
    runId,
    ...(collab === undefined ? {} : { collab: { ...collab, outboxId, rootRunId: runId } }),
    ...(execution ?? {}),
  };
}

function invalidRecord(): never {
  throw new CollabTurnError("invalid_record");
}

function expectedTurnModel(request: CollabTurnRequest): string | null {
  return request.model === undefined || isAuto(request.model.trim()) ? null : request.model.trim();
}

function assertStatusCoherence(record: CollabTurnRecord): void {
  const turn = record.turn.status;
  const run = record.run.status;
  const coherent =
    (turn === "queued" && (run === "queued" || run === "running")) ||
    (turn === "running" && run === "running") ||
    (turn === "completed" && run === "completed") ||
    (turn === "failed" && run === "failed") ||
    ((turn === "cancelled" || turn === "interrupted") && run === "cancelled");
  if (!coherent) invalidRecord();
}

function assertExecutionSnapshot(record: CollabTurnRecord, request: CollabTurnRequest): void {
  const body = record.outbox.bodyPayload;
  const context = body.modelContext;
  if (!isRecord(context)) invalidRecord();
  const hasByokModel = Object.prototype.hasOwnProperty.call(context, "byokModel");
  if (
    Object.keys(context).some((key) => !MODEL_CONTEXT_KEYS.has(key)) ||
    Object.keys(context).length !== MODEL_CONTEXT_KEYS.size - (hasByokModel ? 0 : 1) ||
    context.requestedModel !== expectedTurnModel(request) ||
    context.actorUserId !== record.turn.actorUserId ||
    context.temperature !== null ||
    context.byokKeyId !== body.byokKeyId ||
    (context.byokKeyId !== null && !nonEmpty(context.byokKeyId)) ||
    Object.prototype.hasOwnProperty.call(body, "byokModel") !== hasByokModel ||
    (hasByokModel && body.byokModel !== context.byokModel)
  ) invalidRecord();
  if (context.byokKeyId === null) {
    if (hasByokModel) invalidRecord();
  } else if (!validModel(context.byokModel)) {
    invalidRecord();
  }
}

/** One strict validator shared by replay, recovery, job derivation and descendants. */
export function assertCollabTurnRecord(record: CollabTurnRecord): void {
  let request: CollabTurnRequest;
  try {
    request = normalizeCollabTurnRequest(record.outbox.requestPayload);
  } catch {
    invalidRecord();
  }
  const { message, run, turn, lease, outbox } = record;
  const body = outbox.bodyPayload;
  if (!isRecord(body)) invalidRecord();
  const hasRequestedModel = Object.prototype.hasOwnProperty.call(body, "requestedModel");
  const hasByokModel = Object.prototype.hasOwnProperty.call(body, "byokModel");
  if (
    message.id !== turn.userMessageId ||
    message.sessionId !== outbox.sessionId ||
    message.role !== "user" ||
    message.content !== request.text ||
    run.id !== turn.runId ||
    run.sessionId !== message.sessionId ||
    run.promptMessageId !== message.id ||
    turn.actorUserId !== outbox.actorUserId ||
    turn.idempotencyKey !== outbox.idempotencyKey ||
    outbox.idempotencyKey !== request.idempotencyKey ||
    outbox.runId !== run.id ||
    outbox.userMessageId !== message.id ||
    outbox.jobId !== run.id ||
    !["queued", "published", "settled", "failed"].includes(outbox.status) ||
    !Number.isSafeInteger(outbox.attempts) || outbox.attempts < 0 ||
    turn.model !== expectedTurnModel(request) ||
    lease.roomId !== turn.roomId ||
    lease.holderParticipantId !== turn.participantId ||
    lease.holderUserId !== turn.actorUserId ||
    lease.runId !== run.id ||
    !Number.isSafeInteger(lease.generation) || lease.generation < 1 ||
    !Number.isSafeInteger(lease.roomGeneration) || lease.roomGeneration < 1 ||
    !Number.isSafeInteger(lease.membershipGeneration) || lease.membershipGeneration < 1 ||
    !isRecord(body) ||
    Object.keys(body).some((key) => !BODY_KEYS.has(key)) ||
    Object.keys(body).length !== BODY_KEYS.size -
      (hasRequestedModel ? 0 : 1) - (hasByokModel ? 0 : 1) ||
    !nonEmpty(body.ownerUserId) ||
    !nonEmpty(body.tier) ||
    (body.queuePriority !== 1 && body.queuePriority !== 2) ||
    (request.model !== undefined && (!hasRequestedModel || body.requestedModel !== request.model)) ||
    (request.model === undefined && hasRequestedModel && body.requestedModel !== null) ||
    body.userId !== turn.actorUserId ||
    body.sessionId !== message.sessionId ||
    body.runId !== run.id
  ) invalidRecord();
  const collab = body.collab;
  if (!isRecord(collab)) invalidRecord();
  if (
    Object.keys(collab).some((key) => !COLLAB_KEYS.has(key)) ||
    Object.keys(collab).length !== COLLAB_KEYS.size ||
    collab.roomId !== turn.roomId ||
    collab.participantId !== turn.participantId ||
    collab.membershipGeneration !== lease.membershipGeneration ||
    collab.leaseId !== lease.id ||
    !Number.isSafeInteger(collab.leaseGeneration) ||
    (collab.leaseGeneration as number) < 1 ||
    // Stale recovery advances the row fence but never rewrites the accepted
    // outbox lineage. That mismatch is valid only after release+cancellation.
    ((collab.leaseGeneration !== lease.generation) && (
      (collab.leaseGeneration as number) > lease.generation ||
      lease.releasedAt === null ||
      lease.cancelRequestedAt === null
    )) ||
    collab.outboxId !== outbox.outboxId ||
    collab.rootRunId !== run.id
  ) invalidRecord();
  assertExecutionSnapshot(record, request);
  assertStatusCoherence(record);
}

export function collabTurnResult(record: CollabTurnRecord): CollabTurnResult {
  assertCollabTurnRecord(record);
  return {
    schemaVersion: 1,
    turnId: record.turn.id,
    runId: record.run.id,
    userMessageId: record.message.id,
    userEventId: `message:${record.message.id}`,
    status: record.turn.status === "queued" || record.turn.status === "running"
      ? "queued"
      : record.turn.status,
    model: record.turn.model ?? "auto",
  };
}

/** Replay compares request and authority, then derives rather than trusts a response. */
export function collabTurnReplay(input: {
  record: CollabTurnRecord;
  request: CollabTurnRequest;
  actorUserId: string;
  authorization: CollabAuthorization;
}): CollabTurnResult {
  assertCollabTurnRecord(input.record);
  const request = normalizeCollabTurnRequest(input.request);
  const storedRequest = normalizeCollabTurnRequest(input.record.outbox.requestPayload);
  const body = input.record.outbox.bodyPayload;
  if (
    !sameRequest(storedRequest, request) ||
    input.record.turn.roomId !== input.authorization.roomId ||
    input.record.turn.participantId !== input.authorization.participantId ||
    input.record.turn.actorUserId !== input.actorUserId ||
    input.record.outbox.actorUserId !== input.actorUserId ||
    input.record.message.sessionId !== input.authorization.sessionId ||
    input.record.outbox.sessionId !== input.authorization.sessionId ||
    input.record.lease.holderParticipantId !== input.authorization.participantId ||
    body.ownerUserId !== input.authorization.ownerUserId ||
    input.record.outbox.idempotencyKey !== request.idempotencyKey
  ) throw new CollabTurnError("request_already_used");
  return collabTurnResult(input.record);
}

/** Reconstruct every queue field solely from the validated durable rows. */
export function collabTurnJob(
  record: CollabTurnRecord,
  publication?: AgentRunCollabPublication,
): CollabAgentRunJob {
  assertCollabTurnRecord(record);
  const request = normalizeCollabTurnRequest(record.outbox.requestPayload);
  const body = record.outbox.bodyPayload;
  const ownerUserId = body.ownerUserId as string;
  const modelContext = body.modelContext as unknown as AgentRunModelContext;
  return {
    runId: record.run.id,
    sessionId: record.message.sessionId,
    // Current worker hydration uses userId as host owner; actor remains sender.
    userId: ownerUserId,
    ownerUserId,
    actorUserId: record.turn.actorUserId,
    source: "collab",
    prompt: record.message.content,
    tier: body.tier as string,
    ...(modelContext.requestedModel !== null
      ? { requestedModel: modelContext.requestedModel }
      : {}),
    byokKeyId: modelContext.byokKeyId,
    ...(modelContext.byokModel !== undefined ? { byokModel: modelContext.byokModel } : {}),
    modelContext: { ...modelContext },
    ...(request.attachmentIds !== undefined && request.attachmentIds.length > 0
      ? { attachmentIds: [...request.attachmentIds] }
      : {}),
    collab: { ...(body.collab as unknown as CollabRunLineage) },
    ...(publication !== undefined ? { collabPublication: { ...publication } } : {}),
  };
}

export function collabTurnJobsEqual(a: CollabAgentRunJob, b: CollabAgentRunJob): boolean {
  return canonical(a) === canonical(b);
}

export function collabRecordAuthorityToken(
  record: CollabTurnRecord,
  current: CollabCurrentAuthority,
): string {
  return collabAuthorityToken({
    roomId: record.turn.roomId,
    sessionId: record.message.sessionId,
    ownerUserId: record.outbox.bodyPayload.ownerUserId as string,
    actorUserId: record.turn.actorUserId,
    participantId: record.turn.participantId,
    roomGeneration: current.room.generation,
    membershipGeneration: current.member.generation,
    leaseId: record.lease.id,
    leaseGeneration: record.lease.generation,
    rootRunId: record.run.id,
    turnId: record.turn.id,
  });
}

function publicationExpectation(
  record: CollabTurnRecord,
  current: CollabCurrentAuthority,
  fromStatus: "queued" | "failed" | "published",
  fromAttempts: number,
  fromPublishedAt: string | null,
): CollabPublicationExpectation {
  return {
    fromStatus,
    fromAttempts,
    fromPublishedAt,
    outboxStatus: "published",
    outboxAttempts: fromAttempts + 1,
    runStatus: "queued",
    turnStatus: "queued",
    leaseGeneration: record.lease.generation,
    authorityToken: collabRecordAuthorityToken(record, current),
  };
}

/** Re-evaluate a decision against freshly locked rows before any queue add. */
export function collabPublicationExpectationMatches(input: {
  expectation: CollabPublicationExpectation;
  record: CollabTurnRecord;
  current: CollabCurrentAuthority;
}): boolean {
  const { expectation, record, current } = input;
  if (
    record.outbox.status !== expectation.fromStatus ||
    record.outbox.attempts !== expectation.fromAttempts ||
    (record.outbox.publishedAt?.toISOString() ?? null) !== expectation.fromPublishedAt ||
    record.run.status !== expectation.runStatus ||
    record.turn.status !== expectation.turnStatus ||
    record.lease.generation !== expectation.leaseGeneration ||
    expectation.outboxAttempts !== expectation.fromAttempts + 1 ||
    currentIdentityError(record, current) !== null ||
    currentLeaseError(record, current) !== null
  ) return false;
  const expected = publicationExpectation(
    record,
    current,
    expectation.fromStatus,
    expectation.fromAttempts,
    expectation.fromPublishedAt,
  );
  return canonical(expected) === canonical(expectation);
}

function isTerminal(record: CollabTurnRecord): boolean {
  return ["completed", "failed", "cancelled", "interrupted"].includes(record.turn.status);
}

function currentIdentityError(
  record: CollabTurnRecord,
  current: CollabCurrentAuthority,
): "not_member" | "session_closed" | "admission_denied" | null {
  const body = record.outbox.bodyPayload;
  if (!current.senderActive) return "admission_denied";
  if (
    current.hostSession.id !== record.message.sessionId ||
    current.hostSession.userId !== body.ownerUserId ||
    current.hostSession.deletedAt !== null ||
    current.room.id !== record.turn.roomId ||
    current.room.sessionId !== record.message.sessionId ||
    current.room.ownerUserId !== body.ownerUserId ||
    current.member.roomId !== record.turn.roomId ||
    current.member.userId !== record.turn.actorUserId ||
    current.member.participantId !== record.turn.participantId ||
    current.member.status !== "active"
  ) return "not_member";
  if (current.room.lifecycle !== "active") return "session_closed";
  return null;
}

function currentLeaseError(
  record: CollabTurnRecord,
  current: CollabCurrentAuthority,
): "stale_authorization" | null {
  const heartbeat = record.lease.heartbeatAt.getTime();
  const now = current.now.getTime();
  if (
    !Number.isFinite(now) ||
    !Number.isFinite(heartbeat) ||
    !Number.isFinite(current.staleAfterMs) || current.staleAfterMs < 0 ||
    !Number.isSafeInteger(current.latestLeaseGeneration) || current.latestLeaseGeneration < 1 ||
    current.room.generation !== record.lease.roomGeneration ||
    current.member.generation !== record.lease.membershipGeneration ||
    current.latestLeaseGeneration !== record.lease.generation ||
    record.run.cancelRequested ||
    record.turn.cancelRequestedAt !== null ||
    record.lease.releasedAt !== null ||
    record.lease.cancelRequestedAt !== null ||
    now < heartbeat ||
    now - heartbeat > current.staleAfterMs
  ) return "stale_authorization";
  return null;
}

/**
 * Decide from a post-lock durable snapshot. Publication itself is always after
 * that snapshot's transaction commits. Terminal settlement needs no live lease;
 * queued/running publication requires the current fresh root fence.
 */
export function planCollabPublication(input: {
  record: CollabTurnRecord;
  current: CollabCurrentAuthority;
}): CollabPublicationDecision {
  const { record, current } = input;
  assertCollabTurnRecord(record);
  if (record.outbox.status === "settled") return { kind: "noop", reason: "settled" };
  if (record.outbox.status === "published" && isTerminal(record)) {
    return { kind: "settle", outboxId: record.outbox.outboxId };
  }
  if (record.outbox.status !== "published" && isTerminal(record)) {
    return { kind: "fenced", code: "terminal_outbox_unreconciled" };
  }

  const identityError = currentIdentityError(record, current);
  if (identityError !== null) return { kind: "fenced", code: identityError };
  const leaseError = currentLeaseError(record, current);
  if (leaseError !== null) return { kind: "fenced", code: leaseError };

  if (record.outbox.status === "published" && record.outbox.publishedAt !== null) {
    return { kind: "noop", reason: "published" };
  }
  if (record.run.status === "running") {
    return { kind: "mark_published", outboxId: record.outbox.outboxId };
  }
  const expectation = publicationExpectation(
    record,
    current,
    record.outbox.status,
    record.outbox.attempts,
    record.outbox.publishedAt?.toISOString() ?? null,
  );
  const publication: AgentRunCollabPublication = {
    outboxStatus: expectation.outboxStatus,
    outboxAttempts: expectation.outboxAttempts,
    runStatus: expectation.runStatus,
    turnStatus: expectation.turnStatus,
    leaseGeneration: expectation.leaseGeneration,
    authorityToken: expectation.authorityToken,
  };
  return {
    kind: "publish",
    outboxId: record.outbox.outboxId,
    job: collabTurnJob(record, publication),
    options: {
      jobId: record.outbox.jobId,
      priority: record.outbox.bodyPayload.queuePriority as 1 | 2,
    },
    expectation,
  };
}

/** Descendants resolve the root fence through lineage; no second lease/write. */
export function planCollabDescendantLease(input: {
  root: CollabTurnRecord;
  current: CollabCurrentAuthority;
}): CollabDescendantLeasePlan {
  assertCollabTurnRecord(input.root);
  const identityError = currentIdentityError(input.root, input.current);
  if (identityError !== null) return { kind: "refuse", code: identityError, writes: [] };
  const leaseError = currentLeaseError(input.root, input.current);
  if (leaseError !== null) return { kind: "refuse", code: leaseError, writes: [] };
  return {
    kind: "inherit",
    collab: { ...(input.root.outbox.bodyPayload.collab as unknown as CollabRunLineage) },
    writes: [],
  };
}
