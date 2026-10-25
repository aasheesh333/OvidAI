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
import {
  authorizeProviderOperation,
  snapshotProviderArgs,
  validateProviderArgs,
  type Effect,
  type ProviderOperation,
  type ToolContext,
} from "../providers/types.js";

export const MEMORY_TOOLS: readonly string[] = [
  "create_entities",
  "create_relations",
  "add_observations",
  "read_graph",
  "search_nodes",
  "open_nodes",
];

const DEFAULT_DIR = ".ovid/memory";
export const MEMORY_MAX_STORED_BYTES = 1_048_576;
export const MEMORY_STORAGE_PATH = "/workspace/.ovid/memory/memory.json";
const MUTATION_TOOLS = new Set(["create_entities", "create_relations", "add_observations"]);
const MAX_PENDING_MUTATION_QUEUES = 1_024;
/** Process-wide per-uid lock shared by every Memory handler instance. */
const MUTATION_QUEUES = new Map<string, Promise<void>>();

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

function isObjectRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function schemaValue(value: unknown): Record<string, unknown> {
  return isObjectRecord(value) ? value : {};
}

function boundedMemorySchema(schema: Record<string, unknown>): Record<string, unknown> {
  if (schema.type === "string") return { ...schema, minLength: 1, maxLength: 16_384 };
  if (schema.type === "array") {
    return {
      ...schema,
      maxItems: 1_000,
      items: boundedMemorySchema(schemaValue(schema.items)),
    };
  }
  const properties = Object.fromEntries(Object.entries(schema.properties ?? {}).map(([name, value]) => [
    name,
    boundedMemorySchema(schemaValue(value)),
  ]));
  return {
    ...schema,
    properties,
    additionalProperties: false,
    maxProperties: Object.keys(properties).length,
  };
}

const MEMORY_EFFECTS: Readonly<Record<string, Effect>> = {
  create_entities: "write",
  create_relations: "write",
  add_observations: "write",
  read_graph: "read",
  search_nodes: "read",
  open_nodes: "read",
};

export const MEMORY_OPERATIONS: readonly ProviderOperation[] = TOOLS.map((tool) => ({
  name: tool.name,
  description: tool.description ?? `Memory operation ${tool.name}.`,
  inputSchema: boundedMemorySchema(schemaValue(tool.inputSchema)),
  effect: MEMORY_EFFECTS[tool.name] ?? "write",
  approval: "mode",
  requiredScopes: [],
  request: {
    originKey: "memory",
    method: MEMORY_EFFECTS[tool.name] === "read" ? "GET" : "POST",
    pathTemplate: `/${tool.name}`,
  },
  limits: { timeoutMs: 30_000, responseBytes: 65_536, frameBytes: 65_536, pageBytes: 65_536 },
  outputPolicy: { kind: "redacted_json", maxBytes: 65_536 },
}));

