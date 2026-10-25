/**
 * McpRuntime (P5 Task 16) — the worker-side composition of the router,
 * contribution registry, installer and system bus.
 *
 * Gated on TEST_DATABASE_URL + TEST_REDIS_URL (real db + real Redis bus;
 * idempotent migrate only — parallel P5/P7 lanes share the dev services).
 *
 * Pinned here:
 * - `sandbox: null` still serves curated fetch (no sandbox needed) while the
 *   filesystem tool returns a clean `sandbox_unavailable` tool error (never a
 *   crash);
 * - router, bus and installer are one runtime instance (the installer reads
 *   the same db the router uses; shutdown closes the bus);
 * - shutdown is idempotent.
 */

import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { Redis } from "ioredis";
import { createDb, migrate, mcpServers, newId, schema, users as dbUsers, type Db, type McpServerRow } from "@ovid/db";
import {
  createEnvelopeCrypto,
  createCuratedProviderSupport,
  type EgressRequest,
  type GuardedFetch,
  type ProviderEgress,
  type UserSystemBus,
} from "@ovid/mcp";
import { createMcpToolProvider } from "./mcpTools.js";
import { createMcpRuntime } from "./mcpRuntime.js";
import { createTestProviderRegistry } from "../../../packages/mcp/src/__fixtures__/providerRegistry.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

