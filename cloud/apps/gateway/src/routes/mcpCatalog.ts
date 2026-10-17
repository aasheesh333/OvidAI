import type { FastifyInstance } from "fastify";
import { mcpServers as mcpServersRepo } from "@ovid/db";
import { CURATED_MANIFEST } from "@ovid/mcp";
import type { CatalogServerDto } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";

/**
 * Curated MCP catalog (P5 Task 15) — pure data from CURATED_MANIFEST with the
 * caller's configured flags. No handler is instantiated and no credential
 * value is read: only the presence of a credential row is projected.
 */
export function registerMcpCatalogRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/mcp/catalog", async (request) => {
    const { uid } = request.principal;
    const rows = await mcpServersRepo.list(deps.db, uid);
    const configured = new Set(
      rows.map((row) => row.curatedId).filter((id): id is string => id !== null),
    );

    const items: CatalogServerDto[] = CURATED_MANIFEST.map((entry) => ({
      curatedId: entry.curatedId,
      displayName: entry.displayName,
      description: entry.description,
      credentialFields: entry.credentialFields.map((field) => ({
        key: field.key,
        label: field.label,
        secret: field.secret,
        ...(field.hint !== undefined ? { hint: field.hint } : {}),
      })),
      // Tool defs are served name+description only (input schemas are large
      // and belong to the runtime, not the catalog surface).
      tools: entry.tools.map((tool) => ({
        name: tool.name,
        ...(tool.description !== undefined ? { description: tool.description } : {}),
      })),
      configured: configured.has(entry.curatedId),
    }));

    return { items };
  });
}
