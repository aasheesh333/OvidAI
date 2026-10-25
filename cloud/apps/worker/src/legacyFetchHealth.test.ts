// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
// Requires TEST_DATABASE_URL. No test, typecheck, build, database, or provider
// execution has occurred; this is not a RED/GREEN or live-composition claim.
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import {
  createConnectionHealthStore,
  createDb,
  mcpServers as serverRepo,
  migrate,
  newId,
  schema,
  users,
  type Db,
} from "@ovid/db";
import {
  createCuratedCatalog,
  createCuratedProviderSupport,
  createEnvelopeCrypto,
  createFetchHandler,
  createGitHubHandler,
  type GuardedFetch,
  type McpCallContext,
  type NativeMcpHandler,
} from "@ovid/mcp";

import { createTestProviderRegistry } from "../../../packages/mcp/src/__fixtures__/providerRegistry.js";
import { createMigrationScratch, type MigrationScratch } from "../../../packages/db/src/migrationTestKit.js";
import { createWorkerConnectionHealth } from "./connectionHealth.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const CHECKED_AT = new Date("2026-10-25T02:00:00.000Z");
const MASTER_KEY = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

function countTypedCalls(handler: NativeMcpHandler, count: () => void): NativeMcpHandler {
  return {
    ...handler,
    async callTool(name: string, args: Record<string, unknown>, ctx: McpCallContext) {
      count();
      return handler.callTool(name, args, ctx);
    },
  };
}

