import { and, eq, inArray, or, sql } from "drizzle-orm";
import type { Db } from "./client.js";
import { imageDeletedAccounts, imageJobs as imageJobsTable } from "./schema.js";

/**
 * Images ledger primitives (P9 Task 12). The ImageLedger wrapper in
 * @ovid/mint owns the money/error semantics and the per-account advisory lock
 * (`withUidLock(db, "img:<account>")`); this module only reads/writes the
 * Task-2 `image_jobs` / `image_deleted_accounts` tables.
 *
 * `imageJobsRepo` in moneyRepos.ts stays the raw-row import surface for
 * Task 18; runtime code goes through this module instead.
 */

/** The transaction handle drizzle hands to `db.transaction(cb)`. */
export type ImagesTx = Parameters<Parameters<Db["transaction"]>[0]>[0];
export type ImagesDbOrTx = Db | ImagesTx;

/**
 * Tx exposes the same query-builder surface as Db; the only Db-only member is
 * `$client`, which these methods never touch (same cast as scheduleRepos).
 */
function q(db: ImagesDbOrTx): Db {
  return db as Db;
}

/**
 * Explicit transaction on an already-reserved connection. postgres.js
 * `reserve()` handles do not expose `.begin()`, so drizzle's
 * `db.transaction()` cannot be used inside `withUidLock`; BEGIN/COMMIT/ROLLBACK
 * through the same handle keeps the whole critical section on one session.
 */
export async function withImagesTransaction<T>(
  db: Db,
  fn: (tx: Db) => Promise<T>,
): Promise<T> {
  await db.execute(sql`BEGIN`);
  try {
    const result = await fn(db);
    await db.execute(sql`COMMIT`);
    return result;
  } catch (error) {
    try {
      await db.execute(sql`ROLLBACK`);
    } catch {
      // Connection already aborted; withUidLock's unlock retries a ROLLBACK.
    }
    throw error;
  }
}

export type ImagesJobRow = typeof imageJobsTable.$inferSelect;

export interface ImageSpendRow {
  state: string;
  reserved: string;
  charged: string;
}

export interface SettlePatch {
  state: "done";
  servedModel: string | null;
  actual: string | null;
  charged: string;
  response: Record<string, unknown> | null;
  replayUntil: number;
  receiptUntil: number;
}

