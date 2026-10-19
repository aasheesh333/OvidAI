import type { Redis } from "ioredis";
import type { KeyProvider } from "@ovid/shared";

// Implementations of the @ovid/shared provisioning contracts (controller
// ruling: interfaces live in shared so the Task 9 worker imports them from
// there; implementations stay here in the gateway).
//
// P9 Task 9 removed `createHttpMintProvisioner` (client-token forwarding to
// the public mint). The gateway now calls mint's ADMIN listener through
// `createInternalMintProvisioner` (./internalMint.ts), signing its own
// verified uid. The Redis key READ remains: the worker's resolver and the
// gateway's tests share this one implementation.

/**
 * Reads the user's provisioned key from the mint service's Redis:
 * `GET user:{uid}:key`. The REDIS_MINT_URL already carries the db selector
 * (mint's db2), so the given connection does a plain GET.
 */
export function createMintRedisKeyProvider(redisMint: Redis): KeyProvider {
  return {
    getKeyForUser(uid) {
      return redisMint.get(`user:${uid}:key`);
    },
  };
}

/** The mint's published model-group list (ovid_plans MODEL_GROUPS_KEY). */
export const MODEL_GROUPS_KEY = "config:model_groups";

/**
 * Wave 1a (CH-007): the allowed model catalog for a send's `model` — the
 * LiteLLM model-group names the mint publishes as a JSON list at
 * `config:model_groups` in its db2 (the same redis the key read uses).
 * Every plan may use every catalog model (allowances are price-based), so
 * there is no per-plan filter. Cached for [ttlMs]; a missing/corrupt key or
 * a redis error answers null (catalog unknown → the route fails open).
 */
export function createMintModelCatalog(
  redisMint: Pick<Redis, "get">,
  ttlMs = 60_000,
  now: () => number = Date.now,
): () => Promise<readonly string[] | null> {
  let cached: { at: number; value: readonly string[] | null } | null = null;
  return async () => {
    if (cached !== null && now() - cached.at < ttlMs) return cached.value;
    let value: readonly string[] | null = null;
    try {
      const raw = await redisMint.get(MODEL_GROUPS_KEY);
      const parsed: unknown = raw === null ? null : JSON.parse(raw);
      if (Array.isArray(parsed)) {
        const names = parsed.filter((n): n is string => typeof n === "string" && n !== "");
        value = names.length > 0 ? names : null;
      }
    } catch {
      value = null;
    }
    cached = { at: now(), value };
    return value;
  };
}

/**
 * Thrown when a mint call exceeds its deadline. The messages route maps it to
 * a bounded 503 `unavailable` (never a hung request, never a misleading
 * key_not_minted).
 */
export class MintTimeoutError extends Error {
  readonly timeoutMs: number;

  constructor(timeoutMs: number, options?: { cause?: unknown }) {
    super(`mint call exceeded its ${timeoutMs} ms deadline`, options);
    this.name = "MintTimeoutError";
    this.timeoutMs = timeoutMs;
  }
}

/** P10 Task 2: default deadline for the gateway's internal-mint HTTP call. */
export const DEFAULT_MINT_TIMEOUT_MS = 10_000;
