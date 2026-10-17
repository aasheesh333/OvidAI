/**
 * Task 18 — clean-break seeding (Q1 branch "clean break").
 *
 * EXECUTION IS OWNER-GATED (DECOMMISSION.md Step 3). Seeds ONLY plans +
 * settings into an EMPTY Postgres and publishes the db2 projection; it
 * imports no user data. The owner then edits live values in the admin
 * console (that edit is the migration).
 *
 * Refuses to run when the database already holds users or a settings row
 * unless `--force` is passed, so a mistaken invocation cannot overwrite a
 * configured install. Nothing in Redis is flushed.
 *
 * Usage:
 *   node --experimental-strip-types cloud/scripts/migrate/seedFresh.ts \
 *     [--database-url postgres://…] [--redis-url redis://…/2] \
 *     [--base-daily-usd 0.15] [--paid-window-hours 24] [--force] [--dry-run]
 */

import { parseSettings, seedPlans, type Settings } from "../../apps/mint/dist/planMath.js";
import { storeSettings } from "../../apps/mint/dist/settings.js";
import {
  argValue,
  closeDb,
  hasFlag,
  isMain,
  line,
  ok,
  openDb,
  openRedis,
  ovidDb,
  requiredSetting,
  type DbHandle,
  type RedisLike,
} from "./runtime.js";

export interface SeedFreshReport {
  seeded: boolean;
  baseDailyUsd: string;
  paidWindowHours: number;
  plans: Array<{ id: string; windowHours: number; enabled: boolean }>;
  existingUsers: number;
}

function intArg(raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) {
    throw new Error(`--paid-window-hours must be a positive integer, got ${raw}`);
  }
  return n;
}

export function buildSeedSettings(baseDailyUsd: string, paidWindowHours: number): Settings {
  if (!/^\d+(?:\.\d+)?$/.test(baseDailyUsd)) {
    throw new Error(`--base-daily-usd must be a non-negative decimal, got ${baseDailyUsd}`);
  }
  return parseSettings({}, null, {
    free_daily_usd: Number(baseDailyUsd),
    plans: seedPlans(paidWindowHours),
  });
}

export async function seedFresh(deps: {
  db: DbHandle;
  redis: RedisLike;
  baseDailyUsd?: string;
  paidWindowHours?: number;
  force?: boolean;
  dryRun?: boolean;
}): Promise<SeedFreshReport> {
  const baseDailyUsd = deps.baseDailyUsd ?? "0.15";
  const paidWindowHours = deps.paidWindowHours ?? 24;
  const [userCount] = await deps.db.$client`SELECT count(*)::int AS n FROM users`;
  const existingUsers = Number(userCount?.n ?? 0);
  const existingSettings = await ovidDb.plansRepo.getSettings(deps.db);

  if (!deps.force && (existingUsers > 0 || existingSettings !== null)) {
    throw new Error(
      `refusing to seed: database already has users=${existingUsers} settings=${existingSettings !== null}; ` +
        "this script is for a clean break — pass --force only after confirming",
    );
  }

  const settings = buildSeedSettings(baseDailyUsd, paidWindowHours);
  const report: SeedFreshReport = {
    seeded: deps.dryRun !== true,
    baseDailyUsd,
    paidWindowHours,
    plans: settings.plans.map((plan) => ({
      id: plan.id,
      windowHours: Math.trunc(plan.window_hours),
      enabled: plan.enabled,
    })),
    existingUsers,
  };

  if (deps.dryRun !== true) {
    // Validates, writes plans + the settings singleton (Postgres authority),
    // and publishes config:limits/config:base_daily_usd to db2.
    await storeSettings({ db: deps.db, redis: deps.redis }, settings);
  }
  return report;
}

export function formatReport(report: SeedFreshReport): string[] {
  return [
    line("seeded", report.seeded),
    line("base daily USD", report.baseDailyUsd),
    line("paid window hours", report.paidWindowHours),
    line("existing users", report.existingUsers),
    ...report.plans.map(
      (plan) => `  plan ${plan.id.padEnd(8)} window=${plan.windowHours}h enabled=${plan.enabled}`,
    ),
  ];
}

async function cli(): Promise<void> {
  const argv = process.argv.slice(2);
  const databaseUrl = requiredSetting(argv, "--database-url", "DATABASE_URL");
  const redisUrl = requiredSetting(argv, "--redis-url", "REDIS_DB2_URL");
  const dryRun = hasFlag(argv, "--dry-run");

  const db = openDb(databaseUrl);
  const redis = openRedis(redisUrl);
  try {
    const report = await seedFresh({
      db,
      redis,
      baseDailyUsd: argValue(argv, "--base-daily-usd") ?? "0.15",
      paidWindowHours: intArg(argValue(argv, "--paid-window-hours"), 24),
      force: hasFlag(argv, "--force"),
      dryRun,
    });
    console.log(`[seedFresh]${dryRun ? " DRY RUN" : ""}`);
    for (const row of formatReport(report)) console.log(row);
    if (!dryRun) {
      ok("clean-break seed complete — set live values in the admin console");
    }
  } finally {
    redis.disconnect();
    await closeDb(db);
  }
}

if (isMain(import.meta.url)) {
  cli().catch((err) => {
    console.error(`[seedFresh] FAILED: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  });
}
