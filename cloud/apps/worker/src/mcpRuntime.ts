/**
 * Worker MCP runtime: one activation service, one pinned provider egress and
 * one router/catalog/installer composition. Activated generic REST calls use
 * ProviderEgress; legacy guarded fetch is confined to explicit compatibility
 * tests and later OAuth/plugin/special-native integration gates.
 */

import { AsyncLocalStorage } from "node:async_hooks";
import type { Redis } from "ioredis";
import {
  mcpServers,
  revalidateConnection as revalidateProviderConnection,
  toMcpConnectionRow,
  type Db,
} from "@ovid/db";
import {
  createActivationService,
  createConnectionHealthInvocations,
  createContributionRegistry,
  createCuratedCatalog,
  createCuratedProviderSupport,
  createEnvelopeCrypto,
  createMcpRouter,
  createOAuthFlow,
  createPluginInstaller,
  createProviderEgress,
  createRedisSystemBus,
  createSecretRedactor,
  createSourceResolver,
  type ActivationService,
  type ActivationServiceDeps,
  type CatalogEntry,
  type ConnectionHealthInvocations,
  type ContributionRegistry,
  type CuratedCatalog,
  type EnvelopeCrypto,
  type GuardedFetch,
  type HealthConnection,
  type HealthTransition,
  type McpCallContext,
  type McpRouter,
  type NativeMcpHandler,
  type ProviderEgress,
  type ProviderRegistry,
  type RunContext,
  type SandboxFiles,
  type SandboxSpawner,
  type SourceResolver,
  type UserSystemBus,
} from "@ovid/mcp";
import { createUnavailableSandbox } from "./sandboxSeam.js";
import { createConnectorDiscoveryToolProvider } from "./connectorDiscoveryTools.js";
import {
  createWorkerConnectionHealth,
  scopedProviderEgress,
  withLazyConnectionHealth,
} from "./connectionHealth.js";
import type { McpToolProvider, McpToolProviderOptions } from "./mcpTools.js";

export interface McpRuntimeHealth {
  checkConnectionHealth(connectionId: string, uid: string, operationId: string): Promise<HealthTransition>;
  getConnectionHealth?(connectionId: string, uid: string): Promise<HealthConnection>;
  disconnectConnection?(connectionId: string, uid: string): Promise<HealthConnection>;
}

export interface McpRuntime {
  router: McpRouter;
  activation: ActivationService;
  registry: ContributionRegistry;
  installer: ReturnType<typeof createPluginInstaller>;
  resolver: SourceResolver;
  /** Lazy discovery/schema/call roster; composition replaces the legacy eager provider with this. */
  createToolProvider(options: McpToolProviderOptions): McpToolProvider;
  /** Real lifecycle by default; never invoked by roster/discovery construction. */
  connectionHealth?: McpRuntimeHealth;
  /** Explicit verified-principal and exact-selected-operation invocation surfaces. */
  connectionHealthInvocations?: ConnectionHealthInvocations;
  shutdown(): Promise<void>;
}

export interface McpRuntimeDeps {
  db: Db;
  redisQ: Redis;
  masterKey: string;
  /** Optional composition seams; defaults preserve the production implementations. */
  crypto?: EnvelopeCrypto;
  sourceResolver?: SourceResolver;
  revalidateConnection?: ActivationServiceDeps["revalidateConnection"];
  connectionHealth?: McpRuntimeHealth;
  sandbox: { spawner: SandboxSpawner; files: SandboxFiles } | null;
  /** Later-gate OAuth/plugin compatibility. Production never uses this for activated REST. */
  fetchImpl?: GuardedFetch;
  /** Explicit legacy-handler test seam; never set by production composition. */
  legacyProviderFetchForTest?: boolean;
  /** Test injection or the one production DNS-pinned provider transport. */
  providerEgress?: ProviderEgress;
  /** Explicit isolated test registry; production composition always uses the shared default. */
  providerRegistry?: ProviderRegistry;
  production?: boolean;
  githubApiBase?: string;
  githubToken?: string;
  systemBus?: UserSystemBus;
}

