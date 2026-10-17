/**
 * Task 5, TDD step 1 — the FCS-table pin (spike §8 bug #3).
 *
 * The zstd Frame_Content_Size field size is selected by a 2-bit code:
 *   0 → (singleSegment ? 1 : 0) bytes
 *   1 → 2 bytes, value = stored + 256
 *   2 → 4 bytes
 *   3 → 8 bytes
 * A wrong table silently reports null or off-by-256 content sizes. The sizes
 * below are chosen to sit exactly on the table's boundaries:
 *   100 B      code 0 (single-segment, 1-byte FCS)
 *   1 KB       code 1 (stored 768 + 256)
 *   65_791 B   code 1 max (stored 0xFFFF)
 *   65_792 B   first code 2 size (4-byte FCS)
 *   100 KB     code 2
 *   10 MB      code 2
 * Fixtures are produced by the zstd CLI 1.5.5 (both --check and --no-check
 * variants pin the Content_Checksum_flag bit), plus one Node-zstdCompressSync
 * frame with the packer's exact parameter shape.
 */

import { execFile as execFileCb } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import * as zlib from "node:zlib";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { ArchiveCorruptError } from "../errors.js";
import { parseZstdFrameHeader } from "./zstdFrames.js";

const execFile = promisify(execFileCb);

const SIZES = [100, 1024, 65_791, 65_792, 100 * 1024, 10 * 1024 * 1024];

/** Deterministic content (compressible enough to keep fixtures small). */
function fill(size: number): Buffer {
  const buf = Buffer.alloc(size);
  let x = 0x12345678;
  for (let i = 0; i < size; i++) {
    x = (x * 1664525 + 1013904223) >>> 0;
    buf[i] = x >>> 26;
  }
  return buf;
}

describe("parseZstdFrameHeader — FCS table pin (zstd CLI 1.5.5)", () => {
  let tmp: string;
  /** size → {check: Buffer, nocheck: Buffer} */
  const frames = new Map<number, { check: Buffer; nocheck: Buffer }>();
  let nodeFrame: Buffer;

  beforeAll(async () => {
    tmp = await mkdtemp(join(tmpdir(), "ovid-zf-"));
    const input = join(tmp, "in.bin");
    for (const size of SIZES) {
      await writeFile(input, fill(size));
      const variants: Array<"check" | "nocheck"> = ["check", "nocheck"];
      const pair = { check: Buffer.alloc(0), nocheck: Buffer.alloc(0) };
      for (const v of variants) {
        const out = join(tmp, `out-${size}-${v}.zst`);
        await execFile("zstd", [
          "-9",
          "-f",
          "-q",
          v === "check" ? "--check" : "--no-check",
          "-o",
          out,
          input,
        ]);
        pair[v] = await readFile(out);
      }
      frames.set(size, pair);
    }
    // The packer's frame shape: level 9, checksum ON, FCS ON, clamped windowLog.
    nodeFrame = zlib.zstdCompressSync(fill(4 * 1024 * 1024), {
      params: {
        [zlib.constants.ZSTD_c_compressionLevel]: 9,
        [zlib.constants.ZSTD_c_checksumFlag]: 1,
        [zlib.constants.ZSTD_c_contentSizeFlag]: 1,
        [zlib.constants.ZSTD_c_windowLog]: 22,
      },
    });
  });

  afterAll(async () => {
    await rm(tmp, { recursive: true, force: true });
  });

  it.each(SIZES)("contentSize is exact and checksumFlag tracks --check/--no-check (%d B)", (size) => {
    const pair = frames.get(size)!;
    for (const [variant, buf] of [
      ["check", pair.check],
      ["nocheck", pair.nocheck],
    ] as const) {
      const h = parseZstdFrameHeader(buf);
      expect(h.contentSize, `${variant} contentSize for ${size} B`).toBe(size);
      expect(h.checksumFlag, `${variant} checksumFlag for ${size} B`).toBe(
        variant === "check",
      );
      expect(h.magic).toBe(0xfd2fb528);
      // singleSegment frames carry the content size as the window itself
      if (h.singleSegment) {
        expect(h.contentSize).not.toBeNull();
        expect(h.windowSize).toBe(h.contentSize);
      } else {
        expect(h.windowSize).not.toBeNull();
      }
    }
  });

  it("the Node packer-shaped 4 MiB frame parses with exact contentSize", () => {
    const h = parseZstdFrameHeader(nodeFrame);
    expect(h.contentSize).toBe(4 * 1024 * 1024);
    expect(h.checksumFlag).toBe(true);
    expect(h.totalHeaderLen).toBeLessThanOrEqual(18);
  });

  it("totalHeaderLen covers magic + descriptor + window + dictID + FCS", () => {
    // 4-byte FCS, single-segment (no window descriptor), no dictID:
    // 4 + 1 + 0 + 0 + 4 = 9
    const h = parseZstdFrameHeader(nodeFrame);
    expect(h.totalHeaderLen).toBe(9);
    expect(nodeFrame.subarray(0, h.totalHeaderLen).length).toBe(h.totalHeaderLen);
  });

  it("skippable frames parse with contentSize null and an 8-byte header", () => {
    const skipped = Buffer.alloc(8 + 16);
    skipped.writeUInt32LE(0x184d2a50, 0);
    skipped.writeUInt32LE(16, 4);
    const h = parseZstdFrameHeader(skipped);
    expect(h.contentSize).toBeNull();
    expect(h.checksumFlag).toBe(false);
    expect(h.singleSegment).toBe(false);
    expect(h.windowSize).toBeNull();
    expect(h.totalHeaderLen).toBe(8);
    // caller skips 8 + frame_size bytes
  });

  it("rejects an unknown magic", () => {
    const bad = Buffer.alloc(64, 1);
    bad.writeUInt32LE(0xdeadbeef, 0);
    expect(() => parseZstdFrameHeader(bad)).toThrow(ArchiveCorruptError);
  });

  it("rejects a buffer too short for the declared header", () => {
    const bad = Buffer.alloc(3);
    expect(() => parseZstdFrameHeader(bad)).toThrow(ArchiveCorruptError);
    const short = nodeFrame.subarray(0, 8); // cuts the 4-byte FCS
    expect(() => parseZstdFrameHeader(short)).toThrow(ArchiveCorruptError);
  });

  it("honors the offset parameter", () => {
    const pad = Buffer.alloc(7, 0);
    const h = parseZstdFrameHeader(Buffer.concat([pad, nodeFrame]), 7);
    expect(h.contentSize).toBe(4 * 1024 * 1024);
  });
});
