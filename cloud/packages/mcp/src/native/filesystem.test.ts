import { describe, expect, it } from "vitest";
import { createFilesystemHandler, FILESYSTEM_TOOLS } from "./filesystem.js";
import { resolveWorkspacePath, WORKSPACE_ROOT, type WorkspaceEntry, type WorkspaceFiles } from "../workspace.js";
import type { McpCallContext } from "../transports/native.js";

// ---------------------------------------------------------------------------
// Native Filesystem MCP handler — a 1:1 port of the Dart
// NativeFilesystemMcpHandler, re-based from local disk onto the P2 workspace
// seam: every user path goes through resolveWorkspacePath (jail) and then
// ctx.workspace (per-user, jail-internal /workspace → /workspaces/users/{uid}).
// ---------------------------------------------------------------------------

const MTIME = "2026-10-16T12:00:00.000Z";

/** In-memory WorkspaceFiles fake keyed by uid and jail-absolute path. */
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

  async stat(uid: string, path: string): Promise<{ type: "file" | "dir"; size: number; mtime: string } | null> {
    const store = this.store(uid);
    const file = store.get(path);
    if (file !== undefined) return { type: "file", size: file.length, mtime: MTIME };
    const prefix = path.endsWith("/") ? path : `${path}/`;
    for (const k of store.keys()) if (k.startsWith(prefix)) return { type: "dir", size: 0, mtime: MTIME };
    return null;
  }

  async list(uid: string, dir: string): Promise<WorkspaceEntry[]> {
    const prefix = dir.endsWith("/") ? dir : `${dir}/`;
    const names = new Map<string, "file" | "dir">();
    for (const k of this.store(uid).keys()) {
      if (!k.startsWith(prefix)) continue;
      const rest = k.slice(prefix.length);
      if (rest === "") continue;
      const first = rest.split("/")[0];
      if (!names.has(first)) names.set(first, rest.includes("/") ? "dir" : "file");
    }
    const entries: WorkspaceEntry[] = [];
    for (const [name, type] of names) {
      const size = type === "file" ? (this.store(uid).get(`${prefix}${name}`)?.length ?? 0) : 0;
      entries.push({ name, type, size, mtime: MTIME });
    }
    return entries;
  }

  async remove(uid: string, path: string): Promise<void> {
    const store = this.store(uid);
    store.delete(path);
    const prefix = path.endsWith("/") ? path : `${path}/`;
    for (const k of [...store.keys()]) if (k.startsWith(prefix)) store.delete(k);
  }
}

function makeCtx(ws: FakeWorkspace, uid = "u-1"): McpCallContext {
  return {
    uid,
    secrets: {},
    // R6: native.ts still types workspace as the permissive placeholder; the
    // real surface is workspace.ts and the worker seam (Task 16) adapts to it.
    workspace: ws as unknown as McpCallContext["workspace"],
    fetchImpl: async () => new Response(""),
  };
}

describe("resolveWorkspacePath", () => {
  it("resolves relative paths under the base", () => {
    expect(resolveWorkspacePath(WORKSPACE_ROOT, "notes/a.txt")).toBe("/workspace/notes/a.txt");
    expect(resolveWorkspacePath(WORKSPACE_ROOT, "./a/../b.txt")).toBe("/workspace/b.txt");
    expect(resolveWorkspacePath(WORKSPACE_ROOT, "")).toBe("/workspace");
    expect(resolveWorkspacePath(WORKSPACE_ROOT, ".")).toBe("/workspace");
  });

  it("accepts absolute paths that stay inside the base", () => {
    expect(resolveWorkspacePath(WORKSPACE_ROOT, "/workspace/x/y.txt")).toBe("/workspace/x/y.txt");
  });

  it("throws on absolute escape", () => {
    expect(() => resolveWorkspacePath(WORKSPACE_ROOT, "/etc/passwd")).toThrow();
    expect(() => resolveWorkspacePath(WORKSPACE_ROOT, "/workspacefoo")).toThrow();
  });

  it("throws on .. above base", () => {
    expect(() => resolveWorkspacePath(WORKSPACE_ROOT, "../../etc/passwd")).toThrow();
    expect(() => resolveWorkspacePath(WORKSPACE_ROOT, "a/../../x")).toThrow();
    expect(() => resolveWorkspacePath(WORKSPACE_ROOT, "/workspace/../secret")).toThrow();
  });
});

