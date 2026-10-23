import { countedTokens, tokenCapsFor } from "@ovid/shared";

/**
 * The product's token ceilings, as the gateway enforces them.
 *
 * The spec sells Free as 50M tokens a day and a 1.5B hard ceiling a month,
 * with paid tiers at 1.5× / 5× / 20× of that (the same multiplier that
 * prices their allowance). The counts come from `run_usage`, the ledger the
 * worker already writes per model call — so this is enforcement over a real
 * fact, not a second estimate.
 *
 * The windows are calendar windows in UTC. Two reasons:
 *   - the reset instant is exact, and the client renders it as a countdown
 *     (`x-ovid-resets-at`); a rolling window's true reset depends on when
 *     each old token ages out and cannot be stated as one instant;
 *   - it is the same boundary the account-health screen reports in
 *     `usage.today` / `usage.month` (at its default UTC offset), so the
 *     remaining number the screen shows is the one the gateway enforces.
 *
 * Cache tokens are not part of the count (`countedTokens`): the ledger
 * reports them separately and a cached prompt is already in `inputTokens`.
 */

export type TokenCapWindow = "day" | "month";

export interface TokenCapVerdict {
  window: TokenCapWindow;
  /** The plan's ceiling for that window. */
  cap: number;
  /** Input + output tokens already recorded inside the window. */
  used: number;
  /** When the window rolls over — the instant the client counts down to. */
  resetsAt: Date;
}

export interface TokenSumsLike {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
}

/** Midnight UTC on the day `now` falls in. */
export function utcDayStart(now: Date): Date {
  return new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()),
  );
}

/** The first instant of the next UTC day. */
export function nextUtcDayStart(now: Date): Date {
  return new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1),
  );
}

/** The first instant of the UTC month `now` falls in. */
export function utcMonthStart(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
}

/** The first instant of the next UTC month. */
export function nextUtcMonthStart(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
}

/**
 * The first ceiling `tier` has already reached, or null when the send may
 * proceed.
 *
 * Daily is checked before monthly: when both are spent, the sooner reset is
 * the actionable one. A cap that is missing, non-finite or <= 0 is treated
 * as "not configured" rather than "deny everything" — a malformed plan row
 * must not lock an account out of the product.
 */
export function evaluateTokenCaps(args: {
  tier: string | null | undefined;
  now: Date;
  today: TokenSumsLike;
  month: TokenSumsLike;
  /** Tests/forward-compat: use these caps instead of the plan's. */
  caps?: { perDay: number; perMonth: number };
}): TokenCapVerdict | null {
  const caps = args.caps ?? tokenCapsFor(args.tier);

  if (Number.isFinite(caps.perDay) && caps.perDay > 0) {
    const used = countedTokens(args.today);
    if (used >= caps.perDay) {
      return {
        window: "day",
        cap: caps.perDay,
        used,
        resetsAt: nextUtcDayStart(args.now),
      };
    }
  }

  if (Number.isFinite(caps.perMonth) && caps.perMonth > 0) {
    const used = countedTokens(args.month);
    if (used >= caps.perMonth) {
      return {
        window: "month",
        cap: caps.perMonth,
        used,
        resetsAt: nextUtcMonthStart(args.now),
      };
    }
  }

  return null;
}
