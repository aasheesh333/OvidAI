import {
  and,
  asc,
  eq,
  gt,
  inArray,
  isNull,
  lte,
  or,
  sql,
} from "drizzle-orm";

import type { Db } from "./client.js";
import { studioPreviews, type StudioPreviewRow } from "./schema.js";
import {
  STUDIO_PREVIEW_LIVE_STATUSES,
  type StudioPreviewAdmissionTransaction,
  type StudioPreviewCasUpdate,
  type StudioPreviewRecord,
  type StudioPreviewStorePort,
} from "./studioPreviewStore.js";

/** One fixed database-wide key shared by every preview worker/admission. */
const ADMISSION_LOCK_SCOPE = "ovid:studio-previews:admission:v1";
const TOUCHABLE_STATUSES = ["starting", "running"] as const;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CAS_FIELDS = new Set([
  "generation",
  "status",
  "processId",
  "processGroupId",
  "workerEpoch",
  "bindHost",
  "port",
  "lastAccessAt",
  "expiresAt",
  "endedAt",
  "exitCode",
  "failureCode",
  "logBytes",
]);

function timestamp(value: string): Date {
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) {
    throw new RangeError("Invalid Studio preview timestamp");
  }
  return parsed;
}

function iso(value: Date): string {
  return value.toISOString();
}

function optionalIso(value: Date | null): string | null {
  return value === null ? null : iso(value);
}

/** Explicit 21-field boundary projection: no driver objects or extra columns leak. */
function toRecord(row: StudioPreviewRow): StudioPreviewRecord {
  return {
    id: row.id,
    sessionId: row.sessionId,
    userId: row.userId,
    generation: row.generation,
    kind: row.kind,
    workspacePath: row.workspacePath,
    projectDir: row.projectDir,
    startScript: row.startScript,
    processId: row.processId,
    processGroupId: row.processGroupId,
    workerEpoch: row.workerEpoch,
    bindHost: row.bindHost,
    port: row.port,
    status: row.status,
    createdAt: iso(row.createdAt),
    lastAccessAt: optionalIso(row.lastAccessAt),
    expiresAt: iso(row.expiresAt),
    endedAt: optionalIso(row.endedAt),
    exitCode: row.exitCode,
    failureCode: row.failureCode,
    logBytes: row.logBytes,
  };
}

function toRow(record: StudioPreviewRecord): typeof studioPreviews.$inferInsert {
  return {
    id: record.id,
    sessionId: record.sessionId,
    userId: record.userId,
    generation: record.generation,
    kind: record.kind,
    workspacePath: record.workspacePath,
    projectDir: record.projectDir,
    startScript: record.startScript,
    processId: record.processId,
    processGroupId: record.processGroupId,
    workerEpoch: record.workerEpoch,
    bindHost: record.bindHost,
    port: record.port,
    status: record.status,
    createdAt: timestamp(record.createdAt),
    lastAccessAt: record.lastAccessAt === null ? null : timestamp(record.lastAccessAt),
    expiresAt: timestamp(record.expiresAt),
    endedAt: record.endedAt === null ? null : timestamp(record.endedAt),
    exitCode: record.exitCode,
    failureCode: record.failureCode,
    logBytes: record.logBytes,
  };
}

/**
 * Build only the approved mutable fields. In particular, never spread a caller
 * object into UPDATE: identity, ownership, launch paths/script and createdAt
 * are immutable at this adapter boundary even for untyped JavaScript callers.
 */
function toCasSet(
  generation: number,
  update: StudioPreviewCasUpdate,
): Partial<typeof studioPreviews.$inferInsert> {
  if (!Number.isSafeInteger(update.generation) || update.generation !== generation + 1) {
    throw new RangeError("Studio preview CAS must increment generation exactly once");
  }
  for (const key of Object.keys(update)) {
    if (!CAS_FIELDS.has(key)) {
      throw new Error(
        "Unsupported Studio preview CAS field; identity and launch definition are immutable",
      );
    }
  }
  const set: Partial<typeof studioPreviews.$inferInsert> = {
    generation: update.generation,
  };
  if (update.status !== undefined) set.status = update.status;
  if (update.processId !== undefined) set.processId = update.processId;
  if (update.processGroupId !== undefined) set.processGroupId = update.processGroupId;
  if (update.workerEpoch !== undefined) set.workerEpoch = update.workerEpoch;
  if (update.bindHost !== undefined) set.bindHost = update.bindHost;
  if (update.port !== undefined) set.port = update.port;
  if (update.lastAccessAt !== undefined) {
    set.lastAccessAt = update.lastAccessAt === null ? null : timestamp(update.lastAccessAt);
  }
  if (update.expiresAt !== undefined) set.expiresAt = timestamp(update.expiresAt);
  if (update.endedAt !== undefined) {
    set.endedAt = update.endedAt === null ? null : timestamp(update.endedAt);
  }
  if (update.exitCode !== undefined) set.exitCode = update.exitCode;
  if (update.failureCode !== undefined) set.failureCode = update.failureCode;
  if (update.logBytes !== undefined) set.logBytes = update.logBytes;
  return set;
}