describe("createFilesystemHandler", () => {
  it("read_file returns content", async () => {
    const ws = new FakeWorkspace();
    await ws.write("u-1", "/workspace/notes/a.txt", "hello workspace");
    const handler = createFilesystemHandler();
    const res = await handler.callTool("read_file", { path: "notes/a.txt" }, makeCtx(ws));
    expect(res.isError).toBe(false);
    expect(res.text).toBe("hello workspace");
  });

  it("write_file then read_file round-trips (absolute jail path optional)", async () => {
    const ws = new FakeWorkspace();
    const handler = createFilesystemHandler();
    const write = await handler.callTool("write_file", { path: "docs/b.md", content: "# b" }, makeCtx(ws));
    expect(write.isError).toBe(false);
    expect(write.text).toBe("File written successfully to docs/b.md");

    const read = await handler.callTool("read_file", { path: "/workspace/docs/b.md" }, makeCtx(ws));
    expect(read.isError).toBe(false);
    expect(read.text).toBe("# b");
  });

  it("path escape rejected — ../../etc/passwd and /etc/passwd → isError, workspace untouched", async () => {
    const ws = new FakeWorkspace();
    await ws.write("u-1", "/workspace/keep.txt", "keep");
    const handler = createFilesystemHandler();

    const rel = await handler.callTool("read_file", { path: "../../etc/passwd" }, makeCtx(ws));
    expect(rel.isError).toBe(true);
    expect(rel.text).toContain("Access denied");

    const abs = await handler.callTool("write_file", { path: "/etc/passwd", content: "pwn" }, makeCtx(ws));
    expect(abs.isError).toBe(true);
    expect(abs.text).toContain("Access denied");

    expect(ws.files.get("u-1")?.has("/etc/passwd")).toBe(false);
    for (const k of ws.files.get("u-1")?.keys() ?? []) expect(k.startsWith("/workspace")).toBe(true);
    expect(ws.files.get("u-1")?.get("/workspace/keep.txt")).toBe("keep");
  });

  it("read_file missing → File not found", async () => {
    const ws = new FakeWorkspace();
    const handler = createFilesystemHandler();
    const res = await handler.callTool("read_file", { path: "nope.txt" }, makeCtx(ws));
    expect(res.isError).toBe(true);
    expect(res.text).toContain("File not found");
  });

  it("list_directory returns entries", async () => {
    const ws = new FakeWorkspace();
    await ws.write("u-1", "/workspace/notes/a.txt", "aaa");
    await ws.write("u-1", "/workspace/notes/sub/b.md", "b");
    await ws.write("u-1", "/workspace/root.txt", "r");
    const handler = createFilesystemHandler();

    const res = await handler.callTool("list_directory", { path: "notes" }, makeCtx(ws));
    expect(res.isError).toBe(false);
    const entries = JSON.parse(res.text) as Array<Record<string, unknown>>;
    expect(entries).toHaveLength(2);
    const a = entries.find((e) => e.name === "a.txt");
    expect(a).toMatchObject({ name: "a.txt", path: "notes/a.txt", isDirectory: false, size: 3, modified: MTIME });
    const sub = entries.find((e) => e.name === "sub");
    expect(sub).toMatchObject({ name: "sub", path: "notes/sub", isDirectory: true });

    // default path "." lists the root
    const root = await handler.callTool("list_directory", {}, makeCtx(ws));
    const rootEntries = JSON.parse(root.text) as Array<Record<string, unknown>>;
    expect(rootEntries.map((e) => e.name).sort()).toEqual(["notes", "root.txt"]);
  });

  it("search_files matches by name substring (recursive)", async () => {
    const ws = new FakeWorkspace();
    await ws.write("u-1", "/workspace/src/main.ts", "x");
    await ws.write("u-1", "/workspace/src/util/format.ts", "x");
    await ws.write("u-1", "/workspace/notes/main-notes.txt", "x");
    const handler = createFilesystemHandler();

    const res = await handler.callTool("search_files", { pattern: "MAIN" }, makeCtx(ws));
    expect(res.isError).toBe(false);
    expect(JSON.parse(res.text).sort()).toEqual(["notes/main-notes.txt", "src/main.ts"]);

    const narrow = await handler.callTool("search_files", { path: "src", pattern: "format" }, makeCtx(ws));
    expect(JSON.parse(narrow.text)).toEqual(["src/util/format.ts"]);
  });

  it("get_file_info returns metadata", async () => {
    const ws = new FakeWorkspace();
    await ws.write("u-1", "/workspace/a.txt", "12345");
    const handler = createFilesystemHandler();
    const res = await handler.callTool("get_file_info", { path: "a.txt" }, makeCtx(ws));
    expect(res.isError).toBe(false);
    expect(JSON.parse(res.text)).toEqual({
      path: "a.txt",
      size: 5,
      modified: MTIME,
      isDirectory: false,
      isFile: true,
    });
  });

  it("delete_file removes the file", async () => {
    const ws = new FakeWorkspace();
    await ws.write("u-1", "/workspace/tmp/x.txt", "x");
    const handler = createFilesystemHandler();
    const res = await handler.callTool("delete_file", { path: "tmp/x.txt" }, makeCtx(ws));
    expect(res.isError).toBe(false);
    expect(res.text).toBe("Deleted file: tmp/x.txt");
    expect(await ws.read("u-1", "/workspace/tmp/x.txt")).toBeNull();
  });

  it("unknown tool → isError \"Unknown tool … for filesystem MCP\"", async () => {
    const handler = createFilesystemHandler();
    const res = await handler.callTool("chmod", { path: "a" }, makeCtx(new FakeWorkspace()));
    expect(res.isError).toBe(true);
    expect(res.text).toBe('Unknown tool "chmod" for filesystem MCP');
  });

  it("each user only sees their own workspace", async () => {
    const ws = new FakeWorkspace();
    await ws.write("u-1", "/workspace/secret.txt", "u1");
    const handler = createFilesystemHandler();
    const res = await handler.callTool("read_file", { path: "secret.txt" }, makeCtx(ws, "u-2"));
    expect(res.isError).toBe(true);
    expect(res.text).toContain("File not found");
  });

  it("listTools returns FILESYSTEM_TOOLS with verbatim schemas", async () => {
    const handler = createFilesystemHandler();
    const tools = await handler.listTools();
    expect(tools.map((t) => t.name)).toEqual([...FILESYSTEM_TOOLS]);
    const read = tools.find((t) => t.name === "read_file");
    expect(read?.inputSchema).toEqual({
      type: "object",
      properties: {
        path: { type: "string", description: "Path to the file." },
      },
      required: ["path"],
    });
  });

  it("initialize reports serverInfo filesystem", async () => {
    const handler = createFilesystemHandler();
    expect(await handler.initialize({})).toEqual({
      protocolVersion: "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "filesystem", version: "1.0.0" },
    });
  });
});
