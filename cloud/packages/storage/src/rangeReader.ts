/**
 * Range readers: pread-style random access over stored objects. The fs branch
 * opens a file descriptor; the R2 branch issues signed HTTP range GETs
 * (R2Reader, Task 2).
 */

import { open as fsOpen } from "node:fs/promises";
import {
  GetObjectCommand,
  HeadObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";

import { NotFoundError, StorageError } from "./errors.js";

export interface RangeReader {
  size(): Promise<number>;
  read(offset: number, length: number): Promise<Buffer>;
  close(): Promise<void>;
}

export type ReaderSpec =
  | { kind: "fs"; path: string }
  | {
      kind: "r2";
      endpoint: string;
      region: string;
      bucket: string;
      key: string;
      accessKeyId: string;
      secretAccessKey: string;
    };

/** fs.open + filehandle.read (pread) — one fd, thread-safe positional reads. */
export class FdReader implements RangeReader {
  private readonly path: string;
  private fh: import("node:fs/promises").FileHandle | null = null;
  private readonly open: Promise<import("node:fs/promises").FileHandle>;

  constructor(path: string) {
    this.path = path;
    this.open = this.openHandle();
  }

  private async openHandle(): Promise<import("node:fs/promises").FileHandle> {
    this.fh = await fsOpen(this.path, "r");
    return this.fh;
  }

  private async handle(): Promise<import("node:fs/promises").FileHandle> {
    return this.fh ?? this.open;
  }

  async size(): Promise<number> {
    const fh = await this.handle();
    return (await fh.stat()).size;
  }

  async read(offset: number, length: number): Promise<Buffer> {
    if (offset < 0 || length < 0) {
      throw new StorageError(`invalid read(${offset}, ${length}) — offsets must be non-negative`);
    }
    const fh = await this.handle();
    const buf = Buffer.alloc(length);
    let read = 0;
    while (read < length) {
      const r = await fh.read(buf, read, length - read, offset + read);
      if (r.bytesRead === 0) {
        throw new StorageError(
          `short read at ${this.path}: wanted ${length} bytes at offset ${offset}, hit EOF after ${read}`,
        );
      }
      read += r.bytesRead;
    }
    return buf;
  }

  async close(): Promise<void> {
    const fh = await this.handle();
    await fh.close();
  }
}

/** HTTP range GETs over an R2 object described by a reader spec. Task 2. */
export class R2Reader implements RangeReader {
  private readonly spec: Extract<ReaderSpec, { kind: "r2" }>;
  private client: S3Client | null = null;
  private sizePromise: Promise<number> | null = null;

  constructor(spec: Extract<ReaderSpec, { kind: "r2" }>) {
    this.spec = spec;
  }

  private s3(): S3Client {
    if (this.client === null) {
      this.client = new S3Client({
        region: this.spec.region,
        endpoint: this.spec.endpoint,
        credentials: {
          accessKeyId: this.spec.accessKeyId,
          secretAccessKey: this.spec.secretAccessKey,
        },
        maxAttempts: 4,
      });
    }
    return this.client;
  }

  async size(): Promise<number> {
    if (this.sizePromise === null) {
      this.sizePromise = (async () => {
        try {
          const res = await this.s3().send(
            new HeadObjectCommand({ Bucket: this.spec.bucket, Key: this.spec.key }),
          );
          return res.ContentLength ?? 0;
        } catch (err) {
          throw new NotFoundError(
            `r2 object vanished before read: ${this.spec.key}`,
            { cause: err },
          );
        }
      })();
    }
    return this.sizePromise;
  }

  async read(offset: number, length: number): Promise<Buffer> {
    if (offset < 0 || length < 0) {
      throw new StorageError(
        `invalid read(${offset}, ${length}) — offsets must be non-negative`,
      );
    }
    if (length === 0) return Buffer.alloc(0);
    const res = await this.s3().send(
      new GetObjectCommand({
        Bucket: this.spec.bucket,
        Key: this.spec.key,
        Range: `bytes=${offset}-${offset + length - 1}`,
      }),
    );
    const body = res.Body as AsyncIterable<unknown> | undefined;
    if (body === undefined) {
      throw new StorageError(
        `r2 read of ${this.spec.key} returned no body (wanted ${length} at ${offset})`,
        { code: "r2_short_read" },
      );
    }
    const chunks: Buffer[] = [];
    let got = 0;
    for await (const chunk of body) {
      const buf = Buffer.from(chunk as Uint8Array);
      chunks.push(buf);
      got += buf.length;
    }
    if (got !== length) {
      throw new StorageError(
        `r2 short read of ${this.spec.key}: wanted ${length} bytes at offset ${offset}, got ${got}`,
        { code: "r2_short_read" },
      );
    }
    return Buffer.concat(chunks, got);
  }

  async close(): Promise<void> {
    this.client?.destroy();
    this.client = null;
  }
}

/**
 * Opens a RangeReader for a spec: fs → FdReader (one fd, positional reads);
 * r2 → R2Reader (signed HTTP range GETs).
 */
export async function openReader(spec: ReaderSpec): Promise<RangeReader> {
  if (spec.kind === "fs") {
    return new FdReader(spec.path);
  }
  return new R2Reader(spec);
}
