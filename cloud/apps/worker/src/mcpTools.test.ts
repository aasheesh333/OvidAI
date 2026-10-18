/**
 * MCP agent tools (P5 Task 16) — the P3 roster seam.
 *
 * Gated on TEST_DATABASE_URL (real db; idempotent migrate only). The router
 * runs over fakes at its outer boundaries (guarded fetch, workspace, spawner,
 * bus) so the canonical `execute(args, ctx) → ToolResult` seam, the tier
 * gates and the catalog/install tools are exercised without network or jail.
 */

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createDb, migrate, mcpServers, plugins, schema, type Db } from "@ovid/db";
import {
  CURATED_IDS,
  PRO_REQUIRED_MESSAGE,
  createCuratedCatalog,
  createEnvelopeCrypto,
  createMcpRouter,
  createFetchHandler,
  type GuardedFetch,
  type McpRouter,
  type SandboxSpawner,
  type SourceResolver,
  type UserSystemBus,
  type WorkspaceFiles,
} from "@ovid/mcp";
import type { EnvelopeCrypto } from "@ovid/mcp";
import {
  createCatalogTools,
  createMcpToolProvider,
  type McpAgentTool,
  type McpToolContext,
  type PluginInstallQueue,
} from "./mcpTools.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

let counter = 0;
function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random().toString(36).slice(2, 8)}`;
}

let db: Db;
let crypto: EnvelopeCrypto;

async function seedUser(tier: "free" | "pro"): Promise<string> {
  const id = uid("mcp-tools");
  await db.insert(schema.users).values({ uid: id, email: `${id}@test.local`, tier });
  return id;
}

function ctx(id: string): McpToolContext {
  return { uid: id, sessionId: `session-${id}`, runId: `run-${id}` };
}

const workspace: WorkspaceFiles = {
  async read() {
    return null;
  },
  async write() {},
  async list() {
    return [];
  },
  async stat() {
    return null;
  },
  async remove() {},
};

const spawner: SandboxSpawner = {
  async spawn() {
    throw new Error("stdio spawn is not exercised by the curated tool tests");
  },
};

const bus: UserSystemBus = {
  async publish() {},
  async request() {
    return null;
  },
  async close() {},
};

const fetchImpl: GuardedFetch = async () =>
  new Response("<html><body><h1>hello tools</h1></body></html>", {
    status: 200,
    headers: { "content-type": "text/html" },
  });

function makeRouter(): McpRouter {
  const catalog = createCuratedCatalog({
    fetchImpl,
    workspace,
    handlerOverrides: { fetch: () => createFetchHandler() },
  });
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

interface AddedJob {
  name: string;
  data: unknown;
  opts?: { priority?: number; jobId?: string };
}

function makeQueue(): { queue: PluginInstallQueue; added: AddedJob[] } {
  const added: AddedJob[] = [];
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

const resolverDirs: string[] = [];

/** Stage a minimal native manifest so `adaptPlugin` derives `publisher/name`. */
async function stageManifest(publisher: string, name: string): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "ovid-mcp-tools-"));
  resolverDirs.push(dir);
  await writeFile(
    join(dir, "plugin.json"),
    JSON.stringify({ name, author: publisher, version: "1.0.0" }),
    "utf8",
  );
  return dir;
}

/**
 * The resolver double for the enqueue path: it stages a manifest whose
 * canonical id is `publisher/name` regardless of the source string, exactly
 * like the real resolver + adaptPlugin pair does for github/npm/zip/paste.
 */
function fakeResolver(publisher: string, name: string): Pick<SourceResolver, "resolve"> {
  return {
    async resolve() {
      const stagingDir = await stageManifest(publisher, name);
      return {
        stagingDir,
        bytes: 0,
        provenance: { kind: "test" },
        async discard() {
          await rm(stagingDir, { recursive: true, force: true });
        },
      };
    },
  };
}

function tool(tools: readonly McpAgentTool[], name: string): McpAgentTool {
  const found = tools.find((t) => t.name === name);
  if (found === undefined) throw new Error(`missing tool ${name}`);
  return found;
}

describe.skipIf(!TEST_DATABASE_URL)("MCP agent tools (canonical roster seam)", () => {
  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
    crypto = createEnvelopeCrypto(MASTER_KEY_HEX);
  }, 60_000);

  afterAll(async () => {
    await Promise.all(resolverDirs.map((d) => rm(d, { recursive: true, force: true })));
    await db?.$client.end({ timeout: 5 });
  });

  it("MEDIUM-1: threads the run's sampler into RunContext (samplerFor and ctx.sampler)", async () => {
    const seen: { sampler?: unknown }[] = [];
    const fakeRouter = {
      async listTools() {
        return [
          { name: "mcp__x__y", description: "y", inputSchema: { type: "object" } },
        ];
      },
      async resolveTool(_uid: string, _name: string, runCtx: { sampler?: unknown }) {
        seen.push(runCtx);
        return { serverId: "s1", name: "mcp__x__y" };
      },
      async callTool() {
        return { text: "ok", isError: false };
      },
    } as unknown as McpRouter;

    const sampler = async () => null;
    // (a) provider closes over the active run.
    const viaProvider = createMcpToolProvider(fakeRouter, { samplerFor: () => sampler });
    const [toolA] = await viaProvider.tools("u");
    await toolA!.execute({}, { uid: "u", sessionId: "s", runId: "r" });
    expect(seen[0]!.sampler).toBe(sampler);

    // (b) P3 passes it on the per-call context.
    const provider = createMcpToolProvider(fakeRouter);
    const [toolB] = await provider.tools("u");
    await toolB!.execute({}, { uid: "u", sessionId: "s", runId: "r", sampler });
    expect(seen[1]!.sampler).toBe(sampler);
  });

  it("tools() returns sorted canonical McpAgentTool registrations; specs() mirrors them", async () => {
    const router = makeRouter();
    try {
      const id = await seedUser("free");
      const provider = createMcpToolProvider(router);

      const tools = await provider.tools(id);
      const names = tools.map((t) => t.name);
      expect(names.length).toBeGreaterThan(20);
      expect(names).toEqual([...names].sort());
      expect(names).toContain("mcp__fetch__fetch");

      for (const t of tools) {
        expect(typeof t.description).toBe("string");
        expect(t.parameters).toMatchObject({ type: "object" });
        expect(typeof t.execute).toBe("function");
      }

      const specs = await provider.specs(id);
      expect(specs.map((s) => s.function.name)).toEqual(names);
      for (const spec of specs) {
        expect(spec.type).toBe("function");
        expect(spec.function.parameters).toMatchObject({ type: "object" });
      }
    } finally {
      await router.shutdown();
    }
  });

  it("execute on mcp__fetch__fetch routes through the router", async () => {
    const router = makeRouter();
    try {
      const id = await seedUser("free");
      const provider = createMcpToolProvider(router);
      const fetchTool = tool(await provider.tools(id), "mcp__fetch__fetch");

      const result = await fetchTool.execute(
        { url: "https://example.com/page" },
        ctx(id),
      );
      expect(result.isError).toBe(false);
      expect(result.content).toContain("hello tools");
    } finally {
      await router.shutdown();
    }
  });

  it("execute with an unknown name returns the pinned Unknown tool result", async () => {
    // A listing the router cannot resolve (e.g. a server removed between
    // roster assembly and dispatch): resolveTool → null must become the
    // pinned Unknown-tool result, never a throw or a wrong dispatch.
    const stubRouter = {
      async listTools() {
        return [
          {
            name: "mcp__nope__missing",
            canonicalId: "mcp:nope/missing",
            serverId: "nope",
            curatedId: null,
          },
        ];
      },
      async resolveTool() {
        return null;
      },
      async callTool() {
        throw new Error("callTool must not run for an unresolved tool");
      },
    } as unknown as McpRouter;

    const provider = createMcpToolProvider(stubRouter);
    const [rogue] = await provider.tools("user-unknown");
    const result = await rogue!.execute({}, ctx("user-unknown"));
    expect(result).toEqual({ content: "Unknown tool: mcp__nope__missing", isError: true });
  });

  it("catalog_add_mcp as free returns PRO_REQUIRED_MESSAGE as a tool result (not a throw)", async () => {
    const router = makeRouter();
    try {
      const id = await seedUser("free");
      const { queue, added } = makeQueue();
      const add = tool(
        createCatalogTools({ router, db, queues: { pluginInstalls: queue }, resolver: fakeResolver("unused", "unused") }),
        "catalog_add_mcp",
      );

      const result = await add.execute(
        {
          config: JSON.stringify({
            mcpServers: { "seam-stdio": { command: "node", args: ["server.js"] } },
          }),
        },
        ctx(id),
      );
      expect(result).toEqual({ content: PRO_REQUIRED_MESSAGE, isError: true });
      expect(added).toHaveLength(0);
      expect(await mcpServers.list(db, id)).toEqual([]);
    } finally {
      await router.shutdown();
    }
  });

  it("catalog_add_mcp as pro persists the server row", async () => {
    const router = makeRouter();
    try {
      const id = await seedUser("pro");
      const { queue } = makeQueue();
      const add = tool(
        createCatalogTools({ router, db, queues: { pluginInstalls: queue }, resolver: fakeResolver("unused", "unused") }),
        "catalog_add_mcp",
      );

      const result = await add.execute(
        {
          config: JSON.stringify({
            mcpServers: { "seam-stdio": { command: "node", args: ["server.js"] } },
          }),
        },
        ctx(id),
      );
      expect(result.isError).not.toBe(true);
      const rows = await mcpServers.list(db, id);
      expect(rows.map((r) => r.name)).toContain("seam-stdio");
      expect(rows[0]?.transport).toBe("stdio");
    } finally {
      await router.shutdown();
    }
  });

  it("catalog_list_mcp all names every curated id; custom scope omits curated", async () => {
    const router = makeRouter();
    try {
      const id = await seedUser("pro");
      const { queue } = makeQueue();
      const list = tool(
        createCatalogTools({ router, db, queues: { pluginInstalls: queue }, resolver: fakeResolver("unused", "unused") }),
        "catalog_list_mcp",
      );

      const all = await list.execute({ scope: "all" }, ctx(id));
      expect(all.isError).not.toBe(true);
      for (const curatedId of CURATED_IDS) {
        expect(all.content).toContain(curatedId);
      }
      const parsedAll = JSON.parse(all.content) as Array<{ curatedId: string | null }>;
      expect(parsedAll.filter((s) => s.curatedId !== null)).toHaveLength(20);

      const custom = await list.execute({ scope: "custom" }, ctx(id));
      expect(custom.isError).not.toBe(true);
      expect(JSON.parse(custom.content)).toEqual([]);
      expect(custom.content).not.toContain("github");
    } finally {
      await router.shutdown();
    }
  });

  it("agent_install_plugin parses owner/repo → github and enqueues with the Pro priority", async () => {
    const router = makeRouter();
    try {
      const id = await seedUser("pro");
      const { queue, added } = makeQueue();
      const install = tool(
        createCatalogTools({ router, db, queues: { pluginInstalls: queue }, resolver: fakeResolver("acme", "demo") }),
        "agent_install_plugin",
      );

      const result = await install.execute({ source: "acme/demo" }, ctx(id));
      expect(result.isError).not.toBe(true);
      expect(added).toHaveLength(1);
      expect(added[0]?.data).toMatchObject({
        userId: id,
        pluginId: "acme/demo",
        mode: "install",
        source: { kind: "github", owner: "acme", repo: "demo" },
      });
      expect(added[0]?.opts?.priority).toBe(1);

      const row = await plugins.getByPluginId(db, id, "acme/demo");
      expect(row?.status).toBe("queued");
    } finally {
      await router.shutdown();
    }
  });

  it("agent_install_plugin paste enqueues the manifest's canonical id, never paste/<label> (I3)", async () => {
    const router = makeRouter();
    try {
      const id = await seedUser("pro");
      const { queue, added } = makeQueue();
      // Previously the enqueue path derived `paste/pasted`; the installer
      // derives `acme/pasted-demo` from the staged manifest and refused the
      // job with plugin_id_mismatch. The job and row must carry the
      // canonical id now.
      const install = tool(
        createCatalogTools({
          router,
          db,
          queues: { pluginInstalls: queue },
          resolver: fakeResolver("acme", "pasted-demo"),
        }),
        "agent_install_plugin",
      );

      const result = await install.execute(
        {
          source: JSON.stringify({
            mcpServers: { demo: { command: "node", args: ["demo.js"] } },
          }),
        },
        ctx(id),
      );
      expect(result.isError).not.toBe(true);
      expect(added).toHaveLength(1);
      expect(added[0]?.data).toMatchObject({
        userId: id,
        pluginId: "acme/pasted-demo",
        mode: "install",
        source: { kind: "paste", label: "pasted" },
      });
      expect((added[0]?.data as { source: { kind: string } }).source.kind).toBe("paste");

      expect(await plugins.getByPluginId(db, id, "acme/pasted-demo")).not.toBeNull();
      expect(await plugins.getByPluginId(db, id, "paste/pasted")).toBeNull();
    } finally {
      await router.shutdown();
    }
  });

  it("agent_install_plugin with an unresolvable source returns isError and enqueues nothing", async () => {
    const router = makeRouter();
    try {
      const id = await seedUser("pro");
      const { queue, added } = makeQueue();
      const install = tool(
        createCatalogTools({
          router,
          db,
          queues: { pluginInstalls: queue },
          resolver: {
            async resolve() {
              throw new Error("source_unreachable");
            },
          },
        }),
        "agent_install_plugin",
      );

      const result = await install.execute({ source: "acme/missing" }, ctx(id));
      expect(result.isError).toBe(true);
      expect(result.content).toContain("invalid_source");
      expect(result.content).toContain("source_unreachable");
      expect(added).toHaveLength(0);
      expect(await plugins.getByPluginId(db, id, "acme/missing")).toBeNull();
    } finally {
      await router.shutdown();
    }
  });

  it("agent_install_plugin as free returns pro_required and enqueues nothing", async () => {
    const router = makeRouter();
    try {
      const id = await seedUser("free");
      const { queue, added } = makeQueue();
      const install = tool(
        createCatalogTools({ router, db, queues: { pluginInstalls: queue }, resolver: fakeResolver("unused", "unused") }),
        "agent_install_plugin",
      );

      const result = await install.execute({ source: "acme/demo" }, ctx(id));
      expect(result).toEqual({ content: PRO_REQUIRED_MESSAGE, isError: true });
      expect(added).toHaveLength(0);
      expect(await plugins.getByPluginId(db, id, "acme/demo")).toBeNull();
    } finally {
      await router.shutdown();
    }
  });

  it("agent_install_mcp summarizes a connected curated server with its tool count", async () => {
    const router = makeRouter();
    try {
      const id = await seedUser("pro");
      await router.addServer(id, { curatedId: "github" });
      await router.updateServer(id, "curated:github", {
        secrets: { GITHUB_TOKEN: "ghp_test" },
      });

      const listings = await router.listTools(id);
      const expected = listings.filter((l) => l.curatedId === "github").length;
      expect(expected).toBeGreaterThan(0);

      const { queue } = makeQueue();
      const installMcp = tool(
        createCatalogTools({ router, db, queues: { pluginInstalls: queue }, resolver: fakeResolver("unused", "unused") }),
        "agent_install_mcp",
      );
      const result = await installMcp.execute({ server: "github" }, ctx(id));

      expect(result.isError).not.toBe(true);
      expect(result.content).toContain(String(expected));
    } finally {
      await router.shutdown();
    }
  });
});
