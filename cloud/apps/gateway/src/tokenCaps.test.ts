import { describe, expect, it } from "vitest";
import { PLANS } from "@ovid/shared";
import {
  evaluateTokenCaps,
  nextUtcDayStart,
  nextUtcMonthStart,
  utcDayStart,
  utcMonthStart,
} from "./tokenCaps.js";

/**
 * The token cap is the product's 50M/day + 1.5B/month promise, enforced from
 * the `run_usage` ledger the worker already writes. These are the pure rules;
 * the send route's tests cover the wiring.
 *
 * The windows are calendar windows in UTC. That makes the reset instant
 * exact (the client renders a countdown from it) and matches the
 * account-health screen's `today`/`month` buckets.
 */

const NOW = new Date("2026-10-23T15:04:05.000Z");

function sums(inputTokens: number, outputTokens = 0, cache = 0) {
  return {
    inputTokens,
    outputTokens,
    cacheReadTokens: cache,
    cacheWriteTokens: cache,
  };
}

describe("UTC window boundaries", () => {
  it("starts the day at midnight UTC and resets at the next one", () => {
    expect(utcDayStart(NOW).toISOString()).toBe("2026-10-23T00:00:00.000Z");
    expect(nextUtcDayStart(NOW).toISOString()).toBe("2026-10-24T00:00:00.000Z");
  });

  it("starts the month on the 1st and resets on the next 1st", () => {
    expect(utcMonthStart(NOW).toISOString()).toBe("2026-10-01T00:00:00.000Z");
    expect(nextUtcMonthStart(NOW).toISOString()).toBe("2026-11-01T00:00:00.000Z");
  });

  it("rolls the month across a year boundary", () => {
    const dec = new Date("2026-12-31T23:59:59.000Z");
    expect(nextUtcMonthStart(dec).toISOString()).toBe("2027-01-01T00:00:00.000Z");
    expect(nextUtcDayStart(dec).toISOString()).toBe("2027-01-01T00:00:00.000Z");
  });
});

describe("evaluateTokenCaps", () => {
  it("allows a send with headroom", () => {
    expect(
      evaluateTokenCaps({
        tier: "free",
        now: NOW,
        today: sums(1_000, 500),
        month: sums(10_000_000, 2_000_000),
      }),
    ).toBeNull();
  });

  it("refuses at the Free daily ceiling and names the next UTC midnight", () => {
    const verdict = evaluateTokenCaps({
      tier: "free",
      now: NOW,
      today: sums(49_000_000, 1_000_000),
      month: sums(49_000_000, 1_000_000),
    });
    expect(verdict).toEqual({
      window: "day",
      cap: 50_000_000,
      used: 50_000_000,
      resetsAt: new Date("2026-10-24T00:00:00.000Z"),
    });
  });

  it("refuses at the Free monthly ceiling when today is quiet", () => {
    const verdict = evaluateTokenCaps({
      tier: "free",
      now: NOW,
      today: sums(10),
      month: sums(1_400_000_000, 100_000_000),
    });
    expect(verdict).toEqual({
      window: "month",
      cap: 1_500_000_000,
      used: 1_500_000_000,
      resetsAt: new Date("2026-11-01T00:00:00.000Z"),
    });
  });

  it("reports the daily stop first when both are spent", () => {
    // The sooner reset is the actionable one; the screen's countdown must not
    // send the person to the next month when tomorrow would do.
    const verdict = evaluateTokenCaps({
      tier: "free",
      now: NOW,
      today: sums(60_000_000),
      month: sums(1_600_000_000),
    });
    expect(verdict?.window).toBe("day");
  });

  it("uses the paid multiplier: Pro may move 20× Free", () => {
    expect(PLANS.pro.tokens.perDay).toBe(1_000_000_000);
    expect(
      evaluateTokenCaps({
        tier: "pro",
        now: NOW,
        today: sums(900_000_000),
        month: sums(900_000_000),
      }),
    ).toBeNull();
    expect(
      evaluateTokenCaps({
        tier: "pro",
        now: NOW,
        today: sums(1_000_000_000),
        month: sums(1_000_000_000),
      })?.window,
    ).toBe("day");
  });

  it("gives a legacy stored tier the plan it means", () => {
    expect(
      evaluateTokenCaps({
        tier: "7x",
        now: NOW,
        today: sums(100_000_000),
        month: sums(100_000_000),
      }),
    ).toBeNull(); // Plus = 250M/day, not Free's 50M
    expect(
      evaluateTokenCaps({
        tier: "7x",
        now: NOW,
        today: sums(250_000_000),
        month: sums(250_000_000),
      })?.window,
    ).toBe("day");
  });

  it("counts input + output only; cache is never double-counted", () => {
    // 49.5M input + 0.5M output = 50M, with a huge cache counter that must
    // not tip it over (or be added on top).
    expect(
      evaluateTokenCaps({
        tier: "free",
        now: NOW,
        today: sums(49_500_000, 500_000, 40_000_000),
        month: sums(49_500_000, 500_000, 40_000_000),
      })?.window,
    ).toBe("day");
  });

  it("treats a non-positive cap as not configured, never as deny-all", () => {
    // Defensive: a malformed plan row must not lock every send out of the
    // product. (No shipped tier has a zero cap.)
    expect(
      evaluateTokenCaps({
        tier: "free",
        now: NOW,
        today: sums(0),
        month: sums(0),
        caps: { perDay: 0, perMonth: 0 },
      }),
    ).toBeNull();
  });
});
