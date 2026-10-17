import { defineConfig } from "vitest/config";

// Two DB-gated suites (oauth/flow.test.ts and router.test.ts) share ONE dev
// Postgres (TEST_DATABASE_URL) and each runs an idempotent migrate() in
// beforeAll. On a fresh database those concurrent migrations race (drizzle's
// journal is not concurrency-safe), so serialize test FILES — the same
// package-local convention as apps/gateway/vitest.config.ts. Data isolation
// still comes from fresh uids per test.
export default defineConfig({
  test: {
    fileParallelism: false,
  },
});
