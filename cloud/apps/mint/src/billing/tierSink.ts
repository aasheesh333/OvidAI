import { billingUsers, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { planFor } from "@ovid/shared";
import {
  BILLING_REFRESH_GENERATION_KEY,
  withBillingAccountLock,
  withBillingAccountWrite,
  withBillingProjectionGeneration,
} from "../windows.js";

/**
 * Tier sink — Postgres users.tier, the request-time Redis tier, then LiteLLM.
 * Billing refreshes additionally carry a generation so a superseded writer
 * cannot expose stale paid state even before a later repair runs.
 */
export const TIER_SKEW_SECONDS = 600;

export interface PublishTier {
  publishUserTier(
    uid: string,
    tier: string | null,
    expiresAtEpoch: number | null,
  ): Promise<void>;
}

export interface TierSinkDeps {
  db: Db;
  redis: Redis;
  projection: PublishTier;
  reapplyUser(uid: string): Promise<unknown>;
}

export type TierSink = (
  uid: string,
  tier: string,
  expiresAt: number | null,
  generation?: number,
) => Promise<void>;

export class StaleTierProjectionError extends Error {
  constructor() {
    super("stale billing projection generation");
    this.name = "StaleTierProjectionError";
  }
}

export class TierProjectionError extends Error {
  constructor(message = "billing projection failed") {
    super(message);
    this.name = "TierProjectionError";
  }
}

/** Atomically reserve the newest Redis generation; older writers lose immediately. */
export async function reserveBillingProjectionGeneration(
  redis: Redis,
  uid: string,
  generation: number,
): Promise<boolean> {
  const key = BILLING_REFRESH_GENERATION_KEY(uid);
  if (typeof redis.eval === "function") {
    const result = await redis.eval(
      `local current = tonumber(redis.call('GET', KEYS[1]) or '0')
       if tonumber(ARGV[1]) < current then return 0 end
       redis.call('SET', KEYS[1], ARGV[1])
       return 1`,
      1,
      key,
      String(generation),
    );
    return Number(result) === 1;
  }
  // Lightweight test doubles do not implement Lua; production always takes the atomic path above.
  const current = Number((await redis.get?.(key)) ?? 0);
  if (generation < current) return false;
  await redis.set(key, String(generation));
  return true;
}

function normalizeTier(tier: string): string {
  return planFor(tier).id;
}

async function publishVersionedTier(
  redis: Redis,
  uid: string,
  tier: string,
  expiresAt: number | null,
  generation: number,
): Promise<boolean> {
  const exat = expiresAt === null ? "" : String(Math.floor(expiresAt) + TIER_SKEW_SECONDS);
  const result = await redis.eval(
    `if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
     if ARGV[2] == 'free' then
       redis.call('DEL', KEYS[2], KEYS[3])
       return 1
     end
     if ARGV[3] ~= '' then
       redis.call('SET', KEYS[2], ARGV[2], 'EXAT', ARGV[3])
       redis.call('SET', KEYS[3], ARGV[4], 'EXAT', ARGV[3])
     else
       redis.call('SET', KEYS[2], ARGV[2])
       redis.call('DEL', KEYS[3])
     end
     return 1`,
    3,
    BILLING_REFRESH_GENERATION_KEY(uid),
    `user:${uid}:tier`,
    `user:${uid}:tier_expires_at`,
    String(generation),
    tier,
    exat,
    expiresAt === null ? "" : String(Math.floor(expiresAt)),
  );
  return Number(result) === 1;
}

function assertReapplied(result: unknown): void {
  if (typeof result === "object" && result !== null && "errors" in result) {
    const errors = (result as { errors?: unknown }).errors;
    if (typeof errors === "number" && errors > 0) {
      throw new TierProjectionError("LiteLLM projection failed");
    }
  }
}

export function createTierSink(deps: TierSinkDeps): TierSink {
  return async (uid, tier, expiresAt, generation) => {
    const normalized = normalizeTier(tier);
    const durableExpiry = normalized === "free" ? null : (expiresAt ?? null);

    if (generation === undefined) {
      await withBillingAccountWrite(deps, uid, async () => {
        await billingUsers.setTier(deps.db, uid, normalized, durableExpiry);
        await deps.projection.publishUserTier(uid, normalized, durableExpiry);
        assertReapplied(await deps.reapplyUser(uid));
      });
      return;
    }

    await withBillingProjectionGeneration(generation, () =>
      withBillingAccountLock(deps.db, uid, async () => {
        if (!(await reserveBillingProjectionGeneration(deps.redis, uid, generation))) {
          throw new StaleTierProjectionError();
        }
        if (!(await billingUsers.setTierForRefresh(
          deps.db,
          uid,
          normalized,
          durableExpiry,
          generation,
        ))) {
          throw new StaleTierProjectionError();
        }
        if (!(await publishVersionedTier(deps.redis, uid, normalized, durableExpiry, generation))) {
          throw new StaleTierProjectionError();
        }
        assertReapplied(await deps.reapplyUser(uid));
      }),
    );
  };
}
