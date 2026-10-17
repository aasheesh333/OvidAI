import { describe, expect, it } from "vitest";
import { createMemoryHandler, MEMORY_TOOLS } from "./memory.js";
import type { McpCallContext } from "../transports/native.js";
import type { WorkspaceFiles } from "../workspace.js";

// ---------------------------------------------------------------------------
// Native Memory MCP handler — a 1:1 port of the Dart NativeMemoryMcpHandler,
// with the storage re-based: the Dart class held one in-process graph per
// handler instance; the cloud port persists the graph at
// /workspace/.ovid/memory/memory.json through ctx.workspace, PER USER — a
// process-wide singleton handler stays safe because every call carries its
// own uid and workspace.
// ---------------------------------------------------------------------------

const MEMORY_PATH = "/workspace/.ovid/memory/memory.json";

/** Minimal in-memory WorkspaceFiles fake (memory only reads and writes). */
class FakeWorkspace {
  readonly files = new Map<string, Map<string, string>>();

  private store(uid: string): Map<string, string> {
    let s = this.files.get(uid);
    if (!s) {
      s = new Map();
      this.files.set(uid, s);
    }
    return s;
  }

  async read(uid: string, path: string): Promise<{ content: string; bytes: number } | null> {
    const c = this.store(uid).get(path);
    return c === undefined ? null : { content: c, bytes: c.length };
  }

  async write(uid: string, path: string, content: string): Promise<void> {
    this.store(uid).set(path, content);
  }

  async list(): Promise<never[]> {
    throw new Error("not needed by the memory handler");
  }

  async stat(): Promise<null> {
    return null;
  }

  async remove(): Promise<void> {
    throw new Error("not needed by the memory handler");
  }
}

function makeCtx(ws: FakeWorkspace, uid: string): McpCallContext {
  return {
    uid,
    secrets: {},
    // R6: native.ts still types workspace as the permissive placeholder; the
    // real surface is workspace.ts and the worker seam (Task 16) adapts to it.
    workspace: ws as unknown as McpCallContext["workspace"],
    fetchImpl: async () => new Response(""),
  };
}

const entity = (name: string, entityType: string, observations: string[]) => ({
  entities: [{ name, entityType, observations }],
});

