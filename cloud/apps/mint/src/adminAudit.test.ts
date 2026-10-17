import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { AUDIT_FILE_NAME, AUDIT_LIST, audit } from "./adminAudit.js";
import {
  closeDb,
  closeRedis,
  openFlushedRedis,
  resetTestDb,
  TEST_DATABASE_URL,
  TEST_MINT_REDIS_URL,
} from "./test/env.js";

/**
 * adminAudit.ts — the append-only audit trail's three sinks (mint.py audit):
 * Postgres mint_audit (durable), the capped `audit:admin` Redis list (console)
 * and the never-trimmed admin-audit.jsonl on the mint volume. Every sink is
 * logged-not-thrown: one failing sink never blocks the others or the route.
 */

const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;

const FIXED_NOW = new Date("2026-10-17T12:34:56.000Z");

describe.skipIf(!RUN)("audit() (adminAudit.ts)", () => {
  let db: Db;
  let redis: Redis;
  let stateDir: string;
  /** audit()'s structural deps — the full MintDeps satisfies them. */
  let deps: { db: Db; redis: Redis; env: { auditMax: number; mintStateDir: string }; clock: () => Date };

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
    stateDir = mkdtempSync(join(tmpdir(), "mint-audit-"));
    deps = {
      db,
      redis,
      env: { auditMax: 5000, mintStateDir: stateDir },
      clock: () => FIXED_NOW,
    };
  }, 60_000);

  afterAll(async () => {
    await closeRedis(redis);
    await closeDb(db);
    rmSync(stateDir, { recursive: true, force: true });
  });

  function jsonlLines(): string[] {
    return readFileSync(join(stateDir, AUDIT_FILE_NAME), "utf8")
      .split("\n")
      .filter((l) => l !== "");
  }

  async function pgRows(action: string): Promise<Array<Record<string, unknown>>> {
    return (await db.$client`
      SELECT id, at, actor, action, target, before, after, ip
      FROM mint_audit WHERE action = ${action} ORDER BY at, id`) as Array<
      Record<string, unknown>
    >;
  }

  it("writes Postgres + the Redis list (newest first) + the JSONL file, sorted keys", async () => {
    await audit(deps, "settings", {
      target: "global",
      before: { free_daily_usd: 0.15 },
      after: { free_daily_usd: 3 },
      ip: "10.1.2.3",
    });
    await audit(deps, "ban", { target: { uid: "u1", ip: null } });
    await audit(deps, "reset-window", { target: "u1", after: { reset_month_free: false } });

    // Redis list: newest first, entries are the exact JSON lines
    expect(await redis.llen(AUDIT_LIST)).toBe(3);
    const rows = await redis.lrange(AUDIT_LIST, 0, -1);
    const actions = rows.map((r) => (JSON.parse(r) as { action: string }).action);
    expect(actions).toEqual(["reset-window", "ban", "settings"]);
    const first = JSON.parse(rows[0]!) as Record<string, unknown>;
    expect(first).toMatchObject({
      ts: "2026-10-17T12:34:56Z",
      action: "reset-window",
      actor: "master-key",
      ip: "unknown",
      target: "u1",
      after: { reset_month_free: false },
    });
    // Python json.dumps(entry, sort_keys=True): keys are alphabetical
    expect(rows[0]!.startsWith('{"action":')).toBe(true);

    // JSONL file: append-only, oldest first, one line per entry
    const lines = jsonlLines();
    expect(lines).toHaveLength(3);
    expect(lines.map((l) => (JSON.parse(l) as { action: string }).action)).toEqual([
      "settings",
      "ban",
      "reset-window",
    ]);

    // Postgres: durable rows with UUIDv7 ids and jsonb round-trip
    const pg = await pgRows("settings");
    expect(pg).toHaveLength(1);
    expect(pg[0]!.id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    expect(pg[0]!.actor).toBe("master-key");
    expect(pg[0]!.ip).toBe("10.1.2.3");
    expect(pg[0]!.target).toBe("global");
    expect(pg[0]!.before).toEqual({ free_daily_usd: 0.15 });
    expect(pg[0]!.after).toEqual({ free_daily_usd: 3 });
    expect(new Date(pg[0]!.at as string | Date).getTime()).toBe(FIXED_NOW.getTime());
  });

  it("caps the Redis list at AUDIT_MAX (5001 writes → LLEN 5000) but never trims Postgres or the file", async () => {
    const before = {
      pg: (await pgRows("cap-test")).length,
      file: jsonlLines().length,
    };
    for (let i = 1; i <= 5001; i++) {
      await audit(deps, "cap-test", { target: i });
    }
    expect(await redis.llen(AUDIT_LIST)).toBe(5000);
    // The list kept the NEWEST 5000 — entry 2 was trimmed, entries 3..5001 remain
    const newest = JSON.parse((await redis.lindex(AUDIT_LIST, 0))!) as { target: number };
    const oldest = JSON.parse((await redis.lindex(AUDIT_LIST, -1))!) as { target: number };
    expect(newest.target).toBe(5001);
    expect(oldest.target).toBe(2);

    // Postgres and the file keep ALL 5001 (append-only, never trimmed)
    expect((await pgRows("cap-test")).length - before.pg).toBe(5001);
    expect(jsonlLines().length - before.file).toBe(5001);
  }, 120_000);

  it("a failing sink is logged, never thrown (redis down / db down / missing state dir)", async () => {
    const brokenRedis = new Proxy(redis, {
      get(target, prop) {
        if (prop === "lpush" || prop === "ltrim") {
          return async () => {
            throw new Error("redis down");
          };
        }
        return Reflect.get(target, prop);
      },
    }) as Redis;

    const brokenDb = new Proxy(db, {
      get(target, prop) {
        if (prop === "insert") {
          // drizzle call shape: db.insert(table).values(...) rejects
          return () => ({
            values: async () => {
              throw new Error("db down");
            },
          });
        }
        return Reflect.get(target, prop);
      },
    }) as Db;

    const fileBefore = jsonlLines().length;

    // Redis down: Postgres + file still written, no throw
    await expect(
      audit({ ...deps, redis: brokenRedis }, "sink-redis", { target: "a" }),
    ).resolves.toBeUndefined();
    expect((await pgRows("sink-redis")).length).toBe(1);
    expect(jsonlLines().length - fileBefore).toBe(1);

    // Postgres down: Redis + file still written, no throw
    await expect(
      audit({ ...deps, db: brokenDb }, "sink-db", { target: "b" }),
    ).resolves.toBeUndefined();
    const listRows = await redis.lrange(AUDIT_LIST, 0, -1);
    expect(
      listRows.some((r) => (JSON.parse(r) as { action: string }).action === "sink-db"),
    ).toBe(true);
    expect(jsonlLines().length - fileBefore).toBe(2);

    // State dir missing (Python _state_path → None): silently no file, no throw
    await expect(
      audit(
        { ...deps, env: { auditMax: 5000, mintStateDir: join(stateDir, "nope") } },
        "sink-nodir",
        { target: "c" },
      ),
    ).resolves.toBeUndefined();
    expect((await pgRows("sink-nodir")).length).toBe(1);
    expect(jsonlLines().length - fileBefore).toBe(2);
  });
});
