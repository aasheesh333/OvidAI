import type {
  ProviderAuthState,
  ProviderHealthState,
} from "@ovid/shared";

import {
  assertClosedProviderSchema,
  type ProviderOperation,
} from "./providers/types.js";

/** Persisted connection facts plus secret presence, never secret material. */
export interface HealthConnection {
  connectionId: string;
  userId: string;
  providerId: string;
  enabled: boolean;
  agentEnabled: boolean;
  authState: ProviderAuthState;
  healthState: ProviderHealthState;
  lastCheckedAt: string | null;
  lastSuccessAt: string | null;
  configVersion: number;
  disconnectGeneration: number;
  hasSecrets: boolean;
}

/** Internal store facts that must never be added to the public health DTO. */
export interface HealthConnectionRecord extends HealthConnection {
  /** Exact persisted legacy auth_state="unknown" plus config=null evidence. */
  legacyUnknownAuthWithoutConfig?: true;
}

export interface HealthConnectionExpected {
  configVersion: number;
  disconnectGeneration: number;
}

/** Transient progress is persisted conditionally; final evidence owns both timestamps. */
export type ConnectionHealthWriteState =
  | "checking"
  | "healthy"
  | "degraded"
  | "needs_auth"
  | "refreshing"
  | "revoked"
  | "unavailable";

export interface HealthWrite {
  connectionId: string;
  userId: string;
  expected: HealthConnectionExpected;
  state: ConnectionHealthWriteState;
  /** Set only when that check actually completed. */
  checkedAt?: Date;
  /** Set only when the selected typed operation actually succeeded. */
  succeededAt?: Date;
}

export interface HealthTokenWrite {
  connectionId: string;
  userId: string;
  expected: HealthConnectionExpected;
  /** Opaque to this module. It is forwarded once and never cached or projected. */
  token: unknown;
  signal: AbortSignal;
}

/**
 * The production adapter must implement every write as one conditional,
 * owner-scoped store operation. A null/false result means the fence lost.
 * disconnect() must bump disconnectGeneration and remove OAuth material in
 * the same transaction, matching providerConnections.disconnectConnection.
 */
export interface ConnectionHealthStore {
  get(connectionId: string, uid: string): Promise<HealthConnectionRecord | null>;
  writeHealth(write: HealthWrite): Promise<HealthConnection | null>;
  writeRefreshedToken(write: HealthTokenWrite): Promise<boolean>;
  disconnect(
    connectionId: string,
    uid: string,
    expectedConfigVersion: number,
  ): Promise<HealthConnection | null>;
}

export type HealthOperationOutcome =
  | { status: "succeeded" }
  | { status: "failed"; reason: "unauthorized" | "degraded" | "unavailable" };

export type HealthRefreshOutcome =
  | { status: "refreshed" }
  | { status: "failed"; reason: "invalid_grant" | "unauthorized" | "unavailable" };

export interface HealthOperationInput {
  operation: ProviderOperation;
  expected: HealthConnectionExpected;
  signal: AbortSignal;
}

export interface HealthRefreshInput {
  expected: HealthConnectionExpected;
  signal: AbortSignal;
  /** Origin-only write path. Its argument never enters the shared refresh promise. */
  writeToken(token: unknown): Promise<boolean>;
}

/** A distinct, lifecycle-owned transport for one selected operation. */
export interface HealthOperationSession {
  /** Executes the real typed operation, not a generic ping or descriptor check. */
  execute(input: HealthOperationInput): Promise<HealthOperationOutcome>;
  /** Maps provider HTTP 401/invalid_grant to the typed outcomes above. */
  refresh?(input: HealthRefreshInput): Promise<HealthRefreshOutcome>;
  cancelReconnect?(): void | Promise<void>;
  close(): void | Promise<void>;
}

export interface HealthOpenInput {
  /** Secret-free metadata only. Secret resolution belongs inside the adapter. */
  connection: HealthConnection;
  operation: ProviderOperation;
  expected: HealthConnectionExpected;
  signal: AbortSignal;
}

export interface HealthProvider {
  providerId: string;
  readiness: "supported";
  operations: readonly ProviderOperation[];
  /** Present for ProviderDefinition-backed production compositions. */
  connectionSchema?: Record<string, unknown>;
}

