import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { AlertSink } from "./alertSink.js";
import type { CheckResult, WatchDeps } from "./checks.js";
import { main } from "./main.js";

/**
 * The one-shot main loop, driven with injected deps and a fake sink:
 *   - state-file persistence + edge-triggering across invocations,
 *   - `--self-test` exit codes (0 only on a proven delivery),
 *   - a delivery failure keeps the alert pending for the next run
 *     (Review Focus #5: a dead token must not swallow alerts).
 */

const T0 = Date.parse("2026-10-17T12:00:00.000Z");

function deps(
  queueWaiting: () => Promise<number>,
  overrides: Partial<WatchDeps> = {},
): WatchDeps {
  return {
    fetchJson: async () => ({ status: "ok" }),
    redisInfo: async () => ({ used_memory: "1", maxmemory: "1000" }),
    queueWaiting,
    queueOldestWaitingAgeS: async () => 0,
    sql: async () => [],
    dfPct: async () => 10,
    now: () => new Date(T0),
    mintSpendCents: async () => [],
    ...overrides,
  };
}

function recordingSink(logs: string[]): AlertSink & { sent: string[] } {
  const sent: string[] = [];
  return {
    sent,
    webhookUrl: "http://127.0.0.1:1/hook",
    log: (line) => logs.push(line),
  };
}

/** Successful delivery for every call; records nothing. */
const okFetch = (async () => new Response("{}", { status: 200 })) as typeof fetch;

describe("main (one-shot)", () => {
  let dir: string;
  let stateFile: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "ovid-watch-"));
    stateFile = join(dir, "state.json");
  });

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  function env(): NodeJS.ProcessEnv {
    return {
      WATCH_STATE_FILE: stateFile,
      REDIS_Q_URL: "redis://127.0.0.1:1",
      WATCH_SPEND_PARITY: "off",
      OVID_ALERT_WEBHOOK_URL: "http://127.0.0.1:1/hook",
      GATEWAY_HEALTH_URL: "http://127.0.0.1:1/health",
    };
  }

  it("alerts once on the first failing run and stays quiet on repeats", async () => {
    const logs: string[] = [];
    const sink = recordingSink(logs);
    let now = T0;

    const run = (waiting: number): Promise<number> =>
      main([], env(), {
        deps: deps(async () => waiting),
        sink,
        fetchImpl: okFetch,
        log: (line) => logs.push(line),
        now: () => new Date(now),
      });

    expect(await run(51), logs.join("\n")).toBe(0);
    expect(logs.filter((l) => l.startsWith("ALERT")).length).toBe(1);

    now += 60_000;
    expect(await run(51), logs.join("\n")).toBe(0);
    expect(logs.filter((l) => l.startsWith("ALERT")).length).toBe(1);

    const state = JSON.parse(await readFile(stateFile, "utf8")) as {
      states: Record<string, boolean>;
      lastAlertAt: Record<string, number>;
    };
    expect(state.states["queue-depth"]).toBe(false);
    expect(state.lastAlertAt["queue-depth"]).toBe(T0);
  });

  it("re-alerts after the repeat window and emits one recovery", async () => {
    const logs: string[] = [];
    const sink = recordingSink(logs);
    let now = T0;
    let waiting = 51;

    const run = (): Promise<number> =>
      main([], env(), {
        deps: deps(async () => waiting),
        sink,
        fetchImpl: okFetch,
        log: (line) => logs.push(line),
        now: () => new Date(now),
      });

    await run();
    now += 30 * 60_000;
    await run();
    expect(logs.filter((l) => l.startsWith("ALERT")).length).toBe(2);

    waiting = 0;
    now += 60_000;
    await run();
    expect(logs.filter((l) => l.startsWith("RECOVERED")).length).toBe(1);

    now += 60_000;
    await run();
    expect(logs.filter((l) => l.startsWith("RECOVERED")).length).toBe(1);
  });

  it("a failed delivery exits nonzero and leaves the alert pending for the next run", async () => {
    const logs: string[] = [];
    let attempts = 0;
    const failingSink: AlertSink = {
      webhookUrl: "http://127.0.0.1:1/hook",
      log: (line) => logs.push(line),
    };
    // Inject a webhook whose fetch always fails: sendAlert throws.
    const failingFetch = (async () => {
      attempts += 1;
      throw new Error("telegram down");
    }) as typeof fetch;

    const code = await main([], env(), {
      deps: deps(async () => 51),
      sink: failingSink,
      fetchImpl: failingFetch,
      log: (line) => logs.push(line),
      now: () => new Date(T0),
    });

    expect(code).toBe(1);
    expect(attempts).toBe(1);
    // The state file still records the failing check, but NOT a lastAlertAt,
    // so the next run re-attempts the edge instead of swallowing it.
    const state = JSON.parse(await readFile(stateFile, "utf8")) as {
      states: Record<string, boolean>;
      lastAlertAt: Record<string, number>;
    };
    expect(state.states["queue-depth"]).toBe(false);
    expect(state.lastAlertAt["queue-depth"]).toBeUndefined();

    const retry = await main([], env(), {
      deps: deps(async () => 51),
      sink: failingSink,
      fetchImpl: failingFetch,
      log: (line) => logs.push(line),
      now: () => new Date(T0 + 60_000),
    });
    expect(retry).toBe(1);
    expect(attempts).toBe(2);
  });

  it("--self-test exits 0 only when the fake sender receives the TEST alert", async () => {
    const logs: string[] = [];
    const sink = recordingSink(logs);
    const calls: Array<{ url: string; body: string }> = [];
    const fetchImpl = (async (url: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(url), body: String(init?.body ?? "") });
      return new Response("{}", { status: 200 });
    }) as typeof fetch;

    const code = await main(["--self-test"], env(), {
      sink,
      fetchImpl,
      log: (line) => logs.push(line),
      now: () => new Date("2026-10-17T12:00:00.000Z"),
    });

    expect(code).toBe(0);
    expect(calls).toHaveLength(1);
    expect(JSON.parse(calls[0].body)).toMatchObject({
      text: expect.stringMatching(/^TEST alert from ovid-cloud-watch on .+ at /),
    });
    expect(logs.some((l) => /self-test OK/i.test(l))).toBe(true);
  });

  it("--self-test exits nonzero when delivery fails", async () => {
    const logs: string[] = [];
    const code = await main(["--self-test"], env(), {
      sink: recordingSink(logs),
      fetchImpl: (async () => new Response("no", { status: 502 })) as typeof fetch,
      log: (line) => logs.push(line),
    });
    expect(code).toBe(1);
    expect(logs.some((l) => /self-test FAILED/i.test(l))).toBe(true);
  });
});
