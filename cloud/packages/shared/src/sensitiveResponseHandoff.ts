import { createHmac, timingSafeEqual } from "node:crypto";

// Structural mirrors of @ovid/escrow's public envelope API avoid a package
// cycle. Composition and tests inject the real createEnvelopeCrypto result.
interface EncryptedEnvelope {
  wrappedDek: string;
  iv: string;
  ciphertext: string;
  tag: string;
}

interface EnvelopeCrypto {
  encrypt(plaintext: string, recordId: string): EncryptedEnvelope;
  decrypt(envelope: EncryptedEnvelope, recordId: string): string;
}

/**
 * Phase A sealed codec + durable-store port; no runtime composition.
 *
 * A continuation admission is an ATOMIC database operation, not a free-form
 * apply callback. The adapter must re-check the claim/generation/deadline and
 * pending (not cancelled/expired) fence at database time, install a unique
 * first-writer-wins admission plus the canonical recoverable continuation in
 * `held` state, and commit both before any model/tool effect. Ack atomically
 * resolves the request, tombstones only the handoff envelope, and makes both
 * records `ready` while retaining the canonical sealed value. Terminal handoff
 * transitions atomically cancel both records and clear both sealed values.
 *
 * Exactly-once external model/tool execution is NOT implemented by this pure
 * shared primitive and remains BLOCKED pending a real adapter and downstream
 * idempotency/fencing evidence. No production durability or memory-zeroization
 * claim is made here. Worker identities are authenticated by future composition.
 */

export type SensitiveResponseJsonRecord = Record<string, unknown>;
export type SensitiveRequestStatus = "pending" | "resolved" | "expired" | "cancelled";
export type SensitiveHandoffState =
  | "awaiting_delivery"
  | "claimed"
  | "delivered"
  | "expired"
  | "cancelled";

export interface SensitiveResponseRequestRecord {
  requestId: string;
  userId: string;
  sessionId: string;
  runId: string;
  kind: "approval" | "sampling" | "elicitation";
  safePayload: SensitiveResponseJsonRecord;
  sensitive: boolean;
  status: SensitiveRequestStatus;
  expiresAt: Date;
  version: number;
}

export interface SensitiveResponseClaimRecord {
  claimId: string;
  workerId: string;
  leaseExpiresAt: Date;
}

/** The only persisted response value is the envelope plus keyed commitment. */
export interface SensitiveResponseHandoffRecord {
  responseId: string;
  requestId: string;
  userId: string;
  requestVersion: number;
  clientResponseId: string;
  /** HMAC-SHA-256 with a separate server key; not an offline password verifier. */
  responseCommitment: string;
  envelope: EncryptedEnvelope | null;
  state: SensitiveHandoffState;
  claimGeneration: number;
  claim: SensitiveResponseClaimRecord | null;
  continuationId: string | null;
  createdAt: Date;
  tombstonedAt: Date | null;
}

export interface SensitiveResponseBinding {
  requestId: string;
  userId: string;
  sessionId: string;
  runId: string;
  requestVersion: number;
  responseId: string;
}

export interface SensitiveSealedResponse {
  envelope: EncryptedEnvelope;
  responseCommitment: string;
}

export interface SensitiveResponseCodec {
  seal(
    response: SensitiveResponseJsonRecord,
    binding: SensitiveResponseBinding,
  ): SensitiveSealedResponse;
  unseal(
    sealed: SensitiveSealedResponse,
    binding: SensitiveResponseBinding,
  ): SensitiveResponseJsonRecord;
}

export type SensitiveResponseHandoffErrorCode =
  | "invalid_request"
  | "not_found"
  | "version_conflict"
  | "response_conflict"
  | "client_response_conflict"
  | "request_expired"
  | "request_not_pending"
  | "request_not_expired"
  | "active_claim"
  | "stale_claim"
  | "sealed_response_invalid"
  | "delivery_outcome_uncertain"
  | "transaction_retry_exhausted"
  | "handoff_unavailable";

const ERROR_MESSAGES: Record<SensitiveResponseHandoffErrorCode, string> = {
  invalid_request: "The sensitive response handoff is invalid.",
  not_found: "The sensitive response handoff was not found.",
  version_conflict: "The sensitive response handoff version is stale.",
  response_conflict: "A different sensitive response or acknowledgement was recorded.",
  client_response_conflict: "This clientResponseId is already used.",
  request_expired: "The sensitive response request has expired.",
  request_not_pending: "The sensitive response request is no longer pending.",
  request_not_expired: "The sensitive response request has not reached its expiry.",
  active_claim: "An active worker lease already exists.",
  stale_claim: "The worker lease is stale.",
  sealed_response_invalid: "The sealed response failed authentication.",
  delivery_outcome_uncertain: "The durable delivery outcome is uncertain; retry the same fenced delivery.",
  transaction_retry_exhausted: "The durable transaction retry limit was reached.",
  handoff_unavailable: "The sensitive response handoff is unavailable.",
};

export class SensitiveResponseHandoffError extends Error {
  constructor(readonly code: SensitiveResponseHandoffErrorCode) {
    super(ERROR_MESSAGES[code]);
    this.name = "SensitiveResponseHandoffError";
  }
}

/** Adapters throw this ONLY for a known-rolled-back serialization/deadlock failure. */
export class SensitiveResponseTransactionRetryError extends Error {
  constructor() {
    super("The sensitive response transaction can be retried after rollback.");
    this.name = "SensitiveResponseTransactionRetryError";
  }
}

export interface SensitiveResponseAcceptInput {
  userId: string;
  requestId: string;
  version: number;
  response: SensitiveResponseJsonRecord;
  clientResponseId: string;
}

export interface SensitiveResponseReceipt {
  requestId: string;
  version: number;
  clientResponseId: string;
  createdAt: string;
  deliveryState: "awaiting_delivery";
}

