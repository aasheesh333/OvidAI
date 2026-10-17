import { describe, expect, it } from "vitest";
import {
  McpReconnector,
  RECONNECT_INITIAL_MS,
  RECONNECT_MAX_ATTEMPTS,
  RECONNECT_MAX_MS,
  type ReconnectorOptions,
} from "./backoff.js";

// ---------------------------------------------------------------------------
// Reconnect backoff: pure timer logic with an injectable schedule so the
// tests pin the exact delay sequence without real timers.
// ---------------------------------------------------------------------------

interface Timer {
  ms: number;
  fn: () => void;
  cancelled: boolean;
  fired: boolean;
}

function fakeClock() {
  const timers: Timer[] = [];
  const schedule: NonNullable<ReconnectorOptions["schedule"]> = (ms, fn) => {
    const t: Timer = { ms, fn, cancelled: false, fired: false };
    timers.push(t);
    return () => {
      t.cancelled = true;
    };
  };
  /** Fire the most recently scheduled (unfired) timer and let the connect
   *  promise settle. */
  const fireLast = async (): Promise<void> => {
    const t = timers[timers.length - 1]!;
    if (t.fired) throw new Error("fakeClock: no pending timer to fire");
    t.fired = true;
    t.fn();
    await new Promise<void>((r) => setImmediate(r));
  };
  return { timers, schedule, fireLast };
}

describe("McpReconnector", () => {
  it("exposes the pinned backoff constants", () => {
    expect(RECONNECT_INITIAL_MS).toBe(500);
    expect(RECONNECT_MAX_MS).toBe(30_000);
    expect(RECONNECT_MAX_ATTEMPTS).toBe(10);
  });

  it("delays double 500→1000→…→30000 cap (exact sequence, attempts 1..8)", async () => {
    const { timers, schedule, fireLast } = fakeClock();
    let calls = 0;
    const r = new McpReconnector({
      connect: async () => {
        calls++;
        return false;
      },
      schedule,
    });

    const seen: number[] = [];
    r.scheduleUnexpected();
    seen.push(timers[timers.length - 1]!.ms);
    for (let i = 1; i < 8; i++) {
      await fireLast(); // connect() === false → reschedules
      seen.push(timers[timers.length - 1]!.ms);
    }
    expect(seen).toEqual([500, 1000, 2000, 4000, 8000, 16000, 30000, 30000]);
    expect(r.attempts).toBe(8);
    expect(calls).toBe(7);
  });

  it("gives up after 10 attempts — the 11th scheduleUnexpected schedules nothing", async () => {
    const { timers, schedule, fireLast } = fakeClock();
    const r = new McpReconnector({ connect: async () => false, schedule });

    r.scheduleUnexpected();
    for (let i = 0; i < 9; i++) await fireLast();
    expect(timers).toHaveLength(10); // attempts 1..10 scheduled
    await fireLast(); // 10th connect fails; the internal reschedule gives up
    expect(timers).toHaveLength(10);
    r.scheduleUnexpected(); // 11th — silently dropped
    expect(timers).toHaveLength(10);
    expect(r.attempts).toBe(10);
  });

  it("markConnected resets the attempt counter", async () => {
    const { timers, schedule, fireLast } = fakeClock();
    const r = new McpReconnector({ connect: async () => false, schedule });

    r.scheduleUnexpected();
    await fireLast(); // attempt 2 pending at 1000ms
    expect(timers[timers.length - 1]!.ms).toBe(1000);
    r.markConnected();
    expect(r.attempts).toBe(0);
    await fireLast(); // connect false → next delay back to the initial 500ms
    expect(timers[timers.length - 1]!.ms).toBe(500);
    expect(r.attempts).toBe(1);
  });

  it("cancel clears the pending timer and the attempt counter", async () => {
    const { timers, schedule } = fakeClock();
    const r = new McpReconnector({ connect: async () => false, schedule });

    r.scheduleUnexpected();
    r.scheduleUnexpected(); // second call while a timer is pending
    expect(timers).toHaveLength(2);
    expect(timers[0]!.cancelled).toBe(true); // the first timer was replaced
    r.cancel();
    expect(timers[1]!.cancelled).toBe(true);
    expect(r.attempts).toBe(0);
    r.scheduleUnexpected();
    expect(timers[2]!.ms).toBe(500); // counter was cleared — starts over
  });

  it("successful connect() === true stops rescheduling", async () => {
    const { timers, schedule, fireLast } = fakeClock();
    const r = new McpReconnector({ connect: async () => true, schedule });

    r.scheduleUnexpected();
    await fireLast();
    expect(timers).toHaveLength(1); // no follow-up timer
    expect(r.attempts).toBe(0);
  });

  it("a rejected connect() is treated as failure and reschedules", async () => {
    const { timers, schedule, fireLast } = fakeClock();
    const r = new McpReconnector({
      connect: async () => {
        throw new Error("socket refused");
      },
      schedule,
    });

    r.scheduleUnexpected();
    await fireLast();
    expect(timers).toHaveLength(2);
    expect(timers[1]!.ms).toBe(1000);
    expect(r.attempts).toBe(2);
  });
});