export const imagesRepo = {
  /** One ledger row by (account, request). */
  async get(
    db: ImagesDbOrTx,
    account: string,
    request: string,
  ): Promise<ImagesJobRow | null> {
    const [row] = await q(db)
      .select()
      .from(imageJobsTable)
      .where(and(eq(imageJobsTable.account, account), eq(imageJobsTable.request, request)))
      .limit(1);
    return row ?? null;
  },

  /** The account tombstone check every read/admission path starts with. */
  async isDeleted(db: ImagesDbOrTx, account: string): Promise<boolean> {
    const [row] = await q(db)
      .select({ account: imageDeletedAccounts.account })
      .from(imageDeletedAccounts)
      .where(eq(imageDeletedAccounts.account, account))
      .limit(1);
    return row !== undefined;
  },

  /** Admission row: fresh pending reservation. */
  async insertPending(
    db: ImagesDbOrTx,
    row: {
      account: string;
      request: string;
      fingerprint: string;
      reserved: string;
      budgetWindow: string;
      createdAt: number;
    },
  ): Promise<void> {
    await q(db).insert(imageJobsTable).values({ ...row, state: "pending", charged: "0" });
  },

  /**
   * Rows counted at admission: the same budget window OR any unresolved
   * reservation (pending/unknown never expire, so a window reset cannot hide
   * them).
   */
  async listForAdmission(
    db: ImagesDbOrTx,
    account: string,
    budgetWindow: string,
  ): Promise<ImageSpendRow[]> {
    return q(db)
      .select({
        state: imageJobsTable.state,
        reserved: imageJobsTable.reserved,
        charged: imageJobsTable.charged,
      })
      .from(imageJobsTable)
      .where(
        and(
          eq(imageJobsTable.account, account),
          or(
            eq(imageJobsTable.budgetWindow, budgetWindow),
            inArray(imageJobsTable.state, ["pending", "unknown"]),
          ),
        ),
      );
  },

  /** spent() rows; `budgetWindow === null` means every window. */
  async listForSpent(
    db: ImagesDbOrTx,
    account: string,
    budgetWindow: string | null,
  ): Promise<ImageSpendRow[]> {
    const where =
      budgetWindow === null
        ? eq(imageJobsTable.account, account)
        : and(
            eq(imageJobsTable.account, account),
            eq(imageJobsTable.budgetWindow, budgetWindow),
          );
    return q(db)
      .select({
        state: imageJobsTable.state,
        reserved: imageJobsTable.reserved,
        charged: imageJobsTable.charged,
      })
      .from(imageJobsTable)
      .where(where);
  },

  /** pending|unknown -> done, with the exact charge and retention leases. */
  async settleRow(
    db: ImagesDbOrTx,
    account: string,
    request: string,
    patch: SettlePatch,
  ): Promise<ImagesJobRow> {
    const [row] = await q(db)
      .update(imageJobsTable)
      .set(patch)
      .where(and(eq(imageJobsTable.account, account), eq(imageJobsTable.request, request)))
      .returning();
    return row!;
  },

  /** pending -> unknown ONLY (never expires, never auto-resubmits). */
  async markUnknown(db: ImagesDbOrTx, account: string, request: string): Promise<void> {
    await q(db)
      .update(imageJobsTable)
      .set({ state: "unknown" })
      .where(
        and(
          eq(imageJobsTable.account, account),
          eq(imageJobsTable.request, request),
          eq(imageJobsTable.state, "pending"),
        ),
      );
  },

  /** pending -> failed, releasing the reservation (receipt retained). */
  async markFailed(
    db: ImagesDbOrTx,
    account: string,
    request: string,
    receiptUntil: number,
  ): Promise<void> {
    await q(db)
      .update(imageJobsTable)
      .set({ state: "failed", reserved: "0", receiptUntil })
      .where(
        and(
          eq(imageJobsTable.account, account),
          eq(imageJobsTable.request, request),
          eq(imageJobsTable.state, "pending"),
        ),
      );
  },

  /**
   * Retention sweep: null response blobs past replayUntil and actual values
   * past receiptUntil. Dedup rows, charges and unresolved reservations are
   * never deleted or altered. Returns the number of rows touched.
   */
  async purgeExpired(db: ImagesDbOrTx, now: number, limit: number): Promise<number> {
    const rows = await q(db).execute(sql`
      UPDATE image_jobs SET
        response = CASE WHEN replay_until <= ${now} THEN NULL ELSE response END,
        actual = CASE WHEN receipt_until <= ${now} THEN NULL ELSE actual END
      WHERE (account, request) IN (
        SELECT account, request FROM image_jobs
        WHERE (response IS NOT NULL AND replay_until <= ${now})
           OR (actual IS NOT NULL AND receipt_until <= ${now})
        LIMIT ${limit}
      )
      RETURNING account, request
    `);
    return rows.length;
  },

  /** Idempotent tombstone; the first deletedAt wins. */
  async insertDeleted(
    db: ImagesDbOrTx,
    account: string,
    deletedAt: number,
  ): Promise<void> {
    await q(db)
      .insert(imageDeletedAccounts)
      .values({ account, deletedAt })
      .onConflictDoNothing();
  },

  /** Null every blob/actual and expire both leases for an account. */
  async clearAccount(db: ImagesDbOrTx, account: string): Promise<void> {
    await q(db)
      .update(imageJobsTable)
      .set({ response: null, actual: null, replayUntil: 0, receiptUntil: 0 })
      .where(eq(imageJobsTable.account, account));
  },
};
