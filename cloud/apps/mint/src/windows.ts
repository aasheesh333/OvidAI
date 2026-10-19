import type { MintDeps } from "./app.js";
import {
  DB2,
  findPlan,
  keyBudget,
  poolKeys,
  userPools,
  windowStr,
  type PlanData,
  type Pools,
  type Settings,
} from "./planMath.js";
import { getOverride, getSettings, userFreeDaily } from "./settings.js";

/**
 * Window + budget machinery — port of mint.py's window_bounds /
 * current_window_start / hook_spend / reset_window_user / reapply_user and
 * the tier/budget readers (effective_tier, free_cap_usd, month_spent,
 * tier_budget, user_budget_target).
 *
 * The Redis pool keys (`pool:{uid}:start|spend|auto`) are the LIVE window the
 * UNMODIFIED Python hook reads and writes, so every write here keeps
 * Python's exact shapes: the start is floor(epoch seconds), spend is a
 * float-string, and the TTL equals the plan window. `pools:slow` /
 * `pools:slow_pending` are the hook's slow-mode handshake keys.
 *
 * THE LITELLM CLOCK RULE (mint.py ensure_user_budget/apply_key_budget):
 * sending `budget_duration` restarts LiteLLM's budget clock
 * (budget_reset_at = now + duration), so it is sent ONLY when the stored
 * duration differs, or when a window reset explicitly forces the restart.
 */

export interface ReapplyResult {
  keys: number;
  errors: number;
}

function clockNow(deps: MintDeps): Date {
  const clock = deps.clock ?? (() => new Date());
  return new Date(clock().getTime());
}

/** Python `_float_or`: float(v) unless None/""/unparseable → default. */
export function floatOr(v: unknown, dflt: number): number {
  if (v === null || v === undefined || v === "") return dflt;
  if (typeof v === "number") return v;
  if (typeof v !== "string") return dflt;
  const s = v.trim().replace(/_/g, "");
  if (s === "") return dflt;
  const lower = s.toLowerCase();
  if (lower === "nan" || lower === "+nan" || lower === "-nan") return NaN;
  if (lower === "inf" || lower === "+inf" || lower === "infinity" || lower === "+infinity") {
    return Infinity;
  }
  if (lower === "-inf" || lower === "-infinity") return -Infinity;
  if (!/^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$/.test(s)) return dflt;
  const n = Number(s);
  return Number.isNaN(n) ? dflt : n;
}

/** Python `_int_or`: int(float(v)) truncation, default on unparseable. */
export function intOr(v: unknown, dflt: number): number {
  const n = floatOr(v, NaN);
  if (!Number.isFinite(n)) return dflt;
  return Math.trunc(n);
}

/** Python `_epoch_dt`: falsy → null, else fromtimestamp(..., UTC). */
export function epochDt(v: unknown): Date | null {
  if (v === null || v === undefined || v === "") return null;
  const n = floatOr(v, NaN);
  if (!Number.isFinite(n)) return null;
  return new Date(n * 1000);
}

/** Python `_iso`: whole-second UTC ISO with "+00:00" → "Z". */
export function isoUtc(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Python `_now().strftime('%Y-%m')` for the legacy freecap key. */
function monthKey(uid: string, now: Date): string {
  const month = String(now.getUTCMonth() + 1).padStart(2, "0");
  return `freecap:${uid}:${now.getUTCFullYear()}-${month}`;
}

/** mint.py `plan_for`: the stored tier (id or legacy alias) resolved to a plan. */
export async function planFor(
  deps: MintDeps,
  uid: string,
  s?: Settings,
): Promise<PlanData> {
  const settings = s ?? (await getSettings({ db: deps.db }));
  const tier = await deps.redis.get(`user:${uid}:tier`);
  return findPlan(settings, tier);
}

/** The user's keys: {namespace: keyid} for android ("") and web ("web:"). */
export async function poolUserKeyIds(
  deps: MintDeps,
  uid: string,
): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  for (const ns of ["", "web:"] as const) {
    const key = await deps.redis.get(`user:${uid}:${ns}keyid`);
    if (key) out[ns] = key;
  }
  return out;
}

/** mint.py in_slow_mode: HGET pools:slow uid > now. */
export async function poolInSlowMode(deps: MintDeps, uid: string): Promise<boolean> {
  const until = floatOr(await deps.redis.hget(DB2.SLOW_HASH, uid), 0);
  return until > clockNow(deps).getTime() / 1000;
}

