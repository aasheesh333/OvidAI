import { describe, expect, it } from "vitest";
import {
  MISSED_TOLERANCE_MS,
  ONE_OFF_GRACE_MS,
  RECURRING_GRACE_CAP_MS,
  SCHEDULE_TRIGGER_KINDS,
  decideMissedRun,
  describeTrigger,
  graceMsFor,
  isRecurringTrigger,
  nextFireAfter,
  nextIntervalSlot,
  nextSlotAfterMissed,
  scheduleRetryBackoffMs,
  scheduleTriggerSchema,
} from "./triggers.js";
import type { ScheduleTrigger } from "./triggers.js";

const T = (iso: string) => new Date(iso);
const now = T("2026-10-13T12:00:00.000Z");

const at = (iso: string): ScheduleTrigger => ({ kind: "at", at: iso });
const every = (seconds: number): ScheduleTrigger => ({ kind: "every", seconds });
const dailyAt = (time: string, tz = "UTC"): ScheduleTrigger => ({ kind: "daily_at", time, tz });
const cron = (expr: string, tz = "UTC"): ScheduleTrigger => ({ kind: "cron", expr, tz });

const rejects = (input: unknown) =>
  expect(scheduleTriggerSchema.safeParse(input).success).toBe(false);

describe("scheduleTriggerSchema", () => {
  it("parses each valid variant", () => {
    expect(scheduleTriggerSchema.parse(at("2026-10-13T17:00:00Z"))).toEqual(
      at("2026-10-13T17:00:00Z"),
    );
    expect(scheduleTriggerSchema.parse(every(300))).toEqual(every(300));
    expect(scheduleTriggerSchema.parse(dailyAt("09:00", "Europe/Berlin"))).toEqual(
      dailyAt("09:00", "Europe/Berlin"),
    );
    expect(scheduleTriggerSchema.parse(cron("0 9 * * 1-5"))).toEqual(cron("0 9 * * 1-5"));
  });

  it("every: rejects below the 300 s floor and non-integers", () => {
    rejects(every(299));
    rejects(every(300.5));
  });

  it("daily_at: rejects 24:00 and a non-IANA timezone", () => {
    rejects(dailyAt("24:00"));
    rejects(dailyAt("09:00", "Mars/Olympus"));
  });

  it("cron: rejects 6-field expressions (5-field only)", () => {
    rejects(cron("* * * * * *"));
  });

  it("at: rejects unparseable instants", () => {
    rejects(at("not-a-date"));
  });

  it("rejects two kinds at once (strict variants)", () => {
    rejects({ kind: "every", seconds: 300, at: "2026-10-13T17:00:00Z" });
    rejects({ kind: "at", at: "2026-10-13T17:00:00Z", seconds: 300 });
    rejects({ kind: "daily_at", time: "09:00", tz: "UTC", expr: "0 9 * * *" });
  });

  it("rejects unknown kinds", () => {
    rejects({ kind: "weekly", at: "2026-10-13T17:00:00Z" });
  });
});

describe("nextFireAfter", () => {
  it("at: a future instant fires at itself; at or before `from` never fires", () => {
    expect(nextFireAfter(at("2026-10-13T17:00:00Z"), now)).toEqual(T("2026-10-13T17:00:00.000Z"));
    expect(nextFireAfter(at("2026-10-13T12:00:00Z"), now)).toBeNull();
    expect(nextFireAfter(at("2026-10-13T11:00:00Z"), now)).toBeNull();
  });

  it("every: one full interval after `from`", () => {
    expect(nextFireAfter(every(300), now)).toEqual(T("2026-10-13T12:05:00.000Z"));
  });

  it("daily_at: today when still ahead, otherwise tomorrow", () => {
    expect(nextFireAfter(dailyAt("13:30"), now)).toEqual(T("2026-10-13T13:30:00.000Z"));
    expect(nextFireAfter(dailyAt("08:00"), now)).toEqual(T("2026-10-14T08:00:00.000Z"));
  });

  it("daily_at: exactly now is not after — the next fire is tomorrow (Dart-pinned)", () => {
    expect(nextFireAfter(dailyAt("12:00"), now)).toEqual(T("2026-10-14T12:00:00.000Z"));
  });

  it("cron: next matching field time, strictly after `from`", () => {
    expect(nextFireAfter(cron("0 9 * * *"), now)).toEqual(T("2026-10-14T09:00:00.000Z"));
  });
});

