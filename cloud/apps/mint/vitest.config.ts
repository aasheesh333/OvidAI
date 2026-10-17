import { defineConfig } from "vitest/config";

// The DB-backed test files (settings/projection/hookContract) share ONE dev
// Postgres (TEST_DATABASE_URL) and each drops/recreates the whole schema in
// beforeAll (the P8-T3 invariant), plus a shared Redis db9. Serialize test
// FILES so their beforeAll reset blocks can never race across workers —
// same discipline as @ovid/db and the gateway.
export default defineConfig({
  test: {
    fileParallelism: false,
  },
});