/** mint.py rate_limits: slow vs normal rpm/tpm/parallel from the settings. */
export async function poolRateLimits(
  deps: MintDeps,
  uid: string,
  s?: Settings,
): Promise<{ rpm_limit: number; tpm_limit: number; max_parallel_requests: number }> {
  const settings = s ?? (await getSettings({ db: deps.db }));
  const mode: "slow" | "normal" = (await poolInSlowMode(deps, uid)) ? "slow" : "normal";
  return {
    rpm_limit: settings[`${mode}_rpm`],
    tpm_limit: settings[`${mode}_tpm`],
    max_parallel_requests: settings[`${mode}_parallel`],
  };
}

/** Push the current rate limits to every key (mint.py push_rate_limits). */
export async function poolPushRateLimits(deps: MintDeps, uid: string): Promise<void> {
  const limits = await poolRateLimits(deps, uid);
  for (const keyId of Object.values(await poolUserKeyIds(deps, uid))) {
    try {
      await deps.litellm.keyUpdate({ key: keyId, ...limits });
    } catch (err) {
      console.log(`[mint] rate-limit update error: ${errorName(err)}`);
    }
  }
}

/**
 * mint.py sync_slow_mode: persist the slow flag and, only when it CHANGED,
 * push the new rate limits to the user's keys. Returns whether it changed.
 */
export async function poolSyncSlowMode(
  deps: MintDeps,
  uid: string,
  slow: boolean,
  until: Date,
): Promise<boolean> {
  const was = await poolInSlowMode(deps, uid);
  if (slow) {
    await deps.redis.hset(DB2.SLOW_HASH, uid, (until.getTime() / 1000).toFixed(3));
  } else {
    await deps.redis.hdel(DB2.SLOW_HASH, uid);
  }
  if (was === slow) return false;
  await poolPushRateLimits(deps, uid);
  return true;
}

/**
 * Start of the live window, or null. An EXPIRED window is cleared here
 * (start/spend/auto deleted) exactly like mint.py current_window_start.
 */
export async function currentWindowStart(
  deps: MintDeps,
  uid: string,
  pools: Pools,
): Promise<Date | null> {
  const k = poolKeys(uid);
  const start = epochDt(await deps.redis.get(k.start));
  if (start !== null) {
    const endMs = start.getTime() + pools.window_hours * 3600_000;
    if (endMs <= clockNow(deps).getTime()) {
      await deps.redis.del(k.start, k.spend, k.auto);
      return null;
    }
  }
  return start;
}

/**
 * The current pool window [start, end). The start is created with SET NX EX
 * (the hook may win the race) and, on creation, anchored at `firstUse` when
 * mint found an earlier request than now. With create:false nothing is
 * written and the would-be window is returned.
 */
export async function windowBounds(
  deps: MintDeps,
  uid: string,
  pools: Pools,
  opts: { create?: boolean; firstUse?: Date | null } = {},
): Promise<{ start: Date; end: Date }> {
  const k = poolKeys(uid);
  const secs = Math.trunc(pools.window_hours * 3600);
  const now = clockNow(deps);
  const nowMs = now.getTime();
  const create = opts.create ?? true;
  const firstUse = opts.firstUse ?? null;

  let start = await currentWindowStart(deps, uid, pools);
  if (start === null) {
    if (!create) {
      return { start: now, end: new Date(nowMs + secs * 1000) };
    }
    const begin = firstUse !== null ? new Date(Math.min(firstUse.getTime(), nowMs)) : now;
    // floor to whole seconds so the first request is never after "start"
    const ttl = Math.max(1, Math.trunc(secs - (nowMs - begin.getTime()) / 1000));
    await deps.redis.set(k.start, String(Math.floor(begin.getTime() / 1000)), "EX", ttl, "NX");
    start = epochDt(await deps.redis.get(k.start)) ?? begin;
  }
  return { start, end: new Date(start.getTime() + secs * 1000) };
}

/** The hook's per-user spend counter for the live window (all keys). */
export async function hookSpend(deps: MintDeps, uid: string): Promise<number> {
  return floatOr(await deps.redis.get(poolKeys(uid).spend), 0);
}

/** The user's plan id (stored legacy aliases 3x/7x/15x resolve). */
export async function effectiveTier(deps: MintDeps, uid: string): Promise<string> {
  return (await planFor(deps, uid)).id;
}

