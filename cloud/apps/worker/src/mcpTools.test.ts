import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import { createDb, migrate, schema, type Db } from "@ovid/db";
import {
  CURATED_IDS,
  createCuratedCatalog,
  createEnvelopeCrypto,
  createMcpRouter,
  type ActivatedOperation,
  type GuardedFetch,
  type McpRouter,
  type ProviderOperation,
  type RunMcpSnapshot,
  type SandboxSpawner,
  type SourceResolver,
  type UserSystemBus,
  type WorkspaceFiles,
} from "@ovid/mcp";
import type { EnvelopeCrypto } from "@ovid/mcp";
import {
  CATALOG_AGENT_TOOLS,
  createCatalogTools,
  createMcpToolProvider,
  type McpToolContext,
  type PluginInstallQueue,
} from "./mcpTools.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";
const SECRET_CANARY = "mcp-tools-plaintext-canary";

let db: Db;
let crypto: EnvelopeCrypto;
let counter = 0;

function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random().toString(36).slice(2, 8)}`;
}

async function seedUser(tier: "free" | "pro"): Promise<string> {
  const id = uid("mcp-tools");
  await db.insert(schema.users).values({ uid: id, email: `${id}@test.local`, tier });
  return id;
}

function definition(patch: Partial<ProviderOperation> = {}): ProviderOperation {
  return {
    name: "search",
    description: "Search activated data",
    effect: "read",
    approval: "mode",
    requiredScopes: [],
    inputSchema: {
      type: "object",
      properties: { query: { type: "string", minLength: 1, maxLength: 128 } },
      required: ["query"],
      additionalProperties: false,
      maxProperties: 1,
    },
    outputPolicy: { kind: "redacted_json", maxBytes: 4096 },
    request: { originKey: "acme", method: "GET", pathTemplate: "/search" },
    limits: { timeoutMs: 1000, responseBytes: 4096, frameBytes: 4096, pageBytes: 4096 },
    ...patch,
  };
}

function activated(patch: Partial<ActivatedOperation> = {}): ActivatedOperation {
  return {
    connectionId: "connection-1",
    providerId: "acme",
    operationId: "search",
    modelName: "mcp__acme__search",
    definition: definition(),
    configVersion: 4,
    disconnectGeneration: 2,
    ...patch,
  };
}

function snapshot(operations: readonly ActivatedOperation[] = [activated()]): RunMcpSnapshot {
  return { generation: "snapshot-generation", operations };
}

function ctx(id: string, patch: Partial<McpToolContext> = {}): McpToolContext {
  return {
    uid: id,
    sessionId: `session-${id}`,
    runId: `run-${id}`,
    mode: "auto",
    planMode: false,
    unattended: false,
    isSubagent: false,
    depth: 0,
    callKey: `run-${id}:call-1`,
    signal: new AbortController().signal,
    ...patch,
  };
}

const workspace: WorkspaceFiles = {
  async read() { return null; },
  async write() {},
  async list() { return []; },
  async stat() { return null; },
  async remove() {},
};
const spawner: SandboxSpawner = {
  async spawn() { throw new Error("stdio spawn is not exercised"); },
};
const bus: UserSystemBus = {
  async publish() {},
  async request() { return null; },
  async close() {},
};
const fetchImpl: GuardedFetch = async () =>
  new Response("<html><body><h1>hello tools</h1></body></html>", {
    status: 200,
    headers: { "content-type": "text/html" },
  });

function makeRouter(): McpRouter {
  const catalog = createCuratedCatalog({ fetchImpl, workspace });
  return createMcpRouter({
    db,
    crypto,
    catalog,
    systemBus: bus,
    spawner,
    workspace,
    fetchImpl,
    oauth: {
      getAccessToken: async () => null,
      start: async () => ({ authorizeUrl: "" }),
    },
  });
}

function makeQueue(): { queue: PluginInstallQueue; added: unknown[] } {
  const added: unknown[] = [];
  return {
    added,
    queue: {
      async add(name, data, opts) {
        added.push({ name, data, opts });
        return { id: opts?.jobId ?? "job" };
      },
    },
  };
}

const resolver = {
  async resolve() {
    throw new Error("model-selected source resolution must not run");
  },
} as unknown as Pick<SourceResolver, "resolve">;

describe("snapshot-only MCP tool adapters", () => {
  it("derives canonical tools/specs from the exact snapshot and threads policy, approvals and sampler", async () => {
    const calls: Array<{ name: string; args: Record<string, unknown>; runCtx: Record<string, unknown> }> = [];
    const router = {
      async callTool(_uid: string, name: string, args: Record<string, unknown>, runCtx: Record<string, unknown>) {
        calls.push({ name, args, runCtx });
        return { text: "sanitized provider result", isError: false };
      },
    } as unknown as McpRouter;
    const current = snapshot([
      activated({ modelName: "mcp__acme__z_search", operationId: "z_search" }),
      activated({ modelName: "mcp__acme__a_search", operationId: "a_search" }),
    ]);
    const revalidate = vi.fn(async () => "current" as const);
    const approveProvider = vi.fn(async () => ({ decision: "deny" as const }));
    const sampler = async () => null;
    const provider = createMcpToolProvider(router, {
      snapshotFor: async () => current,
      revalidate,
      samplerFor: () => sampler,
    });

    const tools = await provider.tools(current);
    expect(tools.map((tool) => tool.name)).toEqual(["mcp__acme__a_search", "mcp__acme__z_search"]);
    const specs = await provider.specs(current);
    expect(specs.map((spec) => spec.function.name)).toEqual(tools.map((tool) => tool.name));
    expect(JSON.stringify({ tools, specs })).not.toContain(SECRET_CANARY);

    const result = await tools[0]!.execute({ query: "typed" }, ctx("user-1", {
      mode: "drive",
      planMode: false,
      unattended: false,
      isSubagent: true,
      depth: 1,
      approveProvider,
    }));
    expect(result).toEqual({ content: "sanitized provider result", isError: false });
    expect(revalidate).toHaveBeenCalledWith(current, {
      connectionId: "connection-1",
      operationId: "a_search",
    });
    expect(calls).toHaveLength(1);
    expect(calls[0]!.name).toBe("mcp__acme__a_search");
    expect(calls[0]!.runCtx).toMatchObject({
      sessionId: "session-user-1",
      runId: "run-user-1",
      userId: "user-1",
      connectionId: "connection-1",
      providerId: "acme",
      mode: "drive",
      planMode: false,
      unattended: false,
      isSubagent: true,
      depth: 1,
      callKey: "run-user-1:call-1",
      approveProvider,
      sampler,
    });
  });

  it("denies stale and unrostered direct calls before router execution", async () => {
    const parent = snapshot();
    const callTool = vi.fn(async () => ({ text: "must not execute", isError: false }));
    const router = { callTool } as unknown as McpRouter;
    let current = parent;
    const revalidate = vi.fn(async () => "stale" as const);
    const provider = createMcpToolProvider(router, {
      snapshotFor: async () => current,
      revalidate,
    });
    const [tool] = await provider.tools(parent);

    expect((await tool!.execute({ query: "stale" }, ctx("user-1"))).isError).toBe(true);
    expect(callTool).not.toHaveBeenCalled();

    current = snapshot([]);
    const direct = await tool!.execute({ query: "not-in-child" }, ctx("user-1", {
      runId: "child-run",
      isSubagent: true,
      depth: 1,
    }));
    expect(direct.isError).toBe(true);
    expect(direct.content).toContain("not available");
    expect(callTool).not.toHaveBeenCalled();
    expect(revalidate).toHaveBeenCalledTimes(1);
  });
});

describe.skipIf(!TEST_DATABASE_URL)("read-only catalog discovery", () => {
  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
    crypto = createEnvelopeCrypto(MASTER_KEY_HEX);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  it("keeps discovery read-only and removes every model mutation/install tool", async () => {
    expect(CATALOG_AGENT_TOOLS.map((tool) => tool.name)).toEqual(["catalog_list_mcp"]);
    const id = await seedUser("pro");
    const router = makeRouter();
    const { queue, added } = makeQueue();
    try {
      const tools = createCatalogTools({ router, db, queues: { pluginInstalls: queue }, resolver });
      expect(tools.map((tool) => tool.name)).toEqual(["catalog_list_mcp"]);
      expect(tools.some((tool) => [
        "catalog_add_mcp",
        "agent_install_mcp",
        "agent_install_plugin",
      ].includes(tool.name))).toBe(false);

      const all = await tools[0]!.execute({ scope: "all" }, ctx(id));
      expect(all.isError).not.toBe(true);
      for (const curatedId of CURATED_IDS) expect(all.content).toContain(curatedId);
      const custom = await tools[0]!.execute({ scope: "custom" }, ctx(id));
      expect(JSON.parse(custom.content)).toEqual([]);
      expect(added).toEqual([]);
    } finally {
      await router.shutdown();
    }
  });
});
