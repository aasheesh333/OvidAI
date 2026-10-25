/** Lazy, run-local connector discovery/schema tools and typed operation dispatch. */

import {
  discoverIntegrations,
  loadIntegrationSchema,
  schemaBudgetFor,
  type DiscoveryQuery,
  type McpRouter,
} from "@ovid/mcp";
import {
  callMcpOperation,
  type McpAgentTool,
  type McpToolContext,
  type McpToolProvider,
  type McpToolProviderOptions,
  type ToolResult,
} from "./mcpTools.js";
import type { ModelToolSpec } from "./tools/types.js";

function jsonResult(value: unknown, isError = false): ToolResult {
  return { content: JSON.stringify(value), isError };
}

function invalidInput(message: string): ToolResult {
  return jsonResult({ code: "invalid_input", message }, true);
}

function unavailable(): ToolResult {
  return jsonResult({ code: "unavailable" }, true);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOnlyKeys(args: Record<string, unknown>, allowed: readonly string[]): boolean {
  return Object.keys(args).every((key) => allowed.includes(key));
}

function boundedString(value: unknown, maxLength: number): value is string {
  return typeof value === "string" && value.trim() !== "" && value.length <= maxLength;
}

function discoveryQuery(args: Record<string, unknown>): DiscoveryQuery | null {
  if (!isRecord(args) || !hasOnlyKeys(args, ["query", "providerId"])) return null;
  if (args.query !== undefined && (typeof args.query !== "string" || args.query.length > 512)) return null;
  if (args.providerId !== undefined && !boundedString(args.providerId, 128)) return null;
  return {
    ...(args.query !== undefined ? { query: args.query as string } : {}),
    ...(args.providerId !== undefined ? { providerId: args.providerId as string } : {}),
  };
}

function schemaRequest(args: Record<string, unknown>): {
  connectionId: string;
  operationIds: string[];
} | null {
  if (!isRecord(args) || !hasOnlyKeys(args, ["connectionId", "operationIds"]) ||
      !boundedString(args.connectionId, 256) || !Array.isArray(args.operationIds) ||
      args.operationIds.length === 0 || args.operationIds.length > 12 ||
      !args.operationIds.every((operationId) => boundedString(operationId, 128))) {
    return null;
  }
  return { connectionId: args.connectionId, operationIds: [...args.operationIds] };
}

function callRequest(args: Record<string, unknown>): {
  connectionId: string;
  operationId: string;
  args: Record<string, unknown>;
} | null {
  if (!isRecord(args) || !hasOnlyKeys(args, ["connectionId", "operationId", "args"]) ||
      !boundedString(args.connectionId, 256) || !boundedString(args.operationId, 128) ||
      !isRecord(args.args)) {
    return null;
  }
  return {
    connectionId: args.connectionId,
    operationId: args.operationId,
    args: args.args,
  };
}

/**
 * The initial roster is constant-sized: no per-operation schema is read here.
 * A generic call is required after schema discovery because the old per-operation
 * tools are deliberately absent; it still uses the exact snapshot/revalidation
 * and typed router execution path before any lazy connection can occur.
 */
export function createConnectorDiscoveryTools(
  router: McpRouter,
  opts: McpToolProviderOptions,
): McpAgentTool[] {
  const discover: McpAgentTool = {
    name: "integration_discover",
    description: "Search activated provider operation summaries without loading their schemas.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string", maxLength: 512 },
        providerId: { type: "string", minLength: 1, maxLength: 128 },
      },
      additionalProperties: false,
      maxProperties: 2,
    },
    async execute(args, ctx) {
      const query = discoveryQuery(args);
      if (query === null) return invalidInput("expected optional query and providerId");
      try {
        const snapshot = await opts.snapshotFor(ctx);
        if (snapshot === null) return jsonResult({ code: "denied", results: [] }, true);
        return jsonResult(discoverIntegrations(snapshot, query, schemaBudgetFor(ctx.isSubagent)));
      } catch {
        return unavailable();
      }
    },
  };

  const schema: McpAgentTool = {
    name: "integration_schema",
    description: "Load complete schemas for selected operations in this run, within its schema budget.",
    parameters: {
      type: "object",
      properties: {
        connectionId: { type: "string", minLength: 1, maxLength: 256 },
        operationIds: {
          type: "array",
          items: { type: "string", minLength: 1, maxLength: 128 },
          minItems: 1,
          maxItems: 12,
        },
      },
      required: ["connectionId", "operationIds"],
      additionalProperties: false,
      maxProperties: 2,
    },
    async execute(args, ctx) {
      const request = schemaRequest(args);
      if (request === null) return invalidInput("expected connectionId and 1-12 operationIds");
      try {
        const snapshot = await opts.snapshotFor(ctx);
        if (snapshot === null) return jsonResult({ code: "denied", loaded: [] }, true);
        const result = loadIntegrationSchema(snapshot, request, schemaBudgetFor(ctx.isSubagent));
        return jsonResult(result, result.code === "denied");
      } catch {
        return unavailable();
      }
    },
  };

  const call: McpAgentTool = {
    name: "integration_call",
    description: "Call one activated operation by connection and operation ID; inspect its schema first.",
    parameters: {
      type: "object",
      properties: {
        connectionId: { type: "string", minLength: 1, maxLength: 256 },
        operationId: { type: "string", minLength: 1, maxLength: 128 },
        args: { type: "object" },
      },
      required: ["connectionId", "operationId", "args"],
      additionalProperties: false,
      maxProperties: 3,
    },
    async execute(args, ctx: McpToolContext) {
      const request = callRequest(args);
      if (request === null) return invalidInput("expected connectionId, operationId, and object args");
      return callMcpOperation(router, request, request.args, ctx, opts);
    },
  };

  return [discover, schema, call];
}

/** The lazy replacement for the legacy eager per-operation provider. */
export function createConnectorDiscoveryToolProvider(
  router: McpRouter,
  opts: McpToolProviderOptions,
): McpToolProvider {
  const provider: McpToolProvider = {
    async tools(_snapshot) {
      return createConnectorDiscoveryTools(router, opts);
    },
    async specs(snapshot): Promise<ModelToolSpec[]> {
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