/** Real raw row -> real DB health projection/store -> real MCP lifecycle. */
describe.skipIf(!TEST_DATABASE_URL)("legacy provider health on real Postgres (UNEXECUTED)", () => {
  let scratch: MigrationScratch;
  let db: Db;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "legacy_fetch_health");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 4 });
  }, 180_000);

  afterEach(() => {
    vi.restoreAllMocks();
  });

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  async function seedLegacyRow(providerId: "fetch" | "github", secrets: Record<string, string>) {
    const uid = newId();
    const connectionId = newId();
    const crypto = createEnvelopeCrypto(MASTER_KEY);
    await users.ensure(db, uid, `${uid}@test.local`);
    const secretsSealed = crypto.encrypt(
      JSON.stringify(secrets),
      `mcp_servers:${connectionId}`,
    );
    // Deliberately omit provider_id, config, config_version, and
    // disconnect_generation so their persisted legacy/DB defaults are real.
    await db.insert(schema.mcpServers).values({
      id: connectionId,
      userId: uid,
      name: `Legacy ${providerId}`,
      transport: "native",
      curatedId: providerId,
      authState: "unknown",
      secretsSealed,
      enabled: true,
      agentEnabled: false,
    });
    const rawRows = await db.select().from(schema.mcpServers);
    const raw = rawRows.find((row) => row.id === connectionId);
    expect(raw).toMatchObject({
      providerId: null,
      curatedId: providerId,
      authState: "unknown",
      config: null,
      configVersion: 1,
      disconnectGeneration: 0,
    });
    expect(raw?.secretsSealed).not.toBeNull();
    return { uid, connectionId, crypto };
  }

  it("reaches worker null-config validation before returning unavailable without decrypting sealed material", async () => {
    const canary = "legacy-fetch-sealed-canary-must-not-decrypt";
    const { uid, connectionId, crypto } = await seedLegacyRow("fetch", { authorization: canary });
    const store = createConnectionHealthStore(db);
    await expect(store.get(connectionId, uid)).resolves.toMatchObject({
      providerId: "fetch",
      authState: "missing",
      configVersion: 1,
      disconnectGeneration: 0,
      legacyUnknownAuthWithoutConfig: true,
    });

    // The synthetic supported registry is test-only and does not change Fetch's
    // blocked production readiness. It supplies the real reviewed schema.
    const registry = createTestProviderRegistry({ supported: ["fetch"] });
    const support = createCuratedProviderSupport(registry);
    const decrypt = vi.spyOn(crypto, "decrypt");
    let catalogOpenCalls = 0;
    let sessionHandlerCreations = 0;
    let rawReadsAfterSessionHandler = 0;
    let typedCalls = 0;
    let requests = 0;
    let oauthCalls = 0;
    const realServerGet = serverRepo.get;
    vi.spyOn(serverRepo, "get").mockImplementation(async (database, id, owner) => {
      if (sessionHandlerCreations > 0) rawReadsAfterSessionHandler += 1;
      return realServerGet(database, id, owner);
    });
    const operationFetch: GuardedFetch = async () => {
      requests += 1;
      throw new Error("invalid legacy config must not reach provider I/O");
    };
    const lifecycle = createWorkerConnectionHealth({
      db,
      crypto,
      store,
      providers: support.definitions,
      catalogForSignal: () => {
        catalogOpenCalls += 1;
        return createCuratedCatalog({
          fetchImpl: operationFetch,
          workspace: {},
          registry,
          handlerOverrides: {
            fetch: () => {
              sessionHandlerCreations += 1;
              return countTypedCalls(createFetchHandler(), () => { typedCalls += 1; });
            },
          },
        });
      },
      operationFetch,
      oauthFetch: async () => {
        oauthCalls += 1;
        throw new Error("legacy Fetch must not invoke OAuth");
      },
      now: () => CHECKED_AT,
    });

    const transition = await lifecycle.checkConnectionHealth(connectionId, uid, "fetch");

    expect(transition).toMatchObject({
      to: "unavailable",
      reason: "unavailable",
      persisted: true,
      lastCheckedAt: CHECKED_AT.toISOString(),
      lastSuccessAt: null,
      connection: {
        authState: "missing",
        configVersion: 1,
        disconnectGeneration: 0,
      },
    });
    expect(transition.connection).not.toHaveProperty("legacyUnknownAuthWithoutConfig");
    expect(JSON.stringify(transition)).not.toContain(canary);
    expect(catalogOpenCalls).toBe(1);
    expect(sessionHandlerCreations).toBe(1);
    // One post-open read is the lifecycle fence. The next is the real worker
    // execute() raw-row read immediately before its config:null rejection;
    // deps.open failure or a skipped execute cannot satisfy this assertion.
    expect(rawReadsAfterSessionHandler).toBe(2);
    expect(typedCalls).toBe(0);
    expect(requests).toBe(0);
    expect(oauthCalls).toBe(0);
    expect(decrypt).not.toHaveBeenCalled();
    await expect(store.get(connectionId, uid)).resolves.toMatchObject({
      authState: "missing",
      healthState: "unavailable",
      lastCheckedAt: CHECKED_AT.toISOString(),
      lastSuccessAt: null,
      configVersion: 1,
      disconnectGeneration: 0,
    });
  });

  it("keeps a real unknown/null GitHub control at missing_auth without opening a session", async () => {
    const canary = "legacy-github-sealed-canary-must-not-decrypt";
    const { uid, connectionId, crypto } = await seedLegacyRow("github", { GITHUB_TOKEN: canary });
    const store = createConnectionHealthStore(db);
    await expect(store.get(connectionId, uid)).resolves.toMatchObject({
      providerId: "github",
      authState: "missing",
      configVersion: 1,
      disconnectGeneration: 0,
      legacyUnknownAuthWithoutConfig: true,
    });

    const registry = createTestProviderRegistry({ supported: ["github"] });
    const support = createCuratedProviderSupport(registry);
    const decrypt = vi.spyOn(crypto, "decrypt");
    let catalogOpenCalls = 0;
    let sessionHandlerCreations = 0;
    let typedCalls = 0;
    let requests = 0;
    let oauthCalls = 0;
    const operationFetch: GuardedFetch = async () => {
      requests += 1;
      throw new Error("missing GitHub auth must not reach provider I/O");
    };
    const lifecycle = createWorkerConnectionHealth({
      db,
      crypto,
      store,
      providers: support.definitions,
      catalogForSignal: () => {
        catalogOpenCalls += 1;
        return createCuratedCatalog({
          fetchImpl: operationFetch,
          workspace: {},
          registry,
          handlerOverrides: {
            github: () => {
              sessionHandlerCreations += 1;
              return countTypedCalls(createGitHubHandler(), () => { typedCalls += 1; });
            },
          },
        });
      },
      operationFetch,
      oauthFetch: async () => {
        oauthCalls += 1;
        throw new Error("legacy GitHub missing_auth must not invoke OAuth");
      },
      now: () => CHECKED_AT,
    });

    const transition = await lifecycle.checkConnectionHealth(connectionId, uid, "get_user");

    expect(transition).toMatchObject({
      to: "needs_auth",
      reason: "missing_auth",
      persisted: true,
      lastCheckedAt: CHECKED_AT.toISOString(),
      lastSuccessAt: null,
      connection: {
        authState: "needs_auth",
        configVersion: 1,
        disconnectGeneration: 0,
      },
    });
    expect(transition.connection).not.toHaveProperty("legacyUnknownAuthWithoutConfig");
    expect(JSON.stringify(transition)).not.toContain(canary);
    expect(catalogOpenCalls).toBe(0);
    expect(sessionHandlerCreations).toBe(0);
    expect(typedCalls).toBe(0);
    expect(requests).toBe(0);
    expect(oauthCalls).toBe(0);
    expect(decrypt).not.toHaveBeenCalled();
    await expect(store.get(connectionId, uid)).resolves.toMatchObject({
      authState: "needs_auth",
      healthState: "needs_auth",
      lastCheckedAt: CHECKED_AT.toISOString(),
      lastSuccessAt: null,
      configVersion: 1,
      disconnectGeneration: 0,
    });
  });
});
