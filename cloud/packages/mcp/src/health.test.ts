// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
// Do not treat this authored RED/GREEN suite as executed verification.
import { describe, expect, it, vi } from "vitest";

import {
  ConnectionHealthError,
  createConnectionHealthLifecycle,
  projectConnectionHealth,
  type ConnectionHealthStore,
  type HealthConnection,
  type HealthOperationOutcome,
  type HealthOperationSession,
  type HealthRefreshInput,
  type HealthRefreshOutcome,
  type HealthWrite,
} from "./health.js";
import type { ProviderOperation } from "./providers/types.js";

const CONNECTION_ID = "11111111-1111-4111-8111-111111111111";
const UID = "health-user";
const OPERATION_ID = "list_repositories";
const T0 = "2026-10-24T12:00:00.000Z";
const T1 = "2026-10-24T12:01:00.000Z";
const T2 = "2026-10-24T12:02:00.000Z";
const T3 = "2026-10-24T12:03:00.000Z";

function deferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (reason: unknown) => void;
} {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function connection(overrides: Partial<HealthConnection> = {}): HealthConnection {
  return {
    connectionId: CONNECTION_ID,
    userId: UID,
    providerId: "github",
    enabled: true,
    agentEnabled: true,
    authState: "authorized",
    healthState: "never_checked",
    lastCheckedAt: null,
    lastSuccessAt: null,
    configVersion: 7,
    disconnectGeneration: 3,
    hasSecrets: true,
    ...overrides,
  };
}

function operation(overrides: Partial<ProviderOperation> = {}): ProviderOperation {
  return {
    name: OPERATION_ID,
    description: "List the authenticated user's repositories",
    effect: "read",
    approval: "mode",
    requiredScopes: ["repo:read"],
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
      additionalProperties: false,
      maxProperties: 0,
    },
    outputPolicy: { kind: "redacted_json", maxBytes: 4096 },
    request: { originKey: "github", method: "GET", pathTemplate: "/user/repos" },
    limits: { timeoutMs: 1000, responseBytes: 4096, frameBytes: 4096, pageBytes: 4096 },
    ...overrides,
  };
}

function success(): HealthOperationOutcome {
  return { status: "succeeded" };
}

function failure(reason: "unauthorized" | "degraded" | "unavailable"): HealthOperationOutcome {
  return { status: "failed", reason };
}

async function refreshed(input: HealthRefreshInput, token: unknown): Promise<HealthRefreshOutcome> {
  return await input.writeToken(token)
    ? { status: "refreshed" }
    : { status: "failed", reason: "unavailable" };
}

class FakeHealthStore implements ConnectionHealthStore {
  row: HealthConnection | null;
  readonly writes: HealthWrite[] = [];
  token: unknown = null;
  tokenWriteAttempts = 0;
  disconnectAttempts = 0;
  beforeTokenWrite: (() => Promise<void>) | undefined;

  constructor(row: HealthConnection | null) {
    this.row = row === null ? null : structuredClone(row);
  }

  async get(connectionId: string, uid: string): Promise<HealthConnection | null> {
    if (this.row === null || this.row.connectionId !== connectionId || this.row.userId !== uid) return null;
    return structuredClone(this.row);
  }

  private current(write: { expected: HealthConnectionExpected }): boolean {
    return this.row !== null && this.row.enabled &&
      this.row.configVersion === write.expected.configVersion &&
      this.row.disconnectGeneration === write.expected.disconnectGeneration;
  }

  async writeHealth(write: HealthWrite): Promise<HealthConnection | null> {
    this.writes.push(structuredClone(write));
    if (this.row === null || this.row.connectionId !== write.connectionId ||
        this.row.userId !== write.userId || !this.current(write)) return null;
    if (write.state !== "revoked" &&
        (this.row.authState === "revoked" || this.row.healthState === "revoked")) return null;
    if (write.state === "healthy" && !["configured", "authorized"].includes(this.row.authState)) return null;
    this.row.healthState = write.state;
    if (write.state === "needs_auth" || write.state === "revoked") this.row.authState = write.state;
    if (write.checkedAt !== undefined) this.row.lastCheckedAt = write.checkedAt.toISOString();
    if (write.succeededAt !== undefined) this.row.lastSuccessAt = write.succeededAt.toISOString();
    return structuredClone(this.row);
  }

