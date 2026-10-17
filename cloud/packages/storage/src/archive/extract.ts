/**
 * OVIDWS-G1 read path — extractFile / extractOne / extractAll (Task 5).
 *
 * Invariants (spike §9.1 reader invariants + T4 review carries):
 * - The index is UNTRUSTED at read time: member paths are re-validated
 *   (no "..", ".", absolute, empty, or NUL segments) before ANY filesystem
 *   write, and frame records must chain contiguously from the head magic to
 *   the index-frame offset derived from the footer. decodeIndexWire checks
 *   shape, not chaining — the extractor does.
 * - Every decompressed frame is cross-checked against the index's decSize:
 *   node's zstdDecompressSync does NOT error on truncated frames — it
 *   silently returns a partial buffer. The decSize check turns that into a
 *   loud ArchiveTruncatedError.
 * - Member streams are bounds-checked while parsed (nameLen/targetLen/size
 *   must fit the decompressed payload).
 * - extractOne/extractAll file writes are temp + rename; a failed write
 *   leaves no partial destination and no `.part-` leftovers.
 * - extractAll is ALWAYS two-pass: pass 1 creates every directory first
 *   (solo frames precede the group frame that carries parent dirs — frame
 *   order is never assumed to be parent-before-child), pass 2 extracts
 *   disjoint frame ranges. Directory chmod/utimes are deferred to the end so
 *   read-only dir modes cannot block writes into them.
 */

import { createHash } from "node:crypto";
import { mkdir, rename, rm, symlink, utimes, chmod, writeFile } from "node:fs/promises";
import { availableParallelism } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";
import * as zlib from "node:zlib";

import {
  ArchiveCorruptError,
  ArchiveTruncatedError,
  FileNotInArchiveError,
  FileTooLargeError,
  HashMismatchError,
  StorageError,
} from "../errors.js";
import { openReader, type RangeReader, type ReaderSpec } from "../rangeReader.js";
import {
  ARCHIVE_MAGIC,
  FOOTER_LEN,
  MAX_MEMBER_BYTES,
  MEMBER_HEADER_LEN,
} from "./format.js";
import { decodeMemberHeader } from "./memberStream.js";
import type { ArchiveIndex, FileRec, FrameRec } from "./pack.js";
import { readFooter } from "./readIndex.js";

export interface FileContent {
  rec: FileRec;
  bytes: Buffer;
}

export interface ExtractReport {
  files: number;
  bytes: number;
  ms: number;
}

export interface ExtractOpts {
  /** Worker threads for pass 2 (default min(4, availableParallelism-2)). */
  workers?: number;
  /** Restore modes + mtimes (default true). */
  restoreMeta?: boolean;
  /**
   * Worker entry point override (tests/tooling only — production uses the
   * compiled extractWorker.js next to this module; Node's type stripping
   * cannot load the TS source in a worker).
   */
  workerEntry?: string;
}

/** The compiled worker entry, resolved next to this module. */
const DEFAULT_WORKER_ENTRY = fileURLToPath(new URL("./extractWorker.js", import.meta.url));

// ---------------------------------------------------------------------------
// Member-stream parsing + path safety (shared with recover.ts / the worker)
// ---------------------------------------------------------------------------

const MEMBER_PATH_MAX = 4096;

/**
 * A member as parsed out of a decompressed frame payload. `contentOffset`
 * points at the content bytes within the payload.
 */
export interface MemberSlice {
  path: string;
  target: string;
  type: 0 | 1 | 2;
  mode: number;
  mtimeSec: number;
  contentOffset: number;
  contentLen: number;
}

/**
 * Rejects member paths that could escape the extraction root: absolute
 * paths, ".."/."/empty segments, backslashes, NUL bytes, oversized names.
 * POSIX-relative only — exactly what the packer's walker produces.
 */
export function assertSafeMemberPath(path: string): void {
  const bad = (why: string): never => {
    throw new ArchiveCorruptError(`unsafe member path ${JSON.stringify(path)}: ${why}`);
  };
  if (path.length === 0) bad("empty");
  if (path.length > MEMBER_PATH_MAX) bad(`longer than ${MEMBER_PATH_MAX} bytes`);
  if (path.includes("\0")) bad("contains NUL");
  if (path.startsWith("/")) bad("absolute");
  if (path.includes("\\")) bad("contains a backslash");
  for (const seg of path.split("/")) {
    if (seg === "") bad("empty segment");
    if (seg === ".") bad("'.' segment");
    if (seg === "..") bad("'..' segment");
  }
}

