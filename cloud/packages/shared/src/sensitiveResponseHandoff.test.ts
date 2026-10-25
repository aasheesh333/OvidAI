/**
 * FIX ROUND 1+2 plus round-3 I5/I6 regressions are UNEXECUTED under HEAVY-COMMANDS-PAUSED.md.
 * This race-capable adapter is a contract fake, not real durability or proof
 * of exactly-once external model/tool effects. Those remain BLOCKED.
 */
import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  createEnvelopeCrypto,
  type EncryptedEnvelope,
} from "../../escrow/src/envelope.js";
import {
  createSensitiveResponseCodec,
  createSensitiveResponseHandoff,
  SensitiveResponseHandoffError,
  SensitiveResponseTransactionRetryError,
  type SensitiveContinuationAckInput,
  type SensitiveContinuationAdmissionInput,
  type SensitiveContinuationAdmissionResult,
  type SensitiveContinuationAckResult,
  type SensitiveCanonicalContinuationRecord,
  type SensitiveContinuationRecord,
  type SensitiveHandoffEvent,
  type SensitiveResponseClaim,
  type SensitiveResponseHandoffRecord,
  type SensitiveResponseHandoffStore,
  type SensitiveResponseHandoffTransaction,
  type SensitiveResponseRequestRecord,
  type SensitiveResponseTransactionOptions,
  type SensitiveSealedResponse,
  type SensitiveResponseTransition,
  type SensitiveResponseWorker,
} from "./sensitiveResponseHandoff.js";

const KEY = "a".repeat(64);
const COMMITMENT_KEY = "c".repeat(64);
const OTHER_COMMITMENT_KEY = "d".repeat(64);
const T0 = new Date("2026-10-24T12:00:00.000Z");
const CANARY = "phase-a-canary-7f4c9a-secret-never-serialize";
const RESPONSE = { action: "accept", content: { password: CANARY } };
const BINDING = {
  requestId: "request-1",
  userId: "user-1",
  sessionId: "session-1",
  runId: "run-1",
  requestVersion: 1,
  responseId: "response-1",
} as const;
const WORKER: SensitiveResponseWorker = {
  workerId: "worker-1",
  userId: "user-1",
  sessionId: "session-1",
  runId: "run-1",
};

interface MemoryData {
  requests: Map<string, SensitiveResponseRequestRecord>;
  responses: Map<string, SensitiveResponseHandoffRecord>;
  continuations: Map<string, SensitiveContinuationRecord>;
  canonicalContinuations: Map<string, SensitiveCanonicalContinuationRecord>;
}

interface MemoryBacking {
  data: MemoryData;
  requestRevisions: Map<string, number>;
  responseRevisions: Map<string, number>;
  continuationDurableWrites: number;
  durableLog: string[];
  lockOrder: string[];
  effectObservations: Array<{
    continuationId: string;
    admissionCommitted: boolean;
    canonicalCommitted: boolean;
  }>;
}

interface Gate {
  reached: Promise<void>;
  arrive(): Promise<void>;
  release(): void;
}

function gate(participants: number): Gate {
  let arrived = 0;
  let opened = false;
  let reach!: () => void;
  let open!: () => void;
  const reached = new Promise<void>((resolve) => { reach = resolve; });
  const released = new Promise<void>((resolve) => { open = resolve; });
  return {
    reached,
    async arrive() {
      arrived += 1;
      if (arrived === participants) reach();
      await released;
    },
    release() {
      if (!opened) {
        opened = true;
        open();
      }
    },
  };
}

function continuationId(responseId: string): string {
  return `sensitive-response:${responseId}`;
}

function sealedFromResponse(row: SensitiveResponseHandoffRecord): SensitiveSealedResponse {
  if (row.envelope === null) throw new Error("expected a sealed handoff value");
  return structuredClone({
    envelope: row.envelope,
    responseCommitment: row.responseCommitment,
  });
}

function requestScope(requestId: string): string {
  return `request:${requestId}`;
}

function clientScope(userId: string, clientResponseId: string): string {
  return `client:${userId}:${clientResponseId}`;
}

function sealedValueEquals(
  left: SensitiveSealedResponse | null,
  right: SensitiveSealedResponse | null,
): boolean {
  if (left === null || right === null) return left === right;
  return left.responseCommitment === right.responseCommitment &&
    left.envelope.wrappedDek === right.envelope.wrappedDek &&
    left.envelope.iv === right.envelope.iv &&
    left.envelope.ciphertext === right.envelope.ciphertext &&
    left.envelope.tag === right.envelope.tag;
}

type PersistedPair =
  | { kind: "missing" }
  | { kind: "unavailable" | "conflict" }
  | {
      kind: "match";
      admission: SensitiveContinuationRecord;
      canonical: SensitiveCanonicalContinuationRecord;
    };

function persistedPair(
  data: MemoryData,
  binding: SensitiveContinuationRecord["binding"],
): PersistedPair {
  const admission = data.continuations.get(binding.idempotencyKey);
  const canonical = data.canonicalContinuations.get(binding.continuationId);
  if (admission === undefined && canonical === undefined) return { kind: "missing" };
  if (admission === undefined || canonical === undefined) return { kind: "unavailable" };
  if (!continuationBindingEquals(admission.binding, binding) ||
    !continuationBindingEquals(canonical.binding, binding)) {
    return { kind: "conflict" };
  }
  if (admission.state !== canonical.state ||
    admission.sealedResponse === null || canonical.sealedResponse === null ||
    !sealedValueEquals(admission.sealedResponse, canonical.sealedResponse)) {
    return { kind: "unavailable" };
  }
  return { kind: "match", admission, canonical };
}

function freshBacking(): MemoryBacking {
  return {
    data: {
      requests: new Map(),
      responses: new Map(),
      continuations: new Map(),
      canonicalContinuations: new Map(),
    },
    requestRevisions: new Map(),
    responseRevisions: new Map(),
    continuationDurableWrites: 0,
    durableLog: [],
    lockOrder: [],
    effectObservations: [],
  };
}

function stableBindingMatches(
  input: SensitiveContinuationAdmissionInput | SensitiveContinuationAckInput,
  request: SensitiveResponseRequestRecord | undefined,
  response: SensitiveResponseHandoffRecord | undefined,
): boolean {
  const b = input.binding;
  return request !== undefined && response !== undefined &&
    b.requestId === request.requestId && b.userId === request.userId &&
    b.sessionId === request.sessionId && b.runId === request.runId &&
    b.requestVersion === response.requestVersion &&
    b.responseId === response.responseId && b.responseCommitment === response.responseCommitment &&
    b.continuationId === continuationId(response.responseId) &&
    b.idempotencyKey === b.continuationId;
}

function claimFenceMatches(
  input: SensitiveContinuationAdmissionInput | SensitiveContinuationAckInput,
  request: SensitiveResponseRequestRecord,
  response: SensitiveResponseHandoffRecord,
): boolean {
  const f = input.fence;
  const claim = response.claim;
  return claim !== null && f.claimId === claim.claimId &&
    f.claimGeneration === response.claimGeneration && f.workerId === claim.workerId &&
    f.leaseExpiresAt.getTime() === claim.leaseExpiresAt.getTime() &&
    f.requestExpiresAt.getTime() === request.expiresAt.getTime();
}

class MemoryTransaction implements SensitiveResponseHandoffTransaction {
  readonly operations: Array<(data: MemoryData) => void> = [];
  readonly readRequestIds = new Set<string>();
  readonly requestWrites = new Set<string>();
  readonly readResponseScopes = new Set<string>();
  readonly responseWriteScopes = new Set<string>();
  hasResponseInsert = false;
  hasContinuationInsert = false;
  continuationWriteId: string | null = null;
  ackWrite: string | null = null;

  constructor(
    readonly data: MemoryData,
    private readonly owner: MemoryStore,
    readonly startRequestRevisions: Map<string, number>,
    readonly startResponseRevisions: Map<string, number>,
    private readonly requiredClientScope: string | null,
    private readonly requiredRequestScope: string | null,
  ) {}

  async getRequest(requestId: string): Promise<SensitiveResponseRequestRecord | null> {
    if (this.requiredRequestScope !== null &&
      this.requiredRequestScope !== requestScope(requestId)) {
      throw new Error("request read outside declared lock scope");
    }
    this.readRequestIds.add(requestId);
    const value = this.data.requests.get(requestId);
    return value === undefined ? null : structuredClone(value);
  }

  async listRequests(): Promise<SensitiveResponseRequestRecord[]> {
    return structuredClone([...this.data.requests.values()]);
  }

  async getResponseByRequest(requestId: string): Promise<SensitiveResponseHandoffRecord | null> {
    if (this.requiredRequestScope !== null &&
      this.requiredRequestScope !== requestScope(requestId)) {
      throw new Error("response read outside declared request lock scope");
    }
    this.readResponseScopes.add(requestScope(requestId));
    const value = [...this.data.responses.values()].find((row) => row.requestId === requestId);
    return value === undefined ? null : structuredClone(value);
  }

  async getResponseByClientResponseId(
    userId: string,
    clientResponseId: string,
  ): Promise<SensitiveResponseHandoffRecord | null> {
    const scope = clientScope(userId, clientResponseId);
    if (this.requiredClientScope === null || this.requiredClientScope !== scope) {
      throw new Error("client-response read without its declared ordered lock");
    }
    this.readResponseScopes.add(scope);
    const value = [...this.data.responses.values()].find(
      (row) => row.userId === userId && row.clientResponseId === clientResponseId,
    );
    return value === undefined ? null : structuredClone(value);
  }

  private stage(operation: (data: MemoryData) => void): void {
    operation(this.data);
    this.operations.push(operation);
  }

  async insertAwaitingDelivery(record: SensitiveResponseHandoffRecord): Promise<void> {
    if (this.requiredClientScope !== clientScope(record.userId, record.clientResponseId) ||
      this.requiredRequestScope !== requestScope(record.requestId)) {
      throw new Error("awaiting_delivery insert outside ordered lock scopes");
    }
    if (record.state !== "awaiting_delivery" || record.envelope === null ||
      record.claimGeneration !== 0 || record.claim !== null || record.continuationId !== null) {
      throw new Error("illegal awaiting_delivery insert");
    }
    this.readResponseScopes.add(requestScope(record.requestId));
    this.readResponseScopes.add(clientScope(record.userId, record.clientResponseId));
    this.responseWriteScopes.add(requestScope(record.requestId));
    this.responseWriteScopes.add(clientScope(record.userId, record.clientResponseId));
    this.hasResponseInsert = true;
    this.stage((data) => {
      if (data.responses.has(record.responseId) ||
        [...data.responses.values()].some((row) => row.requestId === record.requestId ||
          (row.userId === record.userId && row.clientResponseId === record.clientResponseId))) {
        throw new SensitiveResponseTransactionRetryError();
      }
      data.responses.set(record.responseId, structuredClone(record));
    });
  }

