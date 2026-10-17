/**
 * R2-backed StorageAdapter — the production backend, speaking Cloudflare R2's
 * S3-compatible API (spec §10).
 *
 * Semantics:
 * - put streams through @aws-sdk/lib-storage's Upload (S3 multipart): small
 *   bodies become a single PutObject, larger ones split at `partSize` with
 *   `queueSize` parts in flight. `leavePartsOnError: false` aborts the
 *   multipart upload on failure — no orphaned invisible parts (the bucket
 *   still gets a 7-day AbortIncompleteMultipartUpload lifecycle rule as
 *   defense in depth; see R2-PROVISIONING.md).
 * - Multipart ETags are NOT object hashes: a caller-supplied `sha256Hex`
 *   travels in `Metadata.sha256` and head() surfaces it again. When the
 *   caller supplies none, head().sha256Hex is null (unlike the dev-only fs
 *   adapter, which computes one — callers that need the hash MUST supply it).
 * - head()/get()/getBuffer() map a missing object (NotFound/NoSuchKey/404) to
 *   null, never throw.
 * - presignGet/presignPut use SigV4 query signing via getSignedUrl —
 *   computed locally, no request. presignPut is ruling R3 / contract 6: the
 *   reusable PUT presigner P8-T3 assumes for attachment uploads.
 * - Keys go through the same assertSafeRelPath layout seam as the fs adapter,
 *   so a hostile key is rejected identically by both backends.
 */

import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { Upload } from "@aws-sdk/lib-storage";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { Transform, type Readable } from "node:stream";

import type { HeadResult, PutOpts, PutResult, StorageAdapter } from "./adapter.js";
import { assertSafeRelPath } from "./keys.js";
import type { ReaderSpec } from "./rangeReader.js";

export interface R2Config {
  accountId: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
  /** Default: the account's S3 endpoint (r2Endpoint). */
  endpoint?: string;
}

/** `https://${accountId}.r2.cloudflarestorage.com` — R2's S3 API endpoint. */
export function r2Endpoint(accountId: string): string {
  return `https://${accountId}.r2.cloudflarestorage.com`;
}

const R2_ENV_VARS = [
  ["OVID_R2_ACCOUNT_ID", "accountId"],
  ["OVID_R2_ACCESS_KEY_ID", "accessKeyId"],
  ["OVID_R2_SECRET_ACCESS_KEY", "secretAccessKey"],
  ["OVID_R2_BUCKET", "bucket"],
] as const;

/**
 * Loads R2Config from the environment. Throws naming the FIRST missing var
 * (in the order above); values never appear in the message. OVID_R2_ENDPOINT
 * optionally overrides the account endpoint (dev/staging pointing at an
 * S3-compatible store).
 */
export function loadR2Config(env: NodeJS.ProcessEnv): R2Config {
  const cfgFields: Record<(typeof R2_ENV_VARS)[number][1], string> = {
    accountId: "",
    accessKeyId: "",
    secretAccessKey: "",
    bucket: "",
  };
  for (const [name, field] of R2_ENV_VARS) {
    const value = env[name];
    if (value === undefined || value === "") {
      throw new Error(`missing required R2 environment variable: ${name}`);
    }
    cfgFields[field] = value;
  }
  const cfg: R2Config = { ...cfgFields };
  const endpoint = env.OVID_R2_ENDPOINT;
  if (endpoint !== undefined && endpoint !== "") {
    cfg.endpoint = endpoint;
  }
  return cfg;
}

/** 8 MiB — spike §7.3: R2 min part 5 MiB, ≤10k parts ⇒ ≤80 GB objects. */
export const R2_PART_SIZE = 8 * 1024 * 1024;
/** In-flight part cap: 2 × 8 MiB ≈ 16 MB RAM per upload. */
export const R2_QUEUE_SIZE = 2;

/** True for the S3 "object absent" family (HeadObject → NotFound, GetObject → NoSuchKey/404). */
function isNotFound(err: unknown): boolean {
  const e = err as { name?: string; $metadata?: { httpStatusCode?: number } };
  return (
    e?.name === "NotFound" ||
    e?.name === "NoSuchKey" ||
    e?.$metadata?.httpStatusCode === 404
  );
}

/** Collects an SDK payload stream into one Buffer. */
async function collectBody(stream: AsyncIterable<unknown>): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of stream) {
    chunks.push(Buffer.from(chunk as Uint8Array));
  }
  return Buffer.concat(chunks);
}