  async writeRefreshedToken(input: {
    connectionId: string;
    userId: string;
    expected: HealthConnectionExpected;
    token: unknown;
    signal: AbortSignal;
  }): Promise<boolean> {
    this.tokenWriteAttempts += 1;
    await this.beforeTokenWrite?.();
    if (this.row === null || this.row.connectionId !== input.connectionId ||
        this.row.userId !== input.userId || input.signal.aborted || !this.current(input) ||
        this.row.authState === "revoked" || this.row.healthState === "revoked") return false;
    this.token = input.token;
    return true;
  }

  async disconnect(connectionId: string, uid: string, expectedConfigVersion: number): Promise<HealthConnection | null> {
    this.disconnectAttempts += 1;
    if (this.row === null || this.row.connectionId !== connectionId || this.row.userId !== uid ||
        this.row.configVersion !== expectedConfigVersion) return null;
    this.row = {
      ...this.row,
      enabled: false,
      agentEnabled: false,
      authState: "revoked",
      healthState: "revoked",
      disconnectGeneration: this.row.disconnectGeneration + 1,
    };
    this.token = null;
    return structuredClone(this.row);
  }
}

// Structural mirror of the store port's version fence; kept separate from the
// fake's input types so accidental config/version widening fails typecheck.
interface HealthConnectionExpected {
  configVersion: number;
  disconnectGeneration: number;
}

interface SessionDouble {
  session: HealthOperationSession;
  executeCalls: () => number;
  refreshCalls: () => number;
  closeCalls: () => number;
  reconnectCancels: () => number;
  signals: AbortSignal[];
}

function sessionDouble(handlers: {
  execute: (input: { signal: AbortSignal }) => Promise<HealthOperationOutcome>;
  refresh?: (input: { signal: AbortSignal }) => Promise<HealthRefreshOutcome>;
}): SessionDouble {
  let executeCalls = 0;
  let refreshCalls = 0;
  let closeCalls = 0;
  let reconnectCancels = 0;
  const signals: AbortSignal[] = [];
  const session: HealthOperationSession = {
    async execute(input) {
      executeCalls += 1;
      signals.push(input.signal);
      return handlers.execute(input);
    },
    ...(handlers.refresh === undefined ? {} : {
      async refresh(input: { signal: AbortSignal }) {
        refreshCalls += 1;
        signals.push(input.signal);
        return handlers.refresh!(input);
      },
    }),
    async cancelReconnect() {
      reconnectCancels += 1;
    },
    async close() {
      closeCalls += 1;
    },
  };
  return {
    session,
    executeCalls: () => executeCalls,
    refreshCalls: () => refreshCalls,
    closeCalls: () => closeCalls,
    reconnectCancels: () => reconnectCancels,
    signals,
  };
}

function harness(
  store: FakeHealthStore,
  sessions: SessionDouble[],
  options: {
    operations?: ProviderOperation[];
    times?: string[];
    runtimeTtlMs?: number;
    maxRuntimes?: number;
    onRuntimeEvicted?: (event: { connectionId: string; userId: string; reason: "ttl" | "capacity" }) => void;
  } = {},
) {
  const times = [...(options.times ?? [T1, T2, T3])];
  let openCalls = 0;
  const lifecycle = createConnectionHealthLifecycle({
    store,
    providers: [{
      providerId: "github",
      readiness: "supported",
      operations: options.operations ?? [operation()],
    }],
    async open(input) {
      const selected = sessions[Math.min(openCalls, sessions.length - 1)];
      if (selected === undefined) throw new Error("unexpected open");
      openCalls += 1;
      return selected.session;
    },
    now() {
      return new Date(times.shift() ?? T3);
    },
    ...(options.runtimeTtlMs === undefined ? {} : { runtimeTtlMs: options.runtimeTtlMs }),
    ...(options.maxRuntimes === undefined ? {} : { maxRuntimes: options.maxRuntimes }),
    ...(options.onRuntimeEvicted === undefined ? {} : { onRuntimeEvicted: options.onRuntimeEvicted }),
  });
  return { lifecycle, openCalls: () => openCalls };
}

async function check(lifecycle: ReturnType<typeof createConnectionHealthLifecycle>) {
  return lifecycle.checkConnectionHealth(CONNECTION_ID, UID, OPERATION_ID);
}

