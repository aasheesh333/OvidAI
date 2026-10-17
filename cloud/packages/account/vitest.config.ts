import { defineConfig } from "vitest/config";

// store.test.ts and adapters.test.ts share ONE dev Postgres
// (TEST_DATABASE_URL) and each reset the schema in beforeAll. Serialize test
// FILES so those reset passes can never race (same discipline as @ovid/db).
export default defineConfig({
  test: {
    fileParallelism: false,
  },
});