/** Client DTOs never contain the commitment, plaintext, or sealed bytes. */
export interface SensitiveResponsePendingDto {
  requestId: string;
  userId: string;
  sessionId: string;
  runId: string;
  kind: SensitiveResponseRequestRecord["kind"];
  safePayload: SensitiveResponseJsonRecord;
  sensitive: true;
  status: SensitiveRequestStatus;
  expiresAt: string;
  response: null;
  version: number;
}

export interface SensitiveResponseWorker {
  workerId: string;
  userId: string;
  sessionId: string;
  runId: string;
}

/** Server-only claim and expected ack identity; never a client DTO. */
export interface SensitiveResponseClaim {
  requestId: string;
  responseId: string;
  claimId: string;
  claimGeneration: number;
  leaseExpiresAt: string;
  requestVersion: number;
  requestExpiresAt: string;
  responseCommitment: string;
  continuationId: string;
}

export interface SensitiveContinuationBinding {
  idempotencyKey: string;
  continuationId: string;
  requestId: string;
  userId: string;
  sessionId: string;
  runId: string;
  responseId: string;
  requestVersion: number;
  responseCommitment: string;
}

export interface SensitiveContinuationFence {
  claimId: string;
  claimGeneration: number;
  workerId: string;
  leaseExpiresAt: Date;
  requestExpiresAt: Date;
  expectedRequestStatus: "pending";
  expectedHandoffState: "claimed";
}

export interface SensitiveContinuationAdmissionInput {
  binding: SensitiveContinuationBinding;
  fence: SensitiveContinuationFence;
  /** Exact authenticated value to persist; plaintext is never supplied to the store. */
  sealedResponse: SensitiveSealedResponse;
}

export interface SensitiveContinuationAckInput {
  binding: SensitiveContinuationBinding;
  fence: SensitiveContinuationFence;
  /** Required for first ack; null only for delivered replay after handoff tombstone. */
  sealedResponse: SensitiveSealedResponse | null;
}

export type SensitiveContinuationState = "held" | "ready" | "cancelled";

/** First-writer record retains the exact sealed value for replay/ack validation. */
export interface SensitiveContinuationRecord {
  binding: SensitiveContinuationBinding;
  /** Non-null in held/ready; terminal cancellation atomically clears it. */
  sealedResponse: SensitiveSealedResponse | null;
  state: SensitiveContinuationState;
  admittedAt: Date;
  firstClaimId: string;
  firstClaimGeneration: number;
}

/** Durable, worker-only canonical value; never a client/log/event DTO. */
export interface SensitiveCanonicalContinuationRecord {
  continuationId: string;
  binding: SensitiveContinuationBinding;
  /** The exact escrow envelope and keyed commitment needed after handoff tombstone. */
  sealedResponse: SensitiveSealedResponse | null;
  state: SensitiveContinuationState;
  admittedAt: Date;
}

export type SensitiveContinuationRefusal =
  | "conflict"
  | "stale_claim"
  | "request_expired"
  | "request_not_pending"
  | "not_found"
  | "continuation_unavailable";

export type SensitiveContinuationAdmissionResult =
  | { kind: "admitted" | "replayed"; continuationId: string }
  | { kind: SensitiveContinuationRefusal };

export type SensitiveContinuationAckResult =
  | { kind: "acknowledged" | "replayed"; continuationId: string }
  | { kind: SensitiveContinuationRefusal };

export type SensitiveResponseTransition =
  | {
      kind: "claim";
      claimGeneration: number;
      claim: SensitiveResponseClaimRecord;
    }
  | { kind: "expired" | "cancelled"; tombstonedAt: Date };

export type SensitiveResponseTransactionOperation =
  | "read"
  | "accept"
  | "claim"
  | "delivery_load"
  | "admit_continuation"
  | "acknowledge"
  | "expire"
  | "cancel";

export interface SensitiveClientResponseLock {
  userId: string;
  clientResponseId: string;
}

export type SensitiveResponseTransactionOptions =
  | {
      operation: "accept";
      lockRequestId: string;
      /** Required before the request lock; scoped to the user, not global. */
      lockClientResponse: SensitiveClientResponseLock;
    }
  | {
      operation: Exclude<SensitiveResponseTransactionOperation, "accept">;
      lockRequestId?: string;
    };

/**
 * Real adapters use serializable transactions and ordered locks across EVERY
 * connection: (userId,clientResponseId) for accept, then request, response,
 * continuation. The client-key lock must precede reading the keyed row and use
 * one database-wide advisory-lock/unique-key scope, never a process-local map.
 * An equivalent design may use the database unique constraint and, only after
 * definite rollback, translate its conflict to RetryError so the next attempt
 * returns the original receipt or client_response_conflict. Unrelated user/key
 * and request scopes must not serialize each other. Every callback rolls back
 * on throw. Commit-unknown failures are not mislabeled as definite rollback.
 */