describe("connection health lifecycle", () => {
  it("does not equate stored secrets with health before a real typed operation succeeds", async () => {
    const store = new FakeHealthStore(connection());
    const selected = sessionDouble({ execute: async () => success() });
    const { lifecycle, openCalls } = harness(store, [selected], { times: [T1] });

    const transition = await check(lifecycle);

    expect(transition).toMatchObject({
      from: "never_checked",
      to: "healthy",
      persisted: true,
      code: "checked",
      lastCheckedAt: T1,
      lastSuccessAt: T1,
    });
    expect(openCalls()).toBe(1);
    expect(selected.executeCalls()).toBe(1);
    expect(store.writes.map((write) => write.state)).toEqual(["checking", "healthy"]);
  });

  it("derives every lifecycle state from facts and rejects stale or contradictory evidence", () => {
    const checked = connection({ lastCheckedAt: T1 });
    const cases: Array<[HealthConnection, "checking" | "refreshing" | undefined, HealthConnection["healthState"]]> = [
      [connection(), undefined, "never_checked"],
      [connection({ lastSuccessAt: T0 }), undefined, "unavailable"],
      [connection({ lastSuccessAt: T0 }), "checking", "unavailable"],
      [connection({ healthState: "checking" }), "checking", "checking"],
      [connection({ healthState: "healthy", lastCheckedAt: T1, lastSuccessAt: T1 }), undefined, "healthy"],
      [connection({ healthState: "degraded", lastCheckedAt: T1, lastSuccessAt: T0 }), undefined, "degraded"],
      [connection({ healthState: "needs_auth", authState: "needs_auth" }), undefined, "needs_auth"],
      [connection({ healthState: "refreshing", lastCheckedAt: T0, lastSuccessAt: T0 }), "refreshing", "refreshing"],
      [connection({ enabled: false, agentEnabled: false, authState: "revoked", healthState: "revoked" }), undefined, "revoked"],
      [connection({ healthState: "unavailable", lastCheckedAt: T1 }), undefined, "unavailable"],
      [connection({ enabled: false, healthState: "disabled" }), undefined, "disabled"],
      [connection({ healthState: "checking" }), undefined, "never_checked"],
      [connection({ healthState: "checking", lastSuccessAt: T0 }), undefined, "unavailable"],
      [{ ...checked, healthState: "refreshing" }, undefined, "unavailable"],
      [{ ...checked, healthState: "healthy" }, undefined, "unavailable"],
    ];

    for (const [facts, activity, expected] of cases) {
      expect(projectConnectionHealth(facts, activity).healthState).toBe(expected);
    }
  });

  it("advances lastSuccessAt only for typed success and preserves it across a later degraded check", async () => {
    const store = new FakeHealthStore(connection());
    const first = sessionDouble({ execute: async () => success() });
    const second = sessionDouble({ execute: async () => failure("degraded") });
    const { lifecycle } = harness(store, [first, second], { times: [T1, T2] });

    const healthy = await check(lifecycle);
    const degraded = await check(lifecycle);

    expect(healthy.connection).toMatchObject({ lastCheckedAt: T1, lastSuccessAt: T1 });
    expect(degraded).toMatchObject({
      from: "healthy",
      to: "degraded",
      lastCheckedAt: T2,
      lastSuccessAt: T1,
    });
    expect(store.writes[0]).not.toHaveProperty("checkedAt");
    expect(store.writes[0]).not.toHaveProperty("succeededAt");
  });

  it("single-flights refresh and retries each real typed operation before reporting healthy", async () => {
    const store = new FakeHealthStore(connection());
    const refresh = deferred<HealthRefreshOutcome>();
    let refreshStarted!: () => void;
    const started = new Promise<void>((resolve) => { refreshStarted = resolve; });
    // Each executor has its own result sequence; after the shared refresh both
    // selected reads must really succeed. Refresh success alone is insufficient.
    let firstCalls = 0;
    const firstSequenced = sessionDouble({
      execute: async () => ++firstCalls === 1 ? failure("unauthorized") : success(),
      refresh: async (input) => {
        refreshStarted();
        await refresh.promise;
        return refreshed(input, { sealed: "rotated-token" });
      },
    });
    let secondCalls = 0;
    const secondSequenced = sessionDouble({
      execute: async () => ++secondCalls === 1 ? failure("unauthorized") : success(),
    });
    const { lifecycle } = harness(store, [firstSequenced, secondSequenced], { times: [T1, T2] });

    const left = check(lifecycle);
    const right = check(lifecycle);
    await started;
    expect(firstSequenced.refreshCalls()).toBe(1);
    expect(secondSequenced.refreshCalls()).toBe(0);
    expect(store.writes.map((write) => write.state)).toContain("refreshing");
    refresh.resolve({ status: "refreshed" });
    const transitions = await Promise.all([left, right]);

    expect(firstSequenced.refreshCalls() + secondSequenced.refreshCalls()).toBe(1);
    expect(store.tokenWriteAttempts).toBe(1);
    expect(store.token).toEqual({ sealed: "rotated-token" });
    expect(firstSequenced.executeCalls()).toBe(2);
    expect(secondSequenced.executeCalls()).toBe(2);
    expect(transitions.map((transition) => transition.to)).toEqual(["healthy", "healthy"]);
    expect(store.writes.filter((write) => write.state === "refreshing")).toHaveLength(1);
  });

  it("does not report healthy after refresh unless the subsequent typed operation succeeds", async () => {
    const store = new FakeHealthStore(connection());
    let calls = 0;
    const selected = sessionDouble({
      execute: async () => ++calls === 1 ? failure("unauthorized") : failure("degraded"),
      refresh: async (input) => refreshed(input, "opaque"),
    });
    const { lifecycle } = harness(store, [selected], { times: [T1] });

    const transition = await check(lifecycle);

    expect(transition.to).toBe("degraded");
    expect(transition.lastSuccessAt).toBeNull();
    expect(store.tokenWriteAttempts).toBe(1);
    expect(selected.executeCalls()).toBe(2);
  });

  it("does not trust a token-free refreshed status unless the originating path committed through the fence", async () => {
    const store = new FakeHealthStore(connection());
    const selected = sessionDouble({
      execute: async () => failure("unauthorized"),
      refresh: async () => ({ status: "refreshed" }),
    });
    const { lifecycle } = harness(store, [selected]);

    const transition = await check(lifecycle);

    expect(transition).toMatchObject({ to: "unavailable", reason: "unavailable" });
    expect(store.tokenWriteAttempts).toBe(0);
    expect(selected.executeCalls()).toBe(1);
    expect(JSON.stringify(transition)).not.toContain("token");
  });

  it("maps an invalid refresh grant to revoked without issuing a typed retry", async () => {
    const store = new FakeHealthStore(connection({ lastSuccessAt: T0 }));
    const selected = sessionDouble({
      execute: async () => failure("unauthorized"),
      refresh: async () => ({ status: "failed", reason: "invalid_grant" }),
    });
    const { lifecycle } = harness(store, [selected], { times: [T1] });

    const transition = await check(lifecycle);

    expect(transition).toMatchObject({ to: "revoked", reason: "invalid_grant", lastCheckedAt: T1, lastSuccessAt: T0 });
    expect(selected.executeCalls()).toBe(1);
    expect(store.tokenWriteAttempts).toBe(0);
  });

  it("maps repeated 401 to needs_auth after one refresh rather than looping or claiming health", async () => {
    const store = new FakeHealthStore(connection());
    const selected = sessionDouble({
      execute: async () => failure("unauthorized"),
      refresh: async (input) => refreshed(input, "opaque"),
    });
    const { lifecycle } = harness(store, [selected], { times: [T1] });

    const transition = await check(lifecycle);

    expect(transition).toMatchObject({ to: "needs_auth", reason: "unauthorized", lastCheckedAt: T1 });
    expect(selected.executeCalls()).toBe(2);
    expect(selected.refreshCalls()).toBe(1);
    expect(store.tokenWriteAttempts).toBe(1);
  });

  it("maps missing authentication and first 401 without a refresh capability to needs_auth", async () => {
    const missingStore = new FakeHealthStore(connection({ authState: "missing", hasSecrets: false }));
    const missing = harness(missingStore, [], { times: [T1] });
    const missingTransition = await check(missing.lifecycle);
    expect(missingTransition).toMatchObject({ to: "needs_auth", reason: "missing_auth", lastCheckedAt: T1 });
    expect(missing.openCalls()).toBe(0);

    const unauthorizedStore = new FakeHealthStore(connection());
    const selected = sessionDouble({ execute: async () => failure("unauthorized") });
    const unauthorized = harness(unauthorizedStore, [selected], { times: [T2] });
    const transition = await check(unauthorized.lifecycle);
    expect(transition).toMatchObject({ to: "needs_auth", reason: "unauthorized", lastCheckedAt: T2 });
    expect(selected.executeCalls()).toBe(1);
  });

  it("never executes a mutation as a health probe and preserves previous success evidence", async () => {
    const store = new FakeHealthStore(connection({ healthState: "healthy", lastCheckedAt: T0, lastSuccessAt: T0 }));
    const mutation = operation({
      name: "delete_repository",
      effect: "destructive",
      approval: "per_action",
      request: { originKey: "github", method: "DELETE", pathTemplate: "/repos/owned" },
    });
    const { lifecycle, openCalls } = harness(store, [], { operations: [mutation], times: [T1] });

    const transition = await lifecycle.checkConnectionHealth(CONNECTION_ID, UID, "delete_repository");

    expect(transition).toMatchObject({
      to: "unavailable",
      code: "invalid_operation",
      reason: "invalid_operation",
      lastCheckedAt: T1,
      lastSuccessAt: T0,
    });
    expect(openCalls()).toBe(0);
  });

  it("projects only declared non-secret fields even when a store row carries sealed columns", () => {
    const projected = projectConnectionHealth({
      ...connection(),
      config: { url: "https://secret-bearing.invalid" },
      secretsSealed: { ciphertext: "sealed-secret-canary" },
    } as HealthConnection);

    expect(Object.keys(projected).sort()).toEqual([
      "agentEnabled",
      "authState",
      "configVersion",
      "connectionId",
      "disconnectGeneration",
      "enabled",
      "hasSecrets",
      "healthState",
      "lastCheckedAt",
      "lastSuccessAt",
      "providerId",
      "userId",
    ]);
    expect(JSON.stringify(projected)).not.toContain("sealed-secret-canary");
    expect(JSON.stringify(projected)).not.toContain("secret-bearing.invalid");
  });

  it("bounds and redacts provider failures instead of returning upstream secrets or payloads", async () => {
    const canary = "refresh_token=never-project-this-secret";
    const store = new FakeHealthStore(connection());
    const selected = sessionDouble({
      execute: async () => {
        throw new Error(`${canary} ${"x".repeat(20_000)}`);
      },
    });
    const { lifecycle } = harness(store, [selected], { times: [T1] });

    const transition = await check(lifecycle);
    const serialized = JSON.stringify(transition);

    expect(transition).toMatchObject({ to: "unavailable", reason: "unavailable" });
    expect(serialized).not.toContain(canary);
    expect(serialized).not.toContain("x".repeat(100));
    expect(serialized.length).toBeLessThan(2_000);
  });

  it("bounds unexpected store failures with the same no-payload error boundary", async () => {
    const canary = "access_token=store-error-must-not-escape";
    const store = new FakeHealthStore(connection());
    store.get = async () => {
      throw new Error(`${canary} ${"stack/payload".repeat(1_000)}`);
    };
    const { lifecycle } = harness(store, []);

    const failure = await check(lifecycle).catch((error: unknown) => error);

    expect(failure).toMatchObject({ code: "unavailable", message: "unavailable" });
    expect(JSON.stringify(failure)).not.toContain(canary);
    expect(JSON.stringify(failure).length).toBeLessThan(1_000);
  });

  it("does not probe disabled, revoked, unknown, or wrong-owner connections", async () => {
    for (const facts of [
      connection({ enabled: false, healthState: "disabled" }),
      connection({ enabled: false, agentEnabled: false, authState: "revoked", healthState: "revoked" }),
    ]) {
      const store = new FakeHealthStore(facts);
      const { lifecycle, openCalls } = harness(store, []);
      const transition = await check(lifecycle);
      expect(transition.persisted).toBe(false);
      expect(transition.to).toBe(facts.healthState);
      expect(openCalls()).toBe(0);
      expect(store.writes).toHaveLength(0);
    }

    for (const store of [new FakeHealthStore(null), new FakeHealthStore(connection())]) {
      const { lifecycle, openCalls } = harness(store, []);
      const uid = store.row === null ? UID : "someone-else";
      await expect(lifecycle.checkConnectionHealth(CONNECTION_ID, uid, OPERATION_ID))
        .rejects.toMatchObject({ code: "not_found" } satisfies Partial<ConnectionHealthError>);
      expect(openCalls()).toBe(0);
    }
  });

  it("scopes disconnect to the owner and conditionally bumps every accepted generation", async () => {
    const store = new FakeHealthStore(connection());
    const { lifecycle } = harness(store, []);

    await expect(lifecycle.disconnectConnection(CONNECTION_ID, "someone-else"))
      .rejects.toMatchObject({ code: "not_found" });
    expect(store.disconnectAttempts).toBe(0);
    expect(store.row?.disconnectGeneration).toBe(3);

    await expect(lifecycle.disconnectConnection(CONNECTION_ID, UID))
      .resolves.toMatchObject({ healthState: "revoked", disconnectGeneration: 4 });
    await expect(lifecycle.disconnectConnection(CONNECTION_ID, UID))
      .resolves.toMatchObject({ healthState: "revoked", disconnectGeneration: 5 });
    expect(store.disconnectAttempts).toBe(2);
  });

  it("fences a config change during refresh and cannot retry or persist the old token", async () => {
    const store = new FakeHealthStore(connection());
    const refresh = deferred<HealthRefreshOutcome>();
    let refreshStarted!: () => void;
    const started = new Promise<void>((resolve) => { refreshStarted = resolve; });
    const selected = sessionDouble({
      execute: async () => failure("unauthorized"),
      refresh: async (input) => {
        refreshStarted();
        await refresh.promise;
        return refreshed(input, "stale-token");
      },
    });
    const { lifecycle } = harness(store, [selected]);

    const pending = check(lifecycle);
    await started;
    store.row = { ...store.row!, configVersion: store.row!.configVersion + 1, healthState: "never_checked" };
    refresh.resolve({ status: "refreshed" });
    const transition = await pending;

    expect(transition.code).toBe("connection_changed");
    expect(transition.persisted).toBe(false);
    expect(transition.connection.configVersion).toBe(8);
    expect(selected.executeCalls()).toBe(1);
    expect(store.token).toBeNull();
  });

  it("disconnect during refresh aborts work, closes owned transports, and prevents token writes or resurrection", async () => {
    const store = new FakeHealthStore(connection());
    const refresh = deferred<HealthRefreshOutcome>();
    let refreshStarted!: () => void;
    const started = new Promise<void>((resolve) => { refreshStarted = resolve; });
    const selected = sessionDouble({
      execute: async () => failure("unauthorized"),
      refresh: async (input) => {
        refreshStarted();
        await refresh.promise;
        return refreshed(input, "must-not-survive");
      },
    });
    const { lifecycle, openCalls } = harness(store, [selected]);

    const pending = check(lifecycle);
    await started;
    const disconnected = await lifecycle.disconnectConnection(CONNECTION_ID, UID);
    expect(disconnected).toMatchObject({ healthState: "revoked", disconnectGeneration: 4, enabled: false });
    const writesAtDisconnect = store.tokenWriteAttempts;
    refresh.resolve({ status: "refreshed" });
    const transition = await pending;

    expect(transition).toMatchObject({ code: "disconnected", to: "revoked", persisted: false });
    expect(store.tokenWriteAttempts).toBe(writesAtDisconnect);
    expect(store.token).toBeNull();
    expect(selected.executeCalls()).toBe(1);
    expect(selected.signals.some((signal) => signal.aborted)).toBe(true);
    expect(selected.reconnectCancels()).toBe(1);
    expect(selected.closeCalls()).toBe(1);
    expect(store.row).toMatchObject({ healthState: "revoked", authState: "revoked", disconnectGeneration: 4 });

    const after = await check(lifecycle);
    expect(after.to).toBe("revoked");
    expect(openCalls()).toBe(1);
    expect(selected.executeCalls()).toBe(1);
  });

  it("disconnect during a typed call fences its late success and prevents a later call", async () => {
    const store = new FakeHealthStore(connection({ lastSuccessAt: T0 }));
    const executing = deferred<HealthOperationOutcome>();
    let executeStarted!: () => void;
    const started = new Promise<void>((resolve) => { executeStarted = resolve; });
    const selected = sessionDouble({
      execute: async () => {
        executeStarted();
        return executing.promise;
      },
    });
    const { lifecycle } = harness(store, [selected]);

    const pending = check(lifecycle);
    await started;
    await lifecycle.disconnectConnection(CONNECTION_ID, UID);
    executing.resolve(success());
    const transition = await pending;

    expect(transition).toMatchObject({ code: "disconnected", to: "revoked", persisted: false, lastSuccessAt: T0 });
    expect(selected.executeCalls()).toBe(1);
    expect(selected.reconnectCancels()).toBe(1);
    expect(selected.closeCalls()).toBe(1);
    expect(store.row).toMatchObject({ healthState: "revoked", lastSuccessAt: T0, disconnectGeneration: 4 });
    expect(store.writes.some((write) => write.state === "healthy")).toBe(false);
  });

  it("closes a transport that finishes opening after disconnect without executing it", async () => {
    const store = new FakeHealthStore(connection());
    const opening = deferred<HealthOperationSession>();
    const selected = sessionDouble({ execute: async () => success() });
    const lifecycle = createConnectionHealthLifecycle({
      store,
      providers: [{ providerId: "github", readiness: "supported", operations: [operation()] }],
      open: () => opening.promise,
    });

    const pending = check(lifecycle);
    // Let the initial conditional checking write and lazy open start.
    await new Promise<void>((resolve) => setImmediate(resolve));
    await lifecycle.disconnectConnection(CONNECTION_ID, UID);
    opening.resolve(selected.session);
    const transition = await pending;

    expect(transition.code).toBe("disconnected");
    expect(selected.executeCalls()).toBe(0);
    expect(selected.closeCalls()).toBe(1);
    expect(store.row?.healthState).toBe("revoked");
  });

  it("uses the generation fence for a token write racing disconnect and never resurrects health", async () => {
    const store = new FakeHealthStore(connection());
    const tokenWrite = deferred<void>();
    let tokenStarted!: () => void;
    const started = new Promise<void>((resolve) => { tokenStarted = resolve; });
    store.beforeTokenWrite = async () => {
      tokenStarted();
      await tokenWrite.promise;
    };
    let calls = 0;
    const selected = sessionDouble({
      execute: async () => ++calls === 1 ? failure("unauthorized") : success(),
      refresh: async (input) => refreshed(input, "racing-token"),
    });
    const { lifecycle } = harness(store, [selected]);

    const pending = check(lifecycle);
    await started;
    await lifecycle.disconnectConnection(CONNECTION_ID, UID);
    tokenWrite.resolve();
    const transition = await pending;

    expect(transition.code).toBe("disconnected");
    expect(store.token).toBeNull();
    expect(selected.executeCalls()).toBe(1);
    expect(store.row).toMatchObject({ healthState: "revoked", disconnectGeneration: 4 });
  });

  it("persists disconnect before runtime allocation even when every runtime slot is active", async () => {
    const otherId = "22222222-2222-4222-8222-222222222222";
    const activeStore = new FakeHealthStore(connection());
    const disconnectStore = new FakeHealthStore(connection({ connectionId: otherId }));
    const store: ConnectionHealthStore = {
      get: (id, uid) => id === CONNECTION_ID ? activeStore.get(id, uid) : disconnectStore.get(id, uid),
      writeHealth: (write) => write.connectionId === CONNECTION_ID
        ? activeStore.writeHealth(write)
        : disconnectStore.writeHealth(write),
      writeRefreshedToken: (write) => write.connectionId === CONNECTION_ID
        ? activeStore.writeRefreshedToken(write)
        : disconnectStore.writeRefreshedToken(write),
      disconnect: (id, uid, version) => id === CONNECTION_ID
        ? activeStore.disconnect(id, uid, version)
        : disconnectStore.disconnect(id, uid, version),
    };
    const executing = deferred<HealthOperationOutcome>();
    let started!: () => void;
    const startedPromise = new Promise<void>((resolve) => { started = resolve; });
    const selected = sessionDouble({
      execute: async () => {
        started();
        return executing.promise;
      },
    });
    const { lifecycle } = harness(store, [selected], { maxRuntimes: 1 });
    const active = check(lifecycle);
    await startedPromise;

    // The map has one active entry and no idle slot to evict. A different
    // connection has no local attempts to cancel and must not need allocation.
    await expect(lifecycle.disconnectConnection(otherId, UID)).resolves.toMatchObject({
      connectionId: otherId,
      healthState: "revoked",
      disconnectGeneration: 4,
    });
    expect(disconnectStore.disconnectAttempts).toBe(1);
    executing.resolve(success());
    await active;
  });

  it("closes non-health transports after durable disconnect even without a health runtime", async () => {
    const store = new FakeHealthStore(connection());
    const closeOwnedTransports = vi.fn(async () => {});
    const lifecycle = createConnectionHealthLifecycle({
      store,
      providers: [],
      open: async () => { throw new Error("must not open"); },
      closeOwnedTransports,
    });

    await expect(lifecycle.disconnectConnection(CONNECTION_ID, UID)).resolves.toMatchObject({
      healthState: "revoked",
      disconnectGeneration: 4,
    });
    expect(store.disconnectAttempts).toBe(1);
    expect(closeOwnedTransports).toHaveBeenCalledWith(CONNECTION_ID, UID);
  });

  it("projects live checking and refreshing through the production read surface", async () => {
    const store = new FakeHealthStore(connection());
    const executing = deferred<HealthOperationOutcome>();
    const refresh = deferred<void>();
    let executeStarted!: () => void;
    let refreshStarted!: () => void;
    const executeStartedPromise = new Promise<void>((resolve) => { executeStarted = resolve; });
    const refreshStartedPromise = new Promise<void>((resolve) => { refreshStarted = resolve; });
    const selected = sessionDouble({
      execute: async () => {
        executeStarted();
        return executing.promise;
      },
      refresh: async (input) => {
        refreshStarted();
        await refresh.promise;
        return refreshed(input, "live-refresh-token");
      },
    });
    const { lifecycle } = harness(store, [selected]);

    const pending = check(lifecycle);
    await executeStartedPromise;
    await expect(lifecycle.getConnectionHealth(CONNECTION_ID, UID))
      .resolves.toMatchObject({ healthState: "checking", lastCheckedAt: null, lastSuccessAt: null });
    executing.resolve(failure("unauthorized"));
    await refreshStartedPromise;
    await expect(lifecycle.getConnectionHealth(CONNECTION_ID, UID))
      .resolves.toMatchObject({ healthState: "refreshing", lastCheckedAt: null, lastSuccessAt: null });
    refresh.resolve();
    await expect(pending).resolves.toMatchObject({ to: "needs_auth" });
    await expect(lifecycle.getConnectionHealth(CONNECTION_ID, UID))
      .resolves.toMatchObject({ healthState: "needs_auth" });
  });

  it("evicts idle runtime state by TTL and bounds the number of retained connections", async () => {
    vi.useFakeTimers();
    try {
      const evictions: Array<{ connectionId: string; reason: string }> = [];
      const store = new FakeHealthStore(connection());
      const selected = sessionDouble({ execute: async () => success() });
      const { lifecycle } = harness(store, [selected], {
        runtimeTtlMs: 50,
        maxRuntimes: 1,
        onRuntimeEvicted(event) {
          evictions.push({ connectionId: event.connectionId, reason: event.reason });
        },
      });

      await check(lifecycle);
      await expect(lifecycle.checkConnectionHealth("missing", UID, OPERATION_ID))
        .rejects.toMatchObject({ code: "not_found" });
      await expect(lifecycle.checkConnectionHealth(CONNECTION_ID, "wrong-owner", OPERATION_ID))
        .rejects.toMatchObject({ code: "not_found" });
      expect(evictions).toEqual([]);
      await vi.advanceTimersByTimeAsync(60);
      expect(evictions).toEqual([{ connectionId: CONNECTION_ID, reason: "ttl" }]);

      await check(lifecycle);
      const otherId = "22222222-2222-4222-8222-222222222222";
      store.row = { ...store.row!, connectionId: otherId, healthState: "never_checked" };
      await lifecycle.checkConnectionHealth(otherId, UID, OPERATION_ID);
      expect(evictions).toContainEqual({ connectionId: CONNECTION_ID, reason: "capacity" });
    } finally {
      vi.useRealTimers();
    }
  });

  it("constructing the lifecycle performs no roster, discovery, secret, transport, or health work", async () => {
    const store = new FakeHealthStore(connection());
    const { openCalls } = harness(store, []);
    expect(openCalls()).toBe(0);
    expect(store.writes).toHaveLength(0);
    expect(store.tokenWriteAttempts).toBe(0);
    expect(store.disconnectAttempts).toBe(0);
  });
});
