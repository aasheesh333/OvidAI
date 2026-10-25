// CURRENT REVISION UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25).
// This suite is authored for the fix-round static contract only. Do not cite
// historical discovery results as evidence for this worker composition.

import { describe, expect, it, vi } from "vitest";
import { Redis } from "ioredis";
import {
  mcpServers,
  users as dbUsers,
  type Db,
  type McpServerRow,
} from "@ovid/db";
import {
  createEnvelopeCrypto,
  type EnvelopeCrypto,
  type EgressRequest,
  type ProviderEgress,
  type ProviderRegistry,
  type RunMcpSnapshot,
  type SourceResolver,
  type UserSystemBus,
} from "@ovid/mcp";
import { createTestProviderRegistry } from "../../../packages/mcp/src/__fixtures__/providerRegistry.js";
import { createMcpRuntime } from "./mcpRuntime.js";
import {
  createCatalogTools,
  type McpAgentTool,
  type McpToolContext,
} from "./mcpTools.js";

const MASTER_KEY = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";
const USER_ID = "connector-lazy-discovery-user";
const CLOUDFLARE_CONNECTION = "cloudflare-connection";
const VERCEL_CONNECTION = "vercel-connection";
const CLOUDFLARE_SECRET = "cloudflare-selected-only-secret";
const VERCEL_SECRET = "vercel-unselected-secret";

function context(runId: string): McpToolContext {
  return {
    uid: USER_ID,
    sessionId: `session-${runId}`,
    runId,
    mode: "auto",
    planMode: false,
    unattended: false,
    isSubagent: false,
    depth: 0,
    callKey: `${runId}:connector-call`,
    signal: new AbortController().signal,
  };
}

function requiredTool(tools: readonly McpAgentTool[], name: string): McpAgentTool {
  const tool = tools.find((candidate) => candidate.name === name);
  if (tool === undefined) throw new Error(`Missing composed tool ${name}`);
  return tool;
}

