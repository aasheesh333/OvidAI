/**
 * Native Memory MCP handler — a 1:1 port of the Dart NativeMemoryMcpHandler
 * (lib/core/native_mcp.dart), with the storage re-based: the Dart class kept
 * one in-process graph per handler instance; the cloud port persists the
 * graph at {workspace}/.ovid/memory/memory.json through ctx.workspace — per
 * user. The handler itself stays stateless between calls (graph loaded at
 * the start of every callTool and persisted on mutation), which is what
 * makes a process-wide singleton instance safe.
 *
 * Graph JSON shape: {entities: [{name, entityType, observations[]}],
 * relations: [{from, to, relationType}]}.
 */

import { trimToolResult, type McpToolDef, type McpToolCallResult } from "../client.js";
import type { McpCallContext, NativeMcpHandler } from "../transports/native.js";
import { resolveWorkspacePath, WORKSPACE_ROOT, type WorkspaceFiles } from "../workspace.js";

export const MEMORY_TOOLS: readonly string[] = [
  "create_entities",
  "create_relations",
  "add_observations",
  "read_graph",
  "search_nodes",
  "open_nodes",
];

const DEFAULT_DIR = ".ovid/memory";

interface MemoryEntity {
  name: string;
  entityType: string;
  observations: string[];
}

interface MemoryRelation {
  from: string;
  to: string;
  relationType: string;
}

interface MemoryGraph {
  entities: Map<string, MemoryEntity>;
  relations: MemoryRelation[];
}

function entityToJson(e: MemoryEntity): Record<string, unknown> {
  return { name: e.name, entityType: e.entityType, observations: [...e.observations] };
}

function relationToJson(r: MemoryRelation): Record<string, unknown> {
  return { from: r.from, to: r.to, relationType: r.relationType };
}

function toolResult(text: string, isError = false): McpToolCallResult {
  const trimmed = trimToolResult(text);
  return { text: trimmed, isError, content: [{ type: "text", text: trimmed }] };
}

const TOOLS: McpToolDef[] = [
  {
    name: "create_entities",
    description: "Create multiple new entities in the knowledge graph.",
    inputSchema: {
      type: "object",
      properties: {
        entities: {
          type: "array",
          items: {
            type: "object",
            properties: {
              name: { type: "string" },
              entityType: { type: "string" },
              observations: {
                type: "array",
                items: { type: "string" },
              },
            },
            required: ["name", "entityType", "observations"],
          },
        },
      },
      required: ["entities"],
    },
  },
  {
    name: "create_relations",
    description: "Create relations between entities in the knowledge graph.",
    inputSchema: {
      type: "object",
      properties: {
        relations: {
          type: "array",
          items: {
            type: "object",
            properties: {
              from: { type: "string" },
              to: { type: "string" },
              relationType: { type: "string" },
            },
            required: ["from", "to", "relationType"],
          },
        },
      },
      required: ["relations"],
    },
  },
  {
    name: "add_observations",
    description: "Add observations to existing entities in the graph.",
    inputSchema: {
      type: "object",
      properties: {
        observations: {
          type: "array",
          items: {
            type: "object",
            properties: {
              entityName: { type: "string" },
              contents: {
                type: "array",
                items: { type: "string" },
              },
            },
            required: ["entityName", "contents"],
          },
        },
      },
      required: ["observations"],
    },
  },
  {
    name: "read_graph",
    description: "Read the entire knowledge graph.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "search_nodes",
    description: "Search for nodes in the knowledge graph matching a query.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Query string." },
      },
      required: ["query"],
    },
  },
  {
    name: "open_nodes",
    description: "Retrieve specific nodes by their names along with their relations.",
    inputSchema: {
      type: "object",
      properties: {
        names: {
          type: "array",
          items: { type: "string" },
          description: "Names of entities to open.",
        },
      },
      required: ["names"],
    },
  },
];

function stringList(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
}

