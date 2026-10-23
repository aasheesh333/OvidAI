import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import postgres from "postgres";
import { migrate } from "./client.js";

/**
 * 0025_plan_table_align — the one-time repair of live `plans` rows.
 *
 * The shape half always runs (it pins the properties that make the migration
 * safe to deploy: journal ordering, rename order, and the refusal to touch
 * users or to insert rows on a fresh database). The behaviour half runs
 * against real Postgres when TEST_DATABASE_URL is set, in a scratch database
 * of its own — the same isolation migrate-cli.test.ts uses, so a concurrent
 * suite dropping the shared schema cannot interfere.
 */

const MIGRATION_PATH = fileURLToPath(
  new URL("../drizzle/0025_plan_table_align.sql", import.meta.url),
);
const JOURNAL_PATH = fileURLToPath(new URL("../drizzle/meta/_journal.json", import.meta.url));

const migrationSql = readFileSync(MIGRATION_PATH, "utf8");

const migrationStatements = (): string[] =>
  migrationSql
    .split("--> statement-breakpoint")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);

describe("0025 plan table migration shape", () => {
  it("is journaled at idx 25 and sorts after 0024", () => {
    const journal = JSON.parse(readFileSync(JOURNAL_PATH, "utf8")) as {
      entries: { idx: number; tag: string; when: number }[];
    };
    const entry = journal.entries.find((e) => e.tag === "0025_plan_table_align");
    expect(entry).toBeDefined();
    expect(entry!.idx).toBe(25);
    // 0024's `when` is in the future on this branch; a 0025 with an earlier
    // `when` would be skipped forever by drizzle's `created_at < folderMillis`
    // check on an install that already applied 0024.
    const previous = journal.entries.find((e) => e.tag === "0024_studio_repos");
    expect(previous).toBeDefined();
    expect(entry!.when).toBeGreaterThan(previous!.when);
  });

  it("renames old pro to plus before old max takes the pro id", () => {
    const toPlus = migrationSql.indexOf(`SET "id" = 'plus'`);
    const maxToPro = migrationSql.indexOf(`SET "id" = 'pro'`);
    expect(toPlus).toBeGreaterThan(-1);
    expect(maxToPro).toBeGreaterThan(toPlus);
  });

  it("leaves users alone and never inserts plan rows", () => {
    expect(migrationSql).not.toMatch(/UPDATE\s+"users"/i);
    expect(migrationSql).not.toMatch(/DELETE\s+FROM\s+"users"/i);
    expect(migrationSql).not.toMatch(/INSERT\s+INTO\s+"plans"/i);
  });

  it("carries the shared table's names, prices, multipliers and aliases", () => {
    for (const fragment of [
      `'Ovid Go', "price_usd" = '5', "aliases" = '["starter","3x"]'::jsonb,`,
      `'Ovid Plus', "price_usd" = '18', "aliases" = '["7x"]'::jsonb,`,
      `'Ovid Pro', "price_usd" = '99', "aliases" = '["max","15x"]'::jsonb,`,
    ]) {
      expect(migrationSql).toContain(fragment);
    }
    expect(migrationSql).toContain(`"mult" = '1.5'`);
    expect(migrationSql).toContain(`"mult" = '5'`);
    expect(migrationSql).toContain(`"mult" = '20'`);
  });
});

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

interface PlanSeed {
  id: string;
  name: string;
  priceUsd: string;
  enabled: boolean;
  aliases: string[];
  windowHours: number;
  mult: string;
  slowMode: boolean;
  autoOss: boolean;
  position: number;
}

/** What the first deployment's ADD-only seed wrote into a live install. */
const OLD_SEED: PlanSeed[] = [
  { id: "free", name: "Free", priceUsd: "0", enabled: true, aliases: [], windowHours: 24, mult: "1", slowMode: false, autoOss: false, position: 0 },
  { id: "starter", name: "Starter", priceUsd: "5", enabled: true, aliases: ["3x"], windowHours: 720, mult: "3", slowMode: false, autoOss: false, position: 1 },
  { id: "pro", name: "Pro", priceUsd: "25", enabled: true, aliases: ["7x"], windowHours: 720, mult: "23", slowMode: false, autoOss: true, position: 2 },
  { id: "max", name: "Max", priceUsd: "60", enabled: true, aliases: ["15x"], windowHours: 720, mult: "43", slowMode: false, autoOss: true, position: 3 },
];