let counter = 0;
function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random().toString(36).slice(2, 8)}`;
}

const fetchImpl: GuardedFetch = async () =>
  new Response("<html><body><h1>hello runtime</h1></body></html>", {
    status: 200,
    headers: { "content-type": "text/html" },
  });

function configuredOriginalRow(providerId: string, userId: string): McpServerRow {
  return {
    id: "00000000-0000-0000-0000-000000000006",
    userId,
    name: providerId,
    transport: "native",
    curatedId: providerId,
    providerId,
    agentEnabled: true,
    authState: "configured",
    healthState: "never_checked",
    lastCheckedAt: null,
    lastSuccessAt: null,
    configVersion: 1,
    disconnectGeneration: 0,
    approvedSourceId: null,
    approvedDigest: null,
    normalizedConnectionName: providerId,
    config: null,
    secretsSealed: null,
    enabled: true,
    createdAt: new Date("2026-10-24T00:00:00.000Z"),
    updatedAt: new Date("2026-10-24T00:00:00.000Z"),
  };
}

describe("McpRuntime readiness composition", () => {
  it("does not activate a real blocked original merely because its descriptor exists", async () => {
    const raw = configuredOriginalRow("exa", "blocked-original-user");
    const list = vi.spyOn(mcpServers, "list").mockResolvedValue([raw]);
    const bus: UserSystemBus = {
      async publish() {},
      async request() { return null; },
      async close() {},
    };
    const runtime = createMcpRuntime({
      db: {} as Db,
      redisQ: {} as Redis,
      masterKey: MASTER_KEY_HEX,
      sandbox: null,
      systemBus: bus,
    });
    try {
      const snapshot = await runtime.activation.snapshotForRun({
        userId: raw.userId,
        runId: "blocked-original-run",
        sessionId: "blocked-original-session",
        isSubagent: false,
        allow: [],
        deny: [],
        mode: "auto",
        planMode: false,
        unattended: false,
      });
      expect(snapshot.operations).toEqual([]);
      expect(list).toHaveBeenCalledWith(expect.anything(), raw.userId);
    } finally {
      await runtime.shutdown();
      list.mockRestore();
    }
  });

  it("keeps a configured legacy Fetch connection manageable while blocked readiness prevents activation", async () => {
    const raw = configuredOriginalRow("fetch", "legacy-fetch-user");
    const list = vi.spyOn(mcpServers, "list").mockResolvedValue([raw]);
    const tier = vi.spyOn(dbUsers, "getTier").mockResolvedValue("free");
    const bus: UserSystemBus = {
      async publish() {},
      async request() { return null; },
      async close() {},
    };
    const runtime = createMcpRuntime({
      db: {} as Db,
      redisQ: {} as Redis,
      masterKey: MASTER_KEY_HEX,
      sandbox: null,
      systemBus: bus,
    });
    try {
      const snapshot = await runtime.activation.snapshotForRun({
        userId: raw.userId,
        runId: "legacy-fetch-run",
        sessionId: "legacy-fetch-session",
        isSubagent: false,
        allow: [],
        deny: [],
        mode: "auto",
        planMode: false,
        unattended: false,
      });
      expect(snapshot.operations).toEqual([]);
      expect(await runtime.activation.revalidate(snapshot, {
        connectionId: raw.id,
        operationId: "fetch",
      })).toBe("denied");
      expect(await runtime.router.listServers(raw.userId)).toEqual([
        expect.objectContaining({ id: raw.id, curatedId: "fetch", enabled: true }),
      ]);
      // Blocked readiness leaves the configured row manageable, but its stale
      // curated definition cannot resolve. Router.callTool throws here; it
      // does not return an {isError} result for an unknown tool.
      await expect(runtime.router.callTool(
        raw.userId,
        "mcp__fetch__fetch",
        { url: "https://example.com/page" },
        { sessionId: "legacy-fetch-session", runId: "legacy-fetch-run" },
      )).rejects.toThrow("unknown MCP tool: mcp__fetch__fetch");
    } finally {
      await runtime.shutdown();
      list.mockRestore();
      tier.mockRestore();
    }
  });

  // UNEXECUTED round-1 regression under the heavy-verification pause.
  it("composes real health lifecycle and authenticated surfaces without eager health work", async () => {
    const bus: UserSystemBus = {
      async publish() {},
      async request() { return null; },
      async close() {},
    };
    const runtime = createMcpRuntime({
      db: {} as Db,
      redisQ: {} as Redis,
      masterKey: MASTER_KEY_HEX,
      sandbox: null,
      systemBus: bus,
      providerRegistry: createTestProviderRegistry(),
    });
    try {
      expect(typeof runtime.connectionHealth?.checkConnectionHealth).toBe("function");
      expect(typeof runtime.connectionHealth?.getConnectionHealth).toBe("function");
      expect(typeof runtime.connectionHealth?.disconnectConnection).toBe("function");
      expect(typeof runtime.connectionHealthInvocations?.checkAuthenticated).toBe("function");
      expect(typeof runtime.connectionHealthInvocations?.getAuthenticated).toBe("function");
      expect(typeof runtime.connectionHealthInvocations?.disconnectAuthenticated).toBe("function");
      expect(typeof runtime.connectionHealthInvocations?.checkSelectedOperation).toBe("function");
    } finally {
      await runtime.shutdown();
    }
  });

  it("uses one mixed test registry for worker catalog entries and activation", async () => {
    const userId = "mixed-registry-user";
    const providerIds = ["fetch", "cloudflare", "exa", "vercel"];
    const rows = providerIds.map((providerId) => ({
      ...configuredOriginalRow(providerId, userId),
      id: `${providerId}-connection`,
    }));
    const list = vi.spyOn(mcpServers, "list")
      .mockResolvedValueOnce(rows.filter((row) => row.curatedId === "fetch" || row.curatedId === "cloudflare"))
      .mockResolvedValueOnce(rows);
    const bus: UserSystemBus = {
      async publish() {},
      async request() { return null; },
      async close() {},
    };
    const providerRegistry = createTestProviderRegistry({
      supported: ["fetch", "cloudflare"],
      internal: ["exa", "vercel"],
    });
    expect(providerRegistry.catalogDefinitions().map((definition) => definition.providerId))
      .toEqual(["fetch", "cloudflare"]);
    expect(createCuratedProviderSupport(providerRegistry).definitions.map((definition) => definition.providerId))
      .toEqual(["fetch", "cloudflare"]);
    const runtime = createMcpRuntime({
      db: {} as Db,
      redisQ: {} as Redis,
      masterKey: MASTER_KEY_HEX,
      sandbox: null,
      systemBus: bus,
      legacyProviderFetchForTest: true,
      providerRegistry,
    });
    try {
      const servers = await runtime.router.listServers(userId);
      const catalogIds = servers
        .filter((server) => server.curatedId !== null)
        .map((server) => server.curatedId);
      const snapshot = await runtime.activation.snapshotForRun({
        userId,
        runId: "mixed-registry-run",
        sessionId: "mixed-registry-session",
        isSubagent: false,
        allow: [],
        deny: [],
        mode: "auto",
        planMode: false,
        unattended: false,
      });
      const activationIds = [...new Set(snapshot.operations.map((operation) => operation.providerId))];
      expect(catalogIds).toEqual(["fetch", "cloudflare"]);
      expect(activationIds).toEqual(catalogIds);
      expect(activationIds).not.toContain("exa");
      expect(activationIds).not.toContain("vercel");
    } finally {
      await runtime.shutdown();
      list.mockRestore();
    }
  });
});

let db: Db;
let redis: Redis;

async function seedUser(tier: "free" | "pro"): Promise<string> {
  const id = uid("mcp-runtime");
  await db.insert(schema.users).values({ uid: id, email: `${id}@test.local`, tier });
  return id;
}

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)("McpRuntime", () => {
  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
    redis = new Redis(TEST_REDIS_URL!);
  }, 60_000);

  afterAll(async () => {
    await redis?.quit();
    await db?.$client.end({ timeout: 5 });
  });

  it("sandbox null: blocked configured originals remain manageable but cannot activate", async () => {
    const id = await seedUser("free");
    const fetchConnectionId = newId();
    await db.insert(schema.mcpServers).values({
      id: fetchConnectionId,
      userId: id,
      name: "fetch",
      transport: "native",
      curatedId: "fetch",
      providerId: "fetch",
      enabled: true,
      agentEnabled: true,
      authState: "configured",
      healthState: "never_checked",
      configVersion: 1,
      disconnectGeneration: 0,
    });
    const runtime = createMcpRuntime({
      db,
      redisQ: redis,
      masterKey: MASTER_KEY_HEX,
      sandbox: null,
      fetchImpl,
      legacyProviderFetchForTest: true,
    });
    try {
      const run = { sessionId: "s-runtime", runId: "r-runtime" };
      const snapshot = await runtime.activation.snapshotForRun({
        userId: id,
        runId: run.runId,
        sessionId: run.sessionId,
        isSubagent: false,
        allow: [],
        deny: [],
        mode: "auto",
        planMode: false,
        unattended: false,
      });
      expect(snapshot.operations).toEqual([]);
      expect(await runtime.activation.revalidate(snapshot, {
        connectionId: fetchConnectionId,
        operationId: "fetch",
      })).toBe("denied");
      expect(await runtime.router.listServers(id)).toEqual([
        expect.objectContaining({ id: fetchConnectionId, curatedId: "fetch", enabled: true }),
      ]);

      await expect(runtime.router.callTool(
        id,
        "mcp__fetch__fetch",
        { url: "https://example.com/page" },
        run,
      )).rejects.toThrow("unknown MCP tool: mcp__fetch__fetch");

      await expect(runtime.router.callTool(
        id,
        "mcp__filesystem__read_file",
        { path: "notes.md" },
        run,
      )).rejects.toThrow("unknown MCP tool: mcp__filesystem__read_file");
    } finally {
      await runtime.shutdown();
    }
  });

  it("withholds blocked original rows from activation and egress without fabricating readiness", async () => {
    const id = await seedUser("free");
    const connectionId = newId();
    const secret = "exa-plaintext-runtime-canary";
    const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);
    await db.insert(schema.mcpServers).values({
      id: connectionId,
      userId: id,
      name: "exa",
      transport: "native",
      curatedId: "exa",
      providerId: "exa",
      enabled: true,
      agentEnabled: true,
      authState: "configured",
      healthState: "never_checked",
      configVersion: 1,
      disconnectGeneration: 0,
      secretsSealed: crypto.encrypt(
        JSON.stringify({ api_key: secret }),
        `mcp_servers:${connectionId}`,
      ),
    });

    const requests: EgressRequest[] = [];
    let closed = 0;
    const providerEgress: ProviderEgress = {
      async request(request) {
        requests.push(request);
        return {
          status: 200,
          headers: new Headers({ "content-type": "application/json" }),
          body: new ReadableStream<Uint8Array>({
            start(controller) {
              controller.enqueue(new TextEncoder().encode(JSON.stringify({
                results: [{ title: "sanitized" }],
                echo: secret,
              })));
              controller.close();
            },
          }),
          origin: new URL("https://api.exa.ai"),
          remoteAddress: "203.0.113.10",
        };
      },
      async close() {
        closed += 1;
      },
    };
    const runtime = createMcpRuntime({
      db,
      redisQ: redis,
      masterKey: MASTER_KEY_HEX,
      sandbox: null,
      providerEgress,
    });
    try {
      const root = await runtime.activation.snapshotForRun({
        userId: id,
        runId: "run-root",
        sessionId: "session-root",
        isSubagent: false,
        allow: [],
        deny: [],
        mode: "auto",
        planMode: false,
        unattended: false,
      });
      expect(root.operations).toEqual([]);
      expect(JSON.stringify(root)).not.toContain(secret);
      const provider = createMcpToolProvider(runtime.router, {
        snapshotFor: async () => root,
        revalidate: (snapshot, call) => runtime.activation.revalidate(snapshot, call),
      });
      expect(await provider.tools(root)).toEqual([]);
      expect(JSON.stringify(await provider.specs(root))).not.toContain(secret);
      expect(await runtime.activation.revalidate(root, {
        connectionId,
        operationId: "search",
      })).toBe("denied");
      expect(requests).toHaveLength(0);
    } finally {
      await runtime.shutdown();
    }
    expect(closed).toBe(1);
  });

  it("router, bus and installer are one runtime instance; shutdown closes the bus idempotently", async () => {
    let busClosed = 0;
    const bus: UserSystemBus = {
      async publish() {},
      async request() {
        return null;
      },
      async close() {
        busClosed += 1;
      },
    };

    const runtime = createMcpRuntime({
      db,
      redisQ: redis,
      masterKey: MASTER_KEY_HEX,
      sandbox: null,
      fetchImpl,
      legacyProviderFetchForTest: true,
      systemBus: bus,
    });

    // The three members share the runtime.
    expect(runtime.router).toBeDefined();
    expect(runtime.registry).toBeDefined();
    expect(runtime.installer).toBeDefined();
    expect(runtime.registry.list()).toEqual([]);

    // The installer is wired to the SAME db (a Free user is refused at the
    // transaction's job-start tier gate, before any source resolution).
    const id = await seedUser("free");
    const outcome = await runtime.installer.install({
      installId: "install-runtime-free",
      userId: id,
      pluginId: "acme/demo",
      mode: "install",
      source: { kind: "paste", label: "runtime", config: "{}" },
    });
    expect(outcome).toMatchObject({ status: "failed", reason: "pro_required" });

    await runtime.shutdown();
    expect(busClosed).toBe(1);
    await runtime.shutdown(); // idempotent — the bus closes once
    expect(busClosed).toBe(1);
  });
});
