/**
 * @ovid/load — the P10 load harness core.
 *
 * - `client.ts`    WS+REST load client; every server frame is parsed through
 *                  the shared `wsServerMsg` schema.
 * - `scenario.ts`  profile DSL + runner (ramp, cadence, reconnect/replay,
 *                  spike, schedules) and the LoadReport aggregation.
 * - `metrics.ts`   percentile/delivery-latency/integrity arithmetic.
 * - `mockServer.ts` mock LiteLLM ([OI] SSE + P9 admin stubs).
 * - `thresholds.ts` smoke/full acceptance tables.
 * - `cli.ts`       `load --profile … --target staging --out …`.
 */
export * from "./client.js";
export * from "./metrics.js";
export * from "./mockServer.js";
export * from "./scenario.js";
export * from "./thresholds.js";
// P10 Task 6 — chaos runner/handles (Task 7 consumes these exact exports).
export * from "./chaos/runner.js";
export * from "./chaos/staging.js";
