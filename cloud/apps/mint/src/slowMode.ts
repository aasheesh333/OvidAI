import type { MintDeps } from "./app.js";
import { DB2 } from "./planMath.js";
import { computeUsage } from "./usage.js";
import {
  floatOr,
  poolInSlowMode,
  poolPushRateLimits,
  poolRateLimits,
  poolSyncSlowMode,
} from "./windows.js";

/**
 * Slow-mode handshake (mint.py:574-732) — the TS half of the contract the
 * UNMODIFIED Python pools hook speaks through `pools:slow` and
 * `pools:slow_pending`.
 *
 * T5 owns the pool primitives (`windows.ts`): inSlowMode / rateLimits /
 * syncSlowMode are DELEGATED (re-exported), never re-implemented, so there is
 * exactly one writer for the hook's keys. This module adds only the sweeper,
 * which is Task 7's.
 */

export const inSlowMode = poolInSlowMode;
export const rateLimits = poolRateLimits;
export const syncSlowMode = poolSyncSlowMode;
/** The hook-flip path needs the push too (resetWindowUser / admin flows). */
export const pushRateLimits = poolPushRateLimits;

function clockNow(deps: MintDeps): Date {
  const clock = deps.clock ?? (() => new Date());
  return new Date(clock().getTime());
}

/**
 * mint.py sweep_slow_mode: drain the hook's `pools:slow_pending` set through
 * computeUsage (which syncs the pool state from the live window), then lift
 * every expired `pools:slow` entry and push normal rate limits to its keys.
 */
export async function sweepSlowMode(
  deps: MintDeps,
): Promise<{ checked: number; lifted: number }> {
  const out = { checked: 0, lifted: 0 };

  for (const uid of await deps.redis.smembers(DB2.SLOW_PENDING)) {
    await deps.redis.srem(DB2.SLOW_PENDING, uid);
    try {
      await computeUsage(deps, uid);
      out.checked += 1;
    } catch (err) {
      console.log(`[mint] slow sweep error: ${errorName(err)}`);
    }
  }

  const nowSeconds = clockNow(deps).getTime() / 1000;
  const entries = await deps.redis.hgetall(DB2.SLOW_HASH);
  for (const [uid, until] of Object.entries(entries)) {
    if (floatOr(until, 0) <= nowSeconds) {
      await deps.redis.hdel(DB2.SLOW_HASH, uid);
      await poolPushRateLimits(deps, uid);
      out.lifted += 1;
    }
  }
  return out;
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : String(err);
}
