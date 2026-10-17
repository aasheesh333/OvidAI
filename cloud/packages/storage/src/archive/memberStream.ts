/**
 * Member stream — the self-describing frame payload of OVIDWS-G1.
 *
 * member := header32 | name | target | content
 *
 * header32 (LE): nameLen u32 | targetLen u32 | mode u32 | mtimeSec u32 |
 *                size u64 | type u8 (0=file, 1=dir, 2=symlink) |
 *                flags u8 | rsv u8[6] (must be zero)
 *
 * `size` counts the CONTENT bytes only: file length for files, 0 for dirs
 * (no content) and 0 for symlinks (the target rides in the `target` field).
 * `targetLen` is non-zero only for symlinks. flags bit0 is reserved for
 * future ns-precision mtime.
 */

import { ArchiveCorruptError, MEMBER_HEADER_LEN } from "./format.js";

export interface MemberHeader {
  nameLen: number;
  targetLen: number;
  mode: number;
  mtimeSec: number;
  size: number;
  type: 0 | 1 | 2;
  flags: number;
}

/** Encodes exactly 32 bytes (size as u64 LE — identical to BigInt64LE for our range). */
export function encodeMemberHeader(h: MemberHeader): Buffer {
  const buf = Buffer.alloc(MEMBER_HEADER_LEN);
  buf.writeUInt32LE(h.nameLen >>> 0, 0);
  buf.writeUInt32LE(h.targetLen >>> 0, 4);
  buf.writeUInt32LE(h.mode >>> 0, 8);
  buf.writeUInt32LE(h.mtimeSec >>> 0, 12);
  buf.writeBigUInt64LE(BigInt(h.size), 16);
  buf.writeUInt8(h.type & 0xff, 24);
  buf.writeUInt8(h.flags & 0xff, 25);
  // bytes 26..31: rsv — zero from alloc
  return buf;
}

export function decodeMemberHeader(buf: Buffer, offset = 0): MemberHeader {
  if (!Buffer.isBuffer(buf) || buf.length < offset + MEMBER_HEADER_LEN) {
    throw new ArchiveCorruptError(
      `member header needs ${MEMBER_HEADER_LEN} bytes at offset ${offset} (buffer has ${buf.length})`,
    );
  }
  for (let i = 26; i < MEMBER_HEADER_LEN; i++) {
    if (buf[offset + i] !== 0) {
      throw new ArchiveCorruptError(
        `member header reserved byte ${i} is non-zero (offset ${offset})`,
      );
    }
  }
  const type = buf.readUInt8(offset + 24);
  if (type > 2) {
    throw new ArchiveCorruptError(
      `member header type ${type} is not 0 (file), 1 (dir) or 2 (symlink)`,
    );
  }
  return {
    nameLen: buf.readUInt32LE(offset),
    targetLen: buf.readUInt32LE(offset + 4),
    mode: buf.readUInt32LE(offset + 8),
    mtimeSec: buf.readUInt32LE(offset + 12),
    size: Number(buf.readBigUInt64LE(offset + 16)),
    type: type as 0 | 1 | 2,
    flags: buf.readUInt8(offset + 25),
  };
}
