import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Redis } from "ioredis";
import { createMintRedisKeyProvider } from "./keys.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

/**
 * P9 Task 9 removed the pre-P9 `createHttpMintProvisioner` (client-token
 * forwarding). Its replacement — `createInternalMintProvisioner` — is
 * covered by internalMint.test.ts; this file keeps the Redis key-read
 * contract that the worker resolver and gateway tests share.
 */

describe.skipIf(!TEST_REDIS_URL)("createMintRedisKeyProvider (real redis)", () => {
  let redis: Redis;
  const written: string[] = [];

  beforeAll(() => {
    // The provider does a plain GET — REDIS_MINT_URL carries the db selector
    // in production; against the dev redis we simply use db0 and clean up.
    redis = new Redis(TEST_REDIS_URL!);
  });

  afterAll(async () => {
    if (written.length > 0) await redis.del(written);
    redis.disconnect();
  });

  it("reads GET user:{uid}:key and returns null for missing users", async () => {
    const provider = createMintRedisKeyProvider(redis);
    const uid = `mint-key-test-${Date.now()}`;
    const key = `user:${uid}:key`;
    written.push(key);
    await redis.set(key, "sk-live-1");

    await expect(provider.getKeyForUser(uid)).resolves.toBe("sk-live-1");
    await expect(provider.getKeyForUser(`missing-${Date.now()}`)).resolves.toBeNull();
  });
});
