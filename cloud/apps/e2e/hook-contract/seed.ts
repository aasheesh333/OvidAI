/**
 * P9 Task 17 - the TypeScript half of the real-Python hook contract.
 *
 * This module writes the SAME Redis db2 projection mint ships in production
 * (Postgres authority -> `createProjection` / `storeSettings`) and hands the
 * resulting uid map to `test_hook_contract.py`, which then runs the
 * UNMODIFIED `server/mint/litellm_hook/ovid_pools.py` against it. Nothing here
 * imports or emulates the Python hook.
 *
 * It is imported by `src/money.test.ts` (Vitest transpiles it), so no `tsx`
 * dev dependency or extra build step is needed. The exported `seed`/`cleanup`
 * pair keeps the harness idempotent and, critically, never FLUSHDBs a Redis
 * database another lane may share: only this run's uids and the three config
 * keys it overwrites are touched, and the prior config values are restored.
 */
import type { Redis } from "ioredis";
import type { Db } from "@ovid/db";
import {
  createProjection,
  storeSettings,
  type PlanData,
  type Settings,
} from "@ovid/mint";

export const HOOK_CONTRACT_BASE_DAILY = 1.0;
export const HOOK_CONTRACT_WINDOW_HOURS = 24;
export const HOOK_CONTRACT_GROUPS = [
  "auto",
  "glm-5.3-flash",
  "deepseek-v4.1-flash",
  "minimax-m3",
  "ovid-image",
];

export const HOOK_CONTRACT_MEMBERS: Settings["auto_oss_members"] = [
  { model: "glm-5.3-flash", weight: 1 },
  { model: "deepseek-v4.1-flash", weight: 1 },
  { model: "minimax-m3", weight: 1 },
];

/** Must stay field-for-field identical to SCALAR_VALUES/PLANS in the pytest file. */
export const HOOK_CONTRACT_SETTINGS: Settings = {
  free_daily_usd: HOOK_CONTRACT_BASE_DAILY,
  free_monthly_cap_usd: 12.5,
  est_input_tokens: 1234,
  est_output_tokens: 600,
  est_image_tokens: 1500,
  slow_rpm: 7,
  slow_tpm: 200_000,
  slow_parallel: 2,
  normal_rpm: 111,
  normal_tpm: 4_000_000,
  normal_parallel: 16,
  hard_ceiling_mult: 2.5,
  auto_oss_members: HOOK_CONTRACT_MEMBERS,
  plans: [
    {
      id: "free",
      name: "Free",
      price_usd: 0,
      enabled: true,
      aliases: [],
      window_hours: HOOK_CONTRACT_WINDOW_HOURS,
      mult: 1,
      slow_mode: false,
      auto_oss: false,
    },
    {
      id: "starter",
      name: "Starter",
      price_usd: 5,
      enabled: true,
      aliases: ["3x"],
      window_hours: HOOK_CONTRACT_WINDOW_HOURS,
      mult: 1.5,
      slow_mode: true,
      auto_oss: false,
    },
    {
      id: "pro",
      name: "Pro",
      price_usd: 25,
      enabled: true,
      aliases: ["7x"],
      window_hours: HOOK_CONTRACT_WINDOW_HOURS,
      mult: 5,
      slow_mode: false,
      auto_oss: true,
    },
  ] satisfies PlanData[],
};

export interface HookContractUids {
  freeUid: string;
  slowUid: string;
  autoUid: string;
  accUid: string;
  autoAccUid: string;
}

export interface HookContractSeed {
  uids: HookContractUids;
  priorConfig: {
    limits: Record<string, string>;
    base: string | null;
    groups: string | null;
  };
}

function unique(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

/** Every Redis key this harness owns for one uid. */
function uidKeys(uid: string): string[] {
  return [
    `user:${uid}:tier`,
    `user:${uid}:tier_expires_at`,
    `user:${uid}:dailyUsd`,
    `user:${uid}:monthlyCapUsd`,
    `user:${uid}:pools`,
    `user:${uid}:banned`,
    `user:${uid}:email`,
    `user:${uid}:keyid`,
    `user:${uid}:key`,
    `user:${uid}:web:keyid`,
    `user:${uid}:web:key`,
    `pool:${uid}:start`,
    `pool:${uid}:spend`,
    `pool:${uid}:auto`,
    `usagecache:${uid}`,
    `mintlock:${uid}`,
    `mintlock:web:${uid}`,
    `freecap:${uid}:1970-01`,
  ];
}

/**
 * Write settings + tiers + model groups through the production projection.
 * Returns the uid map (JSON-serializable) and the prior config snapshot.
 */
export async function seedHookContract(
  redis: Redis,
  db: Db,
): Promise<HookContractSeed> {
  const uids: HookContractUids = {
    freeUid: unique("t17-free"),
    slowUid: unique("t17-slow"),
    autoUid: unique("t17-auto"),
    accUid: unique("t17-acc"),
    autoAccUid: unique("t17-autoacc"),
  };

  const priorConfig = {
    limits: await redis.hgetall("config:limits"),
    base: await redis.get("config:base_daily_usd"),
    groups: await redis.get("config:model_groups"),
  };

  // Own keys only (idempotent re-runs); no FLUSHDB.
  for (const uid of Object.values(uids)) {
    await redis.del(...uidKeys(uid));
  }

  // The projection's hset does not remove stale fields; clear the two config
  // keys first so the shape-drift canary sees exactly what TS wrote.
  await redis.del("config:limits", "config:base_daily_usd");

  // Postgres authority -> db2 projection (plans + config:limits/base).
  await storeSettings({ db, redis }, HOOK_CONTRACT_SETTINGS);
  const projection = createProjection({ db, redis });
  await projection.publishSettings();

  // Tier projection: "3x"/"7x" are the billing aliases the app expects.
  await projection.publishUserTier(uids.freeUid, null, null);
  await projection.publishUserTier(uids.accUid, null, null);
  await projection.publishUserTier(uids.autoAccUid, null, null);
  await projection.publishUserTier(uids.slowUid, "3x", null);
  await projection.publishUserTier(uids.autoUid, "7x", null);

  // The hook's hidden-auto known-set, published by mint from /model/info.
  await projection.publishModelGroups(HOOK_CONTRACT_GROUPS);

  return { uids, priorConfig };
}

/** Restore the shared config keys and delete this run's user/pool state. */
export async function cleanupHookContract(
  redis: Redis,
  seed: HookContractSeed,
): Promise<void> {
  const { uids, priorConfig } = seed;
  for (const uid of Object.values(uids)) {
    await redis.del(...uidKeys(uid));
    await redis.srem("ovid:uids", uid);
    await redis.hdel("pools:slow", uid);
    await redis.srem("pools:slow_pending", uid);
  }

  await redis.del("config:limits");
  if (Object.keys(priorConfig.limits).length > 0) {
    await redis.hset("config:limits", priorConfig.limits);
  }
  if (priorConfig.base === null) {
    await redis.del("config:base_daily_usd");
  } else {
    await redis.set("config:base_daily_usd", priorConfig.base);
  }
  if (priorConfig.groups === null) {
    await redis.del("config:model_groups");
  } else {
    await redis.set("config:model_groups", priorConfig.groups);
  }
}
