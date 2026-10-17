/**
 * fs-backed StorageAdapter — tests/dev only.
 *
 * Semantics:
 * - key → path.join(rootDir, key) AFTER a per-segment assertSafeSegment pass
 *   (a traversal key can never escape the root).
 * - put streams through a pipeline into `${path}.part-${pid}` and renames —
 *   atomic: a torn write is never visible under the final key.
 * - sha256 is computed while streaming and persisted in a `${path}.sha256`
 *   sidecar; metadata in `${path}.meta.json`; both re-surfaced by head().
 * - presignGet/presignPut return `file://` pseudo-URLs with an expiry stamp
 *   — documented NOT capability URLs. In fs mode uploads go through put();
 *   only the R2 adapter signs real GET/PUT URLs (Task 2).
 */

import { createHash } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, open as fsOpen, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { pipeline } from "node:stream/promises";
import { Readable, Transform } from "node:stream";

import type { PutOpts, PutResult, HeadResult, StorageAdapter } from "./adapter.js";
import { KeyLayoutError } from "./errors.js";
import { assertSafeRelPath } from "./keys.js";
import type { ReaderSpec } from "./rangeReader.js";

function keyToPath(rootDir: string, key: string): string {
  // assertSafeRelPath rejects traversal, absolute, control chars, and
  // re-asserts every segment — then returns the normalized relative path.
  const rel = assertSafeRelPath(key);
  return join(rootDir, rel);
}

async function exists(p: string): Promise<boolean> {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

/** Reads a small sidecar file as UTF-8 text, or null when absent. */
async function readSidecar(p: string): Promise<string | null> {
  try {
    const fh = await fsOpen(p, "r");
    try {
      const size = (await fh.stat()).size;
      const buf = Buffer.alloc(size);
      await fh.read(buf, 0, size, 0);
      return buf.toString("utf8");
    } finally {
      await fh.close();
    }
  } catch {
    return null;
  }
}

export function createFsStorage(rootDir: string): StorageAdapter {
  const adapter: StorageAdapter = {
    kind: "fs" as const,

    async put(
      key: string,
      body: NodeJS.ReadableStream | Buffer | Uint8Array,
      opts?: PutOpts,
    ): Promise<PutResult> {
      const path = keyToPath(rootDir, key);
      const partPath = `${path}.part-${process.pid}`;
      const source: Readable = Buffer.isBuffer(body)
        ? Readable.from(body)
        : body instanceof Uint8Array
          ? Readable.from(Buffer.from(body))
          : (body as Readable);
      const hash = createHash("sha256");
      let bytes = 0;
      // count + hash in a Transform so the tap composes with pipeline()
      const counting = new Transform({
        transform(chunk: Buffer, _enc, cb) {
          hash.update(chunk);
          bytes += chunk.length;
          cb(null, chunk);
        },
      });

      await mkdir(dirname(path), { recursive: true });
      try {
        await pipeline(source, counting, createWriteStream(partPath));
        await rename(partPath, path);
      } catch (err) {
        // The .part- file stays on disk for postmortem (brief pin: interrupted
        // put leaves no final object, only a .part- file). It is never visible
        // under the final key — the rename below is the only commit point.
        throw err;
      }
      // sidecars AFTER the object is atomically in place
      const sha256Hex = opts?.sha256Hex ?? hash.digest("hex");
      await rm(`${path}.sha256`, { force: true });
      await writeFile(`${path}.sha256`, sha256Hex, "utf8");
      if (opts?.metadata) {
        await writeFile(`${path}.meta.json`, JSON.stringify(opts.metadata), "utf8");
      } else {
        await rm(`${path}.meta.json`, { force: true });
      }
      return { key, bytes };
    },

    async get(key: string): Promise<NodeJS.ReadableStream | null> {
      const path = keyToPath(rootDir, key);
      if (!(await exists(path))) return null;
      return createReadStream(path);
    },

    async getBuffer(key: string): Promise<Buffer | null> {
      const path = keyToPath(rootDir, key);
      try {
        const fh = await fsOpen(path, "r");
        try {
          const size = (await fh.stat()).size;
          const buf = Buffer.alloc(size);
          let read = 0;
          while (read < size) {
            const r = await fh.read(buf, read, size - read, read);
            if (r.bytesRead === 0) break;
            read += r.bytesRead;
          }
          return read === size ? buf : buf.subarray(0, read);
        } finally {
          await fh.close();
        }
      } catch {
        return null;
      }
    },

    async head(key: string): Promise<HeadResult | null> {
      const path = keyToPath(rootDir, key);
      let size: number;
      try {
        size = (await stat(path)).size;
      } catch {
        return null;
      }
      const sha256Hex = await readSidecar(`${path}.sha256`);
      let metadata: Record<string, string> = {};
      const metaRaw = await readSidecar(`${path}.meta.json`);
      if (metaRaw !== null) {
        try {
          metadata = JSON.parse(metaRaw) as Record<string, string>;
        } catch {
          metadata = {};
        }
      }
      return {
        bytes: size,
        sha256Hex,
        // dev-only adapter: an fs-safe stand-in etag (size+hash prefix)
        etag: sha256Hex === null ? null : `"${sha256Hex.slice(0, 16)}-${size}"`,
        metadata,
      };
    },

    async delete(key: string): Promise<void> {
      const path = keyToPath(rootDir, key);
      await rm(path, { force: true }); // idempotent
      await rm(`${path}.sha256`, { force: true });
      await rm(`${path}.meta.json`, { force: true });
    },

    async presignGet(key: string, ttlSeconds: number): Promise<string> {
      const path = keyToPath(rootDir, key);
      const exp = Math.floor(Date.now() / 1000) + ttlSeconds;
      return `file://${path}#ovid-exp=${exp}`;
    },

    async presignPut(key: string, ttlSeconds: number): Promise<string> {
      const path = keyToPath(rootDir, key);
      const exp = Math.floor(Date.now() / 1000) + ttlSeconds;
      return `file://${path}#ovid-exp=${exp}`;
    },

    async readerSpec(key: string): Promise<ReaderSpec | null> {
      const path = keyToPath(rootDir, key);
      if (!(await exists(path))) return null;
      return { kind: "fs", path };
    },
  };
  return adapter;
}

// Re-export so callers importing the constructor from fsAdapter get the
// layout error too (put() throws it on traversal keys).
export { KeyLayoutError };
