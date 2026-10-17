import {
  InvalidMoneyError,
  discounted,
  exactSum,
  money,
  type Money,
} from "@ovid/money";
import {
  imagesRepo,
  withImagesTransaction,
  withUidLock,
  type Db,
  type ImagesJobRow,
} from "@ovid/db";
import {
  ImageError,
  RECEIPT_RETENTION,
  REPLAY_RETENTION,
  type Receipt,
} from "./types.js";

/**
 * Durable, decimal-exact image metering — port of the `Ledger` class in
 * server/images/service.py onto Postgres (`image_jobs` /
 * `image_deleted_accounts`).
 *
 * The account is a stable verified UID; idempotency survives budget-window
 * resets. Reservations persist until settled/reconciled and a pending job is
 * NEVER expired or auto-resubmitted. Every mutating section for one account
 * runs under the `img:<account>` advisory lock (the SQLite BEGIN IMMEDIATE
 * analogue), inside a transaction so a charge/receipt commit is atomic.
 */

export interface ImageLedger {
  /**
   * Admit one request. Returns the stored replay response for a completed
   * request, or null on fresh admission (row left pending). Existing rows
   * answer per the Python ladder: fingerprint mismatch 409
   * idempotency_conflict; done -> replay (410 image_replay_expired when the
   * blob is gone); receipt expired -> 410 image_receipt_expired;
   * pending/unknown -> 409 image_request_pending + receipt; failed -> 409
   * image_request_failed + receipt. Admission overdraw -> 402
   * image_limit_reached. Deleted account -> 410 image_account_deleted.
   */
  begin(
    account: string,
    request: string,
    fingerprint: string,
    reservation: Money,
    budget: Money,
    budgetWindow: string,
  ): Promise<Record<string, unknown> | null>;

  /** Settle a pending/unknown job; done is idempotent and never re-charges. */
  settle(
    account: string,
    request: string,
    actual: Money,
    response: Record<string, unknown>,
    servedModel?: string | null,
  ): Promise<Record<string, unknown>>;

  /** pending -> unknown ONLY (never expires, never auto-resubmits). */
  unknown(account: string, request: string): Promise<void>;

  /** pending -> failed, reservation released to "0", receipt kept 90 days. */
  fail(account: string, request: string): Promise<void>;

  receipt(account: string, request: string): Promise<Receipt>;

  replay(account: string, request: string): Promise<Record<string, unknown>>;

  spent(
    account: string,
    opts?: { includePending?: boolean; budgetWindow?: string | null },
  ): Promise<Money>;

  /** Bounded retention sweep; never removes dedup rows/charges/reservations. */
  purgeExpired(limit?: number): Promise<number>;

  /** Idempotent tombstone + blob purge; charges and dedup rows stay. */
  deleteAccount(account: string): Promise<void>;
}

export interface ImageLedgerOptions {
  clock?: () => number;
  replayRetention?: number;
  receiptRetention?: number;
}

/** service.py money(): invalid values are an upstream-contract failure. */
function requireMoney(value: unknown): Money {
  try {
    return money(value as Money);
  } catch (error) {
    if (error instanceof InvalidMoneyError) {
      throw new ImageError(502, "invalid_image_response");
    }
    throw error;
  }
}

/** service.py discounted(), with the same error mapping. */
function requireDiscounted(value: Money): Money {
  try {
    return discounted(value);
  } catch (error) {
    if (error instanceof InvalidMoneyError) {
      throw new ImageError(502, "invalid_image_response");
    }
    throw error;
  }
}

class PostgresImageLedger implements ImageLedger {
  private readonly clock: () => number;
  private readonly replayRetention: number;
  private readonly receiptRetention: number;

  constructor(
    private readonly db: Db,
    opts: ImageLedgerOptions = {},
  ) {
    const replayRetention = opts.replayRetention ?? REPLAY_RETENTION;
    const receiptRetention = opts.receiptRetention ?? RECEIPT_RETENTION;
    const durations = [replayRetention, receiptRetention];
    if (
      durations.some(
        (value) => typeof value !== "number" || !Number.isFinite(value),
      ) ||
      !(0 < replayRetention && replayRetention <= receiptRetention)
    ) {
      throw new Error("Invalid image retention policy");
    }
    this.clock = opts.clock ?? (() => Date.now() / 1000);
    this.replayRetention = replayRetention;
    this.receiptRetention = receiptRetention;
  }

