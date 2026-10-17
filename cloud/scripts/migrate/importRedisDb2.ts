/**
 * Task 18 — installed-base import #1: Redis db2 → Postgres (insert-if-absent).
 *
 * EXECUTION IS OWNER-GATED (DECOMMISSION.md Step 3 / Q1 "installed base").
 * This script NEVER deletes or rewrites a Redis key and NEVER overwrites an
 * existing Postgres row; it is safe to re-run. The authoritative resync that
 * follows (MINT_PROJECTION_MODE=import-first → resyncAtBoot) is what makes
 * Postgres the winner from then on.
 *
 * What is imported (projection.importFromRedisOnce):
 *   config:limits hash + config:base_daily_usd → mint_settings + plans
 *   ovid:uids → users (uid, email, tier, tier_expires_at, banned_at/reason,
 *   mint_provisioned) and user_plan_overrides (dailyUsd, monthlyCapUsd, pools)
 *
 * Key ids stay where the hook and the TS app both read them: Redis
 * `user:{uid}:keyid` / `user:{uid}:web:keyid`. There is deliberately no
 * Postgres column for them, so this script reports their presence instead of
 * inventing one — a uid with no keyid is a real migration anomaly the owner
 * must see before flipping /mint.
 *
 * Usage:
 *   node --experimental-strip-types cloud/scripts/migrate/importRedisDb2.ts \
 *     [--database-url postgres://…] [--redis-url redis://…/2] [--dry-run]
 */

import { createProjection } from "../../apps/mint/dist/projection.js";
import {
  closeDb,
  hasFlag,
  isMain,
  line,
  ok,
  openDb,
  openRedis,
  requiredSetting,
  type DbHandle,
  type RedisLike,
} from "./runtime.js";

export const OVID_UIDS_SET = "ovid:uids";

export interface ImportRedisReport {
  imported: { users: number; plans: boolean; settings: boolean };
  scannedUids: number;
  uidsWithAndroidKey: number;
  uidsWithWebKey: number;
  uidsWithoutAnyKeyId: string[];
  tiers: Record<string, number>;
  banned: number;
  overrides: number;
}

/** Read-only census of the live db2 user state (also useful before importing). */
export async function censusRedisDb2(
  redis: RedisLike,
): Promise<Omit<ImportRedisReport, "imported">> {
  const uids = await redis.smembers(OVID_UIDS_SET);
  let android = 0;
  let web = 0;
  const missing: string[] = [];
  const tiers: Record<string, number> = {};
  let banned = 0;
  let overrides = 0;

  for (const uid of uids) {
    const [androidId, webId, tier, ban, daily, monthly, pools] = await Promise.all([
      redis.get(`user:${uid}:keyid`),
      redis.get(`user:${uid}:web:keyid`),
      redis.get(`user:${uid}:tier`),
      redis.get(`user:${uid}:banned`),
      redis.get(`user:${uid}:dailyUsd`),
      redis.get(`user:${uid}:monthlyCapUsd`),
      redis.get(`user:${uid}:pools`),
    ]);
    if (androidId !== null && androidId !== "") android++;
    if (webId !== null && webId !== "") web++;
    if ((androidId === null || androidId === "") && (webId === null || webId === "")) {
      missing.push(uid);
    }
    const tierId = tier !== null && tier !== "" ? tier : "free";
    tiers[tierId] = (tiers[tierId] ?? 0) + 1;
    if (ban !== null && ban !== "") banned++;
    if (daily !== null || monthly !== null || pools !== null) overrides++;
  }

  return {
    scannedUids: uids.length,
    uidsWithAndroidKey: android,
    uidsWithWebKey: web,
    uidsWithoutAnyKeyId: missing.sort(),
    tiers,
    banned,
    overrides,
  };
}

export async function importRedisDb2(deps: {
  db: DbHandle;
  redis: RedisLike;
  dryRun?: boolean;
}): Promise<ImportRedisReport> {
  const census = await censusRedisDb2(deps.redis);
  if (deps.dryRun === true) {
    return {
      imported: { users: 0, plans: false, settings: false },
      ...census,
    };
  }
  const projection = createProjection({ db: deps.db, redis: deps.redis });
  const { imported } = await projection.importFromRedisOnce();
  return { imported, ...census };
}

export function formatReport(report: ImportRedisReport): string[] {
  return [
    line("redis uids scanned", report.scannedUids),
    line("users inserted", report.imported.users),
    line("settings seeded", report.imported.settings),
    line("plans seeded", report.imported.plans),
    line("uids with android keyid", report.uidsWithAndroidKey),
    line("uids with web keyid", report.uidsWithWebKey),
    line("uids with no keyid at all", report.uidsWithoutAnyKeyId.length),
    line("banned flags", report.banned),
    line("plan overrides", report.overrides),
    line("tiers", JSON.stringify(report.tiers)),
    ...(report.uidsWithoutAnyKeyId.length > 0
      ? [`  uids without keyid: ${report.uidsWithoutAnyKeyId.join(", ")}`]
      : []),
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
    const report = await importRedisDb2({ db, redis, dryRun });
    console.log(`[importRedisDb2]${dryRun ? " DRY RUN" : ""}`);
    for (const row of formatReport(report)) console.log(row);
    if (report.uidsWithoutAnyKeyId.length > 0) {
      console.warn(
        "WARN uids without any keyid will be re-minted on their next /mint call; verify that is intended",
      );
    }
    if (!dryRun) ok("db2 → Postgres import complete (insert-if-absent)");
  } finally {
    redis.disconnect();
    await closeDb(db);
  }
}

if (isMain(import.meta.url)) {
  cli().catch((err) => {
    console.error(`[importRedisDb2] FAILED: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  });
}