describe("createMemoryHandler", () => {
  it("create_entities then read_graph round-trips through the per-uid workspace file", async () => {
    const ws = new FakeWorkspace();
    const handler = createMemoryHandler();

    const created = await handler.callTool(
      "create_entities",
      entity("Alice", "Person", ["likes bobcats"]),
      makeCtx(ws, "u-1"),
    );
    expect(created.isError).toBe(false);
    expect(JSON.parse(created.text)).toEqual([
      { name: "Alice", entityType: "Person", observations: ["likes bobcats"] },
    ]);

    // persisted at the brief's path, per user
    const stored = await ws.read("u-1", MEMORY_PATH);
    expect(stored).not.toBeNull();
    expect(JSON.parse(stored!.content)).toEqual({
      entities: [{ name: "Alice", entityType: "Person", observations: ["likes bobcats"] }],
      relations: [],
    });

    const graph = await handler.callTool("read_graph", {}, makeCtx(ws, "u-1"));
    expect(JSON.parse(graph.text)).toEqual({
      entities: [{ name: "Alice", entityType: "Person", observations: ["likes bobcats"] }],
      relations: [],
    });
  });

  it("two uids get separate graphs from the same handler instance", async () => {
    const ws = new FakeWorkspace();
    const handler = createMemoryHandler(); // the process-wide singleton

    await handler.callTool("create_entities", entity("Alice", "Person", ["a"]), makeCtx(ws, "u-1"));
    await handler.callTool("create_entities", entity("Bob", "Person", ["b"]), makeCtx(ws, "u-2"));

    const g1 = JSON.parse((await handler.callTool("read_graph", {}, makeCtx(ws, "u-1"))).text);
    const g2 = JSON.parse((await handler.callTool("read_graph", {}, makeCtx(ws, "u-2"))).text);
    expect(g1.entities.map((e: { name: string }) => e.name)).toEqual(["Alice"]);
    expect(g2.entities.map((e: { name: string }) => e.name)).toEqual(["Bob"]);

    // persisted to two different files
    expect(ws.files.get("u-1")?.has(MEMORY_PATH)).toBe(true);
    expect(ws.files.get("u-2")?.has(MEMORY_PATH)).toBe(true);
  });

  it("graph survives a fresh handler instance reading the same workspace", async () => {
    const ws = new FakeWorkspace();
    await createMemoryHandler().callTool("create_entities", entity("Alice", "Person", ["a"]), makeCtx(ws, "u-9"));
    const graph = await createMemoryHandler().callTool("read_graph", {}, makeCtx(ws, "u-9"));
    expect(JSON.parse(graph.text).entities).toHaveLength(1);
  });

  it("add_observations merges (dedupes) into existing entities", async () => {
    const ws = new FakeWorkspace();
    const handler = createMemoryHandler();
    const ctx = makeCtx(ws, "u-1");
    await handler.callTool("create_entities", entity("Alice", "Person", ["a", "b"]), ctx);

    const res = await handler.callTool(
      "add_observations",
      { observations: [{ entityName: "Alice", contents: ["b", "c"] }] },
      ctx,
    );
    expect(res.isError).toBe(false);
    expect(JSON.parse(res.text)).toEqual([
      { name: "Alice", entityType: "Person", observations: ["a", "b", "c"] },
    ]);

    const graph = JSON.parse((await handler.callTool("read_graph", {}, ctx)).text);
    expect(graph.entities[0].observations).toEqual(["a", "b", "c"]);
  });

  it("search_nodes substring-matches name and observations", async () => {
    const ws = new FakeWorkspace();
    const handler = createMemoryHandler();
    const ctx = makeCtx(ws, "u-1");
    await handler.callTool(
      "create_entities",
      {
        entities: [
          { name: "Alice", entityType: "Person", observations: ["studies ovid"] },
          { name: "Metamorphoses", entityType: "Book", observations: ["poem"] },
        ],
      },
      ctx,
    );

    const byName = JSON.parse((await handler.callTool("search_nodes", { query: "alice" }, ctx)).text);
    expect(byName.entities.map((e: { name: string }) => e.name)).toEqual(["Alice"]);

    const byObs = JSON.parse((await handler.callTool("search_nodes", { query: "OVID" }, ctx)).text);
    expect(byObs.entities.map((e: { name: string }) => e.name)).toEqual(["Alice"]);

    const none = JSON.parse((await handler.callTool("search_nodes", { query: "zebra" }, ctx)).text);
    expect(none.entities).toEqual([]);
    expect(none.relations).toEqual([]);
  });

  it("create_relations + open_nodes traverse", async () => {
    const ws = new FakeWorkspace();
    const handler = createMemoryHandler();
    const ctx = makeCtx(ws, "u-1");
    await handler.callTool(
      "create_entities",
      {
        entities: [
          { name: "Alice", entityType: "Person", observations: [] },
          { name: "Ovid", entityType: "Person", observations: [] },
        ],
      },
      ctx,
    );

    const added = await handler.callTool(
      "create_relations",
      { relations: [{ from: "Alice", to: "Ovid", relationType: "reads" }] },
      ctx,
    );
    expect(JSON.parse(added.text)).toEqual([{ from: "Alice", to: "Ovid", relationType: "reads" }]);

    // exact duplicates are not re-added
    const dup = await handler.callTool(
      "create_relations",
      { relations: [{ from: "Alice", to: "Ovid", relationType: "reads" }] },
      ctx,
    );
    expect(JSON.parse(dup.text)).toEqual([]);

    const opened = JSON.parse((await handler.callTool("open_nodes", { names: ["Alice"] }, ctx)).text);
    expect(opened.entities).toEqual([{ name: "Alice", entityType: "Person", observations: [] }]);
    expect(opened.relations).toEqual([{ from: "Alice", to: "Ovid", relationType: "reads" }]);

    // relations touching a matched entity surface in search results too
    const search = JSON.parse((await handler.callTool("search_nodes", { query: "ovid" }, ctx)).text);
    expect(search.relations).toEqual([{ from: "Alice", to: "Ovid", relationType: "reads" }]);
  });

  it("custom dir persists to a different workspace path", async () => {
    const ws = new FakeWorkspace();
    const handler = createMemoryHandler({ dir: ".ovid/memory2" });
    await handler.callTool("create_entities", entity("X", "Thing", []), makeCtx(ws, "u-1"));
    expect(ws.files.get("u-1")?.has("/workspace/.ovid/memory2/memory.json")).toBe(true);
    expect(ws.files.get("u-1")?.has(MEMORY_PATH)).toBeFalsy();
  });

  it("corrupt stored graph → starts empty, not an error", async () => {
    const ws = new FakeWorkspace();
    await ws.write("u-1", MEMORY_PATH, "{not json");
    const handler = createMemoryHandler();
    const res = await handler.callTool("read_graph", {}, makeCtx(ws, "u-1"));
    expect(res.isError).toBe(false);
    expect(JSON.parse(res.text)).toEqual({ entities: [], relations: [] });
  });

  it("unknown tool → isError \"Unknown tool … for memory MCP\"", async () => {
    const handler = createMemoryHandler();
    const res = await handler.callTool("delete_graph", {}, makeCtx(new FakeWorkspace(), "u-1"));
    expect(res.isError).toBe(true);
    expect(res.text).toBe('Unknown tool "delete_graph" for memory MCP');
  });

  it("listTools returns MEMORY_TOOLS with verbatim schemas", async () => {
    const handler = createMemoryHandler();
    const tools = await handler.listTools();
    expect(tools.map((t) => t.name)).toEqual([...MEMORY_TOOLS]);
    const search = tools.find((t) => t.name === "search_nodes");
    expect(search?.inputSchema).toEqual({
      type: "object",
      properties: {
        query: { type: "string", description: "Query string." },
      },
      required: ["query"],
    });
  });

  it("initialize reports serverInfo memory", async () => {
    const handler = createMemoryHandler();
    expect(await handler.initialize({})).toEqual({
      protocolVersion: "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "memory", version: "1.0.0" },
    });
  });
});

// compile-time: the memory handler only needs the structural WorkspaceFiles
const _ws: WorkspaceFiles = {
  read: async () => null,
  write: async () => {},
  list: async () => [],
  stat: async () => null,
  remove: async () => {},
};
void _ws;