  private now(): number {
    return Math.trunc(this.clock());
  }

  private lockKey(account: string): string {
    return `img:${account}`;
  }

  private receiptOf(row: ImagesJobRow): Receipt {
    const receipt: Receipt = {
      account_id: row.account,
      request_id: row.request,
      fingerprint: row.fingerprint,
      state: (row.state === "done" ? "confirmed" : row.state) as Receipt["state"],
      charged: row.state === "done" || row.state === "failed" ? row.charged : null,
    };
    if (row.servedModel) receipt.model = row.servedModel;
    return receipt;
  }

  /** service.py _response(): stored blob + receipt, or 410 replay-expired. */
  private responseOf(row: ImagesJobRow): Record<string, unknown> {
    const now = this.now();
    if (row.response === null || row.replayUntil === null || now >= row.replayUntil) {
      const receipt =
        row.receiptUntil === null || now < row.receiptUntil ? this.receiptOf(row) : null;
      throw new ImageError(410, "image_replay_expired", { receipt });
    }
    return { ...row.response, receipt: this.receiptOf(row) };
  }

  /** Admission value: unresolved reservations count at their reserved amount. */
  private admissionValue(row: { state: string; reserved: string; charged: string }): Money {
    const unresolved = row.state === "pending" || row.state === "unknown";
    return requireMoney(unresolved ? row.reserved : row.charged);
  }

  private storedMoney(value: string): Money {
    return requireMoney(value);
  }

  async begin(
    account: string,
    request: string,
    fingerprint: string,
    reservation: Money,
    budget: Money,
    budgetWindow: string,
  ): Promise<Record<string, unknown> | null> {
    return withUidLock(this.db, this.lockKey(account), async (locked) =>
      withImagesTransaction(locked, async (tx) => {
        if (await imagesRepo.isDeleted(tx, account)) {
          throw new ImageError(410, "image_account_deleted");
        }
        const row = await imagesRepo.get(tx, account, request);
        if (row !== null) {
          if (row.fingerprint !== fingerprint) {
            throw new ImageError(409, "idempotency_conflict");
          }
          if (row.state === "done") return this.responseOf(row);
          if (row.receiptUntil !== null && this.now() >= row.receiptUntil) {
            throw new ImageError(410, "image_receipt_expired");
          }
          throw new ImageError(
            409,
            row.state === "pending" || row.state === "unknown"
              ? "image_request_pending"
              : "image_request_failed",
            { receipt: this.receiptOf(row) },
          );
        }

        const rows = await imagesRepo.listForAdmission(tx, account, budgetWindow);
        const spent = exactSum(rows.map((r) => this.admissionValue(r)));
        const reserved = requireMoney(reservation);
        const limit = requireMoney(budget);
        if (exactSum([spent, reserved]).greaterThan(limit)) {
          throw new ImageError(402, "image_limit_reached");
        }
        await imagesRepo.insertPending(tx, {
          account,
          request,
          fingerprint,
          reserved: reserved.toString(),
          budgetWindow,
          createdAt: this.now(),
        });
        return null;
      }),
    );
  }