  async transitionRequest(
    requestId: string,
    expectedVersion: number,
    target: "expired" | "cancelled",
  ): Promise<boolean> {
    const row = this.data.requests.get(requestId);
    if (row === undefined || row.version !== expectedVersion || row.status !== "pending") return false;
    this.readRequestIds.add(requestId);
    this.requestWrites.add(requestId);
    this.stage((data) => {
      const current = data.requests.get(requestId);
      if (current === undefined || current.version !== expectedVersion || current.status !== "pending") {
        throw new SensitiveResponseTransactionRetryError();
      }
      data.requests.set(requestId, { ...current, status: target, version: expectedVersion + 1 });
    });
    return true;
  }

  async transitionResponse(
    responseId: string,
    expectedClaimGeneration: number,
    transition: SensitiveResponseTransition,
  ): Promise<boolean> {
    const row = this.data.responses.get(responseId);
    if (row === undefined || row.claimGeneration !== expectedClaimGeneration) return false;
    this.readResponseScopes.add(requestScope(row.requestId));
    if (transition.kind === "claim") {
      if ((row.state !== "awaiting_delivery" && row.state !== "claimed") ||
        row.envelope === null || transition.claimGeneration !== expectedClaimGeneration + 1) return false;
      this.responseWriteScopes.add(requestScope(row.requestId));
      this.stage((data) => {
        const current = data.responses.get(responseId);
        if (current === undefined || current.claimGeneration !== expectedClaimGeneration) {
          throw new SensitiveResponseTransactionRetryError();
        }
        data.responses.set(responseId, {
          ...current,
          state: "claimed",
          claimGeneration: transition.claimGeneration,
          claim: structuredClone(transition.claim),
        });
      });
      return true;
    }
    if (row.state !== "awaiting_delivery" && row.state !== "claimed") return false;
    this.responseWriteScopes.add(requestScope(row.requestId));
    this.stage((data) => {
      const current = data.responses.get(responseId);
      if (current === undefined || current.claimGeneration !== expectedClaimGeneration) {
        throw new SensitiveResponseTransactionRetryError();
      }
      data.responses.set(responseId, {
        ...current,
        state: transition.kind,
        envelope: null,
        continuationId: null,
        tombstonedAt: transition.tombstonedAt,
      });
      for (const [key, continuation] of data.continuations) {
        if (continuation.binding.responseId === responseId && continuation.state !== "cancelled") {
          data.continuations.set(key, {
            ...continuation,
            state: "cancelled",
            sealedResponse: null,
          });
        }
      }
      for (const [key, canonical] of data.canonicalContinuations) {
        if (canonical.binding.responseId === responseId && canonical.state !== "cancelled") {
          data.canonicalContinuations.set(key, {
            ...canonical,
            state: "cancelled",
            sealedResponse: null,
          });
        }
      }
    });
    return true;
  }

  async admitContinuation(
    input: SensitiveContinuationAdmissionInput,
  ): Promise<SensitiveContinuationAdmissionResult> {
    this.owner.admissionAttempts += 1;
    const hook = this.owner.beforeAdmission;
    if (hook !== undefined) await hook();
    const at = this.owner.now();
    const b = input.binding;
    const f = input.fence;
    this.readRequestIds.add(b.requestId);
    this.readResponseScopes.add(requestScope(b.requestId));
    this.owner.admissionFences.push(structuredClone({ binding: b, fence: f }));
    this.owner.admissionSealedValues.push(structuredClone(input.sealedResponse));
    const request = this.data.requests.get(b.requestId);
    const response = [...this.data.responses.values()].find((row) => row.responseId === b.responseId);
    if (request === undefined || response === undefined) return { kind: "not_found" };
    if (!stableBindingMatches(input, request, response)) return { kind: "conflict" };
    const pair = persistedPair(this.data, b);

    if (response.state === "delivered") {
      if (pair.kind === "conflict") return { kind: "conflict" };
      if (pair.kind !== "match") return { kind: "continuation_unavailable" };
      if (!sealedValueEquals(pair.admission.sealedResponse, input.sealedResponse)) {
        return { kind: "conflict" };
      }
      if (request.status === "resolved" && request.version === b.requestVersion + 1 &&
        claimFenceMatches(input, request, response) && pair.admission.state === "ready" &&
        pair.canonical.state === "ready" && response.continuationId === b.continuationId) {
        return { kind: "replayed", continuationId: pair.admission.binding.continuationId };
      }
      return { kind: "stale_claim" };
    }
    if (request.status === "expired" || response.state === "expired") {
      return { kind: "request_expired" };
    }
    if (request.status !== "pending" || response.state === "cancelled") {
      return { kind: "request_not_pending" };
    }
    if (request.version !== b.requestVersion) return { kind: "conflict" };
    if (request.expiresAt.getTime() <= at.getTime()) return { kind: "request_expired" };
    if (response.state !== "claimed" || f.expectedRequestStatus !== "pending" ||
      f.expectedHandoffState !== "claimed" || !claimFenceMatches(input, request, response) ||
      response.claim!.leaseExpiresAt.getTime() <= at.getTime()) {
      return { kind: "stale_claim" };
    }
    if (pair.kind === "conflict") return { kind: "conflict" };
    if (pair.kind === "unavailable") return { kind: "continuation_unavailable" };
    if (pair.kind === "match") {
      if (pair.admission.state === "cancelled") return { kind: "request_not_pending" };
      if (pair.admission.state !== "held" || pair.canonical.state !== "held") {
        return { kind: "continuation_unavailable" };
      }
      if (!sealedValueEquals(pair.admission.sealedResponse, input.sealedResponse)) {
        return { kind: "conflict" };
      }
      return { kind: "replayed", continuationId: pair.admission.binding.continuationId };
    }

    const record: SensitiveContinuationRecord = {
      binding: structuredClone(b),
      sealedResponse: structuredClone(input.sealedResponse),
      state: "held",
      admittedAt: at,
      firstClaimId: f.claimId,
      firstClaimGeneration: f.claimGeneration,
    };
    this.responseWriteScopes.add(requestScope(b.requestId));
    this.hasContinuationInsert = true;
    this.continuationWriteId = b.continuationId;
    this.stage((data) => {
      if (data.continuations.has(b.idempotencyKey) ||
        data.canonicalContinuations.has(b.continuationId)) {
        throw new SensitiveResponseTransactionRetryError();
      }
      // Both durable records retain the same sealed value. The fake's only
      // effect observation is emitted after commit sees both records.
      data.continuations.set(b.idempotencyKey, structuredClone(record));
      data.canonicalContinuations.set(b.continuationId, {
        continuationId: b.continuationId,
        binding: structuredClone(b),
        sealedResponse: structuredClone(input.sealedResponse),
        state: "held",
        admittedAt: at,
      });
    });
    return { kind: "admitted", continuationId: b.continuationId };
  }

  async acknowledgeContinuation(
    input: SensitiveContinuationAckInput,
  ): Promise<SensitiveContinuationAckResult> {
    this.owner.ackAttempts += 1;
    const at = this.owner.now();
    const b = input.binding;
    const f = input.fence;
    this.readRequestIds.add(b.requestId);
    this.readResponseScopes.add(requestScope(b.requestId));
    const request = this.data.requests.get(b.requestId);
    const response = [...this.data.responses.values()].find((row) => row.responseId === b.responseId);
    if (request === undefined || response === undefined) return { kind: "not_found" };
    if (!stableBindingMatches(input, request, response)) return { kind: "conflict" };
    const pair = persistedPair(this.data, b);

    if (response.state === "delivered") {
      if (pair.kind === "conflict") return { kind: "conflict" };
      if (pair.kind !== "match") return { kind: "continuation_unavailable" };
      if (input.sealedResponse !== null &&
        !sealedValueEquals(pair.admission.sealedResponse, input.sealedResponse)) {
        return { kind: "conflict" };
      }
      if (request.status === "resolved" && request.version === b.requestVersion + 1 &&
        claimFenceMatches(input, request, response) &&
        response.continuationId === b.continuationId && pair.admission.state === "ready" &&
        pair.canonical.state === "ready") {
        this.owner.readyAckInputs.push(
          input.sealedResponse === null ? null : structuredClone(input.sealedResponse),
        );
        return { kind: "replayed", continuationId: b.continuationId };
      }
      return { kind: "stale_claim" };
    }
    if (request.status === "expired" || response.state === "expired") {
      return { kind: "request_expired" };
    }
    if (request.status !== "pending" || response.state === "cancelled") {
      return { kind: "request_not_pending" };
    }
    if (request.version !== b.requestVersion) return { kind: "conflict" };
    if (request.expiresAt.getTime() <= at.getTime()) return { kind: "request_expired" };
    if (response.state !== "claimed" || f.expectedRequestStatus !== "pending" ||
      f.expectedHandoffState !== "claimed" || !claimFenceMatches(input, request, response) ||
      response.claim!.leaseExpiresAt.getTime() <= at.getTime()) {
      return { kind: "stale_claim" };
    }
    if (pair.kind === "conflict") return { kind: "conflict" };
    if (pair.kind !== "match") return { kind: "continuation_unavailable" };
    if (input.sealedResponse === null) return { kind: "continuation_unavailable" };
    if (!sealedValueEquals(pair.admission.sealedResponse, input.sealedResponse)) {
      return { kind: "conflict" };
    }
    if (pair.admission.state !== "held" || pair.canonical.state !== "held") {
      return { kind: "continuation_unavailable" };
    }

    this.requestWrites.add(b.requestId);
    this.responseWriteScopes.add(requestScope(b.requestId));
    this.ackWrite = b.continuationId;
    this.stage((data) => {
      const currentRequest = data.requests.get(b.requestId);
      const currentResponse = data.responses.get(b.responseId);
      const currentPair = persistedPair(data, b);
      if (currentRequest === undefined || currentResponse === undefined ||
        currentPair.kind !== "match" || currentRequest.version !== b.requestVersion ||
        currentRequest.status !== "pending" || currentResponse.claimGeneration !== f.claimGeneration ||
        currentResponse.state !== "claimed" || currentPair.admission.state !== "held" ||
        currentPair.canonical.state !== "held" ||
        !sealedValueEquals(currentPair.admission.sealedResponse, input.sealedResponse)) {
        throw new SensitiveResponseTransactionRetryError();
      }
      data.requests.set(b.requestId, {
        ...currentRequest,
        status: "resolved",
        version: b.requestVersion + 1,
      });
      data.responses.set(b.responseId, {
        ...currentResponse,
        state: "delivered",
        envelope: null,
        continuationId: b.continuationId,
        tombstonedAt: at,
      });
      data.continuations.set(b.idempotencyKey, {
        ...currentPair.admission,
        state: "ready",
      });
      data.canonicalContinuations.set(b.continuationId, {
        ...currentPair.canonical,
        state: "ready",
      });
    });
    return { kind: "acknowledged", continuationId: b.continuationId };
  }
}

