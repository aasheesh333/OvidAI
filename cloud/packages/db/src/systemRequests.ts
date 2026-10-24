import { createHash } from "node:crypto";
import { and, asc, desc, eq, gt, isNull, sql } from "drizzle-orm";
import type { Db } from "./client.js";
import { newId } from "./repos.js";
import {
  messages as messagesTable,
  runOutbox as runOutboxTable,
  runs as runsTable,
  sessions as sessionsTable,
  systemRequestResponses as responsesTable,
  systemRequests as requestsTable,
  users as usersTable,
  type RunOutboxRow,
  type SystemRequestResponseRow,
  type SystemRequestRow,
} from "./schema.js";

export type SystemRequestKind = SystemRequestRow["kind"];
export type SystemRequestStatus = SystemRequestRow["status"];
export type RunOutboxStatus = RunOutboxRow["status"];
export type JsonRecord = Record<string, unknown>;

export interface SystemRequestDto {
  requestId: string;
  userId: string;
  sessionId: string;
  runId: string;
  kind: SystemRequestKind;
  safePayload: JsonRecord;
  sensitive: boolean;
  status: SystemRequestStatus;
  /** ISO-8601, matching the canonical REST DTO timestamp convention. */
  expiresAt: string;
  /** Sensitive responses stay null; their writes are blocked until durable handoff. */
  response: JsonRecord | null;
  version: number;
}

export interface SystemResponseDto {
  requestId: string;
  userId: string;
  /** The request version answered by this response (before its CAS increment). */
  version: number;
  response: JsonRecord | null;
  clientResponseId: string;
  createdAt: string;
}

export interface CreateSystemRequestInput {
  requestId: string;
  userId: string;
  sessionId: string;
  runId: string;
  kind: SystemRequestKind;
  safePayload: JsonRecord;
  sensitive: boolean;
  expiresAt: Date;
}

export interface SystemRequestStore {
  create(input: CreateSystemRequestInput): Promise<SystemRequestDto>;
  get(input: { userId: string; requestId: string }): Promise<SystemRequestDto | null>;
  listPending(input: { userId: string; sessionId?: string }): Promise<SystemRequestDto[]>;
  respond(input: {
    userId: string;
    requestId: string;
    version: number;
    response: JsonRecord;
    clientResponseId: string;
  }): Promise<SystemResponseDto | null>;
  expire(input: {
    userId: string;
    requestId: string;
    version: number;
  }): Promise<SystemRequestDto | null>;
}

export type SystemRequestErrorCode =
  | "invalid_request"
  | "not_found"
  | "version_conflict"
  | "response_conflict"
  | "client_response_conflict"
  | "request_expired"
  | "request_not_pending"
  | "request_not_expired"
  | "sensitive_delivery_unavailable";

const REQUEST_ERROR_MESSAGES: Record<SystemRequestErrorCode, string> = {
  invalid_request: "The system request is invalid.",
  not_found: "The system request was not found.",
  version_conflict: "The system request version is stale.",
  response_conflict: "A different response was already recorded.",
  client_response_conflict: "This clientResponseId is already used.",
  request_expired: "The system request has expired.",
  request_not_pending: "The system request is no longer pending.",
  request_not_expired: "The system request has not reached its expiry.",
  sensitive_delivery_unavailable: "Sensitive response delivery is unavailable; re-enter it after durable recovery is available.",
};

/** Typed, payload-free failures suitable for gateway error mapping. */
export class SystemRequestError extends Error {
  constructor(readonly code: SystemRequestErrorCode) {
    super(REQUEST_ERROR_MESSAGES[code]);
    this.name = "SystemRequestError";
  }
}

export type RunOutboxErrorCode =
  | "invalid_request"
  | "not_found"
  | "request_already_used"
  | "invalid_transition"
  | "authorization_required"
  | "admission_denied"
  | "stale_authorization";

/** Typed outbox failures; request/body payloads are never copied into errors. */
export class RunOutboxError extends Error {
  constructor(readonly code: RunOutboxErrorCode) {
    const messages: Record<RunOutboxErrorCode, string> = {
      invalid_request: "The run admission is invalid.",
      not_found: "The run admission target was not found.",
      request_already_used: "This idempotency key is already used by a different payload.",
      invalid_transition: "The outbox row is not in a retryable state.",
      authorization_required: "A transactional run admission authorizer is required.",
      admission_denied: "Run admission is not authorized.",
      stale_authorization: "Run admission authorization is stale.",
    };
    super(messages[code]);
    this.name = "RunOutboxError";
  }
}

