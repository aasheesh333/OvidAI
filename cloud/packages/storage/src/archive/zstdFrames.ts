/**
 * RFC 8878 zstd frame-header parsing (Task 5 read path).
 *
 * Only what the archive reader needs: Frame_Content_Size (the FCS table —
 * spike §8 bug #3), the Content_Checksum_flag, single-segment / window size,
 * and skippable-frame detection. Block walking lives in recover.ts.
 *
 * Frame_Header_Descriptor (1 byte after the magic):
 *   bits 7-6  Frame_Content_Size_flag
 *   bit  5    Single_Segment_flag
 *   bit  4    unused (ignored)
 *   bit  3    reserved (must be 0)
 *   bit  2    Content_Checksum_flag
 *   bits 1-0  Dictionary_ID_flag
 *
 * FCS field size by code: 0 → (singleSegment ? 1 : 0) bytes; 1 → 2 bytes
 * (value = stored + 256); 2 → 4 bytes; 3 → 8 bytes. A frame with code 0 and
 * singleSegment unset carries NO content size (contentSize null).
 */

import { ArchiveCorruptError } from "../errors.js";

/** Little-endian zstd magic number (0xFD2FB528). */
export const ZSTD_MAGIC = 0xfd2fb528;
/** Skippable-frame magic range base: 0x184D2A50 .. 0x184D2A5F. */
export const ZSTD_SKIPPABLE_MAGIC_BASE = 0x184d2a50;
/** The most bytes a zstd frame header can occupy: magic + FHD + window + dictID(4) + FCS(8). */
export const ZSTD_MAX_HEADER_LEN = 4 + 1 + 1 + 4 + 8;

export interface ZstdFrameHeader {
  /** Raw magic (0xFD2FB528 for zstd frames, 0x184D2A50..5F for skippable). */
  magic: number;
  /** Bytes from the frame start to the first block header (skippable: 8). */
  totalHeaderLen: number;
  /** Frame_Content_Size, or null when the frame carries none. */
  contentSize: number | null;
  singleSegment: boolean;
  checksumFlag: boolean;
  /** Window size in bytes (singleSegment: the content size itself), null for skippable. */
  windowSize: number | null;
}

function isSkippable(magic: number): boolean {
  return (magic & 0xfffffff0) === ZSTD_SKIPPABLE_MAGIC_BASE;
}

/**
 * Parses the frame header starting at `offset`. Throws ArchiveCorruptError on
 * an unknown magic, a set reserved bit, or a buffer shorter than the declared
 * header (callers that must distinguish truncation read the boundary first).
 */
export function parseZstdFrameHeader(buf: Buffer, offset = 0): ZstdFrameHeader {
  if (!Buffer.isBuffer(buf) || buf.length < offset + 4) {
    throw new ArchiveCorruptError(
      `zstd frame header at ${offset} needs at least 4 bytes (buffer has ${Math.max(0, buf.length - offset)})`,
    );
  }
  const magic = buf.readUInt32LE(offset);
  if (isSkippable(magic)) {
    // magic | frame_size u32 LE — the payload after 8 bytes is opaque.
    if (buf.length < offset + 8) {
      throw new ArchiveCorruptError(
        `skippable frame header at ${offset} needs 8 bytes (buffer has ${buf.length - offset})`,
      );
    }
    return {
      magic,
      totalHeaderLen: 8,
      contentSize: null,
      singleSegment: false,
      checksumFlag: false,
      windowSize: null,
    };
  }
  if (magic !== ZSTD_MAGIC) {
    throw new ArchiveCorruptError(
      `not a zstd frame: magic 0x${magic.toString(16).padStart(8, "0")} at offset ${offset}`,
    );
  }
  if (buf.length < offset + 5) {
    throw new ArchiveCorruptError(
      `zstd frame header at ${offset} needs at least 5 bytes (buffer has ${buf.length - offset})`,
    );
  }
  const fhd = buf.readUInt8(offset + 4);
  const fcsCode = (fhd >> 6) & 3;
  const singleSegment = ((fhd >> 5) & 1) === 1;
  const reservedBit = ((fhd >> 3) & 1) === 1;
  const checksumFlag = ((fhd >> 2) & 1) === 1;
  const dictIdCode = fhd & 3;
  if (reservedBit) {
    throw new ArchiveCorruptError(
      `zstd frame header at ${offset} has its reserved descriptor bit set`,
    );
  }

  const dictIdLen = [0, 1, 2, 4][dictIdCode];
  const fcsLen = fcsCode === 0 ? (singleSegment ? 1 : 0) : fcsCode === 1 ? 2 : fcsCode === 2 ? 4 : 8;
  const totalHeaderLen = 4 + 1 + (singleSegment ? 0 : 1) + dictIdLen + fcsLen;
  if (buf.length < offset + totalHeaderLen) {
    throw new ArchiveCorruptError(
      `zstd frame header at ${offset} needs ${totalHeaderLen} bytes (buffer has ${buf.length - offset})`,
    );
  }

  let p = offset + 5;
  let windowSize: number | null = null;
  if (!singleSegment) {
    const wd = buf.readUInt8(p);
    p += 1;
    const exponent = wd >>> 3;
    const mantissa = wd & 7;
    const windowLog = 10 + exponent;
    windowSize = 2 ** windowLog + mantissa * 2 ** (windowLog - 3);
  }
  p += dictIdLen;

  let contentSize: number | null = null;
  if (fcsLen === 1) {
    contentSize = buf.readUInt8(p);
  } else if (fcsLen === 2) {
    contentSize = buf.readUInt16LE(p) + 256;
  } else if (fcsLen === 4) {
    contentSize = buf.readUInt32LE(p);
  } else if (fcsLen === 8) {
    contentSize = Number(buf.readBigUInt64LE(p));
  }
  if (singleSegment) {
    // The single segment IS the window; it must be as large as the content.
    windowSize = contentSize;
  }

  return { magic, totalHeaderLen, contentSize, singleSegment, checksumFlag, windowSize };
}