export function createR2Storage(
  cfg: R2Config,
  opts?: { partSizeBytes?: number; queueSize?: number; maxAttempts?: number },
): StorageAdapter {
  const partSize = opts?.partSizeBytes ?? R2_PART_SIZE;
  const queueSize = opts?.queueSize ?? R2_QUEUE_SIZE;
  const endpoint = cfg.endpoint ?? r2Endpoint(cfg.accountId);
  const client = new S3Client({
    region: "auto",
    endpoint,
    credentials: {
      accessKeyId: cfg.accessKeyId,
      secretAccessKey: cfg.secretAccessKey,
    },
    maxAttempts: opts?.maxAttempts ?? 4, // SDK standard-mode retries
  });

  // Same layout seam as the fs adapter — reject before any request.
  const safeKey = (key: string): string => assertSafeRelPath(key);

  async function head(key: string): Promise<HeadResult | null> {
    try {
      const res = await client.send(
        new HeadObjectCommand({ Bucket: cfg.bucket, Key: key }),
      );
      const stored = res.Metadata ?? {};
      // sha256 rides in Metadata but is surfaced as head().sha256Hex, not as
      // caller metadata (matches the fs adapter's sidecar split).
      const metadata: Record<string, string> = { ...stored };
      const sha256Hex = metadata.sha256 ?? null;
      delete metadata.sha256;
      return {
        bytes: res.ContentLength ?? 0,
        sha256Hex,
        etag: res.ETag ?? null,
        metadata,
      };
    } catch (err) {
      if (isNotFound(err)) return null;
      throw err;
    }
  }

  async function getStream(key: string): Promise<Readable | null> {
    try {
      const res = await client.send(
        new GetObjectCommand({ Bucket: cfg.bucket, Key: key }),
      );
      return (res.Body ?? null) as Readable | null;
    } catch (err) {
      if (isNotFound(err)) return null;
      throw err;
    }
  }

  const adapter: StorageAdapter = {
    kind: "r2" as const,

    async put(
      key: string,
      body: NodeJS.ReadableStream | Buffer | Uint8Array,
      putOpts?: PutOpts,
    ): Promise<PutResult> {
      const k = safeKey(key);
      let bytes = 0;
      let uploadBody: Readable | Uint8Array;
      if (body !== null && typeof body !== "string" && typeof (body as Readable).pipe === "function") {
        // Count bytes in a tap so stream puts report `bytes` too (Buffer
        // bodies take the trivial branch below).
        const counting = new Transform({
          transform(chunk: Buffer, _enc, cb) {
            bytes += chunk.length;
            cb(null, chunk);
          },
        });
        uploadBody = (body as Readable).pipe(counting);
      } else {
        uploadBody = body as Uint8Array;
        bytes = uploadBody.byteLength;
      }
      const metadata: Record<string, string> = {};
      if (putOpts?.sha256Hex !== undefined && putOpts.sha256Hex !== "") {
        metadata.sha256 = putOpts.sha256Hex;
      }
      for (const [metaKey, metaValue] of Object.entries(putOpts?.metadata ?? {})) {
        metadata[metaKey.toLowerCase()] = String(metaValue);
      }
      const upload = new Upload({
        client,
        queueSize,
        partSize,
        leavePartsOnError: false,
        params: {
          Bucket: cfg.bucket,
          Key: k,
          Body: uploadBody,
          ContentType: putOpts?.contentType,
          Metadata: metadata,
        },
      });
      await upload.done();
      return { key, bytes };
    },

    async get(key: string): Promise<NodeJS.ReadableStream | null> {
      return getStream(safeKey(key));
    },

    async getBuffer(key: string): Promise<Buffer | null> {
      const stream = await getStream(safeKey(key));
      if (stream === null) return null;
      return collectBody(stream);
    },

    async head(key: string): Promise<HeadResult | null> {
      return head(safeKey(key));
    },

    async delete(key: string): Promise<void> {
      // S3 DELETE of a missing object is 204 — idempotent by construction.
      await client.send(
        new DeleteObjectCommand({ Bucket: cfg.bucket, Key: safeKey(key) }),
      );
    },

    async presignGet(key: string, ttlSeconds: number): Promise<string> {
      const k = safeKey(key);
      return getSignedUrl(
        client,
        new GetObjectCommand({ Bucket: cfg.bucket, Key: k }),
        { expiresIn: ttlSeconds },
      );
    },

    async presignPut(key: string, ttlSeconds: number): Promise<string> {
      const k = safeKey(key);
      return getSignedUrl(
        client,
        new PutObjectCommand({ Bucket: cfg.bucket, Key: k }),
        { expiresIn: ttlSeconds },
      );
    },

    async readerSpec(key: string): Promise<ReaderSpec | null> {
      const k = safeKey(key);
      const h = await head(k);
      if (h === null) return null;
      return {
        kind: "r2",
        endpoint,
        region: "auto",
        bucket: cfg.bucket,
        key: k,
        accessKeyId: cfg.accessKeyId,
        secretAccessKey: cfg.secretAccessKey,
      };
    },
  };
  return adapter;
}