export interface HealthRuntimeEviction {
  connectionId: string;
  userId: string;
  reason: "ttl" | "capacity";
}

export interface ConnectionHealthLifecycleDeps {
  store: ConnectionHealthStore;
  providers: readonly HealthProvider[];
  open(input: HealthOpenInput): Promise<HealthOperationSession>;
  /** Close non-health router transports and legacy OAuth calls for this connection. */
  closeOwnedTransports?(connectionId: string, uid: string): void | Promise<void>;
  now?(): Date;
  /** Idle runtime TTL; defaults to five minutes. Timers are unref'd. */
  runtimeTtlMs?: number;
  /** Maximum retained connection runtimes; defaults to 1024. */
  maxRuntimes?: number;
  /** Non-secret diagnostics for TTL/capacity eviction. */
  onRuntimeEvicted?(event: HealthRuntimeEviction): void;
}

export type HealthTransitionCode =
  | "checked"
  | "unchanged"
  | "invalid_operation"
  | "connection_changed"
  | "disconnected";

export type HealthTransitionReason =
  | "missing_auth"
  | "unauthorized"
  | "invalid_grant"
  | "degraded"
  | "unavailable"
  | "invalid_operation"
  | "unsupported_operation";

export interface HealthTransition {
  connection: HealthConnection;
  from: ProviderHealthState;
  to: ProviderHealthState;
  lastCheckedAt: string | null;
  lastSuccessAt: string | null;
  persisted: boolean;
  code: HealthTransitionCode;
  reason?: HealthTransitionReason;
}

export interface ConnectionHealthLifecycle {
  /** Compose only at an authenticated health endpoint or selected lazy operation need. */
  checkConnectionHealth(
    connectionId: string,
    uid: string,
    operationId: string,
  ): Promise<HealthTransition>;
  /** Secret-free DTO projection with this process's live transient activity. */
  getConnectionHealth(connectionId: string, uid: string): Promise<HealthConnection>;
  disconnectConnection(connectionId: string, uid: string): Promise<HealthConnection>;
}

export type ConnectionHealthErrorCode =
  | "not_found"
  | "connection_changed"
  | "transport_close_failed"
  | "unavailable";

export class ConnectionHealthError extends Error {
  constructor(readonly code: ConnectionHealthErrorCode) {
    super(code);
    this.name = "ConnectionHealthError";
  }
}

interface ConnectionRuntime {
  readonly attempts: Set<HealthAttempt>;
  refresh?: {
    epoch: number;
    promise: Promise<HealthRefreshOutcome>;
  };
  disconnect?: Promise<HealthConnection>;
  idleTimer?: ReturnType<typeof setTimeout>;
  lastUsedAt: number;
  epoch: number;
}

interface HealthAttempt {
  readonly connectionId: string;
  readonly uid: string;
  readonly expected: HealthConnectionExpected;
  readonly controller: AbortController;
  readonly sessions: Set<HealthOperationSession>;
  readonly epoch: number;
  invalidated: boolean;
}

class HealthFence extends Error {
  constructor(readonly kind: "connection_changed" | "disconnected") {
    super(kind);
  }
}

const DISCONNECT_REASON = "connection_disconnected";
const TERMINAL_HEALTH = new Set<ProviderHealthState>(["disabled", "revoked"]);
const READ_METHODS = new Set(["GET", "HEAD"]);
const DEFAULT_RUNTIME_TTL_MS = 300_000;
const DEFAULT_MAX_RUNTIMES = 1_024;

function expectedOf(row: HealthConnection): HealthConnectionExpected {
  return {
    configVersion: row.configVersion,
    disconnectGeneration: row.disconnectGeneration,
  };
}

function validTimestamp(value: string | null): value is string {
  return value !== null && Number.isFinite(Date.parse(value));
}

function unavailableProjection(connection: HealthConnection): HealthConnection {
  return { ...connection, healthState: "unavailable" };
}

