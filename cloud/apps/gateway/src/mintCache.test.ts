import { describe, expect, it } from "vitest";
import { MintInternalError, type InternalMintProvisioner } from "@ovid/shared";
import {
  DEFAULT_MINT_ENSURE_CACHE_MS,
  mintEnsureCacheMsFromEnv,
  withEnsureKeyCache,
} from "./internalMint.js";

function counting(
  impl?: (uid: string, n: number) => Promise<{ key: string; tier: string; baseUrl: string }>,
): InternalMintProvisioner & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    async ensureKeyForUid(uid, opts) {
      calls.push(`${uid}:${opts?.platform ?? ""}`);
      if (impl !== undefined) return impl(uid, calls.length);
      return { key: `k-${uid}`, tier: "free", baseUrl: "http://llm" };
    },
  };
}

describe("withEnsureKeyCache", () => {
  it("serves repeat sends of a uid from cache inside the TTL", async () => {
    let t = 0;
    const inner = counting();
    const mint = withEnsureKeyCache(inner, { ttlMs: 1_000, now: () => t });
    await mint.ensureKeyForUid("a");
    t = 999;
    await expect(mint.ensureKeyForUid("a")).resolves.toEqual({
      key: "k-a",
      tier: "free",
      baseUrl: "http://llm",
    });
    expect(inner.calls).toEqual(["a:"]);
    t = 1_000;
    await mint.ensureKeyForUid("a");
    expect(inner.calls).toEqual(["a:", "a:"]);
  });

  it("keys the cache by platform and shares one in-flight call per uid", async () => {
    const inner = counting();
    const mint = withEnsureKeyCache(inner, { ttlMs: 60_000 });
    await Promise.all([
      mint.ensureKeyForUid("a"),
      mint.ensureKeyForUid("a"),
      mint.ensureKeyForUid("a", { platform: "web" }),
      mint.ensureKeyForUid("b"),
    ]);
    expect(inner.calls.sort()).toEqual(["a:", "a:web", "b:"]);
  });

  it("never caches a refusal (402/429 stays fresh on every send)", async () => {
    const inner = counting(async (uid, n) => {
      if (n === 1) throw new MintInternalError(402, { detail: "monthly free limit reached" }, {});
      return { key: `k-${uid}`, tier: "free", baseUrl: "" };
    });
    const mint = withEnsureKeyCache(inner, { ttlMs: 60_000 });
    await expect(mint.ensureKeyForUid("a")).rejects.toBeInstanceOf(MintInternalError);
    await expect(mint.ensureKeyForUid("a")).resolves.toMatchObject({ key: "k-a" });
    expect(inner.calls).toHaveLength(2);
  });

  it("bounds the cache (oldest evicted)", async () => {
    const inner = counting();
    const mint = withEnsureKeyCache(inner, { ttlMs: 60_000, maxEntries: 2 });
    await mint.ensureKeyForUid("a");
    await mint.ensureKeyForUid("b");
    await mint.ensureKeyForUid("c"); // evicts a
    await mint.ensureKeyForUid("b");
    await mint.ensureKeyForUid("a");
    expect(inner.calls).toEqual(["a:", "b:", "c:", "a:"]);
  });

  it("ttlMs 0 returns the inner provisioner unchanged", () => {
    const inner = counting();
    expect(withEnsureKeyCache(inner, { ttlMs: 0 })).toBe(inner);
  });
});

describe("mintEnsureCacheMsFromEnv", () => {
  it("defaults to 60 s and validates", () => {
    expect(DEFAULT_MINT_ENSURE_CACHE_MS).toBe(60_000);
    expect(mintEnsureCacheMsFromEnv({})).toBe(60_000);
    expect(mintEnsureCacheMsFromEnv({ OVID_MINT_ENSURE_CACHE_MS: "0" })).toBe(0);
    expect(() => mintEnsureCacheMsFromEnv({ OVID_MINT_ENSURE_CACHE_MS: "-1" })).toThrow(
      /OVID_MINT_ENSURE_CACHE_MS/,
    );
    expect(() => mintEnsureCacheMsFromEnv({ OVID_MINT_ENSURE_CACHE_MS: "999999" })).toThrow(
      /OVID_MINT_ENSURE_CACHE_MS/,
    );
  });
});
