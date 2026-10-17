/**
 * @ovid/e2e is a test-only workspace app: the spine regression harness lives
 * in src/spine.test.ts (excluded from this build by tsconfig.json, same
 * convention as every other package's *.test.ts). This module exists so the
 * package has a compilable entry point like every other workspace package
 * (`tsc -p tsconfig.json` → dist/index.js) and so later plans have an obvious
 * home for shared harness code that must survive the build.
 */
export const E2E_PACKAGE = "@ovid/e2e";

// P10 Task 8 security-corpus surfaces (consumed by Task 14's acceptance
// gate): `capabilityGate()` + `SKIPPED_SECURITY` + the summary formatter.
export * from "./security/skipReport.js";
export * from "./security/denylist-corpus.js";
