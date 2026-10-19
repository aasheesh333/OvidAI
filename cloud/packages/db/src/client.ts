import { fileURLToPath } from "node:url";
import { drizzle } from "drizzle-orm/postgres-js";
import { migrate as drizzleMigrate } from "drizzle-orm/postgres-js/migrator";
import postgres from "postgres";

export type Db = ReturnType<typeof drizzle>;

/**
 * Pool knobs (capacity wave 2026-10-19). postgres.js defaults to max 10
 * connections and never closes idle ones; prepared statements are on by
 * default (statement reuse per connection) and stay on.
 */
export interface DbPoolOptions {
  /** Max pooled connections (postgres.js default 10). */
  max?: number;
  /** Close a connection idle this many seconds (default: never). */
  idleTimeoutSec?: number;
}

function poolInt(env: NodeJS.ProcessEnv, name: string, min: number, max: number): number | undefined {
  const raw = env[name];
  if (raw === undefined || raw.trim() === "") return undefined;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < min || n > max) {
    throw new Error(`${name} must be an integer ${min}..${max}, got: ${raw}`);
  }
  return n;
}

/**
 * OVID_DB_POOL_MAX (1..500) / OVID_DB_IDLE_TIMEOUT_S (1..86400), falling back
 * to the per-process `defaults`. Invalid values throw at boot (fail loud).
 */
export function dbPoolOptionsFromEnv(
  env: NodeJS.ProcessEnv,
  defaults: DbPoolOptions = {},
): DbPoolOptions {
  const max = poolInt(env, "OVID_DB_POOL_MAX", 1, 500) ?? defaults.max;
  const idleTimeoutSec = poolInt(env, "OVID_DB_IDLE_TIMEOUT_S", 1, 86_400) ?? defaults.idleTimeoutSec;
  return {
    ...(max !== undefined ? { max } : {}),
    ...(idleTimeoutSec !== undefined ? { idleTimeoutSec } : {}),
  };
}

/** postgres.js client + drizzle wrapper. Close with `db.$client.end()`. */
export function createDb(databaseUrl: string, pool: DbPoolOptions = {}): Db {
  return drizzle(
    postgres(databaseUrl, {
      ...(pool.max !== undefined ? { max: pool.max } : {}),
      ...(pool.idleTimeoutSec !== undefined ? { idle_timeout: pool.idleTimeoutSec } : {}),
    }),
  );
}

/** drizzle/ folder next to the package root — same relative path from src/ (tests) and dist/ (deploy). */
const MIGRATIONS_FOLDER = fileURLToPath(new URL("../drizzle", import.meta.url));

/**
 * Apply all generated migrations in drizzle/ (creates the drizzle journal
 * schema/table on first run; no-op when already up to date). Used by tests and
 * deploy. Opens and closes its own single connection.
 *
 * onnotice is silenced: re-runs make Postgres emit expected NOTICEs ("schema
 * drizzle already exists, skipping", …) which postgres.js would otherwise
 * print — noise on every boot/test run, never actionable.
 */
export async function migrate(databaseUrl: string): Promise<void> {
  const client = postgres(databaseUrl, { max: 1, onnotice: () => {} });
  try {
    await drizzleMigrate(drizzle(client), { migrationsFolder: MIGRATIONS_FOLDER });
  } finally {
    await client.end({ timeout: 5 });
  }
}
