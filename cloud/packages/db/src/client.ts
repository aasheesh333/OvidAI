import { fileURLToPath } from "node:url";
import { drizzle } from "drizzle-orm/postgres-js";
import { migrate as drizzleMigrate } from "drizzle-orm/postgres-js/migrator";
import postgres from "postgres";

export type Db = ReturnType<typeof drizzle>;

/** postgres.js client + drizzle wrapper. Close with `db.$client.end()`. */
export function createDb(databaseUrl: string): Db {
  return drizzle(postgres(databaseUrl));
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
