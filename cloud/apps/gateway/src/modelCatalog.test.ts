import { describe, expect, it } from "vitest";
import { createMintModelCatalog, MODEL_GROUPS_KEY } from "./keys.js";

function fakeRedis(values: Array<string | null | Error>) {
  const reads: string[] = [];
  let i = 0;
  return {
    reads,
    async get(key: string): Promise<string | null> {
      reads.push(key);
      const v = values[Math.min(i++, values.length - 1)]!;
      if (v instanceof Error) throw v;
      return v;
    },
  };
}

describe("createMintModelCatalog (Wave 1a)", () => {
  it("reads the mint's config:model_groups JSON list", async () => {
    const redis = fakeRedis(['["auto","glm-5.3"]']);
    const read = createMintModelCatalog(redis);
    expect(await read()).toEqual(["auto", "glm-5.3"]);
    expect(redis.reads).toEqual([MODEL_GROUPS_KEY]);
  });

  it("missing, corrupt, empty or failing reads are 'catalog unknown' (null)", async () => {
    for (const v of [null, "not json", "{}", "[]", new Error("down")]) {
      const read = createMintModelCatalog(fakeRedis([v]));
      expect(await read()).toBeNull();
    }
  });

  it("caches for the TTL", async () => {
    let t = 0;
    const redis = fakeRedis(['["a"]', '["b"]']);
    const read = createMintModelCatalog(redis, 1000, () => t);
    expect(await read()).toEqual(["a"]);
    t = 500;
    expect(await read()).toEqual(["a"]);
    t = 1500;
    expect(await read()).toEqual(["b"]);
  });
});
