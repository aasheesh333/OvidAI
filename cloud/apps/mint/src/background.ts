import { Decimal } from "decimal.js";
import { pyNumStr } from "@ovid/money";
import type { MintDeps } from "./app.js";
import { refreshModelGroups } from "./catalog.js";
import { sweepSlowMode } from "./slowMode.js";

/**
 * mint.py's background daemon threads, as two unref'd Node timers:
 *  - _sweeper: every MINT_SWEEP_S (default 30 s) drain the slow-mode
 *    handshake and refresh `config:model_groups`;
 *  - _spend_monitor: every 300 s compare LiteLLM's cumulative /global/spend
 *    with today's base and alert once per day bucket at DAILY_SPEND_ALERT_USD.
 *
 * Both bodies run ONCE IMMEDIATELY, then sleep (Python's `while True: try …
 * sleep`), and neither ever throws: a sweep/monitor failure must not kill the
 * loop. `stop()` clears the timers and awaits any in-flight tick.
 */

const SPEND_MONITOR_MS = 300_000;
const DAYBASE_TTL_S = 3 * 86_400;

function clockNow(deps: MintDeps): Date {
  const clock = deps.clock ?? (() => new Date());
  return new Date(clock().getTime());
}

/** Python `time.strftime("%Y%m%d", time.gmtime())`. */
function utcDay(d: Date): string {
  const month = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${d.getUTCFullYear()}${month}${day}`;
}

function money2(value: Decimal): string {
  return value.toDecimalPlaces(2, Decimal.ROUND_HALF_EVEN).toFixed(2);
}

/**
 * One spend-monitor pass. `globalSpend` THROWS on non-2xx (T5-review M3) —
 * the try/catch here is Python's `except Exception: print` so an outage only
 * skips this tick instead of silencing the alert or killing the loop.
 */
export async function spendMonitorOnce(deps: MintDeps): Promise<void> {
  try {
    const total = await deps.litellm.globalSpend();
    const key = `spend:daybase:${utcDay(clockNow(deps))}`;
    // Python str(float) parity for the stored base ("100.0", not "100").
    await deps.redis.set(key, pyNumStr(total), "EX", DAYBASE_TTL_S, "NX");
    const raw = await deps.redis.get(key);
    // Python `float(rds.get(key) or total)` — the base is the FIRST total seen
    // today, so `today` is spend since this process first observed the day.
    const base = raw === null ? total : Number(raw);
    const today = new Decimal(String(total)).minus(new Decimal(String(base)));
    const threshold = new Decimal(String(deps.env.dailySpendAlertUsd));
    if (today.gte(threshold)) {
      await deps.alerter(
        "daily_spend",
        `Spend today $${money2(today)} >= $${money2(threshold)}`,
        86_400,
      );
    }
  } catch (err) {
    console.log(`[mint] spend monitor: ${errorName(err)}`);
  }
}

/** One sweeper pass: slow-mode sweep + the catalog refresh (never throws). */
export async function sweeperOnce(deps: MintDeps): Promise<void> {
  try {
    await sweepSlowMode(deps);
    await refreshModelGroups(deps);
  } catch (err) {
    console.log(`[mint] sweeper: ${errorName(err)}`);
  }
}

interface LoopHandle {
  stop(): Promise<void>;
}

function createLoop(fn: () => Promise<void>, everyMs: number): LoopHandle {
  let stopped = false;
  let timer: NodeJS.Timeout | undefined;
  let inFlight: Promise<void> | null = null;

  const tick = (): void => {
    if (stopped) return;
    // fn() is a never-throwing wrapper; the catch is belt-and-braces so a
    // future edit cannot turn a tick into an unhandled rejection.
    inFlight = fn()
      .catch((err: unknown) => {
        console.log(`[mint] background loop: ${errorName(err)}`);
      })
      .finally(() => {
        inFlight = null;
        if (!stopped) {
          timer = setTimeout(tick, everyMs);
          timer.unref?.();
        }
      });
  };

  tick(); // Python runs the body before its first sleep.

  return {
    async stop() {
      stopped = true;
      if (timer !== undefined) {
        clearTimeout(timer);
        timer = undefined;
      }
      if (inFlight !== null) {
        await inFlight;
      }
    },
  };
}

/** Start the sweeper + spend-monitor loops; call `stop()` on shutdown. */
export function startMintBackgroundLoops(deps: MintDeps): { stop(): Promise<void> } {
  const loops = [
    createLoop(() => sweeperOnce(deps), deps.env.sweepS * 1000),
    createLoop(() => spendMonitorOnce(deps), SPEND_MONITOR_MS),
  ];
  return {
    async stop(): Promise<void> {
      await Promise.all(loops.map((loop) => loop.stop()));
    },
  };
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : String(err);
}
