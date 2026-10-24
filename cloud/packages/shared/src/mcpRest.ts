// MCP + plugins REST DTOs (P5 Task 15) — the wire shapes served by the
// gateway's /cloud/v1/mcp/* and /cloud/v1/plugins/* routes. Pure DTOs + zod
// schemas only: row shapes live in @ovid/db, route behavior in the gateway,
// and the plugin-installs ENQUEUE contract (PluginInstallJob, the queue
// constants) lives in @ovid/queue — this module deliberately does not
// duplicate it.
//
// SECRET HYGIENE (binding): none of these DTOs ever carries a secrets blob,
// an envelope, a manifest, or a config VALUE. The mcp_servers row's
// secrets_sealed and the plugins row's config_sealed are opaque server-side
// columns; the DTO surface exposes only boolean projections (hasSecrets) and
// counts — a JSON.stringify of any response must never contain a credential.

import { z } from "zod";

/** One user-registered (or curated-configured) MCP server. */
export interface McpServerDto {
  id: string;
  name: string;
  transport: "stdio" | "http" | "sse" | "native";
  /** Curated catalog id when the row is a configured curated server. */
  curatedId: string | null;
  /** Remote endpoint (http/sse rows) — non-secret. */
  url?: string;
  /** Local command (stdio rows) — non-secret. */
  command?: string;
  enabled: boolean;
  /** True when a secrets envelope is stored (values never projected). */
  hasSecrets: boolean;
  /** True when the server needs an OAuth round-trip before it is usable. */
  needsAuth: boolean;
  createdAt: string;
  updatedAt: string;
}

export const mcpServerDtoSchema: z.ZodType<McpServerDto> = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  transport: z.enum(["stdio", "http", "sse", "native"]),
  curatedId: z.string().min(1).nullable(),
  url: z.string().optional(),
  command: z.string().optional(),
  enabled: z.boolean(),
  hasSecrets: z.boolean(),
  needsAuth: z.boolean(),
  createdAt: z.string().min(1),
  updatedAt: z.string().min(1),
});

export type McpTransport = "stdio" | "http" | "sse" | "native";
export type ProviderAuthState = "missing" | "configured" | "needs_auth" | "authorized" | "revoked";
export type ProviderHealthState =
  | "never_checked"
  | "checking"
  | "healthy"
  | "degraded"
  | "needs_auth"
  | "refreshing"
  | "revoked"
  | "unavailable"
  | "disabled";

/** Stable, secret-free connection state shared by persistence and the v1 API. */
export interface ProviderConnectionState {
  connectionId: string;
  userId: string;
  providerId: string;
  enabled: boolean;
  agentEnabled: boolean;
  authState: ProviderAuthState;
  healthState: ProviderHealthState;
  lastCheckedAt: string | null;
  lastSuccessAt: string | null;
  configVersion: number;
  disconnectGeneration: number;
  approvedSourceId?: string;
  approvedDigest?: string;
}

const providerConnectionStateShape = {
  connectionId: z.string().min(1),
  userId: z.string().min(1),
  providerId: z.string().min(1),
  enabled: z.boolean(),
  agentEnabled: z.boolean(),
  authState: z.enum(["missing", "configured", "needs_auth", "authorized", "revoked"]),
  healthState: z.enum([
    "never_checked",
    "checking",
    "healthy",
    "degraded",
    "needs_auth",
    "refreshing",
    "revoked",
    "unavailable",
    "disabled",
  ]),
  lastCheckedAt: z.string().min(1).nullable(),
  lastSuccessAt: z.string().min(1).nullable(),
  configVersion: z.number().int().nonnegative(),
  disconnectGeneration: z.number().int().nonnegative(),
  approvedSourceId: z.string().min(1).optional(),
  approvedDigest: z.string().min(1).optional(),
};

export const providerConnectionStateSchema: z.ZodType<ProviderConnectionState> = z
  .object(providerConnectionStateShape)
  .strict();

