import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import {
  ConnectionAdmissionError,
  createConnectionWithinCap,
  lockCustomConnectorCreates,
  mcpOauthTokens,
  mcpServers as mcpServersRepo,
  normalizeConnectionName,
  recordConnectionHealth,
  toMcpConnectionRow,
  transitionConnection,
  users,
  type ConnectionHealthEvidenceState,
  type Db,
  type McpConnectionRow,
  type McpServerRow,
  type TransitionConnectionPatch,
} from "@ovid/db";
import {
  ConnectionHealthError,
  CURATED_IDS,
  CURATED_MANIFEST,
  KNOWN_PROVIDER_IDS,
  defaultHealthOperationId,
  PRO_REQUIRED_MESSAGE,
  RESERVED_PROVIDER_NAMESPACES,
  parseMcpConfig,
  safeServerName,
  type ImportedMcp,
} from "@ovid/mcp";
import {
  planFor,
  type McpConnectionDto,
  type McpServerDto,
  type McpTransport,
  type ProviderAuthState,
  type ProviderHealthState,
} from "@ovid/shared";
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
    name: z.string().trim().min(1).max(200).optional(),
    // The whole object REPLACES the sealed blob (custom rows: {env?,
    // headers?}; curated rows: the flat credential map).
    secrets: z.record(z.string(), z.unknown()).optional(),
  })
  .strict();

const connectionHealthBodySchema = z.object({
  operationId: z.string().trim().min(1).max(128),
}).strict();

const connectionCreateBodySchema = z
  .object({
    providerId: z.string().trim().min(1).max(128),
    name: z.string().trim().min(1).max(200).optional(),
    transport: z.enum(["stdio", "http", "sse", "native"]).optional(),
    config: z.record(z.string(), z.unknown()).optional(),
    secrets: z.record(z.string(), z.unknown()).optional(),
    agentEnabled: z.boolean().optional(),
    approvedSourceId: z.string().trim().min(1).max(200).optional(),
    approvedDigest: z.string().regex(/^sha256:[0-9a-f]{64}$/).optional(),
  })
  .strict()
  .superRefine((body, context) => {
    if ((body.approvedSourceId === undefined) !== (body.approvedDigest === undefined)) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "approvedSourceId and approvedDigest must be provided together.",
      });
    }
  });

