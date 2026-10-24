/**
 * R2 LIVE contract — runs ONLY when OVID_R2_* credentials are present in the
 * environment. CI has no credentials, so the suites report as skipped there;
 * they run on the box after Task 14 provisioning (R2-PROVISIONING.md step 5):
 *
 *   OVID_R2_ACCOUNT_ID=… OVID_R2_ACCESS_KEY_ID=… OVID_R2_SECRET_ACCESS_KEY=… \
 *   OVID_R2_BUCKET=… pnpm --filter @ovid/storage exec vitest run src/r2.live.test.ts
 *
 * Probe objects live under `users/_test-<uuid>/…` and are deleted by cleanup
 * (tracked keys + a prefix sweep for anything untracked).
 */

import { createHash, randomUUID } from "node:crypto";
import {
  DeleteObjectsCommand,
  ListObjectsV2Command,
  S3Client,
} from "@aws-sdk/client-s3";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import type { StorageAdapter } from "./adapter.js";
import { storageContractSuite } from "./contract.js";
import { createR2Storage, loadR2Config, r2Endpoint, type R2Config } from "./r2Adapter.js";
import { openReader } from "./rangeReader.js";

const describeStorageContract = storageContractSuite({
  describe,
  it,
  expect,
  beforeAll,
  afterAll,
});

const cfg: R2Config | null = (() => {
  try {
    return loadR2Config(process.env);
  } catch {
    return null;
  }
})();

/**
 * Wraps an adapter so every contract key lands under `prefix`. put() returns
 * the ORIGINAL (unprefixed) key so contract round-trips via get/head/etc.
 * keep working — those all re-apply the prefix. Every key touched is recorded
 * for cleanup.
 */
function scoped(adapter: StorageAdapter, prefix: string, keys: Set<string>): StorageAdapter {
  const full = (key: string): string => `${prefix}/${key}`;
  return {
    kind: adapter.kind,
    async put(key, body, opts) {
      const k = full(key);
      keys.add(k);
      const result = await adapter.put(k, body, opts);
      return { key, bytes: result.bytes };
    },
    get: (key) => adapter.get(full(key)),
    getBuffer: (key) => adapter.getBuffer(full(key)),
    head: (key) => adapter.head(full(key)),
    delete: (key) => adapter.delete(full(key)),
    presignGet: (key, ttl) => adapter.presignGet(full(key), ttl),
    presignPut: ({ key, ttlSeconds, contentType }) =>
      adapter.presignPut({ key: full(key), ttlSeconds, contentType }),
    readerSpec: (key) => adapter.readerSpec(full(key)),
  };
}

/** Deletes every tracked key, then sweeps the whole prefix for orphans. */
async function cleanup(adapter: StorageAdapter, config: R2Config, prefix: string, keys: Set<string>): Promise<void> {
  for (const key of keys) {
    await adapter.delete(key); // idempotent
  }
  const client = new S3Client({
    region: "auto",
    endpoint: config.endpoint ?? r2Endpoint(config.accountId),
    credentials: {
      accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
    },
  });
  try {
    let token: string | undefined;
    do {
      const list = await client.send(
        new ListObjectsV2Command({
          Bucket: config.bucket,
          Prefix: prefix,
          ContinuationToken: token,
        }),
      );
      const objects = (list.Contents ?? [])
        .map((o) => ({ Key: o.Key }))
        .filter((o): o is { Key: string } => o.Key !== undefined);
      if (objects.length > 0) {
        await client.send(
          new DeleteObjectsCommand({ Bucket: config.bucket, Delete: { Objects: objects } }),
        );
      }
      token = list.IsTruncated ? list.NextContinuationToken : undefined;
    } while (token !== undefined);
  } finally {
    await client.destroy();
  }
}

describeStorageContract.skipIf(cfg === null)("r2-live", async () => {
  const adapter = createR2Storage(cfg!);
  const prefix = `users/_test-${randomUUID()}`;
  const keys = new Set<string>();
  return {
    adapter: scoped(adapter, prefix, keys),
    cleanup: () => cleanup(adapter, cfg!, prefix, keys),
  };
});