export function createMemoryHandler(deps: { dir?: string } = {}): NativeMcpHandler {
  const dir = deps.dir ?? DEFAULT_DIR;
  // the storage path is fixed at construction; an escaping dir fails fast
  const storagePath = resolveWorkspacePath(WORKSPACE_ROOT, `${dir}/memory.json`);

  /** R6: native.ts still types workspace as the permissive placeholder; the
   * real surface is workspace.ts and the worker seam (Task 16) adapts to it. */
  function workspaceOf(ctx: McpCallContext): WorkspaceFiles {
    return ctx.workspace as unknown as WorkspaceFiles;
  }

  async function load(ws: WorkspaceFiles, uid: string): Promise<MemoryGraph> {
    const graph: MemoryGraph = { entities: new Map(), relations: [] };
    const stored = await ws.read(uid, storagePath);
    if (stored === null) return graph;
    try {
      const json = JSON.parse(stored.content) as Record<string, unknown>;
      for (const item of Array.isArray(json.entities) ? json.entities : []) {
        if (typeof item === "object" && item !== null) {
          const j = item as Record<string, unknown>;
          const e: MemoryEntity = {
            name: typeof j.name === "string" ? j.name : "",
            entityType: typeof j.entityType === "string" ? j.entityType : "Concept",
            observations: stringList(j.observations),
          };
          if (e.name !== "") graph.entities.set(e.name, e);
        }
      }
      for (const item of Array.isArray(json.relations) ? json.relations : []) {
        if (typeof item === "object" && item !== null) {
          const j = item as Record<string, unknown>;
          if (typeof j.from === "string" && typeof j.to === "string") {
            graph.relations.push({
              from: j.from,
              to: j.to,
              relationType: typeof j.relationType === "string" ? j.relationType : "related_to",
            });
          }
        }
      }
    } catch {
      // corrupt storage starts empty (Dart parity: Diag.swallow on load)
    }
    return graph;
  }

  async function persist(ws: WorkspaceFiles, uid: string, graph: MemoryGraph): Promise<void> {
    const json = {
      entities: [...graph.entities.values()].map(entityToJson),
      relations: graph.relations.map(relationToJson),
    };
    await ws.write(uid, storagePath, JSON.stringify(json));
  }

  function graphJson(graph: MemoryGraph): string {
    return JSON.stringify({
      entities: [...graph.entities.values()].map(entityToJson),
      relations: graph.relations.map(relationToJson),
    });
  }

  return {
    async initialize(): Promise<Record<string, unknown>> {
      return {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "memory", version: "1.0.0" },
      };
    },

    async listTools(): Promise<McpToolDef[]> {
      return TOOLS.map((t) => ({ ...t, inputSchema: { ...t.inputSchema } }));
    },

    async callTool(name: string, args: Record<string, unknown>, ctx: McpCallContext): Promise<McpToolCallResult> {
      const ws = workspaceOf(ctx);
      try {
        // state lives in the user's workspace, never in the handler
        const graph = await load(ws, ctx.uid);

        switch (name) {
          case "create_entities": {
            const entitiesList = args.entities;
            if (!Array.isArray(entitiesList)) return toolResult("Missing entities list", true);
            const created: MemoryEntity[] = [];
            for (const raw of entitiesList) {
              if (typeof raw !== "object" || raw === null) continue;
              const j = raw as Record<string, unknown>;
              const eName = typeof j.name === "string" ? j.name : "";
              const entityType = typeof j.entityType === "string" ? j.entityType : "Concept";
              const obs = stringList(j.observations);
              if (eName === "") continue;
              const existing = graph.entities.get(eName);
              if (existing !== undefined) {
                const merged = [...new Set([...existing.observations, ...obs])];
                const updated: MemoryEntity = {
                  name: eName,
                  entityType: entityType !== "" ? entityType : existing.entityType,
                  observations: merged,
                };
                graph.entities.set(eName, updated);
                created.push(updated);
              } else {
                const entity: MemoryEntity = { name: eName, entityType, observations: obs };
                graph.entities.set(eName, entity);
                created.push(entity);
              }
            }
            await persist(ws, ctx.uid, graph);
            return toolResult(JSON.stringify(created.map(entityToJson)));
          }

          case "create_relations": {
            const relsList = args.relations;
            if (!Array.isArray(relsList)) return toolResult("Missing relations list", true);
            const added: MemoryRelation[] = [];
            for (const raw of relsList) {
              if (typeof raw !== "object" || raw === null) continue;
              const j = raw as Record<string, unknown>;
              const from = typeof j.from === "string" ? j.from : "";
              const to = typeof j.to === "string" ? j.to : "";
              const relationType = typeof j.relationType === "string" ? j.relationType : "related_to";
              if (from === "" || to === "") continue;
              const exists = graph.relations.some(
                (r) => r.from === from && r.to === to && r.relationType === relationType,
              );
              if (!exists) {
                const rel: MemoryRelation = { from, to, relationType };
                graph.relations.push(rel);
                added.push(rel);
              }
            }
            await persist(ws, ctx.uid, graph);
            return toolResult(JSON.stringify(added.map(relationToJson)));
          }

          case "add_observations": {
            const obsList = args.observations;
            if (!Array.isArray(obsList)) return toolResult("Missing observations list", true);
            const modified: MemoryEntity[] = [];
            for (const raw of obsList) {
              if (typeof raw !== "object" || raw === null) continue;
              const j = raw as Record<string, unknown>;
              const eName = typeof j.entityName === "string" ? j.entityName : "";
              const contents = stringList(j.contents);
              if (eName === "" || contents.length === 0) continue;
              const existing = graph.entities.get(eName);
              if (existing !== undefined) {
                const merged = [...new Set([...existing.observations, ...contents])];
                const updated: MemoryEntity = {
                  name: eName,
                  entityType: existing.entityType,
                  observations: merged,
                };
                graph.entities.set(eName, updated);
                modified.push(updated);
              } else {
                const entity: MemoryEntity = { name: eName, entityType: "Concept", observations: contents };
                graph.entities.set(eName, entity);
                modified.push(entity);
              }
            }
            await persist(ws, ctx.uid, graph);
            return toolResult(JSON.stringify(modified.map(entityToJson)));
          }

          case "read_graph": {
            return toolResult(graphJson(graph));
          }

          case "search_nodes": {
            const query = (typeof args.query === "string" ? args.query : "").toLowerCase();
            const matching = [...graph.entities.values()].filter((e) => {
              if (e.name.toLowerCase().includes(query)) return true;
              if (e.entityType.toLowerCase().includes(query)) return true;
              return e.observations.some((o) => o.toLowerCase().includes(query));
            });
            const names = new Set(matching.map((e) => e.name));
            const matchingRelations = graph.relations.filter((r) => names.has(r.from) || names.has(r.to));
            return toolResult(
              JSON.stringify({
                entities: matching.map(entityToJson),
                relations: matchingRelations.map(relationToJson),
              }),
            );
          }

          case "open_nodes": {
            const names = new Set(stringList(args.names));
            const matching = [...graph.entities.values()].filter((e) => names.has(e.name));
            const matchingRelations = graph.relations.filter((r) => names.has(r.from) || names.has(r.to));
            return toolResult(
              JSON.stringify({
                entities: matching.map(entityToJson),
                relations: matchingRelations.map(relationToJson),
              }),
            );
          }

          default:
            return toolResult(`Unknown tool "${name}" for memory MCP`, true);
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return toolResult(`Memory error: ${message}`, true);
      }
    },
  };
}
