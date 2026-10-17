/**
 * Task 5, TDD step 5 — index-free structural recovery (spike §7.1).
 *
 * The index frame is corrupted (readIndex refuses); scanFrames walks the
 * zstd frame structure byte-exactly from the head magic to the footer-derived
 * index offset, and recoverIndex rebuilds frames[]/files[] from the
 * decompressed member streams — deep-equal to the original index modulo
 * createdAt, and usable for extraction.
 */

import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { once } from "node:events";
import { createWriteStream } from "node:fs";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { FdReader } from "../rangeReader.js";
import {
  ArchiveCorruptError,
  ArchiveTruncatedError,
} from "../errors.js";
import { FOOTER_LEN } from "./format.js";
import { pack, type ArchiveIndex } from "./pack.js";
import { readFooter, readIndex } from "./readIndex.js";
import { recoverIndex, scanFrames } from "./recover.js";
import { extractOne } from "./extract.js";

const MTIME = new Date("2026-10-01T00:00:00.000Z");
const NOW = () => new Date("2026-10-16T09:00:00.000Z");

describe("recover — index-free structural recovery", () => {
  let tmp: string;
  let archivePath: string;
  let corruptPath: string;
  let index: ArchiveIndex;
  let indexOffset: number;

  beforeAll(async () => {
    tmp = await mkdtemp(join(tmpdir(), "ovid-rec-"));
    const wsDir = join(tmp, "ws");
    await mkdir(join(wsDir, "sub"), { recursive: true });
    await writeFile(join(wsDir, "a.txt"), Buffer.from("a".repeat(100)));
    await writeFile(join(wsDir, "sub", "b.bin"), Buffer.alloc(300_000, 7)); // solo frame
    await writeFile(join(wsDir, "sub", "c.txt"), Buffer.from("ccccz"));
    await symlink("../a.txt", join(wsDir, "sub", "link"));
    for (const p of ["a.txt", "sub", "sub/b.bin", "sub/c.txt", "sub/link"]) {
      await utimes(join(wsDir, p), MTIME, MTIME);
    }
    archivePath = join(tmp, "ws.ows");
    const ws = createWriteStream(archivePath);
    const report = await pack(wsDir, ws, { now: NOW });
    ws.end();
    await once(ws, "close");
    index = report.index;
    expect(index.frames).toHaveLength(2); // one solo + one group

    // Corrupt bytes INSIDE the index frame (footer left intact).
    const whole = await readFile(archivePath);
    const footer = await readFooter(new FdReader(archivePath));
    indexOffset = whole.length - FOOTER_LEN - footer.indexFrameLen;
    const bad = Buffer.from(whole);
    bad[indexOffset + Math.floor(footer.indexFrameLen / 2)] ^= 0x5a;
    corruptPath = join(tmp, "corrupt.ows");
    await writeFile(corruptPath, bad);
  });

  afterAll(async () => {
    await rm(tmp, { recursive: true, force: true });
  });

  it("the corrupted archive no longer opens via readIndex", async () => {
    const r = new FdReader(corruptPath);
    await expect(readIndex(r)).rejects.toThrowError(ArchiveCorruptError);
    await r.close();
  });

  it("scanFrames walks every frame and ends exactly at the index frame", async () => {
    const r = new FdReader(corruptPath);
    const frames = await scanFrames(r);
    await r.close();
    expect(frames).toHaveLength(index.frames.length);
    expect(frames.map((f) => [f.offset, f.length])).toEqual(
      index.frames.map((f) => [f.offset, f.length]),
    );
    expect(frames.every((f) => f.checksumFlag)).toBe(true);
    expect(frames.every((f) => f.contentSize !== null)).toBe(true);
    // the walk ends EXACTLY at the index-frame offset (footer math)
    const last = frames[frames.length - 1];
    expect(last.offset + last.length).toBe(indexOffset);
  });

  it("recoverIndex rebuilds the index deep-equal modulo createdAt", async () => {
    const r = new FdReader(corruptPath);
    const recovered = await recoverIndex(r);
    await r.close();
    expect(recovered).toEqual({ ...index, createdAt: "" });
  });

  it("extractOne with the RECOVERED index returns exact bytes", async () => {
    const r = new FdReader(corruptPath);
    const recovered = await recoverIndex(r);
    const dest = join(tmp, "rec-out", "b.bin");
    await extractOne(r, recovered, "sub/b.bin", dest);
    await r.close();
    const bytes = await readFile(dest);
    expect(bytes.length).toBe(300_000);
    expect(bytes[0]).toBe(7);
    expect(bytes[299_999]).toBe(7);
    expect(createHash("sha256").update(bytes).digest("base64url")).toBe(
      index.files.find((f) => f.path === "sub/b.bin")!.hashB64,
    );
  });

  it("recoverIndex also restores symlink records", async () => {
    const r = new FdReader(corruptPath);
    const recovered = await recoverIndex(r);
    await r.close();
    const link = recovered.files.find((f) => f.path === "sub/link")!;
    expect(link.type).toBe(2);
    expect(link.target).toBe("../a.txt");
    expect(link.hashB64).toBe("");
  });

  it("recoverIndex of the intact archive also round-trips", async () => {
    const r = new FdReader(archivePath);
    const recovered = await recoverIndex(r);
    await r.close();
    expect(recovered).toEqual({ ...index, createdAt: "" });
  });

  it("scanFrames rejects a truncated frame loudly", async () => {
    const whole = await readFile(archivePath);
    const frame0 = index.frames[0];
    // head magic + 20 bytes of frame 0, then a footer whose math places the
    // end of the frames region MID-frame — the block walk must hit the
    // boundary and throw truncated (not walk past it into garbage).
    const cut = whole.subarray(0, frame0.offset + 20);
    const footer = Buffer.alloc(FOOTER_LEN); // indexFrameLen 0 → framesEnd = cut end
    footer.write("OVIDEND1", 16, "latin1");
    const cutPath = join(tmp, "cut.ows");
    await writeFile(cutPath, Buffer.concat([cut, footer]));
    const r = new FdReader(cutPath);
    await expect(scanFrames(r)).rejects.toThrowError(ArchiveTruncatedError);
    await expect(scanFrames(r)).rejects.toThrowError(/frame at \d+ truncated/);
    await r.close();
  });

  it("recoverIndex rejects a corrupted data frame", async () => {
    const whole = await readFile(archivePath);
    const frame0 = index.frames[0];
    const bad = Buffer.from(whole);
    bad[frame0.offset + Math.floor(frame0.length / 2)] ^= 0x5a;
    const badPath = join(tmp, "badframe.ows");
    await writeFile(badPath, bad);
    const r = new FdReader(badPath);
    await expect(recoverIndex(r)).rejects.toThrowError(/Data corruption detected/);
    await r.close();
  });
});