describe("daily_at DST (Review Focus 3)", () => {
  it("spring-forward gap: the nonexistent 02:30 shifts to 03:30 EDT, exactly one fire that day", () => {
    const trigger = dailyAt("02:30", "America/New_York");
    const first = nextFireAfter(trigger, T("2026-03-07T12:00:00.000Z"));
    expect(first).toEqual(T("2026-03-08T07:30:00.000Z"));
    // Exactly one fire on 2026-03-08 between 06:00Z and 08:00Z: scanning from
    // just before the window yields one fire inside it, and the next fire
    // after that is already on the following day.
    const fromWindowStart = nextFireAfter(trigger, T("2026-03-08T05:59:00.000Z"));
    expect(fromWindowStart).toEqual(T("2026-03-08T07:30:00.000Z"));
    expect(fromWindowStart!.getTime()).toBeGreaterThan(T("2026-03-08T06:00:00.000Z").getTime());
    expect(fromWindowStart!.getTime()).toBeLessThan(T("2026-03-08T08:00:00.000Z").getTime());
    const second = nextFireAfter(trigger, first!);
    expect(second).toEqual(T("2026-03-09T06:30:00.000Z"));
    expect(second!.getTime()).toBeGreaterThan(T("2026-03-08T08:00:00.000Z").getTime());
  });

  it("fall-back fold: the earlier offset wins (01:30 EDT), one fire that day", () => {
    const trigger = dailyAt("01:30", "America/New_York");
    const first = nextFireAfter(trigger, T("2026-11-01T04:00:00.000Z"));
    expect(first).toEqual(T("2026-11-01T05:30:00.000Z"));
    // The 01:30 EST repetition does not fire again: the next slot is the
    // following day's 01:30 EST (06:30Z).
    expect(nextFireAfter(trigger, first!)).toEqual(T("2026-11-02T06:30:00.000Z"));
  });
});

describe("nextIntervalSlot", () => {
  it("skips every fully-missed period (Dart-pinned: anchored at the occurrence)", () => {
    expect(nextIntervalSlot(T("2026-10-13T09:00:00.000Z"), 3600, T("2026-10-13T12:10:00.000Z"))).toEqual(
      T("2026-10-13T13:00:00.000Z"),
    );
  });

  it("now at the anchor itself advances exactly one slot (strictly after)", () => {
    expect(nextIntervalSlot(T("2026-10-13T09:00:00.000Z"), 3600, T("2026-10-13T09:00:00.000Z"))).toEqual(
      T("2026-10-13T10:00:00.000Z"),
    );
  });
});

describe("graceMsFor", () => {
  it("every: half the interval, capped at 6 h", () => {
    expect(graceMsFor(every(3600))).toBe(1_800_000);
    expect(graceMsFor(every(86_400))).toBe(21_600_000);
  });

  it("daily_at and cron: the full 6 h cap", () => {
    expect(graceMsFor(dailyAt("08:00"))).toBe(21_600_000);
    expect(graceMsFor(cron("0 9 * * *"))).toBe(21_600_000);
  });

  it("at: one-off grace is 24 h", () => {
    expect(graceMsFor(at("2026-10-20T00:00:00Z"))).toBe(86_400_000);
  });
});