function memoryAuthorizationContext(ctx: McpCallContext): ToolContext {
  const candidate = ctx as unknown as Partial<ToolContext>;
  return {
    ...candidate,
    sessionId: candidate.sessionId ?? "",
    runId: candidate.runId ?? "",
    userId: candidate.userId ?? ctx.uid,
    connectionId: candidate.connectionId ?? "",
    providerId: "memory",
    mode: candidate.mode ?? "safe",
    planMode: candidate.planMode ?? false,
    unattended: candidate.unattended ?? true,
    isSubagent: candidate.isSubagent ?? false,
    depth: candidate.depth ?? 0,
    callKey: candidate.callKey ?? "",
    signal: candidate.signal ?? new AbortController().signal,
  } as ToolContext;
}

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
    const metadata = await ws.stat(uid, storagePath);
    if (metadata !== null && metadata.size > MEMORY_MAX_STORED_BYTES) {
      throw new Error("Stored memory graph exceeds the 1 MiB pre-read bound.");
    }
    const stored = await ws.read(uid, storagePath);
    if (stored === null) return graph;
    if (Buffer.byteLength(stored.content, "utf8") > MEMORY_MAX_STORED_BYTES) {
      throw new Error("Stored memory graph exceeds the 1 MiB bound.");
    }
    let json: Record<string, unknown>;
    try {
      const parsed = JSON.parse(stored.content) as unknown;
      if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("not an object");
      json = parsed as Record<string, unknown>;
      if (!Array.isArray(json.entities) || !Array.isArray(json.relations) ||
          json.entities.length > 100_000 || json.relations.length > 100_000) {
        throw new Error("invalid graph arrays");
      }
      for (const item of json.entities) {
        if (typeof item !== "object" || item === null || Array.isArray(item)) throw new Error("invalid entity");
        const entry = item as Record<string, unknown>;
        if (typeof entry.name !== "string" || entry.name === "" ||
            typeof entry.entityType !== "string" || entry.entityType === "" ||
            !Array.isArray(entry.observations) || entry.observations.length > 10_000 ||
            entry.observations.some((observation) => typeof observation !== "string")) {
          throw new Error("invalid entity fields");
        }
        graph.entities.set(entry.name, {
          name: entry.name,
          entityType: entry.entityType,
          observations: [...entry.observations] as string[],
        });
      }
      for (const item of json.relations) {
        if (typeof item !== "object" || item === null || Array.isArray(item)) throw new Error("invalid relation");
        const relation = item as Record<string, unknown>;
        if (typeof relation.from !== "string" || relation.from === "" ||
            typeof relation.to !== "string" || relation.to === "" ||
            typeof relation.relationType !== "string" || relation.relationType === "") {
          throw new Error("invalid relation fields");
        }
        graph.relations.push({ from: relation.from, to: relation.to, relationType: relation.relationType });
      }
    } catch {
      throw new Error("Stored memory graph is corrupt or invalid; refusing to replace it.");
    }
    return graph;
  }

  async function persist(ws: WorkspaceFiles, uid: string, graph: MemoryGraph): Promise<void> {
    const json = {
      entities: [...graph.entities.values()].map(entityToJson),
      relations: graph.relations.map(relationToJson),
    };
    const serialized = JSON.stringify(json);
    if (Buffer.byteLength(serialized, "utf8") > MEMORY_MAX_STORED_BYTES) {
      throw new Error("Memory graph exceeds the 1 MiB storage bound; the previous file was not changed.");
    }
    await ws.write(uid, storagePath, serialized);
  }

  function graphJson(graph: MemoryGraph): string {
    return JSON.stringify({
      entities: [...graph.entities.values()].map(entityToJson),
      relations: graph.relations.map(relationToJson),
    });
  }

  const executeHandler: NativeMcpHandler = {
    async initialize(): Promise<Record<string, unknown>> {
      return {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "memory", version: "1.0.0" },
      };
    },

    async listTools(): Promise<McpToolDef[]> {
      return MEMORY_OPERATIONS.map((operation) => ({ ...operation, inputSchema: { ...operation.inputSchema } }));
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

  async function serializedMutation<T>(uid: string, run: () => Promise<T>): Promise<T> {
    const previous = MUTATION_QUEUES.get(uid);
    if (previous === undefined && MUTATION_QUEUES.size >= MAX_PENDING_MUTATION_QUEUES) {
      throw new Error("Memory mutation queue limit exceeded; retry after pending mutations settle.");
    }
    const next = (previous ?? Promise.resolve()).catch(() => {}).then(run);
    const tail = next.then(() => undefined, () => undefined);
    MUTATION_QUEUES.set(uid, tail);
    try {
      return await next;
    } finally {
      if (MUTATION_QUEUES.get(uid) === tail) MUTATION_QUEUES.delete(uid);
    }
  }

  return {
    initialize: (params) => executeHandler.initialize(params),
    listTools: () => executeHandler.listTools(),
    async callTool(name, args, ctx) {
      const operation = MEMORY_OPERATIONS.find((candidate) => candidate.name === name);
      if (operation === undefined) return toolResult(`Unknown tool "${name}" for memory MCP`, true);
      try {
        args = snapshotProviderArgs(args);
      } catch {
        return toolResult("Invalid operation arguments.", true);
      }
      if (!validateProviderArgs(operation.inputSchema, args).ok) {
        return toolResult("Invalid operation arguments.", true);
      }
      const authorization = await authorizeProviderOperation(memoryAuthorizationContext(ctx), operation, args);
      if (authorization.kind === "deny") return toolResult(`Operation denied (${authorization.code}).`, true);
      if (!MUTATION_TOOLS.has(name)) return executeHandler.callTool(name, args, ctx);
      return serializedMutation(ctx.uid, () => executeHandler.callTool(name, args, ctx));
    },
  };
}
