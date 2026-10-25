import {
  createConnectionHealthLifecycle,
  healthProbeArgs,
  type ConnectionHealthInvocations,
  type ConnectionHealthLifecycle,
  type ConnectionHealthLifecycleDeps,
  type ConnectionHealthStore,
  type CuratedCatalog,
  type EnvelopeCrypto,
  type GuardedFetch,
  type HealthOpenInput,
  type HealthOperationInput,
  type HealthOperationOutcome,
  type HealthOperationSession,
  type HealthProvider,
  type McpCallContext,
  type McpToolCallResult,
  type NativeMcpHandler,
  type ProviderEgress,
  type RunMcpSnapshot,
} from "@ovid/mcp";
import {
  createConnectionHealthStore as createDbConnectionHealthStore,
  mcpOauthTokens,
  mcpServers as serverRepo,
  type Db,
  type McpServerRow,
} from "@ovid/db";

import { createConnectionHealthOAuthRefresher } from "./connectionHealthOAuth.js";
import type {
  McpToolContext,
  McpToolProvider,
  McpToolProviderOptions,
} from "./mcpTools.js";

export interface WorkerConnectionHealthDeps {
  db: Db;
  crypto: EnvelopeCrypto;
  providers: readonly HealthProvider[];
  /** Builds a session-owned catalog whose egress is linked to this signal. */
  catalogForSignal(signal: AbortSignal): CuratedCatalog;
  operationFetch: GuardedFetch;
  /** Separate OAuth-only guarded fetch; never a generic provider fallback. */
  oauthFetch: GuardedFetch;
  /** Production uses the real DB adapter; isolated tests may supply the same port. */
  store?: ConnectionHealthStore;
  closeOwnedTransports?(connectionId: string, uid: string): void | Promise<void>;
  now?(): Date;
  runtimeTtlMs?: number;
  maxRuntimes?: number;
  onRuntimeEvicted?: ConnectionHealthLifecycleDeps["onRuntimeEvicted"];
}

/** Forward both the handler deadline and health-session disconnect into real I/O. */
export function scopedProviderEgress(
  upstream: ProviderEgress,
  sessionSignal: AbortSignal,
): ProviderEgress {
  return {
    async request(request) {
      const controller = new AbortController();
      const signals = [...new Set([sessionSignal, ...(request.signal === undefined ? [] : [request.signal])])];
      const listeners = new Map<AbortSignal, () => void>();
      for (const signal of signals) {
        const listener = () => controller.abort(signal.reason);
        listeners.set(signal, listener);
        if (signal.aborted) listener();
        else signal.addEventListener("abort", listener, { once: true });
      }
      try {
        if (controller.signal.aborted) throw new Error("health_session_closed");
        return await upstream.request({ ...request, signal: controller.signal });
      } finally {
        for (const [signal, listener] of listeners) signal.removeEventListener("abort", listener);
      }
    },
    // The runtime owns upstream. Closing a health session must not close it.
    async close() {},
  };
}

function stringMap(value: unknown): Record<string, string> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return {};
  return Object.fromEntries(Object.entries(value).filter((entry): entry is [string, string] =>
    typeof entry[1] === "string"
  ));
}

function oauthCredentialKeys(provider: HealthProvider | undefined): readonly string[] {
  const schema = provider?.connectionSchema;
  const properties = typeof schema?.properties === "object" && schema.properties !== null
    ? schema.properties as Record<string, unknown>
    : {};
  return ["access_token", "oauth_access_token"].filter((key) => key in properties);
}

function currentVersion(row: McpServerRow, expected: HealthOpenInput["expected"]): boolean {
  return row.enabled && row.configVersion === expected.configVersion &&
    row.disconnectGeneration === expected.disconnectGeneration;
}

function operationOutcome(result: McpToolCallResult): HealthOperationOutcome {
  if (result.isError === false) {
    return typeof result.text === "string" && Array.isArray(result.content)
      ? { status: "succeeded" }
      : { status: "failed", reason: "unavailable" };
  }
  if (result.isError !== true || typeof result.text !== "string") {
    return { status: "failed", reason: "unavailable" };
  }
  const text = result.text.trim();
  const status = /^Provider request failed \(HTTP (\d{3})\)\.$/.exec(text)?.[1] ??
    /^HTTP error (\d{3})(?::|$)/.exec(text)?.[1];
  if (status === "401") return { status: "failed", reason: "unauthorized" };
  if (status !== undefined) return { status: "failed", reason: "degraded" };
  return { status: "failed", reason: "unavailable" };
}