interface PlanRow {
  id: string;
  name: string;
  price_usd: string;
  enabled: boolean;
  aliases: string[];
  window_hours: number;
  mult: string;
  slow_mode: boolean;
  auto_oss: boolean;
  position: number;
}

describe.skipIf(!TEST_DATABASE_URL)("0025 plan table migration against real postgres", () => {
  const scratchDb = `plan_align_test_${Date.now()}_${process.pid}`;
  let admin: postgres.Sql | undefined;
  let sql: postgres.Sql;

  beforeAll(async () => {
    // Resolved HERE, not at describe scope: vitest still runs a skipped
    // describe's callback to collect its tests, so dereferencing
    // TEST_DATABASE_URL there throws on every machine without a test
    // database — turning "skip" into "the whole package fails".
    const scratchUrl = TEST_DATABASE_URL!.replace(/\/[^/]*$/, `/${scratchDb}`);
    admin = postgres(TEST_DATABASE_URL!, { max: 1, onnotice: () => {} });
    await admin.unsafe(`CREATE DATABASE ${scratchDb}`);
    // Every migration up to and including 0025. On an empty plans table 0025
    // is a no-op — that is asserted below.
    await migrate(scratchUrl);
    sql = postgres(scratchUrl, { max: 1, onnotice: () => {} });
  }, 90_000);

  afterAll(async () => {
    try {
      await sql?.end({ timeout: 5 });
    } finally {
      try {
        await admin?.unsafe(`DROP DATABASE IF EXISTS ${scratchDb} WITH (FORCE)`);
      } finally {
        await admin?.end({ timeout: 5 });
      }
    }
  }, 30_000);

  /** Replay the migration's statements the way a re-run / manual apply would. */
  async function runMigration(): Promise<void> {
    for (const statement of migrationStatements()) {
      await sql.unsafe(statement);
    }
  }

  async function reset(): Promise<void> {
    await sql`DELETE FROM plans`;
    await sql`DELETE FROM users`;
  }

  async function insertPlans(rows: readonly PlanSeed[]): Promise<void> {
    for (const r of rows) {
      await sql`INSERT INTO plans
          (id, name, price_usd, enabled, aliases, window_hours, mult, slow_mode, auto_oss, position)
        VALUES
          (${r.id}, ${r.name}, ${r.priceUsd}, ${r.enabled}, ${JSON.stringify(r.aliases)}::jsonb,
           ${r.windowHours}, ${r.mult}, ${r.slowMode}, ${r.autoOss}, ${r.position})`;
    }
  }

  async function listPlans(): Promise<PlanRow[]> {
    return sql<PlanRow[]>`
      SELECT id, name, price_usd, enabled, aliases, window_hours, mult, slow_mode, auto_oss, position
      FROM plans ORDER BY position, id`;
  }

  it("maps the old seed tier-for-tier, not id-for-id", async () => {
    await reset();
    await insertPlans(OLD_SEED);
    await sql`INSERT INTO users (uid, email, tier) VALUES
      ('u-3x', '3x@test.local', '3x'),
      ('u-7x', '7x@test.local', '7x'),
      ('u-15x', '15x@test.local', '15x')`;

    await runMigration();

    expect(await listPlans()).toEqual([
      { id: "free", name: "Free", price_usd: "0", enabled: true, aliases: [], window_hours: 24, mult: "1", slow_mode: false, auto_oss: false, position: 0 },
      // old starter -> go, and its 720h paid window survives the rename
      { id: "go", name: "Ovid Go", price_usd: "5", enabled: true, aliases: ["starter", "3x"], window_hours: 720, mult: "1.5", slow_mode: false, auto_oss: false, position: 1 },
      // old middle pro ($25/23x) -> plus, NOT the top tier
      { id: "plus", name: "Ovid Plus", price_usd: "18", enabled: true, aliases: ["7x"], window_hours: 720, mult: "5", slow_mode: false, auto_oss: true, position: 2 },
      // old top max ($60/43x) -> pro
      { id: "pro", name: "Ovid Pro", price_usd: "99", enabled: true, aliases: ["max", "15x"], window_hours: 720, mult: "20", slow_mode: false, auto_oss: true, position: 3 },
    ]);

    // users.tier is untouched: the stored aliases still resolve to the same
    // tier rank, so no account changes allowance.
    expect(
      (await sql<{ uid: string; tier: string }[]>`SELECT uid, tier FROM users ORDER BY uid`).map(
        (r) => [r.uid, r.tier],
      ),
    ).toEqual([
      ["u-15x", "15x"],
      ["u-3x", "3x"],
      ["u-7x", "7x"],
    ]);
  });

  it("is idempotent — a second apply changes nothing", async () => {
    await reset();
    await insertPlans(OLD_SEED);

    await runMigration();
    const once = await listPlans();
    await runMigration();
    expect(await listPlans()).toEqual(once);
  });

  it("preserves enabled and window_hours across the rename", async () => {
    await reset();
    await insertPlans(
      OLD_SEED.map((r) =>
        r.id === "max" ? { ...r, enabled: false, windowHours: 48 } : r,
      ),
    );

    await runMigration();

    const pro = (await listPlans()).find((r) => r.id === "pro");
    expect(pro).toMatchObject({ name: "Ovid Pro", enabled: false, window_hours: 48 });
  });

  it("a canonical plus wins over an old middle pro; old max still becomes pro", async () => {
    await reset();
    await insertPlans([
      OLD_SEED[0]!,
      OLD_SEED[1]!,
      // canonical new-table plus (already migrated by hand / a partial run)
      { id: "plus", name: "Ovid Plus", priceUsd: "18", enabled: true, aliases: ["7x"], windowHours: 720, mult: "5", slowMode: false, autoOss: true, position: 2 },
      // old middle pro — the colliding row; its disabled state must not leak
      { ...OLD_SEED[2]!, enabled: false, windowHours: 100 },
      OLD_SEED[3]!,
    ]);

    await runMigration();

    const rows = await listPlans();
    expect(rows.map((r) => r.id)).toEqual(["free", "go", "plus", "pro"]);
    expect(rows.find((r) => r.id === "plus")).toMatchObject({
      name: "Ovid Plus",
      price_usd: "18",
      mult: "5",
      enabled: true,
      window_hours: 720,
    });
    expect(rows.find((r) => r.id === "pro")).toMatchObject({
      name: "Ovid Pro",
      price_usd: "99",
      mult: "20",
      enabled: true,
      window_hours: 720,
    });
  });

  it("leaves an empty plans table empty, so the app seed still decides the windows", async () => {
    await reset();
    await runMigration();
    expect(await listPlans()).toEqual([]);
  });

  it("rewrites a partially migrated table and drops no unknown plan", async () => {
    await reset();
    await insertPlans([
      OLD_SEED[0]!,
      { id: "go", name: "Ovid Go", priceUsd: "5", enabled: true, aliases: ["starter", "3x"], windowHours: 720, mult: "1.5", slowMode: false, autoOss: false, position: 1 },
      OLD_SEED[2]!, // old middle pro
      OLD_SEED[3]!, // old max
      // an owner-added plan that is not one of the four tiers
      { id: "team", name: "Team", priceUsd: "250", enabled: true, aliases: [], windowHours: 720, mult: "50", slowMode: false, autoOss: true, position: 9 },
    ]);

    await runMigration();

    const rows = await listPlans();
    expect(rows.map((r) => r.id)).toEqual(["free", "go", "plus", "pro", "team"]);
    expect(rows.find((r) => r.id === "team")).toMatchObject({ name: "Team", price_usd: "250" });
  });
});
