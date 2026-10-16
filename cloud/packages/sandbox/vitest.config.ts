import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Later P2 tasks add host suites that spawn real bwrap sandboxes; those
    // need a far more generous per-test ceiling than vitest's 5s default.
    testTimeout: 30_000,
  },
});