function nonSecretFacts(connection: HealthConnection): HealthConnection {
  return {
    connectionId: connection.connectionId,
    userId: connection.userId,
    providerId: connection.providerId,
    enabled: connection.enabled,
    agentEnabled: connection.agentEnabled,
    authState: connection.authState,
    healthState: connection.healthState,
    lastCheckedAt: connection.lastCheckedAt,
    lastSuccessAt: connection.lastSuccessAt,
    configVersion: connection.configVersion,
    disconnectGeneration: connection.disconnectGeneration,
    hasSecrets: connection.hasSecrets,
  };
}

/**
 * Derive presentation solely from persisted facts. Secret presence and legacy
 * configured/authorized flags are never success evidence. Orphaned transient
 * rows fail closed instead of remaining falsely healthy/checking forever.
 */
function projectConnectionHealthFacts(
  connection: HealthConnection,
  activity?: "checking" | "refreshing",
): HealthConnection {
  // Never spread a persistence row into a public transition: adapters may
  // legitimately have extra config/sealed columns outside this narrow type.
  connection = nonSecretFacts(connection);
  if (connection.authState === "revoked" || connection.healthState === "revoked") {
    return { ...connection, healthState: "revoked" };
  }
  if (!connection.enabled) return { ...connection, healthState: "disabled" };
  if (connection.healthState === "never_checked" &&
      (connection.lastCheckedAt !== null || connection.lastSuccessAt !== null)) {
    return unavailableProjection(connection);
  }
  if (activity !== undefined) return { ...connection, healthState: activity };

  switch (connection.healthState) {
    case "never_checked":
      return connection.lastCheckedAt === null && connection.lastSuccessAt === null
        ? connection
        : unavailableProjection(connection);
    case "checking":
      return activity === "checking"
        ? connection
        : connection.lastCheckedAt === null
          ? { ...connection, healthState: "never_checked" }
          : unavailableProjection(connection);
    case "refreshing":
      return activity === "refreshing" ? connection : unavailableProjection(connection);
    case "healthy":
      return validTimestamp(connection.lastCheckedAt) &&
          connection.lastSuccessAt === connection.lastCheckedAt
        ? connection
        : unavailableProjection(connection);
    case "degraded":
    case "unavailable":
      return validTimestamp(connection.lastCheckedAt) ? connection : unavailableProjection(connection);
    case "needs_auth":
      return connection;
    case "disabled":
      // An enabled row cannot truthfully project disabled.
      return unavailableProjection(connection);
    case "revoked":
      // Handled above; this branch documents exhaustiveness for future states.
      return { ...connection, healthState: "revoked" };
  }
}

/** Enforce the public evidence invariant after every projection branch. */
export function projectConnectionHealth(
  connection: HealthConnection,
  activity?: "checking" | "refreshing",
): HealthConnection {
  const projected = projectConnectionHealthFacts(connection, activity);
  return projected.healthState === "never_checked" &&
      (projected.lastCheckedAt !== null || projected.lastSuccessAt !== null)
    ? unavailableProjection(projected)
    : projected;
}

function transition(
  connection: HealthConnection,
  from: ProviderHealthState,
  persisted: boolean,
  code: HealthTransitionCode,
  reason?: HealthTransitionReason,
): HealthTransition {
  return {
    connection,
    from,
    to: connection.healthState,
    lastCheckedAt: connection.lastCheckedAt,
    lastSuccessAt: connection.lastSuccessAt,
    persisted,
    code,
    ...(reason === undefined ? {} : { reason }),
  };
}

function supportsHealthOperation(operation: ProviderOperation): boolean {
  if (operation.effect !== "read" || !READ_METHODS.has(operation.request.method)) return false;
  try {
    assertClosedProviderSchema(operation.inputSchema);
    return true;
  } catch {
    return false;
  }
}

function hasOnlySchemaKeys(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = [],
): boolean {
  const allowed = new Set([...required, ...optional]);
  return required.every((key) => Object.prototype.hasOwnProperty.call(value, key)) &&
    Object.keys(value).every((key) => allowed.has(key));
}