function continuationBindingEquals(
  left: SensitiveContinuationRecord["binding"],
  right: SensitiveContinuationRecord["binding"],
): boolean {
  return left.idempotencyKey === right.idempotencyKey &&
    left.continuationId === right.continuationId && left.requestId === right.requestId &&
    left.userId === right.userId && left.sessionId === right.sessionId &&
    left.runId === right.runId && left.responseId === right.responseId &&
    left.requestVersion === right.requestVersion &&
    left.responseCommitment === right.responseCommitment;
}

class MemoryStore implements SensitiveResponseHandoffStore {
  admissionAttempts = 0;
  ackAttempts = 0;
  retryCount = 0;
  transactionAttempts = 0;
  forcedRetries = 0;
  beforeAdmission?: () => void | Promise<void>;
  beforeAcknowledgeTransaction?: () => void | Promise<void>;
  readonly admissionFences: Array<{
    binding: SensitiveContinuationAdmissionInput["binding"];
    fence: SensitiveContinuationAdmissionInput["fence"];
  }> = [];
  readonly admissionSealedValues: SensitiveSealedResponse[] = [];
  readonly readyAckInputs: Array<SensitiveSealedResponse | null> = [];
  private responseInsertGate?: Gate;
  private continuationInsertGate?: Gate;
  private acknowledgeTransactionGate?: Gate;
  private failBefore?: { operation: string; error: Error };
  private failAfter?: { operation: string; error: Error };

  constructor(
    private readonly clock: () => Date,
    private readonly backing: MemoryBacking = freshBacking(),
  ) {}

  now(): Date {
    return new Date(this.clock().getTime());
  }

  freshAdapter(): MemoryStore {
    return new MemoryStore(this.clock, this.backing);
  }

  async transaction<T>(
    operation: (transaction: SensitiveResponseHandoffTransaction) => Promise<T>,
    options: SensitiveResponseTransactionOptions,
  ): Promise<T> {
    try {
      this.transactionAttempts += 1;
      if (options.operation === "acknowledge" && this.beforeAcknowledgeTransaction !== undefined) {
        await this.beforeAcknowledgeTransaction();
      }
      if (options.operation === "acknowledge" && this.acknowledgeTransactionGate !== undefined) {
        await this.acknowledgeTransactionGate.arrive();
      }
      const requiredClientScope = options.operation === "accept"
        ? clientScope(
            options.lockClientResponse.userId,
            options.lockClientResponse.clientResponseId,
          )
        : null;
      const requiredRequestScope = options.lockRequestId === undefined
        ? null
        : requestScope(options.lockRequestId);
      if (requiredClientScope !== null) this.backing.lockOrder.push(requiredClientScope);
      if (requiredRequestScope !== null) this.backing.lockOrder.push(requiredRequestScope);
      const tx = new MemoryTransaction(
        structuredClone(this.backing.data),
        this,
        new Map(this.backing.requestRevisions),
        new Map(this.backing.responseRevisions),
        requiredClientScope,
        requiredRequestScope,
      );
      const value = await operation(tx);
      if (tx.hasResponseInsert && this.responseInsertGate !== undefined) {
        await this.responseInsertGate.arrive();
      }
      if (tx.hasContinuationInsert && this.continuationInsertGate !== undefined) {
        await this.continuationInsertGate.arrive();
      }
      if (this.failBefore?.operation === options.operation) {
        const error = this.failBefore.error;
        this.failBefore = undefined;
        throw error;
      }
      if (this.forcedRetries > 0) {
        this.forcedRetries -= 1;
        throw new SensitiveResponseTransactionRetryError();
      }
      if (options.lockRequestId !== undefined) {
        for (const requestId of tx.readRequestIds) {
          if ((this.backing.requestRevisions.get(requestId) ?? 0) !==
            (tx.startRequestRevisions.get(requestId) ?? 0)) {
            throw new SensitiveResponseTransactionRetryError();
          }
        }
        for (const scope of tx.readResponseScopes) {
          if ((this.backing.responseRevisions.get(scope) ?? 0) !==
            (tx.startResponseRevisions.get(scope) ?? 0)) {
            throw new SensitiveResponseTransactionRetryError();
          }
        }
      }

      // Apply to a clone, then swap once. Callbacks are never globally queued;
      // overlapping snapshots conflict in their own lineage/key scopes.
      const next = structuredClone(this.backing.data);
      for (const apply of tx.operations) apply(next);
      if (tx.hasContinuationInsert) {
        const admitted = next.continuations.get(tx.continuationWriteId!);
        const canonical = next.canonicalContinuations.get(tx.continuationWriteId!);
        if (admitted === undefined || canonical === undefined ||
          admitted.state !== "held" || canonical.state !== "held" ||
          !sealedValueEquals(admitted.sealedResponse, canonical.sealedResponse)) {
          throw new Error("sealed canonical admission was not atomically staged");
        }
      }
      this.backing.data = next;
      for (const requestId of tx.requestWrites) {
        this.backing.requestRevisions.set(
          requestId,
          (this.backing.requestRevisions.get(requestId) ?? 0) + 1,
        );
      }
      for (const scope of tx.responseWriteScopes) {
        this.backing.responseRevisions.set(
          scope,
          (this.backing.responseRevisions.get(scope) ?? 0) + 1,
        );
      }
      if (tx.hasContinuationInsert) {
        this.backing.continuationDurableWrites += 1;
        this.backing.durableLog.push(`admit:${tx.continuationWriteId}`);
        this.backing.effectObservations.push({
          continuationId: tx.continuationWriteId!,
          admissionCommitted: this.backing.data.continuations.has(tx.continuationWriteId!),
          canonicalCommitted: this.backing.data.canonicalContinuations.has(tx.continuationWriteId!),
        });
      }
      if (tx.ackWrite !== null) this.backing.durableLog.push(`ack:${tx.ackWrite}`);
      if (tx.operations.length > 0 && this.failAfter?.operation === options.operation) {
        const error = this.failAfter.error;
        this.failAfter = undefined;
        throw error;
      }
      return value;
    } catch (error) {
      if (error instanceof SensitiveResponseTransactionRetryError) this.retryCount += 1;
      throw error;
    }
  }

  pauseResponseInserts(participants: number): Gate {
    const value = gate(participants);
    this.responseInsertGate = value;
    return value;
  }

  pauseContinuationInserts(participants: number): Gate {
    const value = gate(participants);
    this.continuationInsertGate = value;
    return value;
  }

  pauseAcknowledgeTransactions(participants: number): Gate {
    const value = gate(participants);
    this.acknowledgeTransactionGate = value;
    return value;
  }

  failBeforeNextCommit(operation: string, error: Error): void {
    this.failBefore = { operation, error };
  }

  failAfterNextCommit(operation: string, error: Error): void {
    this.failAfter = { operation, error };
  }

  seed(request: SensitiveResponseRequestRecord): void {
    this.backing.data.requests.set(request.requestId, structuredClone(request));
    this.backing.requestRevisions.set(
      request.requestId,
      (this.backing.requestRevisions.get(request.requestId) ?? 0) + 1,
    );
  }

  request(requestId = "request-1"): SensitiveResponseRequestRecord {
    return structuredClone(this.backing.data.requests.get(requestId)!);
  }

  response(requestId = "request-1"): SensitiveResponseHandoffRecord {
    return structuredClone(
      [...this.backing.data.responses.values()].find((row) => row.requestId === requestId)!,
    );
  }

  continuation(responseId: string): SensitiveContinuationRecord {
    return structuredClone(this.backing.data.continuations.get(continuationId(responseId))!);
  }

  canonicalContinuation(continuationIdValue: string): SensitiveCanonicalContinuationRecord {
    return structuredClone(this.backing.data.canonicalContinuations.get(continuationIdValue)!);
  }

  get canonicalCount(): number {
    return this.backing.data.canonicalContinuations.size;
  }

  get effectObservations(): MemoryBacking["effectObservations"] {
    return structuredClone(this.backing.effectObservations);
  }

  get responseCount(): number {
    return this.backing.data.responses.size;
  }

  get continuationCount(): number {
    return this.backing.data.continuations.size;
  }

  get continuationDurableWrites(): number {
    return this.backing.continuationDurableWrites;
  }

  get durableLog(): string[] {
    return [...this.backing.durableLog];
  }

  private bumpResponseScope(scope: string): void {
    this.backing.responseRevisions.set(
      scope,
      (this.backing.responseRevisions.get(scope) ?? 0) + 1,
    );
  }

  replaceResponse(record: SensitiveResponseHandoffRecord): void {
    this.backing.data.responses.set(record.responseId, structuredClone(record));
    this.bumpResponseScope(requestScope(record.requestId));
  }

  replaceContinuation(record: SensitiveContinuationRecord): void {
    this.backing.data.continuations.set(record.binding.idempotencyKey, structuredClone(record));
    this.bumpResponseScope(requestScope(record.binding.requestId));
  }

  replaceCanonical(record: SensitiveCanonicalContinuationRecord): void {
    this.backing.data.canonicalContinuations.set(record.continuationId, structuredClone(record));
    this.bumpResponseScope(requestScope(record.binding.requestId));
  }

  deleteCanonical(continuationIdValue: string): void {
    const existing = this.backing.data.canonicalContinuations.get(continuationIdValue);
    this.backing.data.canonicalContinuations.delete(continuationIdValue);
    if (existing !== undefined) this.bumpResponseScope(requestScope(existing.binding.requestId));
  }

  get lockOrder(): string[] {
    return [...this.backing.lockOrder];
  }

  serializedRows(): string {
    return JSON.stringify({
      requests: [...this.backing.data.requests.values()],
      responses: [...this.backing.data.responses.values()],
      continuations: [...this.backing.data.continuations.values()],
      canonicalContinuations: [...this.backing.data.canonicalContinuations.values()],
    });
  }
}

