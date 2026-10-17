/**
 * Index-free structural recovery (spike §7.1): scanFrames walks the raw zstd
 * frame structure — header (zstdFrames.ts), then every 3-byte block header
 * (Last_Block bit, Block_Type, Block_Size), then the 4-byte xxh64 when the
 * checksum flag is set — from byte 8 to the footer-derived index-frame
 * offset. recoverIndex then decompresses each scanned frame and rebuilds
 * frames[]/files[] from the member streams with re-computed hashes.
 *
 * The footer is trusted for BOUNDARIES only (tail magic + indexFrameLen);
 * the index frame's contents are not (that is the thing being recovered).
 * `createdAt` is unknowable from bytes — the recovered index carries ""
 * (documented); everything else is byte-derived and test-pinned deep-equal
 * to the original modulo that field.
 */

import { createHash } from "node:crypto";

import type { RangeReader } from "../rangeReader.js";
import {
  ARCHIVE_MAGIC,
  ARCHIVE_VERSION,
  ArchiveCorruptError,
  ArchiveTruncatedError,
  FOOTER_LEN,
  FORMAT_NAME,
  ZSTD_LEVEL,
} from "./format.js";
import { decompressFrame, parseMembers } from "./extract.js";
import type { ArchiveIndex, FileRec, FrameRec } from "./pack.js";
import { readFooter } from "./readIndex.js";
import { parseZstdFrameHeader, ZSTD_MAX_HEADER_LEN, ZSTD_MAGIC } from "./zstdFrames.js";

export interface FrameScan {
  offset: number;
  length: number;
  contentSize: number | null;
  checksumFlag: boolean;
}

const CHUNK = 64 * 1024;

/** Buffered sequential cursor over [start, end) backed by a RangeReader. */
class RegionCursor {
  private pos: number;
  private buf: Buffer = Buffer.alloc(0);
  private bufStart = 0;

  constructor(
    private readonly r: RangeReader,
    start: number,
    private readonly end: number,
  ) {
    this.pos = start;
  }

  get offset(): number {
    return this.pos;
  }

  /** Ensures n bytes are buffered at the cursor; false past the region end. */
  private async ensure(n: number): Promise<boolean> {
    if (this.pos + n > this.end) return false;
    const rel = this.pos - this.bufStart;
    if (rel >= 0 && rel + n <= this.buf.length) return true;
    const want = Math.min(Math.max(CHUNK, n), this.end - this.pos);
    this.buf = await this.r.read(this.pos, want);
    this.bufStart = this.pos;
    return true;
  }

  /** Takes n bytes (advancing), or null if the region ends first. */
  async take(n: number): Promise<Buffer | null> {
    if (!(await this.ensure(n))) return null;
    const out = this.buf.subarray(this.pos - this.bufStart, this.pos - this.bufStart + n);
    this.pos += n;
    return out;
  }

  /** Peeks up to n bytes WITHOUT advancing; null if the region ends first. */
  async peek(n: number): Promise<Buffer | null> {
    if (!(await this.ensure(n))) return null;
    return this.buf.subarray(this.pos - this.bufStart, this.pos - this.bufStart + n);
  }

  /** Advances n bytes without reading; false past the region end. */
  async advance(n: number): Promise<boolean> {
    if (this.pos + n > this.end) return false;
    this.pos += n;
    return true;
  }
}

/**
 * Walks the frames region (head magic .. index-frame offset, from footer
 * math). Skippable frames are stepped over by their frame-size field; a
 * frame whose blocks overrun the region is an ArchiveTruncatedError.
 */
