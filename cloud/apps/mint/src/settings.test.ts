import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { plansRepo, users as usersRepo, type Db, type PlanRecord } from "@ovid/db";
import type { Redis } from "ioredis";
import { seedPlans } from "./planMath.js";
import { getOverride, getSettings, storeSettings, userFreeDaily } from "./settings.js";
import { closeDb, inertRedis, openDb, resetTestDb, testUid, TEST_DATABASE_URL } from "./test/env.js";

/**
 * Postgres = durable authority (Ruling Q4): plans-as-data rows + the
 * mint_settings singleton. Ports of test_new_install_seeds_24h_plans,
 * test_existing_install_keeps_live_values_and_30d_paid_windows and
 * test_startup_never_overwrites_settings, against real Postgres
 * (TEST_DATABASE_URL). The Redis publish half of storeSettings is
 * projection.test.ts's subject — an inert redis stands in here.
 */

describe.skipIf(!TEST_DATABASE_URL)("settings authority (Postgres)", () => {
  let db: Db;
  const redis: Redis = inertRedis();

  beforeAll(async () => {
    db = await resetTestDb();
  }, 60_000);

  afterAll(async () => {
    await closeDb(db);
  });

  it("seeds once on empty tables (24h windows on a fresh install)", async () => {
    const s = await getSettings({ db });
    expect(s.free_daily_usd).toBe(0.15);
    expect(s.plans).toEqual(seedPlans());
    expect(s.auto_oss_members.map((m) => m.model)).toEqual([
      "glm-5.3-flash", "deepseek-v4.1-flash", "minimax-m3",
    ]);
    // the seeds were WRITTEN to Postgres
    const rows = await plansRepo.list(db);
    expect(rows.map((r) => r.id)).toEqual(["free", "starter", "pro", "max"]);
    const record = await plansRepo.getSettings(db);
    expect(record?.baseDailyUsd).toBe("0.15");
    expect(record?.scalars.normal_rpm).toBe(240);
  });

  it("second getSettings never re-seeds over edited values", async () => {
    // the owner edits: renamed free plan + slow_rpm 7 + base 3 (Python
    // test_startup_never_overwrites_settings's custom Redis values)
    const custom: PlanRecord = {
      id: "free", name: "Gratis", priceUsd: "0", enabled: true, aliases: [],
      windowHours: 12, mult: "1", slowMode: false, autoOss: false, position: 0,
    };
    await plansRepo.upsert(db, custom);
    const record = (await plansRepo.getSettings(db))!;
    await plansRepo.saveSettings(db, {
      ...record,
      baseDailyUsd: "3",
      scalars: { ...record.scalars, slow_rpm: 7 },
    });

    const s = await getSettings({ db });
    expect(s.free_daily_usd).toBe(3);
    expect(s.slow_rpm).toBe(7);
    expect(s.plans).toHaveLength(4);
    expect(s.plans.find((p) => p.id === "free")).toMatchObject({ name: "Gratis", window_hours: 12 });
  });

  it("storeSettings round-trips through Postgres and survives a fresh process", async () => {
    const edited = await getSettings({ db });
    const stored = await storeSettings({ db, redis }, {
      ...edited,
      free_daily_usd: 3,
      slow_rpm: 5,
      auto_oss_members: [{ model: "minimax-m3", weight: 3 }, { model: "glm-5.3-flash", weight: 1 }],
    });
    expect(stored.slow_rpm).toBe(5);

    // a FRESH process (new connection, no caches) re-reads the same values
    const fresh = openDb();
    try {
      const re = await getSettings({ db: fresh });
      expect(re.free_daily_usd).toBe(3);
      expect(re.slow_rpm).toBe(5);
      expect(re.auto_oss_members).toEqual([
        { model: "minimax-m3", weight: 3 },
        { model: "glm-5.3-flash", weight: 1 },
      ]);
      expect(re.plans.find((p) => p.id === "free")?.name).toBe("Gratis");
    } finally {
      await closeDb(fresh);
    }
  });

  it("storeSettings validates first: invalid input throws and writes nothing", async () => {
    const before = await getSettings({ db });
    const bad = { ...before, slow_rpm: 0 };
    await expect(storeSettings({ db, redis }, bad)).rejects.toThrow("must be between 1 and 1000000");
    expect(await getSettings({ db })).toEqual(before);
  });

  it("storeSettings replaces the plan list wholesale (stale rows removed)", async () => {
    const s = await getSettings({ db });
    const kept = s.plans.filter((p) => p.id === "free" || p.id === "pro");
    const stored = await storeSettings({ db, redis }, { ...s, plans: kept });
    expect(stored.plans.map((p) => p.id)).toEqual(["free", "pro"]);
    const rows = await plansRepo.list(db);
    expect(rows.map((r) => r.id)).toEqual(["free", "pro"]);
    // and a reduced list round-trips
    expect((await getSettings({ db })).plans.map((p) => p.id)).toEqual(["free", "pro"]);
  });

  it("an existing install (users, no settings) seeds paid windows at 720h", async () => {
    await closeDb(db);
    db = await resetTestDb();
    await usersRepo.ensure(db, testUid("old"), null);
    const s = await getSettings({ db });
    expect(Object.fromEntries(s.plans.map((p) => [p.id, p.window_hours]))).toEqual({
      free: 24, starter: 720, pro: 720, max: 720,
    });
  });

  it("getOverride / userFreeDaily read the per-user override from Postgres", async () => {
    await closeDb(db);
    db = await resetTestDb();
    await getSettings({ db }); // seed
    const withOverride = testUid("u1");
    const without = testUid("u2");
    await usersRepo.ensure(db, withOverride, null);
    await usersRepo.ensure(db, without, null);
    await plansRepo.saveOverride(db, withOverride, {
      dailyUsd: "1",
      monthlyCapUsd: null,
      pools: { mult: 2, window_hours: 48, slow_mode: true, auto_oss: false },
    });

    expect(await getOverride({ db }, withOverride)).toEqual({
      mult: 2, window_hours: 48, slow_mode: true, auto_oss: false,
    });
    expect(await getOverride({ db }, without)).toBeNull();
    expect(await userFreeDaily({ db }, withOverride)).toBe(1);
    expect(await userFreeDaily({ db }, without)).toBe(0.15);

    // clearing the override returns to the global allowance
    await plansRepo.saveOverride(db, withOverride, null);
    expect(await getOverride({ db }, withOverride)).toBeNull();
    expect(await userFreeDaily({ db }, withOverride)).toBe(0.15);
  });
});
