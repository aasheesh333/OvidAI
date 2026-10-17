import { defineConfig } from "vitest/config";

// The load harness's own tests are fully in-process: a mock gateway (HTTP +
// WS) and a mock LiteLLM (SSE). No dev services, no staging composition.
// The smoke run drives real timers (ramp/cadence/reconnects), so allow a
// generous ceiling without serializing across files.
export default defineConfig({
  test: {
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
