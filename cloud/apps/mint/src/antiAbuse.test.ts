import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { Db } from "@ovid/db";
import type { Redis } from "ioredis";
import type { MintDeps } from "./app.js";
import { HttpContractError } from "./app.js";
import { createAlerter } from "./alerts.js";
import {
  checkNewKeyBreaker,
  clientIp,
  enforceIpSignupQuota,
  enforceMintRateLimit,
  isBanned,
  recordStrike,
  setKeyBlocked,
} from "./antiAbuse.js";
import { loadMintEnv } from "./env.js";
import type { LiteLlmAdmin } from "./litellmAdmin.js";
import {
  closeRedis,
  openFlushedRedis,
  testUid,
  TEST_MINT_REDIS_URL,
} from "./test/env.js";

/**
 * Ports of mint.py's anti-abuse block (mint.py:790-864) plus the Review Focus
 * #4 fix: an AUTO-ban must block the LiteLLM keys, not merely set the Redis
 * flag the way the Python defect did.
 *
 * Real Redis db9; LiteLLM is a recording spy (no network). Time is pinned
 * through deps.clock so the window bucket keys are deterministic.
 */

const RUN = TEST_MINT_REDIS_URL !== undefined;

const FIXED_NOW = new Date("2026-10-17T12:34:56.000Z");