/**
 * R2-specific live pins beyond the shared contract body: presigned GET is
 * fetchable (200 + identical bytes) via the global fetcher, and the reader
 * seam (readerSpec → openReader → read(off,len)) returns exact slices over
 * real range GETs. Plus a forced-multipart round-trip with Metadata.sha256.
 */
describe.skipIf(cfg === null)("r2-live — presign fetch, range reader, multipart", () => {
  let adapter: StorageAdapter;
  beforeAll(() => {
    adapter = createR2Storage(cfg!);
  });
  const prefix = `users/_test-${randomUUID()}`;
  const keys = new Set<string>();
  const full = (key: string): string => {
    const k = `${prefix}/${key}`;
    keys.add(k);
    return k;
  };

  afterAll(async () => {
    for (const key of keys) {
      await adapter.delete(key);
    }
  });

  it("presigned GET is fetchable: 200 + identical bytes", async () => {
    const body = Buffer.from("presign-fetch-body-0123456789");
    const key = full("fetch.bin");
    await adapter.put(key, body);
    const url = await adapter.presignGet(key, 300);
    const res = await fetch(url);
    expect(res.status).toBe(200);
    const back = Buffer.from(await res.arrayBuffer());
    expect(back.equals(body)).toBe(true);
  });

  it("presigned PUT accepts an upload: PUT → head/getBuffer round-trip", async () => {
    const body = Buffer.from("presign-put-body-abcdefghij");
    const key = full("put-upload.bin");
    const url = await adapter.presignPut({ key, ttlSeconds: 300 });
    const res = await fetch(url, { method: "PUT", body });
    expect(res.status).toBeLessThan(300);
    const head = await adapter.head(key);
    expect(head).not.toBeNull();
    expect(head!.bytes).toBe(body.length);
    expect((await adapter.getBuffer(key))!.equals(body)).toBe(true);
  });

  it("readerSpec → openReader → size()/read(off,len) exact slice", async () => {
    const data = Buffer.alloc(10_240);
    for (let i = 0; i < data.length; i++) data[i] = i % 251;
    const key = full("range.bin");
    await adapter.put(key, data);
    const spec = await adapter.readerSpec(key);
    expect(spec).not.toBeNull();
    expect(spec!.kind).toBe("r2");
    const reader = await openReader(spec!);
    try {
      expect(await reader.size()).toBe(data.length);
      const got = await reader.read(4096, 100);
      expect(got.equals(data.subarray(4096, 4196))).toBe(true);
      const tail = await reader.read(10_140, 100);
      expect(tail.equals(data.subarray(10_140))).toBe(true);
    } finally {
      await reader.close();
    }
  });

  it("multipart put (partSizeBytes override) round-trips; Metadata.sha256 surfaces via head", async () => {
    const multipart = createR2Storage(cfg!, { partSizeBytes: 5 * 1024 * 1024 });
    const data = Buffer.alloc(6 * 1024 * 1024); // 2 parts: 5 MiB + 1 MiB
    for (let i = 0; i < data.length; i++) data[i] = (i * 7) % 251;
    const key = full("multipart.bin");
    keys.add(key);
    const sha256Hex = createHash("sha256").update(data).digest("hex");
    const { bytes } = await multipart.put(key, data, {
      sha256Hex,
      metadata: { probe: "multipart" },
    });
    expect(bytes).toBe(data.length);
    const head = await multipart.head(key);
    expect(head).not.toBeNull();
    expect(head!.bytes).toBe(data.length);
    expect(head!.sha256Hex).toBe(sha256Hex);
    expect(head!.metadata).toEqual({ probe: "multipart" }); // sha256 stays out of caller metadata
    const back = await multipart.getBuffer(key);
    expect(back!.equals(data)).toBe(true);
  });
});
