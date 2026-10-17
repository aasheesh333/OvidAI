import { plansRepo, type Db, type PlanRecord } from "@ovid/db";
import type { Redis } from "ioredis";
import { pyNumStr } from "@ovid/money";
import {
  SCALARS,
  SEED_AUTO_OSS_MEMBERS,
  seedPlans,
  serializeSettings,
  validateMembers,
  validatePlan,
  validateSettings,
  type PoolsOverride,
  type Settings,
} from "./planMath.js";

/**
 * Settings authority: Postgres is durable (Ruling Q4) — plans-as-data rows
 * (Task 2's plansRepo) + the mint_settings singleton — and Redis db2 is a
 * request-time projection re-published on every change (projection.ts).
 * Port of mint.py's get_settings/store_settings/ensure_default_settings/
 * user_free_daily/user_pool_override with the storage swapped from the
 * config:limits hash to Postgres.
 *
 * Seed values are the ovid_plans.py FIRST-RUN seeds (mint.py's SEEDS block
 * comes from the same defaults; the env knobs around them are not ported —
 * Postgres is the authority from the first boot).
 *
 * NOTE on the two drizzle-adjacent queries (stale-plan delete): they run
 * through drizzle's `$client` (postgres.js tagged templates) because
 * @ovid/mint must not import drizzle-orm directly (not a package dependency
 * under pnpm's strict node_modules), and @ovid/db's repo surface has no
 * plan-delete by design.
 */

/** deps shared by every settings call. */
export interface SettingsDeps {
  db: Db;
}

const SCALAR_NAMES = Object.keys(SCALARS);

const SCALAR_SEEDS: Record<string, number> = Object.fromEntries(
  Object.entries(SCALARS).map(([name, spec]) => [name, spec.seed]),
);

/** PlanData → the plans table row (money columns as exact decimal strings). */
function planRow(p: Settings["plans"][number], position: number): PlanRecord {
  return {
    id: p.id,
    name: p.name,
    priceUsd: String(p.price_usd),
    enabled: p.enabled,
    aliases: p.aliases,
    windowHours: Math.trunc(p.window_hours),
    mult: String(p.mult),
    slowMode: p.slow_mode,
    autoOss: p.auto_oss,
    position,
  };
}

/**
 * ensureDefaultSettings — ADD-only seeding (Python ensure_default_settings):
 * writes the first-run seeds for UNSET things and NEVER overwrites a stored
 * value. An existing install (settings row or any users) seeds paid-plan
 * windows at 720h (the behaviour before plans existed); a new install at 24h.
 * The users scan runs only while the settings row is absent, so steady-state
 * getSettings costs the same two queries as Python's HGETALL + GET.
 */
async function ensureDefaultSettings(db: Db): Promise<void> {
  const [record, planRows] = await Promise.all([
    plansRepo.getSettings(db),
    plansRepo.list(db),
  ]);
  const existingInstall =
    record !== null || (await plansRepo.allUids(db)).length > 0;
  const paidWindowHours = existingInstall ? 720 : 24;

  // plans: Python seeds the WHOLE plans field only when absent (hget is None)
  // — the row-level translation is "table empty → write the seed list"; a
  // non-empty table is never re-seeded, so removing a plan row sticks.
  if (planRows.length === 0) {
    let index = 0;
    for (const p of seedPlans(paidWindowHours)) {
      await plansRepo.upsert(db, planRow(p, index++));
    }
  }

  // settings singleton: insert whole when absent; fill only MISSING scalar
  // keys when present (Python's per-field `if hget is None` ADD-only rule)
  if (record === null) {
    await plansRepo.saveSettings(db, {
      baseDailyUsd: pyNumStr(0.15),
      scalars: { ...SCALAR_SEEDS },
      autoOssMembers: SEED_AUTO_OSS_MEMBERS,
    });
  } else {
    const missing = SCALAR_NAMES.some(
      (k) => (record.scalars as Record<string, unknown>)[k] === undefined,
    );
    if (missing) {
      const merged: Record<string, number> = {};
      for (const [name, seed] of Object.entries(SCALAR_SEEDS)) {
        const v = (record.scalars as Record<string, unknown>)[name];
        merged[name] = v === undefined ? seed : (v as number);
      }
      await plansRepo.saveSettings(db, { ...record, scalars: merged });
    }
  }
}

/**
 * Live settings from Postgres. Uninitialized tables are seeded first
 * (ADD-only, so a second call never re-seeds over edited values). Reads are
 * tolerant exactly like Python's parse_settings: corrupt rows fall back to
 * the seeds rather than throwing (mint must keep serving).
 */