function requestFixture(
  overrides: Partial<SensitiveResponseRequestRecord> = {},
): SensitiveResponseRequestRecord {
  return {
    requestId: "request-1",
    userId: "user-1",
    sessionId: "session-1",
    runId: "run-1",
    kind: "elicitation",
    safePayload: { message: "Enter your password" },
    sensitive: true,
    status: "pending",
    expiresAt: new Date(T0.getTime() + 10_000),
    version: 1,
    ...overrides,
  };
}

function acceptFixture(overrides: Record<string, unknown> = {}) {
  return {
    userId: "user-1",
    requestId: "request-1",
    version: 1,
    response: RESPONSE,
    clientResponseId: "client-response-1",
    ...overrides,
  };
}

function setup(options: {
  wake?: (event: SensitiveHandoffEvent) => void | Promise<void>;
} = {}) {
  const crypto = createEnvelopeCrypto(KEY);
  const store = new MemoryStore(() => now);
  const events: SensitiveHandoffEvent[] = [];
  let now = new Date(T0);
  let nextId = 0;
  const dependencies = {
    store,
    crypto,
    responseCommitmentKeyHex: COMMITMENT_KEY,
    clock: () => now,
    newId: () => `id-${++nextId}`,
    leaseMs: 1_000,
    maxTransactionAttempts: 16,
    transactionRetryDelayMs: 0,
    sleep: async () => undefined,
  };
  const wake = options.wake ?? ((event: SensitiveHandoffEvent) => {
    events.push(event);
  });
  const handoff = createSensitiveResponseHandoff({ ...dependencies, wake });
  store.seed(requestFixture());
  return {
    store,
    handoff,
    events,
    crypto,
    now: () => now,
    advance(ms: number) {
      now = new Date(now.getTime() + ms);
    },
    restart(withWake = false) {
      return createSensitiveResponseHandoff({
        ...dependencies,
        ...(withWake ? { wake } : {}),
      });
    },
    recover() {
      const recoveredStore = store.freshAdapter();
      const recovered = createSensitiveResponseHandoff({
        ...dependencies,
        store: recoveredStore,
      });
      return { store: recoveredStore, handoff: recovered };
    },
  };
}

function flipBase64(value: string): string {
  const index = Math.floor(value.length / 2);
  return `${value.slice(0, index)}${value[index] === "A" ? "B" : "A"}${value.slice(index + 1)}`;
}

async function claim(
  handoff: ReturnType<typeof setup>["handoff"],
  worker: SensitiveResponseWorker = WORKER,
): Promise<SensitiveResponseClaim> {
  const value = await handoff.claim({ requestId: "request-1", worker });
  expect(value).not.toBeNull();
  return value!;
}

function pausedAdmission(
  store: MemoryStore,
): { entered: Promise<void>; release: () => void } {
  let entered!: () => void;
  let released!: () => void;
  const atAdmission = new Promise<void>((resolve) => { entered = resolve; });
  const gate = new Promise<void>((resolve) => { released = resolve; });
  store.beforeAdmission = async () => {
    store.beforeAdmission = undefined;
    entered();
    await gate;
  };
  return {
    entered: atAdmission,
    release: () => {
      released();
    },
  };
}

function pausedAcknowledgement(
  store: MemoryStore,
): { entered: Promise<void>; release: () => void } {
  let entered!: () => void;
  let released!: () => void;
  const atAcknowledgement = new Promise<void>((resolve) => { entered = resolve; });
  const gate = new Promise<void>((resolve) => { released = resolve; });
  store.beforeAcknowledgeTransaction = async () => {
    store.beforeAcknowledgeTransaction = undefined;
    entered();
    await gate;
  };
  return { entered: atAcknowledgement, release: () => released() };
}

describe("sensitive response sealed codec", () => {
  it("uses real escrow AES-GCM and authenticates every six-field binding", () => {
    const codec = createSensitiveResponseCodec(createEnvelopeCrypto(KEY), COMMITMENT_KEY);
    const sealed = codec.seal(RESPONSE, BINDING);
    expect(codec.unseal(sealed, BINDING)).toEqual(RESPONSE);
    expect(JSON.stringify(sealed)).not.toContain(CANARY);
    const changes = [
      ["requestId", "request-other"],
      ["userId", "user-other"],
      ["sessionId", "session-other"],
      ["runId", "run-other"],
      ["requestVersion", 2],
      ["responseId", "response-other"],
    ] as const;
    for (const [key, value] of changes) {
      expect(() => codec.unseal(sealed, { ...BINDING, [key]: value }), key).toThrow();
    }
    expect(() => codec.unseal({ ...sealed, responseCommitment: "0".repeat(64) }, BINDING)).toThrow();
  });

  it("canonicalizes replay content and rejects tampering in every envelope field", () => {
    const codec = createSensitiveResponseCodec(createEnvelopeCrypto(KEY), COMMITMENT_KEY);
    const sealed = codec.seal(RESPONSE, BINDING);
    const reordered = codec.seal({ content: { password: CANARY }, action: "accept" }, BINDING);
    expect(reordered.responseCommitment).toBe(sealed.responseCommitment);
    expect(reordered.envelope.ciphertext).not.toBe(sealed.envelope.ciphertext);
    for (const field of ["wrappedDek", "iv", "ciphertext", "tag"] as const) {
      const envelope: EncryptedEnvelope = {
        ...sealed.envelope,
        [field]: flipBase64(sealed.envelope[field]),
      };
      expect(() => codec.unseal({ ...sealed, envelope }, BINDING), field).toThrow();
    }
  });

  it("stores only a keyed commitment, not an unsalted low-entropy password verifier", () => {
    const response = { action: "accept", content: { password: "123456" } };
    const canonical = JSON.stringify({ action: "accept", content: { password: "123456" } });
    const first = createSensitiveResponseCodec(
      createEnvelopeCrypto(KEY),
      COMMITMENT_KEY,
    ).seal(response, BINDING);
    const second = createSensitiveResponseCodec(
      createEnvelopeCrypto(KEY),
      OTHER_COMMITMENT_KEY,
    ).seal(response, BINDING);
    expect(first.responseCommitment).not.toBe(second.responseCommitment);
    expect(first.responseCommitment).not.toBe(createHash("sha256").update(canonical).digest("hex"));
    expect(Object.hasOwn(first, "responseDigest")).toBe(false);
    expect(() => createSensitiveResponseCodec(
      createEnvelopeCrypto(KEY),
      OTHER_COMMITMENT_KEY,
    ).unseal(first, BINDING)).toThrow();
    expect(() => createSensitiveResponseCodec(createEnvelopeCrypto(KEY), "not-a-key")).toThrow();
  });
});

