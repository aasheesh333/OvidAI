/**
 * OVIDWS-G1 packer — streaming write path (spike §3/§9.1).
 *
 * Layout: ARCHIVE_MAGIC | zstd frames | zstd(index wire JSON) | footer(24B).
 *
 * Grouping policy (pinned):
 * - entries walk in byte-wise path order ("dir" < "dir.x" < "dir/f")
 * - files <= soloMax accumulate into the current group; a payload that would
 *   pass groupMax flushes the frame first (groups never exceed groupMax)
 * - files > soloMax are written immediately as their own single-member frame
 *   WITHOUT touching the pending group (spike bug #2 — flushing on every
 *   solo shatters groups and loses ~1.8 MB of ratio)
 * - dirs and symlinks always ride in groups (content-less members)
 * - hardlinks (nlink > 1) are archived as independent full copies (v1)
 * - files > 2 GiB are rejected (unsupported_size; workspace quotas are <= 2 GB)
 *
 * jobs > 1 compresses frames with async zlib.zstdCompress on the libuv
 * threadpool — byte-identical output to the sync path (spike §4.4); set
 * UV_THREADPOOL_SIZE >= jobs or the extra jobs just queue.
 */

import { createHash } from "node:crypto";
import { once } from "node:events";
import { lstat, readdir, readFile, readlink } from "node:fs/promises";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import type { Writable } from "node:stream";
import * as zlib from "node:zlib";

import type { StorageAdapter } from "../adapter.js";
import { StorageError } from "../errors.js";
import {
  ARCHIVE_END_MAGIC,
  ARCHIVE_MAGIC,
  ARCHIVE_VERSION,
  FOOTER_LEN,
  FORMAT_NAME,
  GROUP_MAX,
  HARD_GROUP_MAX_CEILING,
  MAX_MEMBER_BYTES,
  MEMBER_HEADER_LEN,
  SOLO_MAX,
  ZSTD_LEVEL,
  ArchiveCorruptError,
} from "./format.js";
import { encodeMemberHeader } from "./memberStream.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface FrameRec {
  offset: number;
  length: number;
  decSize: number;
  members: number;
}

export interface FileRec {
  path: string;
  type: 0 | 1 | 2;
  size: number;
  mode: number;
  mtime: number;
  frameIndex: number;
  offsetInFrame: number;
  lengthInFrame: number;
  /** base64url(sha256(content)) for files; "" for dirs and symlinks. */
  hashB64: string;
  /** Symlink target (relative or absolute, never resolved). */
  target?: string;
}

export interface ArchiveIndex {
  archiveVersion: 1;
  format: "ovid-ws-grouped-v1";
  zstdLevel: number;
  createdAt: string;
  frames: FrameRec[];
  files: FileRec[];
}

export interface PackReport {
  bytes: number;
  sha256Hex: string;
  index: ArchiveIndex;
  frames: number;
  files: number;
  dirs: number;
  symlinks: number;
  ms: number;
}

export interface PackOpts {
  level?: number;
  groupMax?: number;
  soloMax?: number;
  /** >1 = async compression on the libuv pool (see file header). */
  jobs?: number;
  now?: () => Date;
}

// ---------------------------------------------------------------------------
// Index wire codec (compact-array JSON, spike §9.1 / §6)
// ---------------------------------------------------------------------------

interface WireIndex {
  archiveVersion: number;
  format: string;
  zstdLevel: number;
  checksumFlag: boolean;
  createdAt: string;
  groupMax: number;
  soloMax: number;
  frames: Array<[number, number, number, number]>;
  files: Array<Array<string | number>>;
}

function isSafeUint(v: unknown): v is number {
  return typeof v === "number" && Number.isSafeInteger(v) && v >= 0;
}

/**
 * Serializes the index as compact arrays. `opts` records the groupMax/soloMax
 * actually used by the packer (the ArchiveIndex object itself does not carry
 * them; defaults are written when omitted).
 */
export function encodeIndexWire(
  index: ArchiveIndex,
  opts?: { groupMax?: number; soloMax?: number },
): Buffer {
  const wire: WireIndex = {
    archiveVersion: index.archiveVersion,
    format: index.format,
    zstdLevel: index.zstdLevel,
    checksumFlag: true,
    createdAt: index.createdAt,
    groupMax: opts?.groupMax ?? GROUP_MAX,
    soloMax: opts?.soloMax ?? SOLO_MAX,
    frames: index.frames.map((f) => [f.offset, f.length, f.decSize, f.members]),
    files: index.files.map((f) => {
      const row: Array<string | number> = [
        f.path,
        f.type,
        f.size,
        f.mode,
        f.mtime,
        f.frameIndex,
        f.offsetInFrame,
        f.lengthInFrame,
        f.hashB64,
      ];
      if (f.target !== undefined) row.push(f.target);
      return row;
    }),
  };
  return Buffer.from(JSON.stringify(wire), "utf8");
}

