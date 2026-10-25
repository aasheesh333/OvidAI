import { and, eq, isNull, ne, sql } from "drizzle-orm";
import {
  normalizeMcpConnectionName,
  planFor,
  safeMcpServerName,
  type McpTransport,
  type ProviderAuthState,
  type ProviderConnectionState,
  type ProviderHealthState,
} from "@ovid/shared";
import type { Db } from "./client.js";
import { lockCustomConnectorCreates, newId, users, type McpServerRow } from "./repos.js";
import { mcpOauthTokens, mcpServers, type SealedEnvelope } from "./schema.js";

export interface McpConnectionRow extends ProviderConnectionState {
  name: string;
  transport: McpTransport;
  normalizedConnectionName: string;
  config: Record<string, unknown> | null;
  secretsSealed: SealedEnvelope | null;
  createdAt: Date;
  updatedAt: Date;
}

export type SealConnectionSecrets = (plaintext: string, recordId: string) => SealedEnvelope;

export interface CreateConnectionInput {
  userId: string;
  kind: "curated" | "custom";
  providerId: string;
  name: string;
  normalizedConnectionName: string;
  transport: McpTransport;
  config?: Record<string, unknown> | null;
  secrets?: Record<string, unknown>;
  sealSecrets?: SealConnectionSecrets;
  enabled?: boolean;
  agentEnabled: boolean;
  authState?: ProviderAuthState;
  approvedSourceId?: string;
  approvedDigest?: string;
}

export interface ConnectionVersionExpected {
  configVersion: number;
  disconnectGeneration: number;
}

export type ConnectionHealthEvidenceState =
  | "checking"
  | "healthy"
  | "degraded"
  | "needs_auth"
  | "unavailable";

export interface ConnectionHealthEvidence {
  state: ConnectionHealthEvidenceState;
  checkedAt: Date;
}

export interface TransitionConnectionPatch {
  enabled?: boolean;
  agentEnabled?: boolean;
  name?: string;
  normalizedConnectionName?: string;
  /** Catalog reservation injected by admission callers; never a readiness probe. */
  isNamespaceReserved?: (name: string) => boolean;
  secrets?: Record<string, unknown>;
  sealSecrets?: SealConnectionSecrets;
  authState?: ProviderAuthState;
}

export type ConnectionAdmissionCode =
  | "connector_limit_reached"
  | "server_exists"
  | "secret_sealing_unavailable";

export class ConnectionAdmissionError extends Error {
  constructor(
    readonly code: ConnectionAdmissionCode,
    readonly limit?: number,
  ) {
    super(code);
    this.name = "ConnectionAdmissionError";
  }
}

const AUTH_STATES: readonly ProviderAuthState[] = [
  "missing",
  "configured",
  "needs_auth",
  "authorized",
  "revoked",
];
const HEALTH_STATES: readonly ProviderHealthState[] = [
  "never_checked",
  "checking",
  "healthy",
  "degraded",
  "needs_auth",
  "refreshing",
  "revoked",
  "unavailable",
  "disabled",
];

/** NFKC + case folding, shared with the model-facing MCP namespace policy. */
export function normalizeConnectionName(name: string): string {
  return normalizeMcpConnectionName(name);
}

function authState(value: string): ProviderAuthState {
  // Legacy rows persist "unknown". The v1 contract has no unknown/connected
  // value, so fail closed to missing rather than inventing authorization.
  return (AUTH_STATES as readonly string[]).includes(value) ? value as ProviderAuthState : "missing";
}

function healthState(value: string): ProviderHealthState {
  return (HEALTH_STATES as readonly string[]).includes(value)
    ? value as ProviderHealthState
    : "never_checked";
}

