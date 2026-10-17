import { describe, expect, it } from "vitest";
import {
  diffStates,
  DEFAULT_REPEAT_AFTER_MS,
  type DiffStateOptions,
} from "./alertState.js";
import type { CheckResult } from "./checks.js";

/**
 * Review Focus #5: level-triggered checks must not re-alert every minute.
 * These tests drive `diffStates` with an injected clock and thread the state
 * forward exactly like the one-shot main does.
 */

function failing(name: CheckResult["name"] = "queue-depth"): CheckResult {
  return { name, ok: false, value: 51, threshold: 50, detail: "waiting 51 > 50" };
}

function healthy(name: CheckResult["name"] = "queue-depth"): CheckResult {
  return { name, ok: true, value: 0, threshold: 50, detail: "waiting 0" };
}

function at(ms: number): Date {
  return new Date(ms);
}

const T0 = Date.parse("2026-10-17T12:00:00.000Z");

describe("diffStates (edge-triggered)", () => {
  it("fail, fail, fail → exactly one alert", () => {
    let prev: Record<string, boolean> = {};
    let lastAlertAt: Record<string, number> = {};
    const alerts: CheckResult[] = [];

    for (let i = 0; i < 3; i += 1) {
      const out = diffStates(prev, [failing()], {
        now: at(T0 + i * 60_000),
        repeatAfterMs: 30 * 60_000,
        lastAlertAt,
      });
      alerts.push(...out.alerts);
      prev = out.nextState;
      lastAlertAt = out.nextAlertAt;
    }

    expect(alerts).toHaveLength(1);
    expect(prev["queue-depth"]).toBe(false);
  });

  it("re-alerts only after repeatAfterMs has elapsed", () => {
    let prev: Record<string, boolean> = {};
    let lastAlertAt: Record<string, number> = {};
    const alerts: CheckResult[] = [];

    const run = (now: number): void => {
      const out = diffStates(prev, [failing()], {
        now: at(now),
        repeatAfterMs: 30 * 60_000,
        lastAlertAt,
      });
      alerts.push(...out.alerts);
      prev = out.nextState;
      lastAlertAt = out.nextAlertAt;
    };

    run(T0); // transition → alert 1
    run(T0 + 29 * 60_000); // still inside the quiet window
    expect(alerts).toHaveLength(1);

    run(T0 + 30 * 60_000); // elapsed → alert 2
    expect(alerts).toHaveLength(2);

    run(T0 + 31 * 60_000); // inside the next window
    expect(alerts).toHaveLength(2);

    run(T0 + 60 * 60_000); // elapsed again → alert 3
    expect(alerts).toHaveLength(3);
  });

  it("recovery emits one notice on fail→ok, and only once", () => {
    let prev: Record<string, boolean> = {};
    let lastAlertAt: Record<string, number> = {};

    const first = diffStates(prev, [failing()], {
      now: at(T0),
      repeatAfterMs: DEFAULT_REPEAT_AFTER_MS,
      lastAlertAt,
    });
    expect(first.alerts).toHaveLength(1);
    prev = first.nextState;
    lastAlertAt = first.nextAlertAt;

    const recovered = diffStates(prev, [healthy()], {
      now: at(T0 + 60_000),
      repeatAfterMs: DEFAULT_REPEAT_AFTER_MS,
      lastAlertAt,
    });
    expect(recovered.alerts).toHaveLength(0);
    expect(recovered.recovered).toHaveLength(1);
    expect(recovered.recovered[0].name).toBe("queue-depth");
    prev = recovered.nextState;
    lastAlertAt = recovered.nextAlertAt;

    const stillOk = diffStates(prev, [healthy()], {
      now: at(T0 + 120_000),
      repeatAfterMs: DEFAULT_REPEAT_AFTER_MS,
      lastAlertAt,
    });
    expect(stillOk.recovered).toHaveLength(0);
  });

  it("a failure after recovery alerts immediately (new edge)", () => {
    let prev: Record<string, boolean> = { "queue-depth": true };
    const out = diffStates(prev, [failing()], {
      now: at(T0),
      repeatAfterMs: DEFAULT_REPEAT_AFTER_MS,
      lastAlertAt: {},
    });
    expect(out.alerts).toHaveLength(1);
    prev = out.nextState;
    expect(prev["queue-depth"]).toBe(false);
  });

  it("a first-ever observation that is failing alerts (unknown → fail is an edge)", () => {
    const out = diffStates({}, [failing("disk-80")], {
      now: at(T0),
      repeatAfterMs: DEFAULT_REPEAT_AFTER_MS,
    });
    expect(out.alerts).toHaveLength(1);
  });

  it("a healthy first observation is silent", () => {
    const out = diffStates({}, [healthy("disk-80")], {
      now: at(T0),
      repeatAfterMs: DEFAULT_REPEAT_AFTER_MS,
    });
    expect(out.alerts).toHaveLength(0);
    expect(out.recovered).toHaveLength(0);
  });

  it("missing lastAlertAt (legacy state file) re-alerts a still-failing check", () => {
    // State from an older version has no timestamps: a failure must not be
    // silently swallowed — the next run alerts once and starts tracking.
    const out = diffStates(
      { "queue-depth": false },
      [failing()],
      { now: at(T0), repeatAfterMs: DEFAULT_REPEAT_AFTER_MS },
    );
    expect(out.alerts).toHaveLength(1);
    expect(out.nextAlertAt["queue-depth"]).toBe(T0);
  });

  it("tracks each check independently", () => {
    const out = diffStates(
      { "queue-depth": true, "disk-80": true },
      [failing("queue-depth"), failing("disk-80")],
      { now: at(T0), repeatAfterMs: DEFAULT_REPEAT_AFTER_MS },
    );
    expect(out.alerts.map((a) => a.name).sort()).toEqual(["disk-80", "queue-depth"]);
    expect(out.nextState).toEqual({ "queue-depth": false, "disk-80": false });
  });

  it("the options type accepts an injected clock and repeat window", () => {
    const opts: DiffStateOptions = {
      now: at(T0),
      repeatAfterMs: 1_000,
      lastAlertAt: {},
    };
    expect(diffStates({}, [healthy()], opts).nextState["queue-depth"]).toBe(true);
  });
});
