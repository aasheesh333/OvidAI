import { defineConfig } from "vitest/config";

// repos.test.ts and moneyRepos.test.ts share ONE dev Postgres
// (TEST_DATABASE_URL) and both drop/recreate the whole schema in beforeAll.
// Serialize test FILES so those setup passes can never race across workers
// (same rationale as the gateway's vitest.config.ts).
export default defineConfig({
  test: {
    fileParallelism: false,
  },
});
