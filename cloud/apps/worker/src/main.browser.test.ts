/**
 * P6 Task 14 — worker env additions for the browser engine. Pure loader tests
 * (no chromium, no redis, no DB): `loadWorkerEnv`'s new browser knobs and
 * their fail-loud interaction. The boot path itself (engine construction,
 * SIGTERM ordering) is exercised by Task 15's e2e — these tests assert the
 * exported pieces, never by running main().
 */

import { describe, expect, it } from "vitest";

import { loadWorkerEnv } from "./main.js";

const baseEnv = (overrides: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv => ({
  DATABASE_URL: "postgres://postgres:ovid@127.0.0.1:5433/postgres",
  REDIS_Q_URL: "redis://127.0.0.1:6390",
  REDIS_MINT_URL: "redis://127.0.0.1:6390",
  OVID_LITELLM_BASE: "http://litellm.invalid",
  OVID_DEFAULT_MODEL: "ovid-default-model",
  OVID_INTERNAL_TOKEN: "shared-secret",
  ...overrides,
});

describe("worker browser env (P6 Task 14)", () => {
  it("OVID_BROWSER_STATE_DIR set + OVID_MASTER_KEY missing → throws naming OVID_MASTER_KEY", () => {
    expect(() =>
      loadWorkerEnv(baseEnv({ OVID_BROWSER_STATE_DIR: "/var/lib/ovid/browser-state" })),
    ).toThrow(/OVID_MASTER_KEY/);
    expect(() =>
      loadWorkerEnv(baseEnv({ OVID_BROWSER_STATE_DIR: "/var/lib/ovid/browser-state", OVID_MASTER_KEY: "" })),
    ).toThrow(/OVID_MASTER_KEY/);
    expect(() =>
      loadWorkerEnv(baseEnv({ OVID_BROWSER_STATE_DIR: "/var/lib/ovid/browser-state", OVID_MASTER_KEY: "   " })),
    ).toThrow(/OVID_MASTER_KEY/);
  });

  it("both set → parsed onto the env", () => {
    const cfg = loadWorkerEnv(
      baseEnv({ OVID_BROWSER_STATE_DIR: "/var/lib/ovid/browser-state", OVID_MASTER_KEY: "master-key" }),
    );
    expect(cfg.browserStateDir).toBe("/var/lib/ovid/browser-state");
    expect(cfg.masterKey).toBe("master-key");
  });

  it("neither set → masterKey:null and browserStateDir:null (boot path unaffected)", () => {
    const cfg = loadWorkerEnv(baseEnv());
    expect(cfg.masterKey).toBeNull();
    expect(cfg.browserStateDir).toBeNull();
  });

  it("masterKey alone is fine — without a state dir, persistence stays off", () => {
    const cfg = loadWorkerEnv(baseEnv({ OVID_MASTER_KEY: "master-key" }));
    expect(cfg.masterKey).toBe("master-key");
    expect(cfg.browserStateDir).toBeNull();
  });
});