export interface SensitiveResponseHandoffTransaction {
  getRequest(requestId: string): Promise<SensitiveResponseRequestRecord | null>;
  listRequests(): Promise<SensitiveResponseRequestRecord[]>;
  getResponseByRequest(requestId: string): Promise<SensitiveResponseHandoffRecord | null>;
  getResponseByClientResponseId(
    userId: string,
    clientResponseId: string,
  ): Promise<SensitiveResponseHandoffRecord | null>;
  /** Unique response ID, request ID, and (user ID, client response ID). */
  insertAwaitingDelivery(record: SensitiveResponseHandoffRecord): Promise<void>;
  /** The only legal direct request transitions; version increments in the adapter. */
  transitionRequest(
    requestId: string,
    expectedVersion: number,
    target: "expired" | "cancelled",
  ): Promise<boolean>;
  /** Terminal transitions atomically cancel admission AND canonical held records and clear both sealed values. */
  transitionResponse(
    responseId: string,
    expectedClaimGeneration: number,
    transition: SensitiveResponseTransition,
  ): Promise<boolean>;
  /**
   * Atomically under the same locks and database-time fence:
   * 1. verify full binding, claim ID/generation/worker/lease, request deadline,
   *    pending request and claimed handoff (therefore not cancelled/expired);
   * 2. insert the unique idempotency record first, or replay only an exactly
   *    equal binding AND exact sealedResponse; any different value conflicts;
   * 3. durably create the canonical record in `held` state with that exact
   *    escrow envelope/commitment and six-field binding in the same transaction,
   *    before any model/tool side effect. Plaintext is never a store input.
   * Replay and ack must load both records and require matching binding, legal
   * state, and exact sealed value. Missing canonical value is unavailable and
   * MUST leave the request unresolved; a rebound value conflicts. A crash
   * rolls back both writes. A commit-unknown caller retries the same binding.
   */
  admitContinuation(
    input: SensitiveContinuationAdmissionInput,
  ): Promise<SensitiveContinuationAdmissionResult>;
  /**
   * Atomically re-fence at database time and require matching held admission
   * AND canonical records, equal bindings, and exact sealed values. The input
   * sealedResponse is required for first ack and must equal both persisted
   * copies; delivered replay may pass null only when both records are ready.
   * Only then resolve/increment the request, clear the HANDOFF envelope, and
   * make both records ready while retaining the canonical sealed value for
   * recovery. Missing/rebound canonical values fail unresolved. Delivered
   * replay repeats the same persisted-value validation. Terminal transitions
   * cancel both records and clear both sealed values so no late apply is legal.
   */
  acknowledgeContinuation(
    input: SensitiveContinuationAckInput,
  ): Promise<SensitiveContinuationAckResult>;
}

export interface SensitiveResponseHandoffStore {
  transaction<T>(
    operation: (transaction: SensitiveResponseHandoffTransaction) => Promise<T>,
    options: SensitiveResponseTransactionOptions,
  ): Promise<T>;
}

export interface SensitiveResponseHandoffOptions {
  store: SensitiveResponseHandoffStore;
  crypto: EnvelopeCrypto;
  /** Separate 32-byte hex HMAC key; never the client or a database-readable verifier. */
  responseCommitmentKeyHex: string;
  clock?: () => Date;
  newId: () => string;
  leaseMs: number;
  /** Total attempts including the first; defaults to 8. */
  maxTransactionAttempts?: number;
  /** Linear retry base delay; defaults to zero for deterministic composition. */
  transactionRetryDelayMs?: number;
  sleep?: (milliseconds: number) => Promise<void>;
  wake?: (event: SensitiveHandoffEvent) => void | Promise<void>;
}

export interface SensitiveHandoffEvent {
  type: "sensitive_response_handoff";
  requestId: string;
  responseId: string;
  state: SensitiveHandoffState;
}

export interface SensitiveResponseDelivery {
  deliveryState: "delivered";
  continuationId: string;
}

export interface SensitiveResponseHandoff {
  accept(input: SensitiveResponseAcceptInput): Promise<SensitiveResponseReceipt | null>;
  get(input: {
    userId: string;
    requestId: string;
  }): Promise<SensitiveResponsePendingDto | null>;
  listPending(input: {
    userId: string;
    sessionId?: string;
  }): Promise<SensitiveResponsePendingDto[]>;
  claim(input: {
    requestId: string;
    worker: SensitiveResponseWorker;
  }): Promise<SensitiveResponseClaim | null>;
  deliver(input: {
    claim: SensitiveResponseClaim;
    worker: SensitiveResponseWorker;
  }): Promise<SensitiveResponseDelivery>;
  expire(input: {
    userId: string;
    requestId: string;
    version: number;
  }): Promise<SensitiveResponsePendingDto | null>;
  cancel(input: {
    userId: string;
    requestId: string;
    version: number;
  }): Promise<SensitiveResponsePendingDto | null>;
}

function invalidRequest(): SensitiveResponseHandoffError {
  return new SensitiveResponseHandoffError("invalid_request");
}

function requiredString(value: unknown): string {
  if (typeof value !== "string" || value.length === 0) throw invalidRequest();
  return value;
}

function positiveInteger(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw invalidRequest();
  }
  return value;
}

