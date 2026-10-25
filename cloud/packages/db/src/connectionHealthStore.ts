import { and, eq, inArray, ne } from "drizzle-orm";
import type { ProviderAuthState, ProviderHealthState } from "@ovid/shared";

import type { Db } from "./client.js";
import {
  disconnectConnection as disconnectProviderConnection,
  toMcpConnectionRow,
  type ConnectionVersionExpected,
} from "./providerConnections.js";
import { mcpServers as serverRepo, newId } from "./repos.js";
import {
  mcpOauthTokens as tokenTable,
  mcpServers as serverTable,
  type SealedEnvelope,
} from "./schema.js";

/** Structural counterpart of @ovid/mcp's HealthConnectionRecord; DB does not depend on MCP. */
export interface StoredConnectionHealth {
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
  hasSecrets: boolean;
  /** Internal health input only; never project this legacy marker into a DTO. */
  legacyUnknownAuthWithoutConfig?: true;
}

export type StoredConnectionHealthWriteState =
  | "checking"
  | "healthy"
  | "degraded"
  | "needs_auth"
  | "refreshing"
  | "revoked"
  | "unavailable";

export interface StoredConnectionHealthWrite {
  connectionId: string;
  userId: string;
  expected: ConnectionVersionExpected;
  state: StoredConnectionHealthWriteState;
  checkedAt?: Date;
  succeededAt?: Date;
}

export interface StoredConnectionHealthTokenWrite {
  connectionId: string;
  userId: string;
  expected: ConnectionVersionExpected;
  token: unknown;
  signal: AbortSignal;
}

/** Narrow real store port consumed by the MCP lifecycle without a package cycle. */
export interface ConnectionHealthStore {
  get(connectionId: string, uid: string): Promise<StoredConnectionHealth | null>;
  writeHealth(write: StoredConnectionHealthWrite): Promise<StoredConnectionHealth | null>;
  writeRefreshedToken(write: StoredConnectionHealthTokenWrite): Promise<boolean>;
  disconnect(
    connectionId: string,
    uid: string,
    expectedConfigVersion: number,
  ): Promise<StoredConnectionHealth | null>;
}

function project(row: NonNullable<Awaited<ReturnType<typeof serverRepo.get>>>): StoredConnectionHealth {
  const connection = toMcpConnectionRow(row);
  return {
    connectionId: connection.connectionId,
    userId: connection.userId,
    providerId: connection.providerId,
    enabled: connection.enabled,
    agentEnabled: connection.agentEnabled,
    authState: connection.authState,
    healthState: connection.healthState,
    lastCheckedAt: connection.lastCheckedAt,
    lastSuccessAt: connection.lastSuccessAt,
    configVersion: connection.configVersion,
    disconnectGeneration: connection.disconnectGeneration,
    hasSecrets: row.secretsSealed !== null,
    ...(row.authState === "unknown" && row.config === null
      ? { legacyUnknownAuthWithoutConfig: true as const }
      : {}),
  };
}

function validDate(value: Date | undefined): value is Date {
  return value !== undefined && Number.isFinite(value.getTime());
}

function sealedEnvelope(token: unknown): SealedEnvelope {
  if (typeof token !== "object" || token === null || Array.isArray(token)) {
    throw new Error("invalid_sealed_token");
  }
  const candidate = token as Record<string, unknown>;
  if (Object.keys(candidate).length !== 4 ||
      !["wrappedDek", "iv", "ciphertext", "tag"].every((key) => typeof candidate[key] === "string")) {
    throw new Error("invalid_sealed_token");
  }
  return {
    wrappedDek: candidate.wrappedDek as string,
    iv: candidate.iv as string,
    ciphertext: candidate.ciphertext as string,
    tag: candidate.tag as string,
  };
}

/**
 * Existing mcp_servers columns already support every health state and both
 * timestamps; no migration or widening of providerConnections is required.
 */
