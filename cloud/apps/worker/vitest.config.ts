import path from "node:path";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      // Allow the worker test suite to import the gateway app for
      // route-driven R2 round-trip tests.
      "@gateway": path.resolve(__dirname, "../gateway/src"),
    },
  },
  server: {
    fs: {
      allow: [".."],
    },
  },
  test: {
    globalSetup: ["./src/globalSetup.ts"],
    // Several suites use shared real Postgres/Redis instances and real OS
    // ports/processes; running test files in parallel causes timing flakiness
    // and port/PID collisions. Run files serially to keep the suite stable
    // and deterministic.
    fileParallelism: false,
  },
});