  async settle(
    account: string,
    request: string,
    actual: Money,
    response: Record<string, unknown>,
    servedModel: string | null = null,
  ): Promise<Record<string, unknown>> {
    let deleted = false;
    let result: Record<string, unknown> | null = null;

    await withUidLock(this.db, this.lockKey(account), async (locked) => {
      deleted = await withImagesTransaction(locked, async (tx) => {
        const isDeleted = await imagesRepo.isDeleted(tx, account);
        const row = await imagesRepo.get(tx, account, request);
        if (row === null) throw new ImageError(404, "image_request_not_found");

        if (row.state === "done") {
          // Python checks the tombstone before returning a stored result.
          if (isDeleted) throw new ImageError(410, "image_account_deleted");
          result = this.responseOf(row);
          return false;
        }
        if (row.state !== "pending" && row.state !== "unknown") {
          throw new ImageError(409, "image_request_failed", {
            receipt: this.receiptOf(row),
          });
        }

        const actualMoney = requireMoney(actual);
        const charged = requireDiscounted(actualMoney);
        const now = this.now();
        const updated = await imagesRepo.settleRow(tx, account, request, {
          state: "done",
          servedModel: servedModel ?? null,
          actual: isDeleted ? null : actualMoney.toString(),
          charged: charged.toString(),
          response: isDeleted ? null : response,
          replayUntil: isDeleted ? 0 : now + this.replayRetention,
          receiptUntil: isDeleted ? 0 : now + this.receiptRetention,
        });
        if (!isDeleted) result = this.responseOf(updated);
        return isDeleted;
      });
    });

    if (deleted) {
      // The charge for work accepted before deletion commits, then the
      // response is withheld (Review Focus #5).
      throw new ImageError(410, "image_account_deleted");
    }
    return result!;
  }

  async unknown(account: string, request: string): Promise<void> {
    await withUidLock(this.db, this.lockKey(account), async (locked) => {
      await imagesRepo.markUnknown(locked, account, request);
    });
  }

  async fail(account: string, request: string): Promise<void> {
    await withUidLock(this.db, this.lockKey(account), async (locked) => {
      await imagesRepo.markFailed(locked, account, request, this.now() + this.receiptRetention);
    });
  }

  async receipt(account: string, request: string): Promise<Receipt> {
    // Read-only, like Python: no write lock. A concurrent delete either
    // linearizes before this read (receipt served) or after (410).
    if (await imagesRepo.isDeleted(this.db, account)) {
      throw new ImageError(410, "image_account_deleted");
    }
    const row = await imagesRepo.get(this.db, account, request);
    if (row === null) throw new ImageError(404, "image_request_not_found");
    if (row.receiptUntil !== null && this.now() >= row.receiptUntil) {
      throw new ImageError(410, "image_receipt_expired");
    }
    return this.receiptOf(row);
  }

  async replay(account: string, request: string): Promise<Record<string, unknown>> {
    if (await imagesRepo.isDeleted(this.db, account)) {
      throw new ImageError(410, "image_account_deleted");
    }
    const row = await imagesRepo.get(this.db, account, request);
    if (row === null) throw new ImageError(404, "image_request_not_found");
    // Python checks receipt expiry BEFORE the job state.
    if (row.receiptUntil !== null && this.now() >= row.receiptUntil) {
      throw new ImageError(410, "image_receipt_expired");
    }
    if (row.state !== "done") {
      throw new ImageError(
        409,
        row.state === "pending" || row.state === "unknown"
          ? "image_request_pending"
          : "image_request_failed",
        { receipt: this.receiptOf(row) },
      );
    }
    return this.responseOf(row);
  }

  async spent(
    account: string,
    opts: { includePending?: boolean; budgetWindow?: string | null } = {},
  ): Promise<Money> {
    const rows = await imagesRepo.listForSpent(
      this.db,
      account,
      opts.budgetWindow ?? null,
    );
    const includePending = opts.includePending === true;
    const values = rows.map((row) => {
      const unresolved = row.state === "pending" || row.state === "unknown";
      return this.storedMoney(includePending && unresolved ? row.reserved : row.charged);
    });
    return exactSum(values);
  }

  async purgeExpired(limit = 500): Promise<number> {
    if (!Number.isInteger(limit) || limit < 1 || limit > 10_000) {
      throw new Error("Retention batch size must be between 1 and 10000");
    }
    return imagesRepo.purgeExpired(this.db, this.now(), limit);
  }

  async deleteAccount(account: string): Promise<void> {
    await withUidLock(this.db, this.lockKey(account), async (locked) => {
      await withImagesTransaction(locked, async (tx) => {
        await imagesRepo.insertDeleted(tx, account, this.now());
        await imagesRepo.clearAccount(tx, account);
      });
    });
  }
}

export function createImageLedger(db: Db, opts: ImageLedgerOptions = {}): ImageLedger {
  return new PostgresImageLedger(db, opts);
}
