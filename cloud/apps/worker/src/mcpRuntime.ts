/**
 * Worker MCP runtime (P5 Task 16) — the composition root for the P5 surface
 * inside the worker process:
 *
 *   db + masterKey ─► EnvelopeCrypto ─► sealed server/token rows
 *   redisQ ─────────► UserSystemBus (sys:{uid}:out / sys:{uid}:in)
 *   sandbox seam ───► curated catalog (workspace) + McpRouter (spawner)
 *                  └► plugin installer (files/spawner + source resolver)
 *   one ContributionRegistry shared by the installer and P3's roster.
 *
 * `sandbox: null` is a supported deployment state: the curated
 * fetch/REST/GitHub servers keep working; stdio/filesystem/memory tools and
 * plugin installs fail cleanly with `sandbox_unavailable`.
 *
 * The runtime deliberately does NOT start the plugin-installs queue worker:
 * `installer` is the transaction, and main.ts composes the consumer around
 * this SAME instance (`mcpRuntime.installer`) with
 * `createPluginInstallProcessor` + `createPluginInstallsWorker`. Keeping the
 * worker out of the runtime means there is exactly one installer (and one
 * ContributionRegistry) per worker process.
 */

import type { Redis } from "ioredis";
import type { Db } from "@ovid/db";
import {
  createContributionRegistry,
  createCuratedCatalog,
  createEnvelopeCrypto,
  createGuardedFetch,
  createMcpRouter,
  createOAuthFlow,
  createPluginInstaller,
  createRedisSystemBus,
  createSourceResolver,
  type ContributionRegistry,
  type EnvelopeCrypto,
  type GuardedFetch,
  type McpRouter,
  type SandboxFiles,
  type SandboxSpawner,
  type SourceResolver,
  type UserSystemBus,
} from "@ovid/mcp";
import { createUnavailableSandbox } from "./sandboxSeam.js";

export interface McpRuntime {
  router: McpRouter;
  registry: ContributionRegistry;
  installer: ReturnType<typeof createPluginInstaller>;
  /**
   * The one source resolver (I3): P3's catalog tools need it to derive the
   * canonical plugin id at enqueue, exactly as the installer will.
   */
  resolver: SourceResolver;
  shutdown(): Promise<void>;
}

export interface McpRuntimeDeps {
  db: Db;
  redisQ: Redis;
  masterKey: string;
  /**
   * The P2-backed pair (`createSandboxSeam(...)`), or null when the worker
   * has no sandbox chain — the runtime substitutes
   * `createUnavailableSandbox()`.
   */
  sandbox: { spawner: SandboxSpawner; files: SandboxFiles } | null;
  /** Defaults to @ovid/mcp's SSRF-guarded fetch. */
  fetchImpl?: GuardedFetch;
  githubApiBase?: string;
  /**
   * GitHub API token for plugin-source resolution (M6). Passed explicitly so
   * an embedded/test `main(env)` keeps the token instead of silently falling
   * back to `process.env.GITHUB_API_TOKEN` (unauthenticated rate limits).
   */
  githubToken?: string;
  /**
   * Test seam (additive): inject the system bus instead of building the
   * Redis one. Production leaves this undefined.
   */
  systemBus?: UserSystemBus;
}

export function createMcpRuntime(deps: McpRuntimeDeps): McpRuntime {
  const crypto: EnvelopeCrypto = createEnvelopeCrypto(deps.masterKey);
  const fetchImpl = deps.fetchImpl ?? createGuardedFetch();
  const systemBus =
    deps.systemBus ??
    createRedisSystemBus(
      // ioredis's `off`/`on` listener types are `(...args: any[])`; the bus's
      // structural SystemRedis mirror declares `never[]`. Same client, same
      // methods — the cast is the documented wave-merger carry.
      deps.redisQ as unknown as Parameters<typeof createRedisSystemBus>[0],
    );
  const sandbox = deps.sandbox ?? createUnavailableSandbox();

  // ONE catalog instance: the curated handlers are process-wide singletons
  // (the shared-singleton guarantee the router's per-uid clients rely on).
  const catalog = createCuratedCatalog({
    fetchImpl,
    workspace: sandbox.files,
    ...(deps.githubApiBase !== undefined ? { githubApiBase: deps.githubApiBase } : {}),
  });

  const oauth = createOAuthFlow({
    db: deps.db,
    crypto,
    systemBus,
    fetchImpl,
  });

  const router = createMcpRouter({
    db: deps.db,
    crypto,
    catalog,
    systemBus,
    spawner: sandbox.spawner,
    workspace: sandbox.files,
    fetchImpl,
    oauth,
  });

  const registry = createContributionRegistry();
  const resolver = createSourceResolver({
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
      // Stop accepting/using connections first, then release the bus's
      // pending subscribers (they resolve null = deny).
      await router.shutdown();
      await systemBus.close();
    })();
    return shuttingDown;
  };

  return { router, registry, installer, resolver, shutdown };
}