describe("McpRuntime lazy connector discovery roster", () => {
  it("keeps initial specs inert, loads selected schemas per run, and connects only selected dispatch", async () => {
    const crypto = createEnvelopeCrypto(MASTER_KEY);
    const row = (
      providerId: "cloudflare" | "vercel",
      connectionId: string,
      secrets: Record<string, string>,
    ): McpServerRow => ({
      id: connectionId,
      userId: USER_ID,
      name: providerId,
      transport: "native",
      curatedId: providerId,
      providerId,
      agentEnabled: true,
      authState: "configured",
      healthState: "never_checked",
      lastCheckedAt: null,
      lastSuccessAt: null,
      configVersion: 7,
      disconnectGeneration: 3,
      approvedSourceId: null,
      approvedDigest: null,
      normalizedConnectionName: providerId,
      config: null,
      secretsSealed: crypto.encrypt(JSON.stringify(secrets), `mcp_servers:${connectionId}`),
      enabled: true,
      createdAt: new Date("2026-10-24T00:00:00.000Z"),
      updatedAt: new Date("2026-10-24T00:00:00.000Z"),
    });
    const rows = [
      row("cloudflare", CLOUDFLARE_CONNECTION, { api_token: CLOUDFLARE_SECRET }),
      row("vercel", VERCEL_CONNECTION, { access_token: VERCEL_SECRET }),
    ];
    const list = vi.spyOn(mcpServers, "list").mockResolvedValue(rows);
    const tier = vi.spyOn(dbUsers, "getTier").mockResolvedValue("pro");

    const schemaReads: string[] = [];
    const baseRegistry = createTestProviderRegistry({ supported: ["cloudflare", "vercel"] });
    const providerRegistry: ProviderRegistry = {
      registerProvider: (definition, readiness) => baseRegistry.registerProvider(definition, readiness),
      get: (providerId) => baseRegistry.get(providerId),
      rows: () => baseRegistry.rows(),
      definitions: () => baseRegistry.definitions(),
      assertCatalogCallable: (providerId) => baseRegistry.assertCatalogCallable(providerId),
      catalogDefinitions: () => baseRegistry.catalogDefinitions().map((definition) => ({
        ...definition,
        operations: definition.operations.map((operation) => {
          const inputSchema = operation.inputSchema;
          const evidenced = { ...operation };
          Object.defineProperty(evidenced, "inputSchema", {
            enumerable: true,
            get: () => {
              schemaReads.push(`${definition.providerId}/${operation.name}`);
              return inputSchema;
            },
          });
          return evidenced;
        }),
      })),
    };

    const decryptor = vi.fn<EnvelopeCrypto["decrypt"]>((envelope, recordId) =>
      crypto.decrypt(envelope, recordId)
    );
    const instrumentedCrypto: EnvelopeCrypto = {
      encrypt: (plaintext, recordId) => crypto.encrypt(plaintext, recordId),
      decrypt: decryptor,
    };
    const resolve = vi.fn<SourceResolver["resolve"]>(async () => {
      throw new Error("source resolution must remain unused");
    });
    const sourceResolver: SourceResolver = { resolve };
    const transportCalls: EgressRequest[] = [];
    const providerEgress: ProviderEgress = {
      async request(request) {
        transportCalls.push(request);
        const cloudflare = request.url.hostname === "api.cloudflare.com";
        const payload = cloudflare
          ? {
              success: true,
              result: [{ id: "zone_example", name: "example.com", status: "active" }],
              result_info: { page: 1, per_page: 5, count: 1, total_count: 1, total_pages: 1 },
              errors: [],
              messages: [],
            }
          : { projects: [], pagination: { count: 0, next: null } };
        return {
          status: 200,
          headers: new Headers({ "content-type": "application/json" }),
          body: new Response(JSON.stringify(payload)).body as ReadableStream<Uint8Array>,
          origin: new URL(request.url.origin),
          remoteAddress: "203.0.113.10",
        };
      },
      async close() {},
    };
    const checkConnectionHealth = vi.fn(async () => {
      throw new Error("health checks must remain explicit, never eager");
    });
    const revalidateConnection = vi.fn(async () => "current" as const);
    const systemBus: UserSystemBus = {
      async publish() {},
      async request() { return null; },
      async close() {},
    };

    const runtime = createMcpRuntime({
      db: {} as Db,
      redisQ: {} as Redis,
      masterKey: MASTER_KEY,
      sandbox: null,
      providerRegistry,
      providerEgress,
      crypto: instrumentedCrypto,
      sourceResolver,
      connectionHealth: { checkConnectionHealth },
      revalidateConnection,
      systemBus,
    });
    // Activation's constructor validates each supported schema once. Preserve
    // that real construction evidence; later assertions detect incremental reads.
    const schemaReadsAfterRuntimeValidation = schemaReads.length;
    expect(schemaReadsAfterRuntimeValidation).toBe(2);
    const snapshots = new Map<string, RunMcpSnapshot>();
    const snapshotForRun = async (runId: string): Promise<RunMcpSnapshot> => {
      const snapshot = await runtime.activation.snapshotForRun({
        userId: USER_ID,
        runId,
        sessionId: `session-${runId}`,
        isSubagent: false,
        allow: [],
        deny: [],
        mode: "auto",
        planMode: false,
        unattended: false,
      });
      snapshots.set(runId, snapshot);
      return snapshot;
    };

    try {
      const first = await snapshotForRun("run-first");
      expect(first.operations.map((operation) => operation.operationId).sort()).toEqual([
        "list_projects",
        "list_zones",
      ]);
      const provider = runtime.createToolProvider({
        snapshotFor: async (ctx) => snapshots.get(ctx.runId) ?? null,
        revalidate: (snapshot, call) => runtime.activation.revalidate(snapshot, call),
      });
      const tools = [
        ...await provider.tools(first),
        ...createCatalogTools({ router: runtime.router }),
      ];
      const specs = await provider.specs(first);

      expect(tools.map((tool) => tool.name)).toEqual([
        "integration_discover",
        "integration_schema",
        "integration_call",
        "catalog_list_mcp",
      ]);
      expect(specs.map((spec) => spec.function.name)).toEqual([
        "integration_discover",
        "integration_schema",
        "integration_call",
      ]);
      expect(JSON.stringify(specs)).not.toContain("list_zones");
      expect(JSON.stringify(specs)).not.toContain("list_projects");
      expect(JSON.stringify(specs)).not.toContain("per_page");
      for (const forbidden of [
        "catalog_add_mcp",
        "agent_install_mcp",
        "agent_install_plugin",
        "integration_activate",
        "integration_disconnect",
        "integration_grant",
      ]) {
        expect(tools.some((tool) => tool.name === forbidden)).toBe(false);
      }

      // Evidence is intentionally never cleared: these counts include runtime
      // creation, activation, initial specs, and catalog tool construction.
      expect(schemaReads).toHaveLength(schemaReadsAfterRuntimeValidation);
      expect(resolve).not.toHaveBeenCalled();
      expect(decryptor).not.toHaveBeenCalled();
      expect(transportCalls).toEqual([]);
      expect(checkConnectionHealth).not.toHaveBeenCalled();

      const discover = requiredTool(tools, "integration_discover");
      const schema = requiredTool(tools, "integration_schema");
      const call = requiredTool(tools, "integration_call");
      const discovered = await discover.execute({}, context("run-first"));
      expect(discovered.isError).not.toBe(true);
      const discoveryBody = JSON.parse(discovered.content) as {
        results: Array<{ providerId: string; operationId: string; inputSchema?: unknown }>;
      };
      expect(discoveryBody.results.map((entry) => [entry.providerId, entry.operationId])).toEqual([
        ["cloudflare", "list_zones"],
        ["vercel", "list_projects"],
      ]);
      expect(discoveryBody.results.every((entry) => entry.inputSchema === undefined)).toBe(true);
      expect(schemaReads).toHaveLength(schemaReadsAfterRuntimeValidation);
      expect(resolve).not.toHaveBeenCalled();
      expect(decryptor).not.toHaveBeenCalled();
      expect(transportCalls).toEqual([]);
      expect(checkConnectionHealth).not.toHaveBeenCalled();

      const loaded = await schema.execute({
        connectionId: CLOUDFLARE_CONNECTION,
        operationIds: ["list_zones"],
      }, context("run-first"));
      expect(loaded.isError).not.toBe(true);
      expect(JSON.parse(loaded.content)).toMatchObject({
        code: "ok",
        loaded: [{ providerId: "cloudflare", operationId: "list_zones" }],
      });
      expect(schemaReads).toHaveLength(schemaReadsAfterRuntimeValidation + 1);
      expect(schemaReads.at(-1)).toBe("cloudflare/list_zones");
      expect(resolve).not.toHaveBeenCalled();
      expect(decryptor).not.toHaveBeenCalled();
      expect(transportCalls).toEqual([]);
      expect(checkConnectionHealth).not.toHaveBeenCalled();

      const crossConnection = await schema.execute({
        connectionId: VERCEL_CONNECTION,
        operationIds: ["list_zones"],
      }, context("run-first"));
      expect(JSON.parse(crossConnection.content)).toEqual({ code: "denied", loaded: [] });
      const deniedCall = await call.execute({
        connectionId: VERCEL_CONNECTION,
        operationId: "list_zones",
        args: {},
      }, context("run-first"));
      expect(deniedCall.isError).toBe(true);
      expect(revalidateConnection).not.toHaveBeenCalled();
      expect(resolve).not.toHaveBeenCalled();
      expect(decryptor).not.toHaveBeenCalled();
      expect(transportCalls).toEqual([]);
      expect(checkConnectionHealth).not.toHaveBeenCalled();

      const called = await call.execute({
        connectionId: CLOUDFLARE_CONNECTION,
        operationId: "list_zones",
        args: { page: 1, per_page: 5 },
      }, context("run-first"));
      expect(called.isError).not.toBe(true);
      expect(revalidateConnection).toHaveBeenCalledTimes(1);
      expect(revalidateConnection).toHaveBeenCalledWith({
        connectionId: CLOUDFLARE_CONNECTION,
        userId: USER_ID,
        configVersion: 7,
        disconnectGeneration: 3,
      });
      expect(decryptor.mock.calls.map((entry) => entry[1])).toEqual([
        `mcp_servers:${CLOUDFLARE_CONNECTION}`,
      ]);
      expect(transportCalls.map((entry) => entry.url.hostname)).toEqual(["api.cloudflare.com"]);
      expect(transportCalls[0]?.secretValues).not.toContain(VERCEL_SECRET);
      expect(resolve).not.toHaveBeenCalled();
      expect(checkConnectionHealth).not.toHaveBeenCalled();

      const schemaReadsAfterFirstRun = schemaReads.length;
      const decryptsAfterFirstRun = decryptor.mock.calls.length;
      const transportsAfterFirstRun = transportCalls.length;
      await snapshotForRun("run-second");
      const reloaded = await schema.execute({
        connectionId: CLOUDFLARE_CONNECTION,
        operationIds: ["list_zones"],
      }, context("run-second"));
      expect(JSON.parse(reloaded.content)).toMatchObject({ code: "ok" });
      // A new run snapshot must not reuse the first run's schema/usage cache.
      // The first run's evidence remains intact rather than being mockCleared.
      expect(schemaReads).toHaveLength(schemaReadsAfterFirstRun + 1);
      expect(schemaReads.at(-1)).toBe("cloudflare/list_zones");
      expect(decryptor).toHaveBeenCalledTimes(decryptsAfterFirstRun);
      expect(transportCalls).toHaveLength(transportsAfterFirstRun);
      expect(resolve).not.toHaveBeenCalled();
      expect(checkConnectionHealth).not.toHaveBeenCalled();
    } finally {
      await runtime.shutdown();
      list.mockRestore();
      tier.mockRestore();
    }
  });
});
