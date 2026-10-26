import { defineConfig } from "vitest/config";

// agent-core suites share ONE dev Postgres + Redis with the rest of the
// monorepo and run the real migrate() before seeding. Without this, test FILES
// run in parallel and race on migrate() (duplicate key
// pg_type_typname_nsp_index in loop.test.ts / subagents.test.ts). Serialize
// files, exactly like apps/worker; isolation still comes from freshly
// generated session/run ids per test.
export default defineConfig({
  test: {
    fileParallelism: false,
    testTimeout: 20_000,
    hookTimeout: 30_000,
  },
});