export async function getSettings(deps: SettingsDeps): Promise<Settings> {
  const { db } = deps;
  await ensureDefaultSettings(db);
  const [record, planRows] = await Promise.all([plansRepo.getSettings(db), plansRepo.list(db)]);

  // scalars with _num tolerance (Python parse_settings) — always present
  // after the ensure above; defaults kept as a guard against hand-edited rows
  const scalars: Record<string, number> = {};
  for (const [name, spec] of Object.entries(SCALARS)) {
    const v = (record?.scalars as Record<string, unknown> | undefined)?.[name];
    const n = typeof v === "number" && !Number.isNaN(v) ? v : spec.seed;
    scalars[name] = spec.type === "int" ? Math.trunc(n) : n;
  }

  // members: invalid stored → [] (plain auto); absent → the seed members
  let autoOssMembers: Settings["auto_oss_members"];
  if (record === null) {
    autoOssMembers = SEED_AUTO_OSS_MEMBERS;
  } else {
    try {
      autoOssMembers = validateMembers(record.autoOssMembers);
    } catch {
      autoOssMembers = [];
    }
  }

  // plans: validated rows; a corrupt list falls back to seedPlans (24h),
  // exactly like parse_settings replacing an invalid stored blob
  let plans: Settings["plans"];
  try {
    if (planRows.length === 0) throw new Error("no plans");
    plans = planRows.map((r) =>
      validatePlan({
        id: r.id,
        name: r.name,
        price_usd: Number(r.priceUsd),
        enabled: r.enabled,
        aliases: r.aliases,
        window_hours: r.windowHours,
        mult: Number(r.mult),
        slow_mode: r.slowMode,
        auto_oss: r.autoOss,
      }),
    );
  } catch {
    plans = seedPlans();
  }

  // base_daily_usd is stored as Python str(float) text — parse with the 0.15
  // default of parse_settings on garbage
  const freeDaily = record === null ? 0.15 : pyNumOr(record.baseDailyUsd, 0.15);
  return {
    free_daily_usd: freeDaily,
    ...scalars,
    auto_oss_members: autoOssMembers,
    plans,
  } as Settings;
}

/** mint.py _float_or: default on unparseable (never throws). */
function pyNumOr(raw: string, dflt: number): number {
  if (raw === null || raw === undefined || raw.trim() === "") return dflt;
  const n = Number(raw);
  return Number.isNaN(n) ? dflt : n;
}

/**
 * Postgres committed, but the Redis db2 re-publish failed. The durable state
 * is authoritative; the caller must surface a degraded projection (and audit
 * it) rather than pretending the write was rejected. The underlying driver
 * message is kept as `cause` for the server log only — never the wire.
 */
export class ProjectionPublishError extends Error {
  constructor(readonly cause: unknown) {
    super("redis projection failed");
    this.name = "ProjectionPublishError";
  }
}

/**
 * Store settings: validateSettings → save Postgres (authority) → publish the
 * db2 projection. usagecache:* is deliberately NOT dropped (the 15 s TTL
 * rides out — the plan's ruling on the brief's open question). Returns the
 * validated settings.
 */
export async function storeSettings(deps: { db: Db; redis: Redis }, s: Settings): Promise<Settings> {
  const { db, redis } = deps;
  const validated = validateSettings(s);

  // Postgres — full replace, exactly like Python writing the whole plans
  // JSON: upsert every plan (position = list index) and remove stale rows
  const rows = validated.plans.map((p, i) => planRow(p, i));
  for (const row of rows) {
    await plansRepo.upsert(db, row);
  }
  const ids = rows.map((r) => r.id); // never empty: 'free' is required
  await db.$client`DELETE FROM plans WHERE NOT (id = ANY(${ids}))`;
  const scalars: Record<string, number> = Object.fromEntries(
    SCALAR_NAMES.map((k) => [k, (validated as unknown as Record<string, number>)[k]]),
  );
  await plansRepo.saveSettings(db, {
    baseDailyUsd: pyNumStr(validated.free_daily_usd),
    scalars,
    autoOssMembers: validated.auto_oss_members,
  });

  // Redis db2 projection — the hook's config:limits + config:base_daily_usd.
  // Postgres is already committed here: a projection failure is a DEGRADED
  // state, not a rejected write (the caller audits it and asks for a resync).
  try {
    await publishSettingsToRedis(redis, validated);
  } catch (err) {
    throw new ProjectionPublishError(err);
  }
  return validated;
}

/** The exact Redis writes of ovid_plans.serialize_settings → rds.set/hset. */
export async function publishSettingsToRedis(redis: Redis, s: Settings): Promise<void> {
  const { baseDaily, fields } = serializeSettings(s);
  await redis.set("config:base_daily_usd", baseDaily);
  await redis.hset("config:limits", fields);
}

/** The per-user pools override (Redis user:{uid}:pools shape) from Postgres. */
export async function getOverride(deps: SettingsDeps, uid: string): Promise<PoolsOverride | null> {
  const rec = await plansRepo.getOverride(deps.db, uid);
  return rec?.pools ?? null;
}

/**
 * This user's free allowance per 24h: the admin's custom limit or the global
 * (mint.py user_free_daily; the override text is an exact decimal string).
 */
export async function userFreeDaily(deps: SettingsDeps, uid: string): Promise<number> {
  const [rec, s] = await Promise.all([plansRepo.getOverride(deps.db, uid), getSettings(deps)]);
  const raw = rec?.dailyUsd ?? null;
  if (raw !== null && raw.trim() !== "") {
    const n = Number(raw);
    if (!Number.isNaN(n)) return n; // Python float(override), default on ValueError
  }
  return s.free_daily_usd;
}
