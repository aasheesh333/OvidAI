import { migrate } from "@ovid/db";

/**
 * The worker suite shares one real Postgres database across test files.
 * Many files assume the schema is already present but do not call migrate
 * themselves; relying on file-order is non-deterministic under Vitest's
 * parallel test-file execution. Migrate once before any test file runs so
 * every file starts from a migrated shared database. Files that also call
 * migrate() in their own beforeAll are safe because migrate() is idempotent.
 */
export default async function globalSetup(): Promise<void> {
  const databaseUrl = process.env.TEST_DATABASE_URL;
  if (!databaseUrl) return;
  await migrate(databaseUrl);
}
