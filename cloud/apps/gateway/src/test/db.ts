import { createDb, migrate, type Db } from "@ovid/db";

export const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

/**
 * Db handle against the shared dev Postgres, migrated.
 *
 * No DROP here (unlike @ovid/db's repos.test.ts): gateway test files are
 * serialized via vitest.config.ts (fileParallelism:false), migrate() is
 * idempotent, and every test scopes its data by freshly generated uids — so
 * files neither race on migrations nor interfere through leftover rows.
 */
export async function openTestDb(): Promise<Db> {
  const url = TEST_DATABASE_URL!;
  await migrate(url);
  return createDb(url);
}

export async function closeDb(db: Db | undefined): Promise<void> {
  await db?.$client.end({ timeout: 5 });
}

/** Fresh per-test uid (never collides with other files' data). */
export function testUid(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}