export async function scanFrames(r: RangeReader): Promise<FrameScan[]> {
  const size = await r.size();
  const { indexFrameLen } = await readFooter(r);
  const framesEnd = size - FOOTER_LEN - indexFrameLen;
  if (framesEnd < ARCHIVE_MAGIC.length) {
    throw new ArchiveCorruptError(
      `footer indexFrameLen ${indexFrameLen} is inconsistent with archive size ${size}`,
    );
  }
  const head = await r.read(0, ARCHIVE_MAGIC.length);
  if (head.toString("latin1") !== ARCHIVE_MAGIC) {
    throw new ArchiveCorruptError(
      `bad head magic ${JSON.stringify(head.toString("latin1"))} — not an ovid-ws-grouped-v1 archive`,
    );
  }

  const out: FrameScan[] = [];
  const cur = new RegionCursor(r, ARCHIVE_MAGIC.length, framesEnd);
  while (cur.offset < framesEnd) {
    const frameOff = cur.offset;
    const remaining = framesEnd - frameOff;
    const headBuf = (await cur.peek(Math.min(ZSTD_MAX_HEADER_LEN, remaining)))!;
    let h;
    try {
      h = parseZstdFrameHeader(headBuf);
    } catch (err) {
      if (remaining < ZSTD_MAX_HEADER_LEN) {
        throw new ArchiveTruncatedError(
          `frame at ${frameOff} truncated (header needs more than the ${remaining} B left in the frames region)`,
          { cause: err },
        );
      }
      throw err;
    }

    if (h.magic !== ZSTD_MAGIC) {
      // skippable frame: magic | frame_size u32 LE | payload
      await cur.advance(4); // magic
      const sizeBuf = await cur.take(4);
      if (sizeBuf === null) {
        throw new ArchiveTruncatedError(
          `skippable frame at ${frameOff} truncated (frame-size field)`,
        );
      }
      const ok = await cur.advance(sizeBuf.readUInt32LE(0));
      if (!ok) {
        throw new ArchiveTruncatedError(
          `skippable frame at ${frameOff} truncated (payload overruns the frames region)`,
        );
      }
      out.push({
        offset: frameOff,
        length: cur.offset - frameOff,
        contentSize: null,
        checksumFlag: false,
      });
      continue;
    }

    if (!(await cur.advance(h.totalHeaderLen))) {
      throw new ArchiveTruncatedError(`frame at ${frameOff} truncated (frame header)`);
    }
    for (;;) {
      const bh = await cur.take(3);
      if (bh === null) {
        throw new ArchiveTruncatedError(
          `frame at ${frameOff} truncated (block header at ${cur.offset})`,
        );
      }
      const v = bh.readUIntLE(0, 3);
      const last = (v & 1) === 1;
      const type = (v >> 1) & 3;
      const blockSize = v >>> 3;
      if (type === 3) {
        throw new ArchiveCorruptError(
          `frame at ${frameOff}: reserved block type at byte ${cur.offset - 3}`,
        );
      }
      // Raw and Compressed blocks occupy blockSize bytes; an RLE block is a
      // single byte that expands to blockSize copies. (The 3 header bytes
      // were already consumed by take().)
      const consumed = type === 1 ? 1 : blockSize;
      if (!(await cur.advance(consumed))) {
        throw new ArchiveTruncatedError(
          `frame at ${frameOff} truncated (block overruns the frames region)`,
        );
      }
      if (last) break;
    }
    if (h.checksumFlag && !(await cur.advance(4))) {
      throw new ArchiveTruncatedError(
        `frame at ${frameOff} truncated (missing the 4-B xxh64 checksum)`,
      );
    }
    out.push({
      offset: frameOff,
      length: cur.offset - frameOff,
      contentSize: h.contentSize,
      checksumFlag: h.checksumFlag,
    });
  }
  return out;
}

const bytewise = (a: string, b: string): number =>
  Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));

/**
 * Rebuilds an ArchiveIndex purely from archive bytes: scanFrames →
 * decompress every frame → parse member streams → frames[]/files[] with
 * re-computed hashB64. `createdAt` is "" (unknowable); `zstdLevel` is the
 * pinned default. Throws loudly (never returns a garbage index) on any
 * structural violation — the same guarantees as the normal read path.
 */
export async function recoverIndex(r: RangeReader): Promise<ArchiveIndex> {
  const scanned = await scanFrames(r);
  const frames: FrameRec[] = [];
  const files: FileRec[] = [];

  for (let i = 0; i < scanned.length; i++) {
    const f = scanned[i];
    if (f.contentSize === null) {
      throw new ArchiveCorruptError(
        `frame ${i} at byte ${f.offset} carries no Frame_Content_Size — cannot rebuild a v1 index (skippable or foreign frame)`,
      );
    }
    const comp = await r.read(f.offset, f.length);
    const payload = decompressFrame(comp, i, f.contentSize);
    const members = parseMembers(payload);
    for (const m of members) {
      const rec: FileRec = {
        path: m.path,
        type: m.type,
        size:
          m.type === 0
            ? m.contentLen
            : m.type === 2
              ? Buffer.byteLength(m.target, "utf8")
              : 0,
        mode: m.mode,
        mtime: m.mtimeSec,
        frameIndex: i,
        offsetInFrame: m.contentOffset,
        lengthInFrame: m.contentLen,
        hashB64:
          m.type === 0
            ? createHash("sha256")
                .update(payload.subarray(m.contentOffset, m.contentOffset + m.contentLen))
                .digest("base64url")
            : "",
      };
      if (m.type === 2) rec.target = m.target;
      files.push(rec);
    }
    frames.push({
      offset: f.offset,
      length: f.length,
      decSize: payload.length,
      members: members.length,
    });
  }

  files.sort((a, b) => bytewise(a.path, b.path));
  for (let i = 1; i < files.length; i++) {
    if (files[i].path === files[i - 1].path) {
      throw new ArchiveCorruptError(
        `duplicate member path '${files[i].path}' recovered from the frame streams`,
      );
    }
  }

  return {
    archiveVersion: ARCHIVE_VERSION,
    format: FORMAT_NAME,
    zstdLevel: ZSTD_LEVEL,
    createdAt: "",
    frames,
    files,
  };
}
