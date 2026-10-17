import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { Db } from "@ovid/db";
import type { Redis } from "ioredis";
import type { MintDeps } from "./app.js";
import {
  spendMonitorOnce,
  startMintBackgroundLoops,
  sweeperOnce,
} from "./background.js";
import { createAlerter } from "./alerts.js";
import { loadMintEnv } from "./env.js";
import { createLiteLlmAdmin, type LiteLlmAdmin } from "./litellmAdmin.js";
import { DB2 } from "./planMath.js";
import { getSettings } from "./settings.js";
import { inSlowMode, rateLimits, sweepSlowMode, syncSlowMode } from "./slowMode.js";
import {
  closeDb,
  closeRedis,
  openFlushedRedis,
  resetTestDb,
  testUid,
  TEST_DATABASE_URL,
  TEST_MINT_REDIS_URL,
} from "./test/env.js";
import { FakeLiteLlm, MASTER_KEY, standardModels } from "./test/litellmFake.js";

/**
 * Slow-mode handshake + background loops. Ports of mint.py's
 * in_slow_mode/rate_limits/sync_slow_mode/sweep_slow_mode and the
 * _sweeper/_spend_monitor daemon threads.
 *
 * T5 owns the pool helpers; slowMode.ts only re-exports them under the
 * brief's names — the tests below pin that delegation (the same
 * pools:slow / /key/update wire effects) and the sweeper, which is T7's.
 */

const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;

const FIXED_NOW = new Date("2026-10-17T12:34:56.000Z");
const FIXED_UNTIL = new Date("2026-10-17T13:00:00.000Z");