/**
 * Concrete durable StudioPreviewStorePort over the package's existing Drizzle
 * postgres-js Db. Compose with createStudioPreviewStore(port) at the worker
 * composition boundary; this module deliberately holds no process-local rows.
 */
export function createStudioPreviewPostgresStore(db: Db): StudioPreviewStorePort {
  return {
    async transaction<T>(
      callback: (tx: StudioPreviewAdmissionTransaction) => Promise<T>,
    ): Promise<T> {
      return db.transaction(async (transaction) => {
        const tx: StudioPreviewAdmissionTransaction = {
          async lockCapacity() {
            await transaction.execute(sql`
              SELECT pg_advisory_xact_lock(hashtextextended(${ADMISSION_LOCK_SCOPE}, 0))
            `);
          },

          async liveDevServerCounts(userId) {
            const rows = await transaction
              .select({
                perUser: sql<number>`count(*) FILTER (WHERE ${studioPreviews.userId} = ${userId})::int`,
                global: sql<number>`count(*)::int`,
              })
              .from(studioPreviews)
              .where(and(
                eq(studioPreviews.kind, "dev_server"),
                inArray(studioPreviews.status, [...STUDIO_PREVIEW_LIVE_STATUSES]),
              ));
            return rows[0] ?? { perUser: 0, global: 0 };
          },

          async insert(record) {
            const rows = await transaction
              .insert(studioPreviews)
              .values(toRow(record))
              .returning();
            const row = rows[0];
            if (row === undefined) throw new Error("Studio preview insert returned no record");
            return toRecord(row);
          },
        };
        return callback(tx);
      }, {
        // A waiter must take a fresh statement snapshot after the advisory
        // lock, so a stronger connection-default isolation cannot stale-count.
        isolationLevel: "read committed",
      });
    },

    async getForUser(userId, sessionId, id) {
      // Route params are not necessarily UUID-parsed; malformed/unknown ids
      // must retain the contract's empty/non-enumerating result, not a 22P02.
      if (id !== undefined && !UUID.test(id)) return [];
      const rows = await db
        .select()
        .from(studioPreviews)
        .where(and(
          eq(studioPreviews.userId, userId),
          eq(studioPreviews.sessionId, sessionId),
          ...(id === undefined ? [] : [eq(studioPreviews.id, id)]),
        ));
      return rows.map(toRecord);
    },

    async getLive() {
      const rows = await db
        .select()
        .from(studioPreviews)
        .where(inArray(studioPreviews.status, [...STUDIO_PREVIEW_LIVE_STATUSES]));
      return rows.map(toRecord);
    },

    async compareAndSwap(id, generation, update) {
      if (!UUID.test(id)) return null;
      const rows = await db
        .update(studioPreviews)
        .set(toCasSet(generation, update))
        .where(and(
          eq(studioPreviews.id, id),
          eq(studioPreviews.generation, generation),
        ))
        .returning();
      const row = rows[0];
      return row === undefined ? null : toRecord(row);
    },

    async touch({ id, generation, now }) {
      if (!UUID.test(id)) return false;
      const at = timestamp(now);
      const rows = await db
        .update(studioPreviews)
        .set({ lastAccessAt: at })
        .where(and(
          eq(studioPreviews.id, id),
          eq(studioPreviews.generation, generation),
          inArray(studioPreviews.status, [...TOUCHABLE_STATUSES]),
          gt(studioPreviews.expiresAt, at),
          or(
            isNull(studioPreviews.lastAccessAt),
            lte(studioPreviews.lastAccessAt, new Date(at.getTime() - 1_000)),
          ),
        ))
        .returning({ id: studioPreviews.id });
      return rows.length === 1;
    },

    async sweepExpired(now, limit) {
      if (!Number.isInteger(limit) || limit < 1) {
        throw new RangeError("Studio preview sweep limit must be a positive integer");
      }
      const rows = await db
        .select()
        .from(studioPreviews)
        .where(and(
          inArray(studioPreviews.status, [...STUDIO_PREVIEW_LIVE_STATUSES]),
          lte(studioPreviews.expiresAt, timestamp(now)),
        ))
        .orderBy(asc(studioPreviews.expiresAt), asc(studioPreviews.id))
        .limit(limit);
      return rows.map(toRecord);
    },
  };
}
