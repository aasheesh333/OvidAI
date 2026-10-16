import { defineConfig } from "vitest/config";

// runProcessor.test.ts shares ONE dev Postgres + Redis with the rest of the
// monorepo suites and runs a real BullMQ worker against the pinned
// "agent-runs" queue. Serialize test FILES so migrate() calls, per-test
// seeding and queue obliteration can never race across workers; isolation
// comes from freshly generated session/run ids per test (gateway convention).
// The BullMQ legs (job add → worker "completed") get a generous ceiling.
export default defineConfig({
  test: {
    fileParallelism: false,
    testTimeout: 20_000,
    hookTimeout: 30_000,
  },
});
