import { AsyncLocalStorage } from "node:async_hooks";
import {
  billingUsers,
  type BillingRemoteEffect,
  type BillingRemoteExecuteOptions,
  type BillingRemoteExecution,
  type BillingRemoteOperation,
  type BillingRemoteOperationKind,
  type Db,
} from "@ovid/db";
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
import {
  executeMintRemoteOperation,
  mintRemoteOperation,
} from "./billing/remoteProtocol.js";

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

/** Per-call billing generation, propagated through the existing one-argument production wrapper. */
const billingProjectionGeneration = new AsyncLocalStorage<number>();
const billingRecoveryId = new AsyncLocalStorage<string>();
const billingRemoteWriteLock = new AsyncLocalStorage<string>();
export const BILLING_REFRESH_GENERATION_KEY = (uid: string): string =>
  `user:${uid}:billing_refresh_generation`;

/** A compatibility writer was superseded before its callback performed any mutation. */
export class StaleBillingAccountWriteError extends Error {
  constructor() {
    super("stale billing projection generation");
    this.name = "StaleBillingAccountWriteError";
  }
}

export function withBillingProjectionGeneration<T>(
  generation: number,
  operation: () => Promise<T>,
): Promise<T> {
  return billingProjectionGeneration.run(generation, operation);
}

/** Generation bound to the current account lock; unversioned boot resyncs have none. */
export function currentBillingProjectionGeneration(): number | undefined {
  return billingProjectionGeneration.getStore();
}

/** Share one cross-process account lock with billing and compatibility writers. */
export async function withBillingAccountLock<T>(
  db: Db,
  uid: string,
  operation: () => Promise<T>,
): Promise<T> {
  if (billingRemoteWriteLock.getStore() === uid) return operation();
  return billingUsers.withBillingRemoteWriteLock(db, uid, () =>
    billingRemoteWriteLock.run(uid, operation),
  );
}

/** Compatibility writers join the same durable latest-generation protocol. */
export async function withBillingAccountWrite<T>(
  deps: Pick<MintDeps, "db" | "redis">,
  uid: string,
  operation: () => Promise<T>,
  opts: { recoveryId?: string } = {},
): Promise<T> {
  if (billingRemoteWriteLock.getStore() === uid) return operation();
  return withBillingAccountLock(deps.db, uid, async () => {
    // Generation allocation is inside the SAME cross-process scope lock as the
    // side effects. A newer refund therefore cannot supersede halfway through
    // this callback and expose a stale intermediate durable/Redis write.
    const { generation } = await billingUsers.beginRefresh(deps.db, uid, opts.recoveryId);
    const key = BILLING_REFRESH_GENERATION_KEY(uid);
    const reserved = await deps.redis.eval(
      `local current = tonumber(redis.call('GET', KEYS[1]) or '0')
       if tonumber(ARGV[1]) < current then return 0 end
       redis.call('SET', KEYS[1], ARGV[1])
       return 1`,
      1,
      key,
      String(generation),
    );
    if (Number(reserved) !== 1) throw new StaleBillingAccountWriteError();
    if (!(await billingUsers.isLatestRefresh(deps.db, uid, generation))) {
      throw new StaleBillingAccountWriteError();
    }
    return withBillingProjectionGeneration(generation, () =>
      opts.recoveryId === undefined
        ? operation()
        : billingRecoveryId.run(opts.recoveryId, operation),
    );
  });
}

async function withAccountWriter<T>(
  deps: MintDeps,
  uid: string,
  operation: () => Promise<T>,
  opts: { retrySuperseded?: boolean; recoveryId?: string } = {},
): Promise<T> {
  if (billingRemoteWriteLock.getStore() === uid) return operation();
  if (billingProjectionGeneration.getStore() !== undefined) {
    return withBillingAccountLock(deps.db, uid, operation);
  }
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      return await withBillingAccountWrite(deps, uid, operation, { recoveryId: opts.recoveryId });
    } catch (error) {
      if (opts.retrySuperseded !== true || !(error instanceof StaleBillingAccountWriteError)) {
        throw error;
      }
    }
  }
  throw new StaleBillingAccountWriteError();
}