async function decryptedConnectionSecrets(
  deps: WorkerConnectionHealthDeps,
  provider: HealthProvider | undefined,
  raw: McpServerRow,
): Promise<Record<string, string>> {
  // Public Fetch health is explicitly credential-free; do not even decrypt a
  // legacy secrets envelope merely because it is present on the row.
  if (provider?.providerId === "fetch") return {};
  let parsed: unknown = null;
  if (raw.secretsSealed !== null) {
    parsed = JSON.parse(deps.crypto.decrypt(raw.secretsSealed, `mcp_servers:${raw.id}`));
  }
  const secrets = {
    ...stringMap(raw.config),
    ...stringMap(parsed),
  };

  const credentialKeys = oauthCredentialKeys(provider);
  if (credentialKeys.length === 0) return secrets;
  const oauth = await mcpOauthTokens.get(deps.db, raw.id, raw.userId);
  if (oauth === null) return secrets;
  // Read-only access-token projection. Refresh is exclusively the fenced
  // connectionHealthOAuth adapter, never OAuthFlow.getAccessToken here.
  const material = JSON.parse(deps.crypto.decrypt(
    oauth.tokensSealed,
    `mcp_oauth_tokens:${raw.id}`,
  )) as unknown;
  if (typeof material !== "object" || material === null) return secrets;
  const accessToken = (material as Record<string, unknown>).accessToken;
  if (typeof accessToken !== "string" || accessToken === "") return secrets;
  for (const key of credentialKeys) secrets[key] = accessToken;
  return secrets;
}

function createRealHealthSession(
  deps: WorkerConnectionHealthDeps,
  input: HealthOpenInput,
): HealthOperationSession {
  const provider = deps.providers.find((candidate) => candidate.providerId === input.connection.providerId);
  const controller = new AbortController();
  const abort = () => controller.abort(input.signal.reason);
  if (input.signal.aborted) abort();
  else input.signal.addEventListener("abort", abort, { once: true });
  const deadline = setTimeout(() => controller.abort("health_session_timeout"), 30_000);
  deadline.unref?.();
  let handler: NativeMcpHandler;
  try {
    const catalog = deps.catalogForSignal(controller.signal);
    const entry = catalog.get(input.connection.providerId);
    if (entry === undefined) throw new Error("health_provider_unavailable");
    handler = entry.handler;
  } catch (error) {
    clearTimeout(deadline);
    input.signal.removeEventListener("abort", abort);
    controller.abort("health_session_closed");
    throw error;
  }
  const refreshOAuth = createConnectionHealthOAuthRefresher({
    db: deps.db,
    crypto: deps.crypto,
    fetchImpl: deps.oauthFetch,
    ...(deps.now === undefined ? {} : { now: deps.now }),
  });
  let closed = false;
  let closePromise: Promise<void> | undefined;
  const canRefresh = oauthCredentialKeys(provider).length > 0;

  async function close(): Promise<void> {
    closePromise ??= (async () => {
      closed = true;
      clearTimeout(deadline);
      input.signal.removeEventListener("abort", abort);
      controller.abort("health_session_closed");
      await handler.dispose?.();
    })();
    return closePromise;
  }

  return {
    async execute(executeInput: HealthOperationInput): Promise<HealthOperationOutcome> {
      if (closed || executeInput.signal.aborted || executeInput.operation.name !== input.operation.name ||
          executeInput.expected.configVersion !== input.expected.configVersion ||
          executeInput.expected.disconnectGeneration !== input.expected.disconnectGeneration) {
        return { status: "failed", reason: "unavailable" };
      }
      const raw = await serverRepo.get(deps.db, input.connection.connectionId, input.connection.userId);
      if (raw === null || !currentVersion(raw, input.expected)) {
        return { status: "failed", reason: "unavailable" };
      }
      const args = healthProbeArgs({
        providerId: input.connection.providerId,
        operation: input.operation,
        config: raw.config,
      });
      if (args === null) return { status: "failed", reason: "unavailable" };

      let secrets: Record<string, string> | null = null;
      try {
        secrets = await decryptedConnectionSecrets(deps, provider, raw);
        // Final cross-process fence immediately before invoking the real typed
        // handler; no provider call is issued for a disconnected generation.
        const current = await serverRepo.get(deps.db, input.connection.connectionId, input.connection.userId);
        if (current === null || !currentVersion(current, input.expected) ||
            current.authState === "revoked" || current.healthState === "revoked") {
          return { status: "failed", reason: "unavailable" };
        }
        if (closed || executeInput.signal.aborted) return { status: "failed", reason: "unavailable" };
        const ctx = {
          uid: input.connection.userId,
          secrets,
          workspace: {},
          fetchImpl: deps.operationFetch,
          sessionId: "connection-health",
          runId: `health:${input.connection.connectionId}`,
          userId: input.connection.userId,
          connectionId: input.connection.connectionId,
          providerId: input.connection.providerId,
          mode: "safe",
          planMode: false,
          unattended: false,
          isSubagent: false,
          depth: 0,
          callKey: `health:${input.operation.name}`,
          signal: executeInput.signal,
        } as McpCallContext;
        const result = await handler.callTool(input.operation.name, args, ctx);
        return operationOutcome(result);
      } catch {
        return { status: "failed", reason: "unavailable" };
      } finally {
        // No decrypted config/access token is retained on the session or cache.
        secrets = null;
      }
    },

    ...(canRefresh ? {
      async refresh(refreshInput: Parameters<NonNullable<HealthOperationSession["refresh"]>>[0]) {
        if (closed || refreshInput.signal.aborted ||
            refreshInput.expected.configVersion !== input.expected.configVersion ||
            refreshInput.expected.disconnectGeneration !== input.expected.disconnectGeneration) {
          return { status: "failed", reason: "unauthorized" } as const;
        }
        return refreshOAuth({
          connectionId: input.connection.connectionId,
          userId: input.connection.userId,
        }, refreshInput);
      },
    } : {}),
    close,
  };
}