/** The monthly backstop: per-user override or the global setting. */
export async function freeCapUsd(deps: MintDeps, uid: string): Promise<number> {
  const override = await deps.redis.get(`user:${uid}:monthlyCapUsd`);
  const s = await getSettings({ db: deps.db });
  return floatOr(override, s.free_monthly_cap_usd);
}

/** User-level spend over LiteLLM's user-budget window; 0 on error. */
export async function monthSpent(deps: MintDeps, uid: string): Promise<number> {
  const info = await deps.litellm.userInfo(uid);
  return info === null ? 0 : floatOr(info.spend, 0);
}

export async function freeCapRemaining(deps: MintDeps, uid: string): Promise<number> {
  return Math.max(0, (await freeCapUsd(deps, uid)) - (await monthSpent(deps, uid)));
}

/**
 * The monthly backstop's reset instant: LiteLLM's per-user budget clock
 * (`user_info.budget_reset_at`) — the SAME 30-day clock userBudgetTarget arms
 * for the free plan (cap over 30d), so when that budget is spent up it is
 * this stamp the client counts down to. Null when LiteLLM reports no clock
 * (user unknown, outage, budget never armed) or an unparseable stamp — the
 * 402 then carries no x-ovid-resets-at and the client shows no countdown.
 */
export async function freeCapResetAt(deps: MintDeps, uid: string): Promise<Date | null> {
  const raw = (await deps.litellm.userInfo(uid))?.budget_reset_at ?? null;
  if (raw === null) return null;
  const ms = Date.parse(raw);
  return Number.isNaN(ms) ? null : new Date(ms);
}

async function tierBudgetWith(
  deps: MintDeps,
  uid: string,
  tier: string,
  s: Settings,
): Promise<{ budget: number; duration: string }> {
  const freeDaily = await userFreeDaily({ db: deps.db }, uid);
  const override = await getOverride({ db: deps.db }, uid);
  const pools = userPools(s, findPlan(s, tier), freeDaily, override);
  return { budget: keyBudget(pools, s), duration: windowStr(pools.window_hours) };
}

/** (LiteLLM key max_budget, budget_duration) for a plan id or alias. */
export async function tierBudget(
  deps: MintDeps,
  uid: string,
  tier: string,
): Promise<{ budget: number; duration: string }> {
  const s = await getSettings({ db: deps.db });
  return tierBudgetWith(deps, uid, tier, s);
}

/**
 * The LiteLLM USER budget: free plan = the monthly backstop over 30d; every
 * other plan = the key budget per plan window.
 */
export async function userBudgetTarget(
  deps: MintDeps,
  uid: string,
  tier: string,
): Promise<{ budget: number; duration: string }> {
  const s = await getSettings({ db: deps.db });
  if (findPlan(s, tier).id === "free") {
    return { budget: await freeCapUsd(deps, uid), duration: "30d" };
  }
  return tierBudgetWith(deps, uid, tier, s);
}

/** mint.py ensure_user_budget — the duration is sent only when it changes. */
export async function ensureUserBudget(
  deps: MintDeps,
  uid: string,
  tier: string,
  forceDuration: boolean,
  extra: Record<string, unknown> | null,
): Promise<void> {
  const { budget, duration } = await userBudgetTarget(deps, uid, tier);
  const body: Record<string, unknown> = {
    user_id: uid,
    max_budget: budget,
    ...(extra ?? {}),
  };
  // Only send budget_duration when it changes: LiteLLM restarts the budget
  // clock (budget_reset_at = now + duration) whenever it is sent.
  let current: string | null | "unknown" = null;
  if (!forceDuration) {
    const { status, info } = await deps.litellm.userInfoStatus(uid);
    if (status === 200) {
      current = info?.budget_duration ?? null;
    } else if (status !== 404) {
      current = "unknown"; // outage: don't touch the clock
    }
  }
  if (forceDuration || (current !== duration && current !== "unknown")) {
    body.budget_duration = duration;
  }
  const status = await deps.litellm.userUpdate(body);
  if (status === 0) {
    // The wrapper swallows network errors; reapplyUser must count this like
    // Python's raised httpx exception.
    throw new Error("user/update network error");
  }
  if (status >= 300) {
    console.log(`[mint] user/update ${status} for ${uid.slice(0, 6)}`);
  }
}