async function billingProjectionCurrent(deps: MintDeps, uid: string): Promise<boolean> {
  const expected = billingProjectionGeneration.getStore();
  if (expected === undefined) return true;
  return (await deps.redis.get(BILLING_REFRESH_GENERATION_KEY(uid))) === String(expected);
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
  return withAccountWriter(deps, uid, async () => {
    const limits = await poolRateLimits(deps, uid);
    for (const keyId of Object.values(await poolUserKeyIds(deps, uid))) {
      await performRemoteOperation(
        deps,
        remoteOperation(uid, "key", keyId, { key: keyId, ...limits }),
      );
    }
  }, { retrySuperseded: true });
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
  return withAccountWriter(deps, uid, async () => {
    const generation = currentBillingProjectionGeneration();
    if (generation === undefined) throw new StaleBillingAccountWriteError();
    const was = await poolInSlowMode(deps, uid);
    if (was === slow) return false;
    const result = slow
      ? await deps.redis.eval(
          `if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
           redis.call('HSET', KEYS[2], ARGV[2], ARGV[3])
           return 1`,
          2,
          BILLING_REFRESH_GENERATION_KEY(uid),
          DB2.SLOW_HASH,
          String(generation),
          uid,
          (until.getTime() / 1000).toFixed(3),
        )
      : await deps.redis.eval(
          `if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
           redis.call('HDEL', KEYS[2], ARGV[2])
           return 1`,
          2,
          BILLING_REFRESH_GENERATION_KEY(uid),
          DB2.SLOW_HASH,
          String(generation),
          uid,
        );
    if (Number(result) !== 1) throw new StaleBillingAccountWriteError();
    await poolPushRateLimits(deps, uid);
    return true;
  }, { retrySuperseded: true });
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

function remoteOperation(
  uid: string,
  kind: BillingRemoteOperationKind,
  target: string,
  body: Record<string, unknown>,
  opts: {
    effect?: BillingRemoteEffect;
    idempotencyKey?: string;
    restartBudgetClock?: boolean;
  } = {},
): BillingRemoteOperation {
  const generation = billingProjectionGeneration.getStore();
  if (generation === undefined) throw new Error("billing remote operation requires generation");
  const restart = opts.restartBudgetClock === true;
  const recoveryId = opts.idempotencyKey ?? (restart ? billingRecoveryId.getStore() : undefined);
  if (restart && recoveryId === undefined) {
    throw new Error("budget clock restart requires a stable logical recovery id");
  }
  return mintRemoteOperation(uid, generation, kind, target, body, {
    ...opts,
    ...(recoveryId === undefined ? {} : { idempotencyKey: recoveryId }),
  });
}

/** Shared lifecycle entry point used by key mint/rotation, bans, and team writes. */
export async function executeBillingRemoteOperation(
  deps: MintDeps,
  uid: string,
  kind: BillingRemoteOperationKind,
  target: string,
  body: Record<string, unknown>,
  opts: {
    effect?: BillingRemoteEffect;
    idempotencyKey?: string;
    restartBudgetClock?: boolean;
  } = {},
  execution: BillingRemoteExecuteOptions = {},
): Promise<BillingRemoteExecution> {
  return executeMintRemoteOperation(deps, remoteOperation(uid, kind, target, body, opts), execution);
}

/** One account serialized, write-ahead, latest-generation fenced remote mutation. */
async function performRemoteOperation(
  deps: MintDeps,
  operation: BillingRemoteOperation,
): Promise<void> {
  await executeMintRemoteOperation(deps, operation);
}

/** mint.py ensure_user_budget — the duration is sent only when it changes. */
async function ensureUserBudgetLocked(
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
  if (!(await billingProjectionCurrent(deps, uid))) {
    throw new Error("stale billing projection generation");
  }
  await performRemoteOperation(deps, remoteOperation(uid, "user", uid, body, {
    restartBudgetClock: forceDuration,
  }));
  if (!(await billingProjectionCurrent(deps, uid))) {
    throw new Error("stale billing projection generation");
  }
}

export async function ensureUserBudget(
  deps: MintDeps,
  uid: string,
  tier: string,
  forceDuration: boolean,
  extra: Record<string, unknown> | null,
): Promise<void> {
  return withAccountWriter(deps, uid, () =>
    ensureUserBudgetLocked(deps, uid, tier, forceDuration, extra),
  );
}

/** mint.py apply_key_budget: budget + rate limits; duration only on change. */
async function applyKeyBudget(
  deps: MintDeps,
  uid: string,
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
  if (!(await billingProjectionCurrent(deps, uid))) {
    throw new Error("stale billing projection generation");
  }
  await performRemoteOperation(deps, remoteOperation(uid, "key", keyId, body, {
    restartBudgetClock: forceDuration,
  }));
  if (!(await billingProjectionCurrent(deps, uid))) {
    throw new Error("stale billing projection generation");
  }
  return true;
}

/** Compatibility entry point for an existing key's complete mutation body. */
export async function updateKeyProjection(
  deps: MintDeps,
  uid: string,
  keyId: string,
  body: Record<string, unknown>,
): Promise<void> {
  return withAccountWriter(deps, uid, async () => {
    if (!(await billingProjectionCurrent(deps, uid))) {
      throw new Error("stale billing projection generation");
    }
    await performRemoteOperation(
      deps,
      remoteOperation(uid, "key", keyId, { ...body, key: keyId }),
    );
    if (!(await billingProjectionCurrent(deps, uid))) {
      throw new Error("stale billing projection generation");
    }
  });
}

/**
 * mint.py reapply_user: re-apply the window budget + rate limits to EVERY key
 * (android + web) and the LiteLLM user budget. `extra` merges into each key
 * body, `userExtra` into the user body.
 */
async function reapplyUserUnlocked(
  deps: MintDeps,
  uid: string,
  opts: {
    extra?: Record<string, unknown>;
    forceDuration?: boolean;
    userExtra?: Record<string, unknown> | null;
    userForceDuration?: boolean;
    operationId?: string;
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
      if (await applyKeyBudget(deps, uid, keyId, budget, duration, info, bodyExtra, forceDuration)) {
        keys += 1;
      } else {
        errors += 1;
      }
    } catch (err) {
      errors += 1;
      console.log(`[mint] reapply key error: ${errorName(err)}`);
      return { keys, errors };
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
 * Billing and compatibility callers serialize the entire remote sequence per
 * account. Without this lock, an older paid request can finish after a newer
 * Free request even though generation pre/post checks fire. Every caller
 * allocates its durable generation only after entering the same scope lock.
 */
export async function reapplyUser(
  deps: MintDeps,
  uid: string,
  opts: {
    extra?: Record<string, unknown>;
    forceDuration?: boolean;
    userExtra?: Record<string, unknown> | null;
    userForceDuration?: boolean;
    /** Required for any explicit budget-clock restart; stable across retry. */
    operationId?: string;
  } = {},
): Promise<ReapplyResult> {
  const force = opts.forceDuration === true || opts.userForceDuration === true;
  if (force && (opts.operationId === undefined || opts.operationId.trim() === "")) {
    throw new Error("explicit budget clock restart requires a stable operationId");
  }
  return withAccountWriter(
    deps,
    uid,
    () => reapplyUserUnlocked(deps, uid, opts),
    {
      retrySuperseded: true,
      ...(force ? { recoveryId: `budget-restart:${uid}:${opts.operationId}` } : {}),
    },
  );
}

/**
 * mint.py reset_window_user: restart the window NOW — clear the pool
 * counters, slow mode and usage cache, zero spend on every key, and
 * re-apply the budgets. The free plan's LiteLLM user budget is the monthly
 * backstop with its own 30-day clock, so it restarts only when
 * resetMonthFree is set; other plans' user budget is the window budget.
 */
async function resetWindowUserLocked(
  deps: MintDeps,
  uid: string,
  opts: { resetMonthFree?: boolean; operationId: string },
): Promise<ReapplyResult> {
  const now = clockNow(deps);
  const s = await getSettings({ db: deps.db });
  const plan = await planFor(deps, uid, s);
  const freeDaily = await userFreeDaily({ db: deps.db }, uid);
  const override = await getOverride({ db: deps.db }, uid);
  const pools = userPools(s, plan, freeDaily, override);
  const k = poolKeys(uid);

  const generation = currentBillingProjectionGeneration();
  if (generation === undefined) throw new StaleBillingAccountWriteError();
  const projected = await deps.redis.eval(
    `if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
     redis.call('DEL', KEYS[2], KEYS[3], KEYS[4], KEYS[8])
     redis.call('SET', KEYS[5], ARGV[3], 'EX', ARGV[4])
     redis.call('HDEL', KEYS[6], ARGV[2])
     redis.call('SREM', KEYS[7], ARGV[2])
     return 1`,
    8,
    BILLING_REFRESH_GENERATION_KEY(uid),
    k.spend,
    k.auto,
    `usagecache:${uid}`,
    k.start,
    DB2.SLOW_HASH,
    DB2.SLOW_PENDING,
    monthKey(uid, now),
    String(generation),
    uid,
    (now.getTime() / 1000).toFixed(3),
    String(Math.trunc(pools.window_hours * 3600)),
  );
  if (Number(projected) !== 1) throw new StaleBillingAccountWriteError();

  const isFree = plan.id === "free";
  const restartUser = !isFree || (opts.resetMonthFree ?? false);
  const res = await reapplyUser(deps, uid, {
    extra: { spend: 0 },
    forceDuration: true,
    userExtra: restartUser ? { spend: 0 } : null,
    userForceDuration: restartUser,
    operationId: opts.operationId,
  });
  return res;
}

export async function resetWindowUser(
  deps: MintDeps,
  uid: string,
  opts: { resetMonthFree?: boolean; operationId: string },
): Promise<ReapplyResult> {
  const operationId = opts.operationId.trim();
  if (operationId === "") throw new Error("window reset requires a stable operationId");
  return withAccountWriter(
    deps,
    uid,
    () => resetWindowUserLocked(deps, uid, opts),
    { retrySuperseded: true, recoveryId: `window-reset:${uid}:${operationId}` },
  );
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