describe.skipIf(!RUN)("slow mode + background loops", () => {
  let db: Db;
  let redis: Redis;
  let fake: FakeLiteLlm;
  let env: ReturnType<typeof loadMintEnv>;
  let deps: MintDeps;
  let logSpy: ReturnType<typeof vi.spyOn>;

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
    fake = new FakeLiteLlm();
    await fake.start();
    env = loadMintEnv({
      NODE_ENV: "test",
      DATABASE_URL: TEST_DATABASE_URL!,
      REDIS_DB2_URL: TEST_MINT_REDIS_URL!,
      LITELLM_BASE: fake.baseUrl,
      LITELLM_MASTER_KEY: MASTER_KEY,
      OVID_ADMIN_MASTER_KEY: "sk-admin-test",
      OVID_INTERNAL_API_SECRET: "sk-internal-test",
      FIREBASE_PROJECT_ID: "ovid-test",
      APPCHECK_ENABLED: "false",
      MINT_SWEEP_S: "30",
    });
    deps = {
      db,
      redis,
      litellm: createLiteLlmAdmin(fake.baseUrl, MASTER_KEY),
      env,
      alerter: createAlerter(redis, env),
      verifyIdentity: async () => ({ uid: "unused", email: null, platform: "android" }),
      clock: () => new Date(FIXED_NOW.getTime()),
    };
    await getSettings({ db });
    standardModels(fake);
  }, 60_000);

  afterAll(async () => {
    await fake.stop();
    await closeRedis(redis);
    await closeDb(db);
  });

  afterEach(() => {
    logSpy?.mockRestore();
    fake.calls.length = 0;
  });

  async function userWithKeys(uid: string): Promise<{ android: string; web: string }> {
    const android = `tok-${uid}-a`;
    const web = `tok-${uid}-w`;
    fake.addKey(android);
    fake.addKey(web);
    await redis.set(`user:${uid}:keyid`, android);
    await redis.set(`user:${uid}:web:keyid`, web);
    return { android, web };
  }

  it("syncSlowMode on HSETs the .3f epoch and pushes slow limits to BOTH keys", async () => {
    const uid = testUid("slow-on");
    const { android, web } = await userWithKeys(uid);

    const changed = await syncSlowMode(deps, uid, true, FIXED_UNTIL);
    expect(changed).toBe(true);
    expect(await redis.hget(DB2.SLOW_HASH, uid)).toBe(
      (FIXED_UNTIL.getTime() / 1000).toFixed(3),
    );

    const bodies = fake.posts("/key/update");
    expect(bodies).toHaveLength(2);
    expect(new Set(bodies.map((b) => b.key))).toEqual(new Set([android, web]));
    for (const body of bodies) {
      expect(body.rpm_limit).toBe(20); // slow_rpm seed
      expect(body.tpm_limit).toBe(200_000); // slow_tpm seed
      expect(body.max_parallel_requests).toBe(2); // slow_parallel seed
    }

    // No state change → no second push.
    fake.calls.length = 0;
    expect(await syncSlowMode(deps, uid, true, FIXED_UNTIL)).toBe(false);
    expect(fake.posts("/key/update")).toHaveLength(0);
  });

  it("inSlowMode/rateLimits delegate to the T5 pool helpers", async () => {
    const uid = testUid("slow-read");
    await userWithKeys(uid);
    expect(await inSlowMode(deps, uid)).toBe(false);
    expect(await rateLimits(deps, uid)).toEqual({
      rpm_limit: 240,
      tpm_limit: 4_000_000,
      max_parallel_requests: 16,
    });
    await syncSlowMode(deps, uid, true, FIXED_UNTIL);
    expect(await inSlowMode(deps, uid)).toBe(true);
    expect(await rateLimits(deps, uid)).toEqual({
      rpm_limit: 20,
      tpm_limit: 200_000,
      max_parallel_requests: 2,
    });
  });

  it("sweepSlowMode drains pools:slow_pending through computeUsage", async () => {
    const uid = testUid("slow-pending");
    await userWithKeys(uid);
    await redis.sadd(DB2.SLOW_PENDING, uid);

    const res = await sweepSlowMode(deps);
    expect(res.checked).toBe(1);
    expect(await redis.sismember(DB2.SLOW_PENDING, uid)).toBe(0);
  });

  it("sweepSlowMode lifts an expired entry and pushes normal limits", async () => {
    const uid = testUid("slow-lift");
    const { android, web } = await userWithKeys(uid);
    const past = ((FIXED_NOW.getTime() - 60_000) / 1000).toFixed(3);
    await redis.hset(DB2.SLOW_HASH, uid, past);

    const res = await sweepSlowMode(deps);
    expect(res.lifted).toBe(1);
    expect(await redis.hget(DB2.SLOW_HASH, uid)).toBeNull();

    const bodies = fake.posts("/key/update");
    expect(new Set(bodies.map((b) => b.key))).toEqual(new Set([android, web]));
    for (const body of bodies) {
      expect(body.rpm_limit).toBe(240);
      expect(body.tpm_limit).toBe(4_000_000);
      expect(body.max_parallel_requests).toBe(16);
    }
  });

  it("spend monitor sets the day base once and alerts at the threshold once per day bucket", async () => {
    logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    let total = 100;
    const spendDeps: MintDeps = {
      ...deps,
      litellm: {
        ...deps.litellm,
        globalSpend: async () => total,
      } as LiteLlmAdmin,
    };

    await spendMonitorOnce(spendDeps); // first call of the day: base = total, today = 0
    expect(await redis.get("spend:daybase:20261017")).toBe("100.0");
    expect(await redis.ttl("spend:daybase:20261017")).toBeGreaterThan(3 * 86400 - 60);
    expect(alertLines("daily_spend")).toHaveLength(0);

    total = 125.5; // +25.50 today, over the $20 default
    await spendMonitorOnce(spendDeps);
    expect(await redis.get("spend:daybase:20261017")).toBe("100.0"); // SETNX kept the base
    expect(alertLines("daily_spend")).toHaveLength(1);
    expect(alertLines("daily_spend")[0]).toContain("Spend today $25.50 >= $20.00");

    total = 126;
    await spendMonitorOnce(spendDeps);
    expect(alertLines("daily_spend")).toHaveLength(1); // 86400 s bucket dedupes
  });

  it("spend monitor swallows a globalSpend failure (non-2xx throws in the wrapper)", async () => {
    logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const spendDeps: MintDeps = {
      ...deps,
      litellm: {
        ...deps.litellm,
        globalSpend: async () => {
          throw new Error("global/spend 500");
        },
      } as LiteLlmAdmin,
    };
    await expect(spendMonitorOnce(spendDeps)).resolves.toBeUndefined();
    expect(logSpy.mock.calls.some((args) => String(args[0]).includes("spend monitor"))).toBe(true);
  });

  it("sweeperOnce runs the sweep + catalog refresh without throwing", async () => {
    const uid = testUid("sweep-once");
    await userWithKeys(uid);
    const past = ((FIXED_NOW.getTime() - 60_000) / 1000).toFixed(3);
    await redis.hset(DB2.SLOW_HASH, uid, past);
    await expect(sweeperOnce(deps)).resolves.toBeUndefined();
    expect(await redis.hget(DB2.SLOW_HASH, uid)).toBeNull();
    expect(await redis.get(DB2.MODEL_GROUPS_KEY)).not.toBeNull();
  });

  it("startMintBackgroundLoops ticks immediately and stop() is clean + idempotent", async () => {
    const ticks: string[] = [];
    const loopDeps: MintDeps = {
      ...deps,
      litellm: {
        ...deps.litellm,
        globalSpend: async () => {
          ticks.push("spend");
          return 0;
        },
      } as LiteLlmAdmin,
    };
    const handle = startMintBackgroundLoops(loopDeps);
    // Python's daemon threads run the body first, then sleep.
    await new Promise((resolve) => setTimeout(resolve, 25));
    await handle.stop();
    await expect(handle.stop()).resolves.toBeUndefined();
    expect(ticks).toContain("spend");
  });

  function alertLines(kind: string): string[] {
    return logSpy.mock.calls
      .map((args) => String(args[0] ?? ""))
      .filter((line) => line.includes(`ALERT ${kind}:`));
  }
});