/** The v1 connection DTO deliberately does not extend the legacy server DTO. */
export interface McpConnectionDto extends ProviderConnectionState {
  name: string;
  transport: McpTransport;
  hasSecrets: boolean;
  createdAt: string;
  updatedAt: string;
}

export const mcpConnectionDtoSchema: z.ZodType<McpConnectionDto> = z
  .object({
    ...providerConnectionStateShape,
    name: z.string().min(1),
    transport: z.enum(["stdio", "http", "sse", "native"]),
    hasSecrets: z.boolean(),
    createdAt: z.string().min(1),
    updatedAt: z.string().min(1),
  })
  .strict();

export interface ConnectionEnvelope {
  contractVersion: 1;
  items: McpConnectionDto[];
}

export const connectionEnvelopeSchema: z.ZodType<ConnectionEnvelope> = z
  .object({
    contractVersion: z.literal(1),
    items: z.array(mcpConnectionDtoSchema),
  })
  .strict();

/** One curated catalog entry with the caller's configured flag. */
export interface CatalogServerDto {
  curatedId: string;
  displayName: string;
  description: string;
  credentialFields: { key: string; label: string; secret: boolean; hint?: string }[];
  tools: { name: string; description?: string }[];
  /** True when the caller already has an mcp_servers row for this entry. */
  configured: boolean;
}

export const catalogServerDtoSchema: z.ZodType<CatalogServerDto> = z.object({
  curatedId: z.string().min(1),
  displayName: z.string().min(1),
  description: z.string(),
  credentialFields: z.array(
    z.object({
      key: z.string().min(1),
      label: z.string().min(1),
      secret: z.boolean(),
      hint: z.string().optional(),
    }),
  ),
  tools: z.array(
    z.object({
      name: z.string().min(1),
      description: z.string().optional(),
    }),
  ),
  configured: z.boolean(),
});

/**
 * One installed plugin. The manifest and the sealed user config are NEVER
 * projected (Task 14 review carry: only capabilities, probeFailures, status
 * and a source label cross the wire); `status` passes the installer's full
 * vocabulary through verbatim, including `queued` (gateway-created row) and
 * `rolled_back` (refused transaction).
 */
export interface PluginDto {
  id: string;
  /** Canonical `publisher/name`. */
  pluginId: string;
  version: string;
  status: string;
  source: { kind: string; label: string };
  capabilities: string[];
  probeFailures: string[];
  installedAt: string;
  updatedAt: string;
}

export const pluginDtoSchema: z.ZodType<PluginDto> = z.object({
  id: z.string().min(1),
  pluginId: z.string().min(1),
  version: z.string().min(1),
  status: z.string().min(1),
  source: z.object({ kind: z.string().min(1), label: z.string().min(1) }),
  capabilities: z.array(z.string()),
  probeFailures: z.array(z.string()),
  installedAt: z.string().min(1),
  updatedAt: z.string().min(1),
});

/** POST /plugins/install and DELETE /plugins/:id answer (202). */
export interface PluginInstallResponse {
  installId: string;
  status: "queued";
}

export const pluginInstallResponseSchema: z.ZodType<PluginInstallResponse> = z.object({
  installId: z.string().min(1),
  status: z.literal("queued"),
});

/**
 * POST /cloud/v1/system/responses body — the REST answer path for ANY
 * pending system-channel request (spec §6.2 "client answers via REST/WS";
 * the WS `system_response` frame carries the same shape). The payload is
 * opaquely forwarded: approval cards answer
 * `{approve: boolean, allowDependencyScripts?: boolean}` (the worker↔client
 * contract pinned by the Task 14 installer — deny/timeout equivalence is
 * enforced on the worker side), sampling/elicitation their own shapes.
 */
export interface SystemResponseBody {
  id: string;
  payload: Record<string, unknown>;
}

export const systemResponseBodySchema: z.ZodType<SystemResponseBody> = z
  .object({
    id: z.string().min(1),
    payload: z.record(z.string(), z.unknown()),
  })
  .strict();