const legacyFetchDisabled: GuardedFetch = async () => {
  throw new Error("legacy_provider_fetch_disabled");
};

function contextualCatalog(
  base: CuratedCatalog,
  storage: AsyncLocalStorage<Record<string, unknown>>,
): CuratedCatalog {
  const handlers = new Map<NativeMcpHandler, NativeMcpHandler>();
  const wrapHandler = (handler: NativeMcpHandler): NativeMcpHandler => {
    const existing = handlers.get(handler);
    if (existing !== undefined) return existing;
    const wrapped: NativeMcpHandler = {
      initialize: (params) => handler.initialize(params),
      listTools: () => handler.listTools(),
      callTool: (name, args, ctx) => handler.callTool(name, args, {
        ...ctx,
        ...storage.getStore(),
      } as McpCallContext),
      ...(handler.dispose !== undefined ? { dispose: () => handler.dispose!() } : {}),
    };
    handlers.set(handler, wrapped);
    return wrapped;
  };
  const wrapEntry = (entry: CatalogEntry): CatalogEntry => ({
    ...entry,
    handler: wrapHandler(entry.handler),
  });
  return {
    entries: () => base.entries().map(wrapEntry),
    get: (id) => {
      const entry = base.get(id);
      return entry === undefined ? undefined : wrapEntry(entry);
    },
  };
}

function contextualRouter(
  base: McpRouter,
  storage: AsyncLocalStorage<Record<string, unknown>>,
  healthInvocations: ConnectionHealthInvocations,
): McpRouter {
  const withRun = <T>(runCtx: RunContext | undefined, fn: () => Promise<T>): Promise<T> =>
    runCtx === undefined
      ? fn()
      : storage.run(runCtx as unknown as Record<string, unknown>, fn);
  return {
    connectionHealthInvocations: healthInvocations,
    listServers: (uid) => base.listServers(uid),
    addServer: (uid, input) => base.addServer(uid, input),
    updateServer: (uid, id, patch) => base.updateServer(uid, id, patch),
    removeServer: (uid, id) => base.removeServer(uid, id),
    disconnectServerTransports: (uid, id) => base.disconnectServerTransports(uid, id),
    listTools: (uid, runCtx) => withRun(runCtx, () => base.listTools(uid, runCtx)),
    resolveTool: (uid, name, runCtx) => withRun(runCtx, () => base.resolveTool(uid, name, runCtx)),
    callTool: (uid, name, args, runCtx) =>
      withRun(runCtx, () => base.callTool(uid, name, args, runCtx)),
    connectForRun: (uid, runCtx) => withRun(runCtx, () => base.connectForRun(uid, runCtx)),
    releaseRun: (uid, runCtx) => base.releaseRun(uid, runCtx),
    shutdown: () => base.shutdown(),
  };
}