export class ResponseWaitError extends Error {
  constructor(readonly code: "invalid_response_wait") {
    super("responseWaitSeconds must be an integer between 15 and 600.");
    this.name = "ResponseWaitError";
  }
}

type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];
type DbOrTx = Db | Tx;
type StoreOptions = { clock?: () => Date };

function q(db: DbOrTx): Db {
  return db as Db;
}

function requiredString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new SystemRequestError("invalid_request");
  }
  return value;
}

function validDate(value: Date): Date {
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) {
    throw new SystemRequestError("invalid_request");
  }
  return value;
}

/** Normalize JSON without invoking toJSON or retaining non-JSON values. */
function normalizeJson(value: unknown, ancestors = new Set<object>()): unknown {
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new SystemRequestError("invalid_request");
    return value;
  }
  if (typeof value !== "object") throw new SystemRequestError("invalid_request");
  const object = value as object;
  if (ancestors.has(object)) throw new SystemRequestError("invalid_request");
  ancestors.add(object);
  try {
    if (Array.isArray(value)) return value.map((entry) => normalizeJson(entry, ancestors));
    const prototype = Object.getPrototypeOf(value) as unknown;
    if (prototype !== Object.prototype && prototype !== null) {
      throw new SystemRequestError("invalid_request");
    }
    const result: JsonRecord = {};
    for (const key of Object.keys(value as JsonRecord).sort()) {
      // defineProperty also makes an own "__proto__" key instead of changing
      // the result object's prototype. Input remains plain JSON thereafter.
      Object.defineProperty(result, key, {
        value: normalizeJson((value as JsonRecord)[key], ancestors),
        enumerable: true,
        configurable: true,
        writable: true,
      });
    }
    return result;
  } finally {
    ancestors.delete(object);
  }
}

function jsonRecord(value: unknown): JsonRecord {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new SystemRequestError("invalid_request");
  }
  return normalizeJson(value) as JsonRecord;
}

function canonical(value: JsonRecord): string {
  return JSON.stringify(jsonRecord(value));
}

function digest(value: JsonRecord): string {
  return createHash("sha256").update(canonical(value), "utf8").digest("hex");
}

