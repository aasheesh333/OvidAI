/**
 * P6 Task 14 — worker env additions for the browser engine. Pure loader tests
 * (no chromium, no redis, no DB): `loadWorkerEnv`'s new browser knobs and
 * their fail-loud interaction. The boot path itself (engine construction,
 * SIGTERM ordering) is exercised by Task 15's e2e — these tests assert the
 * exported pieces, never by running main().
 */

import { describe, expect, it } from "vitest";
import { loadBrowserEngineConfig } from "@ovid/browser";

import { loadWorkerEnv } from "./main.js";

const baseEnv = (overrides: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv => ({
  DATABASE_URL: "postgres://postgres:ovid@127.0.0.1:5433/postgres",
  REDIS_Q_URL: "redis://127.0.0.1:6390",
  REDIS_MINT_URL: "redis://127.0.0.1:6390",
  OVID_INTERNAL_MINT_URL: "http://127.0.0.1:18092",
  OVID_INTERNAL_API_SECRET: "test-internal-secret-0123456789abcdef",
  OVID_LITELLM_BASE: "http://litellm.invalid",
  OVID_DEFAULT_MODEL: "ovid-default-model",
  OVID_INTERNAL_TOKEN: "shared-secret",
  ...overrides,
});

/** A well-formed OVID_MASTER_KEY (64 hex chars = 32 bytes). */
const MASTER_KEY_HEX =
  "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

describe("worker credential broker flag", () => {
  it("is default-off in the production browser config and only exact 1 opts in", () => {
    expect(loadBrowserEngineConfig(baseEnv()).credentialBrokerEnabled).toBe(false);
    expect(loadBrowserEngineConfig(baseEnv({ OVID_BROWSER_CREDENTIAL_BROKER: "0" })).credentialBrokerEnabled).toBe(false);
    expect(loadBrowserEngineConfig(baseEnv({ OVID_BROWSER_CREDENTIAL_BROKER: "1" })).credentialBrokerEnabled).toBe(true);
    expect(() => loadBrowserEngineConfig(baseEnv({ OVID_BROWSER_CREDENTIAL_BROKER: "true" }))).toThrow(
      /OVID_BROWSER_CREDENTIAL_BROKER/,
    );
  });
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
      baseEnv({ OVID_BROWSER_STATE_DIR: "/var/lib/ovid/browser-state", OVID_MASTER_KEY: MASTER_KEY_HEX }),
    );
    expect(cfg.browserStateDir).toBe("/var/lib/ovid/browser-state");
    expect(cfg.masterKey).toBe(MASTER_KEY_HEX);
  });

  it("neither set → masterKey:null and browserStateDir:null (boot path unaffected)", () => {
    const cfg = loadWorkerEnv(baseEnv());
    expect(cfg.masterKey).toBeNull();
    expect(cfg.browserStateDir).toBeNull();
  });

  it("masterKey alone is fine — without a state dir, persistence stays off", () => {
    const cfg = loadWorkerEnv(baseEnv({ OVID_MASTER_KEY: MASTER_KEY_HEX }));
    expect(cfg.masterKey).toBe(MASTER_KEY_HEX);
    expect(cfg.browserStateDir).toBeNull();
  });

  it("OVID_MASTER_KEY must be 64 hex chars — malformed values throw naming the variable (M5)", () => {
    expect(() => loadWorkerEnv(baseEnv({ OVID_MASTER_KEY: "master-key" }))).toThrow(
      /OVID_MASTER_KEY/,
    );
    expect(() =>
      loadWorkerEnv(baseEnv({ OVID_MASTER_KEY: "ab7d31c4" })),
    ).toThrow(/OVID_MASTER_KEY/);
    expect(() =>
      loadWorkerEnv(baseEnv({ OVID_MASTER_KEY: "z".repeat(64) })),
    ).toThrow(/OVID_MASTER_KEY/);
    // Upper-case hex is valid (crypto.ts's regex is case-insensitive).
    expect(
      loadWorkerEnv(baseEnv({ OVID_MASTER_KEY: MASTER_KEY_HEX.toUpperCase() })).masterKey,
    ).toBe(MASTER_KEY_HEX.toUpperCase());
  });
});