export function createMcpRuntime(deps: McpRuntimeDeps): McpRuntime {
  const crypto: EnvelopeCrypto = deps.crypto ?? createEnvelopeCrypto(deps.masterKey);
  const redactor = createSecretRedactor();
  const support = createCuratedProviderSupport(deps.providerRegistry);
  const providerEgress = deps.providerEgress ??
    (deps.legacyProviderFetchForTest === true
      ? undefined
      : createProviderEgress({
          origins: support.origins,
          redactor,
          production: deps.production ?? true,
        }));
  const fetchImpl = deps.fetchImpl ?? legacyFetchDisabled;
  const providerCalls = new AsyncLocalStorage<Record<string, unknown>>();
  const systemBus = deps.systemBus ?? createRedisSystemBus(
    deps.redisQ as unknown as Parameters<typeof createRedisSystemBus>[0],
  );
  const sandbox = deps.sandbox ?? createUnavailableSandbox();

  const baseCatalog = createCuratedCatalog({
    fetchImpl,
    workspace: sandbox.files,
    registry: support.registry,
    ...(deps.githubApiBase !== undefined ? { githubApiBase: deps.githubApiBase } : {}),
    ...(providerEgress !== undefined
      ? {
          providerEgress,
          handlerOverrides: support.handlerOverrides(providerEgress, redactor),
        }
      : {}),
  });
  const catalog = contextualCatalog(baseCatalog, providerCalls);

  const activation = createActivationService({
    definitions: support.definitions,
    listConnections: async (userId) => {
      const rows = await mcpServers.list(deps.db, userId);
      return rows.map((raw) => {
        const row = toMcpConnectionRow(raw);
        return {
          connectionId: row.connectionId,
          userId: row.userId,
          providerId: row.providerId,
          enabled: row.enabled,
          agentEnabled: row.agentEnabled,
          authState: row.authState,
          configVersion: row.configVersion,
          disconnectGeneration: row.disconnectGeneration,
        };
      });
    },
    revalidateConnection: deps.revalidateConnection ?? ((call) => revalidateProviderConnection(
      deps.db,
      call.connectionId,
      call.userId,
      {
        configVersion: call.configVersion,
        disconnectGeneration: call.disconnectGeneration,
      },
    )),
  });

  const oauth = createOAuthFlow({
    db: deps.db,
    crypto,
    systemBus,
    fetchImpl,
  });
  const baseRouter = createMcpRouter({
    db: deps.db,
    crypto,
    catalog,
    systemBus,
    spawner: sandbox.spawner,
    workspace: sandbox.files,
    fetchImpl,
    oauth,
  });

  const connectionHealth = deps.connectionHealth ?? createWorkerConnectionHealth({
    db: deps.db,
    crypto,
    providers: support.definitions,
    catalogForSignal: (signal) => {
      const sessionEgress = providerEgress === undefined
        ? undefined
        : scopedProviderEgress(providerEgress, signal);
      return createCuratedCatalog({
        fetchImpl,
        workspace: sandbox.files,
        registry: support.registry,
        ...(deps.githubApiBase !== undefined ? { githubApiBase: deps.githubApiBase } : {}),
        ...(sessionEgress !== undefined
          ? {
              providerEgress: sessionEgress,
              handlerOverrides: support.handlerOverrides(sessionEgress, redactor),
            }
          : {}),
      });
    },
    operationFetch: fetchImpl,
    oauthFetch: fetchImpl,
    closeOwnedTransports: async (connectionId, uid) => {
      await baseRouter.disconnectServerTransports(uid, connectionId);
    },
  });
  const healthInvocations = createConnectionHealthInvocations({
    lifecycle: connectionHealth,
    revalidate: (snapshot, call) => activation.revalidate(snapshot, call),
  });
  const router = contextualRouter(baseRouter, providerCalls, healthInvocations);

  const registry = createContributionRegistry();
  const resolver = deps.sourceResolver ?? createSourceResolver({
    fetchImpl,
    ...(deps.githubApiBase !== undefined ? { githubApiBase: deps.githubApiBase } : {}),
    ...(deps.githubToken !== undefined ? { githubToken: deps.githubToken } : {}),
  });
  const installer = createPluginInstaller({
    db: deps.db,
    crypto,
    systemBus,
    resolver,
    sandbox,
    registry,
  });

  let shuttingDown: Promise<void> | null = null;
  const shutdown = (): Promise<void> => {
    shuttingDown ??= (async () => {
      await router.shutdown();
      await providerEgress?.close();
      await systemBus.close();
    })();
    return shuttingDown;
  };

  return {
    router,
    activation,
    registry,
    installer,
    resolver,
    createToolProvider: (options) => withLazyConnectionHealth(
      createConnectorDiscoveryToolProvider(router, options),
      healthInvocations,
      options,
    ),
    connectionHealth,
    connectionHealthInvocations: healthInvocations,
    shutdown,
  };
}
