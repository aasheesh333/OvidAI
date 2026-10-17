import { describe, expect, it } from "vitest";

import { createStorage, loadStorageEnv } from "./storageEnv.js";

/**
 * Offline env-selection pins. No network, no filesystem writes (createStorage
 * fs root is never touched — construction only).
 */

const R2_ENV = {
  OVID_R2_ACCOUNT_ID: "acct-123",
  OVID_R2_ACCESS_KEY_ID: "key-456",
  OVID_R2_SECRET_ACCESS_KEY: "secret-789",
  OVID_R2_BUCKET: "bucket-abc",
} as const;

const FS_ENV = { OVID_FS_STORAGE_ROOT: "/tmp/ovid-storage-test-root" } as const;

describe("loadStorageEnv", () => {
  it("empty env → fs backend, which FAILS without OVID_FS_STORAGE_ROOT", () => {
    expect(() => loadStorageEnv({})).toThrow(/OVID_FS_STORAGE_ROOT/);
  });

  it("OVID_FS_STORAGE_ROOT set → backend fs carrying the root", () => {
    const env = loadStorageEnv({ ...FS_ENV });
    expect(env.backend).toBe("fs");
    expect(env.fsRoot).toBe("/tmp/ovid-storage-test-root");
    expect(env.r2).toBeUndefined();
  });

  it("empty OVID_FS_STORAGE_ROOT counts as missing", () => {
    expect(() => loadStorageEnv({ OVID_FS_STORAGE_ROOT: "" })).toThrow(/OVID_FS_STORAGE_ROOT/);
  });

  it("all four OVID_R2_* present, backend unset → auto-detect r2", () => {
    const env = loadStorageEnv({ ...R2_ENV });
    expect(env.backend).toBe("r2");
    expect(env.r2).toMatchObject({ accountId: "acct-123", bucket: "bucket-abc" });
    expect(env.fsRoot).toBeUndefined();
  });

  it("only some OVID_R2_* present → falls back to fs (still needs the root)", () => {
    const { OVID_R2_BUCKET: _drop, ...partial } = R2_ENV;
    expect(() => loadStorageEnv({ ...partial })).toThrow(/OVID_FS_STORAGE_ROOT/);
    const env = loadStorageEnv({ ...partial, ...FS_ENV });
    expect(env.backend).toBe("fs");
  });

  it("explicit OVID_STORAGE_BACKEND=r2 requires the R2 vars (names the first missing one)", () => {
    expect(() => loadStorageEnv({ OVID_STORAGE_BACKEND: "r2", ...FS_ENV })).toThrow(
      /OVID_R2_ACCOUNT_ID/,
    );
  });

  it("explicit OVID_STORAGE_BACKEND=fs wins over present R2 vars", () => {
    const env = loadStorageEnv({ OVID_STORAGE_BACKEND: "fs", ...FS_ENV, ...R2_ENV });
    expect(env.backend).toBe("fs");
  });

  it("explicit OVID_STORAGE_BACKEND=r2 ignores the fs root entirely", () => {
    const env = loadStorageEnv({ OVID_STORAGE_BACKEND: "r2", ...R2_ENV, ...FS_ENV });
    expect(env.backend).toBe("r2");
    expect(env.fsRoot).toBeUndefined();
  });

  it("an invalid OVID_STORAGE_BACKEND value fails loud", () => {
    expect(() => loadStorageEnv({ OVID_STORAGE_BACKEND: "s3", ...FS_ENV })).toThrow(
      /OVID_STORAGE_BACKEND/,
    );
  });

  it("NODE_ENV=production + fs backend → throws (fs is a dev/test backend)", () => {
    expect(() => loadStorageEnv({ NODE_ENV: "production", ...FS_ENV })).toThrow(/production/);
  });

  it("NODE_ENV=production + r2 backend → fine", () => {
    const env = loadStorageEnv({ NODE_ENV: "production", ...R2_ENV });
    expect(env.backend).toBe("r2");
  });
});

describe("createStorage", () => {
  it("backend fs → the fs adapter over fsRoot", () => {
    const adapter = createStorage({ backend: "fs", fsRoot: "/tmp/whatever" });
    expect(adapter.kind).toBe("fs");
  });

  it("backend fs without fsRoot → throws", () => {
    expect(() => createStorage({ backend: "fs" })).toThrow(/fsRoot/);
  });

  it("backend r2 → the R2 adapter over the carried config", () => {
    const adapter = createStorage({
      backend: "r2",
      r2: {
        accountId: "a",
        accessKeyId: "k",
        secretAccessKey: "s",
        bucket: "b",
      },
    });
    expect(adapter.kind).toBe("r2");
  });

  it("backend r2 without a config → throws", () => {
    expect(() => createStorage({ backend: "r2" })).toThrow(/r2/);
  });
});
