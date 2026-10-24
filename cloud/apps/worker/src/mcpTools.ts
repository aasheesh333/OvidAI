/** Snapshot-only MCP/provider adapters and read-only catalog discovery. */

import type { Db } from "@ovid/db";
import {
  PRO_REQUIRED_MESSAGE,
  ProRequiredError,
  type ActivatedOperation,
  type McpRouter,
  type McpServerSummary,
  type PluginInstallJob,
  type PluginSourceInput,
  type RunContext,
  type RunMcpSnapshot,
  type RunPolicy,
  type SamplingRequest,
  type SamplingResult,
  type SourceResolver,
  type ToolContext as ProviderToolContext,
} from "@ovid/mcp";
import { pluginSourceInputSchema } from "@ovid/shared";
import type { ModelToolSpec } from "./tools/types.js";

export interface ToolResult {
  content: string;
  isError?: boolean;
  artifacts?: unknown[];
}

/** Canonical ToolContext plus MCP's uid spelling and provider approval access. */
export interface McpToolContext extends RunPolicy {
  uid: string;
  sessionId: string;
  runId: string;
  isSubagent: boolean;
  depth: number;
  callKey: string;
  signal: AbortSignal;
  approveProvider?: ProviderToolContext["approveProvider"];
  sampler?: (req: SamplingRequest) => Promise<SamplingResult | null>;
}

export interface McpAgentTool {
  readonly name: string;
  readonly description: string;
  readonly parameters: Record<string, unknown>;
  execute(args: Record<string, unknown>, ctx: McpToolContext): Promise<ToolResult>;
}

export interface McpToolProvider {
  tools(snapshot: RunMcpSnapshot): Promise<McpAgentTool[]>;
  specs(snapshot: RunMcpSnapshot): Promise<ModelToolSpec[]>;
}

export interface McpToolProviderOptions {
  /** Resolves the exact root/child snapshot for THIS call, never a global roster. */
  snapshotFor(ctx: McpToolContext): Promise<RunMcpSnapshot | null>;
  /** Task 1's current-row/config/disconnect fence, invoked on every dispatch. */
  revalidate(
    snapshot: RunMcpSnapshot,
    call: { connectionId: string; operationId: string },
  ): Promise<"current" | "stale" | "denied">;
  samplerFor?: (
    ctx: McpToolContext,
  ) => ((req: SamplingRequest) => Promise<SamplingResult | null>) | undefined;
}

function byName(a: { name: string }, b: { name: string }): number {
  return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
}

function toolResult(content: string, isError = false): ToolResult {
  return isError ? { content, isError: true } : { content, isError: false };
}

function runContext(
  ctx: McpToolContext,
  operation: ActivatedOperation,
  samplerFor?: McpToolProviderOptions["samplerFor"],
): RunContext {
  const sampler = samplerFor?.(ctx) ?? ctx.sampler;
  return {
    sessionId: ctx.sessionId,
    runId: ctx.runId,
    userId: ctx.uid,
    connectionId: operation.connectionId,
    providerId: operation.providerId,
    mode: ctx.mode,
    planMode: ctx.planMode,
    unattended: ctx.unattended,
    isSubagent: ctx.isSubagent,
    depth: ctx.depth,
    callKey: ctx.callKey,
    signal: ctx.signal,
    ...(ctx.approveProvider !== undefined ? { approveProvider: ctx.approveProvider } : {}),
    ...(sampler !== undefined ? { sampler } : {}),
  } as RunContext;
}

function gatedOrRethrow(err: unknown): ToolResult {
  if (err instanceof ProRequiredError) return toolResult(PRO_REQUIRED_MESSAGE, true);
  const code = (err as { code?: unknown } | null)?.code;
  if (code === "sandbox_unavailable") {
    return toolResult(err instanceof Error ? err.message : String(err), true);
  }
  throw err;
}

function toolForOperation(
  router: McpRouter,
  activated: ActivatedOperation,
  opts: McpToolProviderOptions,
): McpAgentTool {
  return {
    name: activated.modelName,
    description: activated.definition.description,
    parameters: activated.definition.inputSchema,
    async execute(args, ctx) {
      try {
        const current = await opts.snapshotFor(ctx);
        const operation = current?.operations.find(
          (candidate) => candidate.modelName === activated.modelName &&
            candidate.connectionId === activated.connectionId &&
            candidate.operationId === activated.operationId,
        );
        if (current === null || current === undefined || operation === undefined) {
          return toolResult(`DENIED: ${activated.modelName} is not available in this run.`, true);
        }
        const verdict = await opts.revalidate(current, {
          connectionId: operation.connectionId,
          operationId: operation.operationId,
        });
        if (verdict !== "current") {
          return toolResult(
            verdict === "stale"
              ? `DENIED: ${activated.modelName} is stale.`
              : `DENIED: ${activated.modelName} is not available in this run.`,
            true,
          );
        }
        const result = await router.callTool(
          ctx.uid,
          operation.modelName,
          args,
          runContext(ctx, operation, opts.samplerFor),
        );
        return toolResult(result.text, result.isError);
      } catch (err) {
        if (err instanceof ProRequiredError ||
            (err as { code?: unknown } | null)?.code === "sandbox_unavailable") {
          return gatedOrRethrow(err);
        }
        return toolResult("Provider operation failed.", true);
      }
    },
  };
}

export function createMcpToolProvider(
  router: McpRouter,
  opts: McpToolProviderOptions,
): McpToolProvider {
  const provider: McpToolProvider = {
    async tools(snapshot) {
      return [...snapshot.operations]
        .sort((a, b) => byName({ name: a.modelName }, { name: b.modelName }))
        .map((operation) => toolForOperation(router, operation, opts));
    },
    async specs(snapshot) {
      const tools = await provider.tools(snapshot);
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

/** Kept as a structural export for the existing worker barrel; no model tool enqueues installs. */
export interface PluginInstallQueue {
  add(
    name: string,
    data: PluginInstallJob,
    opts?: { priority?: number; jobId?: string },
  ): Promise<unknown>;
}

export interface CatalogToolDeps {
  router: McpRouter;
  /** Legacy caller fields are optional and unused by read-only discovery. */
  db?: Db;
  queues?: { pluginInstalls: PluginInstallQueue };
  resolver?: Pick<SourceResolver, "resolve">;
}

const LIST_SCOPE = { type: "string", enum: ["curated", "custom", "all"] } as const;
const CATALOG_DEFS: ReadonlyArray<Pick<McpAgentTool, "name" | "description" | "parameters">> = [
  {
    name: "catalog_list_mcp",
    description:
      "List MCP servers available to this user. scope: curated (built-in), custom (user-added), or all. Read-only.",
    parameters: {
      type: "object",
      properties: {
        scope: { ...LIST_SCOPE, description: "Which servers to list (default: all)." },
      },
      additionalProperties: false,
    },
  },
];

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

/** Public source parser retained for authenticated, non-model callers. */
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

export function createCatalogTools(deps: CatalogToolDeps): McpAgentTool[] {
  // Referenced only to keep legacy structural consumers type-compatible; no
  // database writes, queue operations or source resolution occur here.
  void deps.db;
  void deps.queues;
  void deps.resolver;
  return [{
    ...CATALOG_DEFS[0]!,
    async execute(args, ctx) {
      try {
        const scope = parseScope(args.scope);
        if (scope === null) {
          return toolResult('invalid_input: scope must be "curated", "custom" or "all"', true);
        }
        const servers = await deps.router.listServers(ctx.uid);
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
  }];
}
