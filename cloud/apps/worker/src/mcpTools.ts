/**
 * MCP/catalog agent tools (P5 Task 16) — THE P3 ROSTER SEAM.
 *
 * ## Seam contract (P3 consumes this)
 *
 * P3's roster builder calls `mcpToolProvider.tools(uid)` / `specs(uid)`
 * alongside the native tools when assembling the sorted tool list, and routes
 * any model tool-call whose name starts with `mcp__` (or resolves through
 * `router.resolveTool`) to that tool's canonical
 * `execute(args, ctx) → ToolResult` (ctx carries uid + session/run ids). The
 * provider closes over the active run's `RunContext`; its `sampler` is a
 * closure over the run's `ModelTransport` + the run's API key — ONE
 * completion call, NO retry layer (the processor owns retries; reword when
 * P9's `RunDeps.keys: KeyResolver` lands).
 *
 * Catalog agent tools (`catalog_list_mcp`, `catalog_add_mcp`,
 * `agent_install_mcp`, `agent_install_plugin`) register as ordinary roster
 * tools owned by P3 through the SAME canonical seam. Until P3 lands they are
 * exercised at router level by the Task 16 e2e.
 *
 * Tool rules:
 * - a GATED refusal is a normal tool result
 *   `{content: PRO_REQUIRED_MESSAGE, isError: true}` — the agent can adapt
 *   and tell the user; never a thrown error into the run loop;
 * - user/validation errors are `isError` results, never throws;
 * - `execute` validates its own arguments.
 */

import { randomUUID } from "node:crypto";
import { plugins as pluginsRepo, users as usersRepo, type Db } from "@ovid/db";
import {
  ConfigParseError,
  PRO_REQUIRED_MESSAGE,
  ProRequiredError,
  adaptPlugin,
  parseMcpConfig,
  type McpRouter,
  type McpServerSummary,
  type McpToolListing,
  type PluginInstallJob,
  type PluginSourceInput,
  type RunContext,
  type SourceResolver,
} from "@ovid/mcp";
import { pluginSourceInputSchema } from "@ovid/shared";
import type { ModelToolSpec } from "./tools/types.js";

// ---------------------------------------------------------------------------
// Canonical tool seam (P2's AgentTool additively extended)
// ---------------------------------------------------------------------------

/** P2's landed `{content, isError}` + optional artifacts; omitted isError === false. */
export interface ToolResult {
  content: string;
  isError?: boolean;
  artifacts?: unknown[];
}

/** The subset of P2's ToolContext the MCP surface needs (RunContext rides alongside). */
export interface McpToolContext {
  uid: string;
  sessionId: string;
  runId: string;
}

export interface McpAgentTool {
  /** Published name: `mcp__<server>__<tool>` (or `catalog_*` / `agent_*`). */
  readonly name: string;
  readonly description: string;
  /** JSON Schema object sent to the model. */
  readonly parameters: Record<string, unknown>;
  /** Validates args itself; user errors → isError result, never a throw. */
  execute(args: Record<string, unknown>, ctx: McpToolContext): Promise<ToolResult>;
}

export interface McpToolProvider {
  /** One tool per McpToolListing, sorted by name (prompt-cache-stable). */
  tools(uid: string): Promise<McpAgentTool[]>;
  /** [OI] function specs derived from tools(), same sort. */
  specs(uid: string): Promise<ModelToolSpec[]>;
}

function byName(a: { name: string }, b: { name: string }): number {
  return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
}

function toolResult(content: string, isError = false): ToolResult {
  return isError ? { content, isError: true } : { content, isError: false };
}