/** mint.py apply_key_budget: budget + rate limits; duration only on change. */
async function applyKeyBudget(
  deps: MintDeps,
  keyId: string,
  budget: number,
  duration: string,
  info: Record<string, unknown> | null,
  extra: Record<string, unknown>,
  forceDuration: boolean,
): Promise<boolean> {
  const body: Record<string, unknown> = { key: keyId, max_budget: budget, ...extra };
  if (forceDuration || (info !== null && info.budget_duration !== duration)) {
    body.budget_duration = duration;
  }
  const status = await deps.litellm.keyUpdateStatus(body);
  if (status === 0) throw new Error("key/update network error");
  if (status >= 300) {
    console.log(`[mint] key/update ${status}`);
    return false;
  }
  return true;
}

/**
 * mint.py reapply_user: re-apply the window budget + rate limits to EVERY key
 * (android + web) and the LiteLLM user budget. `extra` merges into each key
 * body, `userExtra` into the user body.
 */
export async function reapplyUser(
  deps: MintDeps,
  uid: string,
  opts: {
    extra?: Record<string, unknown>;
    forceDuration?: boolean;
    userExtra?: Record<string, unknown> | null;
    userForceDuration?: boolean;
  } = {},
): Promise<ReapplyResult> {
  const forceDuration = opts.forceDuration ?? false;
  const userForceDuration = opts.userForceDuration ?? false;
  const s = await getSettings({ db: deps.db });
  const plan = await planFor(deps, uid, s);
  const { budget, duration } = await tierBudgetWith(deps, uid, plan.id, s);
  const bodyExtra = { ...(await poolRateLimits(deps, uid, s)), ...(opts.extra ?? {}) };

  let keys = 0;
  let errors = 0;
  for (const keyId of Object.values(await poolUserKeyIds(deps, uid))) {
    try {
      const info = forceDuration ? null : await deps.litellm.keyInfo(keyId);
      if (await applyKeyBudget(deps, keyId, budget, duration, info, bodyExtra, forceDuration)) {
        keys += 1;
      } else {
        errors += 1;
      }
    } catch (err) {
      errors += 1;
      console.log(`[mint] reapply key error: ${errorName(err)}`);
    }
  }
  try {
    await ensureUserBudget(deps, uid, plan.id, userForceDuration, opts.userExtra ?? null);
  } catch (err) {
    errors += 1;
    console.log(`[mint] reapply user error: ${errorName(err)}`);
  }
  return { keys, errors };
}

/**
 * mint.py reset_window_user: restart the window NOW — clear the pool
 * counters, slow mode and usage cache, zero spend on every key, and
 * re-apply the budgets. The free plan's LiteLLM user budget is the monthly
 * backstop with its own 30-day clock, so it restarts only when
 * resetMonthFree is set; other plans' user budget is the window budget.
 */
export async function resetWindowUser(
  deps: MintDeps,
  uid: string,
  opts: { resetMonthFree?: boolean } = {},
): Promise<ReapplyResult> {
  const now = clockNow(deps);
  const s = await getSettings({ db: deps.db });
  const plan = await planFor(deps, uid, s);
  const freeDaily = await userFreeDaily({ db: deps.db }, uid);
  const override = await getOverride({ db: deps.db }, uid);
  const pools = userPools(s, plan, freeDaily, override);
  const k = poolKeys(uid);

  await deps.redis.del(k.spend, k.auto, `usagecache:${uid}`);
  await deps.redis.set(
    k.start,
    (now.getTime() / 1000).toFixed(3),
    "EX",
    Math.trunc(pools.window_hours * 3600),
  );
  await deps.redis.hdel(DB2.SLOW_HASH, uid);
  await deps.redis.srem(DB2.SLOW_PENDING, uid);

  const isFree = plan.id === "free";
  const restartUser = !isFree || (opts.resetMonthFree ?? false);
  const res = await reapplyUser(deps, uid, {
    extra: { spend: 0 },
    forceDuration: true,
    userExtra: restartUser ? { spend: 0 } : null,
    userForceDuration: restartUser,
  });
  await deps.redis.del(monthKey(uid, now)); // legacy key, harmless
  return res;
}

/** Drop the 15 s /usage caches for the given users. */
export async function dropUsageCache(deps: MintDeps, uids: string[]): Promise<void> {
  for (const uid of uids) {
    await deps.redis.del(`usagecache:${uid}`);
  }
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : String(err);
}
