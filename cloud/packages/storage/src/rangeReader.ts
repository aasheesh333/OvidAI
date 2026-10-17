/**
 * Range readers: pread-style random access over stored objects. The fs branch
 * opens a file descriptor; the R2 branch (real HTTP range GETs) is added in
 * Task 2.
 */

import { open as fsOpen } from "node:fs/promises";

import { StorageError } from "./errors.js";

export interface RangeReader {
  size(): Promise<number>;
  read(offset: number, length: number): Promise<Buffer>;
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

/**
 * Opens a RangeReader for a spec. Only the fs branch exists here; the R2
 * branch (HTTP range GETs with signed requests) lands in Task 2.
 */
export async function openReader(spec: ReaderSpec): Promise<RangeReader> {
  if (spec.kind === "fs") {
    return new FdReader(spec.path);
  }
  throw new StorageError("R2 range reader arrives in Task 2", {
    code: "not_implemented",
  });
}
