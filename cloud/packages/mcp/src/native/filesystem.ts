/**
 * Native Filesystem MCP handler — a 1:1 port of the Dart
 * NativeFilesystemMcpHandler (lib/core/native_mcp.dart), re-based from local
 * disk onto the P2 workspace seam: instead of a rootPath on the host, every
 * user path is jailed by resolveWorkspacePath against WORKSPACE_ROOT and then
 * served through ctx.workspace (per-user, jail-internal /workspace →
 * /workspaces/users/{uid}). Because the handler holds no state, one
 * process-wide instance is safe; user separation comes from ctx.
 */

import { trimToolResult, type McpToolDef, type McpToolCallResult } from "../client.js";
import type { McpCallContext, NativeMcpHandler } from "../transports/native.js";
import { resolveWorkspacePath, WORKSPACE_ROOT, type WorkspaceFiles } from "../workspace.js";

// The brief's FILESYSTEM_TOOLS adds create_or_update_file (an alias of
// write_file — same jail, same write) on top of the Dart tool set.
export const FILESYSTEM_TOOLS: readonly string[] = [
  "read_file",
  "write_file",
  "create_or_update_file",
  "delete_file",
  "list_directory",
  "get_file_info",
  "search_files",
];

/** R6: native.ts still types workspace as the permissive placeholder; the
 * real surface is workspace.ts and the worker seam (Task 16) adapts to it. */
function workspaceOf(ctx: McpCallContext): WorkspaceFiles {
  return ctx.workspace as unknown as WorkspaceFiles;
}

function toolResult(text: string, isError = false): McpToolCallResult {
  const trimmed = trimToolResult(text);
  return { text: trimmed, isError, content: [{ type: "text", text: trimmed }] };
}

const WRITE_SCHEMA = {
  type: "object",
  properties: {
    path: { type: "string", description: "Path to the file." },
    content: { type: "string", description: "Content to write." },
  },
  required: ["path", "content"],
};

const TOOLS: McpToolDef[] = [
  {
    name: "read_file",
    description: "Read the contents of a file.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to the file." },
      },
      required: ["path"],
    },
  },
  {
    name: "write_file",
    description: "Create or overwrite a file with given contents.",
    inputSchema: WRITE_SCHEMA,
  },
  {
    name: "create_or_update_file",
    description: "Create or update a file with given contents.",
    inputSchema: WRITE_SCHEMA,
  },
  {
    name: "delete_file",
    description: "Delete a file or directory.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to delete." },
      },
      required: ["path"],
    },
  },
  {
    name: "list_directory",
    description: "List contents of a directory.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to directory (default: root)." },
      },
    },
  },
  {
    name: "get_file_info",
    description: "Get file or directory metadata (size, modified time, etc.).",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to file or directory." },
      },
      required: ["path"],
    },
  },
  {
    name: "search_files",
    description: "Recursively search for files matching a pattern.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Starting path (default: root)." },
        pattern: { type: "string", description: "Filename search pattern or substring." },
      },
      required: ["pattern"],
    },
  },
];

/** Relative-to-root display path (Dart _relative). */
function relFromRoot(resolved: string): string {
  if (resolved === WORKSPACE_ROOT) return ".";
  return resolved.slice(WORKSPACE_ROOT.length + 1);
}

