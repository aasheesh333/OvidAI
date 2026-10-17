/**
 * Pinned constants for the `ovid-ws-grouped-v1` archive format (OVIDWS-G1).
 *
 * Byte layout is binding — spike §9.1 verbatim:
 *
 *   0x00  magic    "OVIDWS01"                        8 B
 *   0x08  frames   zstd frames back-to-back (level 9, xxh64 checksum ON,
 *                  FCS ON, windowLog = clamp(ceil(log2(decSize)), 17, 27));
 *                  payload = self-describing member stream (memberStream.ts)
 *   end-1 index    compact-array JSON, zstd-9 single frame, UTF-8
 *   end   footer   indexFrameLen u64 LE | sha256(indexJson)[0..8] | "OVIDEND1"
 */

import { ArchiveCorruptError, ArchiveTruncatedError } from "../errors.js";

export {
  /** Archive bytes fail a structural check (code "archive_corrupt"). */
  ArchiveCorruptError,
  /** Archive is shorter than its own footer (code "archive_truncated"). */
  ArchiveTruncatedError,
};

export const ARCHIVE_MAGIC = "OVIDWS01";
export const ARCHIVE_END_MAGIC = "OVIDEND1";
export const FORMAT_NAME = "ovid-ws-grouped-v1";
export const ARCHIVE_VERSION = 1;
/** G7: level 9. L19 = 6.7x pack time for -18% bytes — keep 9 (spike §4.5). */
export const ZSTD_LEVEL = 9;
/** 4 MiB group sweet spot; the extractOne SLA dial (spike §5.2). */
export const GROUP_MAX = 4 * 1024 * 1024;
export const SOLO_MAX = 256 * 1024;
/** NEVER exceed 16 MiB groups — 64 MiB groups fail the extractOne SLA. */
export const HARD_GROUP_MAX_CEILING = 16 * 1024 * 1024;
export const FOOTER_LEN = 24;
export const MEMBER_HEADER_LEN = 32;

/**
 * Workspace quotas are <= 2 GB, so no single member may exceed 2 GiB
 * (v1 edge — larger members would need a streaming ZstdCompress pass).
 */
export const MAX_MEMBER_BYTES = 2 * 1024 * 1024 * 1024;
