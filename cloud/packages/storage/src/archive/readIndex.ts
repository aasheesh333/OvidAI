/**
 * OVIDWS-G1 index reader — footer + index frame, zero content decompression.
 *
 * Open path (order pinned by the task brief): footer (24 B) -> pread index
 * frame -> zstdDecompressSync (windowLogMax 27) -> verify sha256(indexJson)
 * [0..8] === footer.indexHash -> verify head magic -> decodeIndexWire.
 * Any failure is a typed error — never silent garbage (spike §7.2).
 */

import { createHash } from "node:crypto";
import * as zlib from "node:zlib";

import type { RangeReader } from "../rangeReader.js";
import {
  ARCHIVE_END_MAGIC,
  ARCHIVE_MAGIC,
  FOOTER_LEN,
  ArchiveCorruptError,
  ArchiveTruncatedError,
} from "./format.js";
import { decodeIndexWire, type ArchiveIndex } from "./pack.js";

/**
 * Reads the trailing 24 B: indexFrameLen u64 LE | sha256(indexJson)[0..8] |
 * "OVIDEND1". A bad tail magic means truncation or corruption.
 */
export async function readFooter(
  r: RangeReader,
): Promise<{ indexFrameLen: number; indexHash: Buffer }> {
  const size = await r.size();
  if (size < FOOTER_LEN + ARCHIVE_MAGIC.length) {
    throw new ArchiveTruncatedError(
      `bad tail magic: archive truncated or corrupt (size ${size} cannot hold magic + footer)`,
    );
  }
  const tail = await r.read(size - FOOTER_LEN, FOOTER_LEN);
  if (tail.subarray(16).toString("latin1") !== ARCHIVE_END_MAGIC) {
    throw new ArchiveTruncatedError("bad tail magic: archive truncated or corrupt");
  }
  return {
    indexFrameLen: Number(tail.readBigUInt64LE(0)),
    indexHash: Buffer.from(tail.subarray(8, 16)),
  };
}

/** Footer + index frame + both magic checks + indexHash verification. */
export async function readIndex(r: RangeReader): Promise<ArchiveIndex> {
  const size = await r.size();
  const { indexFrameLen, indexHash } = await readFooter(r);

  const indexOffset = size - FOOTER_LEN - indexFrameLen;
  if (
    !Number.isSafeInteger(indexFrameLen) ||
    indexFrameLen < 0 ||
    indexOffset < ARCHIVE_MAGIC.length
  ) {
    throw new ArchiveCorruptError(
      `index frame length ${indexFrameLen} is inconsistent with archive size ${size}`,
    );
  }

  const comp = await r.read(indexOffset, indexFrameLen);
  let json: Buffer;
  try {
    json = zlib.zstdDecompressSync(comp, {
      params: { [zlib.constants.ZSTD_d_windowLogMax]: 27 },
    });
  } catch (err) {
    throw new ArchiveCorruptError(
      "index frame failed zstd decode (archive corrupt)",
      { cause: err },
    );
  }

  const calc = createHash("sha256").update(json).digest();
  if (!calc.subarray(0, 8).equals(indexHash)) {
    throw new ArchiveCorruptError(
      "index hash mismatch — index frame corrupt",
    );
  }

  const head = await r.read(0, ARCHIVE_MAGIC.length);
  if (head.toString("latin1") !== ARCHIVE_MAGIC) {
    throw new ArchiveCorruptError(
      `bad head magic ${JSON.stringify(head.toString("latin1"))} — not an ovid-ws-grouped-v1 archive`,
    );
  }

  return decodeIndexWire(json);
}

/** Spike §9.2 alias — readIndex IS the manifest read. */
export const manifest: typeof readIndex = readIndex;
