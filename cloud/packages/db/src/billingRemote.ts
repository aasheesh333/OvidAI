import { AsyncLocalStorage } from "node:async_hooks";
import type { Db } from "./client.js";
import { billingUsers } from "./billingRepos.js";
import {
  billingRemote,
  type BillingRemoteEffect,
  type BillingRemoteOperation,
  type BillingRemoteOperationRecord,
} from "./billingRemoteRepos.js";

const authorityAccountContext = new AsyncLocalStorage<{
  uid: string;
  generation: number;
  lockedDb: Db;
}>();

export type BillingRemoteReadback =
  | { state: "live"; info: Record<string, unknown>; target?: string }
  | { state: "deleted" }
  | { state: "unavailable" };

export interface BillingRemoteSendResult {
  status: number;
  /** A 2xx response only. Failure bodies are never propagated or logged. */
  response?: Record<string, unknown>;
}

export interface BillingRemoteTransport {
  send(operation: BillingRemoteOperation): Promise<BillingRemoteSendResult>;
  read(operation: BillingRemoteOperation): Promise<BillingRemoteReadback>;
}

export interface BillingRemoteExecution {
  status: "completed";
  /** Present only for the create call whose 2xx response was actually received. */
  response?: Record<string, unknown>;
  /** Non-secret generated key/team target recovered from durable intent/readback. */
  target?: string;
  recovered: boolean;
}

export class BillingRemoteUnresolvedError extends Error {
  readonly code = "billing_projection_unavailable";
  constructor() {
    super("billing remote projection is unresolved");
    this.name = "BillingRemoteUnresolvedError";
  }
}

export class BillingRemoteTargetDeletedError extends Error {
  readonly code = "billing_target_deleted";
  constructor() {
    super("billing remote target no longer exists");
    this.name = "BillingRemoteTargetDeletedError";
  }
}

export class BillingRemotePlaintextUnavailableError extends Error {
  readonly code = "billing_key_recovery_required";
  constructor() {
    super("the generated key plaintext was not recovered; a second key will not be generated");
    this.name = "BillingRemotePlaintextUnavailableError";
  }
}

export class BillingRemoteStaleGenerationError extends Error {
  readonly code = "stale_billing_projection_generation";
  constructor() {
    super("stale billing projection generation");
    this.name = "BillingRemoteStaleGenerationError";
  }
}

export interface BillingRemoteAuthorityDeps {
  db: Db;
  transport: BillingRemoteTransport;
  /** Operator alert sink. It receives durable metadata, never a create response. */
  onUnresolved?: (operation: BillingRemoteOperationRecord) => void | Promise<void>;
}

