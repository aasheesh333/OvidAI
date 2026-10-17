import { defineConfig } from "vitest/config";

// Fully in-process unit tests: fake deps, fake fetch and one loopback HTTP
// server for the delivery-path proof. No dev services, no staging, and NEVER
// a real Telegram call (the sink is always injected/faked in tests).
export default defineConfig({
  test: {
    fileParallelism: false,
    testTimeout: 15_000,
    hookTimeout: 15_000,
  },
});
