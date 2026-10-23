import { billingUsers, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { planFor } from "@ovid/shared";

/**
 * Tier sink — the README's `set_user_tier` path.
 *
 * Postgres users.tier (+ tier_expires_at) is written FIRST (durable authority,
 * Ruling Q4), then the Redis projection (SET … EXAT expiry+600 / DEL both keys
 * on free), then `reapplyUser` so the LiteLLM key budgets follow the tier —
 * exactly the machinery /upgrade uses.
 *
 * The Redis key expiring on its own means a missed RTDN can never leave a
 * paid tier on forever.
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
  /** Kept in the contract so the sink owns the full projection dependency set. */
  redis: Redis;
  projection: PublishTier;
  reapplyUser(uid: string): Promise<unknown>;
}

export type TierSink = (
  uid: string,
  tier: string,
  expiresAt: number | null,
) => Promise<void>;

/**
 * Normalize to a plan id: an unknown tier is Free by absence, and a legacy
 * spelling (`3x` / `7x` / `15x`) is written back as the id it means, so the
 * stored string is always one the gateway resolves.
 */
function normalizeTier(tier: string): string {
  return planFor(tier).id;
}

export function createTierSink(deps: TierSinkDeps): TierSink {
  void deps.redis; // projection owns Redis; kept for dependency symmetry
  return async (uid, tier, expiresAt) => {
    const normalized = normalizeTier(tier);
    const durableExpiry = normalized === "free" ? null : (expiresAt ?? null);

    // 1. Durable copy first — a Redis failure must never lose the tier.
    await billingUsers.setTier(deps.db, uid, normalized, durableExpiry);
    // 2. Request-time projection (self-expiring keys).
    await deps.projection.publishUserTier(uid, normalized, durableExpiry);
    // 3. LiteLLM budgets follow the tier (same path as /upgrade).
    await deps.reapplyUser(uid);
  };
}