function runContext(ctx: McpToolContext): RunContext {
  return { sessionId: ctx.sessionId, runId: ctx.runId };
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** ProRequiredError → the pinned upgrade copy (never a throw). */
function gatedOrRethrow(err: unknown): ToolResult {
  if (err instanceof ProRequiredError) {
    return toolResult(PRO_REQUIRED_MESSAGE, true);
  }
  const code = (err as { code?: unknown } | null)?.code;
  if (code === "sandbox_unavailable") {
    return toolResult(errorMessage(err), true);
  }
  throw err;
}

function toolForListing(router: McpRouter, uid: string, listing: McpToolListing): McpAgentTool {
  return {
    name: listing.name,
    description: listing.description ?? `MCP tool ${listing.name}`,
    parameters: listing.inputSchema ?? { type: "object", properties: {} },
    async execute(args, ctx) {
      const runCtx = runContext(ctx);
      try {
        // Never guess: resolve first, then dispatch through the router (the
        // router re-reads the tier at every gate point).
        const resolved = await router.resolveTool(uid, listing.name, runCtx);
        if (resolved === null) {
          return toolResult(`Unknown tool: ${listing.name}`, true);
        }
        const result = await router.callTool(uid, listing.name, args, runCtx);
        return toolResult(result.text, result.isError);
      } catch (err) {
        return gatedOrRethrow(err);
      }
    },
  };
}

export function createMcpToolProvider(router: McpRouter): McpToolProvider {
  async function listTools(uid: string): Promise<McpAgentTool[]> {
    const listings = await router.listTools(uid);
    return [...listings].sort(byName).map((listing) => toolForListing(router, uid, listing));
  }

  const provider: McpToolProvider = {
    tools: listTools,
    async specs(uid: string): Promise<ModelToolSpec[]> {
      // M3: derive from tools() (the one roster fetch), never a second
      // router.listTools pass — that would re-spawn stdio servers just to
      // produce the model-facing specs.
      const tools = await provider.tools(uid);
      return tools.map((tool) => ({
        type: "function" as const,
        function: {
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters,
        },
      }));
    },
  };
  return provider;
}

// ---------------------------------------------------------------------------
// Catalog + install tools
// ---------------------------------------------------------------------------

/**
 * Structural BullMQ `Queue.add` subset — the worker must not declare a
 * direct bullmq dependency (only @ovid/queue does). The deferred
 * plugin-installs lane's concrete Queue<PluginInstallJob> satisfies this.
 */
export interface PluginInstallQueue {
  add(
    name: string,
    data: PluginInstallJob,
    opts?: { priority?: number; jobId?: string },
  ): Promise<unknown>;
}

export interface CatalogToolDeps {
  router: McpRouter;
  db: Db;
  queues: { pluginInstalls: PluginInstallQueue };
  /**
   * The runtime's source resolver (I3). REQUIRED: the enqueue path must write
   * the SAME canonical `publisher/name` the installer derives from the
   * adapted manifest. The old per-source heuristic (`paste/<label>`,
   * package/URL slugs) produced ids the installer refuses with
   * `plugin_id_mismatch`, so paste installs were guaranteed to fail.
   *
   * The source is staged once here to read the manifest id; the installer
   * resolves it again at install time (T14 owns that transaction). A source
   * that cannot be resolved/adapted is an isError result and is never
   * enqueued.
   */
  resolver: Pick<SourceResolver, "resolve">;
}

const LIST_SCOPE = { type: "string", enum: ["curated", "custom", "all"] } as const;

const CATALOG_DEFS: ReadonlyArray<Pick<McpAgentTool, "name" | "description" | "parameters">> = [
  {
    name: "catalog_list_mcp",
    description:
      "List MCP servers available to this user. scope: curated (built-in), custom (user-added), or all.",
    parameters: {
      type: "object",
      properties: {
        scope: { ...LIST_SCOPE, description: "Which servers to list (default: all)." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "catalog_add_mcp",
    description:
      "Add a custom MCP server from a pasted .mcp.json / Codex TOML config. Custom servers are a Pro feature.",
    parameters: {
      type: "object",
      properties: {
        config: { type: "string", description: "The pasted MCP configuration text." },
      },
      required: ["config"],
      additionalProperties: false,
    },
  },
  {
    name: "agent_install_mcp",
    description:
      "Connect to an MCP server and report how many tools it exposes. Curated servers need no extra install.",
    parameters: {
      type: "object",
      properties: {
        server: {
          type: "string",
          description: "Server id, published name, or curated id (e.g. github).",
        },
      },
      required: ["server"],
      additionalProperties: false,
    },
  },
  {
    name: "agent_install_plugin",
    description:
      "Install a plugin from a source string: owner/repo (GitHub), npm:<package>, an http(s) archive URL, or a pasted config. Pro feature.",
    parameters: {
      type: "object",
      properties: {
        source: {
          type: "string",
          description: "owner/repo, npm:<pkg>, https://…zip, or pasted config text.",
        },
      },
      required: ["source"],
      additionalProperties: false,
    },
  },
];

/**
 * M1: the exported catalog-tool METADATA (names/schemas are stable and safe
 * to render), deliberately WITHOUT `execute`. Execution requires runtime
 * deps (db/queues/resolver) and is bound by `createCatalogTools(deps)`; a
 * consumer that needs callable tools must go through that factory. Omitting
 * `execute` makes the unbound state a type error instead of a runtime
 * "not bound" result.
 */
export type CatalogAgentToolDef = Pick<McpAgentTool, "name" | "description" | "parameters">;

export const CATALOG_AGENT_TOOLS: readonly CatalogAgentToolDef[] = CATALOG_DEFS.map(
  (def) => ({ ...def }),
);

function parseScope(value: unknown): "curated" | "custom" | "all" | null {
  if (value === undefined) return "all";
  return value === "curated" || value === "custom" || value === "all" ? value : null;
}

function summaryItem(summary: McpServerSummary): Record<string, unknown> {
  return {
    id: summary.id,
    name: summary.name,
    transport: summary.transport,
    curatedId: summary.curatedId,
    enabled: summary.enabled,
    hasSecrets: summary.hasSecrets,
    status: summary.status,
  };
}

/** Parse the agent-facing source string into the shared wire contract. */
export function parsePluginSource(raw: string): PluginSourceInput {
  const text = raw.trim();
  if (text === "") throw new Error("invalid_input: source is empty");

  if (text.startsWith("npm:")) {
    const spec = text.slice("npm:".length).trim();
    const match = /^(@[^/]+\/[^@]+|[^@]+)(?:@(.+))?$/.exec(spec);
    if (match === null) throw new Error("invalid_input: malformed npm source");
    return pluginSourceInputSchema.parse({
      kind: "npm",
      package: match[1]!,
      ...(match[2] !== undefined ? { version: match[2] } : {}),
    });
  }

  if (/^https?:\/\//i.test(text)) {
    return pluginSourceInputSchema.parse({ kind: "zip", url: text });
  }

  const github = /^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)(?:@([^\s]+))?$/.exec(text);
  if (github !== null) {
    return pluginSourceInputSchema.parse({
      kind: "github",
      owner: github[1]!,
      repo: github[2]!,
      ...(github[3] !== undefined ? { ref: github[3] } : {}),
    });
  }

  return pluginSourceInputSchema.parse({ kind: "paste", label: "pasted", config: text });
}

/**
 * I3: derive the canonical plugin id the SAME way the installer will — stage
 * the source with the runtime's resolver and adapt its manifest (Task 13's
 * normalization). Enqueueing a heuristic id (`paste/<label>`, a package or
 * URL slug) made the installer refuse the job with `plugin_id_mismatch`.
 *
 * The staging tree is discarded immediately: this call only reads identity;
 * the install transaction resolves the source again.
 */
async function canonicalPluginId(
  resolver: Pick<SourceResolver, "resolve">,
  source: PluginSourceInput,
): Promise<string> {
  const resolved = await resolver.resolve(source);
  try {
    return (await adaptPlugin(resolved.stagingDir)).pluginId;
  } finally {
    await resolved.discard().catch(() => {
      // discard is idempotent/best-effort; identity was already read.
    });
  }
}

export function createCatalogTools(deps: CatalogToolDeps): McpAgentTool[] {
  const { router, db, queues, resolver } = deps;

  const listTool: McpAgentTool = {
    ...CATALOG_DEFS[0]!,
    async execute(args, ctx) {
      try {
        const scope = parseScope(args.scope);
        if (scope === null) {
          return toolResult('invalid_input: scope must be "curated", "custom" or "all"', true);
        }
        const servers = await router.listServers(ctx.uid);
        const items = servers.filter((server) =>
          scope === "all"
            ? true
            : scope === "curated"
              ? server.curatedId !== null
              : server.curatedId === null,
        );
        return toolResult(JSON.stringify(items.map(summaryItem)));
      } catch (err) {
        return gatedOrRethrow(err);
      }
    },
  };

  const addTool: McpAgentTool = {
    ...CATALOG_DEFS[1]!,
    async execute(args, ctx) {
      try {
        const config = args.config;
        if (typeof config !== "string" || config.trim() === "") {
          return toolResult("invalid_input: config must be a non-empty string", true);
        }
        let imported;
        try {
          // Empty env: `${SECRET}` references stay literal for the
          // credential gate; worker env values never leak into stored config.
          imported = parseMcpConfig(config, { env: {} });
        } catch (err) {
          if (err instanceof ConfigParseError) {
            return toolResult(`invalid_config: ${err.message}`, true);
          }
          throw err;
        }
        if (imported.length === 0) {
          return toolResult("invalid_config: no MCP servers found in config", true);
        }
        const summary = await router.addServer(ctx.uid, { imported: imported[0]! });
        return toolResult(`Added MCP server "${summary.name}" (${summary.transport}).`);
      } catch (err) {
        if (err instanceof ProRequiredError) {
          return toolResult(PRO_REQUIRED_MESSAGE, true);
        }
        if (err instanceof Error && err.message === "server_exists") {
          return toolResult("server_exists: an MCP server with that name already exists", true);
        }
        return toolResult(errorMessage(err), true);
      }
    },
  };

  const installMcpTool: McpAgentTool = {
    ...CATALOG_DEFS[2]!,
    async execute(args, ctx) {
      try {
        const name = args.server;
        if (typeof name !== "string" || name.trim() === "") {
          return toolResult("invalid_input: server must be a non-empty string", true);
        }
        const servers = await router.listServers(ctx.uid);
        const summary = servers.find(
          (server) =>
            server.id === name || server.name === name || server.curatedId === name,
        );
        if (summary === undefined) {
          return toolResult(`Unknown MCP server: ${name}`, true);
        }
        if (summary.curatedId === null) {
          const tier = await usersRepo.getTier(db, ctx.uid);
          if (tier === "free") return toolResult(PRO_REQUIRED_MESSAGE, true);
        }
        const listings = await router.listTools(ctx.uid);
        const count = listings.filter((listing) => listing.serverId === summary.id).length;
        return toolResult(
          `Connected ${summary.name}: ${count} tool${count === 1 ? "" : "s"} available.`,
        );
      } catch (err) {
        return gatedOrRethrow(err);
      }
    },
  };

  const installPluginTool: McpAgentTool = {
    ...CATALOG_DEFS[3]!,
    async execute(args, ctx) {
      try {
        const raw = args.source;
        if (typeof raw !== "string" || raw.trim() === "") {
          return toolResult("invalid_input: source must be a non-empty string", true);
        }
        let source: PluginSourceInput;
        try {
          source = parsePluginSource(raw);
        } catch (err) {
          return toolResult(errorMessage(err), true);
        }

        const tier = await usersRepo.getTier(db, ctx.uid);
        if (tier === "free") return toolResult(PRO_REQUIRED_MESSAGE, true);

        // I3: the row/job carry the manifest's canonical id, not a source
        // heuristic — the installer refuses any mismatch. A source that
        // cannot be resolved/adapted is a validation error (never enqueued).
        let pluginId: string;
        try {
          pluginId = await canonicalPluginId(resolver, source);
        } catch (err) {
          return toolResult(`invalid_source: ${errorMessage(err)}`, true);
        }

        const installId = randomUUID();
        // Queue status vocabulary (T15): queued → installing by the worker.
        await pluginsRepo.upsert(db, {
          userId: ctx.uid,
          pluginId,
          version: "0.0.0",
          source: source as unknown as Record<string, unknown>,
          status: "queued",
        });
        await queues.pluginInstalls.add(
          "plugin-install",
          {
            installId,
            userId: ctx.uid,
            pluginId,
            mode: "install",
            source,
          },
          { priority: tier === "free" ? 2 : 1, jobId: installId },
        );
        return toolResult(`Queued plugin install: ${pluginId} (install ${installId}).`);
      } catch (err) {
        return gatedOrRethrow(err);
      }
    },
  };

  return [listTool, addTool, installMcpTool, installPluginTool];
}