function legacyCredentialFreeConfigCheck(
  connection: HealthConnectionRecord,
  provider: HealthProvider | undefined,
): boolean {
  if (connection.authState !== "missing" ||
      connection.legacyUnknownAuthWithoutConfig !== true ||
      provider?.providerId !== "fetch") return false;
  const schema = provider.connectionSchema;
  if (schema === undefined) return false;
  try {
    assertClosedProviderSchema(schema);
  } catch {
    return false;
  }
  if (!hasOnlySchemaKeys(schema, [
    "type",
    "properties",
    "required",
    "additionalProperties",
    "minProperties",
    "maxProperties",
  ]) || schema.type !== "object" || schema.additionalProperties !== false ||
      schema.minProperties !== 1 || schema.maxProperties !== 1 ||
      !Array.isArray(schema.required) || schema.required.length !== 1 || schema.required[0] !== "url") {
    return false;
  }
  const properties = schema.properties;
  if (typeof properties !== "object" || properties === null || Array.isArray(properties) ||
      Object.keys(properties).length !== 1 ||
      !Object.prototype.hasOwnProperty.call(properties, "url")) return false;
  const url = (properties as Record<string, unknown>).url;
  if (typeof url !== "object" || url === null || Array.isArray(url)) return false;
  const leaf = url as Record<string, unknown>;
  // Only the canonical primitive URL leaf and its non-secret metadata qualify.
  // In particular, properties/items/default/examples and every other extension
  // are rejected rather than being trusted not to carry credentials.
  return hasOnlySchemaKeys(leaf, ["type", "minLength", "maxLength"], ["title", "description"]) &&
    leaf.type === "string" && leaf.minLength === 1 && leaf.maxLength === 2_048 &&
    (leaf.title === undefined || typeof leaf.title === "string") &&
    (leaf.description === undefined || typeof leaf.description === "string");
}

