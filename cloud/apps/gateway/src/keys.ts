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
