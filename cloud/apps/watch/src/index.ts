/**
 * @ovid/watch — P10 monitoring & alerting.
 *
 * - `checks.ts`      gateway/queue/lag/disk/redis-memory/spend-parity checks.
 * - `alertState.ts`  edge-triggered state transitions (Review Focus #5).
 * - `alertSink.ts`   mint's Telegram mechanism + optional webhook; self-test.
 * - `env.ts`         strict env parsing with the plan's locked defaults.
 * - `main.ts`        one-shot timer entry point + real deps wiring.
 */
export * from "./alertSink.js";
export * from "./alertState.js";
export * from "./checks.js";
export * from "./env.js";
export * from "./main.js";
