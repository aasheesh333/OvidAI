import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import postgres from "postgres";

// The CLI is exercised AS DEPLOYED: a spawned `node dist/migrate-cli.js`
// against a real Postgres — that is the exact form provision.sh invokes, and
// it pins the property a src-level test cannot: MIGRATIONS_FOLDER resolves
// correctly relative to dist/ (../drizzle from the compiled file).
const CLI_PATH = fileURLToPath(new URL("../dist/migrate-cli.js", import.meta.url));

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

const cli = (args: string[]): ReturnType<typeof spawnSync> =>
  spawnSync(process.execPath, [CLI_PATH, ...args], {
    encoding: "utf8",
    timeout: 60_000,
    env: process.env,
  });

describe.skipIf(!TEST_DATABASE_URL)("migrate-cli against real postgres", () => {
  // Scratch database per run, created/dropped through the admin connection —
  // keeps the CLI test isolated from repos.test.ts (which drops/re-migrates
  // the shared TEST_DATABASE_URL schema concurrently).
  const scratchDb = `migrate_cli_test_${Date.now()}_${process.pid}`;
  const scratchUrl = TEST_DATABASE_URL!.replace(/\/[^/]*$/, `/${scratchDb}`);
  let admin: postgres.Sql | undefined;

  beforeAll(async () => {
    admin = postgres(TEST_DATABASE_URL!, { max: 1, onnotice: () => {} });
    await admin.unsafe(`CREATE DATABASE ${scratchDb}`);
  }, 30_000);

  afterAll(async () => {
    try {
      await admin?.unsafe(`DROP DATABASE IF EXISTS ${scratchDb} WITH (FORCE)`);
    } finally {
      await admin?.end({ timeout: 5 });
    }
  }, 30_000);

  it("is built (dist/migrate-cli.js exists — run `pnpm build` first)", () => {
    expect(existsSync(CLI_PATH)).toBe(true);
  });

  it("applies migrations to a fresh database and exits 0", () => {
    const r = cli([scratchUrl]);
    expect(r.stderr).toBe("");
    expect(r.stdout).toMatch(/\[migrate\] applying/);
    expect(r.stdout).toMatch(/\[migrate\] done/);
    expect(r.status).toBe(0);
  }, 90_000);

  it("is idempotent — a second run against the migrated database exits 0", () => {
    const r = cli([scratchUrl]);
    expect(r.status).toBe(0);
  }, 90_000);

  it("exits 1 with a diagnostic on an unreachable database", () => {
    // Port 1 on loopback: immediate ECONNREFUSED, nothing listening.
    const r = cli(["postgres://nope:nope@127.0.0.1:1/nodb"]);
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/\[migrate\] FAILED/);
  }, 90_000);

  it("exits 1 with usage when no DATABASE_URL argument is given", () => {
    const r = cli([]);
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/usage: node dist\/migrate-cli\.js <DATABASE_URL>/);
  });
});