async function lockKey(tx: Tx, scope: string): Promise<void> {
  await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${scope}, 0))`);
}

function requestDto(
  row: SystemRequestRow,
  response?: SystemRequestResponseRow | null,
): SystemRequestDto {
  return {
    requestId: row.requestId,
    userId: row.userId,
    sessionId: row.sessionId,
    runId: row.runId,
    kind: row.kind,
    safePayload: row.safePayload,
    sensitive: row.sensitive,
    status: row.status,
    expiresAt: row.expiresAt.toISOString(),
    response: row.sensitive ? null : (response?.response ?? null),
    version: row.version,
  };
}

function responseDto(row: SystemRequestResponseRow, sensitive: boolean): SystemResponseDto {
  return {
    requestId: row.requestId,
    userId: row.userId,
    version: row.requestVersion,
    response: sensitive ? null : row.response,
    clientResponseId: row.clientResponseId,
    createdAt: row.createdAt.toISOString(),
  };
}

async function latestResponse(
  db: DbOrTx,
  requestId: string,
): Promise<SystemRequestResponseRow | null> {
  const rows = await q(db)
    .select()
    .from(responsesTable)
    .where(eq(responsesTable.requestId, requestId))
    .orderBy(desc(responsesTable.requestVersion))
    .limit(1);
  return rows[0] ?? null;
}

type RespondResult =
  | { kind: "success"; response: SystemResponseDto }
  | { kind: "not_found" }
  | { kind: "failure"; code: SystemRequestErrorCode };

export function createSystemRequestStore(db: Db, options: StoreOptions = {}): SystemRequestStore {
  const clock = options.clock ?? (() => new Date());
  return {
    async create(input) {
      const requestId = requiredString(input.requestId, "requestId");
      const userId = requiredString(input.userId, "userId");
      const sessionId = requiredString(input.sessionId, "sessionId");
      const runId = requiredString(input.runId, "runId");
      const safePayload = jsonRecord(input.safePayload);
      const expiresAt = validDate(input.expiresAt);
      return db.transaction(async (tx) => {
        // A request cannot borrow another user's session or another session's run.
        const identity = await tx
          .select({ id: sessionsTable.id })
          .from(sessionsTable)
          .innerJoin(runsTable, eq(runsTable.sessionId, sessionsTable.id))
          .where(and(
            eq(sessionsTable.id, sessionId),
            eq(sessionsTable.userId, userId),
            eq(runsTable.id, runId),
            isNull(sessionsTable.deletedAt),
          ))
          .for("share")
          .limit(1);
        if (identity.length === 0) throw new SystemRequestError("not_found");
        const [row] = await tx
          .insert(requestsTable)
          .values({
            requestId,
            userId,
            sessionId,
            runId,
            kind: input.kind,
            safePayload,
            sensitive: input.sensitive,
            status: "pending",
            expiresAt,
            version: 1,
            createdAt: clock(),
          })
          .returning();
        return requestDto(row!);
      });
    },

    async get({ userId, requestId }) {
      const rows = await db
        .select({ request: requestsTable, response: responsesTable })
        .from(requestsTable)
        .leftJoin(responsesTable, eq(responsesTable.requestId, requestsTable.requestId))
        .where(and(eq(requestsTable.requestId, requestId), eq(requestsTable.userId, userId)))
        .orderBy(desc(responsesTable.requestVersion))
        .limit(1);
      const row = rows[0];
      return row === undefined ? null : requestDto(row.request, row.response);
    },

    async listPending({ userId, sessionId }) {
      const now = clock();
      const rows = await db
        .select({ request: requestsTable, response: responsesTable })
        .from(requestsTable)
        .leftJoin(responsesTable, eq(responsesTable.requestId, requestsTable.requestId))
        .where(and(
          eq(requestsTable.userId, userId),
          ...(sessionId === undefined ? [] : [eq(requestsTable.sessionId, sessionId)]),
          eq(requestsTable.status, "pending"),
          gt(requestsTable.expiresAt, now),
        ))
        .orderBy(asc(requestsTable.createdAt), asc(requestsTable.requestId));
      return rows.map((row) => requestDto(row.request, row.response));
    },

    async respond(input) {
      requiredString(input.userId, "userId");
      requiredString(input.requestId, "requestId");
      requiredString(input.clientResponseId, "clientResponseId");
      const result = await db.transaction(async (tx): Promise<RespondResult> => {
        await lockKey(tx, `0033:system-response:${input.userId}:${input.clientResponseId}`);
        const found = await tx
          .select()
          .from(requestsTable)
          .where(and(eq(requestsTable.requestId, input.requestId), eq(requestsTable.userId, input.userId)))
          .for("update")
          .limit(1);
        const request = found[0];
        if (request === undefined) return { kind: "not_found" };
        // RUNTIME BLOCKER: 0033 has no sealed sensitive value or acknowledged
        // durable handoff. Resolving before pub/sub would strand the only copy
        // on publish failure/no subscriber/restart. Keep the request pending
        // and require client re-entry until that delivery contract exists.
        if (request.sensitive) {
          throw new SystemRequestError("sensitive_delivery_unavailable");
        }
        const normalized = jsonRecord(input.response);
        const responseDigest = digest(normalized);
        const existing = await latestResponse(tx, input.requestId);
        const keyed = await tx
          .select()
          .from(responsesTable)
          .where(and(
            eq(responsesTable.userId, input.userId),
            eq(responsesTable.clientResponseId, input.clientResponseId),
          ))
          .limit(1);
        const keyedRow = keyed[0];
        if (keyedRow !== undefined && keyedRow.requestId !== input.requestId) {
          return { kind: "failure", code: "client_response_conflict" };
        }
        if (
          keyedRow !== undefined &&
          (keyedRow.requestVersion !== input.version || keyedRow.responseDigest !== responseDigest)
        ) {
          return { kind: "failure", code: "response_conflict" };
        }
        if (existing !== null) {
          if (existing.requestVersion !== input.version) {
            return { kind: "failure", code: "version_conflict" };
          }
          if (existing.responseDigest !== responseDigest) {
            return { kind: "failure", code: "response_conflict" };
          }
          return { kind: "success", response: responseDto(existing, request.sensitive) };
        }
        if (keyedRow !== undefined) return { kind: "failure", code: "client_response_conflict" };
        if (request.status === "expired") return { kind: "failure", code: "request_expired" };
        if (request.status === "resolved") return { kind: "failure", code: "response_conflict" };
        if (request.status !== "pending") return { kind: "failure", code: "request_not_pending" };
        const now = clock();
        if (request.expiresAt.getTime() <= now.getTime()) {
          await tx
            .update(requestsTable)
            .set({ status: "expired", version: request.version + 1 })
            .where(and(
              eq(requestsTable.requestId, request.requestId),
              eq(requestsTable.version, request.version),
              eq(requestsTable.status, "pending"),
            ));
          // Return rather than throw so this real expiry transition commits.
          return { kind: "failure", code: "request_expired" };
        }
        if (request.version !== input.version) return { kind: "failure", code: "version_conflict" };
        const updated = await tx
          .update(requestsTable)
          .set({ status: "resolved", version: request.version + 1 })
          .where(and(
            eq(requestsTable.requestId, request.requestId),
            eq(requestsTable.version, input.version),
            eq(requestsTable.status, "pending"),
            gt(requestsTable.expiresAt, now),
          ))
          .returning();
        if (updated.length === 0) return { kind: "failure", code: "version_conflict" };
        const [response] = await tx
          .insert(responsesTable)
          .values({
            responseId: newId(),
            requestId: input.requestId,
            userId: input.userId,
            requestVersion: input.version,
            clientResponseId: input.clientResponseId,
            response: request.sensitive ? null : normalized,
            responseDigest,
            createdAt: now,
          })
          .returning();
        return { kind: "success", response: responseDto(response!, request.sensitive) };
      });
      if (result.kind === "not_found") return null;
      if (result.kind === "failure") throw new SystemRequestError(result.code);
      return result.response;
    },

    async expire({ userId, requestId, version }) {
      return db.transaction(async (tx) => {
        const found = await tx
          .select()
          .from(requestsTable)
          .where(and(eq(requestsTable.requestId, requestId), eq(requestsTable.userId, userId)))
          .for("update")
          .limit(1);
        const request = found[0];
        if (request === undefined) return null;
        if (request.status === "expired") {
          if (version === request.version || version === request.version - 1) {
            return requestDto(request, await latestResponse(tx, requestId));
          }
          throw new SystemRequestError("version_conflict");
        }
        if (request.status !== "pending") throw new SystemRequestError("request_not_pending");
        if (request.version !== version) throw new SystemRequestError("version_conflict");
        if (request.expiresAt.getTime() > clock().getTime()) {
          throw new SystemRequestError("request_not_expired");
        }
        const [row] = await tx
          .update(requestsTable)
          .set({ status: "expired", version: request.version + 1 })
          .where(and(
            eq(requestsTable.requestId, requestId),
            eq(requestsTable.version, version),
            eq(requestsTable.status, "pending"),
          ))
          .returning();
        if (row === undefined) throw new SystemRequestError("version_conflict");
        return requestDto(row);
      });
    },
  };
}

export const DEFAULT_RESPONSE_WAIT_SECONDS = 45;

export interface ResponseWaitStore {
  get(userId: string): Promise<number>;
  set(userId: string, responseWaitSeconds: number): Promise<number>;
}

export function createResponseWaitStore(db: Db): ResponseWaitStore {
  return {
    async get(userId) {
      const rows = await db
        .select({ responseWaitSeconds: usersTable.responseWaitSeconds })
        .from(usersTable)
        .where(eq(usersTable.uid, userId))
        .limit(1);
      return rows[0]?.responseWaitSeconds ?? DEFAULT_RESPONSE_WAIT_SECONDS;
    },
    async set(userId, responseWaitSeconds) {
      if (
        !Number.isInteger(responseWaitSeconds) ||
        responseWaitSeconds < 15 ||
        responseWaitSeconds > 600
      ) {
        throw new ResponseWaitError("invalid_response_wait");
      }
      const [row] = await db
        .insert(usersTable)
        .values({ uid: userId, responseWaitSeconds })
        .onConflictDoUpdate({
          target: usersTable.uid,
          set: { responseWaitSeconds },
        })
        .returning({ responseWaitSeconds: usersTable.responseWaitSeconds });
      return row!.responseWaitSeconds;
    },
  };
}

export interface RunAdmissionCollabAuthorization {
  roomId: string;
  participantId: string;
  membershipGeneration: number;
  leaseId: string;
  leaseGeneration: number;
}

export interface RunAdmissionAuthorization {
  /** Host workspace/storage owner; actorUserId remains model/quota identity. */
  ownerUserId: string;
  /** Present only for a currently authorized collaboration admission. */
  collab?: RunAdmissionCollabAuthorization;
}

export type RunAdmissionTransaction = Tx;

/**
 * Verifies owner/membership/generation/lease facts with the same transaction
 * and lock ordering as message/run/outbox insertion. Throw RunOutboxError with
 * not_found, admission_denied, or stale_authorization; never return a boolean
 * that could be mistaken for a committed authorization decision.
 */
export type RunAdmissionAuthorizer = (
  tx: RunAdmissionTransaction,
  input: RunAdmissionInput,
) => Promise<void>;

export interface RunAdmissionInput {
  actorUserId: string;
  sessionId: string;
  idempotencyKey: string;
  /** Canonical user message text; never an assistant/system role. */
  content: string;
  /** Exact client request: schemaVersion/idempotencyKey/text/model?/attachmentIds?. */
  requestPayload: JsonRecord;
  /** Server-safe input: ownerUserId plus optional requestedModel only. */
  bodyPayload: JsonRecord;
  authorization: RunAdmissionAuthorization;
}

export type RunOutboxRecord = RunOutboxRow;

export interface RunOutboxStoreOptions extends StoreOptions {
  authorize: RunAdmissionAuthorizer;
}

export interface RunOutboxStore {
  admit(input: RunAdmissionInput): Promise<RunOutboxRecord>;
  /** @internal Publisher/recovery only. Not an owner-scoped public read API. */
  get(input: { outboxId: string }): Promise<RunOutboxRecord | null>;
  /** Records a publication attempt; a sanitized error code records `failed`. */
  markPublished(input: { outboxId: string; error?: string }): Promise<RunOutboxRecord | null>;
  markSettled(input: { outboxId: string }): Promise<RunOutboxRecord | null>;
  retry(input: { outboxId: string; error?: string }): Promise<RunOutboxRecord | null>;
}

const REQUEST_PAYLOAD_KEYS = new Set([
  "schemaVersion",
  "idempotencyKey",
  "text",
  "model",
  "attachmentIds",
]);
const BODY_PAYLOAD_KEYS = new Set(["ownerUserId", "requestedModel"]);
const AUTHORIZATION_KEYS = new Set(["ownerUserId", "collab"]);
const COLLAB_KEYS = new Set([
  "roomId",
  "participantId",
  "membershipGeneration",
  "leaseId",
  "leaseGeneration",
]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MODEL_RE = /^[^\u0000-\u001f\u007f]+$/;

function invalidAdmission(): never {
  throw new RunOutboxError("invalid_request");
}

function exactKeys(value: JsonRecord, allowed: ReadonlySet<string>): void {
  if (Object.keys(value).some((key) => !allowed.has(key))) invalidAdmission();
}

function requiredAdmissionString(value: unknown): string {
  if (typeof value !== "string" || value.length === 0) invalidAdmission();
  return value;
}

function validModel(value: unknown): value is string {
  if (
    typeof value !== "string" ||
    value.trim() === "" ||
    value.length > 160 ||
    !MODEL_RE.test(value)
  ) {
    return false;
  }
  // Model IDs come from the server catalog/authorizer, never a credential
  // envelope. Conservatively refuse common secret markers even when the
  // generic model-id grammar would otherwise accept the string.
  return !/(?:secret|password|api[_-]?key|byok|bearer|sk-)/i.test(value);
}

function normalizeAuthorization(value: unknown): RunAdmissionAuthorization {
  const raw = jsonRecord(value);
  exactKeys(raw, AUTHORIZATION_KEYS);
  const ownerUserId = requiredAdmissionString(raw.ownerUserId);
  if (raw.collab === undefined) return { ownerUserId };
  const collab = jsonRecord(raw.collab);
  exactKeys(collab, COLLAB_KEYS);
  for (const key of ["roomId", "participantId", "leaseId"] as const) {
    if (typeof collab[key] !== "string" || !UUID_RE.test(collab[key] as string)) invalidAdmission();
  }
  for (const key of ["membershipGeneration", "leaseGeneration"] as const) {
    if (!Number.isSafeInteger(collab[key]) || (collab[key] as number) < 1) invalidAdmission();
  }
  return {
    ownerUserId,
    collab: {
      roomId: collab.roomId as string,
      participantId: collab.participantId as string,
      membershipGeneration: collab.membershipGeneration as number,
      leaseId: collab.leaseId as string,
      leaseGeneration: collab.leaseGeneration as number,
    },
  };
}

function normalizeAdmission(input: RunAdmissionInput): RunAdmissionInput {
  try {
    const actorUserId = requiredAdmissionString(input.actorUserId);
    const sessionId = requiredAdmissionString(input.sessionId);
    const idempotencyKey = requiredAdmissionString(input.idempotencyKey);
    if (idempotencyKey.length > 64 || typeof input.content !== "string" || input.content.trim() === "") {
      invalidAdmission();
    }
    const authorization = normalizeAuthorization(input.authorization);
    const requestPayload = jsonRecord(input.requestPayload);
    exactKeys(requestPayload, REQUEST_PAYLOAD_KEYS);
    if (
      requestPayload.schemaVersion !== 1 ||
      requestPayload.idempotencyKey !== idempotencyKey ||
      requestPayload.text !== input.content
    ) {
      invalidAdmission();
    }
    if (requestPayload.model !== undefined && !validModel(requestPayload.model)) invalidAdmission();
    if (requestPayload.attachmentIds !== undefined) {
      if (!Array.isArray(requestPayload.attachmentIds)) invalidAdmission();
      for (const id of requestPayload.attachmentIds) {
        if (typeof id !== "string" || !UUID_RE.test(id)) invalidAdmission();
      }
    }
    const bodyPayload = jsonRecord(input.bodyPayload);
    exactKeys(bodyPayload, BODY_PAYLOAD_KEYS);
    if (
      bodyPayload.ownerUserId !== authorization.ownerUserId ||
      (bodyPayload.requestedModel !== undefined &&
        bodyPayload.requestedModel !== null &&
        !validModel(bodyPayload.requestedModel))
    ) {
      invalidAdmission();
    }
    if (
      requestPayload.model !== undefined &&
      bodyPayload.requestedModel !== requestPayload.model
    ) {
      invalidAdmission();
    }
    return {
      actorUserId,
      sessionId,
      idempotencyKey,
      content: input.content,
      requestPayload,
      bodyPayload,
      authorization,
    };
  } catch (error) {
    if (error instanceof RunOutboxError) throw error;
    if (error instanceof SystemRequestError) throw new RunOutboxError("invalid_request");
    throw error;
  }
}

function collabJobPayload(
  collab: RunAdmissionCollabAuthorization,
  outboxId: string,
  runId: string,
): JsonRecord {
  return { ...collab, outboxId, rootRunId: runId };
}

function storedBodyPayload(input: RunAdmissionInput, outboxId: string, runId: string): JsonRecord {
  return jsonRecord({
    ...input.bodyPayload,
    userId: input.actorUserId,
    sessionId: input.sessionId,
    runId,
    ...(input.authorization.collab === undefined
      ? {}
      : { collab: collabJobPayload(input.authorization.collab, outboxId, runId) }),
  });
}

function sameBodyInput(stored: JsonRecord, input: RunAdmissionInput): boolean {
  const storedInput: JsonRecord = { ownerUserId: stored.ownerUserId };
  if (Object.prototype.hasOwnProperty.call(stored, "requestedModel")) {
    storedInput.requestedModel = stored.requestedModel;
  }
  if (canonical(storedInput) !== canonical(input.bodyPayload)) return false;
  const collab = input.authorization.collab;
  if (collab === undefined) return stored.collab === undefined;
  if (stored.collab === null || typeof stored.collab !== "object" || Array.isArray(stored.collab)) {
    return false;
  }
  const actual = stored.collab as JsonRecord;
  return (Object.keys(collab) as Array<keyof RunAdmissionCollabAuthorization>)
    .every((key) => actual[key] === collab[key]);
}

async function assertActiveActor(tx: Tx, actorUserId: string): Promise<void> {
  const found = await tx
    .select({ uid: usersTable.uid, bannedAt: usersTable.bannedAt })
    .from(usersTable)
    .where(eq(usersTable.uid, actorUserId))
    .for("update")
    .limit(1);
  if (found[0] === undefined) throw new RunOutboxError("not_found");
  if (found[0].bannedAt !== null) throw new RunOutboxError("admission_denied");
  const deleting = await tx.execute(sql`
    SELECT 1 AS present FROM account_deletions
    WHERE uid = ${actorUserId} AND state IN ('pending','fenced','deleting','deleted')
    LIMIT 1`) as unknown as Array<{ present: number }>;
  if (deleting.length > 0) throw new RunOutboxError("admission_denied");
}

/** Owner-only admission; collaboration requires its own membership/lease authorizer. */
export function createOwnerRunAdmissionAuthorizer(): RunAdmissionAuthorizer {
  return async (tx, input) => {
    if (input.authorization.collab !== undefined) invalidAdmission();
    const found = await tx
      .select({ userId: sessionsTable.userId })
      .from(sessionsTable)
      .where(and(eq(sessionsTable.id, input.sessionId), isNull(sessionsTable.deletedAt)))
      .for("update")
      .limit(1);
    if (
      found[0]?.userId !== input.authorization.ownerUserId ||
      input.actorUserId !== input.authorization.ownerUserId
    ) {
      throw new RunOutboxError("not_found");
    }
  };
}

function validateOutboxError(error: string | undefined): void {
  // lastError is an operational code, never provider/client error text.
  // Reject URLs, whitespace, credentials, and unbounded messages at the
  // repository boundary instead of persisting a secret-shaped payload.
  if (error !== undefined && !/^[a-z0-9][a-z0-9_.-]{0,127}$/.test(error)) {
    throw new RunOutboxError("invalid_request");
  }
}

export function createRunOutboxStore(db: Db, options: RunOutboxStoreOptions): RunOutboxStore {
  if (typeof options?.authorize !== "function") {
    throw new RunOutboxError("authorization_required");
  }
  const clock = options.clock ?? (() => new Date());
  return {
    async admit(input) {
      const normalized = normalizeAdmission(input);
      return db.transaction(async (tx) => {
        await lockKey(tx, `0033:run-admission:${normalized.actorUserId}:${normalized.idempotencyKey}`);
        const session = await tx
          .select({ id: sessionsTable.id })
          .from(sessionsTable)
          .where(and(eq(sessionsTable.id, normalized.sessionId), isNull(sessionsTable.deletedAt)))
          .for("update")
          .limit(1);
        if (session.length === 0) throw new RunOutboxError("not_found");
        await assertActiveActor(tx, normalized.actorUserId);
        // Authorization is a transactional decision, not a preflight hint. A
        // callback's writes and checks commit or roll back with admission.
        await options.authorize(tx, normalized);

        const existingRows = await tx
          .select({ outbox: runOutboxTable, content: messagesTable.content })
          .from(runOutboxTable)
          .innerJoin(messagesTable, eq(messagesTable.id, runOutboxTable.userMessageId))
          .where(and(
            eq(runOutboxTable.actorUserId, normalized.actorUserId),
            eq(runOutboxTable.idempotencyKey, normalized.idempotencyKey),
          ))
          .for("update")
          .limit(1);
        const existing = existingRows[0];
        if (existing !== undefined) {
          if (
            existing.outbox.sessionId !== normalized.sessionId ||
            existing.content !== normalized.content ||
            canonical(existing.outbox.requestPayload) !== canonical(normalized.requestPayload) ||
            !sameBodyInput(existing.outbox.bodyPayload, normalized)
          ) {
            throw new RunOutboxError("request_already_used");
          }
          return existing.outbox;
        }
        const now = clock();
        const userMessageId = newId();
        const runId = newId();
        const outboxId = newId();
        await tx.insert(messagesTable).values({
          id: userMessageId,
          sessionId: normalized.sessionId,
          role: "user",
          content: normalized.content,
          createdAt: now,
        });
        await tx.insert(runsTable).values({
          id: runId,
          sessionId: normalized.sessionId,
          status: "queued",
          promptMessageId: userMessageId,
          createdAt: now,
        });
        const [row] = await tx.insert(runOutboxTable).values({
          outboxId,
          actorUserId: normalized.actorUserId,
          sessionId: normalized.sessionId,
          runId,
          userMessageId,
          idempotencyKey: normalized.idempotencyKey,
          status: "queued",
          requestPayload: normalized.requestPayload,
          bodyPayload: storedBodyPayload(normalized, outboxId, runId),
          jobId: runId,
          attempts: 0,
          createdAt: now,
          updatedAt: now,
        }).returning();
        return row!;
      });
    },

    async get({ outboxId }) {
      const rows = await db
        .select()
        .from(runOutboxTable)
        .where(eq(runOutboxTable.outboxId, outboxId))
        .limit(1);
      return rows[0] ?? null;
    },

    async markPublished({ outboxId, error }) {
      validateOutboxError(error);
      return db.transaction(async (tx) => {
        const found = await tx
          .select()
          .from(runOutboxTable)
          .where(eq(runOutboxTable.outboxId, outboxId))
          .for("update")
          .limit(1);
        const row = found[0];
        if (row === undefined) return null;
        if (error === undefined && row.status === "published") return row;
        if (error !== undefined && row.status === "failed" && row.lastError === error) return row;
        if (row.status !== "queued" && row.status !== "failed") {
          throw new RunOutboxError("invalid_transition");
        }
        // A different failure is a new attempt and must go through retry first;
        // repeating the same failed outcome above is an idempotent replay.
        if (error !== undefined && row.status === "failed") {
          throw new RunOutboxError("invalid_transition");
        }
        const now = clock();
        if (error !== undefined) {
          const [failed] = await tx
            .update(runOutboxTable)
            .set({
              status: "failed",
              attempts: row.attempts + 1,
              publishedAt: null,
              lastAttemptAt: now,
              settledAt: null,
              lastError: error,
              updatedAt: now,
            })
            .where(and(eq(runOutboxTable.outboxId, outboxId), eq(runOutboxTable.status, row.status)))
            .returning();
          return failed ?? null;
        }
        const [updated] = await tx
          .update(runOutboxTable)
          .set({
            status: "published",
            attempts: row.attempts + 1,
            publishedAt: now,
            lastAttemptAt: now,
            lastError: null,
            updatedAt: now,
          })
          .where(and(eq(runOutboxTable.outboxId, outboxId), eq(runOutboxTable.status, row.status)))
          .returning();
        return updated ?? null;
      });
    },

    async markSettled({ outboxId }) {
      return db.transaction(async (tx) => {
        const found = await tx
          .select()
          .from(runOutboxTable)
          .where(eq(runOutboxTable.outboxId, outboxId))
          .for("update")
          .limit(1);
        const row = found[0];
        if (row === undefined) return null;
        if (row.status === "settled") return row;
        if (row.status !== "published") throw new RunOutboxError("invalid_transition");
        const now = clock();
        const [updated] = await tx
          .update(runOutboxTable)
          .set({ status: "settled", settledAt: now, lastError: null, updatedAt: now })
          .where(and(eq(runOutboxTable.outboxId, outboxId), eq(runOutboxTable.status, "published")))
          .returning();
        return updated ?? null;
      });
    },

    async retry({ outboxId, error }) {
      validateOutboxError(error);
      return db.transaction(async (tx) => {
        const found = await tx
          .select()
          .from(runOutboxTable)
          .where(eq(runOutboxTable.outboxId, outboxId))
          .for("update")
          .limit(1);
        const row = found[0];
        if (row === undefined) return null;
        if (row.status !== "queued" && row.status !== "failed") {
          throw new RunOutboxError("invalid_transition");
        }
        const now = clock();
        const [updated] = await tx
          .update(runOutboxTable)
          .set({
            status: "queued",
            attempts: row.attempts + 1,
            publishedAt: null,
            lastAttemptAt: now,
            settledAt: null,
            lastError: error ?? null,
            updatedAt: now,
          })
          .where(and(eq(runOutboxTable.outboxId, outboxId), eq(runOutboxTable.status, row.status)))
          .returning();
        return updated ?? null;
      });
    },
  };
}