describe("decideMissedRun (Dart MissedRunPolicy port)", () => {
  it("within tolerance is on time (and still-in-the-future is on time)", () => {
    expect(decideMissedRun(at("2026-10-20T00:00:00Z"), T("2026-10-13T11:59:00.000Z"), now)).toBe("onTime");
    expect(decideMissedRun(at("2026-10-20T00:00:00Z"), T("2026-10-13T13:00:00.000Z"), now)).toBe("onTime");
  });

  it("one-off: late runs once within a day, else paused for review", () => {
    expect(decideMissedRun(at("2026-10-20T00:00:00Z"), T("2026-10-13T09:00:00.000Z"), now)).toBe("runNow");
    expect(decideMissedRun(at("2026-10-20T00:00:00Z"), T("2026-10-11T12:00:00.000Z"), now)).toBe(
      "pauseForReview",
    );
  });

  it("recurring: within grace runs now, beyond grace skips to the next slot", () => {
    expect(decideMissedRun(every(3600), T("2026-10-13T11:40:00.000Z"), now)).toBe("runNow");
    expect(decideMissedRun(every(3600), T("2026-10-13T09:00:00.000Z"), now)).toBe("skipToNext");
    expect(decideMissedRun(dailyAt("07:00"), T("2026-10-13T07:00:00.000Z"), now)).toBe("runNow");
    expect(decideMissedRun(dailyAt("05:00"), T("2026-10-13T05:00:00.000Z"), now)).toBe("skipToNext");
  });
});

describe("nextSlotAfterMissed", () => {
  it("every: the slot anchored at the missed occurrence, skipping missed periods", () => {
    expect(nextSlotAfterMissed(every(3600), T("2026-10-13T09:00:00.000Z"), T("2026-10-13T12:10:00.000Z"))).toEqual(
      T("2026-10-13T13:00:00.000Z"),
    );
  });

  it("daily_at: the next slot strictly after now (Dart nextDaily(now))", () => {
    expect(
      nextSlotAfterMissed(dailyAt("08:00"), T("2026-10-12T08:00:00.000Z"), now),
    ).toEqual(T("2026-10-14T08:00:00.000Z"));
  });

  it("at: one-offs have no next slot", () => {
    expect(nextSlotAfterMissed(at("2026-10-11T12:00:00.000Z"), T("2026-10-11T12:00:00.000Z"), now)).toBeNull();
  });
});

describe("scheduleRetryBackoffMs", () => {
  it("30 s · 2^(attempt−1) for attempts 1..3", () => {
    expect(scheduleRetryBackoffMs(1)).toBe(30_000);
    expect(scheduleRetryBackoffMs(2)).toBe(60_000);
    expect(scheduleRetryBackoffMs(3)).toBe(120_000);
  });

  it("rejects attempts below 1", () => {
    expect(() => scheduleRetryBackoffMs(0)).toThrow();
  });
});

describe("describeTrigger", () => {
  it("renders the pinned human echo templates", () => {
    expect(describeTrigger(at("2026-10-13T17:00:00Z"))).toBe("once at 2026-10-13T17:00:00.000Z");
    expect(describeTrigger(every(300))).toBe("every 300 seconds");
    expect(describeTrigger(dailyAt("09:00", "Europe/Berlin"))).toBe("daily at 09:00 (Europe/Berlin)");
    expect(describeTrigger(cron("0 9 * * 1-5", "America/New_York"))).toBe(
      "cron '0 9 * * 1-5' (America/New_York)",
    );
  });
});

describe("isRecurringTrigger and pinned constants", () => {
  it("everything but `at` is recurring", () => {
    expect(isRecurringTrigger(at("2026-10-13T17:00:00Z"))).toBe(false);
    expect(isRecurringTrigger(every(300))).toBe(true);
    expect(isRecurringTrigger(dailyAt("09:00"))).toBe(true);
    expect(isRecurringTrigger(cron("0 9 * * *"))).toBe(true);
  });

  it("exports the Dart missed-run constants exactly", () => {
    expect(MISSED_TOLERANCE_MS).toBe(120_000);
    expect(ONE_OFF_GRACE_MS).toBe(86_400_000);
    expect(RECURRING_GRACE_CAP_MS).toBe(21_600_000);
    expect(SCHEDULE_TRIGGER_KINDS).toEqual(["at", "every", "daily_at", "cron"]);
  });
});
