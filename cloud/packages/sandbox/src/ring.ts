/**
 * Byte-oriented chunk ring for session output (P2 Task 9, spec §6.2): a PTY
 * scrollback and a job output log are both an append-only byte stream with a
 * bounded retained window and offset-based incremental reads.
 *
 * Pinned semantics:
 * - `offset` is the byte position of a chunk's first byte in the session's
 *   LIFETIME stream — a cumulative count that eviction never rewinds.
 * - `push` splits payloads larger than 64 KiB into ≤ 64 KiB chunks.
 * - Eviction drops the OLDEST chunks until the retained window fits capBytes
 *   (a single chunk larger than the cap is kept — the newest data is never
 *   dropped just to satisfy the cap).
 * - `since(k)` delivers every byte at positions ≥ k ("k bytes consumed"):
 *   chunks ending ≤ k are skipped, a chunk straddling k is delivered as its
 *   tail slice, and bytes < k are never re-delivered. `k` below the retained
 *   window sets `truncated` and returns everything still retained.
 * - `data` is base64 so arbitrary binary output survives JSON transports.
 */

/** One retained slice of the session's output stream. */
export interface RingChunk {
  /** Byte position of this chunk's first byte in the lifetime stream. */
  offset: number;
  /** The chunk's bytes, base64-encoded. */
  data: string;
}

export interface SinceResult {
  /** True iff bytes before the returned window were evicted. */
  truncated: boolean;
  chunks: RingChunk[];
  /** The ring's lifetime end offset (see {@link ChunkRing.endOffset}). */
  endOffset: number;
}

export interface ChunkRing {
  /** Appends `data`; chunks > 64 KiB are split. Returns the first chunk. */
  push(data: Buffer): RingChunk;
  /**
   * Incremental read: `null` → everything retained; `offset` = a previous
   * `endOffset` (or any byte count) → only bytes at positions ≥ offset.
   */
  since(offset: number | null): SinceResult;
  /** Lifetime byte count — everything ever pushed, retained or not. */
  readonly endOffset: number;
  /** Retained byte count (≤ capBytes, except a single oversized chunk). */
  readonly byteLength: number;
}

/** The maximum size of a single stored chunk. */
const MAX_CHUNK_BYTES = 64 * 1024;

/** spec §6.2: 256 KB of PTY scrollback per session. */
export const PTY_SCROLLBACK_BYTES = 262_144;
/** Background job output ring per job. */
export const JOB_OUTPUT_RING_BYTES = 1_048_576;

export function createChunkRing(capBytes: number): ChunkRing {
  const chunks: { offset: number; buf: Buffer }[] = [];
  let endOffset = 0; // lifetime bytes
  let byteLength = 0; // retained bytes

  const evict = () => {
    // Never evict the only chunk: dropping the newest data entirely is worse
    // than briefly exceeding the cap (only possible when capBytes < 64 KiB).
    while (chunks.length > 1 && byteLength > capBytes) {
      byteLength -= chunks[0].buf.length;
      chunks.shift();
    }
  };

  return {
    push(data: Buffer): RingChunk {
      if (data.length === 0) {
        return { offset: endOffset, data: "" };
      }
      let first: RingChunk | undefined;
      for (let pos = 0; pos < data.length; pos += MAX_CHUNK_BYTES) {
        const buf = data.subarray(pos, pos + MAX_CHUNK_BYTES);
        const chunk = { offset: endOffset, buf };
        chunks.push(chunk);
        if (first === undefined) first = { offset: chunk.offset, data: buf.toString("base64") };
        endOffset += buf.length;
        byteLength += buf.length;
      }
      evict();
      return first!;
    },

    since(offset: number | null): SinceResult {
      if (chunks.length === 0) {
        return { truncated: false, chunks: [], endOffset };
      }
      const windowStart = chunks[0].offset;
      // null → everything retained from the very beginning (k = 0): identical
      // delivery to since(0), including the truncated flag when history was
      // evicted before the retained window.
      const k = offset ?? 0;
      // k below the retained window: everything before it was evicted.
      const truncated = k < windowStart;

      const out: RingChunk[] = [];
      for (const chunk of chunks) {
        const start = chunk.offset;
        const end = start + chunk.buf.length; // exclusive
        if (end <= k) continue; // fully covered
        if (start >= k) {
          out.push({ offset: start, data: chunk.buf.toString("base64") });
        } else {
          // Straddling k: deliver the tail slice so bytes ≥ k are never lost
          // and bytes < k are never re-delivered.
          const buf = chunk.buf.subarray(k - start);
          out.push({ offset: k, data: buf.toString("base64") });
        }
      }
      return { truncated, chunks: out, endOffset };
    },

    get endOffset(): number {
      return endOffset;
    },

    get byteLength(): number {
      return byteLength;
    },
  };
}
