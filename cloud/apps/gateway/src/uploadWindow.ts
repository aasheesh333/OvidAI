import { PlanGateError, planFor, type PlanTier } from "./planGate.js";

/**
 * The plan's FILE WINDOW — a product promise, not a burst limiter.
 *
 *   Free            50 files / 24 h
 *   Go · Plus · Pro 80 files / 3 h
 *
 * Only the per-project cap (`PROJECT_FILE_CAPS`) and the storage quota were
 * enforced before this; the window counter did not exist, so the numbers on
 * the Plans screen described nothing.
 *
 * The window is a rolling one measured from "now", counted from the
 * `attachments` rows the upload already creates — the database is the record
 * of what was uploaded, so no second ledger can drift from it.
 */
export interface UploadWindow {
  readonly limit: number;
  readonly hours: number;
}

export const UPLOAD_WINDOWS: Readonly<Record<PlanTier, UploadWindow>> = Object.freeze({
  free: Object.freeze({ limit: 50, hours: 24 }),
  go: Object.freeze({ limit: 80, hours: 3 }),
  plus: Object.freeze({ limit: 80, hours: 3 }),
  pro: Object.freeze({ limit: 80, hours: 3 }),
});

/** An upload would exceed the plan's file window. */
export class UploadWindowExceededError extends PlanGateError {
  constructor(
    readonly tier: PlanTier,
    readonly limit: number,
    readonly hours: number,
    readonly used: number,
    readonly retryAt: Date,
  ) {
    const window = hours === 1 ? "hour" : `${hours} hours`;
    super(
      "upload_limit_reached",
      429,
      `Your plan allows ${limit} files every ${window}. ` +
        `Delete files or upgrade to continue.`,
      { tier, limit, hours, used, retryAt: retryAt.toISOString() },
    );
    this.name = "UploadWindowExceededError";
  }
}

/**
 * Refuses the upload when the tier's rolling window is already full.
 *
 * `countSince` is injected so the decision is unit-testable and the caller
 * owns the query (the attachments table, scoped to this uid).
 */
export async function assertUploadWindow(opts: {
  tier: string | null | undefined;
  now: Date;
  countSince: (since: Date) => Promise<number>;
}): Promise<void> {
  const plan = planFor(opts.tier);
  const window = UPLOAD_WINDOWS[plan.tier];
  const since = new Date(opts.now.getTime() - window.hours * 60 * 60 * 1000);
  const used = await opts.countSince(since);
  if (used < window.limit) return;
  // The oldest upload in the window frees a slot when it ages out. The caller
  // does not know the exact timestamps, so the honest answer is "when the
  // window next has room", i.e. one window from now at worst. Callers that
  // know the oldest row pass it through `oldestAt`.
  throw new UploadWindowExceededError(
    plan.tier,
    window.limit,
    window.hours,
    used,
    new Date(opts.now.getTime() + window.hours * 60 * 60 * 1000),
  );
}
