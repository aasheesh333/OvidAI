import { defineConfig } from "vitest/config";

// The spine e2e composes the REAL gateway + worker + Postgres + Redis in one
// process. Serialize test files (same discipline as every other suite that
// touches the shared dev services), and give the BullMQ legs (REST send →
// queue → worker → SSE stream → WS delivery) generous ceilings — they cross
// four network hops per event.
export default defineConfig({
  test: {
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 60_000,
  },
});