export function createConnectionHealthLifecycle(
  deps: ConnectionHealthLifecycleDeps,
): ConnectionHealthLifecycle {
  const providers = new Map<string, HealthProvider>();
  for (const provider of deps.providers) {
    if (providers.has(provider.providerId)) throw new Error("duplicate_health_provider");
    providers.set(provider.providerId, provider);
  }

  // Only non-secret identity/epoch/status-only single-flight bookkeeping lives here.
  const runtimes = new Map<string, ConnectionRuntime>();
  const reconnectCancellations = new WeakMap<HealthOperationSession, Promise<void>>();
  const closing = new WeakMap<HealthOperationSession, Promise<void>>();
  const now = deps.now ?? (() => new Date());
  const runtimeTtlMs = Math.max(1, Math.floor(deps.runtimeTtlMs ?? DEFAULT_RUNTIME_TTL_MS));
  const maxRuntimes = Math.max(1, Math.floor(deps.maxRuntimes ?? DEFAULT_MAX_RUNTIMES));

  function key(connectionId: string, uid: string): string {
    return JSON.stringify([uid, connectionId]);
  }

  function idle(runtime: ConnectionRuntime): boolean {
    return runtime.attempts.size === 0 && runtime.refresh === undefined && runtime.disconnect === undefined;
  }

  function evict(id: string, runtime: ConnectionRuntime, reason: "ttl" | "capacity"): void {
    if (runtimes.get(id) !== runtime || !idle(runtime)) return;
    if (runtime.idleTimer !== undefined) clearTimeout(runtime.idleTimer);
    runtime.idleTimer = undefined;
    runtimes.delete(id);
    try {
      const [userId, connectionId] = JSON.parse(id) as [string, string];
      deps.onRuntimeEvicted?.({ connectionId, userId, reason });
    } catch {
      // Diagnostics must never break lifecycle fencing or cleanup.
    }
  }

  function scheduleIdle(id: string, runtime: ConnectionRuntime): void {
    if (!idle(runtime)) return;
    if (runtime.idleTimer !== undefined) clearTimeout(runtime.idleTimer);
    runtime.lastUsedAt = Date.now();
    runtime.idleTimer = setTimeout(() => evict(id, runtime, "ttl"), runtimeTtlMs);
    runtime.idleTimer.unref?.();
  }

  function runtimeFor(connectionId: string, uid: string): ConnectionRuntime {
    const id = key(connectionId, uid);
    const existing = runtimes.get(id);
    if (existing !== undefined) {
      if (existing.idleTimer !== undefined) clearTimeout(existing.idleTimer);
      existing.idleTimer = undefined;
      existing.lastUsedAt = Date.now();
      return existing;
    }

    if (runtimes.size >= maxRuntimes) {
      const candidates = [...runtimes.entries()]
        .filter((entry): entry is [string, ConnectionRuntime] => idle(entry[1]))
        .sort((left, right) => left[1].lastUsedAt - right[1].lastUsedAt);
      for (const [candidateId, candidate] of candidates) {
        evict(candidateId, candidate, "capacity");
        if (runtimes.size < maxRuntimes) break;
      }
      if (runtimes.size >= maxRuntimes) throw new ConnectionHealthError("unavailable");
    }

    const created: ConnectionRuntime = { attempts: new Set(), epoch: 0, lastUsedAt: Date.now() };
    runtimes.set(id, created);
    return created;
  }

  function liveActivity(runtime: ConnectionRuntime | undefined): "checking" | "refreshing" | undefined {
    if (runtime === undefined) return undefined;
    if (runtime.refresh !== undefined) return "refreshing";
    return runtime.attempts.size > 0 ? "checking" : undefined;
  }

  async function requiredConnection(connectionId: string, uid: string): Promise<HealthConnectionRecord> {
    const row = await deps.store.get(connectionId, uid);
    if (row === null) throw new ConnectionHealthError("not_found");
    return {
      ...nonSecretFacts(row),
      ...(row.legacyUnknownAuthWithoutConfig === true
        ? { legacyUnknownAuthWithoutConfig: true as const }
        : {}),
    };
  }

  async function currentProjection(connectionId: string, uid: string): Promise<HealthConnection> {
    const row = await requiredConnection(connectionId, uid);
    return projectConnectionHealth(row, liveActivity(runtimes.get(key(connectionId, uid))));
  }

  function cancelReconnect(session: HealthOperationSession): Promise<void> {
    const existing = reconnectCancellations.get(session);
    if (existing !== undefined) return existing;
    const promise = Promise.resolve().then(() => session.cancelReconnect?.()).then(() => {});
    reconnectCancellations.set(session, promise);
    return promise;
  }

  function closeSession(session: HealthOperationSession): Promise<void> {
    const existing = closing.get(session);
    if (existing !== undefined) return existing;
    const promise = (async () => {
      const results = await Promise.allSettled([
        cancelReconnect(session),
        Promise.resolve().then(() => session.close()),
      ]);
      if (results.some((result) => result.status === "rejected")) {
        throw new ConnectionHealthError("transport_close_failed");
      }
    })();
    closing.set(session, promise);
    return promise;
  }

  async function closeAttempt(attempt: HealthAttempt, propagate: boolean): Promise<void> {
    const results = await Promise.allSettled([...attempt.sessions].map(closeSession));
    attempt.sessions.clear();
    if (propagate && results.some((result) => result.status === "rejected")) {
      throw new ConnectionHealthError("transport_close_failed");
    }
  }

  function invalidateAttempts(runtime: ConnectionRuntime): void {
    runtime.epoch += 1;
    runtime.refresh = undefined;
    for (const attempt of runtime.attempts) {
      attempt.invalidated = true;
      attempt.controller.abort(DISCONNECT_REASON);
      // Stop timer-driven reconnect before the durable disconnect. The weak
      // cache makes this and the later owned close one cancellation per handle.
      for (const session of attempt.sessions) {
        void cancelReconnect(session).catch(() => {});
      }
    }
  }

  function locallyFenced(runtime: ConnectionRuntime, attempt: HealthAttempt): boolean {
    return attempt.invalidated || attempt.controller.signal.aborted || runtime.epoch !== attempt.epoch;
  }

  async function assertCurrent(
    runtime: ConnectionRuntime,
    attempt: HealthAttempt,
  ): Promise<HealthConnection> {
    if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");
    const current = await requiredConnection(attempt.connectionId, attempt.uid);
    if (current.configVersion !== attempt.expected.configVersion ||
        current.disconnectGeneration !== attempt.expected.disconnectGeneration) {
      throw new HealthFence(current.disconnectGeneration !== attempt.expected.disconnectGeneration
        ? "disconnected"
        : "connection_changed");
    }
    if (!current.enabled || current.authState === "revoked" || current.healthState === "revoked") {
      throw new HealthFence("disconnected");
    }
    if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");
    return current;
  }

  async function fenceTransition(
    runtime: ConnectionRuntime,
    attempt: HealthAttempt,
    from: ProviderHealthState,
    kind: "connection_changed" | "disconnected",
  ): Promise<HealthTransition> {
    if (kind === "disconnected" && runtime.disconnect !== undefined) {
      await runtime.disconnect.catch(() => {});
    }
    const current = await requiredConnection(attempt.connectionId, attempt.uid);
    const projected = projectConnectionHealth(current, liveActivity(runtime));
    const disconnected = projected.healthState === "revoked" ||
      current.disconnectGeneration !== attempt.expected.disconnectGeneration;
    return transition(
      projected,
      from,
      false,
      disconnected ? "disconnected" : "connection_changed",
    );
  }

  async function finalEvidence(
    runtime: ConnectionRuntime,
    attempt: HealthAttempt,
    from: ProviderHealthState,
    state: ConnectionHealthWriteState,
    reason?: HealthTransitionReason,
    code: HealthTransitionCode = "checked",
  ): Promise<HealthTransition> {
    if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");
    const checkedAt = now();
    const updated = await deps.store.writeHealth({
      connectionId: attempt.connectionId,
      userId: attempt.uid,
      expected: attempt.expected,
      state,
      checkedAt,
      ...(state === "healthy" ? { succeededAt: checkedAt } : {}),
    });
    if (updated === null) throw new HealthFence("connection_changed");
    if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");
    return transition(projectConnectionHealth(updated), from, true, code, reason);
  }

  async function sharedRefresh(
    runtime: ConnectionRuntime,
    attempt: HealthAttempt,
    session: HealthOperationSession,
  ): Promise<HealthRefreshOutcome> {
    const existing = runtime.refresh;
    if (existing !== undefined && existing.epoch === attempt.epoch) return existing.promise;
    if (session.refresh === undefined) return { status: "failed", reason: "unauthorized" };

    // This promise and every joiner see status only. The originating adapter
    // passes its token straight to writeToken; no token-bearing result is kept
    // in ConnectionRuntime or shared with another operation.
    let committed = false;
    const promise = (async (): Promise<HealthRefreshOutcome> => {
      const refreshing = await deps.store.writeHealth({
        connectionId: attempt.connectionId,
        userId: attempt.uid,
        expected: attempt.expected,
        state: "refreshing",
      });
      if (refreshing === null) throw new HealthFence("connection_changed");
      await assertCurrent(runtime, attempt);
      if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");

      const writeToken = async (token: unknown): Promise<boolean> => {
        if (committed) return true;
        if (locallyFenced(runtime, attempt)) return false;
        const stored = await deps.store.writeRefreshedToken({
          connectionId: attempt.connectionId,
          userId: attempt.uid,
          expected: attempt.expected,
          token,
          signal: attempt.controller.signal,
        });
        if (!stored) return false;
        if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");
        await assertCurrent(runtime, attempt);
        committed = true;
        return true;
      };

      let refreshed: HealthRefreshOutcome;
      try {
        refreshed = await session.refresh!({
          expected: attempt.expected,
          signal: attempt.controller.signal,
          writeToken,
        });
      } catch (error) {
        if (error instanceof HealthFence) throw error;
        if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");
        // Raw provider errors never escape through a transition or log.
        return { status: "failed", reason: "unavailable" };
      }
      if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");
      if (refreshed.status === "refreshed" && !committed) {
        return { status: "failed", reason: "unavailable" };
      }
      return refreshed;
    })();

    const registration = { epoch: attempt.epoch, promise };
    runtime.refresh = registration;
    try {
      return await promise;
    } finally {
      if (runtime.refresh === registration) runtime.refresh = undefined;
    }
  }

  async function executeSelectedOperation(
    runtime: ConnectionRuntime,
    attempt: HealthAttempt,
    session: HealthOperationSession,
    operation: ProviderOperation,
    from: ProviderHealthState,
  ): Promise<HealthTransition> {
    const execute = async (): Promise<HealthOperationOutcome> => {
      await assertCurrent(runtime, attempt);
      if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");
      try {
        const outcome = await session.execute({
          operation,
          expected: attempt.expected,
          signal: attempt.controller.signal,
        });
        if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");
        return outcome;
      } catch (error) {
        if (error instanceof HealthFence) throw error;
        if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");
        return { status: "failed", reason: "unavailable" };
      }
    };

    let outcome = await execute();
    if (outcome.status === "succeeded") return finalEvidence(runtime, attempt, from, "healthy");
    if (outcome.reason !== "unauthorized") {
      return finalEvidence(runtime, attempt, from, outcome.reason, outcome.reason);
    }

    const refreshed = await sharedRefresh(runtime, attempt, session);
    if (refreshed.status === "failed") {
      if (refreshed.reason === "invalid_grant") {
        return finalEvidence(runtime, attempt, from, "revoked", "invalid_grant");
      }
      if (refreshed.reason === "unauthorized") {
        return finalEvidence(runtime, attempt, from, "needs_auth", "unauthorized");
      }
      return finalEvidence(runtime, attempt, from, "unavailable", "unavailable");
    }

    // Token refresh is never success evidence. This selected typed read must
    // succeed after the fenced token write before healthy can be persisted.
    outcome = await execute();
    if (outcome.status === "succeeded") return finalEvidence(runtime, attempt, from, "healthy");
    return finalEvidence(runtime, attempt, from,
      outcome.reason === "unauthorized" ? "needs_auth" : outcome.reason,
      outcome.reason,
    );
  }

  async function checkConnectionHealth(
    connectionId: string,
    uid: string,
    operationId: string,
  ): Promise<HealthTransition> {
    // Missing/wrong-owner IDs are rejected before allocating any runtime entry.
    const initial = await requiredConnection(connectionId, uid);
    const runtime = runtimeFor(connectionId, uid);
    if (runtime.disconnect !== undefined) {
      await runtime.disconnect.catch(() => {});
      const current = await currentProjection(connectionId, uid);
      scheduleIdle(key(connectionId, uid), runtime);
      return transition(current, current.healthState, false,
        current.healthState === "revoked" ? "disconnected" : "connection_changed");
    }

    const projected = projectConnectionHealth(initial, liveActivity(runtime));
    const from = projected.healthState;
    if (!initial.enabled || TERMINAL_HEALTH.has(from)) {
      scheduleIdle(key(connectionId, uid), runtime);
      return transition(projected, from, false, "unchanged");
    }

    const attempt: HealthAttempt = {
      connectionId,
      uid,
      expected: expectedOf(initial),
      controller: new AbortController(),
      sessions: new Set(),
      epoch: runtime.epoch,
      invalidated: false,
    };
    runtime.attempts.add(attempt);

    try {
      // Recheck a disconnect that began between the initial read and attempt
      // registration before any health/provider side effect.
      if (runtime.disconnect !== undefined || locallyFenced(runtime, attempt)) {
        throw new HealthFence("disconnected");
      }
      const checking = await deps.store.writeHealth({
        connectionId,
        userId: uid,
        expected: attempt.expected,
        state: "checking",
      });
      if (checking === null) throw new HealthFence("connection_changed");
      if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");

      const provider = providers.get(initial.providerId);
      if ((initial.authState === "missing" || initial.authState === "needs_auth") &&
          !legacyCredentialFreeConfigCheck(initial, provider)) {
        return await finalEvidence(runtime, attempt, from, "needs_auth", "missing_auth");
      }

      const selected = provider?.operations.find((candidate) => candidate.name === operationId);
      if (provider === undefined || selected === undefined) {
        return await finalEvidence(
          runtime,
          attempt,
          from,
          "unavailable",
          "unsupported_operation",
          "invalid_operation",
        );
      }
      if (!supportsHealthOperation(selected)) {
        return await finalEvidence(
          runtime,
          attempt,
          from,
          "unavailable",
          "invalid_operation",
          "invalid_operation",
        );
      }

      await assertCurrent(runtime, attempt);
      let session: HealthOperationSession;
      try {
        session = await deps.open({
          connection: initial,
          operation: selected,
          expected: attempt.expected,
          signal: attempt.controller.signal,
        });
      } catch (error) {
        if (locallyFenced(runtime, attempt)) throw new HealthFence("disconnected");
        return await finalEvidence(runtime, attempt, from, "unavailable", "unavailable");
      }
      attempt.sessions.add(session);
      if (locallyFenced(runtime, attempt)) {
        await closeAttempt(attempt, false);
        throw new HealthFence("disconnected");
      }
      return await executeSelectedOperation(runtime, attempt, session, selected, from);
    } catch (error) {
      if (error instanceof HealthFence || locallyFenced(runtime, attempt)) {
        const kind = error instanceof HealthFence ? error.kind : "disconnected";
        return await fenceTransition(runtime, attempt, from, kind);
      }
      // Only an expected conditional-write/provider failure reaches here. Do
      // not leak an arbitrary error message, stack, token, or upstream payload.
      return await finalEvidence(runtime, attempt, from, "unavailable", "unavailable");
    } finally {
      runtime.attempts.delete(attempt);
      await closeAttempt(attempt, false).catch(() => {});
      scheduleIdle(key(connectionId, uid), runtime);
    }
  }

  async function disconnectConnection(connectionId: string, uid: string): Promise<HealthConnection> {
    // As with checks, unknown/foreign IDs never allocate retained runtime state.
    const current = await requiredConnection(connectionId, uid);
    const runtime = runtimes.get(key(connectionId, uid));
    if (runtime === undefined) {
      // No local attempts exist, so a full map is irrelevant. Persist the real
      // atomic disconnect before considering any optional runtime allocation.
      const disconnected = await deps.store.disconnect(connectionId, uid, current.configVersion);
      if (disconnected === null) throw new ConnectionHealthError("connection_changed");
      await deps.closeOwnedTransports?.(connectionId, uid);
      return projectConnectionHealth(disconnected);
    }
    if (runtime.disconnect !== undefined) return runtime.disconnect;

    const pending = (async (): Promise<HealthConnection> => {
      // Repeated/external disconnects still cancel this process's old attempts.
      invalidateAttempts(runtime);
      // This store port is the atomic generation bump + OAuth deletion point.
      // No refresh/token write can pass its expected generation afterwards.
      const disconnected = await deps.store.disconnect(connectionId, uid, current.configVersion);
      if (disconnected === null) throw new ConnectionHealthError("connection_changed");

      const attempts = [...runtime.attempts];
      const results: PromiseSettledResult<void>[] = await Promise.allSettled(
        attempts.map((attempt) => closeAttempt(attempt, true)),
      );
      try {
        await deps.closeOwnedTransports?.(connectionId, uid);
      } catch {
        results.push({ status: "rejected", reason: "transport_close_failed" });
      }
      if (results.some((result) => result.status === "rejected")) {
        // State is still durably revoked; report cleanup failure without any
        // provider error text and let the caller re-read that persisted fact.
        throw new ConnectionHealthError("transport_close_failed");
      }
      return projectConnectionHealth(disconnected);
    })();

    runtime.disconnect = pending;
    try {
      return await pending;
    } finally {
      if (runtime.disconnect === pending) runtime.disconnect = undefined;
      scheduleIdle(key(connectionId, uid), runtime);
    }
  }

  function boundedError(error: unknown): ConnectionHealthError {
    return error instanceof ConnectionHealthError
      ? error
      : new ConnectionHealthError("unavailable");
  }

  return {
    async checkConnectionHealth(connectionId, uid, operationId) {
      try {
        return await checkConnectionHealth(connectionId, uid, operationId);
      } catch (error) {
        throw boundedError(error);
      }
    },
    async getConnectionHealth(connectionId, uid) {
      try {
        // Reads never allocate runtime entries, including for foreign IDs.
        return await currentProjection(connectionId, uid);
      } catch (error) {
        throw boundedError(error);
      }
    },
    async disconnectConnection(connectionId, uid) {
      try {
        return await disconnectConnection(connectionId, uid);
      } catch (error) {
        throw boundedError(error);
      }
    },
  };
}
