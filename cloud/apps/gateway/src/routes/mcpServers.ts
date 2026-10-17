import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import {
  mcpOauthTokens,
  mcpServers as mcpServersRepo,
  users,
  type McpServerRow,
} from "@ovid/db";
import {
  CURATED_IDS,
  PRO_REQUIRED_MESSAGE,
  parseMcpConfig,
  safeServerName,
  type ImportedMcp,
} from "@ovid/mcp";
import type { McpServerDto } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { badRequest, isUuid, notFound, sendError, zodBadRequest } from "./http.js";

/**
 * MCP server CRUD (P5 Task 15).
 *
 *  - Custom servers are a Pro feature (tier read at request time; the router
 *    re-checks it at every dispatch point — this REST gate is UX, not the
 *    security boundary).
 *  - Curated credential rows are available to EVERY tier: the curated server
 *    itself is shared, only the user's credentials are stored.
 *  - Secret material (env, headers, oauth credentials, curated credential
 *    maps) is sealed under the pinned recordId `mcp_servers:{row.id}`. It is
 *    never written to a plaintext column and never projected in a DTO.
 *  - Wrong owner and unknown id are the same 404 (never 403).
 */

const secretMap = z.record(z.string(), z.string());

const customBodySchema = z
  .object({
    name: z.string().trim().min(1).max(200),
    transport: z.enum(["stdio", "http", "sse"]),
    url: z.string().min(1).optional(),
    command: z.string().min(1).optional(),
    args: z.array(z.string()).optional(),
    cwd: z.string().min(1).optional(),
    env: secretMap.optional(),
    headers: secretMap.optional(),
  })
  .strict();

const pastedBodySchema = z
  .object({
    pasted: z.string().min(1),
  })
  .strict();

const curatedBodySchema = z
  .object({
    curatedId: z.string().min(1),
    name: z.string().trim().min(1).max(200).optional(),
    secrets: secretMap.optional(),
  })
  .strict();

const patchBodySchema = z
  .object({
    enabled: z.boolean().optional(),
    // The whole object REPLACES the sealed blob (custom rows: {env?,
    // headers?}; curated rows: the flat credential map).
    secrets: z.record(z.string(), z.unknown()).optional(),
  })
  .strict();

const MCP_SERVER_NOT_FOUND = "MCP server not found.";
const SERVER_EXISTS = "An MCP server with this name already exists.";

function mcpNotFound(reply: FastifyReply): FastifyReply {
  return notFound(reply, MCP_SERVER_NOT_FOUND);
}

function serverExists(reply: FastifyReply): FastifyReply {
  return sendError(reply, 409, "server_exists", SERVER_EXISTS);
}

/** Detects PostgreSQL unique-violation (23505) through drizzle's error wrap. */
function isUniqueViolation(err: unknown): boolean {
  let e: unknown = err;
  for (let depth = 0; e instanceof Error && depth < 5; depth++) {
    if ((e as { code?: string }).code === "23505") return true;
    if (/duplicate key|unique constraint/i.test(e.message)) return true;
    e = (e as { cause?: unknown }).cause;
  }
  return false;
}

function configOf(row: McpServerRow): Record<string, unknown> {
  return (row.config ?? {}) as Record<string, unknown>;
}

/**
 * `needsAuth` is a transport projection: a remote server without a stored
 * OAuth token set needs an authorization round-trip before use. Native and
 * stdio servers never do.
 */
async function needsAuthFor(deps: GatewayDeps, row: McpServerRow, uid: string): Promise<boolean> {
  if (row.transport !== "http" && row.transport !== "sse") return false;
  const token = await mcpOauthTokens.get(deps.db, row.id, uid);
  return token === null;
}