describe.skipIf(!RUN)("anti-abuse (antiAbuse.ts)", () => {
  let redis: Redis;
  let env: ReturnType<typeof loadMintEnv>;
  let blockCalls: { op: "block" | "unblock"; key: string }[];
  let litellm: LiteLlmAdmin;
  let deps: MintDeps;
  let logSpy: ReturnType<typeof vi.spyOn>;

  beforeAll(async () => {
    redis = await openFlushedRedis();
    env = loadMintEnv({
      NODE_ENV: "test",
      DATABASE_URL: "postgres://u:p@localhost:5432/test",
      REDIS_DB2_URL: TEST_MINT_REDIS_URL!,
      LITELLM_MASTER_KEY: "sk-litellm-test",
      OVID_ADMIN_MASTER_KEY: "sk-admin-test",
      OVID_INTERNAL_API_SECRET: "sk-internal-test",
      FIREBASE_PROJECT_ID: "ovid-test",
      APPCHECK_ENABLED: "false",
    });
    blockCalls = [];
    litellm = {
      keyBlock: async (key: string) => {
        blockCalls.push({ op: "block", key });
        return 200;
      },
      keyUnblock: async (key: string) => {
        blockCalls.push({ op: "unblock", key });
        return 200;
      },
    } as unknown as LiteLlmAdmin;
    deps = {
      db: {} as unknown as Db,
      redis,
      litellm,
      env,
      alerter: createAlerter(redis, env),
      verifyIdentity: async () => ({ uid: "unused", email: null, platform: "android" }),
      clock: () => new Date(FIXED_NOW.getTime()),
    };
  }, 60_000);

  afterAll(async () => {
    await closeRedis(redis);
  });

  afterEach(() => {
    logSpy?.mockRestore();
    blockCalls.length = 0;
  });

  function alertLines(kind: string): string[] {
    return logSpy.mock.calls
      .map((args) => String(args[0] ?? ""))
      .filter((line) => line.includes(`ALERT ${kind}:`));
  }

  async function userWithKeys(uid: string): Promise<{ android: string; web: string }> {
    const android = `tok-${uid}-a`;
    const web = `tok-${uid}-w`;
    await redis.set(`user:${uid}:keyid`, android);
    await redis.set(`user:${uid}:web:keyid`, web);
    return { android, web };
  }

  it("clientIp takes the first XFF hop, else x-real-ip, else unknown", () => {
    expect(clientIp("203.0.113.9, 10.0.0.1", "10.0.0.2")).toBe("203.0.113.9");
    expect(clientIp(" 203.0.113.9 ,10.0.0.1", "")).toBe("203.0.113.9");
    expect(clientIp("", " 198.51.100.7 ")).toBe("198.51.100.7");
    expect(clientIp("", "")).toBe("unknown");
  });

  it("isBanned reads the uid flag and the IP ban, but never the unknown IP", async () => {
    const uid = testUid("ban-read");
    expect(await isBanned(deps, uid, "198.51.100.1")).toBe(false);

    await redis.set(`ban:ip:198.51.100.1`, "admin");
    expect(await isBanned(deps, uid, "198.51.100.1")).toBe(true);
    expect(await isBanned(deps, uid, "unknown")).toBe(false);

    await redis.set(`user:${uid}:banned`, "auto");
    expect(await isBanned(deps, uid, "unknown")).toBe(true);
  });

  it("strike limit−1 does not ban and touches no LiteLLM key; strike #limit bans, blocks BOTH keys, alerts once", async () => {
    logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const uid = testUid("strike");
    const ip = "203.0.113.10";
    const { android, web } = await userWithKeys(uid);
    const limit = env.abuse.abuseStrikeLimit;

    for (let i = 1; i < limit; i += 1) {
      await recordStrike(deps, uid, ip);
    }
    expect(await redis.get(`user:${uid}:banned`)).toBeNull();
    expect(blockCalls).toHaveLength(0);
    expect(alertLines("auto_ban")).toHaveLength(0);

    // Strike #limit → banned "auto" + /key/block for android AND web.
    await recordStrike(deps, uid, ip);
    expect(await redis.get(`user:${uid}:banned`)).toBe("auto");
    expect(blockCalls.filter((c) => c.op === "block").map((c) => c.key).sort()).toEqual(
      [android, web].sort(),
    );
    expect(alertLines("auto_ban")).toHaveLength(1);

    // Another strike inside the same 600 s alert bucket: ban re-asserted and
    // keys re-blocked (idempotent), but the operator is NOT alerted twice.
    await recordStrike(deps, uid, ip);
    expect(await redis.get(`user:${uid}:banned`)).toBe("auto");
    expect(blockCalls.filter((c) => c.op === "block")).toHaveLength(4);
    expect(alertLines("auto_ban")).toHaveLength(1);

    // The advisory IP counter is TTL'd, never a ban by itself.
    expect(await redis.get(`ban:ip:${ip}`)).toBeNull();
    expect(await redis.ttl(`abuse:ip:${ip}`)).toBeGreaterThan(0);
  });

  it("setKeyBlocked(false) unblocks every namespace keyid", async () => {
    const uid = testUid("unblock");
    const { android, web } = await userWithKeys(uid);
    await setKeyBlocked(deps, uid, false);
    expect(blockCalls.map((c) => c.op)).toEqual(["unblock", "unblock"]);
    expect(blockCalls.map((c) => c.key).sort()).toEqual([android, web].sort());
  });

  it("returning user on ipacct is never throttled (even with a hot velocity counter)", async () => {
    const uid = testUid("returning");
    const ip = "203.0.113.11";
    await redis.sadd(`ipacct:${ip}`, uid);
    const win = Math.floor(Math.floor(FIXED_NOW.getTime() / 1000) / env.abuse.signupVelocityWindowS);
    const velKey = `ipnew:${ip}:${win}`;
    await redis.set(velKey, "9999");

    await expect(enforceIpSignupQuota(deps, uid, ip)).resolves.toBeUndefined();
    expect(await redis.get(velKey)).toBe("9999"); // untouched
  });

  it("13th new signup in the window → 429 exact detail, and the IP is NOT banned", async () => {
    const ip = "203.0.113.12";
    const limit = env.abuse.newAccountsPerIpPerWindow;
    for (let i = 0; i < limit; i += 1) {
      await enforceIpSignupQuota(deps, testUid(`signup-${i}`), ip);
    }
    let thrown: unknown;
    try {
      await enforceIpSignupQuota(deps, testUid("signup-over"), ip);
    } catch (err) {
      thrown = err;
    }
    expect(thrown).toBeInstanceOf(HttpContractError);
    expect((thrown as HttpContractError).status).toBe(429);
    expect((thrown as HttpContractError).detail).toBe(
      "sign-ups from this network are busy right now — please retry in a few minutes",
    );
    expect(await redis.get(`ban:ip:${ip}`)).toBeNull();
  });

  it("41st mint call in the hour → 429 exact detail", async () => {
    const ip = "203.0.113.13";
    const limit = env.abuse.mintCallsPerIp;
    for (let i = 0; i < limit; i += 1) {
      await enforceMintRateLimit(deps, ip);
    }
    let thrown: unknown;
    try {
      await enforceMintRateLimit(deps, ip);
    } catch (err) {
      thrown = err;
    }
    expect(thrown).toBeInstanceOf(HttpContractError);
    expect((thrown as HttpContractError).status).toBe(429);
    expect((thrown as HttpContractError).detail).toBe(
      "too many requests from this network — retry later",
    );
  });

  it("the unknown IP is exempt from the mint-call throttle", async () => {
    for (let i = 0; i < 100; i += 1) {
      await expect(enforceMintRateLimit(deps, "unknown")).resolves.toBeUndefined();
    }
  });

  it("501st new key → 503 exact detail + alert:newkey_spike set", async () => {
    logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const limit = env.abuse.globalNewkeysPerWindow;
    for (let i = 0; i < limit; i += 1) {
      await checkNewKeyBreaker(deps);
    }
    let thrown: unknown;
    try {
      await checkNewKeyBreaker(deps);
    } catch (err) {
      thrown = err;
    }
    expect(thrown).toBeInstanceOf(HttpContractError);
    expect((thrown as HttpContractError).status).toBe(503);
    expect((thrown as HttpContractError).detail).toBe(
      "sign-ups are temporarily paused — please try again shortly",
    );
    expect(await redis.get("alert:newkey_spike")).toBe(String(limit + 1));
    expect(await redis.ttl("alert:newkey_spike")).toBeGreaterThan(0);
    expect(alertLines("newkey_spike")).toHaveLength(1);
  });
});