describe("sensitive response gateway acceptance", () => {
  it("seals before one awaiting_delivery commit and returns only an immutable receipt", async () => {
    const context = setup();
    let insertSawSealedValue = false;
    const originalInsert = MemoryTransaction.prototype.insertAwaitingDelivery;
    MemoryTransaction.prototype.insertAwaitingDelivery = async function (record) {
      insertSawSealedValue = record.envelope !== null && record.state === "awaiting_delivery";
      expect(this.data.requests.get(record.requestId)?.status).toBe("pending");
      await originalInsert.call(this, record);
    };
    try {
      const receipt = await context.handoff.accept(acceptFixture());
      expect(insertSawSealedValue).toBe(true);
      expect(receipt).toEqual({
        requestId: "request-1",
        version: 1,
        clientResponseId: "client-response-1",
        createdAt: T0.toISOString(),
        deliveryState: "awaiting_delivery",
      });
      expect(Object.keys(receipt!)).toEqual([
        "requestId",
        "version",
        "clientResponseId",
        "createdAt",
        "deliveryState",
      ]);
      expect(context.store.request()).toMatchObject({ status: "pending", version: 1 });
      expect(context.store.response()).toMatchObject({
        requestVersion: 1,
        state: "awaiting_delivery",
        claimGeneration: 0,
        claim: null,
      });
      expect(context.store.response().responseCommitment).toMatch(/^[0-9a-f]{64}$/);
      expect(Object.hasOwn(context.store.response(), "responseDigest")).toBe(false);
      expect(context.store.response().envelope).not.toBeNull();
      expect(context.store.serializedRows()).not.toContain(CANARY);
      expect(JSON.stringify(receipt)).not.toContain(CANARY);
      expect(JSON.stringify(context.events)).not.toContain(CANARY);
    } finally {
      MemoryTransaction.prototype.insertAwaitingDelivery = originalInsert;
    }
  });

  it("replays canonical content and fences changed content, versions, and client IDs", async () => {
    const { handoff, store } = setup();
    const first = await handoff.accept(acceptFixture());
    expect(await handoff.accept(acceptFixture({
      response: { content: { password: CANARY }, action: "accept" },
    }))).toEqual(first);
    expect(await handoff.accept(acceptFixture({ clientResponseId: "regenerated-retry" }))).toEqual(first);
    expect(store.responseCount).toBe(1);
    await expect(handoff.accept(acceptFixture({
      response: { action: "accept", content: { password: "changed" } },
    }))).rejects.toMatchObject({ code: "response_conflict" });
    await expect(handoff.accept(acceptFixture({ version: 2 })))
      .rejects.toMatchObject({ code: "response_conflict" });
    await expect(handoff.accept(acceptFixture({ version: 2, clientResponseId: "new-id" })))
      .rejects.toMatchObject({ code: "version_conflict" });
    store.seed(requestFixture({ requestId: "request-2" }));
    await expect(handoff.accept(acceptFixture({ requestId: "request-2" })))
      .rejects.toMatchObject({ code: "client_response_conflict" });
    expect(await handoff.accept(acceptFixture({ userId: "user-other", clientResponseId: "foreign" })))
      .toBeNull();
    expect(store.responseCount).toBe(1);
  });

  it("retries real overlapping accept races instead of globally serializing them away", async () => {
    const { handoff, store, restart } = setup();
    const identicalGate = store.pauseResponseInserts(12);
    const handoffs = [
      handoff,
      ...Array.from({ length: 11 }, () => restart(false)),
    ];
    const identicalPending = Promise.all(handoffs.map((peer) =>
      peer.accept(acceptFixture()),
    ));
    await identicalGate.reached;
    identicalGate.release();
    const identical = await identicalPending;
    expect(new Set(identical.map((row) => JSON.stringify(row))).size).toBe(1);
    expect(store.responseCount).toBe(1);
    expect(store.retryCount).toBeGreaterThan(0);

    const conflicted = setup();
    const conflictGate = conflicted.store.pauseResponseInserts(2);
    const conflictingPeer = conflicted.restart(false);
    const outcomesPending = Promise.allSettled([
      conflicted.handoff.accept(acceptFixture({ clientResponseId: "race-a" })),
      conflictingPeer.accept(acceptFixture({
        clientResponseId: "race-b",
        response: { action: "accept", content: { password: "different" } },
      })),
    ]);
    await conflictGate.reached;
    conflictGate.release();
    const outcomes = await outcomesPending;
    expect(outcomes.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejected = outcomes.find((result) => result.status === "rejected");
    expect(rejected?.status).toBe("rejected");
    if (rejected?.status === "rejected") {
      expect(rejected.reason).toMatchObject({ code: "response_conflict" });
    }
    expect(conflicted.store.responseCount).toBe(1);
    expect(conflicted.store.retryCount).toBeGreaterThan(0);
  });

  it("keeps independent accept races out of each other's conflict and retry scopes", async () => {
    const context = setup();
    for (let index = 0; index < 8; index += 1) {
      context.store.seed(requestFixture({ requestId: `request-${index}` }));
    }
    const insertGate = context.store.pauseResponseInserts(8);
    const peers = Array.from({ length: 8 }, () => context.restart(false));
    const pending = Promise.all(peers.map((peer, index) => peer.accept(acceptFixture({
      requestId: `request-${index}`,
      clientResponseId: `client-${index}`,
    }))));
    await insertGate.reached;
    insertGate.release();
    const receipts = await pending;
    expect(receipts.map((receipt) => receipt?.requestId)).toEqual(
      Array.from({ length: 8 }, (_, index) => `request-${index}`),
    );
    expect(context.store.responseCount).toBe(8);
    expect(context.store.retryCount).toBe(0);
  });

  it("reconciles an ordinary accept whose commit result was lost before receipt", async () => {
    const context = setup();
    context.store.failAfterNextCommit("accept", new Error("receipt commit result lost"));
    await expect(context.handoff.accept(acceptFixture()))
      .rejects.toMatchObject({ code: "handoff_unavailable" });
    expect(context.store.responseCount).toBe(1);
    expect(context.store.request()).toMatchObject({ status: "pending", version: 1 });
    const replay = await context.restart(false).accept(acceptFixture());
    expect(replay).toEqual({
      requestId: "request-1",
      version: 1,
      clientResponseId: "client-response-1",
      createdAt: T0.toISOString(),
      deliveryState: "awaiting_delivery",
    });
    expect(context.store.responseCount).toBe(1);
  });

  it("orders client-key locks across fresh adapters for cross-request same-key races", async () => {
    const context = setup();
    context.store.seed(requestFixture({ requestId: "request-2" }));
    const first = context.recover();
    const second = context.recover();
    const firstGate = first.store.pauseResponseInserts(1);
    const secondGate = second.store.pauseResponseInserts(1);
    const pending = Promise.allSettled([
      first.handoff.accept(acceptFixture({ clientResponseId: "shared-client-key" })),
      second.handoff.accept(acceptFixture({
        requestId: "request-2",
        clientResponseId: "shared-client-key",
      })),
    ]);
    await Promise.all([firstGate.reached, secondGate.reached]);
    firstGate.release();
    secondGate.release();
    const outcomes = await pending;
    expect(outcomes.filter((outcome) => outcome.status === "fulfilled")).toHaveLength(1);
    const rejected = outcomes.find((outcome) => outcome.status === "rejected");
    expect(rejected?.status).toBe("rejected");
    if (rejected?.status === "rejected") {
      expect(rejected.reason).toMatchObject({ code: "client_response_conflict" });
    }
    const fulfilled = outcomes.find((outcome) => outcome.status === "fulfilled");
    expect(fulfilled?.status).toBe("fulfilled");
    if (fulfilled?.status !== "fulfilled") throw new Error("missing same-key winner");
    const winner = fulfilled.value;
    expect(winner).not.toBeNull();
    expect(context.store.responseCount).toBe(1);
    expect(first.store.retryCount + second.store.retryCount).toBeGreaterThan(0);

    const replay = await context.recover().handoff.accept(acceptFixture({
      requestId: winner!.requestId,
      clientResponseId: "shared-client-key",
    }));
    expect(replay).toEqual(winner);
    await expect(context.handoff.accept(acceptFixture({
      requestId: winner!.requestId,
      clientResponseId: "shared-client-key",
      version: 2,
    }))).rejects.toMatchObject({ code: "response_conflict" });
    await expect(context.handoff.accept(acceptFixture({
      requestId: winner!.requestId,
      clientResponseId: "shared-client-key",
      response: { action: "accept", content: { password: "changed" } },
    }))).rejects.toMatchObject({ code: "response_conflict" });
    expect(context.store.responseCount).toBe(1);

    const order = context.store.lockOrder;
    expect(order.length).toBeGreaterThanOrEqual(4);
    expect(order).toContain(clientScope("user-1", "shared-client-key"));
    for (let index = 0; index < order.length; index += 2) {
      expect(order[index]).toMatch(/^client:/);
      expect(order[index + 1]).toMatch(/^request:/);
    }
  });

  it("fences different payloads by client key while isolating cross-user and unrelated scopes", async () => {
    const conflict = setup();
    conflict.store.seed(requestFixture({ requestId: "request-2" }));
    const first = conflict.recover();
    const second = conflict.recover();
    const firstGate = first.store.pauseResponseInserts(1);
    const secondGate = second.store.pauseResponseInserts(1);
    const pending = Promise.allSettled([
      first.handoff.accept(acceptFixture({ clientResponseId: "shared-different-payload" })),
      second.handoff.accept(acceptFixture({
        requestId: "request-2",
        clientResponseId: "shared-different-payload",
        response: { action: "accept", content: { password: "different" } },
      })),
    ]);
    await Promise.all([firstGate.reached, secondGate.reached]);
    firstGate.release();
    secondGate.release();
    const outcomes = await pending;
    expect(outcomes.filter((outcome) => outcome.status === "fulfilled")).toHaveLength(1);
    const rejected = outcomes.find((outcome) => outcome.status === "rejected");
    expect(rejected?.status).toBe("rejected");
    if (rejected?.status === "rejected") {
      expect(rejected.reason).toMatchObject({ code: "client_response_conflict" });
    }
    expect(conflict.store.responseCount).toBe(1);
    expect(first.store.retryCount + second.store.retryCount).toBeGreaterThan(0);

    const isolated = setup();
    isolated.store.seed(requestFixture({
      requestId: "request-2",
      userId: "user-2",
      sessionId: "session-2",
      runId: "run-2",
    }));
    const userOne = isolated.recover();
    const userTwo = isolated.recover();
    const userOneGate = userOne.store.pauseResponseInserts(1);
    const userTwoGate = userTwo.store.pauseResponseInserts(1);
    const isolatedPending = Promise.all([
      userOne.handoff.accept(acceptFixture({ clientResponseId: "same-cross-user-key" })),
      userTwo.handoff.accept(acceptFixture({
        requestId: "request-2",
        userId: "user-2",
        clientResponseId: "same-cross-user-key",
        response: { action: "accept", content: { password: "other-user-secret" } },
      })),
    ]);
    await Promise.all([userOneGate.reached, userTwoGate.reached]);
    userOneGate.release();
    userTwoGate.release();
    const isolatedReceipts = await isolatedPending;
    expect(isolatedReceipts.map((receipt) => receipt?.requestId)).toEqual([
      "request-1",
      "request-2",
    ]);
    expect(isolated.store.responseCount).toBe(2);
    expect(userOne.store.retryCount + userTwo.store.retryCount).toBe(0);
    expect(isolated.store.lockOrder).toContain(clientScope("user-1", "same-cross-user-key"));
    expect(isolated.store.lockOrder).toContain(clientScope("user-2", "same-cross-user-key"));
  });

  it("keeps non-sensitive responses outside this primitive and refuses invalid bounds", async () => {
    const context = setup();
    context.store.seed(requestFixture({ sensitive: false }));
    await expect(context.handoff.accept(acceptFixture()))
      .rejects.toMatchObject({ code: "invalid_request" });
    expect(context.store.responseCount).toBe(0);
    expect(() => createSensitiveResponseHandoff({
      store: context.store,
      crypto: context.crypto,
      responseCommitmentKeyHex: COMMITMENT_KEY,
      clock: context.now,
      newId: () => "id",
      leaseMs: 0,
    })).toThrow(SensitiveResponseHandoffError);
  });
});

describe("worker-only fenced durable continuation handoff", () => {
  it("carries the full fence, admits before ack, resolves once, and tombstones sealed bytes", async () => {
    const { handoff, store } = setup();
    const receipt = await handoff.accept(acceptFixture());
    const lease = await claim(handoff);
    const acceptedSealed = sealedFromResponse(store.response());
    const expectedContinuationId = continuationId(lease.responseId);
    expect(lease).toMatchObject({
      requestId: "request-1",
      responseId: store.response().responseId,
      requestVersion: 1,
      requestExpiresAt: store.request().expiresAt.toISOString(),
      responseCommitment: store.response().responseCommitment,
      continuationId: expectedContinuationId,
      claimGeneration: 1,
      leaseExpiresAt: new Date(T0.getTime() + 1_000).toISOString(),
    });
    const delivered = await handoff.deliver({ claim: lease, worker: WORKER });
    expect(delivered).toEqual({ deliveryState: "delivered", continuationId: expectedContinuationId });
    expect(store.durableLog).toEqual([
      `admit:${expectedContinuationId}`,
      `ack:${expectedContinuationId}`,
    ]);
    expect(store.admissionFences[0]).toMatchObject({
      binding: {
        requestId: "request-1",
        userId: "user-1",
        sessionId: "session-1",
        runId: "run-1",
        responseId: lease.responseId,
        requestVersion: 1,
        responseCommitment: lease.responseCommitment,
        continuationId: expectedContinuationId,
        idempotencyKey: expectedContinuationId,
      },
      fence: {
        claimId: lease.claimId,
        claimGeneration: 1,
        workerId: "worker-1",
        expectedRequestStatus: "pending",
        expectedHandoffState: "claimed",
      },
    });
    expect(store.admissionFences[0]?.fence.requestExpiresAt).toEqual(store.request().expiresAt);
    expect(store.admissionFences[0]?.fence.leaseExpiresAt).toEqual(new Date(T0.getTime() + 1_000));
    expect(store.request()).toMatchObject({ status: "resolved", version: 2 });
    expect(store.response()).toMatchObject({
      state: "delivered",
      envelope: null,
      continuationId: expectedContinuationId,
      tombstonedAt: T0,
    });
    expect(store.continuation(lease.responseId)).toMatchObject({
      state: "ready",
      firstClaimId: lease.claimId,
      firstClaimGeneration: 1,
    });
    expect(store.continuationDurableWrites).toBe(1);
    expect(store.admissionSealedValues).toEqual([acceptedSealed]);
    expect(store.continuation(lease.responseId).sealedResponse).toEqual(acceptedSealed);
    expect(store.canonicalContinuation(expectedContinuationId)).toEqual({
      continuationId: expectedContinuationId,
      state: "ready",
      admittedAt: T0,
      sealedResponse: acceptedSealed,
      binding: {
        requestId: "request-1",
        userId: "user-1",
        sessionId: "session-1",
        runId: "run-1",
        responseId: lease.responseId,
        requestVersion: 1,
        responseCommitment: lease.responseCommitment,
        continuationId: expectedContinuationId,
        idempotencyKey: expectedContinuationId,
      },
    });
    expect(store.effectObservations).toEqual([{
      continuationId: expectedContinuationId,
      admissionCommitted: true,
      canonicalCommitted: true,
    }]);
    expect(store.serializedRows()).not.toContain(CANARY);
    expect(await handoff.get({ userId: "user-1", requestId: "request-1" }))
      .toMatchObject({ status: "resolved", response: null });
    expect(await handoff.accept(acceptFixture())).toEqual(receipt);
  });

  it("allows exactly one active claim and fences an already-stale worker before admission", async () => {
    const { handoff, store, advance } = setup();
    await handoff.accept(acceptFixture());
    const claims = await Promise.allSettled([
      handoff.claim({ requestId: "request-1", worker: WORKER }),
      handoff.claim({ requestId: "request-1", worker: { ...WORKER, workerId: "worker-2" } }),
    ]);
    expect(claims.filter((result) => result.status === "fulfilled" && result.value !== null)).toHaveLength(1);
    expect(claims.filter((result) => result.status === "rejected")).toHaveLength(1);
    const first = claimFromStore(store);
    const firstWorker = { ...WORKER, workerId: store.response().claim!.workerId };
    advance(1_000);
    const secondWorker = { ...WORKER, workerId: "worker-after-expiry" };
    const second = await claim(handoff, secondWorker);
    expect(second.claimGeneration).toBe(2);
    const admissions = store.admissionAttempts;
    await expect(handoff.deliver({ claim: first, worker: firstWorker }))
      .rejects.toMatchObject({ code: "stale_claim" });
    expect(store.admissionAttempts).toBe(admissions);
    expect(store.continuationCount).toBe(0);
    expect(store.request().status).toBe("pending");
  });

  it("recovers after failed wake and restart without any subscriber", async () => {
    const context = setup({ wake: () => {
      throw new Error("no subscriber / commit already durable");
    } });
    const receipt = await context.handoff.accept(acceptFixture());
    expect(receipt?.deliveryState).toBe("awaiting_delivery");
    expect(context.store.request().status).toBe("pending");
    const recovered = context.recover();
    // Keep one handoff instance to prove a new object over the same port has
    // no in-memory delivery state; fresh-adapter recovery is tested below.
    const restarted = context.restart(false);
    const lease = await claim(restarted);
    await restarted.deliver({ claim: lease, worker: WORKER });
    expect(context.store.request().status).toBe("resolved");
    expect(context.store.continuationDurableWrites).toBe(1);
  });

  it("refuses a paused in-flight admission after lease takeover before any durable effect", async () => {
    const context = setup();
    await context.handoff.accept(acceptFixture());
    const first = await claim(context.handoff);
    const paused = pausedAdmission(context.store);
    const firstDelivery = context.handoff.deliver({ claim: first, worker: WORKER });
    await paused.entered;
    context.advance(1_000);
    const secondWorker = { ...WORKER, workerId: "worker-2" };
    const second = await claim(context.handoff, secondWorker);
    paused.release();
    await expect(firstDelivery).rejects.toMatchObject({ code: "stale_claim" });
    expect(context.store.continuationDurableWrites).toBe(0);
    expect(context.store.continuationCount).toBe(0);
    expect(context.store.canonicalCount).toBe(0);
    expect(context.store.effectObservations).toEqual([]);
    await context.handoff.deliver({ claim: second, worker: secondWorker });
    expect(context.store.continuationDurableWrites).toBe(1);
    expect(context.store.continuationCount).toBe(1);
  });

  it("first-writer-wins concurrent admissions and exact non-null first-ack replay", async () => {
    const { handoff, store } = setup();
    await handoff.accept(acceptFixture());
    const lease = await claim(handoff);
    const acceptedSealed = sealedFromResponse(store.response());
    const admissionGate = store.pauseContinuationInserts(2);
    const acknowledgeGate = store.pauseAcknowledgeTransactions(2);
    const pending = Promise.all([
      handoff.deliver({ claim: lease, worker: WORKER }),
      handoff.deliver({ claim: lease, worker: WORKER }),
    ]);
    await admissionGate.reached;
    admissionGate.release();
    // Both callers loaded work and carry the exact non-null first-ack value.
    // One commits; the other retries into ready replay with that same value.
    await acknowledgeGate.reached;
    acknowledgeGate.release();
    const deliveries = await pending;
    expect(deliveries).toEqual([
      { deliveryState: "delivered", continuationId: lease.continuationId },
      { deliveryState: "delivered", continuationId: lease.continuationId },
    ]);
    expect(store.continuationDurableWrites).toBe(1);
    expect(store.continuationCount).toBe(1);
    expect(store.canonicalCount).toBe(1);
    expect(store.effectObservations).toHaveLength(1);
    expect(store.admissionSealedValues.length).toBeGreaterThanOrEqual(2);
    for (const sealed of store.admissionSealedValues) expect(sealed).toEqual(acceptedSealed);
    expect(store.readyAckInputs).toContainEqual(acceptedSealed);
    expect(store.durableLog).toEqual([
      `admit:${lease.continuationId}`,
      `ack:${lease.continuationId}`,
    ]);
    expect(store.retryCount).toBeGreaterThan(0);
  });

  it("reconciles uncertain admission commit through a fresh adapter without a duplicate write", async () => {
    const context = setup();
    await context.handoff.accept(acceptFixture());
    const first = await claim(context.handoff);
    context.store.failAfterNextCommit(
      "admit_continuation",
      new Error("admission commit outcome lost"),
    );
    await expect(context.handoff.deliver({ claim: first, worker: WORKER }))
      .rejects.toMatchObject({ code: "delivery_outcome_uncertain" });
    expect(context.store.continuationDurableWrites).toBe(1);
    expect(context.store.continuation(first.responseId).state).toBe("held");
    expect(context.store.canonicalContinuation(first.continuationId).state).toBe("held");
    expect(context.store.effectObservations).toEqual([{
      continuationId: first.continuationId,
      admissionCommitted: true,
      canonicalCommitted: true,
    }]);
    expect(context.store.request().status).toBe("pending");
    expect(context.store.response().state).toBe("claimed");

    const recovered = context.recover();
    context.advance(1_000);
    const retryWorker = { ...WORKER, workerId: "worker-recovered" };
    const retry = await claim(recovered.handoff, retryWorker);
    await recovered.handoff.deliver({ claim: retry, worker: retryWorker });
    expect(context.store.continuationDurableWrites).toBe(1);
    expect(context.store.effectObservations).toHaveLength(1);
    expect(context.store.continuation(first.responseId)).toMatchObject({
      state: "ready",
      firstClaimId: first.claimId,
      firstClaimGeneration: first.claimGeneration,
    });
    expect(context.store.request()).toMatchObject({ status: "resolved", version: 2 });
  });

  it("reconciles a lost ack result without rerunning admission", async () => {
    const context = setup();
    await context.handoff.accept(acceptFixture());
    const lease = await claim(context.handoff);
    context.store.failAfterNextCommit("acknowledge", new Error("ack commit outcome lost"));
    await expect(context.handoff.deliver({ claim: lease, worker: WORKER }))
      .rejects.toMatchObject({ code: "delivery_outcome_uncertain" });
    expect(context.store.request().status).toBe("resolved");
    expect(context.store.response().state).toBe("delivered");
    const admissions = context.store.admissionAttempts;
    const acknowledgements = context.store.ackAttempts;
    await expect(context.handoff.deliver({ claim: lease, worker: WORKER }))
      .resolves.toEqual({ deliveryState: "delivered", continuationId: lease.continuationId });
    expect(context.store.admissionAttempts).toBe(admissions);
    expect(context.store.ackAttempts).toBe(acknowledgements + 1);
    expect(context.store.continuationDurableWrites).toBe(1);
  });

  it("rejects changed delivered content or continuation identity before any admission", async () => {
    const { handoff, store } = setup();
    await handoff.accept(acceptFixture());
    const lease = await claim(handoff);
    await handoff.deliver({ claim: lease, worker: WORKER });
    const admissions = store.admissionAttempts;
    const acknowledgements = store.ackAttempts;
    for (const changed of [
      { responseCommitment: "0".repeat(64) },
      { continuationId: "continuation-changed" },
    ]) {
      await expect(handoff.deliver({ claim: { ...lease, ...changed }, worker: WORKER }))
        .rejects.toMatchObject({ code: "response_conflict" });
    }
    expect(store.admissionAttempts).toBe(admissions);
    expect(store.ackAttempts).toBe(acknowledgements + 2);
    expect(store.continuationDurableWrites).toBe(1);
    expect(store.request()).toMatchObject({ status: "resolved", version: 2 });
  });

  it("conflicts a rebound continuation and never acks before durable admission", async () => {
    const conflict = setup();
    await conflict.handoff.accept(acceptFixture());
    const lease = await claim(conflict.handoff);
    conflict.store.failAfterNextCommit("admit_continuation", new Error("uncertain"));
    await expect(conflict.handoff.deliver({ claim: lease, worker: WORKER }))
      .rejects.toMatchObject({ code: "delivery_outcome_uncertain" });
    const original = conflict.store.continuation(lease.responseId);
    conflict.store.replaceContinuation({
      ...original,
      binding: { ...original.binding, responseCommitment: "0".repeat(64) },
    });
    const recovered = conflict.recover();
    await expect(recovered.handoff.deliver({ claim: lease, worker: WORKER }))
      .rejects.toMatchObject({ code: "response_conflict" });
    expect(conflict.store.continuationDurableWrites).toBe(1);
    expect(conflict.store.request().status).toBe("pending");

    const absent = setup();
    await absent.handoff.accept(acceptFixture());
    const absentLease = await claim(absent.handoff);
    absent.store.failBeforeNextCommit("admit_continuation", new Error("before durable admission"));
    await expect(absent.handoff.deliver({ claim: absentLease, worker: WORKER }))
      .rejects.toMatchObject({ code: "delivery_outcome_uncertain" });
    expect(absent.store.continuationDurableWrites).toBe(0);
    expect(absent.store.continuationCount).toBe(0);
    expect(absent.store.canonicalCount).toBe(0);
    expect(absent.store.effectObservations).toEqual([]);
    expect(absent.store.response().continuationId).toBeNull();
    expect(absent.store.request().status).toBe("pending");
    await absent.handoff.deliver({ claim: absentLease, worker: WORKER });
    expect(absent.store.continuationDurableWrites).toBe(1);
  });
});

describe("canonical sealed recovery and lifecycle fencing", () => {
  it("recovers through fresh adapter/handoff after handoff tombstone and replays ready ack", async () => {
    const context = setup();
    await context.handoff.accept(acceptFixture());
    const lease = await claim(context.handoff);
    const acceptedSealed = sealedFromResponse(context.store.response());
    await context.handoff.deliver({ claim: lease, worker: WORKER });

    const recovered = context.recover();
    expect(recovered.store).not.toBe(context.store);
    expect(recovered.handoff).not.toBe(context.handoff);
    expect(recovered.store.response().envelope).toBeNull();
    const canonical = recovered.store.canonicalContinuation(lease.continuationId);
    expect(canonical).toMatchObject({ state: "ready", sealedResponse: acceptedSealed });
    expect(recovered.store.continuation(lease.responseId)).toMatchObject({
      state: "ready",
      sealedResponse: acceptedSealed,
    });
    const binding = canonical.binding;
    const codec = createSensitiveResponseCodec(createEnvelopeCrypto(KEY), COMMITMENT_KEY);
    expect(codec.unseal(canonical.sealedResponse!, {
      requestId: binding.requestId,
      userId: binding.userId,
      sessionId: binding.sessionId,
      runId: binding.runId,
      requestVersion: binding.requestVersion,
      responseId: binding.responseId,
    })).toEqual(RESPONSE);
    await expect(recovered.handoff.deliver({ claim: lease, worker: WORKER }))
      .resolves.toEqual({ deliveryState: "delivered", continuationId: lease.continuationId });
    expect(recovered.store.readyAckInputs).toContainEqual(null);
    expect(recovered.store.continuationDurableWrites).toBe(1);
  });

  it("ready ack replays exact sealed value and rejects changed or missing canonical values", async () => {
    const { handoff, store } = setup();
    await handoff.accept(acceptFixture());
    const lease = await claim(handoff);
    const acceptedSealed = sealedFromResponse(store.response());
    await handoff.deliver({ claim: lease, worker: WORKER });
    const admitted = store.admissionFences[0]!;
    const replay = await store.transaction(
      (tx) => tx.acknowledgeContinuation({ ...admitted, sealedResponse: acceptedSealed }),
      { operation: "acknowledge", lockRequestId: "request-1" },
    );
    expect(replay).toEqual({ kind: "replayed", continuationId: lease.continuationId });
    expect(store.readyAckInputs).toContainEqual(acceptedSealed);

    const changed = {
      ...acceptedSealed,
      responseCommitment: "0".repeat(64),
    };
    await expect(store.transaction(
      (tx) => tx.acknowledgeContinuation({ ...admitted, sealedResponse: changed }),
      { operation: "acknowledge", lockRequestId: "request-1" },
    )).resolves.toEqual({ kind: "conflict" });

    const canonical = store.canonicalContinuation(lease.continuationId);
    store.replaceCanonical({ ...canonical, sealedResponse: null });
    await expect(store.transaction(
      (tx) => tx.acknowledgeContinuation({ ...admitted, sealedResponse: acceptedSealed }),
      { operation: "acknowledge", lockRequestId: "request-1" },
    )).resolves.toEqual({ kind: "continuation_unavailable" });
    expect(store.continuationDurableWrites).toBe(1);
    expect(store.durableLog).toEqual([
      `admit:${lease.continuationId}`,
      `ack:${lease.continuationId}`,
    ]);
    expect(store.request()).toMatchObject({ status: "resolved", version: 2 });
  });

  it("fails first ack unresolved when the canonical sealed value is missing", async () => {
    const { handoff, store } = setup();
    await handoff.accept(acceptFixture());
    const lease = await claim(handoff);
    const paused = pausedAcknowledgement(store);
    const delivery = handoff.deliver({ claim: lease, worker: WORKER });
    await paused.entered;
    expect(store.continuation(lease.responseId).state).toBe("held");
    store.deleteCanonical(lease.continuationId);
    paused.release();
    await expect(delivery).rejects.toMatchObject({ code: "handoff_unavailable" });
    expect(store.request()).toMatchObject({ status: "pending", version: 1 });
    expect(store.response()).toMatchObject({ state: "claimed" });
    expect(store.response().envelope).not.toBeNull();
    expect(store.continuationDurableWrites).toBe(1);
    expect(store.continuation(lease.responseId).state).toBe("held");
  });

  it("rejects a rebound canonical value during admission replay before any ack", async () => {
    const context = setup();
    await context.handoff.accept(acceptFixture());
    const lease = await claim(context.handoff);
    context.store.failAfterNextCommit("admit_continuation", new Error("uncertain admission"));
    await expect(context.handoff.deliver({ claim: lease, worker: WORKER }))
      .rejects.toMatchObject({ code: "delivery_outcome_uncertain" });
    const canonical = context.store.canonicalContinuation(lease.continuationId);
    context.store.replaceCanonical({
      ...canonical,
      sealedResponse: {
        ...canonical.sealedResponse!,
        responseCommitment: "0".repeat(64),
      },
    });
    const recovered = context.recover();
    await expect(recovered.handoff.deliver({ claim: lease, worker: WORKER }))
      .rejects.toMatchObject({ code: "handoff_unavailable" });
    expect(recovered.store.ackAttempts).toBe(0);
    expect(context.store.continuationDurableWrites).toBe(1);
    expect(context.store.request()).toMatchObject({ status: "pending", version: 1 });
    expect(context.store.response()).toMatchObject({ state: "claimed" });
    expect(context.store.response().envelope).not.toBeNull();
  });

  it("rejects rebound canonical identity or sealed value before resolving", async () => {
    for (const rebound of ["binding", "value"] as const) {
      const { handoff, store } = setup();
      await handoff.accept(acceptFixture());
      const lease = await claim(handoff);
      const paused = pausedAcknowledgement(store);
      const delivery = handoff.deliver({ claim: lease, worker: WORKER });
      await paused.entered;
      const canonical = store.canonicalContinuation(lease.continuationId);
      if (rebound === "binding") {
        store.replaceCanonical({
          ...canonical,
          binding: { ...canonical.binding, responseCommitment: "0".repeat(64) },
        });
      } else {
        store.replaceCanonical({
          ...canonical,
          sealedResponse: {
            ...canonical.sealedResponse!,
            envelope: {
              ...canonical.sealedResponse!.envelope,
              ciphertext: flipBase64(canonical.sealedResponse!.envelope.ciphertext),
            },
          },
        });
      }
      paused.release();
      await expect(delivery).rejects.toMatchObject({
        code: rebound === "binding" ? "response_conflict" : "handoff_unavailable",
      });
      expect(store.request()).toMatchObject({ status: "pending", version: 1 });
      expect(store.response()).toMatchObject({ state: "claimed" });
      expect(store.response().envelope).not.toBeNull();
      expect(store.continuation(lease.responseId).state).toBe("held");
    }
  });

  it("does not reconcile delivered metadata after its canonical value disappears", async () => {
    const { handoff, store } = setup();
    await handoff.accept(acceptFixture());
    const lease = await claim(handoff);
    await handoff.deliver({ claim: lease, worker: WORKER });
    store.deleteCanonical(lease.continuationId);
    const admissions = store.admissionAttempts;
    await expect(handoff.deliver({ claim: lease, worker: WORKER }))
      .rejects.toMatchObject({ code: "handoff_unavailable" });
    expect(store.admissionAttempts).toBe(admissions);
    expect(store.continuationDurableWrites).toBe(1);
    expect(store.response()).toMatchObject({ state: "delivered", envelope: null });
  });
});

describe("expiry, cancellation, and tenant fencing", () => {
  it("expiry before claim tombstones the sealed row and blocks admission", async () => {
    const { handoff, store, advance } = setup();
    await handoff.accept(acceptFixture());
    advance(10_000);
    await expect(handoff.claim({ requestId: "request-1", worker: WORKER }))
      .rejects.toMatchObject({ code: "request_expired" });
    expect(store.request()).toMatchObject({ status: "expired", version: 2 });
    expect(store.response()).toMatchObject({ state: "expired", envelope: null });
    expect(store.response().tombstonedAt).toEqual(new Date(T0.getTime() + 10_000));
    expect(store.continuationDurableWrites).toBe(0);
  });

  it("refuses a paused in-flight admission after the request deadline before any effect", async () => {
    const { handoff, store, advance } = setup();
    await handoff.accept(acceptFixture());
    const lease = await claim(handoff);
    const paused = pausedAdmission(store);
    const delivery = handoff.deliver({ claim: lease, worker: WORKER });
    await paused.entered;
    advance(10_000);
    paused.release();
    await expect(delivery).rejects.toMatchObject({ code: "request_expired" });
    expect(store.continuationDurableWrites).toBe(0);
    expect(store.continuationCount).toBe(0);
    expect(store.canonicalCount).toBe(0);
    expect(store.effectObservations).toEqual([]);
    expect(store.ackAttempts).toBe(0);
    await handoff.expire({ userId: "user-1", requestId: "request-1", version: 1 });
    expect(store.request()).toMatchObject({ status: "expired", version: 2 });
    expect(store.response()).toMatchObject({ state: "expired", envelope: null });
  });

  it("refuses a paused in-flight admission after cancellation before any effect", async () => {
    const { handoff, store } = setup();
    await handoff.accept(acceptFixture());
    const lease = await claim(handoff);
    const paused = pausedAdmission(store);
    const delivery = handoff.deliver({ claim: lease, worker: WORKER });
    await paused.entered;
    await handoff.cancel({ userId: "user-1", requestId: "request-1", version: 1 });
    paused.release();
    await expect(delivery).rejects.toMatchObject({ code: "request_not_pending" });
    expect(store.continuationDurableWrites).toBe(0);
    expect(store.continuationCount).toBe(0);
    expect(store.canonicalCount).toBe(0);
    expect(store.effectObservations).toEqual([]);
    expect(store.ackAttempts).toBe(0);
    expect(store.request()).toMatchObject({ status: "cancelled", version: 2 });
  });

  it("fences a paused ack at the deadline and cancels the still-held continuation", async () => {
    const { handoff, store, advance } = setup();
    await handoff.accept(acceptFixture());
    const lease = await claim(handoff);
    const paused = pausedAcknowledgement(store);
    const delivery = handoff.deliver({ claim: lease, worker: WORKER });
    await paused.entered;
    expect(store.continuation(lease.responseId).state).toBe("held");
    expect(store.continuationDurableWrites).toBe(1);
    advance(10_000);
    paused.release();
    await expect(delivery).rejects.toMatchObject({ code: "request_expired" });
    expect(store.request().status).toBe("pending");
    expect(store.response().state).toBe("claimed");
    await handoff.expire({ userId: "user-1", requestId: "request-1", version: 1 });
    expect(store.continuation(lease.responseId)).toMatchObject({
      state: "cancelled",
      sealedResponse: null,
    });
    expect(store.canonicalContinuation(lease.continuationId)).toMatchObject({
      state: "cancelled",
      sealedResponse: null,
    });
    expect(store.request()).toMatchObject({ status: "expired", version: 2 });
    expect(store.response()).toMatchObject({ state: "expired", envelope: null });
  });

  it("request expiry before unseal prevents admission and cancellation cleans up idempotently", async () => {
    const expired = setup();
    await expired.handoff.accept(acceptFixture());
    const expiredLease = await claim(expired.handoff);
    expired.advance(10_000);
    const admissions = expired.store.admissionAttempts;
    await expect(expired.handoff.deliver({ claim: expiredLease, worker: WORKER }))
      .rejects.toMatchObject({ code: "request_expired" });
    expect(expired.store.admissionAttempts).toBe(admissions);
    expect(expired.store.continuationDurableWrites).toBe(0);

    const cancelled = setup();
    await cancelled.handoff.accept(acceptFixture());
    const dto = await cancelled.handoff.cancel({
      userId: "user-1",
      requestId: "request-1",
      version: 1,
    });
    expect(dto).toMatchObject({ status: "cancelled", version: 2, response: null });
    expect(await cancelled.handoff.cancel({ userId: "user-1", requestId: "request-1", version: 1 }))
      .toEqual(dto);
    expect(cancelled.store.response()).toMatchObject({ state: "cancelled", envelope: null });
    await expect(cancelled.handoff.claim({ requestId: "request-1", worker: WORKER }))
      .rejects.toMatchObject({ code: "request_not_pending" });
  });

  it("cancellation after held admission blocks ack and atomically fences execution", async () => {
    const context = setup();
    await context.handoff.accept(acceptFixture());
    const lease = await claim(context.handoff);
    context.store.failAfterNextCommit("admit_continuation", new Error("uncertain"));
    await expect(context.handoff.deliver({ claim: lease, worker: WORKER }))
      .rejects.toMatchObject({ code: "delivery_outcome_uncertain" });
    expect(context.store.continuation(lease.responseId).state).toBe("held");
    await context.handoff.cancel({ userId: "user-1", requestId: "request-1", version: 1 });
    expect(context.store.continuation(lease.responseId)).toMatchObject({
      state: "cancelled",
      sealedResponse: null,
    });
    expect(context.store.canonicalContinuation(lease.continuationId)).toMatchObject({
      state: "cancelled",
      sealedResponse: null,
    });
    const admissions = context.store.admissionAttempts;
    await expect(context.handoff.deliver({ claim: lease, worker: WORKER }))
      .rejects.toMatchObject({ code: "request_not_pending" });
    expect(context.store.admissionAttempts).toBe(admissions);
    expect(context.store.request()).toMatchObject({ status: "cancelled", version: 2 });
  });

  it("keeps cancellation terminal instead of reclassifying it when expiry is later observed", async () => {
    const { handoff, store, advance } = setup();
    await handoff.accept(acceptFixture());
    await handoff.cancel({ userId: "user-1", requestId: "request-1", version: 1 });
    advance(10_000);
    await expect(handoff.claim({ requestId: "request-1", worker: WORKER }))
      .rejects.toMatchObject({ code: "request_not_pending" });
    expect(store.request()).toMatchObject({ status: "cancelled", version: 2 });
    expect(store.response()).toMatchObject({ state: "cancelled", envelope: null });
  });

  it("denies cross-user/session/run claims and deliveries without admission", async () => {
    const { handoff, store } = setup();
    await handoff.accept(acceptFixture());
    for (const worker of [
      { ...WORKER, userId: "user-other" },
      { ...WORKER, sessionId: "session-other" },
      { ...WORKER, runId: "run-other" },
    ]) {
      expect(await handoff.claim({ requestId: "request-1", worker })).toBeNull();
      expect(store.response().state).toBe("awaiting_delivery");
    }
    const lease = await claim(handoff);
    const admissions = store.admissionAttempts;
    await expect(handoff.deliver({
      claim: lease,
      worker: { ...WORKER, runId: "run-other" },
    })).rejects.toMatchObject({ code: "not_found" });
    expect(store.admissionAttempts).toBe(admissions);
    expect(store.continuationDurableWrites).toBe(0);
    expect(store.request().status).toBe("pending");
  });
});

describe("adapter retry and legal-transition conformance", () => {
  it("bounds serialization retries and rejects an illegal generation skip", async () => {
    const exhausted = setup();
    exhausted.store.forcedRetries = 20;
    await expect(exhausted.handoff.accept(acceptFixture()))
      .rejects.toMatchObject({ code: "transaction_retry_exhausted" });
    expect(exhausted.store.transactionAttempts).toBe(16);
    expect(exhausted.store.responseCount).toBe(0);

    const { handoff, store } = setup();
    await handoff.accept(acceptFixture());
    const row = store.response();
    const transitioned = await store.transaction(
      (tx) => tx.transitionResponse(row.responseId, 0, {
        kind: "claim",
        claimGeneration: 2,
        claim: {
          claimId: "illegal-skip",
          workerId: "worker-1",
          leaseExpiresAt: new Date(T0.getTime() + 1_000),
        },
      }),
      { operation: "claim", lockRequestId: "request-1" },
    );
    expect(transitioned).toBe(false);
    expect(store.response()).toMatchObject({ state: "awaiting_delivery", claimGeneration: 0 });
  });
});

describe("sealed-row adversarial failures and disclosure boundaries", () => {
  it("fails closed on ciphertext tamper and cross-record swaps before admission", async () => {
    const tampered = setup();
    await tampered.handoff.accept(acceptFixture());
    const tamperedLease = await claim(tampered.handoff);
    const row = tampered.store.response();
    tampered.store.replaceResponse({
      ...row,
      envelope: { ...row.envelope!, ciphertext: flipBase64(row.envelope!.ciphertext) },
    });
    const admissions = tampered.store.admissionAttempts;
    await expect(tampered.handoff.deliver({ claim: tamperedLease, worker: WORKER }))
      .rejects.toMatchObject({ code: "sealed_response_invalid" });
    expect(tampered.store.admissionAttempts).toBe(admissions);
    expect(tampered.store.continuationDurableWrites).toBe(0);
    expect(tampered.store.request().status).toBe("pending");

    const swapped = setup();
    swapped.store.seed(requestFixture({ requestId: "request-2" }));
    await swapped.handoff.accept(acceptFixture());
    await swapped.handoff.accept(acceptFixture({
      requestId: "request-2",
      clientResponseId: "client-response-2",
    }));
    const first = swapped.store.response("request-1");
    const second = swapped.store.response("request-2");
    swapped.store.replaceResponse({ ...first, envelope: second.envelope });
    const lease = await claim(swapped.handoff);
    const swappedAdmissions = swapped.store.admissionAttempts;
    await expect(swapped.handoff.deliver({ claim: lease, worker: WORKER }))
      .rejects.toMatchObject({ code: "sealed_response_invalid" });
    expect(swapped.store.admissionAttempts).toBe(swappedAdmissions);
    expect(swapped.store.continuationDurableWrites).toBe(0);
    expect(swapped.store.request().status).toBe("pending");
  });

  it("keeps canary and sealed bytes out of rows, DTOs, events, safe errors, and URLs", async () => {
    const context = setup();
    const receipt = await context.handoff.accept(acceptFixture());
    const pending = await context.handoff.listPending({ userId: "user-1", sessionId: "session-1" });
    expect(pending).toHaveLength(1);
    expect(pending[0]).toMatchObject({ response: null, sensitive: true, status: "pending" });
    const sealed = context.store.response().envelope!;
    const clientArtifacts = JSON.stringify({ receipt, pending });
    for (const bytes of [sealed.wrappedDek, sealed.iv, sealed.ciphertext, sealed.tag]) {
      expect(clientArtifacts).not.toContain(bytes);
    }
    expect(clientArtifacts).not.toContain(CANARY);

    const lease = await claim(context.handoff);
    const errors: unknown[] = [];
    context.store.beforeAdmission = async () => {
      throw new Error(`unsafe adapter detail ${CANARY}`);
    };
    try {
      await context.handoff.deliver({ claim: lease, worker: WORKER });
    } catch (error) {
      errors.push(error);
    }
    try {
      await context.handoff.accept(acceptFixture({ version: 99 }));
    } catch (error) {
      errors.push(error);
    }
    const safeErrors = errors.map((error) => ({
      name: error instanceof Error ? error.name : typeof error,
      code: error instanceof SensitiveResponseHandoffError ? error.code : null,
      message: error instanceof Error ? error.message : String(error),
    }));
    const url = new URL("https://client.invalid/system-requests/request-1");
    url.searchParams.set("receipt", JSON.stringify(receipt));
    url.searchParams.set("pending", JSON.stringify(pending));
    url.searchParams.set("errors", JSON.stringify(safeErrors));
    const allArtifacts = JSON.stringify({
      rows: context.store.serializedRows(),
      receipt,
      pending,
      events: context.events,
      safeErrors,
      url: url.toString(),
    });
    expect(allArtifacts).not.toContain(CANARY);
    expect(errors).toHaveLength(2);
    for (const error of errors) {
      expect(String(error)).not.toContain(CANARY);
      expect(JSON.stringify(error)).not.toContain(CANARY);
    }
  });
});

function claimFromStore(store: MemoryStore): SensitiveResponseClaim {
  const row = store.response();
  const request = store.request();
  expect(row.claim).not.toBeNull();
  return {
    requestId: row.requestId,
    responseId: row.responseId,
    claimId: row.claim!.claimId,
    claimGeneration: row.claimGeneration,
    leaseExpiresAt: row.claim!.leaseExpiresAt.toISOString(),
    requestVersion: row.requestVersion,
    requestExpiresAt: request.expiresAt.toISOString(),
    responseCommitment: row.responseCommitment,
    continuationId: continuationId(row.responseId),
  };
}
