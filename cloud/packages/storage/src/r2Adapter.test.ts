import { describe, expect, it } from "vitest";

import {
  createR2Storage,
  loadR2Config,
  r2Endpoint,
  R2_PART_SIZE,
  R2_QUEUE_SIZE,
} from "./r2Adapter.js";
import { KeyLayoutError } from "./errors.js";

/**
 * Offline config/presign pins — NO network. The presign tests use an
 * unreachable-account fake credential set and still resolve, pinning that
 * getSignedUrl signs locally (a signing request would never reach the fake
 * account).
 */

const FULL_ENV = {
  OVID_R2_ACCOUNT_ID: "acct-123",
  OVID_R2_ACCESS_KEY_ID: "key-456",
  OVID_R2_SECRET_ACCESS_KEY: "secret-789",
  OVID_R2_BUCKET: "bucket-abc",
} as const;

const ALL_VALUES = Object.values(FULL_ENV);

describe("r2Endpoint", () => {
  it("maps an account id onto the R2 S3 endpoint", () => {
    expect(r2Endpoint("abc")).toBe("https://abc.r2.cloudflarestorage.com");
  });
});

describe("loadR2Config", () => {
  it("reads a full env into an R2Config", () => {
    const cfg = loadR2Config({ ...FULL_ENV });
    expect(cfg).toEqual({
      accountId: "acct-123",
      accessKeyId: "key-456",
      secretAccessKey: "secret-789",
      bucket: "bucket-abc",
    });
  });

  it.each(["OVID_R2_ACCOUNT_ID", "OVID_R2_ACCESS_KEY_ID", "OVID_R2_SECRET_ACCESS_KEY", "OVID_R2_BUCKET"] satisfies (keyof typeof FULL_ENV)[])(
    "missing %s throws naming THAT var and leaking no values",
    (name) => {
      const env = { ...FULL_ENV };
      delete env[name];
      expect(() => loadR2Config(env)).toThrow(
        new RegExp(name.replace(/_/g, "_")),
      );
      let message = "";
      try {
        loadR2Config(env);
      } catch (err) {
        message = (err as Error).message;
      }
      expect(message).toContain(name);
      for (const value of ALL_VALUES) {
        expect(message).not.toContain(value);
      }
    },
  );

  it("checks vars in order — the FIRST missing var is named", () => {
    const env = {
      OVID_R2_ACCESS_KEY_ID: "k",
      OVID_R2_SECRET_ACCESS_KEY: "s",
      OVID_R2_BUCKET: "b",
    };
    expect(() => loadR2Config(env)).toThrow(/OVID_R2_ACCOUNT_ID/);
  });

  it("treats an empty-string var as missing", () => {
    const env = { ...FULL_ENV, OVID_R2_BUCKET: "" };
    expect(() => loadR2Config(env)).toThrow(/OVID_R2_BUCKET/);
  });

  it("optional OVID_R2_ENDPOINT overrides the account endpoint", () => {
    const cfg = loadR2Config({ ...FULL_ENV, OVID_R2_ENDPOINT: "http://127.0.0.1:9000" });
    expect(cfg.endpoint).toBe("http://127.0.0.1:9000");
    expect(loadR2Config({ ...FULL_ENV }).endpoint).toBeUndefined();
  });
});

describe("createR2Storage — offline pins", () => {
  const FAKE_CFG = {
    accountId: "a",
    accessKeyId: "k",
    secretAccessKey: "s",
    bucket: "b",
  };

  it("kind is \"r2\"", () => {
    expect(createR2Storage(FAKE_CFG).kind).toBe("r2");
  });

  it("R2_PART_SIZE is 8 MiB and R2_QUEUE_SIZE is 2", () => {
    expect(R2_PART_SIZE).toBe(8 * 1024 * 1024);
    expect(R2_QUEUE_SIZE).toBe(2);
  });

  it("presignGet signs OFFLINE with unreachable fake creds: origin, key path, X-Amz-Signature, X-Amz-Expires", async () => {
    const adapter = createR2Storage(FAKE_CFG);
    const url = await adapter.presignGet("users/u/x.tar.zst", 60);
    const u = new URL(url);
    expect(u.origin).toBe("https://a.r2.cloudflarestorage.com");
    expect(u.pathname).toContain("users/u/x.tar.zst");
    expect(u.searchParams.get("X-Amz-Signature")).toMatch(/^[0-9a-f]{64}$/);
    expect(u.searchParams.get("X-Amz-Expires")).toBe("60");
  });

  it("presignPut signs OFFLINE with the same shape — the P8-T3 upload seam (ruling R3)", async () => {
    const adapter = createR2Storage(FAKE_CFG);
    const url = await adapter.presignPut("users/u/x.bin", 60);
    const u = new URL(url);
    expect(u.origin).toBe("https://a.r2.cloudflarestorage.com");
    expect(u.pathname).toContain("users/u/x.bin");
    expect(u.searchParams.get("X-Amz-Signature")).toMatch(/^[0-9a-f]{64}$/);
    expect(u.searchParams.get("X-Amz-Expires")).toBe("60");
  });

  it("presignGet/presignPut reject unsafe keys before any request (key layout seam)", async () => {
    const adapter = createR2Storage(FAKE_CFG);
    await expect(adapter.presignGet("../escape", 60)).rejects.toBeInstanceOf(KeyLayoutError);
    await expect(adapter.presignPut("a/../../b", 60)).rejects.toBeInstanceOf(KeyLayoutError);
  });

  it("put rejects unsafe keys before any request (no network)", async () => {
    const adapter = createR2Storage(FAKE_CFG);
    await expect(adapter.put("../escape", Buffer.from("x"))).rejects.toBeInstanceOf(KeyLayoutError);
    await expect(adapter.head("a/../../b")).rejects.toBeInstanceOf(KeyLayoutError);
    await expect(adapter.get("\\bad")).rejects.toBeInstanceOf(KeyLayoutError);
    await expect(adapter.delete("../escape")).rejects.toBeInstanceOf(KeyLayoutError);
    await expect(adapter.readerSpec("")).rejects.toBeInstanceOf(KeyLayoutError);
  });

  it("presign honors a custom endpoint", async () => {
    const adapter = createR2Storage({ ...FAKE_CFG, endpoint: "http://127.0.0.1:9000" });
    const url = await adapter.presignGet("users/u/x.tar.zst", 60);
    expect(new URL(url).origin).toBe("http://127.0.0.1:9000");
  });
});
