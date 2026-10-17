/**
 * Task 4 — readIndex corruption guards (TDD step 4 of the brief) and the
 * decodeIndexWire shape contract.
 *
 * Fixture packed into memory; each case flips or truncates bytes on a copy.
 * Matrix from spike §7.2: every fault produces a typed error (never silent
 * garbage), except a corrupted CONTENT frame — detection there is per-use,
 * so open must succeed.
 */

import { createHash } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile, utimes } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Writable } from "node:stream";
import * as zlib from "node:zlib";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { StorageError } from "../errors.js";
import type { RangeReader } from "../rangeReader.js";
import {
  ArchiveCorruptError,
  ArchiveTruncatedError,
  FOOTER_LEN,
} from "./format.js";
import {
  decodeIndexWire,
  encodeIndexWire,
  pack,
  type ArchiveIndex,
  type PackReport,
} from "./pack.js";
import { manifest, readIndex, readFooter } from "./readIndex.js";

const MTIME = new Date("2026-10-01T00:00:00.000Z");
const NOW = () => new Date("2026-10-16T09:00:00.000Z");

class MemReader implements RangeReader {
  constructor(private readonly buf: Buffer) {}
  async size(): Promise<number> {
    return this.buf.length;
  }
  async read(offset: number, length: number): Promise<Buffer> {
    if (offset < 0 || length < 0 || offset + length > this.buf.length) {
      throw new StorageError(
        `MemReader read(${offset}, ${length}) out of bounds (size ${this.buf.length})`,
      );
    }
    return this.buf.subarray(offset, offset + length);
  }
  async close(): Promise<void> {}
}

async function packToBuffer(wsDir: string): Promise<{ report: PackReport; buf: Buffer }> {
  const chunks: Buffer[] = [];
  const sink = new Writable({
    write(chunk, _enc, cb) {
      chunks.push(Buffer.from(chunk));
      cb();
    },
  });
  const report = await pack(wsDir, sink, { now: NOW });
  return { report, buf: Buffer.concat(chunks) };
}

describe("readIndex — corruption matrix", () => {
  let tmp: string;
  let wsDir: string;
  let good: Buffer;
  let goodIndex: ArchiveIndex;

  beforeAll(async () => {
    tmp = await mkdtemp(join(tmpdir(), "ovid-ridx-"));
    wsDir = join(tmp, "ws");
    await mkdir(join(wsDir, "sub"), { recursive: true });
    await writeFile(join(wsDir, "a.txt"), Buffer.from("a".repeat(100)));
    await writeFile(join(wsDir, "sub", "b.bin"), Buffer.alloc(300_000, 7)); // solo frame
    await writeFile(join(wsDir, "sub", "c.txt"), Buffer.from("ccccz"));
    for (const p of ["a.txt", "sub", "sub/b.bin", "sub/c.txt"]) {
      await utimes(join(wsDir, p), MTIME, MTIME);
    }
    const { report, buf } = await packToBuffer(wsDir);
    good = buf;
    goodIndex = report.index;
    expect(report.frames).toBe(2); // one solo + one group — sanity for the flips below
  });

  afterAll(async () => {
    await rm(tmp, { recursive: true, force: true });
  });

  function flip(copy: Buffer, at: number): Buffer {
    expect(at).toBeGreaterThan(0);
    expect(at).toBeLessThan(copy.length);
    copy[at] ^= 0x5a;
    return copy;
  }

  it("opens the good archive and readFooter agrees with the layout", async () => {
    const index = await readIndex(new MemReader(good));
    expect(index).toEqual(goodIndex);

    const footer = await readFooter(new MemReader(good));
    const indexOffset = good.length - FOOTER_LEN - footer.indexFrameLen;
    const json = zlib.zstdDecompressSync(
      good.subarray(indexOffset, indexOffset + footer.indexFrameLen),
      { params: { [zlib.constants.ZSTD_d_windowLogMax]: 27 } },
    );
    // footer hash is sha256(uncompressed index JSON)[0..8]
    expect(createHash("sha256").update(json).digest().subarray(0, 8)).toEqual(
      footer.indexHash,
    );
    expect(decodeIndexWire(json)).toEqual(goodIndex);
  });

  it("manifest is an alias of readIndex", () => {
    expect(manifest).toBe(readIndex);
  });

  it("truncating 1 byte -> ArchiveTruncatedError with bad tail magic", async () => {
    const truncated = good.subarray(0, good.length - 1);
    const p = readIndex(new MemReader(truncated));
    await expect(p).rejects.toBeInstanceOf(ArchiveTruncatedError);
    await expect(p).rejects.toMatchObject({
      code: "archive_truncated",
      message: expect.stringContaining("bad tail magic"),
    });
  });

  it("flipping a byte in the footer indexHash -> ArchiveCorruptError", async () => {
    const footerStart = good.length - FOOTER_LEN;
    const corrupted = flip(Buffer.from(good), footerStart + 8 + 3); // inside indexHash [8,16)
    const p = readIndex(new MemReader(corrupted));
    await expect(p).rejects.toBeInstanceOf(ArchiveCorruptError);
    await expect(p).rejects.toMatchObject({
      code: "archive_corrupt",
      message: expect.stringContaining("index hash mismatch"),
    });
  });

  it("flipping a byte in the compressed index frame -> ArchiveCorruptError", async () => {
    const footer = await readFooter(new MemReader(good));
    const indexOffset = good.length - FOOTER_LEN - footer.indexFrameLen;
    const at = indexOffset + Math.floor(footer.indexFrameLen / 2);
    const corrupted = flip(Buffer.from(good), at);
    const p = readIndex(new MemReader(corrupted));
    await expect(p).rejects.toBeInstanceOf(ArchiveCorruptError);
    await expect(p).rejects.toMatchObject({ code: "archive_corrupt" });
  });

  it("flipping a byte in an unrelated content frame -> open SUCCEEDS (per-use detection)", async () => {
    const frame = goodIndex.frames[0];
    const at = frame.offset + Math.floor(frame.length / 2);
    const corrupted = flip(Buffer.from(good), at);
    const index = await readIndex(new MemReader(corrupted));
    expect(index).toEqual(goodIndex);
  });

  it("bad head magic (XVIDWS01) -> ArchiveCorruptError", async () => {
    const corrupted = Buffer.from(good);
    corrupted[0] = "X".charCodeAt(0);
    const p = readIndex(new MemReader(corrupted));
    await expect(p).rejects.toBeInstanceOf(ArchiveCorruptError);
    await expect(p).rejects.toMatchObject({
      code: "archive_corrupt",
      message: expect.stringContaining("bad head magic"),
    });
  });

  it("a non-archive buffer fails cleanly (too small)", async () => {
    const p = readIndex(new MemReader(Buffer.from("not an archive at all")));
    await expect(p).rejects.toBeInstanceOf(ArchiveTruncatedError);
  });
});

