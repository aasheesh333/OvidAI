import { describe, expect, it } from "vitest";
import { createChunkRing } from "./ring.js";

/**
 * Portable ChunkRing tests (Task 9 Step 1). Semantics pinned here:
 * - `offset` is the byte position of a chunk's first byte in the session's
 *   LIFETIME stream (cumulative byte count, never rewound by eviction).
 * - `since(k)` delivers every byte at positions >= k (k = "bytes consumed");
 *   chunks fully covered (ending <= k) are excluded and bytes < k are never
 *   re-delivered; a chunk straddling k is delivered as its tail slice.
 * - `since(null)` returns everything still retained; `truncated` is true iff
 *   bytes before the retained window have been evicted.
 * - Pushes larger than 64 KiB split into <= 64 KiB chunks.
 * - Eviction drops the OLDEST chunks beyond capBytes.
 */

const KIB = 1024;

function decode(chunks: { data: string }[]): string {
  return chunks.map((c) => Buffer.from(c.data, "base64").toString("utf8")).join("");
}

function reassemble(chunks: { data: string }[]): Buffer {
  return Buffer.concat(chunks.map((c) => Buffer.from(c.data, "base64")));
}

describe("ChunkRing — push/since ordering", () => {
  it("offsets are cumulative byte counts; since(null) returns everything in order", () => {
    const ring = createChunkRing(4 * KIB);
    const c1 = ring.push(Buffer.from("aa"));
    expect(c1.offset).toBe(0);
    const c2 = ring.push(Buffer.from("bbb"));
    expect(c2.offset).toBe(2);
    expect(ring.endOffset).toBe(5);
    expect(ring.byteLength).toBe(5);

    const all = ring.since(null);
    expect(all.truncated).toBe(false);
    expect(all.endOffset).toBe(5);
    expect(all.chunks.map((c) => c.offset)).toEqual([0, 2]);
    expect(decode(all.chunks)).toBe("aabbb");
  });

  it("since(k) excludes chunks ending ≤ k and never duplicates covered bytes", () => {
    const ring = createChunkRing(4 * KIB);
    ring.push(Buffer.from("aa")); // [0,2)
    ring.push(Buffer.from("bb")); // [2,4)
    ring.push(Buffer.from("cc")); // [4,6)

    // k=4: everything ending ≤ 4 is covered → only the [4,6) chunk remains.
    expect(ring.since(4).chunks.map((c) => c.offset)).toEqual([4]);
    // k=2: the [2,4) chunk starts AT the first uncovered byte — delivered whole.
    expect(ring.since(2).chunks.map((c) => c.offset)).toEqual([2, 4]);
    // k at the very end: nothing left, and not truncated.
    expect(ring.since(6)).toEqual({ truncated: false, chunks: [], endOffset: 6 });
    // k beyond the end: same.
    expect(ring.since(99)).toEqual({ truncated: false, chunks: [], endOffset: 6 });
  });

  it("a chunk straddling k is delivered as its tail slice — covered bytes never re-delivered", () => {
    const ring = createChunkRing(4 * KIB);
    ring.push(Buffer.from("abcdef")); // one chunk [0,6)
    const s = ring.since(3); // bytes 0..2 covered; 3..5 uncovered
    expect(s.truncated).toBe(false);
    expect(s.chunks).toEqual([{ offset: 3, data: Buffer.from("def").toString("base64") }]);
    expect(s.endOffset).toBe(6);
  });

  it("repeated polling with the returned endOffset never re-delivers a byte", () => {
    const ring = createChunkRing(4 * KIB);
    ring.push(Buffer.from("one-"));
    ring.push(Buffer.from("two-"));
    ring.push(Buffer.from("three"));
    let seen = "";
    let cursor: number | null = null;
    for (let i = 0; i < 3; i++) {
      const res = ring.since(cursor);
      seen += decode(res.chunks);
      cursor = res.endOffset;
    }
    expect(seen).toBe("one-two-three");
    expect(cursor).toBe(ring.endOffset);
  });
});

describe("ChunkRing — eviction", () => {
  it("cap 100 B, push 3×60 B → byteLength ≤ 100; since(0) is truncated with only retained chunks", () => {
    const ring = createChunkRing(100);
    const push = (byte: number) => ring.push(Buffer.alloc(60, byte));
    push(0x31); // "1"
    push(0x32); // "2"
    push(0x33); // "3"
    expect(ring.byteLength).toBeLessThanOrEqual(100);
    expect(ring.endOffset).toBe(180); // lifetime count never rewound

    const s = ring.since(0);
    expect(s.truncated).toBe(true);
    expect(s.endOffset).toBe(180);
    expect(s.chunks.length).toBeGreaterThan(0);
    // Only retained chunks: every chunk starts inside the retained window and
    // the retained bytes are the TAIL of the lifetime stream (the "3" push).
    const buf = reassemble(s.chunks);
    expect(buf.length).toBe(ring.byteLength);
    expect(buf.length).toBe(60);
    expect(buf[0]).toBe(0x33);
    expect(buf.every((b) => b === 0x33)).toBe(true);
  });

  it("evicts the OLDEST chunks first — only the newest push survives", () => {
    const ring = createChunkRing(100);
    ring.push(Buffer.alloc(60, 0x31));
    const mid = ring.since(null); // everything is retained here
    expect(mid.truncated).toBe(false);
    ring.push(Buffer.alloc(60, 0x32));
    const s = ring.since(null);
    expect(s.truncated).toBe(true);
    expect(reassemble(s.chunks).every((b) => b === 0x32)).toBe(true);
  });
});

describe("ChunkRing — chunk splitting", () => {
  it("a 128 KiB single push splits into ≤64 KiB chunks with contiguous offsets", () => {
    const ring = createChunkRing(1024 * KIB);
    const big = Buffer.alloc(128 * KIB, 0x42);
    ring.push(big);
    const all = ring.since(null);
    expect(all.chunks.length).toBe(2);
    for (const c of all.chunks) {
      expect(Buffer.from(c.data, "base64").length).toBeLessThanOrEqual(64 * KIB);
    }
    expect(all.chunks[0].offset).toBe(0);
    expect(all.chunks[1].offset).toBe(64 * KIB);
    // Contiguous: reassembling the chunks reproduces the original buffer.
    expect(reassemble(all.chunks).equals(big)).toBe(true);
    expect(ring.endOffset).toBe(128 * KIB);
    expect(ring.byteLength).toBe(128 * KIB);
  });
});

describe("ChunkRing — binary safety", () => {
  it("base64 round-trips arbitrary binary data", () => {
    const ring = createChunkRing(4 * KIB);
    const bin = Buffer.from([0, 255, 128]);
    const chunk = ring.push(bin);
    expect(Buffer.from(chunk.data, "base64").equals(bin)).toBe(true);
    expect(chunk.offset).toBe(0);
    const s = ring.since(null);
    expect(Buffer.from(s.chunks[0].data, "base64").equals(bin)).toBe(true);
    // and through a partial read
    expect(Buffer.from(ring.since(1).chunks[0].data, "base64").equals(Buffer.from([255, 128]))).toBe(
      true,
    );
  });
});
