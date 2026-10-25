import { and, eq, inArray, like, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/postgres-js";
import type { Db } from "./client.js";
import { plansRepo, type OverrideRecord, type PurchaseRow } from "./moneyRepos.js";
import type { BillingRemoteOperation } from "./billingRemoteRepos.js";
import {
  billingPurchases as billingPurchasesTable,
  users as usersTable,
} from "./schema.js";

export type BillingPurchaseState =
  | "active"
  | "cancelled"
  | "expired"
  | "refunded"
  | "pending"
  | "unknown";

/** Verified fields persisted for a RevenueCat purchase; period is derived from productId. */
export interface RevenueCatEntitlementWrite {
  tier: string;
  productId: string;
  expiresAt: number | null;
  autoRenewing: boolean;
  purchaseState: BillingPurchaseState;
}

export interface RevenueCatEventWrite {
  eventId: string;
  transactionId: string;
  uid: string;
  occurredAt: number;
  entitlement: RevenueCatEntitlementWrite;
}

export interface RevenueCatTransferWrite {
  eventId: string;
  fromUids: string[];
  toUid: string;
  occurredAt: number;
}

export interface RevenueCatApplyResult {
  status: "applied" | "replayed" | "stale";
  previousUid: string | null;
  previousUids: string[];
  ownerUid: string | null;
  projectionPending: boolean;
}

export interface RevenueCatRefreshSnapshot {
  generation: number;
  rows: PurchaseRow[];
}

export type { BillingRemoteOperation, BillingRemoteOperationKind } from "./billingRemoteRepos.js";

/*
 * RevenueCat shares the existing purchase ledger; no schema change is needed.
 * Purchase tokens are namespaced away from Play tokens and all marker rows
 * have a NULL uid, so they can never win an account's effective entitlement.
 */
const purchaseToken = (transactionId: string): string =>
  `revenuecat:purchase:${transactionId}`;
const eventToken = (eventId: string): string => `revenuecat:event:${eventId}`;
const refreshToken = (uid: string): string => `revenuecat:refresh:${uid}`;
const remoteToken = (uid: string): string => `revenuecat:remote:${uid}`;
const anomalyStandingToken = (uid: string): string => `revenuecat:anomaly-standing:${uid}`;
const ANOMALY_STANDING_PREFIX = "rc-anomaly-standing:";
const EVENT_TIME_PREFIX = "rc-event-at:";
const REMOTE_META_PREFIX = "rc-remote:";
const EVENT_META_PREFIX = "rc-event-meta:";

interface EventMetadata {
  ownerUid: string | null;
  previousUids: string[];
}

function eventMetadata(ownerUid: string | null, previousUids: string[]): string {
  return `${EVENT_META_PREFIX}${JSON.stringify({ ownerUid, previousUids })}`;
}

function readEventMetadata(row: PurchaseRow): EventMetadata {
  if (row.accountHash?.startsWith(EVENT_META_PREFIX)) {
    try {
      const parsed = JSON.parse(row.accountHash.slice(EVENT_META_PREFIX.length)) as unknown;
      if (typeof parsed === "object" && parsed !== null) {
        const value = parsed as { ownerUid?: unknown; previousUids?: unknown };
        return {
          ownerUid: typeof value.ownerUid === "string" ? value.ownerUid : null,
          previousUids: Array.isArray(value.previousUids)
            ? value.previousUids.filter((uid): uid is string => typeof uid === "string")
            : [],
        };
      }
    } catch {
      // A malformed old marker cannot fabricate an account-switch projection.
    }
  }
  return { ownerUid: null, previousUids: [] };
}

function persistedEventTime(row: { accountHash: string | null; updatedAt: number }): number {
  if (row.accountHash?.startsWith(EVENT_TIME_PREFIX)) {
    const value = Number(row.accountHash.slice(EVENT_TIME_PREFIX.length));
    if (Number.isFinite(value)) return value;
  }
  return row.updatedAt;
}

function applyResult(
  status: RevenueCatApplyResult["status"],
  ownerUid: string | null,
  previousUids: string[],
  projectionPending: boolean,
): RevenueCatApplyResult {
  return {
    status,
    previousUid: previousUids[0] ?? null,
    previousUids: [...previousUids],
    ownerUid,
    projectionPending,
  };
}

function replayResult(row: PurchaseRow): RevenueCatApplyResult {
  const metadata = readEventMetadata(row);
  return applyResult("replayed", metadata.ownerUid, metadata.previousUids, row.status === "pending");
}

function remoteMetadata(operation: BillingRemoteOperation): string {
  return `${REMOTE_META_PREFIX}${JSON.stringify({
    generation: operation.generation,
    kind: operation.kind,
    target: operation.target,
    ...(operation.maxBudget !== undefined ? { maxBudget: operation.maxBudget } : {}),
    ...(operation.budgetDuration !== undefined ? { budgetDuration: operation.budgetDuration } : {}),
    ...(operation.spend !== undefined ? { spend: operation.spend } : {}),
    ...(operation.rpmLimit !== undefined ? { rpmLimit: operation.rpmLimit } : {}),
    ...(operation.tpmLimit !== undefined ? { tpmLimit: operation.tpmLimit } : {}),
    ...(operation.maxParallelRequests !== undefined ? { maxParallelRequests: operation.maxParallelRequests } : {}),
    ...(operation.extra !== undefined ? { extra: operation.extra } : {}),
    ...(operation.retryable === true ? { retryable: true } : {}),
  })}`;
}

function readRemoteOperation(
  row: PurchaseRow,
  uid: string,
): BillingRemoteOperation | null {
  if (!row.accountHash?.startsWith(REMOTE_META_PREFIX)) return null;
  try {
    const value = JSON.parse(row.accountHash.slice(REMOTE_META_PREFIX.length)) as {
      generation?: unknown;
      kind?: unknown;
      target?: unknown;
      maxBudget?: unknown;
      budgetDuration?: unknown;
      spend?: unknown;
      rpmLimit?: unknown;
      tpmLimit?: unknown;
      maxParallelRequests?: unknown;
      extra?: unknown;
      retryable?: unknown;
    };
    if (
      !Number.isSafeInteger(value.generation) ||
      (value.kind !== "user" && value.kind !== "key") ||
      typeof value.target !== "string" ||
      !(value.maxBudget === undefined || typeof value.maxBudget === "number" || value.maxBudget === null) ||
      (value.budgetDuration !== undefined && value.budgetDuration !== null && typeof value.budgetDuration !== "string") ||
      (value.spend !== undefined && typeof value.spend !== "number") ||
      (value.rpmLimit !== undefined && value.rpmLimit !== null && typeof value.rpmLimit !== "number") ||
      (value.tpmLimit !== undefined && value.tpmLimit !== null && typeof value.tpmLimit !== "number") ||
      (value.maxParallelRequests !== undefined && value.maxParallelRequests !== null && typeof value.maxParallelRequests !== "number") ||
      (value.extra !== undefined && (typeof value.extra !== "object" || value.extra === null || Array.isArray(value.extra))) ||
      (value.retryable !== undefined && typeof value.retryable !== "boolean")
    ) {
      return null;
    }
    return {
      uid,
      generation: value.generation as number,
      kind: value.kind,
      target: value.target,
      ...(value.maxBudget !== undefined ? { maxBudget: value.maxBudget as number | null } : {}),
      ...(value.budgetDuration !== undefined ? { budgetDuration: value.budgetDuration as string | null } : {}),
      ...(value.spend !== undefined ? { spend: value.spend as number } : {}),
      ...(value.rpmLimit !== undefined ? { rpmLimit: value.rpmLimit as number | null } : {}),
      ...(value.tpmLimit !== undefined ? { tpmLimit: value.tpmLimit as number | null } : {}),
      ...(value.maxParallelRequests !== undefined ? { maxParallelRequests: value.maxParallelRequests as number | null } : {}),
      ...(value.extra !== undefined ? { extra: value.extra as Record<string, unknown> } : {}),
      retryable: value.retryable === true,
    };
  } catch {
    return null;
  }
}

function sameRemoteOperation(
  left: BillingRemoteOperation,
  right: BillingRemoteOperation,
): boolean {
  return left.uid === right.uid &&
    left.generation === right.generation &&
    left.kind === right.kind &&
    left.target === right.target &&
    left.maxBudget === right.maxBudget &&
    left.budgetDuration === right.budgetDuration &&
    left.spend === right.spend &&
    left.rpmLimit === right.rpmLimit &&
    left.tpmLimit === right.tpmLimit &&
    left.maxParallelRequests === right.maxParallelRequests &&
    JSON.stringify(left.extra ?? null) === JSON.stringify(right.extra ?? null) &&
    (left.retryable ?? false) === (right.retryable ?? false);
}

function markerValues(
  eventId: string,
  occurredAt: number,
  ownerUid: string | null,
  previousUids: string[],
): typeof billingPurchasesTable.$inferInsert {
  return {
    token: eventToken(eventId),
    uid: null,
    productId: "revenuecat_event",
    tier: "free",
    status: "pending",
    expiresAt: null,
    autoRenewing: false,
    linkedToken: null,
    accountHash: eventMetadata(ownerUid, previousUids),
    updatedAt: Math.trunc(occurredAt),
  };
}

/**
 * P9 Task 10: the durable users.tier projection used by the billing tier sink.
 *
 * `users.tier` is the Postgres authority (Ruling Q4); the Redis
 * `user:{uid}:tier` pair is the request-time projection. This repo keeps the
 * two billing-specific column reads/writes in one place so the mint app never
 * imports drizzle-orm directly and moneyRepos.ts (Task 2, another lane's hot
 * file) stays untouched.
 */
export interface BillingUserTier {
  tier: string;
  tierExpiresAt: Date | null;
}

type BillingRefreshTx = Parameters<Parameters<Db["transaction"]>[0]>[0];

export interface AnomalyStandingProjection {
  uid: string;
  generation: number;
  bannedAtIso: string;
  status: "pending" | "replaced";
}

function anomalyStandingMetadata(generation: number, bannedAtIso: string): string {
  return `${ANOMALY_STANDING_PREFIX}${JSON.stringify({ generation, bannedAtIso })}`;
}

function readAnomalyStanding(row: PurchaseRow, uid: string): AnomalyStandingProjection | null {
  if (!row.accountHash?.startsWith(ANOMALY_STANDING_PREFIX)) return null;
  try {
    const value = JSON.parse(row.accountHash.slice(ANOMALY_STANDING_PREFIX.length)) as {
      generation?: unknown;
      bannedAtIso?: unknown;
    };
    if (!Number.isSafeInteger(value.generation) || typeof value.bannedAtIso !== "string") {
      return null;
    }
    return {
      uid,
      generation: value.generation as number,
      bannedAtIso: value.bannedAtIso,
      status: row.status === "replaced" ? "replaced" : "pending",
    };
  } catch {
    return null;
  }
}

/** Check and hold the refresh marker row while the actual SQL mutation runs. */
async function withRefreshTransaction<T>(
  db: Db,
  uid: string,
  generation: number,
  write: (tx: BillingRefreshTx) => Promise<T>,
): Promise<T | false> {
  return db.transaction(async (tx) => {
    const [marker] = await tx
      .select({ accountHash: billingPurchasesTable.accountHash })
      .from(billingPurchasesTable)
      .where(eq(billingPurchasesTable.token, refreshToken(uid)))
      .limit(1)
      .for("update");
    if (marker?.accountHash !== String(generation)) return false;
    return write(tx);
  });
}

export const billingUsers = {
  /** Current durable tier; a missing row reads as free (never throws). */
  async getTier(db: Db, uid: string): Promise<BillingUserTier> {
    const [row] = await db
      .select({ tier: usersTable.tier, tierExpiresAt: usersTable.tierExpiresAt })
      .from(usersTable)
      .where(eq(usersTable.uid, uid))
      .limit(1);
    return { tier: row?.tier ?? "free", tierExpiresAt: row?.tierExpiresAt ?? null };
  },

  /** Insert-if-absent so a purchase verified before key minting still persists. */
  async setTier(
    db: Db,
    uid: string,
    tier: string,
    tierExpiresAtEpoch: number | null,
  ): Promise<void> {
    const tierExpiresAt =
      tierExpiresAtEpoch === null || tierExpiresAtEpoch === undefined
        ? null
        : new Date(tierExpiresAtEpoch * 1000);
    await db
      .insert(usersTable)
      .values({ uid, tier, tierExpiresAt, mintProvisioned: true })
      .onConflictDoUpdate({
        target: usersTable.uid,
        set: { tier, tierExpiresAt, mintProvisioned: true },
      });
  },

  /**
   * Version-checked durable write for a billing refresh. The marker row lock
   * orders this transaction against beginRefresh: a superseded generation
   * performs no users write at all instead of relying on a later repair.
   */
  async setTierForRefresh(
    db: Db,
    uid: string,
    tier: string,
    tierExpiresAtEpoch: number | null,
    generation: number,
  ): Promise<boolean> {
    return db.transaction(async (tx) => {
      const [marker] = await tx
        .select({ accountHash: billingPurchasesTable.accountHash })
        .from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.token, refreshToken(uid)))
        .limit(1)
        .for("update");
      if (marker?.accountHash !== String(generation)) return false;
      const tierExpiresAt = tierExpiresAtEpoch === null ? null : new Date(tierExpiresAtEpoch * 1000);
      await tx
        .insert(usersTable)
        .values({ uid, tier, tierExpiresAt, mintProvisioned: true })
        .onConflictDoUpdate({
          target: usersTable.uid,
          set: { tier, tierExpiresAt, mintProvisioned: true },
        });
      return true;
    });
  },

  /** Generation-checked compatibility override write; absent fields keep their value. */
  async saveOverrideForRefresh(
    db: Db,
    uid: string,
    override: Partial<OverrideRecord> | null,
    generation: number,
  ): Promise<boolean> {
    const result = await withRefreshTransaction(db, uid, generation, async (tx) => {
      await plansRepo.saveOverride(tx as unknown as Db, uid, override);
      return true;
    });
    return result === true;
  },

  async markProvisionedForRefresh(db: Db, uid: string, generation: number): Promise<boolean> {
    const result = await withRefreshTransaction(db, uid, generation, async (tx) => {
      await tx
        .insert(usersTable)
        .values({ uid, mintProvisioned: true })
        .onConflictDoUpdate({
          target: usersTable.uid,
          set: { mintProvisioned: true },
        });
      return true;
    });
    return result === true;
  },

  /** Actual ban/unban SQL is fenced, not merely the route callback entry. */
  async setBannedForRefresh(
    db: Db,
    uid: string,
    banned: boolean,
    reason: string,
    bannedAtIso: string,
    generation: number,
  ): Promise<boolean> {
    const result = await withRefreshTransaction(db, uid, generation, async (tx) => {
      if (banned) {
        await tx.execute(sql`
          INSERT INTO users (uid, banned_at, banned_reason)
          VALUES (${uid}, ${bannedAtIso}, ${reason})
          ON CONFLICT (uid) DO UPDATE
            SET banned_at = EXCLUDED.banned_at, banned_reason = EXCLUDED.banned_reason`);
      } else {
        await tx.execute(sql`
          UPDATE users SET banned_at = NULL, banned_reason = NULL WHERE uid = ${uid}`);
      }
      return true;
    });
    return result === true;
  },

  /**
   * Durable anomaly standing intent. It commits before any Redis/key effect;
   * later failures leave this pending for the next account-locked retry.
   */
  async beginAnomalyStandingProjection(
    db: Db,
    uid: string,
    generation: number,
    bannedAtIso: string,
  ): Promise<void> {
    const token = anomalyStandingToken(uid);
    await db
      .insert(billingPurchasesTable)
      .values({
        token,
        uid: null,
        productId: "anomaly_standing",
        tier: "free",
        status: "pending",
        expiresAt: null,
        autoRenewing: false,
        linkedToken: null,
        accountHash: anomalyStandingMetadata(generation, bannedAtIso),
        updatedAt: Math.floor(Date.now() / 1000),
      })
      .onConflictDoUpdate({
        target: billingPurchasesTable.token,
        set: {
          status: "pending",
          accountHash: anomalyStandingMetadata(generation, bannedAtIso),
          updatedAt: Math.floor(Date.now() / 1000),
        },
      });
  },

  async completeAnomalyStandingProjection(
    db: Db,
    uid: string,
    generation: number,
  ): Promise<boolean> {
    const token = anomalyStandingToken(uid);
    return db.transaction(async (tx) => {
      const [row] = await tx.select().from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.token, token)).limit(1).for("update");
      const current = row === undefined ? null : readAnomalyStanding(row, uid);
      if (current === null || current.status !== "pending" || current.generation !== generation) {
        return false;
      }
      await tx.update(billingPurchasesTable)
        .set({ status: "replaced", updatedAt: Math.floor(Date.now() / 1000) })
        .where(eq(billingPurchasesTable.token, token));
      return true;
    });
  },

  async getPendingAnomalyStandingProjection(
    db: Db,
    uid: string,
  ): Promise<AnomalyStandingProjection | null> {
    const [row] = await db.select().from(billingPurchasesTable)
      .where(eq(billingPurchasesTable.token, anomalyStandingToken(uid))).limit(1);
    if (row === undefined) return null;
    const current = readAnomalyStanding(row, uid);
    if (current === null) throw new Error("anomaly standing projection is malformed");
    return current.status === "pending" ? current : null;
  },

  /** All account purchases (Play and RevenueCat); marker rows never have a uid. */
  async listPurchases(db: Db, uid: string): Promise<PurchaseRow[]> {
    return db
      .select()
      .from(billingPurchasesTable)
      .where(eq(billingPurchasesTable.uid, uid));
  },

  /** Read one RevenueCat transaction by its server-supplied original id. */
  async getPurchase(db: Db, transactionId: string): Promise<PurchaseRow | null> {
    const [row] = await db
      .select()
      .from(billingPurchasesTable)
      .where(
        and(
          eq(billingPurchasesTable.token, purchaseToken(transactionId)),
          like(billingPurchasesTable.token, "revenuecat:purchase:%"),
        ),
      )
      .limit(1);
    return row ?? null;
  },

  /**
   * Atomically apply one verified event. A transaction-scoped advisory lock
   * serializes even first-row inserts, so a newer refund cannot be overwritten
   * by an older concurrent initial purchase. Replay metadata preserves every
   * previous owner needed to repair a failed account-switch projection.
   */
  async applyRevenueCatEvent(
    db: Db,
    input: RevenueCatEventWrite,
  ): Promise<RevenueCatApplyResult> {
    return db.transaction(async (tx) => {
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${"revenuecat:event-write"}, 0))`);
      const markerToken = eventToken(input.eventId);
      const [marker] = await tx
        .select()
        .from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.token, markerToken))
        .limit(1);
      if (marker !== undefined) return replayResult(marker);

      const token = purchaseToken(input.transactionId);
      const [existing] = await tx
        .select()
        .from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.token, token))
        .limit(1)
        .for("update");
      const previousUids = existing?.uid ? [existing.uid] : [];
      const stale = existing !== undefined && persistedEventTime(existing) > input.occurredAt;
      const ownerUid = stale ? (existing?.uid ?? input.uid) : input.uid;

      if (!stale) {
        const ent = input.entitlement;
        await tx
          .insert(billingPurchasesTable)
          .values({
            token,
            uid: input.uid,
            productId: ent.productId,
            tier: ent.tier,
            status: ent.purchaseState,
            expiresAt: ent.expiresAt,
            autoRenewing: ent.autoRenewing,
            linkedToken: null,
            accountHash: `${EVENT_TIME_PREFIX}${input.occurredAt}`,
            updatedAt: Math.trunc(input.occurredAt),
          })
          .onConflictDoUpdate({
            target: billingPurchasesTable.token,
            set: {
              uid: input.uid,
              productId: ent.productId,
              tier: ent.tier,
              status: ent.purchaseState,
              expiresAt: ent.expiresAt,
              autoRenewing: ent.autoRenewing,
              linkedToken: null,
              accountHash: `${EVENT_TIME_PREFIX}${input.occurredAt}`,
              updatedAt: Math.trunc(input.occurredAt),
            },
          });
      }
      await tx
        .insert(billingPurchasesTable)
        .values(markerValues(input.eventId, input.occurredAt, ownerUid, previousUids));
      return applyResult(stale ? "stale" : "applied", ownerUid, previousUids, true);
    });
  },

  /** Official TRANSFER has no transaction/product fields: move existing rows by account. */
  async transferRevenueCatEvent(
    db: Db,
    input: RevenueCatTransferWrite,
  ): Promise<RevenueCatApplyResult> {
    return db.transaction(async (tx) => {
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${"revenuecat:event-write"}, 0))`);
      const markerToken = eventToken(input.eventId);
      const [marker] = await tx
        .select()
        .from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.token, markerToken))
        .limit(1);
      if (marker !== undefined) return replayResult(marker);

      const fromUids = [...new Set(input.fromUids.filter((uid) => uid !== input.toUid))];
      const previousUids = [...new Set(input.fromUids)];
      if (fromUids.length > 0) {
        const rows = await tx
          .select()
          .from(billingPurchasesTable)
          .where(
            and(
              inArray(billingPurchasesTable.uid, fromUids),
              like(billingPurchasesTable.token, "revenuecat:purchase:%"),
            ),
          )
          .for("update");
        for (const row of rows) {
          if (persistedEventTime(row) > input.occurredAt) continue;
          await tx
            .update(billingPurchasesTable)
            .set({
              uid: input.toUid,
              accountHash: `${EVENT_TIME_PREFIX}${input.occurredAt}`,
              updatedAt: Math.trunc(input.occurredAt),
            })
            .where(eq(billingPurchasesTable.token, row.token));
        }
      }
      await tx
        .insert(billingPurchasesTable)
        .values(markerValues(input.eventId, input.occurredAt, input.toUid, previousUids));
      return applyResult("applied", input.toUid, previousUids, true);
    });
  },

  /** Mark only after every affected users/Redis/LiteLLM projection succeeded. */
  async markRevenueCatEventProjected(db: Db, eventId: string): Promise<void> {
    await db
      .update(billingPurchasesTable)
      .set({ status: "replaced" })
      .where(eq(billingPurchasesTable.token, eventToken(eventId)));
  },

  /**
   * Serialize one account's complete billing LiteLLM update sequence across
   * processes. The lock is held until every remote request resolves; a newer
   * refresh therefore cannot return success while an older request is in
   * flight. The session lock releases on callback end/disconnect. Short nested
   * transactions commit recovery records before any unresolved error escapes.
   */
  async withBillingRemoteWriteLock<T>(
    db: Db,
    uid: string,
    operation: (lockedDb: Db) => Promise<T>,
  ): Promise<T> {
    const reserved = await db.$client.reserve();
    // postgres.js reserve() has query helpers + release(), but NO begin().
    // Drizzle calls client.begin for every short recovery transaction. Supply
    // a transaction-capable adapter using the RESERVED connection's supported
    // tagged/unsafe queries; never call the main pool begin (max:1 starvation).
    reserved.options = db.$client.options;
    let savepointSequence = 0;
    const savepoint = async (
      nameOrOperation: string | ((client: unknown) => unknown),
      maybeOperation?: (client: unknown) => unknown,
    ): Promise<unknown> => {
      const name = `billing_s${savepointSequence++}`;
      const operation = typeof nameOrOperation === "string" ? maybeOperation : nameOrOperation;
      if (operation === undefined) throw new Error("savepoint callback required");
      await reserved`SAVEPOINT ${reserved(name)}`;
      try {
        const result = await operation(reserved);
        await reserved`RELEASE SAVEPOINT ${reserved(name)}`;
        return result;
      } catch (error) {
        await reserved`ROLLBACK TO SAVEPOINT ${reserved(name)}`;
        await reserved`RELEASE SAVEPOINT ${reserved(name)}`;
        throw error;
      }
    };
    const begin = async (
      optionsOrOperation: string | ((client: unknown) => unknown),
      maybeOperation?: (client: unknown) => unknown,
    ): Promise<unknown> => {
      const options = typeof optionsOrOperation === "string" ? optionsOrOperation : "";
      const operation = typeof optionsOrOperation === "string" ? maybeOperation : optionsOrOperation;
      if (operation === undefined) throw new Error("transaction callback required");
      // Match postgres.js's option sanitization; normal billing calls use no
      // options. BEGIN/COMMIT/ROLLBACK execute on this same reserved handle.
      await reserved.unsafe(`BEGIN ${options.replace(/[^a-z ]/ig, "")}`);
      try {
        const result = await operation(reserved);
        await reserved`COMMIT`;
        return result;
      } catch (error) {
        await reserved`ROLLBACK`;
        throw error;
      }
    };
    // These are explicit supported transaction boundaries, not a pretend
    // postgres.js pool transaction. Nested Drizzle transactions use savepoints.
    Object.assign(reserved, { begin, savepoint });
    const locked = drizzle(reserved);
    try {
      await reserved`SET lock_timeout = '30s'`;
      await reserved`
        SELECT pg_advisory_lock(hashtextextended(${`revenuecat:litellm-write:${uid}`}, 0))`;
      // This is a SESSION lock, not an enclosing transaction. Each nested
      // intent/phase/standing transaction commits independently before remote
      // I/O or an unresolved result is rethrown. max:1 uses this same handle.
      return await operation(locked);
    } finally {
      try {
        await reserved`
          SELECT pg_advisory_unlock(hashtextextended(${`revenuecat:litellm-write:${uid}`}, 0))`;
      } catch {
        // Clear only an aborted nested transaction; earlier commits survive.
        try {
          await reserved`ROLLBACK`;
          await reserved`
            SELECT pg_advisory_unlock(hashtextextended(${`revenuecat:litellm-write:${uid}`}, 0))`;
        } catch {
          // Releasing below also drops the session lock if the handle died.
        }
      } finally {
        await reserved.release();
      }
    }
  },

  /** The unresolved remote mutation for an account, if a response was lost. */
  async getPendingRemoteOperation(
    db: Db,
    uid: string,
  ): Promise<BillingRemoteOperation | null> {
    const [row] = await db
      .select()
      .from(billingPurchasesTable)
      .where(eq(billingPurchasesTable.token, remoteToken(uid)))
      .limit(1);
    if (row === undefined || row.status !== "pending") return null;
    const operation = readRemoteOperation(row, uid);
    if (operation === null) throw new Error("billing remote outbox is malformed");
    return operation;
  },

  /**
   * Write the intent before the remote request. A pending older operation is
   * never overwritten: a newer generation must reconcile it first.
   */
  async beginRemoteOperation(
    db: Db,
    operation: BillingRemoteOperation,
  ): Promise<boolean> {
    return db.transaction(async (tx) => {
      const [refresh] = await tx
        .select({ accountHash: billingPurchasesTable.accountHash })
        .from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.token, refreshToken(operation.uid)))
        .limit(1)
        .for("update");
      if (refresh?.accountHash !== String(operation.generation)) return false;
      const [existing] = await tx
        .select()
        .from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.token, remoteToken(operation.uid)))
        .limit(1)
        .for("update");
      if (existing?.status === "pending") {
        const pending = readRemoteOperation(existing, operation.uid);
        if (pending === null || pending.retryable !== true) return false;
      }
      await tx
        .insert(billingPurchasesTable)
        .values({
          token: remoteToken(operation.uid),
          uid: null,
          productId: "litellm_remote",
          tier: "free",
          status: "pending",
          expiresAt: null,
          autoRenewing: false,
          linkedToken: null,
          accountHash: remoteMetadata(operation),
          updatedAt: Math.floor(Date.now() / 1000),
        })
        .onConflictDoUpdate({
          target: billingPurchasesTable.token,
          set: {
            status: "pending",
            accountHash: remoteMetadata(operation),
            updatedAt: Math.floor(Date.now() / 1000),
          },
        });
      return true;
    });
  },

  /** A definite HTTP error has no unresolved response; permit an explicit retry. */
  async markRemoteOperationRetryable(
    db: Db,
    operation: BillingRemoteOperation,
  ): Promise<boolean> {
    return db.transaction(async (tx) => {
      const [row] = await tx
        .select()
        .from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.token, remoteToken(operation.uid)))
        .limit(1)
        .for("update");
      if (row === undefined || row.status !== "pending") return false;
      const current = readRemoteOperation(row, operation.uid);
      if (current === null || !sameRemoteOperation(current, operation)) return false;
      await tx
        .update(billingPurchasesTable)
        .set({
          accountHash: remoteMetadata({ ...operation, retryable: true }),
          updatedAt: Math.floor(Date.now() / 1000),
        })
        .where(eq(billingPurchasesTable.token, remoteToken(operation.uid)));
      return true;
    });
  },

  /** Complete only after a remote readback proves this exact operation's state. */
  async completeRemoteOperation(
    db: Db,
    operation: BillingRemoteOperation,
  ): Promise<boolean> {
    return db.transaction(async (tx) => {
      const [row] = await tx
        .select()
        .from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.token, remoteToken(operation.uid)))
        .limit(1)
        .for("update");
      if (row === undefined || row.status !== "pending") return false;
      const current = readRemoteOperation(row, operation.uid);
      if (current === null || !sameRemoteOperation(current, operation)) return false;
      await tx
        .update(billingPurchasesTable)
        .set({ status: "replaced", updatedAt: Math.floor(Date.now() / 1000) })
        .where(eq(billingPurchasesTable.token, remoteToken(operation.uid)));
      return true;
    });
  },

  /**
   * Allocate a latest-refresh generation and snapshot the account atomically.
   * Callers hold the account scope lock before this allocation and through
   * projection. A stable recoveryId reuses that logical operation's generation.
   */
  async beginRefresh(db: Db, uid: string, recoveryId?: string): Promise<RevenueCatRefreshSnapshot> {
    return db.transaction(async (tx) => {
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${`revenuecat:refresh-lock:${uid}`}, 0))`);
      const token = refreshToken(uid);
      const [existing] = await tx
        .select()
        .from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.token, token))
        .limit(1)
        .for("update");
      const parsed = Number(existing?.accountHash ?? "0");
      const current = Number.isSafeInteger(parsed) && parsed >= 1 ? parsed : 0;
      const reuse = recoveryId !== undefined && current >= 1 && existing?.linkedToken === recoveryId;
      const generation = reuse ? current : current + 1;
      if (!reuse) {
        await tx
          .insert(billingPurchasesTable)
          .values({
            token,
            uid: null,
            productId: "revenuecat_refresh",
            tier: "free",
            status: "replaced",
            expiresAt: null,
            autoRenewing: false,
            linkedToken: recoveryId ?? null,
            accountHash: String(generation),
            updatedAt: Math.floor(Date.now() / 1000),
          })
          .onConflictDoUpdate({
            target: billingPurchasesTable.token,
            set: {
              accountHash: String(generation),
              linkedToken: recoveryId ?? null,
              updatedAt: Math.floor(Date.now() / 1000),
            },
          });
      }
      const rows = await tx
        .select()
        .from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.uid, uid));
      return { generation, rows };
    });
  },

  /** A newer beginRefresh supersedes every older users/Redis/LiteLLM write. */
  async isLatestRefresh(db: Db, uid: string, generation: number): Promise<boolean> {
    const [row] = await db
      .select({ accountHash: billingPurchasesTable.accountHash })
      .from(billingPurchasesTable)
      .where(eq(billingPurchasesTable.token, refreshToken(uid)))
      .limit(1);
    return row?.accountHash === String(generation);
  },
};