function toDto(row: McpServerRow, needsAuth: boolean): McpServerDto {
  const config = configOf(row);
  return {
    id: row.id,
    name: row.name,
    transport: row.transport as McpServerDto["transport"],
    curatedId: row.curatedId,
    ...(typeof config.url === "string" ? { url: config.url } : {}),
    ...(typeof config.command === "string" ? { command: config.command } : {}),
    enabled: row.enabled,
    hasSecrets: row.secretsSealed !== null,
    needsAuth,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

async function dtoFor(deps: GatewayDeps, row: McpServerRow, uid: string): Promise<McpServerDto> {
  return toDto(row, await needsAuthFor(deps, row, uid));
}

/**
 * The model-facing namespace (`mcp__<safe name>__`) is reserved: a custom
 * server whose sanitized name collides with a curated id (or another custom
 * row) would shadow it, so creation is refused rather than silently
 * namespaced (Task 11 router parity).
 */
function namespaceTaken(rows: McpServerRow[], name: string): boolean {
  const safe = safeServerName(name);
  if (CURATED_IDS.some((id) => safeServerName(id) === safe)) return true;
  return rows.some((row) => row.curatedId === null && safeServerName(row.name) === safe);
}

function validateTransport(body: z.infer<typeof customBodySchema>): string | null {
  if (body.transport === "stdio") {
    return body.command === undefined ? "stdio servers require a command." : null;
  }
  return body.url === undefined ? `${body.transport} servers require a url.` : null;
}

/** Create a custom (or pasted) server row, sealing any secrets it carries. */
async function createCustom(
  deps: GatewayDeps,
  uid: string,
  imported: ImportedMcp,
): Promise<McpServerRow> {
  const rows = await mcpServersRepo.list(deps.db, uid);
  if (rows.some((row) => row.name === imported.name) || namespaceTaken(rows, imported.name)) {
    throw new Error("server_exists");
  }

  const config: Record<string, unknown> = { type: imported.transport };
  if (imported.url !== undefined) config.url = imported.url;
  if (imported.command !== undefined) config.command = imported.command;
  if (imported.args !== undefined) config.args = [...imported.args];
  if (imported.cwd !== undefined) config.cwd = imported.cwd;

  const secrets: Record<string, unknown> = {};
  if (imported.env !== undefined && Object.keys(imported.env).length > 0) {
    secrets.env = imported.env;
  }
  if (imported.headers !== undefined && Object.keys(imported.headers).length > 0) {
    secrets.headers = imported.headers;
  }
  if (imported.oauth !== undefined) secrets.oauth = imported.oauth;

  let row: McpServerRow;
  try {
    row = await mcpServersRepo.create(deps.db, {
      userId: uid,
      name: imported.name,
      transport: imported.transport,
      curatedId: null,
      config,
      // The recordId needs the generated row id: create, then seal.
      secretsSealed: null,
    });
  } catch (err) {
    if (isUniqueViolation(err)) throw new Error("server_exists");
    throw err;
  }

  if (Object.keys(secrets).length > 0) {
    // Caller guaranteed deps.crypto (the route refuses loudly otherwise).
    const sealed = deps.crypto!.encrypt(JSON.stringify(secrets), `mcp_servers:${row.id}`);
    const updated = await mcpServersRepo.update(deps.db, row.id, uid, { secretsSealed: sealed });
    if (updated !== null) row = updated;
  }
  return row;
}

async function createCurated(
  deps: GatewayDeps,
  uid: string,
  curatedId: string,
  name: string,
  secrets: Record<string, string> | undefined,
): Promise<McpServerRow> {
  if (!CURATED_IDS.includes(curatedId)) throw new Error("unknown_curated_id");
  const rows = await mcpServersRepo.list(deps.db, uid);
  if (
    rows.some((row) => row.curatedId === curatedId) ||
    rows.some((row) => row.name === name)
  ) {
    throw new Error("server_exists");
  }

  let row: McpServerRow;
  try {
    row = await mcpServersRepo.create(deps.db, {
      userId: uid,
      name,
      transport: "native",
      curatedId,
      config: null,
      secretsSealed: null,
    });
  } catch (err) {
    if (isUniqueViolation(err)) throw new Error("server_exists");
    throw err;
  }

  if (secrets !== undefined) {
    // Curated credential rows seal the FLAT credential map — the router's
    // ctx.secrets contract (Task 11).
    const sealed = deps.crypto!.encrypt(JSON.stringify(secrets), `mcp_servers:${row.id}`);
    const updated = await mcpServersRepo.update(deps.db, row.id, uid, { secretsSealed: sealed });
    if (updated !== null) row = updated;
  }
  return row;
}

export function registerMcpServerRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.post("/mcp/servers", async (request, reply) => {
    const { uid } = request.principal;
    const body = request.body as unknown;
    if (body === null || typeof body !== "object" || Array.isArray(body)) {
      return badRequest(reply, "Invalid request body.");
    }
    const record = body as Record<string, unknown>;

    // ── pasted .mcp.json / config.toml (custom, Pro-only) ────────────────
    if (record.pasted !== undefined) {
      const parsed = pastedBodySchema.safeParse(body);
      if (!parsed.success) return zodBadRequest(reply, parsed.error);
      if (deps.crypto === undefined) {
        return sendError(reply, 503, "unavailable", "MCP secret sealing is not configured.");
      }
      if ((await users.getTier(deps.db, uid)) === "free") {
        return sendError(reply, 402, "pro_required", PRO_REQUIRED_MESSAGE);
      }

      let imported: ImportedMcp[];
      try {
        imported = parseMcpConfig(parsed.data.pasted);
      } catch {
        // ConfigParseError messages are value-free; never echo config bytes.
        return badRequest(reply, "The pasted MCP configuration could not be parsed.");
      }
      if (imported.length === 0) {
        return badRequest(reply, "The pasted MCP configuration declares no servers.");
      }

      const created: McpServerDto[] = [];
      try {
        for (const entry of imported) {
          const row = await createCustom(deps, uid, entry);
          created.push(await dtoFor(deps, row, uid));
        }
      } catch (err) {
        if (err instanceof Error && err.message === "server_exists") return serverExists(reply);
        throw err;
      }
      return reply.code(201).send(created);
    }

    // ── curated credential row (ALL tiers) ───────────────────────────────
    if (record.curatedId !== undefined) {
      const parsed = curatedBodySchema.safeParse(body);
      if (!parsed.success) return zodBadRequest(reply, parsed.error);
      if (parsed.data.secrets !== undefined && deps.crypto === undefined) {
        return sendError(reply, 503, "unavailable", "MCP secret sealing is not configured.");
      }
      try {
        const row = await createCurated(
          deps,
          uid,
          parsed.data.curatedId,
          parsed.data.name ?? parsed.data.curatedId,
          parsed.data.secrets,
        );
        return reply.code(201).send(await dtoFor(deps, row, uid));
      } catch (err) {
        if (err instanceof Error && err.message === "server_exists") return serverExists(reply);
        if (err instanceof Error && err.message === "unknown_curated_id") {
          return badRequest(reply, "Unknown curated server.");
        }
        throw err;
      }
    }

    // ── custom server (Pro-only) ─────────────────────────────────────────
    const parsed = customBodySchema.safeParse(body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    if (deps.crypto === undefined) {
      return sendError(reply, 503, "unavailable", "MCP secret sealing is not configured.");
    }
    const invalid = validateTransport(parsed.data);
    if (invalid !== null) return badRequest(reply, invalid);
    if ((await users.getTier(deps.db, uid)) === "free") {
      return sendError(reply, 402, "pro_required", PRO_REQUIRED_MESSAGE);
    }

    const imported: ImportedMcp = {
      name: parsed.data.name,
      transport: parsed.data.transport,
      ...(parsed.data.url !== undefined ? { url: parsed.data.url } : {}),
      ...(parsed.data.command !== undefined ? { command: parsed.data.command } : {}),
      ...(parsed.data.args !== undefined ? { args: parsed.data.args } : {}),
      ...(parsed.data.cwd !== undefined ? { cwd: parsed.data.cwd } : {}),
      ...(parsed.data.env !== undefined ? { env: parsed.data.env } : {}),
      ...(parsed.data.headers !== undefined ? { headers: parsed.data.headers } : {}),
    };

    try {
      const row = await createCustom(deps, uid, imported);
      return reply.code(201).send(await dtoFor(deps, row, uid));
    } catch (err) {
      if (err instanceof Error && err.message === "server_exists") return serverExists(reply);
      throw err;
    }
  });

  app.get("/mcp/servers", async (request) => {
    const { uid } = request.principal;
    const rows = await mcpServersRepo.list(deps.db, uid);
    return Promise.all(rows.map((row) => dtoFor(deps, row, uid)));
  });

  app.get("/mcp/servers/:id", async (request, reply) => {
    const { uid } = request.principal;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return mcpNotFound(reply);
    const row = await mcpServersRepo.get(deps.db, id, uid);
    if (row === null) return mcpNotFound(reply);
    return dtoFor(deps, row, uid);
  });

  app.patch("/mcp/servers/:id", async (request, reply) => {
    const { uid } = request.principal;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return mcpNotFound(reply);

    const parsed = patchBodySchema.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    if (parsed.data.secrets !== undefined && deps.crypto === undefined) {
      return sendError(reply, 503, "unavailable", "MCP secret sealing is not configured.");
    }

    const row = await mcpServersRepo.get(deps.db, id, uid);
    if (row === null) return mcpNotFound(reply);

    const patch: { enabled?: boolean; secretsSealed?: ReturnType<NonNullable<GatewayDeps["crypto"]>["encrypt"]> } = {};
    if (parsed.data.enabled !== undefined) patch.enabled = parsed.data.enabled;
    if (parsed.data.secrets !== undefined) {
      // REPLACE the sealed blob — never merge, never echo.
      patch.secretsSealed = deps.crypto!.encrypt(
        JSON.stringify(parsed.data.secrets),
        `mcp_servers:${row.id}`,
      );
    }

    const updated = await mcpServersRepo.update(deps.db, row.id, uid, patch);
    if (updated === null) return mcpNotFound(reply);
    return dtoFor(deps, updated, uid);
  });

  app.delete("/mcp/servers/:id", async (request, reply) => {
    const { uid } = request.principal;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return mcpNotFound(reply);
    const removed = await mcpServersRepo.remove(deps.db, id, uid);
    if (!removed) return mcpNotFound(reply);
    return reply.code(204).send();
  });
}