/** Inverse of encodeIndexWire; throws ArchiveCorruptError on bad shape. */
export function decodeIndexWire(buf: Buffer): ArchiveIndex {
  let parsed: unknown;
  try {
    parsed = JSON.parse(buf.toString("utf8"));
  } catch (err) {
    throw new ArchiveCorruptError("index wire JSON is not parseable", {
      cause: err,
    });
  }
  const corrupt = (why: string): never => {
    throw new ArchiveCorruptError(`index wire is malformed: ${why}`);
  };
  if (typeof parsed !== "object" || parsed === null) throw corrupt("not an object");
  const w = parsed as Record<string, unknown>;

  if (w.archiveVersion !== ARCHIVE_VERSION) {
    throw corrupt(`archiveVersion ${JSON.stringify(w.archiveVersion)} !== ${ARCHIVE_VERSION}`);
  }
  if (w.format !== FORMAT_NAME) throw corrupt(`format ${JSON.stringify(w.format)} !== ${FORMAT_NAME}`);
  if (typeof w.zstdLevel !== "number" || !Number.isFinite(w.zstdLevel)) throw corrupt("zstdLevel is not a number");
  if (typeof w.createdAt !== "string") throw corrupt("createdAt is not a string");
  if (typeof w.checksumFlag !== "boolean") throw corrupt("checksumFlag is not a boolean");
  if (!isSafeUint(w.groupMax)) throw corrupt("groupMax is not a uint");
  if (!isSafeUint(w.soloMax)) throw corrupt("soloMax is not a uint");
  if (!Array.isArray(w.frames)) throw corrupt("frames is not an array");
  if (!Array.isArray(w.files)) throw corrupt("files is not an array");

  const frames: FrameRec[] = w.frames.map((row, i) => {
    if (
      !Array.isArray(row) ||
      row.length !== 4 ||
      !row.every(isSafeUint)
    ) {
      throw corrupt(`frames[${i}] is not [offset, length, decSize, members]`);
    }
    const [offset, length, decSize, members] = row as number[];
    return { offset, length, decSize, members };
  });

  const files: FileRec[] = w.files.map((row, i) => {
    if (!Array.isArray(row) || (row.length !== 9 && row.length !== 10)) {
      throw corrupt(`files[${i}] is not a 9- or 10-element row`);
    }
    const [path, type, size, mode, mtime, frameIndex, offsetInFrame, lengthInFrame, hashB64, target] =
      row as unknown[];
    if (typeof path !== "string" || path.length === 0) throw corrupt(`files[${i}].path is not a non-empty string`);
    if (type !== 0 && type !== 1 && type !== 2) throw corrupt(`files[${i}].type ${JSON.stringify(type)} is not 0|1|2`);
    if (!isSafeUint(size) || !isSafeUint(mode) || !isSafeUint(mtime)) throw corrupt(`files[${i}] has a negative or non-integer size/mode/mtime`);
    if (!isSafeUint(frameIndex) || !isSafeUint(offsetInFrame) || !isSafeUint(lengthInFrame)) {
      throw corrupt(`files[${i}] has a negative or non-integer frame range`);
    }
    if (frameIndex >= frames.length) throw corrupt(`files[${i}].frameIndex ${frameIndex} is out of range`);
    if (typeof hashB64 !== "string") throw corrupt(`files[${i}].hashB64 is not a string`);
    if (row.length === 10 && typeof target !== "string") throw corrupt(`files[${i}].target is not a string`);
    const rec: FileRec = {
      path,
      type,
      size,
      mode,
      mtime,
      frameIndex,
      offsetInFrame,
      lengthInFrame,
      hashB64,
    };
    if (row.length === 10) rec.target = target as string;
    return rec;
  });

  return {
    archiveVersion: ARCHIVE_VERSION,
    format: FORMAT_NAME,
    zstdLevel: w.zstdLevel as number,
    createdAt: w.createdAt as string,
    frames,
    files,
  };
}

// ---------------------------------------------------------------------------
// Workspace walk (shared with uiTree.liveTree)
// ---------------------------------------------------------------------------