/** Map a raw 0031 row without exposing its secret/config columns in the state fields. */
export function toMcpConnectionRow(row: McpServerRow): McpConnectionRow {
  return {
    connectionId: row.id,
    userId: row.userId,
    providerId: row.providerId ?? row.curatedId ?? "custom",
    enabled: row.enabled,
    agentEnabled: row.agentEnabled,
    authState: authState(row.authState),
    healthState: healthState(row.healthState),
    lastCheckedAt: row.lastCheckedAt?.toISOString() ?? null,
    lastSuccessAt: row.lastSuccessAt?.toISOString() ?? null,
    configVersion: row.configVersion,
    disconnectGeneration: row.disconnectGeneration,
    ...(row.approvedSourceId !== null ? { approvedSourceId: row.approvedSourceId } : {}),
    ...(row.approvedDigest !== null ? { approvedDigest: row.approvedDigest } : {}),
    name: row.name,
    transport: row.transport as McpTransport,
    normalizedConnectionName: normalizeConnectionName(row.normalizedConnectionName ?? row.name),
    config: row.config,
    secretsSealed: row.secretsSealed,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

function isUniqueViolation(error: unknown): boolean {
  let current: unknown = error;
  for (let depth = 0; current instanceof Error && depth < 6; depth += 1) {
    if ((current as { code?: string }).code === "23505") return true;
    if (/duplicate key|unique constraint/i.test(current.message)) return true;
    current = (current as { cause?: unknown }).cause;
  }
  return false;
}

function serverExists(): ConnectionAdmissionError {
  return new ConnectionAdmissionError("server_exists");
}

function seal(
  secrets: Record<string, unknown> | undefined,
  sealSecrets: SealConnectionSecrets | undefined,
  connectionId: string,
): SealedEnvelope | null {
  if (secrets === undefined) return null;
  if (sealSecrets === undefined) throw new ConnectionAdmissionError("secret_sealing_unavailable");
  return sealSecrets(JSON.stringify(secrets), `mcp_servers:${connectionId}`);
}

async function namespaceCollisionExists(
  db: Db,
  uid: string,
  name: string,
  excludeConnectionId?: string,
): Promise<boolean> {
  const namespace = safeMcpServerName(name);
  if (namespace === "") return true;
  // Model namespaces are per-user global across every approved-source identity.
  const rows = await db
    .select({ name: mcpServers.name })
    .from(mcpServers)
    .where(and(
      eq(mcpServers.userId, uid),
      isNull(mcpServers.curatedId),
      ...(excludeConnectionId === undefined ? [] : [ne(mcpServers.id, excludeConnectionId)]),
    ));
  return rows.some((row) => safeMcpServerName(row.name) === namespace);
}

async function customNamespaceExists(db: Db, input: CreateConnectionInput): Promise<boolean> {
  return input.kind === "custom" && namespaceCollisionExists(db, input.userId, input.name);
}

async function identityExists(db: Db, input: CreateConnectionInput): Promise<boolean> {
  if (input.kind === "curated") {
    const rows = await db.select({ id: mcpServers.id }).from(mcpServers).where(and(
      eq(mcpServers.userId, input.userId),
      eq(mcpServers.curatedId, input.providerId),
      sql`COALESCE(${mcpServers.providerId}, ${mcpServers.curatedId}) = ${input.providerId}`,
    )).limit(1);
    return rows.length > 0;
  }
  // Source identity still controls idempotency; canonical name comparison also
  // understands legacy rows whose persisted normalization predates NFKC.
  const rows = await db
    .select({ name: mcpServers.name, normalized: mcpServers.normalizedConnectionName })
    .from(mcpServers)
    .where(and(
      eq(mcpServers.userId, input.userId),
      isNull(mcpServers.curatedId),
      sql`COALESCE(${mcpServers.approvedSourceId}, ${mcpServers.approvedDigest}, '') = ${input.approvedSourceId ?? input.approvedDigest ?? ""}`,
    ));
  const expected = normalizeConnectionName(input.normalizedConnectionName);
  return rows.some((row) => normalizeConnectionName(row.normalized ?? row.name) === expected);
}

/**
 * Admit and seal one connection in a single transaction. The tier and count
 * are deliberately read only after the per-user lock, never from request state.
 */
export async function createConnectionWithinCap(
  db: Db,
  input: CreateConnectionInput,
): Promise<McpConnectionRow> {
  try {
    return await db.transaction(async (transaction) => {
      const tx = transaction as unknown as Db;
      await lockCustomConnectorCreates(tx, input.userId);
      const canonicalInput = input.kind === "custom"
        ? { ...input, normalizedConnectionName: normalizeConnectionName(input.name) }
        : input;
      // The route precheck is only UX: this sanitized namespace check runs
      // after the per-user lock, in the same transaction as the insert.
      if (await customNamespaceExists(tx, canonicalInput)) throw serverExists();
      if (await identityExists(tx, canonicalInput)) throw serverExists();

      if (input.kind === "custom") {
        const tier = await users.getTier(tx, input.userId);
        const limit = planFor(tier).customConnectors;
        const countRows = await tx
          .select({ count: sql<number>`count(*)::int` })
          .from(mcpServers)
          .where(and(eq(mcpServers.userId, input.userId), isNull(mcpServers.curatedId)));
        const count = countRows[0]?.count ?? 0;
        if (count >= limit) throw new ConnectionAdmissionError("connector_limit_reached", limit);
      }

      const connectionId = newId();
      const secretsSealed = seal(input.secrets, input.sealSecrets, connectionId);
      const rows = await tx
        .insert(mcpServers)
        .values({
          id: connectionId,
          userId: input.userId,
          name: input.name.trim(),
          transport: input.transport,
          curatedId: input.kind === "curated" ? input.providerId : null,
          providerId: input.providerId,
          agentEnabled: input.agentEnabled,
          authState: input.authState ?? (input.secrets === undefined ? "missing" : "configured"),
          healthState: "never_checked",
          configVersion: 1,
          disconnectGeneration: 0,
          approvedSourceId: input.approvedSourceId ?? null,
          approvedDigest: input.approvedDigest ?? null,
          normalizedConnectionName: canonicalInput.normalizedConnectionName,
          config: input.config ?? null,
          secretsSealed,
          enabled: input.enabled ?? true,
        })
        .returning();
      return toMcpConnectionRow(rows[0]!);
    });
  } catch (error) {
    if (isUniqueViolation(error)) throw serverExists();
    throw error;
  }
}

/** Conditional connection mutation; every real transition advances configVersion. */
export async function transitionConnection(
  db: Db,
  id: string,
  uid: string,
  patch: TransitionConnectionPatch,
  expected: ConnectionVersionExpected,
): Promise<McpConnectionRow | null> {
  const changed = patch.enabled !== undefined || patch.agentEnabled !== undefined ||
    patch.name !== undefined || patch.secrets !== undefined || patch.authState !== undefined;
  const expectedWhere = and(
    eq(mcpServers.id, id),
    eq(mcpServers.userId, uid),
    eq(mcpServers.configVersion, expected.configVersion),
    eq(mcpServers.disconnectGeneration, expected.disconnectGeneration),
  );
  if (!changed) {
    const rows = await db.select().from(mcpServers).where(expectedWhere).limit(1);
    return rows[0] === undefined ? null : toMcpConnectionRow(rows[0]);
  }

  const set: {
    updatedAt: Date;
    enabled?: boolean;
    agentEnabled?: boolean;
    name?: string;
    normalizedConnectionName?: string;
    secretsSealed?: SealedEnvelope;
    authState?: ProviderAuthState;
    healthState?: ProviderHealthState | ReturnType<typeof sql>;
    lastCheckedAt?: Date | null;
    lastSuccessAt?: Date | null;
    configVersion: ReturnType<typeof sql>;
  } = {
    updatedAt: new Date(),
    configVersion: sql`${mcpServers.configVersion} + 1`,
  };
  if (patch.enabled !== undefined) {
    set.enabled = patch.enabled;
    set.healthState = patch.enabled ? "never_checked" : "disabled";
  }
  if (patch.agentEnabled !== undefined) set.agentEnabled = patch.agentEnabled;
  if (patch.name !== undefined) {
    set.name = patch.name.trim();
    set.normalizedConnectionName = patch.normalizedConnectionName ?? normalizeConnectionName(patch.name);
  }
  if (patch.secrets !== undefined) {
    set.secretsSealed = seal(patch.secrets, patch.sealSecrets, id)!;
    set.healthState = patch.enabled === undefined
      ? sql`CASE WHEN ${mcpServers.enabled} THEN 'never_checked' ELSE 'disabled' END`
      : patch.enabled ? "never_checked" : "disabled";
    set.lastCheckedAt = null;
    set.lastSuccessAt = null;
  }
  if (patch.authState !== undefined) set.authState = patch.authState;

  try {
    return await db.transaction(async (transaction) => {
      const tx = transaction as unknown as Db;
      if (patch.name !== undefined) {
        await lockCustomConnectorCreates(tx, uid);
        const current = await tx
          .select({ curatedId: mcpServers.curatedId })
          .from(mcpServers)
          .where(and(eq(mcpServers.id, id), eq(mcpServers.userId, uid)))
          .limit(1);
        if (current[0]?.curatedId === null) {
          if (patch.isNamespaceReserved?.(patch.name) === true) throw serverExists();
          if (await namespaceCollisionExists(tx, uid, patch.name, id)) throw serverExists();
        }
      }
      // The same conditional update fences every mutation, including a rename
      // combined with secrets. A rejected rename writes nothing and bumps nothing.
      const rows = await tx.update(mcpServers).set(set).where(expectedWhere).returning();
      return rows[0] === undefined ? null : toMcpConnectionRow(rows[0]);
    });
  } catch (error) {
    if (isUniqueViolation(error)) throw serverExists();
    throw error;
  }
}

/**
 * Commit health evidence only against the exact enabled connection generation
 * that was checked. Health never advances either execution fence, and only a
 * healthy result creates new last-success evidence.
 */
export async function recordConnectionHealth(
  db: Db,
  id: string,
  uid: string,
  expected: ConnectionVersionExpected,
  evidence: ConnectionHealthEvidence,
): Promise<McpConnectionRow | null> {
  const set: {
    updatedAt: Date;
    healthState: ConnectionHealthEvidenceState;
    lastCheckedAt: Date;
    lastSuccessAt?: Date;
  } = {
    updatedAt: evidence.checkedAt,
    healthState: evidence.state,
    lastCheckedAt: evidence.checkedAt,
  };
  if (evidence.state === "healthy") set.lastSuccessAt = evidence.checkedAt;
  const rows = await db
    .update(mcpServers)
    .set(set)
    .where(and(
      eq(mcpServers.id, id),
      eq(mcpServers.userId, uid),
      eq(mcpServers.enabled, true),
      eq(mcpServers.configVersion, expected.configVersion),
      eq(mcpServers.disconnectGeneration, expected.disconnectGeneration),
    ))
    .returning();
  return rows[0] === undefined ? null : toMcpConnectionRow(rows[0]);
}

/** Disconnect is a state transition, not a delete: stale generations remain observable. */
export async function disconnectConnection(
  db: Db,
  id: string,
  uid: string,
  expectedConfigVersion: number,
): Promise<McpConnectionRow | null> {
  return db.transaction(async (transaction) => {
    const tx = transaction as unknown as Db;
    const rows = await tx
      .update(mcpServers)
      .set({
        enabled: false,
        agentEnabled: false,
        authState: "revoked",
        healthState: "revoked",
        disconnectGeneration: sql`${mcpServers.disconnectGeneration} + 1`,
        updatedAt: new Date(),
      })
      .where(and(
        eq(mcpServers.id, id),
        eq(mcpServers.userId, uid),
        eq(mcpServers.configVersion, expectedConfigVersion),
      ))
      .returning();
    const row = rows[0];
    if (row === undefined) return null;
    // Token removal commits with the generation bump. A stale disconnect does
    // not delete current auth; a completed disconnect leaves no cached OAuth
    // material that could be projected as still authorized.
    await tx.delete(mcpOauthTokens).where(and(
      eq(mcpOauthTokens.serverId, id),
      eq(mcpOauthTokens.userId, uid),
    ));
    return toMcpConnectionRow(row);
  });
}

export async function revalidateConnection(
  db: Db,
  id: string,
  uid: string,
  expected: ConnectionVersionExpected,
): Promise<"current" | "stale" | "denied"> {
  const rows = await db
    .select()
    .from(mcpServers)
    .where(and(eq(mcpServers.id, id), eq(mcpServers.userId, uid)))
    .limit(1);
  const row = rows[0];
  if (row === undefined) return "denied";
  if (row.configVersion !== expected.configVersion ||
      row.disconnectGeneration !== expected.disconnectGeneration) return "stale";
  if (!row.enabled || !row.agentEnabled) return "denied";
  const auth = authState(row.authState);
  return auth === "configured" || auth === "authorized" ? "current" : "denied";
}