function normalizeJson(value: unknown, ancestors = new Set<object>()): unknown {
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw invalidRequest();
    return value;
  }
  if (typeof value !== "object") throw invalidRequest();
  const object = value as object;
  if (ancestors.has(object)) throw invalidRequest();
  ancestors.add(object);
  try {
    if (Array.isArray(value)) return value.map((entry) => normalizeJson(entry, ancestors));
    const prototype = Object.getPrototypeOf(value) as unknown;
    if (prototype !== Object.prototype && prototype !== null) throw invalidRequest();
    const result: SensitiveResponseJsonRecord = {};
    for (const key of Object.keys(value as SensitiveResponseJsonRecord).sort()) {
      Object.defineProperty(result, key, {
        value: normalizeJson((value as SensitiveResponseJsonRecord)[key], ancestors),
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

function jsonRecord(value: unknown): SensitiveResponseJsonRecord {
  try {
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      throw invalidRequest();
    }
    return normalizeJson(value) as SensitiveResponseJsonRecord;
  } catch (error) {
    if (error instanceof SensitiveResponseHandoffError) throw error;
    throw invalidRequest();
  }
}

function validDate(value: Date): Date {
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) throw invalidRequest();
  return new Date(value.getTime());
}

function parseCommitmentKey(value: string): Buffer {
  if (typeof value !== "string" || !/^[0-9a-fA-F]{64}$/.test(value)) {
    throw invalidRequest();
  }
  return Buffer.from(value, "hex");
}

function keyedCommitment(key: Buffer, canonical: string, recordId: string): string {
  return createHmac("sha256", key)
    .update("ovid-sensitive-response-commitment-v1\0", "utf8")
    .update(recordId, "utf8")
    .update("\0", "utf8")
    .update(canonical, "utf8")
    .digest("hex");
}

function commitmentEqual(left: unknown, right: unknown): boolean {
  if (typeof left !== "string" || typeof right !== "string" ||
    !/^[0-9a-f]{64}$/.test(left) || !/^[0-9a-f]{64}$/.test(right)) return false;
  return timingSafeEqual(Buffer.from(left, "hex"), Buffer.from(right, "hex"));
}

export function sensitiveResponseRecordId(binding: SensitiveResponseBinding): string {
  const parts = [
    requiredString(binding.requestId),
    requiredString(binding.userId),
    requiredString(binding.sessionId),
    requiredString(binding.runId),
    String(positiveInteger(binding.requestVersion)),
    requiredString(binding.responseId),
  ];
  return `sensitive-system-response-v1|${parts.map((part) => `${part.length}:${part}`).join("|")}`;
}

export function createSensitiveResponseCodec(
  crypto: EnvelopeCrypto,
  responseCommitmentKeyHex: string,
): SensitiveResponseCodec {
  const commitmentKey = parseCommitmentKey(responseCommitmentKeyHex);
  return {
    seal(response, binding) {
      const normalized = jsonRecord(response);
      const canonical = JSON.stringify(normalized);
      const recordId = sensitiveResponseRecordId(binding);
      const responseCommitment = keyedCommitment(commitmentKey, canonical, recordId);
      try {
        return { envelope: crypto.encrypt(canonical, recordId), responseCommitment };
      } catch {
        throw new SensitiveResponseHandoffError("sealed_response_invalid");
      }
    },

    unseal(sealed, binding) {
      try {
        if (sealed === null || typeof sealed !== "object" ||
          !/^[0-9a-f]{64}$/.test(sealed.responseCommitment)) {
          throw new Error("invalid sealed response");
        }
        const recordId = sensitiveResponseRecordId(binding);
        const plaintext = crypto.decrypt(sealed.envelope, recordId);
        const normalized = jsonRecord(JSON.parse(plaintext) as unknown);
        const expected = keyedCommitment(commitmentKey, JSON.stringify(normalized), recordId);
        if (!commitmentEqual(expected, sealed.responseCommitment)) {
          throw new Error("response commitment mismatch");
        }
        return normalized;
      } catch {
        throw new SensitiveResponseHandoffError("sealed_response_invalid");
      }
    },
  };
}

type Outcome<T> =
  | { ok: true; value: T; event?: SensitiveHandoffEvent }
  | { ok: false; code: SensitiveResponseHandoffErrorCode; event?: SensitiveHandoffEvent };

function success<T>(value: T, event?: SensitiveHandoffEvent): Outcome<T> {
  return event === undefined ? { ok: true, value } : { ok: true, value, event };
}

function failure<T>(
  code: SensitiveResponseHandoffErrorCode,
  event?: SensitiveHandoffEvent,
): Outcome<T> {
  return event === undefined ? { ok: false, code } : { ok: false, code, event };
}

type AcceptDecision =
  | { kind: "seal"; request: SensitiveResponseRequestRecord }
  | { kind: "receipt"; receipt: SensitiveResponseReceipt }
  | { kind: "not_found" };

type DeliveryLoad =
  | {
      kind: "work";
      request: SensitiveResponseRequestRecord;
      response: SensitiveResponseHandoffRecord;
    }
  | {
      kind: "delivered";
      request: SensitiveResponseRequestRecord;
      response: SensitiveResponseHandoffRecord;
    };

function eventFor(
  response: SensitiveResponseHandoffRecord,
  state: SensitiveHandoffState,
): SensitiveHandoffEvent {
  return {
    type: "sensitive_response_handoff",
    requestId: response.requestId,
    responseId: response.responseId,
    state,
  };
}

function pendingDto(row: SensitiveResponseRequestRecord): SensitiveResponsePendingDto {
  return {
    requestId: row.requestId,
    userId: row.userId,
    sessionId: row.sessionId,
    runId: row.runId,
    kind: row.kind,
    safePayload: jsonRecord(row.safePayload),
    sensitive: true,
    status: row.status,
    expiresAt: row.expiresAt.toISOString(),
    response: null,
    version: row.version,
  };
}

function receiptFor(row: SensitiveResponseHandoffRecord): SensitiveResponseReceipt {
  return {
    requestId: row.requestId,
    version: row.requestVersion,
    clientResponseId: row.clientResponseId,
    createdAt: row.createdAt.toISOString(),
    deliveryState: "awaiting_delivery",
  };
}

function bindingFor(
  request: SensitiveResponseRequestRecord,
  responseId: string,
  requestVersion: number,
): SensitiveResponseBinding {
  return {
    requestId: request.requestId,
    userId: request.userId,
    sessionId: request.sessionId,
    runId: request.runId,
    requestVersion,
    responseId,
  };
}

function continuationIdFor(responseId: string): string {
  return `sensitive-response:${responseId}`;
}

function sameLineage(
  request: SensitiveResponseRequestRecord,
  response: SensitiveResponseHandoffRecord,
  worker: SensitiveResponseWorker,
): boolean {
  return response.requestId === request.requestId && response.userId === request.userId &&
    request.userId === worker.userId && request.sessionId === worker.sessionId &&
    request.runId === worker.runId;
}

function stableClaimIdentity(
  request: SensitiveResponseRequestRecord,
  response: SensitiveResponseHandoffRecord,
  claim: SensitiveResponseClaim,
): boolean {
  return claim.requestVersion === response.requestVersion &&
    claim.requestExpiresAt === request.expiresAt.toISOString() &&
    claim.continuationId === continuationIdFor(response.responseId) &&
    commitmentEqual(claim.responseCommitment, response.responseCommitment);
}

function leaseClaimMatches(
  request: SensitiveResponseRequestRecord,
  response: SensitiveResponseHandoffRecord,
  claim: SensitiveResponseClaim,
  worker: SensitiveResponseWorker,
): boolean {
  const active = response.claim;
  return active !== null && claim.requestId === request.requestId &&
    claim.responseId === response.responseId && claim.claimId === active.claimId &&
    claim.claimGeneration === response.claimGeneration && active.workerId === worker.workerId &&
    claim.leaseExpiresAt === active.leaseExpiresAt.toISOString();
}

function claimMatches(
  request: SensitiveResponseRequestRecord,
  response: SensitiveResponseHandoffRecord,
  claim: SensitiveResponseClaim,
  worker: SensitiveResponseWorker,
): boolean {
  return leaseClaimMatches(request, response, claim, worker) &&
    stableClaimIdentity(request, response, claim);
}

function continuationBindingFor(
  request: SensitiveResponseRequestRecord,
  response: SensitiveResponseHandoffRecord,
): SensitiveContinuationBinding {
  const continuationId = continuationIdFor(response.responseId);
  return {
    idempotencyKey: continuationId,
    continuationId,
    requestId: request.requestId,
    userId: request.userId,
    sessionId: request.sessionId,
    runId: request.runId,
    responseId: response.responseId,
    requestVersion: response.requestVersion,
    responseCommitment: response.responseCommitment,
  };
}

function continuationAckBindingFor(
  request: SensitiveResponseRequestRecord,
  response: SensitiveResponseHandoffRecord,
  claim: SensitiveResponseClaim,
): SensitiveContinuationBinding {
  return {
    ...continuationBindingFor(request, response),
    idempotencyKey: claim.continuationId,
    continuationId: claim.continuationId,
    requestVersion: claim.requestVersion,
    responseCommitment: claim.responseCommitment,
  };
}

function continuationFenceFor(
  request: SensitiveResponseRequestRecord,
  response: SensitiveResponseHandoffRecord,
  claim: SensitiveResponseClaim,
  worker: SensitiveResponseWorker,
): SensitiveContinuationFence {
  if (response.claim === null) throw new SensitiveResponseHandoffError("stale_claim");
  return {
    claimId: claim.claimId,
    claimGeneration: claim.claimGeneration,
    workerId: worker.workerId,
    leaseExpiresAt: validDate(new Date(claim.leaseExpiresAt)),
    requestExpiresAt: validDate(new Date(claim.requestExpiresAt)),
    expectedRequestStatus: "pending",
    expectedHandoffState: "claimed",
  };
}

function continuationRefusalCode(
  kind: SensitiveContinuationRefusal,
): SensitiveResponseHandoffErrorCode {
  switch (kind) {
    case "conflict": return "response_conflict";
    case "stale_claim": return "stale_claim";
    case "request_expired": return "request_expired";
    case "request_not_pending": return "request_not_pending";
    case "not_found": return "not_found";
    case "continuation_unavailable": return "handoff_unavailable";
  }
}

export function createSensitiveResponseHandoff(
  options: SensitiveResponseHandoffOptions,
): SensitiveResponseHandoff {
  if (!Number.isSafeInteger(options.leaseMs) || options.leaseMs <= 0) {
    throw invalidRequest();
  }
  const maxAttempts = options.maxTransactionAttempts ?? 8;
  positiveInteger(maxAttempts);
  const retryDelay = options.transactionRetryDelayMs ?? 0;
  if (!Number.isSafeInteger(retryDelay) || retryDelay < 0) throw invalidRequest();
  const commitmentKey = parseCommitmentKey(options.responseCommitmentKeyHex);
  const clock = options.clock ?? (() => new Date());
  const sleep = options.sleep ?? (async (milliseconds: number) => {
    if (milliseconds > 0) await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
  });
  const codec = createSensitiveResponseCodec(options.crypto, options.responseCommitmentKeyHex);

  function now(): Date {
    return validDate(clock());
  }

  function nextId(): string {
    return requiredString(options.newId());
  }

  function contentCommitment(
    response: SensitiveResponseJsonRecord,
    binding: SensitiveResponseBinding,
  ): string {
    return keyedCommitment(
      commitmentKey,
      JSON.stringify(response),
      sensitiveResponseRecordId(binding),
    );
  }

  async function transact<T>(
    operation: (transaction: SensitiveResponseHandoffTransaction) => Promise<T>,
    transactionOptions: SensitiveResponseTransactionOptions,
    deliveryOutcomeMayBeUncertain = false,
  ): Promise<T> {
    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        return await options.store.transaction(operation, transactionOptions);
      } catch (error) {
        if (error instanceof SensitiveResponseHandoffError) throw error;
        const retryable = error instanceof SensitiveResponseTransactionRetryError;
        if (retryable && attempt < maxAttempts) {
          try {
            if (retryDelay > 0) await sleep(retryDelay * attempt);
          } catch {
            if (deliveryOutcomeMayBeUncertain) {
              throw new SensitiveResponseHandoffError("delivery_outcome_uncertain");
            }
            throw new SensitiveResponseHandoffError("handoff_unavailable");
          }
          continue;
        }
        if (deliveryOutcomeMayBeUncertain) {
          // Unknown commit result OR exhausted admission/ack retries: only a
          // same-binding replay can reconcile; never claim definite rollback.
          throw new SensitiveResponseHandoffError("delivery_outcome_uncertain");
        }
        if (retryable) throw new SensitiveResponseHandoffError("transaction_retry_exhausted");
        throw new SensitiveResponseHandoffError("handoff_unavailable");
      }
    }
    throw new SensitiveResponseHandoffError("handoff_unavailable");
  }

  async function notify(event: SensitiveHandoffEvent | undefined): Promise<void> {
    if (event === undefined || options.wake === undefined) return;
    try {
      await options.wake(event);
    } catch {
      // The durable row remains authoritative when a wake hint fails.
    }
  }

  async function finalize<T>(outcome: Outcome<T>): Promise<T> {
    await notify(outcome.event);
    if (!outcome.ok) throw new SensitiveResponseHandoffError(outcome.code);
    return outcome.value;
  }

  async function tombstone(
    tx: SensitiveResponseHandoffTransaction,
    response: SensitiveResponseHandoffRecord,
    state: "expired" | "cancelled",
    at: Date,
  ): Promise<boolean> {
    if (response.state === state && response.envelope === null) return false;
    const updated = await tx.transitionResponse(response.responseId, response.claimGeneration, {
      kind: state,
      tombstonedAt: at,
    });
    if (!updated) throw new SensitiveResponseHandoffError("stale_claim");
    return true;
  }

  async function terminate(
    tx: SensitiveResponseHandoffTransaction,
    request: SensitiveResponseRequestRecord,
    response: SensitiveResponseHandoffRecord | null,
    state: "expired" | "cancelled",
    at: Date,
  ): Promise<{ request: SensitiveResponseRequestRecord; changed: boolean }> {
    let nextRequest = request;
    let changed = false;
    if (request.status === "pending") {
      const updated = await tx.transitionRequest(request.requestId, request.version, state);
      if (!updated) throw new SensitiveResponseHandoffError("version_conflict");
      nextRequest = { ...request, status: state, version: request.version + 1 };
      changed = true;
    }
    if (response !== null && response.state !== "delivered") {
      changed = (await tombstone(tx, response, state, at)) || changed;
    }
    return { request: nextRequest, changed };
  }

  async function decideAccept(
    tx: SensitiveResponseHandoffTransaction,
    input: SensitiveResponseAcceptInput,
    normalized: SensitiveResponseJsonRecord,
    at: Date,
  ): Promise<Outcome<AcceptDecision>> {
    const request = await tx.getRequest(input.requestId);
    if (request === null || request.userId !== input.userId) {
      return success({ kind: "not_found" });
    }
    if (!request.sensitive) return failure("invalid_request");
    const existing = await tx.getResponseByRequest(input.requestId);
    const keyed = await tx.getResponseByClientResponseId(input.userId, input.clientResponseId);
    if (keyed !== null && keyed.requestId !== input.requestId) {
      return failure("client_response_conflict");
    }
    if (keyed !== null) {
      const expected = contentCommitment(
        normalized,
        bindingFor(request, keyed.responseId, input.version),
      );
      if (keyed.requestVersion !== input.version ||
        !commitmentEqual(keyed.responseCommitment, expected)) {
        return failure("response_conflict");
      }
    }
    if (existing !== null) {
      if (existing.requestVersion !== input.version) return failure("version_conflict");
      const expected = contentCommitment(
        normalized,
        bindingFor(request, existing.responseId, input.version),
      );
      if (!commitmentEqual(existing.responseCommitment, expected)) {
        return failure("response_conflict");
      }
      if (existing.userId !== request.userId) return failure("not_found");
      return success({ kind: "receipt", receipt: receiptFor(existing) });
    }
    if (keyed !== null) return failure("client_response_conflict");
    if (request.status === "expired") return failure("request_expired");
    if (request.status === "resolved") return failure("response_conflict");
    if (request.status !== "pending") return failure("request_not_pending");
    if (request.expiresAt.getTime() <= at.getTime()) {
      const updated = await tx.transitionRequest(request.requestId, request.version, "expired");
      if (!updated) throw new SensitiveResponseHandoffError("version_conflict");
      return failure("request_expired");
    }
    if (request.version !== input.version) return failure("version_conflict");
    return success({ kind: "seal", request });
  }

  async function loadDelivery(
    tx: SensitiveResponseHandoffTransaction,
    claim: SensitiveResponseClaim,
    worker: SensitiveResponseWorker,
    at: Date,
  ): Promise<Outcome<DeliveryLoad>> {
    const request = await tx.getRequest(claim.requestId);
    if (request === null) return failure("not_found");
    const response = await tx.getResponseByRequest(claim.requestId);
    if (response === null || !sameLineage(request, response, worker)) {
      return failure("not_found");
    }
    if (response.state === "delivered") {
      if (!leaseClaimMatches(request, response, claim, worker)) return failure("stale_claim");
      // Do not reconcile in the orchestrator: the ack port must compare the
      // caller's expected content/continuation identity with durable identity.
      return success({ kind: "delivered", request, response });
    }
    // Expected content and continuation identity are supplied on EVERY retry,
    // before unseal or a new admission. Delivered replay reaches the ack port.
    if (!stableClaimIdentity(request, response, claim)) return failure("response_conflict");
    if (request.status !== "expired" && request.status !== "pending") {
      return failure("request_not_pending");
    }
    if (request.status === "expired" || request.expiresAt.getTime() <= at.getTime()) {
      const terminated = await terminate(tx, request, response, "expired", at);
      return failure(
        "request_expired",
        terminated.changed ? eventFor(response, "expired") : undefined,
      );
    }
    if (response.state === "expired") return failure("request_expired");
    if (response.state === "cancelled") return failure("request_not_pending");
    if (request.version !== response.requestVersion) return failure("version_conflict");
    if (response.state !== "claimed") return failure("stale_claim");
    if (!claimMatches(request, response, claim, worker)) return failure("stale_claim");
    if (response.claim === null || response.claim.leaseExpiresAt.getTime() <= at.getTime()) {
      return failure("stale_claim");
    }
    if (response.envelope === null) return failure("handoff_unavailable");
    return success({ kind: "work", request, response });
  }

  async function acknowledge(
    request: SensitiveResponseRequestRecord,
    responseRecord: SensitiveResponseHandoffRecord,
    claim: SensitiveResponseClaim,
    worker: SensitiveResponseWorker,
    sealedResponse: SensitiveSealedResponse | null,
  ): Promise<SensitiveResponseDelivery> {
    const binding = continuationAckBindingFor(request, responseRecord, claim);
    const fence = continuationFenceFor(request, responseRecord, claim, worker);
    const acknowledged = await transact(
      (tx) => tx.acknowledgeContinuation({ binding, fence, sealedResponse }),
      { operation: "acknowledge", lockRequestId: claim.requestId },
      true,
    );
    if (acknowledged.kind !== "acknowledged" && acknowledged.kind !== "replayed") {
      throw new SensitiveResponseHandoffError(continuationRefusalCode(acknowledged.kind));
    }
    if (acknowledged.continuationId !== binding.continuationId) {
      throw new SensitiveResponseHandoffError("response_conflict");
    }
    await notify(eventFor(responseRecord, "delivered"));
    return { deliveryState: "delivered", continuationId: acknowledged.continuationId };
  }

  return {
    async accept(input) {
      requiredString(input.userId);
      requiredString(input.requestId);
      requiredString(input.clientResponseId);
      positiveInteger(input.version);
      const normalized = jsonRecord(input.response);
      const first = await finalize(await transact(
        (tx) => decideAccept(tx, input, normalized, now()),
        {
          operation: "accept",
          lockRequestId: input.requestId,
          lockClientResponse: {
            userId: input.userId,
            clientResponseId: input.clientResponseId,
          },
        },
      ));
      if (first.kind === "not_found") return null;
      if (first.kind === "receipt") return first.receipt;

      // Sealing occurs only after the first authorized fence. The commit
      // transaction repeats it and bounded retry preserves replay semantics.
      const responseId = nextId();
      const createdAt = now();
      const sealed = codec.seal(
        normalized,
        bindingFor(first.request, responseId, input.version),
      );
      const committed = await finalize(await transact(async (tx) => {
        const decision = await decideAccept(tx, input, normalized, now());
        if (!decision.ok || decision.value.kind !== "seal") return decision;
        if (decision.value.request.userId !== first.request.userId ||
          decision.value.request.sessionId !== first.request.sessionId ||
          decision.value.request.runId !== first.request.runId ||
          decision.value.request.version !== first.request.version) {
          return failure<AcceptDecision>("version_conflict");
        }
        const record: SensitiveResponseHandoffRecord = {
          responseId,
          requestId: input.requestId,
          userId: input.userId,
          requestVersion: input.version,
          clientResponseId: input.clientResponseId,
          responseCommitment: sealed.responseCommitment,
          envelope: sealed.envelope,
          state: "awaiting_delivery",
          claimGeneration: 0,
          claim: null,
          continuationId: null,
          createdAt,
          tombstonedAt: null,
        };
        await tx.insertAwaitingDelivery(record);
        return success<AcceptDecision>(
          { kind: "receipt", receipt: receiptFor(record) },
          eventFor(record, "awaiting_delivery"),
        );
      }, {
          operation: "accept",
          lockRequestId: input.requestId,
          lockClientResponse: {
            userId: input.userId,
            clientResponseId: input.clientResponseId,
          },
        }));
      if (committed.kind === "not_found") return null;
      if (committed.kind !== "receipt") {
        throw new SensitiveResponseHandoffError("handoff_unavailable");
      }
      return committed.receipt;
    },

    async get({ userId, requestId }) {
      requiredString(userId);
      requiredString(requestId);
      return finalize(await transact(async (tx) => {
        const request = await tx.getRequest(requestId);
        if (request === null || request.userId !== userId || !request.sensitive) {
          return success(null);
        }
        return success(pendingDto(request));
      }, { operation: "read" }));
    },

    async listPending({ userId, sessionId }) {
      requiredString(userId);
      if (sessionId !== undefined) requiredString(sessionId);
      const at = now();
      return finalize(await transact(async (tx) => {
        const requests = await tx.listRequests();
        return success(requests
          .filter((request) => request.sensitive && request.userId === userId &&
            (sessionId === undefined || request.sessionId === sessionId) &&
            request.status === "pending" && request.expiresAt.getTime() > at.getTime())
          .sort((a, b) => a.requestId.localeCompare(b.requestId))
          .map(pendingDto));
      }, { operation: "read" }));
    },

    async claim({ requestId, worker }) {
      requiredString(requestId);
      requiredString(worker.workerId);
      requiredString(worker.userId);
      requiredString(worker.sessionId);
      requiredString(worker.runId);
      return finalize(await transact(async (tx) => {
        const at = now();
        const request = await tx.getRequest(requestId);
        if (request === null || !request.sensitive) return success(null);
        const response = await tx.getResponseByRequest(requestId);
        if (response === null || !sameLineage(request, response, worker)) {
          return success(null);
        }
        if (request.status !== "expired" && request.status !== "pending") {
          return failure("request_not_pending");
        }
        if (request.status === "expired" || request.expiresAt.getTime() <= at.getTime()) {
          const terminated = await terminate(tx, request, response, "expired", at);
          return failure(
            "request_expired",
            terminated.changed ? eventFor(response, "expired") : undefined,
          );
        }
        if (response.state === "expired") return failure("request_expired");
        if (response.state === "cancelled" || response.state === "delivered") {
          return failure("request_not_pending");
        }
        if (request.version !== response.requestVersion) return failure("version_conflict");
        if (response.state !== "awaiting_delivery" && response.state !== "claimed") {
          return failure("handoff_unavailable");
        }
        if (response.envelope === null) return failure("handoff_unavailable");
        if (response.claim !== null && response.claim.leaseExpiresAt.getTime() > at.getTime()) {
          return failure("active_claim");
        }

        const claimId = nextId();
        const generation = response.claimGeneration + 1;
        const leaseExpiresAt = new Date(at.getTime() + options.leaseMs);
        const claimRecord = { claimId, workerId: worker.workerId, leaseExpiresAt };
        const updated = await tx.transitionResponse(response.responseId, response.claimGeneration, {
          kind: "claim",
          claimGeneration: generation,
          claim: claimRecord,
        });
        if (!updated) throw new SensitiveResponseHandoffError("stale_claim");
        const claimed = {
          ...response,
          state: "claimed" as const,
          claimGeneration: generation,
          claim: claimRecord,
        };
        return success({
          requestId,
          responseId: response.responseId,
          claimId,
          claimGeneration: generation,
          leaseExpiresAt: leaseExpiresAt.toISOString(),
          requestVersion: response.requestVersion,
          requestExpiresAt: request.expiresAt.toISOString(),
          responseCommitment: response.responseCommitment,
          continuationId: continuationIdFor(response.responseId),
        }, eventFor(claimed, "claimed"));
      }, { operation: "claim", lockRequestId: requestId }));
    },

    async deliver({ claim, worker }) {
      requiredString(worker.workerId);
      requiredString(worker.userId);
      requiredString(worker.sessionId);
      requiredString(worker.runId);
      requiredString(claim.requestId);
      requiredString(claim.responseId);
      requiredString(claim.claimId);
      positiveInteger(claim.claimGeneration);
      positiveInteger(claim.requestVersion);
      requiredString(claim.leaseExpiresAt);
      requiredString(claim.requestExpiresAt);
      requiredString(claim.responseCommitment);
      requiredString(claim.continuationId);
      validDate(new Date(claim.leaseExpiresAt));
      validDate(new Date(claim.requestExpiresAt));

      const loaded = await finalize(await transact(
        (tx) => loadDelivery(tx, claim, worker, now()),
        { operation: "delivery_load", lockRequestId: claim.requestId },
      ));
      if (loaded.kind === "delivered") {
        return acknowledge(loaded.request, loaded.response, claim, worker, null);
      }

      const sealedResponse: SensitiveSealedResponse = {
        envelope: loaded.response.envelope!,
        responseCommitment: loaded.response.responseCommitment,
      };
      // Authenticate before admission, but never pass plaintext to the store.
      // The canonical durable record retains this exact sealed value instead.
      codec.unseal(sealedResponse, bindingFor(
        loaded.request,
        loaded.response.responseId,
        loaded.response.requestVersion,
      ));
      const binding = continuationBindingFor(loaded.request, loaded.response);
      const fence = continuationFenceFor(loaded.request, loaded.response, claim, worker);

      // No unguarded callback exists. The store adapter must re-fence and
      // first-writer-wins admit atomically at its own database clock, even if
      // this worker paused after the load above. Unknown outcomes are retried
      // with this identical deterministic binding.
      const admitted = await transact(
        (tx) => tx.admitContinuation({ binding, fence, sealedResponse }),
        { operation: "admit_continuation", lockRequestId: claim.requestId },
        true,
      );
      if (admitted.kind !== "admitted" && admitted.kind !== "replayed") {
        throw new SensitiveResponseHandoffError(continuationRefusalCode(admitted.kind));
      }
      if (admitted.continuationId !== binding.continuationId) {
        throw new SensitiveResponseHandoffError("response_conflict");
      }

      return acknowledge(loaded.request, loaded.response, claim, worker, sealedResponse);
    },

    async expire({ userId, requestId, version }) {
      requiredString(userId);
      requiredString(requestId);
      positiveInteger(version);
      return finalize(await transact(async (tx) => {
        const request = await tx.getRequest(requestId);
        if (request === null || request.userId !== userId || !request.sensitive) {
          return success(null);
        }
        const response = await tx.getResponseByRequest(requestId);
        if (request.status === "expired") {
          if (version !== request.version && version !== request.version - 1) {
            return failure("version_conflict");
          }
          const terminated = await terminate(tx, request, response, "expired", now());
          return success(
            pendingDto(terminated.request),
            terminated.changed && response !== null ? eventFor(response, "expired") : undefined,
          );
        }
        if (request.status !== "pending") return failure("request_not_pending");
        if (request.version !== version) return failure("version_conflict");
        const at = now();
        if (request.expiresAt.getTime() > at.getTime()) return failure("request_not_expired");
        const terminated = await terminate(tx, request, response, "expired", at);
        return success(
          pendingDto(terminated.request),
          response !== null ? eventFor(response, "expired") : undefined,
        );
      }, { operation: "expire", lockRequestId: requestId }));
    },

    async cancel({ userId, requestId, version }) {
      requiredString(userId);
      requiredString(requestId);
      positiveInteger(version);
      return finalize(await transact(async (tx) => {
        const request = await tx.getRequest(requestId);
        if (request === null || request.userId !== userId || !request.sensitive) {
          return success(null);
        }
        const response = await tx.getResponseByRequest(requestId);
        if (request.status === "cancelled") {
          if (version !== request.version && version !== request.version - 1) {
            return failure("version_conflict");
          }
          const terminated = await terminate(tx, request, response, "cancelled", now());
          return success(
            pendingDto(terminated.request),
            terminated.changed && response !== null ? eventFor(response, "cancelled") : undefined,
          );
        }
        if (request.status !== "pending") return failure("request_not_pending");
        if (request.version !== version) return failure("version_conflict");
        const terminated = await terminate(tx, request, response, "cancelled", now());
        return success(
          pendingDto(terminated.request),
          response !== null ? eventFor(response, "cancelled") : undefined,
        );
      }, { operation: "cancel", lockRequestId: requestId }));
    },
  };
}