export interface BillingRemoteExecuteOptions {
  /** Runs only when a new remote send is about to occur, never during recovery. */
  beforeSend?: () => Promise<void>;
  /**
   * Runs in-memory immediately after an acknowledged create, before readback.
   * It may install a plaintext reference in a secret store. It is never called
   * during recovery because LiteLLM cannot return the original plaintext twice.
   */
  onResult?: (
    operation: BillingRemoteOperation,
    response: Record<string, unknown>,
  ) => Promise<void>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function effectOf(operation: BillingRemoteOperation): BillingRemoteEffect {
  return operation.effect ?? "update";
}

function matchesValue(actual: unknown, expected: unknown): boolean {
  if (expected === null) return actual === null || actual === undefined;
  if (Array.isArray(expected)) {
    return Array.isArray(actual) && actual.length === expected.length &&
      expected.every((entry, index) => matchesValue(actual[index], entry));
  }
  if (isRecord(expected)) {
    return isRecord(actual) && Object.entries(expected).every(([field, value]) =>
      matchesValue(actual[field], value)
    );
  }
  return actual === expected;
}

function extraMatches(info: Record<string, unknown>, extra: Record<string, unknown> | undefined): boolean {
  return extra === undefined || Object.entries(extra).every(([field, expected]) =>
    matchesValue(info[field], expected)
  );
}

export function billingRemoteMatches(
  operation: BillingRemoteOperation,
  readback: BillingRemoteReadback,
): boolean {
  const effect = effectOf(operation);
  if (effect === "generate" &&
      (readback.state !== "live" || typeof readback.target !== "string" || readback.target === "")) {
    return false;
  }
  if (effect === "delete") return readback.state === "deleted";
  if (readback.state !== "live") return false;
  const info = readback.info;
  if ((effect === "block" || effect === "unblock") && operation.blocked !== undefined) {
    return info.blocked === operation.blocked;
  }
  if (operation.maxBudget !== undefined &&
      (operation.maxBudget === null ? info.max_budget !== null : info.max_budget !== operation.maxBudget)) {
    return false;
  }
  if (operation.budgetDuration !== undefined &&
      (info.budget_duration ?? null) !== operation.budgetDuration) return false;
  if (operation.spend !== undefined && Number(info.spend) !== operation.spend) return false;
  if (operation.rpmLimit !== undefined && (info.rpm_limit ?? null) !== operation.rpmLimit) return false;
  if (operation.tpmLimit !== undefined && (info.tpm_limit ?? null) !== operation.tpmLimit) return false;
  if (operation.maxParallelRequests !== undefined &&
      (info.max_parallel_requests ?? null) !== operation.maxParallelRequests) return false;
  if (operation.blocked !== undefined && info.blocked !== operation.blocked) return false;
  return extraMatches(info, operation.extra);
}

export function billingRemoteBody(operation: BillingRemoteOperation): Record<string, unknown> {
  const effect = effectOf(operation);
  if (effect === "delete") return { keys: [operation.target] };
  if (effect === "block" || effect === "unblock") return { key: operation.target };
  const body: Record<string, unknown> = { ...(operation.extra ?? {}) };
  if (operation.kind === "user") body.user_id = operation.target;
  if (operation.kind === "key" && effect !== "generate") body.key = operation.target;
  if (operation.kind === "team" && effect !== "generate") body.team_id = operation.target;
  if (operation.maxBudget !== undefined) body.max_budget = operation.maxBudget;
  if (operation.budgetDuration !== undefined) body.budget_duration = operation.budgetDuration;
  if (operation.spend !== undefined) body.spend = operation.spend;
  if (operation.rpmLimit !== undefined) body.rpm_limit = operation.rpmLimit;
  if (operation.tpmLimit !== undefined) body.tpm_limit = operation.tpmLimit;
  if (operation.maxParallelRequests !== undefined) {
    body.max_parallel_requests = operation.maxParallelRequests;
  }
  return body;
}

function endpoint(operation: BillingRemoteOperation): string {
  const effect = effectOf(operation);
  if (operation.kind === "user") return "/user/update";
  if (operation.kind === "team") return effect === "generate" ? "/team/new" : "/team/update";
  if (effect === "generate") return "/key/generate";
  if (effect === "delete") return "/key/delete";
  if (effect === "block") return "/key/block";
  if (effect === "unblock") return "/key/unblock";
  return "/key/update";
}

function createdTargetFrom(
  operation: BillingRemoteOperation,
  response: Record<string, unknown> | undefined,
): string | null {
  if (effectOf(operation) !== "generate" || response === undefined) return null;
  const value = operation.kind === "team" ? response.team_id : response.token ?? response.key_id;
  return typeof value === "string" && value !== "" ? value : null;
}

function assertSafeIntent(operation: BillingRemoteOperation): void {
  if (operation.uid === "" || !Number.isSafeInteger(operation.generation) || operation.generation < 1) {
    throw new Error("billing remote operation requires a durable scope and generation");
  }
  if (operation.target === "") throw new Error("billing remote operation requires a target");
  if (operation.extra !== undefined && Object.hasOwn(operation.extra, "key")) {
    throw new Error("plaintext key material is forbidden in a durable remote intent");
  }
  if (effectOf(operation) === "generate" && operation.idempotencyKey === undefined) {
    throw new Error("remote generate requires a stable idempotency key");
  }
  if (effectOf(operation) === "generate" && operation.kind === "key" &&
      typeof operation.extra?.key_alias !== "string") {
    throw new Error("key generate requires the durable alias as key_alias");
  }
}

export function createBillingRemoteAuthority(deps: BillingRemoteAuthorityDeps) {
  const authorityDb = (): Db => authorityAccountContext.getStore()?.lockedDb ?? deps.db;

  async function alert(operation: BillingRemoteOperationRecord): Promise<void> {
    try {
      await deps.onUnresolved?.(operation);
    } catch {
      // Alert delivery cannot turn an unresolved mutation into success or erase
      // its durable marker. The original unresolved error is preserved.
    }
  }

  async function unresolved(operation: BillingRemoteOperationRecord): Promise<never> {
    await alert(operation);
    throw new BillingRemoteUnresolvedError();
  }

  async function read(operation: BillingRemoteOperation): Promise<BillingRemoteReadback> {
    try {
      return await deps.transport.read(operation);
    } catch {
      return { state: "unavailable" };
    }
  }

  async function assertCurrent(operation: BillingRemoteOperation): Promise<void> {
    if (!(await billingUsers.isLatestRefresh(authorityDb(), operation.uid, operation.generation))) {
      throw new BillingRemoteStaleGenerationError();
    }
  }

  async function recoveredResult(
    operation: BillingRemoteOperation,
  ): Promise<BillingRemoteExecution> {
    const current = await billingRemote.get(authorityDb(), operation);
    return {
      status: "completed",
      ...(current?.createdTarget === undefined ? {} : { target: current.createdTarget }),
      recovered: true,
    };
  }

  async function completeExisting(
    operation: BillingRemoteOperationRecord,
    resolution: "readback" | "not-required" | "terminal-404",
  ): Promise<void> {
    if (!(await billingRemote.complete(authorityDb(), operation, resolution))) {
      throw new BillingRemoteUnresolvedError();
    }
  }

  async function retireExisting(
    operation: BillingRemoteOperationRecord,
    resolution: "terminal-404" | "superseded-not-sent" | "definite-rejection",
  ): Promise<void> {
    if (!(await billingRemote.retire(authorityDb(), operation, resolution))) {
      throw new BillingRemoteUnresolvedError();
    }
  }

  async function deletedOutcome(
    pending: BillingRemoteOperationRecord,
    desired: BillingRemoteOperation,
  ): Promise<"retired" | "completed" | "deleted-target"> {
    const same = billingRemote.same(pending, desired);
    const effect = effectOf(pending);
    if (same && effect === "update" && pending.kind !== "user") {
      await retireExisting(pending, "terminal-404");
      return "deleted-target";
    }
    if (same && (effect === "delete" || effect === "block" || effect === "unblock")) {
      await completeExisting(pending, "terminal-404");
      return "completed";
    }
    if (pending.kind === "key" && effect !== "generate") {
      await retireExisting(pending, "terminal-404");
      return "retired";
    }
    throw new BillingRemoteUnresolvedError();
  }

  /**
   * Reconcile only operations with a definite terminal request outcome. An
   * uncertain call is never replayed and is never completed by one readback.
   */
  async function reconcile(
    pending: BillingRemoteOperationRecord,
    desired: BillingRemoteOperation,
  ): Promise<"continue" | "completed" | "send"> {
    // Recovery may span billing generations. The current desired writer's
    // generation fences this lock; an older persisted generation is not an
    // independent license to send or block reconciliation forever.
    await assertCurrent(desired);
    const same = billingRemote.same(pending, desired);
    const phase = pending.phase ?? "prepared";
    if (phase === "prepared") {
      if (same) return "send";
      await retireExisting(pending, "superseded-not-sent");
      return "continue";
    }
    if (phase === "rejected") {
      if (same) return "send";
      await retireExisting(pending, "definite-rejection");
      return "continue";
    }

    const readback = await read(pending);
    if (phase === "uncertain") {
      // Authenticated 404 is a terminal target outcome for key lifecycle
      // operations. A missing generate alias is NOT terminal: an accepted
      // create may still be delayed, so it remains operator-unresolved.
      if (pending.kind === "key" && effectOf(pending) !== "generate" && readback.state === "deleted") {
        const outcome = await deletedOutcome(pending, desired);
        if (outcome === "deleted-target") throw new BillingRemoteTargetDeletedError();
        return outcome === "completed" ? "completed" : "continue";
      }
      return unresolved(pending);
    }

    // A 2xx response was durably recorded before the process stopped. Readback
    // may finish that exact operation, but a mismatch never causes a blind
    // replay (and especially never replays an older paid intent).
    if (readback.state === "deleted") {
      const outcome = await deletedOutcome(pending, desired);
      if (outcome === "deleted-target") throw new BillingRemoteTargetDeletedError();
      return outcome === "completed" ? "completed" : "continue";
    }
    if (readback.state === "live" && billingRemoteMatches(pending, readback)) {
      if (effectOf(pending) === "generate" && readback.target !== undefined) {
        if (!(await billingRemote.bindCreatedTarget(authorityDb(), pending, readback.target))) {
          throw new BillingRemoteUnresolvedError();
        }
      }
      await completeExisting(pending, "readback");
      // A changed create body may recover the reference only. It must never
      // cause a second create; the caller performs a normal target update.
      return same || effectOf(pending) === "generate" ? "completed" : "continue";
    }
    // Never turn an alias/body mismatch into a fresh credential.
    return unresolved(pending);
  }

  async function execute(
    desired: BillingRemoteOperation,
    opts: BillingRemoteExecuteOptions = {},
  ): Promise<BillingRemoteExecution> {
    assertSafeIntent(desired);
    await assertCurrent(desired);

    const exactBefore = await billingRemote.get(authorityDb(), desired);
    if (exactBefore?.status === "replaced") {
      return recoveredResult(desired);
    }
    // An operator-drained generate may be reconciled by its stable alias. A
    // live alias never generates again; authenticated absence after confirmed
    // drain permits the original create, not a new lifecycle identity.

    for (const pending of await billingRemote.listUnresolved(authorityDb(), desired.uid)) {
      const outcome = await reconcile(pending, desired);
      if (outcome === "completed") return recoveredResult(desired);
    }

    const completed = await billingRemote.getCompleted(authorityDb(), desired);
    if (completed !== null) return recoveredResult(desired);

    // Exact desired-state readback suppresses a no-op send across restart and
    // across multiple targets. An explicit clock restart is the exception:
    // matching duration is not proof that the requested reset already happened.
    const before = await read(desired);
    if (effectOf(desired) === "update" && desired.kind !== "user" && before.state === "deleted") {
      throw new BillingRemoteTargetDeletedError();
    }
    const alreadyApplied = effectOf(desired) !== "generate" &&
      !desired.restartBudgetClock && billingRemoteMatches(desired, before);
    const terminalAbsent = before.state === "deleted" &&
      (effectOf(desired) === "delete" || effectOf(desired) === "block" || effectOf(desired) === "unblock");

    const begin = await billingRemote.begin(authorityDb(), desired);
    if (begin === "blocked") {
      const pending = await billingRemote.getPending(authorityDb(), desired.uid);
      if (pending !== null) return unresolved(pending);
      throw new BillingRemoteUnresolvedError();
    }
    if (begin === "completed") return recoveredResult(desired);

    const current = await billingRemote.get(authorityDb(), desired);
    if (current === null || current.status !== "pending") throw new BillingRemoteUnresolvedError();
    if (effectOf(desired) === "generate" && before.state === "live" && before.target !== undefined) {
      if (!(await billingRemote.bindCreatedTarget(authorityDb(), current, before.target))) {
        throw new BillingRemoteUnresolvedError();
      }
    }
    if (alreadyApplied || terminalAbsent) {
      await completeExisting(current, terminalAbsent ? "terminal-404" : "not-required");
      return recoveredResult(desired);
    }
    if (before.state === "live" && effectOf(desired) === "generate") {
      // The aliased credential exists but its original secret is not available.
      // Do not issue another create even if the body differs only by generation.
      if (billingRemoteMatches(desired, before)) {
        await completeExisting(current, "readback");
      }
      throw new BillingRemotePlaintextUnavailableError();
    }

    await assertCurrent(desired);
    await opts.beforeSend?.();
    if (!(await billingRemote.markAttempted(authorityDb(), current))) {
      throw new BillingRemoteUnresolvedError();
    }
    let sent: BillingRemoteSendResult;
    try {
      sent = await deps.transport.send(desired);
    } catch {
      sent = { status: 0 };
    }
    if (sent.status === 0) {
      const pending = await billingRemote.get(authorityDb(), desired);
      if (pending === null) throw new BillingRemoteUnresolvedError();
      return unresolved(pending);
    }
    if (sent.status < 200 || sent.status >= 300) {
      if (sent.status === 404 && desired.kind === "key") {
        const after = await read(desired);
        if (after.state === "deleted") {
          const outcome = await deletedOutcome(current, desired);
          if (outcome === "completed") return recoveredResult(desired);
          if (outcome === "deleted-target") throw new BillingRemoteTargetDeletedError();
        }
      }
      await billingRemote.markRejected(authorityDb(), desired);
      const pending = await billingRemote.get(authorityDb(), desired);
      if (pending === null) throw new BillingRemoteUnresolvedError();
      return unresolved(pending);
    }

    if (!(await billingRemote.markAcknowledged(authorityDb(), desired))) {
      throw new BillingRemoteUnresolvedError();
    }
    const createdTarget = createdTargetFrom(desired, sent.response);
    if (createdTarget !== null &&
        !(await billingRemote.bindCreatedTarget(authorityDb(), desired, createdTarget))) {
      throw new BillingRemoteUnresolvedError();
    }
    if (sent.response !== undefined && opts.onResult !== undefined) {
      try {
        await opts.onResult(desired, sent.response);
      } catch {
        const pending = await billingRemote.get(authorityDb(), desired);
        if (pending !== null) await alert(pending);
        throw new BillingRemoteUnresolvedError();
      }
    }

    const after = await read(desired);
    if (after.state === "deleted") {
      const outcome = await deletedOutcome(current, desired);
      if (outcome === "completed") {
        return {
          status: "completed",
          ...(sent.response === undefined ? {} : { response: sent.response }),
          ...(createdTarget === null ? {} : { target: createdTarget }),
          recovered: false,
        };
      }
      if (outcome === "deleted-target") throw new BillingRemoteTargetDeletedError();
    }
    if (!billingRemoteMatches(desired, after)) {
      const pending = await billingRemote.get(authorityDb(), desired);
      if (pending === null) throw new BillingRemoteUnresolvedError();
      return unresolved(pending);
    }
    if (effectOf(desired) === "generate" && createdTarget === null && after.target !== undefined &&
        !(await billingRemote.bindCreatedTarget(authorityDb(), desired, after.target))) {
      throw new BillingRemoteUnresolvedError();
    }
    const completedOperation = createdTarget === null ? current : { ...current, createdTarget };
    await completeExisting(completedOperation, "readback");
    const resultTarget = createdTarget ?? after.target;
    return {
      status: "completed",
      ...(sent.response === undefined ? {} : { response: sent.response }),
      ...(resultTarget === undefined ? {} : { target: resultTarget }),
      recovered: false,
    };
  }

  return {
    execute,

    /** Cross-process scope lock + durable latest generation for non-mint callers. */
    async withAccount<T>(
      uid: string,
      operation: (generation: number, lockedDb: Db) => Promise<T>,
    ): Promise<T> {
      const current = authorityAccountContext.getStore();
      if (current?.uid === uid) {
        if (!(await billingUsers.isLatestRefresh(authorityDb(), uid, current.generation))) {
          throw new BillingRemoteStaleGenerationError();
        }
        return operation(current.generation, current.lockedDb);
      }
      return billingUsers.withBillingRemoteWriteLock(deps.db, uid, async (lockedDb) => {
        const { generation } = await billingUsers.beginRefresh(lockedDb, uid);
        if (!(await billingUsers.isLatestRefresh(lockedDb, uid, generation))) {
          throw new BillingRemoteStaleGenerationError();
        }
        return authorityAccountContext.run(
          { uid, generation, lockedDb },
          () => operation(generation, lockedDb),
        );
      });
    },

    listUnresolved(uid?: string): Promise<BillingRemoteOperationRecord[]> {
      return billingRemote.listUnresolved(authorityDb(), uid);
    },

    /** Requires owner-authenticated external drain evidence at the route boundary. */
    async markDrained(uid: string, operationId: string, generation: number): Promise<boolean> {
      const current = authorityAccountContext.getStore();
      if (current?.uid === uid) {
        // Nested withAccount already owns exactly one reservation/session lock.
        // Validate against its committed generation, then use that same handle;
        // reacquiring here would deadlock max:1 and self-lock every other pool.
        if (current.generation !== generation ||
            !(await billingUsers.isLatestRefresh(current.lockedDb, uid, generation))) {
          throw new BillingRemoteStaleGenerationError();
        }
        return billingRemote.markDrained(current.lockedDb, uid, operationId, generation);
      }
      // External drain has no existing context: acquire exactly one reservation
      // and one session advisory lock, retaining independent commit boundaries.
      return billingUsers.withBillingRemoteWriteLock(deps.db, uid, async (lockedDb) => {
        if (!(await billingUsers.isLatestRefresh(lockedDb, uid, generation))) {
          throw new BillingRemoteStaleGenerationError();
        }
        return billingRemote.markDrained(lockedDb, uid, operationId, generation);
      });
    },
  };
}

export type BillingRemoteAuthority = ReturnType<typeof createBillingRemoteAuthority>;

export function createLiteLlmBillingTransport(opts: {
  baseUrl: string;
  masterKey: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}): BillingRemoteTransport {
  const root = opts.baseUrl.replace(/\/+$/, "");
  const fetchImpl = opts.fetchImpl ?? fetch;
  const timeoutMs = opts.timeoutMs ?? 20_000;

  async function request(
    path: string,
    method: "GET" | "POST",
    body?: Record<string, unknown>,
    params?: Record<string, string>,
  ): Promise<{ status: number; payload: unknown }> {
    try {
      const url = new URL(`${root}${path}`);
      for (const [field, value] of Object.entries(params ?? {})) url.searchParams.set(field, value);
      const response = await fetchImpl(url, {
        method,
        headers: {
          authorization: `Bearer ${opts.masterKey}`,
          ...(body === undefined ? { "cache-control": "no-store" } : { "content-type": "application/json" }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
      });
      let payload: unknown = null;
      try {
        payload = await response.json();
      } catch {
        // Status remains authoritative for definite errors; a malformed 2xx
        // cannot supply a create response or a successful readback.
      }
      return { status: response.status, payload };
    } catch {
      return { status: 0, payload: null };
    }
  }

  function liveInfo(operation: BillingRemoteOperation, payload: unknown): BillingRemoteReadback {
    if (!isRecord(payload)) return { state: "unavailable" };
    const candidate = operation.kind === "user"
      ? payload.user_info
      : operation.kind === "team"
        ? payload.team_info ?? payload.info ?? payload
        : payload.info ?? payload;
    return isRecord(candidate) ? { state: "live", info: candidate } : { state: "unavailable" };
  }

  async function readDirect(operation: BillingRemoteOperation, target: string): Promise<BillingRemoteReadback> {
    const path = operation.kind === "user" ? "/user/info" : operation.kind === "team" ? "/team/info" : "/key/info";
    const field = operation.kind === "user" ? "user_id" : operation.kind === "team" ? "team_id" : "key";
    const result = await request(path, "GET", undefined, { [field]: target });
    if (result.status === 404) return { state: "deleted" };
    if (result.status < 200 || result.status >= 300) return { state: "unavailable" };
    const readback = liveInfo(operation, result.payload);
    return effectOf(operation) === "generate" && readback.state === "live"
      ? { ...readback, target }
      : readback;
  }

  async function findByAlias(operation: BillingRemoteOperation): Promise<BillingRemoteReadback> {
    const alias = operation.target;
    const userId = operation.kind === "key" ? operation.extra?.user_id : undefined;
    if (operation.kind === "key" && typeof userId !== "string") return { state: "unavailable" };
    let previous = "";
    for (let page = 1; page <= 100; page += 1) {
      const path = operation.kind === "team" ? "/team/list" : "/key/list";
      const result = await request(path, "GET", undefined, {
        ...(typeof userId === "string" ? { user_id: userId } : {}),
        page: String(page),
        size: "100",
      });
      if (result.status < 200 || result.status >= 300 || !isRecord(result.payload)) {
        return { state: "unavailable" };
      }
      const raw = operation.kind === "team"
        ? result.payload.teams ?? result.payload.data
        : result.payload.keys;
      if (!Array.isArray(raw)) return { state: "unavailable" };
      const signature = JSON.stringify(raw);
      if (signature === previous) return { state: "unavailable" };
      previous = signature;
      for (const entry of raw) {
        if (!isRecord(entry) || entry.key_alias !== alias && entry.team_alias !== alias) continue;
        const target = operation.kind === "team" ? entry.team_id : entry.token ?? entry.key_id;
        if (typeof target !== "string" || target === "") return { state: "unavailable" };
        return { state: "live", info: entry, target };
      }
      const totalPages = typeof result.payload.total_pages === "number" ? result.payload.total_pages : null;
      if (totalPages !== null ? page >= totalPages : raw.length < 100) return { state: "deleted" };
    }
    return { state: "unavailable" };
  }

  return {
    async send(operation) {
      const result = await request(endpoint(operation), "POST", billingRemoteBody(operation));
      if (result.status < 200 || result.status >= 300) return { status: result.status };
      return {
        status: result.status,
        ...(isRecord(result.payload) ? { response: result.payload } : {}),
      };
    },

    async read(operation) {
      if (effectOf(operation) === "generate" && operation.createdTarget === undefined) {
        return findByAlias(operation);
      }
      return readDirect(operation, operation.createdTarget ?? operation.target);
    },
  };
}