/** Real DB + catalog + OAuth composition used by the worker runtime by default. */
export function createWorkerConnectionHealth(
  deps: WorkerConnectionHealthDeps,
): ConnectionHealthLifecycle {
  return createConnectionHealthLifecycle({
    store: deps.store ?? createDbConnectionHealthStore(deps.db),
    providers: deps.providers,
    open: (input) => Promise.resolve().then(() => createRealHealthSession(deps, input)),
    ...(deps.closeOwnedTransports === undefined ? {} : { closeOwnedTransports: deps.closeOwnedTransports }),
    ...(deps.now === undefined ? {} : { now: deps.now }),
    ...(deps.runtimeTtlMs === undefined ? {} : { runtimeTtlMs: deps.runtimeTtlMs }),
    ...(deps.maxRuntimes === undefined ? {} : { maxRuntimes: deps.maxRuntimes }),
    ...(deps.onRuntimeEvicted === undefined ? {} : { onRuntimeEvicted: deps.onRuntimeEvicted }),
  });
}

function unauthorizedResult(result: { content: string; isError?: boolean }): boolean {
  if (result.isError !== true) return false;
  const text = result.content.trim();
  return /^Provider request failed \(HTTP 401\)\.$/.test(text) || /^HTTP error 401(?::|$)/.test(text);
}

function healthReadable(operation: RunMcpSnapshot["operations"][number]): boolean {
  return operation.definition.effect === "read" &&
    (operation.definition.request.method === "GET" || operation.definition.request.method === "HEAD");
}

/**
 * Lazy health runs only after a selected typed read actually reports 401.
 * A successful refresh permits one retry of that read; writes are never probes.
 */
export function withLazyConnectionHealth(
  base: McpToolProvider,
  invocations: ConnectionHealthInvocations,
  opts: Pick<McpToolProviderOptions, "snapshotFor">,
): McpToolProvider {
  const provider: McpToolProvider = {
    async tools(snapshot) {
      const tools = await base.tools(snapshot);
      return tools.map((tool) => {
        const legacySelected = tool.name === "integration_call"
          ? undefined
          : snapshot.operations.find((operation) => operation.modelName === tool.name);
        if (tool.name !== "integration_call" && legacySelected === undefined) return tool;
        return {
          ...tool,
          async execute(args: Record<string, unknown>, ctx: McpToolContext) {
            const original = await tool.execute(args, ctx);
            if (!unauthorizedResult(original)) return original;
            const current = await opts.snapshotFor(ctx);
            const selected = tool.name === "integration_call"
              ? current?.operations.find((operation) =>
                  operation.connectionId === args.connectionId && operation.operationId === args.operationId
                )
              : current?.operations.find((operation) => operation.modelName === tool.name);
            if (current === null || current === undefined || selected === undefined || !healthReadable(selected)) {
              return original;
            }
            try {
              const checked = await invocations.checkSelectedOperation({
                snapshot: current,
                uid: ctx.uid,
                connectionId: selected.connectionId,
                operationId: selected.operationId,
              });
              return checked.to === "healthy" ? tool.execute(args, ctx) : original;
            } catch {
              return original;
            }
          },
        };
      });
    },
    async specs(snapshot) {
      return base.specs(snapshot);
    },
  };
  return provider;
}