export function createConnectionHealthStore(db: Db): ConnectionHealthStore {
  return {
    async get(connectionId, uid) {
      const row = await serverRepo.get(db, connectionId, uid);
      return row === null ? null : project(row);
    },

    async writeHealth(write) {
      if (write.state === "healthy" &&
          (!validDate(write.checkedAt) || !validDate(write.succeededAt) ||
            write.checkedAt.getTime() !== write.succeededAt.getTime())) {
        throw new Error("healthy_evidence_requires_success");
      }
      if (write.state !== "healthy" && write.succeededAt !== undefined) {
        throw new Error("success_evidence_requires_healthy_operation");
      }
      if (write.checkedAt !== undefined && !validDate(write.checkedAt)) {
        throw new Error("invalid_health_timestamp");
      }

      const set: {
        updatedAt: Date;
        healthState: StoredConnectionHealthWriteState;
        authState?: "needs_auth" | "revoked";
        lastCheckedAt?: Date;
        lastSuccessAt?: Date;
      } = {
        // Progress writes update the row mutation time only; lastCheckedAt and
        // lastSuccessAt remain the prior durable evidence exactly as persisted.
        updatedAt: write.checkedAt ?? new Date(),
        healthState: write.state,
      };
      // These are authentication facts, not presentation-only states: the
      // existing activation revalidator denies both values on its next read.
      if (write.state === "needs_auth" || write.state === "revoked") set.authState = write.state;
      if (write.checkedAt !== undefined) set.lastCheckedAt = write.checkedAt;
      if (write.succeededAt !== undefined) set.lastSuccessAt = write.succeededAt;

      const conditions = [
        eq(serverTable.id, write.connectionId),
        eq(serverTable.userId, write.userId),
        eq(serverTable.enabled, true),
        eq(serverTable.configVersion, write.expected.configVersion),
        eq(serverTable.disconnectGeneration, write.expected.disconnectGeneration),
      ];
      if (write.state !== "revoked") {
        conditions.push(ne(serverTable.authState, "revoked"), ne(serverTable.healthState, "revoked"));
      }
      if (write.state === "healthy") {
        conditions.push(inArray(serverTable.authState, ["configured", "authorized"]));
      }
      const rows = await db.update(serverTable).set(set).where(and(...conditions)).returning();
      const row = rows[0];
      return row === undefined ? null : project(row);
    },

    async writeRefreshedToken(write) {
      if (write.signal.aborted) return false;
      const tokensSealed = sealedEnvelope(write.token);
      return db.transaction(async (transaction) => {
        const tx = transaction as unknown as Db;
        // Serialize against disconnect/config transitions on the parent row.
        // Once this lock is held, either this write commits before disconnect
        // (which then deletes it), or it observes the new generation and fails.
        const rows = await tx.select({
          enabled: serverTable.enabled,
          authState: serverTable.authState,
          healthState: serverTable.healthState,
          configVersion: serverTable.configVersion,
          disconnectGeneration: serverTable.disconnectGeneration,
        }).from(serverTable).where(and(
          eq(serverTable.id, write.connectionId),
          eq(serverTable.userId, write.userId),
        )).for("update").limit(1);
        const current = rows[0];
        if (current === undefined || !current.enabled ||
            current.authState === "revoked" || current.healthState === "revoked" ||
            current.configVersion !== write.expected.configVersion ||
            current.disconnectGeneration !== write.expected.disconnectGeneration ||
            write.signal.aborted) return false;

        await tx.insert(tokenTable).values({
          id: newId(),
          userId: write.userId,
          serverId: write.connectionId,
          tokensSealed,
        }).onConflictDoUpdate({
          target: tokenTable.serverId,
          set: {
            userId: write.userId,
            tokensSealed,
            updatedAt: new Date(),
          },
        });
        return true;
      });
    },

    async disconnect(connectionId, uid, expectedConfigVersion) {
      const row = await disconnectProviderConnection(db, connectionId, uid, expectedConfigVersion);
      if (row === null) return null;
      const raw = await serverRepo.get(db, connectionId, uid);
      return raw === null ? null : project(raw);
    },
  };
}
