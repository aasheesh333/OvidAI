import { defineConfig } from "vitest/config";

// The route tests (sessions/messages/health) all share ONE dev Postgres
// (TEST_DATABASE_URL) and mutate overlapping tables. Serialize test FILES so
// their beforeAll migrate() calls and per-test seeding can never race across
// workers; data isolation between files comes from fresh uids per test.
export default defineConfig({
  test: {
    fileParallelism: false,
  },
});