/**
 * Parses a self-describing member stream (frame payload), bounds-checking
 * every header field against the payload: nameLen/targetLen must fit, the
 * content must fit, dirs/symlinks must be content-less. Throws
 * ArchiveCorruptError on the first structural violation — never returns a
 * garbage walk.
 */
export function parseMembers(payload: Buffer): MemberSlice[] {
  const out: MemberSlice[] = [];
  const corrupt = (why: string): never => {
    throw new ArchiveCorruptError(`member stream is malformed: ${why}`);
  };
  let off = 0;
  while (off < payload.length) {
    const h = decodeMemberHeader(payload, off);
    if (h.nameLen === 0) corrupt(`member at ${off} has nameLen 0`);
    if (h.type !== 0 && h.size !== 0) {
      corrupt(`dir/symlink member at ${off} carries ${h.size} content bytes`);
    }
    let p = off + MEMBER_HEADER_LEN;
    if (h.nameLen > payload.length - p) {
      corrupt(`nameLen ${h.nameLen} at ${off} overruns the ${payload.length} B payload`);
    }
    const path = payload.subarray(p, p + h.nameLen).toString("utf8");
    p += h.nameLen;
    if (h.targetLen > payload.length - p) {
      corrupt(`targetLen ${h.targetLen} at ${off} overruns the ${payload.length} B payload`);
    }
    const target = h.targetLen > 0 ? payload.subarray(p, p + h.targetLen).toString("utf8") : "";
    p += h.targetLen;
    if (h.type === 2 && h.targetLen === 0) corrupt(`symlink member at ${off} has an empty target`);
    if (h.size > payload.length - p) {
      corrupt(`content size ${h.size} at ${off} overruns the ${payload.length} B payload`);
    }
    assertSafeMemberPath(path);
    if (target.includes("\0")) corrupt(`symlink target at ${off} contains NUL`);
    out.push({
      path,
      target,
      type: h.type,
      mode: h.mode,
      mtimeSec: h.mtimeSec,
      contentOffset: p,
      contentLen: h.size,
    });
    off = p + h.size;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Frame decompression + index validation
// ---------------------------------------------------------------------------

/**
 * Decompresses one frame. zstd failures are wrapped in an
 * ArchiveCorruptError whose message carries the canonical
 * "Data corruption detected" wording plus the library's own message; a
 * decompressed size that disagrees with `expectedDecSize` (the index's
 * record) is an ArchiveTruncatedError — zstdDecompressSync silently returns
 * partial output for truncated frames, so this check is what makes
 * truncation loud.
 */
export function decompressFrame(
  comp: Buffer,
  frameIndex: number,
  expectedDecSize: number | null,
): Buffer {
  let out: Buffer;
  try {
    out = zlib.zstdDecompressSync(comp, {
      params: { [zlib.constants.ZSTD_d_windowLogMax]: 27 },
    });
  } catch (err) {
    throw new ArchiveCorruptError(
      `frame ${frameIndex}: zstd Data corruption detected — ${(err as Error).message}`,
      { cause: err },
    );
  }
  if (expectedDecSize !== null && out.length !== expectedDecSize) {
    throw new ArchiveTruncatedError(
      `frame ${frameIndex} truncated: decompressed ${out.length} B but the index says ${expectedDecSize} B`,
    );
  }
  return out;
}

/** Reads a frame's compressed bytes; a short read means truncation. */
async function readFrameBytes(
  r: RangeReader,
  frame: FrameRec,
  frameIndex: number,
): Promise<Buffer> {
  try {
    return await r.read(frame.offset, frame.length);
  } catch (err) {
    if (
      err instanceof StorageError &&
      (err.code === "storage" || err.code === "r2_short_read")
    ) {
      throw new ArchiveTruncatedError(
        `frame ${frameIndex} at byte ${frame.offset} truncated: ${err.message}`,
        { cause: err },
      );
    }
    throw err;
  }
}

/** Archive size + footer → the byte offset where the index frame starts. */
async function readerBounds(
  r: RangeReader,
): Promise<{ size: number; framesEnd: number }> {
  const size = await r.size();
  const { indexFrameLen } = await readFooter(r);
  const framesEnd = size - FOOTER_LEN - indexFrameLen;
  if (framesEnd < ARCHIVE_MAGIC.length) {
    throw new ArchiveCorruptError(
      `footer indexFrameLen ${indexFrameLen} is inconsistent with archive size ${size}`,
    );
  }
  return { size, framesEnd };
}

/** decSize ceiling: a solo member (2 GiB) plus its header + a long name. */
const FRAME_DEC_CEILING = MAX_MEMBER_BYTES + MEMBER_HEADER_LEN + MEMBER_PATH_MAX;

/**
 * Re-validates the index before any read or write: frames must chain
 * contiguously from the head magic to `framesEnd` (footer-derived), every
 * member path must be safe, and every member's in-frame range must fit its
 * frame. decodeIndexWire checks shape only — this is the chaining/bounds
 * gate the T4 review requires of the extractor.
 */
export function validateIndexForRead(index: ArchiveIndex, framesEnd: number): void {
  let off = ARCHIVE_MAGIC.length;
  index.frames.forEach((f, i) => {
    if (f.offset !== off) {
      throw new ArchiveCorruptError(
        `frames[${i}].offset ${f.offset} breaks the chain (expected ${off})`,
      );
    }
    if (f.length <= 0) throw new ArchiveCorruptError(`frames[${i}].length is ${f.length}`);
    if (f.decSize <= 0) throw new ArchiveCorruptError(`frames[${i}].decSize is ${f.decSize}`);
    if (f.decSize > FRAME_DEC_CEILING) {
      throw new ArchiveCorruptError(
        `frames[${i}].decSize ${f.decSize} exceeds the v1 extraction ceiling ${FRAME_DEC_CEILING}`,
      );
    }
    off += f.length;
  });
  if (off !== framesEnd) {
    throw new ArchiveCorruptError(
      `frame chain ends at ${off} but the footer places the index frame at ${framesEnd}`,
    );
  }
  // A path carried by two frames would make extraction order-dependent (and
  // two threads can race the same `${dest}.part-${pid}` temp name) — reject
  // it up front, mirroring recoverIndex's duplicate check.
  const seenPaths = new Set<string>();
  index.files.forEach((rec, i) => {
    if (seenPaths.has(rec.path)) {
      throw new ArchiveCorruptError(
        `files[${i}] duplicates member path '${rec.path}' across frames`,
      );
    }
    seenPaths.add(rec.path);
    if (rec.frameIndex >= index.frames.length) {
      throw new ArchiveCorruptError(`files[${i}].frameIndex ${rec.frameIndex} is out of range`);
    }
    assertSafeMemberPath(rec.path);
    const frame = index.frames[rec.frameIndex];
    if (rec.offsetInFrame + rec.lengthInFrame > frame.decSize) {
      throw new ArchiveCorruptError(
        `files[${i}] ('${rec.path}') range [${rec.offsetInFrame}, +${rec.lengthInFrame}) exceeds frame ${rec.frameIndex}'s ${frame.decSize} B`,
      );
    }
    if (rec.type === 0) {
      if (rec.size !== rec.lengthInFrame) {
        throw new ArchiveCorruptError(
          `files[${i}] ('${rec.path}') size ${rec.size} != lengthInFrame ${rec.lengthInFrame}`,
        );
      }
      if (rec.size > MAX_MEMBER_BYTES) {
        throw new FileTooLargeError(
          `'${rec.path}' is ${rec.size} bytes (> 2 GiB v1 ceiling)`,
          { sizeBytes: rec.size },
        );
      }
    } else if (rec.type === 2) {
      if (rec.target === undefined || rec.target.length === 0) {
        throw new ArchiveCorruptError(`files[${i}] symlink '${rec.path}' has no target`);
      }
      if (rec.target.includes("\0")) {
        throw new ArchiveCorruptError(`files[${i}] symlink '${rec.path}' target contains NUL`);
      }
    }
  });
}

// ---------------------------------------------------------------------------
// extractFile / extractOne
// ---------------------------------------------------------------------------

/**
 * Returns one file's exact bytes plus its index record. Map lookup on
 * index.files by exact path; one pread of the carrying frame; one
 * zstdDecompressSync guarded by the frame checksum and the decSize
 * cross-check; sha256 must equal rec.hashB64.
 */
export async function extractFile(
  r: RangeReader,
  index: ArchiveIndex,
  path: string,
): Promise<FileContent> {
  const rec = index.files.find((f) => f.path === path);
  if (rec === undefined) {
    throw new FileNotInArchiveError(`'${path}' is not in the archive index`);
  }
  if (rec.type === 1) {
    throw new FileNotInArchiveError(`'${path}' is a directory, not a file`);
  }
  if (rec.type === 2) {
    throw new FileNotInArchiveError(`'${path}' is a symlink, not a file`);
  }
  if (rec.size > MAX_MEMBER_BYTES) {
    throw new FileTooLargeError(`'${path}' is ${rec.size} bytes (> 2 GiB v1 ceiling)`, {
      sizeBytes: rec.size,
    });
  }
  const { framesEnd } = await readerBounds(r);
  validateIndexForRead(index, framesEnd);

  const frame = index.frames[rec.frameIndex];
  const comp = await readFrameBytes(r, frame, rec.frameIndex);
  const payload = decompressFrame(comp, rec.frameIndex, frame.decSize);
  if (rec.offsetInFrame + rec.lengthInFrame > payload.length) {
    throw new ArchiveCorruptError(
      `'${path}' range [${rec.offsetInFrame}, +${rec.lengthInFrame}) exceeds frame ${rec.frameIndex}'s ${payload.length} B payload`,
    );
  }
  const bytes = Buffer.from(
    payload.subarray(rec.offsetInFrame, rec.offsetInFrame + rec.lengthInFrame),
  );
  const sha = createHash("sha256").update(bytes).digest("base64url");
  if (sha !== rec.hashB64) {
    throw new HashMismatchError(
      `HASH MISMATCH for '${path}' — index says ${rec.hashB64}, frame ${rec.frameIndex} yields ${sha}`,
    );
  }
  return { rec, bytes };
}

/**
 * Atomic single-file extract: extractFile, then mkdir -p the parent, write
 * `${dest}.part-${pid}`, chmod, rename over dest, utimes. On ANY error the
 * temp file is removed — dest never exists partially.
 */
export async function extractOne(
  r: RangeReader,
  index: ArchiveIndex,
  path: string,
  dest: string,
): Promise<void> {
  const { rec, bytes } = await extractFile(r, index, path);
  await writeFileAtomic(dest, bytes, rec.mode, rec.mtime, true);
}

// ---------------------------------------------------------------------------
// extractAll — two-pass, parallel frame ranges
// ---------------------------------------------------------------------------

/**
 * Atomic file write used by every extract path: temp file + rename (never a
 * partial destination), optional chmod/utimes. The temp file is removed on
 * any failure.
 */
async function writeFileAtomic(
  dest: string,
  bytes: Buffer,
  mode: number,
  mtimeSec: number,
  restoreMeta: boolean,
): Promise<void> {
  await mkdir(dirname(dest), { recursive: true });
  const tmp = `${dest}.part-${process.pid}`;
  try {
    await writeFile(tmp, bytes);
    if (restoreMeta) await chmod(tmp, mode);
    await rename(tmp, dest);
    if (restoreMeta) await utimes(dest, mtimeSec, mtimeSec);
  } catch (err) {
    await rm(tmp, { force: true });
    throw err;
  }
}

/**
 * Extracts the members of the given frames into destDir. `frames` is a
 * contiguous slice of index.frames starting at `baseFrameIndex`; `recs` are
 * the index records for exactly those frames (any order). Used directly by
 * the in-process path and by each worker thread (via extractWorker.ts).
 *
 * Every member is cross-checked against its index record (path, type, mode,
 * mtime, size, target) and its content sha256 against rec.hashB64. Dirs are
 * skipped here — pass 1 of extractAll has already created them.
 */
export async function extractFrameRange(
  r: RangeReader,
  frames: FrameRec[],
  recs: FileRec[],
  destDir: string,
  restoreMeta: boolean,
  baseFrameIndex = 0,
): Promise<{ files: number; bytes: number }> {
  const byFrame = new Map<number, Map<string, FileRec>>();
  for (const rec of recs) {
    let m = byFrame.get(rec.frameIndex);
    if (m === undefined) {
      m = new Map();
      byFrame.set(rec.frameIndex, m);
    }
    if (m.has(rec.path)) {
      throw new ArchiveCorruptError(`duplicate index record for '${rec.path}'`);
    }
    m.set(rec.path, rec);
  }

  let files = 0;
  let bytes = 0;
  for (let fi = 0; fi < frames.length; fi++) {
    const frame = frames[fi];
    const abs = baseFrameIndex + fi;
    const recMap = byFrame.get(abs) ?? new Map<string, FileRec>();
    const comp = await readFrameBytes(r, frame, abs);
    const payload = decompressFrame(comp, abs, frame.decSize);
    const members = parseMembers(payload);
    if (members.length !== frame.members) {
      throw new ArchiveCorruptError(
        `frame ${abs} carries ${members.length} members but the index says ${frame.members}`,
      );
    }
    for (const m of members) {
      const rec = recMap.get(m.path);
      if (rec === undefined) {
        throw new ArchiveCorruptError(
          `frame ${abs} carries member '${m.path}' that the index does not know`,
        );
      }
      recMap.delete(m.path);
      if (
        rec.type !== m.type ||
        rec.mode !== m.mode ||
        rec.mtime !== m.mtimeSec ||
        rec.offsetInFrame !== m.contentOffset ||
        rec.lengthInFrame !== m.contentLen ||
        (m.type === 2 && rec.target !== m.target)
      ) {
        throw new ArchiveCorruptError(
          `frame ${abs} member '${m.path}' disagrees with its index record`,
        );
      }
      const dest = join(destDir, m.path);
      if (m.type === 1) continue; // pass 1 created every dir
      if (m.type === 0) {
        const content = payload.subarray(m.contentOffset, m.contentOffset + m.contentLen);
        const sha = createHash("sha256").update(content).digest("base64url");
        if (sha !== rec.hashB64) {
          throw new HashMismatchError(
            `HASH MISMATCH for '${m.path}' — index says ${rec.hashB64}, frame ${abs} yields ${sha}`,
          );
        }
        await writeFileAtomic(dest, Buffer.from(content), m.mode, m.mtimeSec, restoreMeta);
        files++;
        bytes += m.contentLen;
      } else {
        await rm(dest, { force: true });
        await symlink(m.target, dest);
        files++;
      }
    }
    if (recMap.size > 0) {
      const [path] = recMap.keys();
      throw new ArchiveCorruptError(
        `index claims member '${path}' in frame ${abs} but the frame does not carry it`,
      );
    }
  }
  return { files, bytes };
}

/** Every directory that must exist before pass 2: dir members + parents. */
function dirPathsFor(files: FileRec[]): string[] {
  const dirs = new Set<string>();
  const addAncestors = (path: string): void => {
    const segs = path.split("/");
    for (let i = 1; i < segs.length; i++) dirs.add(segs.slice(0, i).join("/"));
  };
  for (const rec of files) {
    if (rec.type === 1) dirs.add(rec.path);
    addAncestors(rec.path);
  }
  dirs.delete("");
  return [...dirs].sort((a, b) =>
    Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8")),
  );
}

/** Deferred directory metadata — applied only after every write has landed. */
async function restoreDirMeta(destDir: string, files: FileRec[]): Promise<void> {
  for (const rec of files) {
    if (rec.type !== 1) continue;
    const dest = join(destDir, rec.path);
    await utimes(dest, rec.mtime, rec.mtime);
    await chmod(dest, rec.mode);
  }
}

/** Shared prologue/epilogue of both extractAll paths. */
async function runExtraction(
  spec: ReaderSpec,
  index: ArchiveIndex,
  destDir: string,
  restoreMeta: boolean,
  extract: () => Promise<{ files: number; bytes: number }>,
): Promise<ExtractReport> {
  const t0 = Date.now();
  {
    const r = await openReader(spec);
    try {
      const { framesEnd } = await readerBounds(r);
      validateIndexForRead(index, framesEnd);
    } finally {
      await r.close();
    }
  }
  // Pass 1: ALL dirs, path-sorted, default modes (chmod/utimes deferred).
  await mkdir(destDir, { recursive: true });
  for (const d of dirPathsFor(index.files)) {
    await mkdir(join(destDir, d), { recursive: true });
  }
  // Pass 2 (caller): disjoint frame ranges, order-independent by construction.
  const { files, bytes } = await extract();
  if (restoreMeta) await restoreDirMeta(destDir, index.files);
  return { files, bytes, ms: Date.now() - t0 };
}

/** Single-reader sequential extractAll (the workers=1 path). */
export async function extractAllInProcess(
  spec: ReaderSpec,
  index: ArchiveIndex,
  destDir: string,
  opts: { restoreMeta?: boolean } = {},
): Promise<ExtractReport> {
  const restoreMeta = opts.restoreMeta ?? true;
  return runExtraction(spec, index, destDir, restoreMeta, async () => {
    const r = await openReader(spec);
    try {
      return await extractFrameRange(r, index.frames, index.files, destDir, restoreMeta, 0);
    } finally {
      await r.close();
    }
  });
}

/** Rebuilds a typed error from a worker's {code, message} report. */
function mapWorkerError(e: { code: string; message: string }): Error {
  switch (e.code) {
    case "archive_corrupt":
      return new ArchiveCorruptError(e.message);
    case "archive_truncated":
      return new ArchiveTruncatedError(e.message);
    case "hash_mismatch":
      return new HashMismatchError(e.message);
    case "file_not_in_archive":
      return new FileNotInArchiveError(e.message);
    case "file_too_large":
      return new FileTooLargeError(e.message, { sizeBytes: 0 });
    default:
      return new StorageError(e.message, { code: e.code });
  }
}

/** Splits `total` frames into at most `workers` contiguous ranges. */
function partition(total: number, workers: number): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  for (let i = 0; i < workers; i++) {
    const start = Math.floor((i * total) / workers);
    const end = Math.floor(((i + 1) * total) / workers);
    if (end > start) out.push([start, end]);
  }
  return out;
}

/**
 * Parallel extractAll: pass 1 creates every directory; pass 2 hands each
 * worker thread a disjoint contiguous frame range — each opens its OWN
 * reader via openReader(spec), decompresses its frames, and writes its
 * members (files via temp+rename, symlinks via symlink()). Any thread error
 * terminates all threads and rejects with the typed error; the partial tree
 * is deliberately left for the caller to wipe and retry.
 */
export async function extractAll(
  spec: ReaderSpec,
  index: ArchiveIndex,
  destDir: string,
  opts: ExtractOpts = {},
): Promise<ExtractReport> {
  const workers = opts.workers ?? Math.min(4, Math.max(1, availableParallelism() - 2));
  const restoreMeta = opts.restoreMeta ?? true;
  if (workers <= 1 || index.frames.length <= 1) {
    return extractAllInProcess(spec, index, destDir, { restoreMeta });
  }
  const entry = opts.workerEntry ?? DEFAULT_WORKER_ENTRY;

  return runExtraction(spec, index, destDir, restoreMeta, async () => {
    const ranges = partition(index.frames.length, Math.min(workers, index.frames.length));
    const threads: Worker[] = [];
    try {
      const reports = await Promise.all(
        ranges.map(([start, end]) => {
          const frameRecs = index.frames.slice(start, end);
          const fileRecs = index.files.filter(
            (f) => f.frameIndex >= start && f.frameIndex < end,
          );
          return new Promise<{ files: number; bytes: number }>((resolve, reject) => {
            const w = new Worker(entry, {
              workerData: {
                spec,
                destDir,
                restoreMeta,
                frames: frameRecs,
                recs: fileRecs,
                baseFrameIndex: start,
              },
            });
            threads.push(w);
            let settled = false;
            const settle = (fn: () => void): void => {
              if (settled) return;
              settled = true;
              fn();
            };
            w.on("message", (m: { error?: { code: string; message: string } }) => {
              settle(() => {
                if (m?.error !== undefined) reject(mapWorkerError(m.error));
                else resolve(m as { files: number; bytes: number });
              });
            });
            w.on("error", (err) => settle(() => reject(err)));
            w.on("exit", (code) =>
              settle(() =>
                reject(
                  new StorageError(
                    `archive extract worker (frames ${start}..${end}) exited with code ${code}`,
                    { code: "archive_worker_exit" },
                  ),
                ),
              ),
            );
          });
        }),
      );
      return reports.reduce(
        (acc, rep) => ({ files: acc.files + rep.files, bytes: acc.bytes + rep.bytes }),
        { files: 0, bytes: 0 },
      );
    } finally {
      for (const w of threads) void w.terminate();
    }
  });
}