export interface WorkspaceEntry {
  /** Relative POSIX path, byte-wise sorted by the walker. */
  path: string;
  type: 0 | 1 | 2;
  /** File bytes; symlink target bytes; 0 for dirs. */
  size: number;
  /** lstat mode & 0o7777. */
  mode: number;
  /** floor(mtimeMs / 1000) — the format stores u32 seconds. */
  mtime: number;
  /** Symlink target (never resolved). */
  target?: string;
  /** Absolute path (files and symlinks; content reads use this). */
  abs: string;
}

/**
 * Recursive walk in byte-wise path order ("dir" < "dir.x" < "dir/f").
 * Never follows symlinks; other node types (fifo/socket/device) are skipped.
 */
export async function walkWorkspace(wsDir: string): Promise<WorkspaceEntry[]> {
  const out: WorkspaceEntry[] = [];
  await walkDir(wsDir, "", out);
  out.sort((a, b) => Buffer.compare(Buffer.from(a.path, "utf8"), Buffer.from(b.path, "utf8")));
  return out;
}

async function walkDir(dir: string, prefix: string, out: WorkspaceEntry[]): Promise<void> {
  const dirents = await readdir(dir, { withFileTypes: true });
  for (const d of dirents) {
    const rel = prefix === "" ? d.name : `${prefix}/${d.name}`;
    const abs = join(dir, d.name);
    // lstat, never follow: symlinked dirs stay symlinks, not descended
    const st = await lstat(abs);
    const mode = st.mode & 0o7777;
    const mtime = Math.floor(st.mtimeMs / 1000);
    if (st.isDirectory()) {
      out.push({ path: rel, type: 1, size: 0, mode, mtime, abs });
      await walkDir(abs, rel, out);
    } else if (st.isFile()) {
      out.push({ path: rel, type: 0, size: st.size, mode, mtime, abs });
    } else if (st.isSymbolicLink()) {
      const target = await readlink(abs);
      out.push({
        path: rel,
        type: 2,
        size: Buffer.byteLength(target, "utf8"),
        mode,
        mtime,
        target,
        abs,
      });
    }
    // fifos, sockets, devices: skipped (v1; a jail workspace has none)
  }
}

// ---------------------------------------------------------------------------
// Pack
// ---------------------------------------------------------------------------

function clampWindowLog(decSize: number): number {
  return Math.min(27, Math.max(17, Math.ceil(Math.log2(Math.max(1, decSize)))));
}

function zstdCompressAsync(
  payload: Buffer,
  params: { [key: number]: number | boolean },
): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    // pledgedSrcSize makes the streaming compressor pledge the Frame_Content_
    // Size — without it the async frame header differs from the sync path
    // (FCS dropped) and the archive is no longer byte-identical across jobs.
    zlib.zstdCompress(
      payload,
      { params, pledgedSrcSize: payload.length },
      (err, out) => {
        if (err) reject(err);
        else resolve(out);
      },
    );
  });
}

/**
 * Packs `wsDir` into `sink`. The sink is NOT ended — the caller owns its
 * lifecycle (packToStorage ends its bridge; the file test ends its stream).
 */