function escapeRegExp(p: string): string {
  return p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function createFilesystemHandler(): NativeMcpHandler {
  return {
    async initialize(): Promise<Record<string, unknown>> {
      return {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "filesystem", version: "1.0.0" },
      };
    },

    async listTools(): Promise<McpToolDef[]> {
      return TOOLS.map((t) => ({ ...t, inputSchema: { ...t.inputSchema } }));
    },

    async callTool(name: string, args: Record<string, unknown>, ctx: McpCallContext): Promise<McpToolCallResult> {
      const ws = workspaceOf(ctx);
      try {
        // the jail: every path resolves inside WORKSPACE_ROOT or is refused
        function resolve(p: unknown): string {
          const relPath = typeof p === "string" ? p : "";
          return resolveWorkspacePath(WORKSPACE_ROOT, relPath);
        }

        switch (name) {
          case "read_file": {
            const relPath = args.path;
            if (typeof relPath !== "string") return toolResult("Missing path", true);
            const safe = resolve(relPath);
            const file = await ws.read(ctx.uid, safe);
            if (file === null) return toolResult(`File not found: ${relPath}`, true);
            return toolResult(file.content);
          }

          case "write_file":
          case "create_or_update_file": {
            const relPath = args.path;
            const content = args.content;
            if (typeof relPath !== "string" || typeof content !== "string") {
              return toolResult("Missing path or content", true);
            }
            const safe = resolve(relPath);
            await ws.write(ctx.uid, safe, content);
            return toolResult(`File written successfully to ${relFromRoot(safe)}`);
          }

          case "list_directory": {
            const safe = resolve(typeof args.path === "string" ? args.path : ".");
            if ((await ws.stat(ctx.uid, safe)) === null) {
              return toolResult(`Directory not found: ${relFromRoot(safe)}`, true);
            }
            const entries = await ws.list(ctx.uid, safe);
            const dirRel = relFromRoot(safe);
            const list = entries.map((e) => ({
              name: e.name,
              path: dirRel === "." ? e.name : `${dirRel}/${e.name}`,
              isDirectory: e.type === "dir",
              size: e.size,
              modified: e.mtime,
            }));
            return toolResult(JSON.stringify(list));
          }

          case "get_file_info": {
            const relPath = args.path;
            if (typeof relPath !== "string") return toolResult("Missing path", true);
            const safe = resolve(relPath);
            const stat = await ws.stat(ctx.uid, safe);
            if (stat === null) return toolResult(`Not found: ${relPath}`, true);
            return toolResult(
              JSON.stringify({
                path: relFromRoot(safe),
                size: stat.size,
                modified: stat.mtime,
                isDirectory: stat.type === "dir",
                isFile: stat.type === "file",
              }),
            );
          }

          case "search_files": {
            const pattern = args.pattern;
            if (typeof pattern !== "string" || pattern === "") {
              return toolResult("Missing search pattern", true);
            }
            const safe = resolve(typeof args.path === "string" ? args.path : ".");
            if ((await ws.stat(ctx.uid, safe)) === null) {
              return toolResult(`Directory not found: ${relFromRoot(safe)}`, true);
            }
            const regExp = new RegExp(escapeRegExp(pattern), "i");
            const matches: string[] = [];

            const walk = async (dirAbs: string, relBase: string): Promise<void> => {
              const entries = await ws.list(ctx.uid, dirAbs);
              for (const e of entries) {
                const rel = relBase === "" ? e.name : `${relBase}/${e.name}`;
                if (regExp.test(e.name) || regExp.test(rel)) matches.push(rel);
                if (e.type === "dir") await walk(`${dirAbs}/${e.name}`, rel);
              }
            };
            await walk(safe, relFromRoot(safe) === "." ? "" : relFromRoot(safe));
            return toolResult(JSON.stringify(matches));
          }

          case "delete_file": {
            const relPath = args.path;
            if (typeof relPath !== "string") return toolResult("Missing path", true);
            const safe = resolve(relPath);
            const stat = await ws.stat(ctx.uid, safe);
            if (stat === null) {
              return toolResult(`File or directory does not exist: ${relFromRoot(safe)}`, true);
            }
            await ws.remove(ctx.uid, safe);
            return toolResult(
              stat.type === "dir"
                ? `Deleted directory: ${relFromRoot(safe)}`
                : `Deleted file: ${relFromRoot(safe)}`,
            );
          }

          default:
            return toolResult(`Unknown tool "${name}" for filesystem MCP`, true);
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        // resolveWorkspacePath threw — the jail refused this path
        if (message.includes("escapes the workspace root")) {
          return toolResult(`Access denied: ${message}`, true);
        }
        return toolResult(`Filesystem error: ${message}`, true);
      }
    },
  };
}