const connectionPatchBodySchema = z
  .object({
    enabled: z.boolean().optional(),
    agentEnabled: z.boolean().optional(),
    name: z.string().trim().min(1).max(200).optional(),
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

class CustomConnectorLimitError extends Error {
  constructor(readonly limit: number) {
    super(
      `Your plan includes ${limit} custom connector${limit === 1 ? "" : "s"}. Delete one before adding another.`,
    );
    this.name = "CustomConnectorLimitError";
  }
}

function assertCustomConnectorCapacity(
  tier: string | null,
  rows: McpServerRow[],
  adding: number,
): void {
  const limit = planFor(tier).customConnectors;
  const current = rows.filter((row) => row.curatedId === null).length;
  if (current + adding > limit) throw new CustomConnectorLimitError(limit);
}

/** Serialize a user's whole custom-create batch, then check its cap in the same transaction. */
async function withCustomConnectorLock<T>(
  deps: GatewayDeps,
  uid: string,
  work: (db: Db) => Promise<T>,
): Promise<T> {
  return deps.db.transaction(async (tx) => {
    const db = tx as unknown as Db;
    await lockCustomConnectorCreates(db, uid);
    return work(db);
  });
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

export interface ConnectionGenerationChange {
  connectionId: string;
  userId: string;
  configVersion: number;
  disconnectGeneration: number;
}

export interface ConnectionGenerationInvalidationListener {
  invalidate(change: ConnectionGenerationChange): void | Promise<void>;
}

/** Internal provider-probe input. None of these fields are projected in logs or DTOs. */
export interface ConnectionHealthProbeInput {
  connectionId: string;
  userId: string;
  providerId: string;
  transport: McpTransport;
  configVersion: number;
  disconnectGeneration: number;
  config: Record<string, unknown> | null;
  secrets?: Record<string, unknown>;
}

export interface ConnectionHealthAdapter {
  check(input: ConnectionHealthProbeInput): Promise<{ state: ConnectionHealthEvidenceState }>;
}

type McpConnectionRouteDeps = GatewayDeps & {
  connectionGenerationListener?: ConnectionGenerationInvalidationListener;
};

function providerIdOf(row: McpServerRow): string {
  return row.providerId ?? row.curatedId ?? "custom";
}

function requiredProviderKeys(providerId: string, secret?: boolean): readonly string[] {
  const fields = CURATED_MANIFEST.find((entry) => entry.curatedId === providerId)?.credentialFields ?? [];
  return fields
    .filter((field) => secret === undefined || field.secret === secret)
    .filter((field) => !/\boptional\b/i.test(field.label) && !/\bempty\s+means\b/i.test(field.hint ?? ""))
    .map((field) => field.key);
}

function hasRequiredValues(values: Record<string, unknown>, keys: readonly string[]): boolean {
  return keys.every((key) => {
    const value = values[key];
    return typeof value === "string" && value.trim() !== "";
  });
}

function hasSecretValue(secrets: Record<string, unknown> | undefined): boolean {
  return secrets !== undefined && Object.values(secrets).some((value) => {
    if (typeof value === "string") return value.trim() !== "";
    if (value === null || value === undefined) return false;
    if (typeof value === "object") return Object.keys(value).length > 0;
    return true;
  });
}

/** Evaluate the complete catalog connection contract, not just its secret half. */
function authStateForConnection(
  providerId: string,
  transport: McpTransport,
  config: Record<string, unknown> | undefined,
  secrets: Record<string, unknown> | undefined,
  oauthAuthorized = false,
): ProviderAuthState {
  const remote = transport === "http" || transport === "sse";
  if (CURATED_IDS.includes(providerId)) {
    const values = { ...(config ?? {}), ...(secrets ?? {}) };
    if (!hasRequiredValues(values, requiredProviderKeys(providerId, false))) return "missing";
    if (remote && oauthAuthorized) return "authorized";
    return hasRequiredValues(values, requiredProviderKeys(providerId, true))
      ? "configured"
      : "missing";
  }
  if (remote) {
    if (oauthAuthorized) return "authorized";
    return hasSecretValue(secrets) ? "configured" : "needs_auth";
  }
  return "configured";
}

function readSealedConnectionSecrets(
  deps: GatewayDeps,
  raw: McpServerRow,
): Record<string, unknown> | undefined {
  if (raw.secretsSealed === null || deps.crypto === undefined) return undefined;
  try {
    const parsed = JSON.parse(
      deps.crypto.decrypt(raw.secretsSealed, `mcp_servers:${raw.id}`),
    ) as unknown;
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return undefined;
    return parsed as Record<string, unknown>;
  } catch {
    return undefined;
  }
}

function toConnectionDto(
  row: McpConnectionRow,
  projection: {
    authState?: ProviderAuthState;
    healthState?: ProviderHealthState;
    lastCheckedAt?: string | null;
    lastSuccessAt?: string | null;
  } = {},
): McpConnectionDto {
  return {
    connectionId: row.connectionId,
    userId: row.userId,
    providerId: row.providerId,
    enabled: row.enabled,
    agentEnabled: row.agentEnabled,
    authState: projection.authState ?? row.authState,
    healthState: projection.healthState ?? row.healthState,
    lastCheckedAt: projection.lastCheckedAt === undefined ? row.lastCheckedAt : projection.lastCheckedAt,
    lastSuccessAt: projection.lastSuccessAt === undefined ? row.lastSuccessAt : projection.lastSuccessAt,
    configVersion: row.configVersion,
    disconnectGeneration: row.disconnectGeneration,
    ...(row.approvedSourceId !== undefined ? { approvedSourceId: row.approvedSourceId } : {}),
    ...(row.approvedDigest !== undefined ? { approvedDigest: row.approvedDigest } : {}),
    name: row.name,
    transport: row.transport,
    hasSecrets: row.secretsSealed !== null,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

async function connectionDtoFor(
  deps: GatewayDeps,
  raw: McpServerRow,
  uid: string,
): Promise<McpConnectionDto> {
  const row = toMcpConnectionRow(raw);
  let projectedAuth = row.authState;
  if (raw.authState === "unknown") {
    const remote = raw.transport === "http" || raw.transport === "sse";
    const token = remote ? await mcpOauthTokens.get(deps.db, raw.id, uid) : null;
    projectedAuth = authStateForConnection(
      providerIdOf(raw),
      raw.transport as McpTransport,
      raw.config ?? undefined,
      readSealedConnectionSecrets(deps, raw),
      token !== null,
    );
  }
  let projectedHealth = !raw.enabled && raw.healthState === "never_checked"
    ? "disabled"
    : row.healthState;
  let lastCheckedAt = row.lastCheckedAt;
  let lastSuccessAt = row.lastSuccessAt;
  if (deps.connectionHealthInvocations !== undefined) {
    const live = await deps.connectionHealthInvocations.getAuthenticated({
      principal: { uid, authenticated: true },
      connectionId: raw.id,
    });
    projectedHealth = live.healthState;
    lastCheckedAt = live.lastCheckedAt;
    lastSuccessAt = live.lastSuccessAt;
  }
  return toConnectionDto(row, {
    authState: projectedAuth,
    healthState: projectedHealth,
    lastCheckedAt,
    lastSuccessAt,
  });
}

/** Return only authentication facts established without a network health probe. */
async function activationAuthState(
  deps: GatewayDeps,
  raw: McpServerRow,
  uid: string,
): Promise<"configured" | "authorized" | null> {
  const row = toMcpConnectionRow(raw);
  if (row.authState === "revoked") return null;
  const remote = raw.transport === "http" || raw.transport === "sse";
  const oauth = remote ? await mcpOauthTokens.get(deps.db, raw.id, uid) : null;
  const projected = authStateForConnection(
    providerIdOf(raw),
    raw.transport as McpTransport,
    raw.config ?? undefined,
    readSealedConnectionSecrets(deps, raw),
    oauth !== null,
  );
  return projected === "configured" || projected === "authorized" ? projected : null;
}

function normalizeConfigKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, "");
}

const CATALOG_CREDENTIAL_CONFIG_KEYS = new Set(
  CURATED_MANIFEST.flatMap((entry) => entry.credentialFields)
    .filter((field) => field.secret)
    .map((field) => normalizeConfigKey(field.key)),
);
const DIRECT_CREDENTIAL_CONFIG_KEYS = new Set([
  "env",
  "header",
  "headers",
  "oauth",
  "authorization",
  "cookie",
  "cookies",
  "credential",
  "credentials",
  "password",
  "passwd",
  "privateKey",
  "secret",
  "secrets",
  "token",
  "refreshToken",
  "clientSecret",
].map(normalizeConfigKey));

function hasCredentialConfigKey(value: unknown, depth = 0): boolean {
  if (depth > 16) return true;
  if (Array.isArray(value)) return value.some((entry) => hasCredentialConfigKey(entry, depth + 1));
  if (value === null || typeof value !== "object") return false;
  return Object.entries(value).some(([key, entry]) => {
    const normalized = normalizeConfigKey(key);
    if (CATALOG_CREDENTIAL_CONFIG_KEYS.has(normalized) || DIRECT_CREDENTIAL_CONFIG_KEYS.has(normalized)) {
      return true;
    }
    return hasCredentialConfigKey(entry, depth + 1);
  });
}

function validateConnectionTransport(
  transport: McpTransport,
  config: Record<string, unknown> | undefined,
): string | null {
  if (transport === "stdio") {
    return typeof config?.command === "string" && config.command.length > 0
      ? null
      : "stdio connections require config.command.";
  }
  if (transport === "http" || transport === "sse") {
    return typeof config?.url === "string" && config.url.length > 0
      ? null
      : `${transport} connections require config.url.`;
  }
  return null;
}

async function notifyConnectionGeneration(
  deps: McpConnectionRouteDeps,
  row: Pick<McpConnectionRow, "connectionId" | "userId" | "configVersion" | "disconnectGeneration">,
): Promise<void> {
  try {
    await deps.connectionGenerationListener?.invalidate({
      connectionId: row.connectionId,
      userId: row.userId,
      configVersion: row.configVersion,
      disconnectGeneration: row.disconnectGeneration,
    });
  } catch {
    // The DB versions are the authoritative fence. Notification is only a
    // cache hint; never turn an already-committed mutation into a fake retry.
    deps.logger?.warn(
      {
        connectionId: row.connectionId,
        userId: row.userId,
        configVersion: row.configVersion,
        disconnectGeneration: row.disconnectGeneration,
      },
      "Connection generation listener failed; database fencing remains authoritative.",
    );
  }
}

function connectionChanged(reply: FastifyReply): FastifyReply {
  return sendError(reply, 409, "connection_changed", "The connection changed. Refresh and try again.");
}

function connectionHealthFailure(reply: FastifyReply, error: unknown): FastifyReply {
  if (error instanceof ConnectionHealthError && error.code === "not_found") return mcpNotFound(reply);
  if (error instanceof ConnectionHealthError && error.code === "connection_changed") return connectionChanged(reply);
  return sendError(reply, 503, "unavailable", "Connection health is temporarily unavailable.");
}

function connectionAdmissionFailure(reply: FastifyReply, error: unknown): FastifyReply {
  if (!(error instanceof ConnectionAdmissionError)) throw error;
  if (error.code === "server_exists") return serverExists(reply);
  if (error.code === "secret_sealing_unavailable") {
    return sendError(reply, 503, "unavailable", "MCP secret sealing is not configured.");
  }
  const limit = error.limit ?? 0;
  if (limit === 0) return sendError(reply, 402, "pro_required", PRO_REQUIRED_MESSAGE);
  return sendError(
    reply,
    403,
    "connector_limit_reached",
    `Your plan includes ${limit} custom connector${limit === 1 ? "" : "s"}. Delete one before adding another.`,
  );
}

/**
 * The model-facing namespace (`mcp__<safe name>__`) is reserved: a custom
 * server whose sanitized name collides with a curated id (or another custom
 * row) would shadow it, so creation is refused rather than silently
 * namespaced (Task 11 router parity).
 */
function reservedNamespaceTaken(name: string): boolean {
  const safe = safeServerName(name);
  return safe === "" || RESERVED_PROVIDER_NAMESPACES.has(safe);
}

function namespaceTaken(rows: McpServerRow[], name: string): boolean {
  if (reservedNamespaceTaken(name)) return true;
  const safe = safeServerName(name);
  return rows.some((row) => row.curatedId === null && safeServerName(row.name) === safe);
}

function renameAdmission(name: string | undefined): Pick<
  TransitionConnectionPatch,
  "name" | "isNamespaceReserved"
> {
  return name === undefined ? {} : { name, isNamespaceReserved: reservedNamespaceTaken };
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
  if (imported.oauth !== undefined) {
    // LOW-4: sealed for round-trip fidelity only — the OAuth flow always
    // performs discovery + DCR and does not consume a static client block.
    secrets.oauth = imported.oauth;
  }

  let row: McpServerRow;
  try {
    // Create + seal in ONE transaction: a sealing failure must not leave a
    // secrets_sealed = null row behind (a retry would then hit server_exists).
    // The recordId needs the generated row id: create, then seal.
    row = await deps.db.transaction(async (tx) => {
      const db = tx as unknown as Db;
      const created = await mcpServersRepo.create(db, {
        userId: uid,
        name: imported.name,
        transport: imported.transport,
        curatedId: null,
        config,
        secretsSealed: null,
      });
      if (Object.keys(secrets).length === 0) return created;
      // Caller guaranteed deps.crypto (the route refuses loudly otherwise).
      const sealed = deps.crypto!.encrypt(JSON.stringify(secrets), `mcp_servers:${created.id}`);
      const updated = await mcpServersRepo.update(db, created.id, uid, { secretsSealed: sealed });
      return updated ?? created;
    });
  } catch (err) {
    if (isUniqueViolation(err)) throw new Error("server_exists");
    throw err;
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
    // Create + seal in ONE transaction (see createCustom).
    row = await deps.db.transaction(async (tx) => {
      const db = tx as unknown as Db;
      const created = await mcpServersRepo.create(db, {
        userId: uid,
        name,
        transport: "native",
        curatedId,
        config: null,
        secretsSealed: null,
      });
      if (secrets === undefined) return created;
      // Curated credential rows seal the FLAT credential map — the router's
      // ctx.secrets contract (Task 11).
      const sealed = deps.crypto!.encrypt(JSON.stringify(secrets), `mcp_servers:${created.id}`);
      const updated = await mcpServersRepo.update(db, created.id, uid, { secretsSealed: sealed });
      return updated ?? created;
    });
  } catch (err) {
    if (isUniqueViolation(err)) throw new Error("server_exists");
    throw err;
  }
  return row;
}

export function registerMcpServerRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  const connectionDeps = deps as McpConnectionRouteDeps;

  app.post("/mcp/connections", async (request, reply) => {
    const parsed = connectionCreateBodySchema.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    // Plugin Task 12 must supply a real approved-source registry/admission
    // path. Until then these canonical fields are recognized but fail closed;
    // in particular they never fall through to arbitrary custom URL/config.
    if (parsed.data.approvedSourceId !== undefined) {
      return sendError(
        reply,
        503,
        "approved_source_unavailable",
        "Approved-source connection creation is not available.",
      );
    }
    if (parsed.data.secrets !== undefined && deps.crypto === undefined) {
      return sendError(reply, 503, "unavailable", "MCP secret sealing is not configured.");
    }
    const { uid } = request.principal;
    const providerId = parsed.data.providerId;
    const supported = CURATED_IDS.includes(providerId);
    if (!supported && KNOWN_PROVIDER_IDS.includes(providerId)) {
      return sendError(
        reply,
        409,
        "provider_unsupported",
        "This provider is known but is not supported for connection admission.",
      );
    }
    const kind = supported ? "curated" : "custom";
    const transport = parsed.data.transport ?? (kind === "curated" ? "native" : "http");
    if (kind === "curated" && transport !== "native") {
      return badRequest(reply, "Curated providers use their catalog-owned transport.");
    }
    if (hasCredentialConfigKey(parsed.data.config)) {
      return badRequest(reply, "Credential fields must be sent in secrets, not config.");
    }
    if (parsed.data.agentEnabled === true && kind === "custom") {
      return sendError(
        reply,
        409,
        "provider_unsupported",
        "This provider is not supported for agent activation.",
      );
    }
    const invalid = validateConnectionTransport(transport, parsed.data.config);
    if (invalid !== null) return badRequest(reply, invalid);

    const authState = authStateForConnection(
      providerId,
      transport,
      parsed.data.config,
      parsed.data.secrets,
    );
    if (parsed.data.agentEnabled === true) {
      // Creation is enabled by default; no request field can bypass that same
      // effective-enabled prerequisite enforced by PATCH.
      if (authState !== "configured" && authState !== "authorized") {
        return sendError(
          reply,
          409,
          "auth_required",
          "Provider authentication is required before agent activation.",
        );
      }
    }
    const name = parsed.data.name ??
      CURATED_MANIFEST.find((entry) => entry.curatedId === providerId)?.displayName ??
      providerId;
    if (kind === "custom" && reservedNamespaceTaken(name)) return serverExists(reply);

    try {
      const row = await createConnectionWithinCap(deps.db, {
        userId: uid,
        kind,
        providerId,
        name,
        normalizedConnectionName: normalizeConnectionName(name),
        transport,
        config: parsed.data.config ?? null,
        secrets: parsed.data.secrets,
        sealSecrets: parsed.data.secrets === undefined
          ? undefined
          : (plaintext, recordId) => deps.crypto!.encrypt(plaintext, recordId),
        agentEnabled: parsed.data.agentEnabled ?? false,
        authState,
      });
      return reply.code(201).send(toConnectionDto(row));
    } catch (error) {
      return connectionAdmissionFailure(reply, error);
    }
  });

  app.get("/mcp/connections", async (request) => {
    const { uid } = request.principal;
    const rows = await mcpServersRepo.list(deps.db, uid);
    return {
      contractVersion: 1 as const,
      items: await Promise.all(rows.map((row) => connectionDtoFor(deps, row, uid))),
    };
  });

  app.get("/mcp/connections/:id", async (request, reply) => {
    const { uid } = request.principal;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return mcpNotFound(reply);
    const row = await mcpServersRepo.get(deps.db, id, uid);
    if (row === null) return mcpNotFound(reply);
    return connectionDtoFor(deps, row, uid);
  });

  app.post("/mcp/connections/:id", async (request, reply) => {
    const { uid } = request.principal;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return mcpNotFound(reply);
    const raw = await mcpServersRepo.get(deps.db, id, uid);
    if (raw === null) return mcpNotFound(reply);

    if (deps.connectionHealthInvocations !== undefined) {
      let operationId = defaultHealthOperationId(providerIdOf(raw)) ?? "__unsupported__";
      if (request.body !== undefined) {
        const parsed = connectionHealthBodySchema.safeParse(request.body);
        if (!parsed.success) return zodBadRequest(reply, parsed.error);
        operationId = parsed.data.operationId;
      }
      try {
        const result = await deps.connectionHealthInvocations.checkAuthenticated({
          principal: { uid, authenticated: true },
          connectionId: id,
          operationId,
        });
        return toConnectionDto(toMcpConnectionRow(raw), {
          authState: result.connection.authState,
          healthState: result.to,
          lastCheckedAt: result.lastCheckedAt,
          lastSuccessAt: result.lastSuccessAt,
        });
      } catch (error) {
        return connectionHealthFailure(reply, error);
      }
    }

    if (request.body !== undefined) {
      return badRequest(reply, "The health check request body must be empty.");
    }

    const row = toMcpConnectionRow(raw);
    if (!row.enabled) {
      const dto = await connectionDtoFor(deps, raw, uid);
      return {
        ...dto,
        healthState: row.healthState === "revoked" ? "revoked" : "disabled",
      };
    }
    const expected = {
      configVersion: row.configVersion,
      disconnectGeneration: row.disconnectGeneration,
    };
    const record = async (state: ConnectionHealthEvidenceState) => {
      const checkedAt = connectionDeps.clock?.() ?? new Date();
      const updated = await recordConnectionHealth(deps.db, id, uid, expected, { state, checkedAt });
      if (updated === null) return connectionChanged(reply);
      // Re-read the raw row so legacy auth_state="unknown" uses exactly the
      // same sealed-credential/OAuth projection as GET and PATCH. Recheck the
      // fences so a mutation between the write and re-read cannot answer stale.
      const current = await mcpServersRepo.get(deps.db, id, uid);
      if (current === null) return mcpNotFound(reply);
      if (!current.enabled ||
          current.configVersion !== expected.configVersion ||
          current.disconnectGeneration !== expected.disconnectGeneration) {
        return connectionChanged(reply);
      }
      return reply.send(await connectionDtoFor(deps, current, uid));
    };

    const providerId = providerIdOf(raw);
    const supported = raw.curatedId !== null && CURATED_IDS.includes(providerId);
    // There is no generic ping fallback. Unsupported providers and compositions
    // without a real per-provider adapter both report an unavailable capability.
    if (!supported || connectionDeps.connectionHealth === undefined) {
      return record("unavailable");
    }
    const auth = await activationAuthState(deps, raw, uid);
    if (auth === null) return record("needs_auth");

    const secrets = readSealedConnectionSecrets(deps, raw);
    let state: ConnectionHealthEvidenceState;
    try {
      const result = await connectionDeps.connectionHealth.check({
        connectionId: id,
        userId: uid,
        providerId,
        transport: raw.transport as McpTransport,
        configVersion: row.configVersion,
        disconnectGeneration: row.disconnectGeneration,
        config: raw.config,
        ...(secrets !== undefined ? { secrets } : {}),
      });
      state = result.state;
    } catch {
      // Adapter errors can contain provider payloads or credentials. Log only
      // stable non-secret metadata and make no claim about provider health.
      deps.logger?.warn(
        { connectionId: id, userId: uid, providerId },
        "Connection health probe failed; reporting unavailable.",
      );
      state = "unavailable";
    }
    return record(state);
  });

  app.patch("/mcp/connections/:id", async (request, reply) => {
    const { uid } = request.principal;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return mcpNotFound(reply);
    const raw = await mcpServersRepo.get(deps.db, id, uid);
    if (raw === null) return mcpNotFound(reply);
    const parsed = connectionPatchBodySchema.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    if (parsed.data.secrets !== undefined && deps.crypto === undefined) {
      return sendError(reply, 503, "unavailable", "MCP secret sealing is not configured.");
    }

    let activationAuth: "configured" | "authorized" | null = null;
    const activationRequested = parsed.data.agentEnabled === true;
    const activeMutationRequiresAuth = (parsed.data.agentEnabled ?? raw.agentEnabled) &&
      (parsed.data.secrets !== undefined || parsed.data.enabled === true);
    if (activationRequested || activeMutationRequiresAuth) {
      const providerId = providerIdOf(raw);
      if (raw.curatedId === null || !CURATED_IDS.includes(providerId)) {
        return sendError(
          reply,
          409,
          "provider_unsupported",
          "This provider is not supported for agent activation.",
        );
      }
      if (!(parsed.data.enabled ?? raw.enabled)) {
        return sendError(reply, 409, "connection_disabled", "Enable the connection before agent activation.");
      }
      if (parsed.data.secrets !== undefined) {
        const oauth = await mcpOauthTokens.get(deps.db, raw.id, uid);
        const candidate = authStateForConnection(
          providerId,
          raw.transport as McpTransport,
          raw.config ?? undefined,
          parsed.data.secrets,
          oauth !== null,
        );
        activationAuth = candidate === "configured" || candidate === "authorized" ? candidate : null;
      } else {
        activationAuth = await activationAuthState(deps, raw, uid);
      }
      if (activationAuth === null) {
        return sendError(
          reply,
          409,
          "auth_required",
          "Provider authentication is required before agent activation.",
        );
      }
    }

    const patch: TransitionConnectionPatch = {
      enabled: parsed.data.enabled,
      agentEnabled: parsed.data.agentEnabled,
      ...renameAdmission(parsed.data.name),
    };
    if (parsed.data.secrets !== undefined) {
      patch.secrets = parsed.data.secrets;
      patch.sealSecrets = (plaintext, recordId) => deps.crypto!.encrypt(plaintext, recordId);
      const oauth = await mcpOauthTokens.get(deps.db, raw.id, uid);
      patch.authState = activationAuth ?? authStateForConnection(
        providerIdOf(raw),
        raw.transport as McpTransport,
        raw.config ?? undefined,
        parsed.data.secrets,
        oauth !== null,
      );
    }
    if (activationAuth !== null) patch.authState = activationAuth;

    try {
      const updated = await transitionConnection(deps.db, id, uid, patch, {
        configVersion: raw.configVersion,
        disconnectGeneration: raw.disconnectGeneration,
      });
      if (updated === null) return connectionChanged(reply);
      if (updated.configVersion !== raw.configVersion ||
          updated.disconnectGeneration !== raw.disconnectGeneration) {
        await notifyConnectionGeneration(connectionDeps, updated);
      }
      if (raw.authState === "unknown") {
        const current = await mcpServersRepo.get(deps.db, id, uid);
        if (current === null) return mcpNotFound(reply);
        return connectionDtoFor(deps, current, uid);
      }
      return toConnectionDto(updated);
    } catch (error) {
      return connectionAdmissionFailure(reply, error);
    }
  });

  app.delete("/mcp/connections/:id", async (request, reply) => {
    const { uid } = request.principal;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return mcpNotFound(reply);
    const raw = await mcpServersRepo.get(deps.db, id, uid);
    if (raw === null) return mcpNotFound(reply);
    if (deps.connectionHealthInvocations === undefined) {
      return sendError(reply, 503, "unavailable", "Connection disconnect is temporarily unavailable.");
    }
    // This gateway owns a separate OAuthFlow from the worker. Cancel its
    // token callbacks/readers before awaiting worker-owned disconnect cleanup.
    deps.oauth?.cancelRefreshes(uid, id);
    try {
      const disconnected = await deps.connectionHealthInvocations.disconnectAuthenticated({
        principal: { uid, authenticated: true },
        connectionId: id,
      });
      await notifyConnectionGeneration(connectionDeps, disconnected);
      return reply.code(204).send();
    } catch (error) {
      return connectionHealthFailure(reply, error);
    }
  });

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
      const tier = await users.getTier(deps.db, uid);
      if (planFor(tier).customConnectors === 0) {
        return sendError(reply, 402, "pro_required", PRO_REQUIRED_MESSAGE);
      }

      let imported: ImportedMcp[];
      try {
        // C1: NEVER interpolate against the gateway process env — a pasted
        // config is caller-controlled, and the gateway env holds
        // OVID_MASTER_KEY / DATABASE_URL / redis URLs. Unresolved `${VAR}`
        // stays literal for the credential gate.
        imported = parseMcpConfig(parsed.data.pasted, { env: {} });
      } catch {
        // ConfigParseError messages are value-free; never echo config bytes.
        return badRequest(reply, "The pasted MCP configuration could not be parsed.");
      }
      if (imported.length === 0) {
        return badRequest(reply, "The pasted MCP configuration declares no servers.");
      }

      try {
        const created = await withCustomConnectorLock(deps, uid, async (db) => {
          const scoped = { ...deps, db };
          assertCustomConnectorCapacity(
            tier,
            await mcpServersRepo.list(db, uid),
            imported.length,
          );
          const batch: McpServerDto[] = [];
          for (const entry of imported) {
            const row = await createCustom(scoped, uid, entry);
            batch.push(await dtoFor(scoped, row, uid));
          }
          return batch;
        });
        return reply.code(201).send(created);
      } catch (err) {
        if (err instanceof CustomConnectorLimitError) {
          return sendError(reply, 403, "connector_limit_reached", err.message);
        }
        if (err instanceof Error && err.message === "server_exists") return serverExists(reply);
        throw err;
      }
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
    const tier = await users.getTier(deps.db, uid);
    if (planFor(tier).customConnectors === 0) {
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
      const row = await withCustomConnectorLock(deps, uid, async (db) => {
        const scoped = { ...deps, db };
        assertCustomConnectorCapacity(tier, await mcpServersRepo.list(db, uid), 1);
        return createCustom(scoped, uid, imported);
      });
      return reply.code(201).send(await dtoFor(deps, row, uid));
    } catch (err) {
      if (err instanceof CustomConnectorLimitError) {
        return sendError(reply, 403, "connector_limit_reached", err.message);
      }
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

    // Ownership FIRST: a foreign/unknown id is always the same 404, even
    // when the body is malformed (the 404 must not depend on body validity).
    const row = await mcpServersRepo.get(deps.db, id, uid);
    if (row === null) return mcpNotFound(reply);

    const parsed = patchBodySchema.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    if (parsed.data.secrets !== undefined && deps.crypto === undefined) {
      return sendError(reply, 503, "unavailable", "MCP secret sealing is not configured.");
    }

    const activeMutationRequiresAuth = row.agentEnabled &&
      (parsed.data.secrets !== undefined || parsed.data.enabled === true);
    let candidateAuth: "configured" | "authorized" | null = null;
    if (activeMutationRequiresAuth) {
      const providerId = providerIdOf(row);
      if (row.curatedId === null || !CURATED_IDS.includes(providerId)) {
        return sendError(
          reply,
          409,
          "provider_unsupported",
          "This provider is not supported for agent activation.",
        );
      }
      if (parsed.data.secrets !== undefined) {
        const oauth = await mcpOauthTokens.get(deps.db, row.id, uid);
        const candidate = authStateForConnection(
          providerId,
          row.transport as McpTransport,
          row.config ?? undefined,
          parsed.data.secrets,
          oauth !== null,
        );
        candidateAuth = candidate === "configured" || candidate === "authorized" ? candidate : null;
      } else {
        candidateAuth = await activationAuthState(deps, row, uid);
      }
      if (candidateAuth === null) {
        return sendError(
          reply,
          409,
          "auth_required",
          "Provider authentication is required before agent activation.",
        );
      }
    }

    const patch: TransitionConnectionPatch = {
      enabled: parsed.data.enabled,
      ...renameAdmission(parsed.data.name),
    };
    if (candidateAuth !== null) patch.authState = candidateAuth;
    if (parsed.data.secrets !== undefined) {
      // REPLACE the sealed blob — never merge, never echo. Legacy writes use
      // the same generation fence as the v1 endpoint without changing its DTO.
      patch.secrets = parsed.data.secrets;
      patch.sealSecrets = (plaintext, recordId) => deps.crypto!.encrypt(plaintext, recordId);
      patch.authState = candidateAuth ?? authStateForConnection(
        providerIdOf(row),
        row.transport as McpTransport,
        row.config ?? undefined,
        parsed.data.secrets,
      );
    }

    try {
      const updated = await transitionConnection(deps.db, row.id, uid, patch, {
        configVersion: row.configVersion,
        disconnectGeneration: row.disconnectGeneration,
      });
      if (updated === null) return connectionChanged(reply);
      if (updated.configVersion !== row.configVersion ||
          updated.disconnectGeneration !== row.disconnectGeneration) {
        await notifyConnectionGeneration(connectionDeps, updated);
      }
      const current = await mcpServersRepo.get(deps.db, row.id, uid);
      if (current === null) return mcpNotFound(reply);
      return dtoFor(deps, current, uid);
    } catch (error) {
      return connectionAdmissionFailure(reply, error);
    }
  });

  app.delete("/mcp/servers/:id", async (request, reply) => {
    const { uid } = request.principal;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return mcpNotFound(reply);
    const row = await mcpServersRepo.get(deps.db, id, uid);
    if (row === null) return mcpNotFound(reply);
    if (deps.connectionHealthInvocations === undefined) {
      return sendError(reply, 503, "unavailable", "Connection disconnect is temporarily unavailable.");
    }
    // The gateway and worker own different OAuthFlow instances; abort this
    // process's callback/readers before worker disconnect and legacy removal.
    deps.oauth?.cancelRefreshes(uid, id);
    try {
      const disconnected = await deps.connectionHealthInvocations.disconnectAuthenticated({
        principal: { uid, authenticated: true },
        connectionId: id,
      });
      await notifyConnectionGeneration(connectionDeps, disconnected);
      // Only after worker-owned OAuth/transport cleanup may the legacy alias
      // remove the row. Wrong-owner/missing rows still return the same 404.
      const removed = await mcpServersRepo.remove(deps.db, id, uid);
      if (!removed) return mcpNotFound(reply);
      return reply.code(204).send();
    } catch (error) {
      return connectionHealthFailure(reply, error);
    }
  });
}