describe("decodeIndexWire — shape contract", () => {
  const valid: ArchiveIndex = {
    archiveVersion: 1,
    format: "ovid-ws-grouped-v1",
    zstdLevel: 9,
    createdAt: "2026-10-16T09:00:00.000Z",
    frames: [{ offset: 8, length: 10, decSize: 20, members: 1 }],
    files: [
      {
        path: "x.txt",
        type: 0,
        size: 3,
        mode: 0o644,
        mtime: 5,
        frameIndex: 0,
        offsetInFrame: 40,
        lengthInFrame: 3,
        hashB64: "h",
      },
    ],
  };

  it("round-trips the valid index", () => {
    expect(decodeIndexWire(encodeIndexWire(valid))).toEqual(valid);
  });

  const badCases: Array<[string, (wire: Record<string, unknown>) => Record<string, unknown>]> = [
    ["wrong archiveVersion", (w) => ({ ...w, archiveVersion: 2 })],
    ["wrong format", (w) => ({ ...w, format: "tar" })],
    ["missing frames", (w) => ({ ...w, frames: undefined })],
    ["frames row of length 3", (w) => ({ ...w, frames: [[8, 10, 20]] })],
    ["files row of length 8", (w) => ({ ...w, files: [["x.txt", 0, 3, 420, 5, 0, 40, 3]] })],
    ["member type 5", (w) => ({ ...w, files: [["x.txt", 5, 3, 420, 5, 0, 40, 3, "h"]] })],
    ["frameIndex out of range", (w) => ({ ...w, files: [["x.txt", 0, 3, 420, 5, 9, 40, 3, "h"]] })],
    ["negative size", (w) => ({ ...w, files: [["x.txt", 0, -1, 420, 5, 0, 40, 3, "h"]] })],
    ["empty path", (w) => ({ ...w, files: [["", 0, 3, 420, 5, 0, 40, 3, "h"]] })],
  ];

  for (const [name, mutate] of badCases) {
    it(`throws ArchiveCorruptError on ${name}`, () => {
      const wire = JSON.parse(encodeIndexWire(valid).toString("utf8")) as Record<string, unknown>;
      expect(() => decodeIndexWire(Buffer.from(JSON.stringify(mutate(wire))))).toThrow(
        ArchiveCorruptError,
      );
    });
  }

  it("throws ArchiveCorruptError on unparseable JSON", () => {
    expect(() => decodeIndexWire(Buffer.from("not json{"))).toThrow(ArchiveCorruptError);
  });
});
