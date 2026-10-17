import { createHash, randomBytes } from "node:crypto";
import { and, asc, desc, eq, gt, inArray, isNotNull, isNull, lte, or, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/postgres-js";
import type { Db } from "./client.js";
import { newId } from "./repos.js";
import {
  accountDeletions as accountDeletionsTable,
  billingPurchases as billingPurchasesTable,
  byokKeys as byokKeysTable,
  imageDeletedAccounts,
  imageJobs as imageJobsTable,
  mintSettings,
  plans as plansTable,
  reports as reportsTable,
  shareForks,
  shares as sharesTable,
  userPlanOverrides,
  users as usersTable,
} from "./schema.js";

// ---------------------------------------------------------------------------
// P9 Task 2: money & accounts repos. Ports of the Python durable stores:
// server/billing/store.py (billingPurchases), server/shares/repository.py
// (sharesRepo), server/reports/repository.py (reportsRepo), the account
// deletion table access (server/account/postgres.py) and its advisory-lock
// discipline (withUidLock). MONEY IS SACRED: every money value crosses this
// boundary as an exact decimal string in a text column — never a float.
// ---------------------------------------------------------------------------

/** Detects PostgreSQL unique-violation (23505) through drizzle's error wrap. */
function isUniqueViolation(err: unknown): boolean {
  let e: unknown = err;
  for (let depth = 0; e instanceof Error && depth < 5; depth++) {
    if ((e as { code?: string }).code === "23505") return true;
    e = (e as { cause?: unknown }).cause;
  }
  return false;
}

// ---------------------------------------------------------------------------
// plansRepo — plans-as-data, mint settings singleton, per-user overrides
// ---------------------------------------------------------------------------

export type PlanRecord = typeof plansTable.$inferSelect;

export interface MintSettingsRecord {
  baseDailyUsd: string;
  /** The ovid_plans.py SCALARS set as native numbers (Task 4 serializes for Redis). */
  scalars: Record<string, number>;
  autoOssMembers: { model: string; weight: number }[];
}

/** Redis user:{uid}:pools shape — snake_case keys kept verbatim (hook reads them). */
export type PoolsOverride = NonNullable<typeof userPlanOverrides.$inferSelect["pools"]>;

export interface OverrideRecord {
  dailyUsd: string | null;
  monthlyCapUsd: string | null;
  pools: PoolsOverride | null;
}

function overrideOf(row: typeof userPlanOverrides.$inferSelect): OverrideRecord {
  return { dailyUsd: row.dailyUsd, monthlyCapUsd: row.monthlyCapUsd, pools: row.pools ?? null };
}

export const plansRepo = {
  /** All plans ordered by console position (drives /plans and the admin table). */
  async list(db: Db): Promise<PlanRecord[]> {
    return db.select().from(plansTable).orderBy(asc(plansTable.position), asc(plansTable.id));
  },

  /** Full-row upsert keyed by plan id. */
  async upsert(db: Db, p: PlanRecord): Promise<void> {
    await db
      .insert(plansTable)
      .values(p)
      .onConflictDoUpdate({
        target: plansTable.id,
        set: {
          name: p.name,
          priceUsd: p.priceUsd,
          enabled: p.enabled,
          aliases: p.aliases,
          windowHours: p.windowHours,
          mult: p.mult,
          slowMode: p.slowMode,
          autoOss: p.autoOss,
          position: p.position,
        },
      });
  },

  async setEnabled(db: Db, id: string, enabled: boolean): Promise<void> {
    await db.update(plansTable).set({ enabled }).where(eq(plansTable.id, id));
  },

  async getSettings(db: Db): Promise<MintSettingsRecord | null> {
    const [row] = await db.select().from(mintSettings).where(eq(mintSettings.id, 1)).limit(1);
    if (!row) return null;
    return {
      baseDailyUsd: row.baseDailyUsd,
      scalars: row.scalars,
      autoOssMembers: row.autoOssMembers,
    };
  },

  /** Upserts the singleton (id = 1) — Postgres is the authority (Ruling Q4). */
  async saveSettings(db: Db, s: MintSettingsRecord): Promise<void> {
    await db
      .insert(mintSettings)
      .values({ id: 1, ...s, updatedAt: new Date() })
      .onConflictDoUpdate({
        target: mintSettings.id,
        set: {
          baseDailyUsd: s.baseDailyUsd,
          scalars: s.scalars,
          autoOssMembers: s.autoOssMembers,
          updatedAt: new Date(),
        },
      });
  },

  async getOverride(db: Db, uid: string): Promise<OverrideRecord | null> {
    const [row] = await db
      .select()
      .from(userPlanOverrides)
      .where(eq(userPlanOverrides.uid, uid))
      .limit(1);
    return row ? overrideOf(row) : null;
  },

  /**
   * Partial upsert: fields present in `o` are written (null CLEARS the field),
   * absent fields keep their stored value; `o === null` removes the override.
   * When nothing remains set the row is deleted so the table stays meaningful.
   */
  async saveOverride(
    db: Db,
    uid: string,
    o: Partial<OverrideRecord> | null,
  ): Promise<void> {
    if (o === null) {
      await db.delete(userPlanOverrides).where(eq(userPlanOverrides.uid, uid));
      return;
    }
    const [existing] = await db
      .select()
      .from(userPlanOverrides)
      .where(eq(userPlanOverrides.uid, uid))
      .limit(1);
    const merged: OverrideRecord = {
      dailyUsd: o.dailyUsd !== undefined ? o.dailyUsd : (existing?.dailyUsd ?? null),
      monthlyCapUsd:
        o.monthlyCapUsd !== undefined ? o.monthlyCapUsd : (existing?.monthlyCapUsd ?? null),
      pools: o.pools !== undefined ? o.pools : (existing?.pools ?? null),
    };
    if (merged.dailyUsd === null && merged.monthlyCapUsd === null && merged.pools === null) {
      await db.delete(userPlanOverrides).where(eq(userPlanOverrides.uid, uid));
      return;
    }
    await db
      .insert(userPlanOverrides)
      .values({ uid, ...merged, updatedAt: new Date() })
      .onConflictDoUpdate({
        target: userPlanOverrides.uid,
        set: { ...merged, updatedAt: new Date() },
      });
  },

  /** Every provisioned user — the durable replacement for ovid:uids scans. */
  async allUids(db: Db): Promise<string[]> {
    const rows = await db
      .select({ uid: usersTable.uid })
      .from(usersTable)
      .orderBy(asc(usersTable.uid));
    return rows.map((r) => r.uid);
  },
};

// ---------------------------------------------------------------------------
// billingPurchases — the durable Play-Billing ledger (store.py port)
// ---------------------------------------------------------------------------

/**
 * The persisted ledger shape. PINNED HERE (Task 2) so the ledger schema and
 * Task 10's billing port cannot drift; Task 10's Entitlement extends this with
 * the verify-time-only fields (acknowledged, test_purchase, state). snake_case
 * mirrors the Python domain object exactly.
 */
export interface EntitlementFields {
  status: "active" | "pending" | "expired" | "revoked" | "replaced";
  tier: string;
  product_id: string;
  expires_at: number | null;
  auto_renewing: boolean;
  linked_token: string | null;
  account_hash: string | null;
}

export type PurchaseRow = typeof billingPurchasesTable.$inferSelect;

/** A token bound to one account, replayed from another — the 409 path. */
export class PurchaseConflictError extends Error {
  constructor(message = "purchase_owned_by_another_account") {
    super(message);
    this.name = "PurchaseConflictError";
  }
}

/** Terminal local states a later Play read must never undo (store.py STICKY). */
const STICKY_STATUSES = new Set(["revoked", "replaced"]);

// Mirrors server/billing/products.py TIER_RANK = {tier: rank}. The canonical
// copy lives in Task 10's products.ts; duplicated here because @ovid/db must
// stay app-independent. Unknown tiers rank as free (rank 0), as in Python.
const TIER_RANK: Record<string, number> = { free: 0, "3x": 1, "7x": 2, "15x": 3 };
const tierRank = (tier: string): number => TIER_RANK[tier] ?? 0;

export const billingPurchases = {
  async get(db: Db, token: string): Promise<PurchaseRow | null> {
    const [row] = await db
      .select()
      .from(billingPurchasesTable)
      .where(eq(billingPurchasesTable.token, token))
      .limit(1);
    return row ?? null;
  },

  /**
   * Upsert of a fresh Play evaluation (store.py record). STICKY: an existing
   * revoked/replaced row keeps its status and drops to tier free — later Play
   * reads must never resurrect a revoked/refunded purchase. `uid` binds an
   * unbound token; a different existing owner raises PurchaseConflictError.
   * linked_token marks the OLD token replaced (tier free, auto-renew off).
   */
  async record(
    db: Db,
    token: string,
    ent: EntitlementFields,
    now: number,
    uid?: string | null,
  ): Promise<PurchaseRow> {
    return db.transaction(async (tx) => {
      const [existing] = await tx
        .select()
        .from(billingPurchasesTable)
        .where(eq(billingPurchasesTable.token, token))
        .limit(1);
      const owner = existing?.uid ?? null;
      if (uid != null && owner != null && owner !== uid) {
        throw new PurchaseConflictError();
      }
      const boundOwner = owner ?? uid ?? null;
      let status: string = ent.status;
      let tier: string = ent.tier;
      if (existing && STICKY_STATUSES.has(existing.status)) {
        status = existing.status;
        tier = "free";
      }
      const [row] = await tx
        .insert(billingPurchasesTable)
        .values({
          token,
          uid: boundOwner,
          productId: ent.product_id,
          tier,
          status,
          expiresAt: ent.expires_at,
          autoRenewing: ent.auto_renewing,
          linkedToken: ent.linked_token,
          accountHash: ent.account_hash,
          updatedAt: now,
        })
        .onConflictDoUpdate({
          target: billingPurchasesTable.token,
          set: {
            uid: boundOwner,
            productId: ent.product_id,
            tier,
            status,
            expiresAt: ent.expires_at,
            autoRenewing: ent.auto_renewing,
            linkedToken: ent.linked_token,
            accountHash: ent.account_hash,
            updatedAt: now,
          },
        })
        .returning();
      if (ent.linked_token && ent.linked_token !== token) {
        // Upgrade/downgrade/resubscribe: the old token no longer grants.
        await tx
          .update(billingPurchasesTable)
          .set({ status: "replaced", tier: "free", autoRenewing: false, updatedAt: now })
          .where(eq(billingPurchasesTable.token, ent.linked_token));
      }
      return row!;
    });
  },

  /** Terminal local transition (store.py mark): tier drops to free, renew off. */
  async mark(
    db: Db,
    token: string,
    status: "revoked" | "replaced",
    now: number,
  ): Promise<PurchaseRow | null> {
    const rows = await db
      .update(billingPurchasesTable)
      .set({ status, tier: "free", autoRenewing: false, updatedAt: now })
      .where(eq(billingPurchasesTable.token, token))
      .returning();
    return rows[0] ?? null;
  },

  /** Best currently-active purchase for the uid (null ⇒ free): highest tier, then latest expiry. */
  async effective(db: Db, uid: string, now: number): Promise<PurchaseRow | null> {
    const rows = await db
      .select()
      .from(billingPurchasesTable)
      .where(
        and(
          eq(billingPurchasesTable.uid, uid),
          eq(billingPurchasesTable.status, "active"),
          gt(billingPurchasesTable.expiresAt, now),
        ),
      );
    let best: PurchaseRow | null = null;
    for (const row of rows) {
      if (
        !best ||
        tierRank(row.tier) > tierRank(best.tier) ||
        (tierRank(row.tier) === tierRank(best.tier) && (row.expiresAt ?? 0) > (best.expiresAt ?? 0))
      ) {
        best = row;
      }
    }
    return best;
  },
};

// ---------------------------------------------------------------------------
// imageJobsRepo — RAW-ROW surface for the Task-18 migration scripts ONLY.
// App runtime goes through the Task-12 ImageLedger wrapper; no route or
// service code may call these directly (importImagesLedger/verifyMigration).
// ---------------------------------------------------------------------------

export type ImageJobRow = typeof imageJobsTable.$inferSelect;

export const imageJobsRepo = {
  /** Insert-if-absent import (ON CONFLICT DO NOTHING — never rewrites money). */
  async insertRaw(db: Db, row: ImageJobRow): Promise<void> {
    await db.insert(imageJobsTable).values(row).onConflictDoNothing();
  },

  /** Full rows (incl. response blobs) in deterministic (account, request) order. */
  async listRaw(
    db: Db,
    opts?: { states?: string[]; limit?: number },
  ): Promise<ImageJobRow[]> {
    const where =
      opts?.states && opts.states.length > 0
        ? inArray(imageJobsTable.state, opts.states)
        : undefined;
    const query = db
      .select()
      .from(imageJobsTable)
      .where(where)
      .orderBy(asc(imageJobsTable.account), asc(imageJobsTable.request));
    return opts?.limit ? query.limit(opts.limit) : query;
  },

  /** state → row count (pending/unknown parity check in verifyMigration). */
  async countByState(db: Db): Promise<Record<string, number>> {
    const rows = await db
      .select({ state: imageJobsTable.state, n: sql<number>`count(*)::int` })
      .from(imageJobsTable)
      .groupBy(imageJobsTable.state);
    return Object.fromEntries(rows.map((r) => [r.state, r.n]));
  },

  /** Tombstone import (idempotent — the first deletedAt wins). */
  async insertDeletedAccountRaw(db: Db, account: string, deletedAt: number): Promise<void> {
    await db
      .insert(imageDeletedAccounts)
      .values({ account, deletedAt })
      .onConflictDoNothing();
  },
};

// ---------------------------------------------------------------------------
// sharesRepo — snapshots with idempotent receipts (server/shares/repository.py)
// ---------------------------------------------------------------------------

export interface ShareMessage {
  role: string;
  content: string;
}

export interface ShareBody {
  sessionId: string;
  requestId: string;
  messages: ShareMessage[];
}

/**
 * The immutable receipt (what create returns and the wire shape is built
 * from): token + provenance + the sampled validity window. `createdAt`/
 * `expiresAt` are ms-precision Dates; Task 16 renders them as epoch seconds
 * for the legacy wire contract.
 */
export interface ShareReceiptRow {
  token: string;
  sessionId: string;
  requestId: string;
  createdAt: Date;
  expiresAt: Date;
}

/** 409 family: request id reuse, changed content, revoked/expired sources. */
export class ShareConflictError extends Error {
  readonly status = 409;
  constructor(readonly code: string = "request_already_used") {
    super(code);
    this.name = "ShareConflictError";
  }
}

/** 404 family: unknown token or wrong owner (no existence leaks). */
export class ShareNotFoundError extends Error {
  readonly status = 404;
  constructor(readonly code: string = "share_not_found") {
    super(code);
    this.name = "ShareNotFoundError";
  }
}

// Python snapshot fingerprint: sha256(sessionId + "\n" + json of {messages})
// with sorted keys and compact separators. We recompute it on both sides of
// the dedup comparison (never stored), so JSON.stringify's exact escaping
// only has to agree with itself.
function shareFingerprint(sessionId: string, messages: ShareMessage[]): string {
  const canonical = JSON.stringify({
    messages: messages.map((m) => ({ content: m.content, role: m.role })),
  });
  return createHash("sha256").update(`${sessionId}\n${canonical}`).digest("hex");
}

function receiptOf(row: typeof sharesTable.$inferSelect): ShareReceiptRow {
  return {
    token: row.token,
    sessionId: row.sessionId,
    requestId: row.requestId,
    createdAt: row.createdAt,
    expiresAt: row.expiresAt,
  };
}

/** Dedup against an existing receipt row (repository.py create's previous branch). */
function dedupOrConflict(
  row: typeof sharesTable.$inferSelect,
  body: ShareBody,
  now: Date,
): ShareReceiptRow {
  if (
    shareFingerprint(row.sessionId, row.content?.messages ?? []) !==
      shareFingerprint(body.sessionId, body.messages) ||
    row.revokedAt !== null ||
    row.content === null ||
    row.expiresAt.getTime() <= now.getTime()
  ) {
    throw new ShareConflictError();
  }
  return receiptOf(row);
}

function activeShareConditions(now: Date) {
  return [
    isNull(sharesTable.revokedAt),
    isNotNull(sharesTable.content),
    gt(sharesTable.expiresAt, now),
  ];
}

export const sharesRepo = {
  /**
   * Create with dedup on (ownerUid, requestId): identical retry → the SAME
   * receipt; changed content, revoked or expired previous → 409. Expiry is
   * evaluated against the caller's `now` inside the write transaction, so a
   * queued retry can never observe a born-expired receipt.
   */
  async create(
    db: Db,
    ownerUid: string,
    body: ShareBody,
    opts: { now: Date; ttlSeconds: number },
  ): Promise<ShareReceiptRow> {
    try {
      return await db.transaction(async (tx) => {
        const [previous] = await tx
          .select()
          .from(sharesTable)
          .where(and(eq(sharesTable.ownerUid, ownerUid), eq(sharesTable.requestId, body.requestId)))
          .limit(1);
        if (previous) return dedupOrConflict(previous, body, opts.now);
        const [row] = await tx
          .insert(sharesTable)
          .values({
            token: randomBytes(32).toString("base64url"), // 43 chars
            ownerUid,
            sessionId: body.sessionId,
            requestId: body.requestId,
            content: { messages: body.messages },
            messageCount: body.messages.length,
            createdAt: opts.now,
            expiresAt: new Date(opts.now.getTime() + opts.ttlSeconds * 1000),
          })
          .returning();
        return receiptOf(row!);
      });
    } catch (err) {
      if (isUniqueViolation(err)) {
        // Lost an insert race on (owner_uid, request_id) — rerun the dedup
        // path against the winner's row.
        const [previous] = await db
          .select()
          .from(sharesTable)
          .where(
            and(eq(sharesTable.ownerUid, ownerUid), eq(sharesTable.requestId, body.requestId)),
          )
          .limit(1);
        if (previous) return dedupOrConflict(previous, body, opts.now);
      }
      throw err;
    }
  },

  /** Active receipts only (content present, not revoked, unexpired), newest first. */
  async list(
    db: Db,
    ownerUid: string,
    sessionId?: string | null,
    opts?: { now?: Date },
  ): Promise<ShareReceiptRow[]> {
    const now = opts?.now ?? new Date();
    const conds = [eq(sharesTable.ownerUid, ownerUid), ...activeShareConditions(now)];
    if (sessionId != null) conds.push(eq(sharesTable.sessionId, sessionId));
    const rows = await db
      .select()
      .from(sharesTable)
      .where(and(...conds))
      .orderBy(desc(sharesTable.createdAt), asc(sharesTable.token));
    return rows.map(receiptOf);
  },

  /**
   * Replace the snapshot of a live owned link (repository.py update). The
   * receipt is unchanged — token, owner and expiry can never be revived.
   */
  async update(
    db: Db,
    ownerUid: string,
    token: string,
    body: ShareBody,
    opts?: { now?: Date },
  ): Promise<ShareReceiptRow> {
    const now = opts?.now ?? new Date();
    return db.transaction(async (tx) => {
      const [row] = await tx
        .select()
        .from(sharesTable)
        .where(
          and(
            eq(sharesTable.ownerUid, ownerUid),
            eq(sharesTable.token, token),
            ...activeShareConditions(now),
          ),
        )
        .limit(1);
      if (!row || row.sessionId !== body.sessionId) throw new ShareNotFoundError();
      await tx
        .update(sharesTable)
        .set({ content: { messages: body.messages }, messageCount: body.messages.length })
        .where(eq(sharesTable.token, token));
      return receiptOf(row);
    });
  },

  /** Idempotent for the owner; unknown token or wrong owner → 404. Clears content. */
  async revoke(
    db: Db,
    ownerUid: string,
    token: string,
    opts?: { now?: Date },
  ): Promise<void> {
    const rows = await db
      .update(sharesTable)
      .set({ revokedAt: opts?.now ?? new Date(), content: null })
      .where(and(eq(sharesTable.ownerUid, ownerUid), eq(sharesTable.token, token)))
      .returning({ token: sharesTable.token });
    if (rows.length === 0) throw new ShareNotFoundError();
  },

  /**
   * Fork a live share into the recipient's session id (repository.py fork).
   * Idempotent per (recipientUid, requestId); a request id already bound to a
   * different source token, or a revoked/expired/purged source → 409.
   */
  async fork(
    db: Db,
    recipientUid: string,
    token: string,
    requestId: string,
    opts?: { now?: Date },
  ): Promise<{ sessionId: string }> {
    const now = opts?.now ?? new Date();
    try {
      return await db.transaction(async (tx) => {
        const [source] = await tx
          .select()
          .from(sharesTable)
          .where(and(eq(sharesTable.token, token), ...activeShareConditions(now)))
          .limit(1);
        if (!source) throw new ShareConflictError("share_unavailable");
        const [previous] = await tx
          .select()
          .from(shareForks)
          .where(and(eq(shareForks.recipientUid, recipientUid), eq(shareForks.requestId, requestId)))
          .limit(1);
        if (previous) {
          if (previous.token !== token) throw new ShareConflictError();
          return { sessionId: previous.sessionId };
        }
        const sessionId = randomBytes(16).toString("base64url"); // 22 chars, like token_urlsafe(16)
        await tx
          .insert(shareForks)
          .values({ token, recipientUid, requestId, sessionId, createdAt: now });
        return { sessionId };
      });
    } catch (err) {
      if (isUniqueViolation(err)) {
        const [previous] = await db
          .select()
          .from(shareForks)
          .where(and(eq(shareForks.recipientUid, recipientUid), eq(shareForks.requestId, requestId)))
          .limit(1);
        if (previous && previous.token === token) return { sessionId: previous.sessionId };
      }
      throw err;
    }
  },

  /** Public viewer payload, or null on unknown/revoked/expired/purged tokens. */
  async publicSnapshot(
    db: Db,
    token: string,
    opts?: { now?: Date },
  ): Promise<{ sessionId: string; messages: ShareMessage[] } | null> {
    const now = opts?.now ?? new Date();
    const [row] = await db
      .select({ content: sharesTable.content, sessionId: sharesTable.sessionId })
      .from(sharesTable)
      .where(and(eq(sharesTable.token, token), isNull(sharesTable.revokedAt), gt(sharesTable.expiresAt, now)))
      .limit(1);
    if (!row || !row.content) return null;
    return { sessionId: row.sessionId, messages: row.content.messages };
  },

  /**
   * Retention sweep (repository.py purge_expired): clears content past expiry
   * in batches of `limit` (1..10000), oldest expiry first. Receipt rows are
   * kept — dedup history must survive so an old request can never republish.
   */
  async purgeExpired(db: Db, limit: number, opts?: { now?: Date }): Promise<number> {
    if (!Number.isInteger(limit) || limit < 1 || limit > 10000) {
      throw new Error("Retention batch size must be between 1 and 10000");
    }
    const now = opts?.now ?? new Date();
    const expired = db
      .select({ token: sharesTable.token })
      .from(sharesTable)
      .where(and(isNotNull(sharesTable.content), lte(sharesTable.expiresAt, now)))
      .orderBy(asc(sharesTable.expiresAt), asc(sharesTable.token))
      .limit(limit);
    const updated = await db
      .update(sharesTable)
      .set({ content: null })
      .where(inArray(sharesTable.token, expired))
      .returning({ token: sharesTable.token });
    return updated.length;
  },

  /**
   * Account-deletion cleanup: permanent tombstone semantics — receipt rows are
   * KEPT (dedup history) with content erased and purgedAt set; the recipient's
   * fork rows are removed. Idempotent. (Blocking future creates is the route
   * layer's lifecycle fence, not this repo's job.)
   */
  async deleteAccount(db: Db, uid: string, opts?: { now?: Date }): Promise<void> {
    const now = opts?.now ?? new Date();
    await db.transaction(async (tx) => {
      await tx
        .update(sharesTable)
        .set({ content: null, purgedAt: now })
        .where(eq(sharesTable.ownerUid, uid));
      await tx.delete(shareForks).where(eq(shareForks.recipientUid, uid));
    });
  },

  /** Quota counters for the owner: currently-active vs lifetime receipts. */
  async counts(
    db: Db,
    ownerUid: string,
    opts?: { now?: Date },
  ): Promise<{ active: number; lifetime: number }> {
    const now = opts?.now ?? new Date();
    const [active] = await db
      .select({ n: sql<number>`count(*)::int` })
      .from(sharesTable)
      .where(and(eq(sharesTable.ownerUid, ownerUid), ...activeShareConditions(now)));
    const [lifetime] = await db
      .select({ n: sql<number>`count(*)::int` })
      .from(sharesTable)
      .where(eq(sharesTable.ownerUid, ownerUid));
    return { active: active!.n, lifetime: lifetime!.n };
  },
};

// ---------------------------------------------------------------------------
// reportsRepo — moderation queue (server/reports/repository.py)
// ---------------------------------------------------------------------------

export type ReportRow = typeof reportsTable.$inferSelect;

export interface ReportBody {
  requestId: string;
  kind: string;
  reason: string;
  details: string;
  excerpt: string;
  targetId?: string | null;
  model?: string | null;
}

export const reportsRepo = {
  /**
   * Dedup on (reporterUid, requestId): a repeat returns the ORIGINAL id with
   * created:false (route answers 200 instead of 201). Insert-race safe: the
   * unique index makes the loser's insert a no-op and it falls back to the
   * stored row.
   */
  async create(
    db: Db,
    reporterUid: string,
    body: ReportBody,
  ): Promise<{ id: string; created: boolean }> {
    const inserted = await db
      .insert(reportsTable)
      .values({
        id: newId(),
        reporterUid,
        requestId: body.requestId,
        kind: body.kind,
        reason: body.reason,
        details: body.details,
        excerpt: body.excerpt,
        targetId: body.targetId ?? null,
        model: body.model ?? null,
      })
      .onConflictDoNothing({ target: [reportsTable.reporterUid, reportsTable.requestId] })
      .returning({ id: reportsTable.id });
    if (inserted[0]) return { id: inserted[0].id, created: true };
    const [existing] = await db
      .select({ id: reportsTable.id })
      .from(reportsTable)
      .where(
        and(eq(reportsTable.reporterUid, reporterUid), eq(reportsTable.requestId, body.requestId)),
      )
      .limit(1);
    return { id: existing!.id, created: false };
  },

  /** Reviewer queue, oldest first. */
  async listOpen(db: Db, limit: number): Promise<ReportRow[]> {
    return db
      .select()
      .from(reportsTable)
      .where(eq(reportsTable.status, "open"))
      .orderBy(asc(reportsTable.createdAt))
      .limit(limit);
  },
};

// ---------------------------------------------------------------------------
// byokKeysRepo — BYOK escrow storage (Task 11 routes/worker decrypt)
// ---------------------------------------------------------------------------

export type ByokKeyRow = typeof byokKeysTable.$inferSelect;

export interface ByokKeyInsert {
  userId: string;
  providerId: string;
  endpoint: string;
  label?: string | null;
  wrappedDek: string;
  iv: string;
  ciphertext: string;
  tag: string;
}

export const byokKeysRepo = {
  async create(db: Db, row: ByokKeyInsert): Promise<ByokKeyRow> {
    const [created] = await db
      .insert(byokKeysTable)
      .values({ id: newId(), ...row })
      .returning();
    return created!;
  },

  /** Insertion order. Ciphertext travels to the CALLER only — routes project. */
  async list(db: Db, userId: string): Promise<ByokKeyRow[]> {
    return db
      .select()
      .from(byokKeysTable)
      .where(eq(byokKeysTable.userId, userId))
      .orderBy(asc(byokKeysTable.createdAt), asc(byokKeysTable.id));
  },

  /** Null on unknown id OR wrong owner (the gateway's no-existence-leak rule). */
  async get(db: Db, id: string, userId: string): Promise<ByokKeyRow | null> {
    const [row] = await db
      .select()
      .from(byokKeysTable)
      .where(and(eq(byokKeysTable.id, id), eq(byokKeysTable.userId, userId)))
      .limit(1);
    return row ?? null;
  },

  /** true iff the row existed AND was owned by userId. */
  async remove(db: Db, id: string, userId: string): Promise<boolean> {
    const removed = await db
      .delete(byokKeysTable)
      .where(and(eq(byokKeysTable.id, id), eq(byokKeysTable.userId, userId)))
      .returning({ id: byokKeysTable.id });
    return removed.length > 0;
  },

  async setTestResult(db: Db, id: string, ok: boolean, at: Date): Promise<void> {
    await db
      .update(byokKeysTable)
      .set({ lastTestOk: ok, lastTestAt: at })
      .where(eq(byokKeysTable.id, id));
  },

  /** Cloud-cleanup step data:byok (Task 15) — remove ALL of the user's rows, idempotent. */
  async deleteAccount(db: Db, userId: string): Promise<void> {
    await db.delete(byokKeysTable).where(eq(byokKeysTable.userId, userId));
  },
};

// ---------------------------------------------------------------------------
// accountDeletions — lifecycle rows (server/account/postgres.py)
// ---------------------------------------------------------------------------

/**
 * The Python deletion record (server/account/domain.py row) kept verbatim in
 * jsonb — snake_case keys (request_id, next_attempt, attempts, fence_owned,
 * completed, …). Task 15 owns the typed port.
 */
export type DeletionRecordData = Record<string, unknown>;

export interface DeletionRecord {
  uid: string;
  state: string;
  /** Epoch seconds. */
  deleteAfter: number;
  record: DeletionRecordData;
}

const nextAttemptExpr = sql`COALESCE(CAST(${accountDeletionsTable.record} ->> 'next_attempt' AS double precision), 0)`;
const attemptsExpr = sql`COALESCE(CAST(${accountDeletionsTable.record} ->> 'attempts' AS bigint), 0)`;

export const accountDeletions = {
  /**
   * Uids the sweeper should finalize now, in the EXACT Python order:
   * next_attempt, attempts, delete_after, uid — LIMIT 100. Eligibility:
   * (state in pending/fenced/deleting AND delete_after <= now) OR
   * (state = cancelled AND record.fence_owned = 'true') AND next_attempt <= now.
   */
  async due(db: Db, now: number): Promise<string[]> {
    const rows = await db
      .select({ uid: accountDeletionsTable.uid })
      .from(accountDeletionsTable)
      .where(
        and(
          sql`${nextAttemptExpr} <= ${now}`,
          or(
            and(
              inArray(accountDeletionsTable.state, ["pending", "fenced", "deleting"]),
              lte(accountDeletionsTable.deleteAfter, now),
            ),
            and(
              eq(accountDeletionsTable.state, "cancelled"),
              sql`${accountDeletionsTable.record} ->> 'fence_owned' = 'true'`,
            ),
          ),
        ),
      )
      .orderBy(
        asc(nextAttemptExpr),
        asc(attemptsExpr),
        asc(accountDeletionsTable.deleteAfter),
        asc(accountDeletionsTable.uid),
      )
      .limit(100);
    return rows.map((r) => r.uid);
  },

  async get(db: Db, uid: string): Promise<DeletionRecord | null> {
    const [row] = await db
      .select()
      .from(accountDeletionsTable)
      .where(eq(accountDeletionsTable.uid, uid))
      .limit(1);
    return row
      ? { uid: row.uid, state: row.state, deleteAfter: row.deleteAfter, record: row.record }
      : null;
  },

  /** Upsert the whole lifecycle row (the record jsonb is replaced wholesale). */
  async save(db: Db, row: DeletionRecord): Promise<void> {
    await db
      .insert(accountDeletionsTable)
      .values({
        uid: row.uid,
        state: row.state,
        deleteAfter: row.deleteAfter,
        record: row.record,
        updatedAt: new Date(),
      })
      .onConflictDoUpdate({
        target: accountDeletionsTable.uid,
        set: {
          state: row.state,
          deleteAfter: row.deleteAfter,
          record: row.record,
          updatedAt: new Date(),
        },
      });
  },
};

// ---------------------------------------------------------------------------
// withUidLock — per-uid advisory lock (server/account/postgres.py locked())
// ---------------------------------------------------------------------------

/**
 * Runs `fn` under the per-uid advisory lock — the SAME seed as Python
 * (hashtextextended(uid, 714031)), so TS and Python writers interlock during
 * the dual-run. A DEDICATED connection is reserved from the pool: the
 * session-level lock must be taken, held and released on one connection, and
 * `fn` runs on that same connection (as Python's Session does) so the whole
 * critical section serializes. lock_timeout 30 s caps the wait.
 *
 * The lock is released in finally — even when fn throws or leaves a
 * transaction open (the unlock is retried after a ROLLBACK in that case) —
 * so a crashed section can never pin the uid forever.
 */
export async function withUidLock<T>(
  db: Db,
  uid: string,
  fn: (tx: Db) => Promise<T>,
): Promise<T> {
  const reserved = await db.$client.reserve();
  // postgres.js reserve() returns a bare Sql WITHOUT the pool's `options`
  // object (only the top-level sql gets it) — drizzle's constructor requires
  // client.options. Point it at the pool's (already drizzle-mutated) options.
  reserved.options = db.$client.options;
  const locked = drizzle(reserved);
  try {
    await reserved`SET lock_timeout = '30s'`;
    await reserved`SELECT pg_advisory_lock(hashtextextended(${uid}, 714031))`;
    return await fn(locked);
  } finally {
    try {
      await reserved`SELECT pg_advisory_unlock(hashtextextended(${uid}, 714031))`;
    } catch {
      // fn died inside an aborted transaction — every statement on the
      // connection errors until it is rolled back. Clear it, re-unlock.
      try {
        await reserved`ROLLBACK`;
        await reserved`SELECT pg_advisory_unlock(hashtextextended(${uid}, 714031))`;
      } catch {
        // Connection unusable; release below anyway (the server reaps it).
      }
    } finally {
      await reserved.release();
    }
  }
}