export async function pack(
  wsDir: string,
  sink: Writable,
  opts: PackOpts = {},
): Promise<PackReport> {
  const t0 = Date.now();
  const level = opts.level ?? ZSTD_LEVEL;
  const groupMax = opts.groupMax ?? GROUP_MAX;
  const soloMax = opts.soloMax ?? SOLO_MAX;
  const jobs = Math.max(1, Math.floor(opts.jobs ?? 1));
  const now = opts.now ?? (() => new Date());

  if (!Number.isSafeInteger(groupMax) || groupMax <= 0) {
    throw new StorageError(`groupMax must be a positive integer (got ${groupMax})`, {
      code: "invalid_arg",
    });
  }
  if (groupMax > HARD_GROUP_MAX_CEILING) {
    throw new StorageError(
      `groupMax ${groupMax} exceeds the ${HARD_GROUP_MAX_CEILING} byte hard ceiling — 64 MiB groups fail the extractOne SLA (spike §5.2)`,
      { code: "group_max_ceiling" },
    );
  }
  if (!Number.isSafeInteger(soloMax) || soloMax < 0) {
    throw new StorageError(`soloMax must be a non-negative integer (got ${soloMax})`, {
      code: "invalid_arg",
    });
  }

  const entries = await walkWorkspace(wsDir);

  // Running sha256 over every chunk pushed (spike §7.3) + byte counter.
  const hash = createHash("sha256");
  let bytes = 0;
  // Sink errors surface through the drain race; the no-op catch keeps the
  // rejection from becoming an unhandled one when it fires outside a race.
  const sinkError = once(sink, "error");
  sinkError.catch(() => {});

  async function writeChunk(chunk: Buffer): Promise<void> {
    hash.update(chunk);
    bytes += chunk.length;
    if (!sink.write(chunk)) {
      await Promise.race([once(sink, "drain"), sinkError]);
    }
  }

  const compressFrame = (payload: Buffer): Promise<Buffer> => {
    const params: { [key: number]: number | boolean } = {
      // P6-T3 ruling: the level goes through params (the `level` option is
      // silently ignored by node:zstd).
      [zlib.constants.ZSTD_c_compressionLevel]: level,
      [zlib.constants.ZSTD_c_checksumFlag]: 1,
      [zlib.constants.ZSTD_c_contentSizeFlag]: 1,
      [zlib.constants.ZSTD_c_windowLog]: clampWindowLog(payload.length),
    };
    if (jobs > 1) return zstdCompressAsync(payload, params);
    return Promise.resolve(zlib.zstdCompressSync(payload, { params }));
  };

  // Frame pipeline: submitted in walk order, written strictly FIFO so frame
  // offsets stay sequential; with jobs>1 the threadpool compresses ahead.
  interface FrameJob {
    compressP: Promise<Buffer>;
    decSize: number;
    members: number;
    recs: FileRec[];
  }
  const pendingJobs: FrameJob[] = [];
  let inFlight = 0;
  let cursor = 0;
  let frameCounter = 0;
  const frameRecs: FrameRec[] = [];
  const allRecs: FileRec[] = [];

  async function flushJob(): Promise<void> {
    const job = pendingJobs.shift()!;
    let comp: Buffer;
    try {
      comp = await job.compressP;
    } finally {
      inFlight--;
    }
    await writeChunk(comp);
    frameRecs.push({
      offset: cursor,
      length: comp.length,
      decSize: job.decSize,
      members: job.members,
    });
    for (const rec of job.recs) {
      rec.frameIndex = frameCounter;
      allRecs.push(rec);
    }
    frameCounter++;
    cursor += comp.length;
  }

  async function submitFrame(payload: Buffer, recs: FileRec[]): Promise<void> {
    while (inFlight >= jobs) await flushJob();
    const compressP = compressFrame(payload);
    inFlight++;
    pendingJobs.push({ compressP, decSize: payload.length, members: recs.length, recs });
  }

  // Pending group accumulator — survives across solo frames (spike bug #2).
  let groupParts: Buffer[] = [];
  let groupSize = 0;
  let groupRecs: FileRec[] = [];

  async function flushGroup(): Promise<void> {
    if (groupRecs.length === 0) return;
    const payload =
      groupParts.length === 1 ? groupParts[0] : Buffer.concat(groupParts, groupSize);
    const recs = groupRecs;
    groupParts = [];
    groupSize = 0;
    groupRecs = [];
    await submitFrame(payload, recs);
  }

  async function appendGroupMember(
    e: WorkspaceEntry,
    content: Buffer | null,
  ): Promise<void> {
    const name = Buffer.from(e.path, "utf8");
    const target = e.target === undefined ? Buffer.alloc(0) : Buffer.from(e.target, "utf8");
    const header = encodeMemberHeader({
      nameLen: name.length,
      targetLen: target.length,
      mode: e.mode,
      mtimeSec: e.mtime,
      size: content?.length ?? 0,
      type: e.type,
      flags: 0,
    });
    const memberSize =
      MEMBER_HEADER_LEN + name.length + target.length + (content?.length ?? 0);
    // Groups never exceed groupMax: flush BEFORE appending when it would tip
    // over. (A first member larger than groupMax — only possible with
    // soloMax > groupMax — flushes via the post-append check below.)
    if (groupRecs.length > 0 && groupSize + memberSize > groupMax) {
      await flushGroup();
    }
    const rec: FileRec = {
      path: e.path,
      type: e.type,
      size: e.type === 0 ? content!.length : e.size,
      mode: e.mode,
      mtime: e.mtime,
      frameIndex: -1, // assigned at write time
      offsetInFrame: groupSize + MEMBER_HEADER_LEN + name.length + target.length,
      lengthInFrame: content?.length ?? 0,
      hashB64:
        e.type === 0 && content !== null
          ? createHash("sha256").update(content).digest("base64url")
          : "",
    };
    if (e.target !== undefined) rec.target = e.target;
    groupParts.push(header, name, target, ...(content !== null ? [content] : []));
    groupSize += memberSize;
    groupRecs.push(rec);
    if (groupSize > groupMax) await flushGroup();
  }

  const magicBuf = Buffer.from(ARCHIVE_MAGIC, "latin1");
  // Reject oversize members BEFORE the first byte is written — a failed pack
  // leaves nothing behind in the sink.
  for (const e of entries) {
    if (e.type === 0 && e.size > MAX_MEMBER_BYTES) {
      throw new StorageError(
        `${e.path} is ${e.size} bytes (> 2 GiB) — unsupported in v1 archives (workspace quotas are <= 2 GB)`,
        { code: "unsupported_size" },
      );
    }
  }
  await writeChunk(magicBuf);
  cursor = magicBuf.length;

  for (const e of entries) {
    if (e.type === 0 && e.size > soloMax) {
      // Solo: own single-member frame, immediately; the pending group is
      // deliberately left alone.
      const content = await readFile(e.abs);
      if (content.length > MAX_MEMBER_BYTES) {
        throw new StorageError(`${e.path} grew past 2 GiB mid-pack`, {
          code: "unsupported_size",
        });
      }
      const name = Buffer.from(e.path, "utf8");
      const header = encodeMemberHeader({
        nameLen: name.length,
        targetLen: 0,
        mode: e.mode,
        mtimeSec: e.mtime,
        size: content.length,
        type: 0,
        flags: 0,
      });
      const payload = Buffer.concat([header, name, content]);
      const rec: FileRec = {
        path: e.path,
        type: 0,
        size: content.length,
        mode: e.mode,
        mtime: e.mtime,
        frameIndex: -1,
        offsetInFrame: MEMBER_HEADER_LEN + name.length,
        lengthInFrame: content.length,
        hashB64: createHash("sha256").update(content).digest("base64url"),
      };
      await submitFrame(payload, [rec]);
    } else if (e.type === 0) {
      const content = await readFile(e.abs);
      await appendGroupMember(e, content);
    } else {
      await appendGroupMember(e, null);
    }
  }
  await flushGroup();
  while (pendingJobs.length > 0) await flushJob();

  // Index: compact wire JSON, zstd frame, footer.
  allRecs.sort((a, b) =>
    Buffer.compare(Buffer.from(a.path, "utf8"), Buffer.from(b.path, "utf8")),
  );
  const index: ArchiveIndex = {
    archiveVersion: ARCHIVE_VERSION,
    format: FORMAT_NAME,
    zstdLevel: level,
    createdAt: now().toISOString(),
    frames: frameRecs,
    files: allRecs,
  };
  const indexJson = encodeIndexWire(index, { groupMax, soloMax });
  const indexFrame = await compressFrame(indexJson);
  await writeChunk(indexFrame);

  const indexHash = createHash("sha256").update(indexJson).digest();
  const footer = Buffer.alloc(FOOTER_LEN);
  footer.writeBigUInt64LE(BigInt(indexFrame.length), 0);
  indexHash.copy(footer, 8, 0, 8);
  footer.write(ARCHIVE_END_MAGIC, 16, "latin1");
  await writeChunk(footer);

  let files = 0;
  let dirs = 0;
  let symlinks = 0;
  for (const rec of allRecs) {
    if (rec.type === 0) files++;
    else if (rec.type === 1) dirs++;
    else symlinks++;
  }

  return {
    bytes,
    sha256Hex: hash.digest("hex"),
    index,
    frames: frameRecs.length,
    files,
    dirs,
    symlinks,
    ms: Date.now() - t0,
  };
}

/**
 * Packs straight into a StorageAdapter put-stream through a PassThrough
 * bridge — no temp file (spike §7.3). Verifies the adapter saw exactly the
 * bytes pack produced.
 */
export async function packToStorage(
  wsDir: string,
  storage: StorageAdapter,
  key: string,
  opts: PackOpts = {},
): Promise<PackReport> {
  const bridge = new PassThrough();
  const putP = storage.put(key, bridge, {
    contentType: "application/x-ovid-ws+grouped",
    metadata: { format: FORMAT_NAME },
  });
  let report: PackReport;
  try {
    report = await pack(wsDir, bridge, opts);
    bridge.end();
  } catch (err) {
    bridge.destroy();
    await putP.catch(() => {});
    throw err;
  }
  const put = await putP;
  if (put.bytes !== report.bytes) {
    throw new StorageError(
      `storage.put counted ${put.bytes} bytes for ${key} but pack produced ${report.bytes}`,
      { code: "archive_length_mismatch" },
    );
  }
  return report;
}
