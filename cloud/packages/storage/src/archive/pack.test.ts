/**
 * Task 4 — packer tests over a seeded fixture (TDD step 1 of the brief).
 *
 * Fixture (byte-wise path order):
 *   a                dir
 *   a/empty.txt      0 B
 *   a/k.txt          1024 B, mode 0o755
 *   a/one.txt        1 B
 *   b                dir
 *   b/big.bin        5_000_000 B   (solo frame)
 *   b/over.bin       262_145 B     (solo frame — 256 KiB + 1)
 *   b/under.bin      262_143 B     (group — 256 KiB - 1)
 *   b/z              dir
 *   b/z/link         symlink -> ../../a/one.txt
 *
 * Pinned frame plan (3 frames — the minimum; a packer that flushes the
 * pending group on every solo file would emit 4):
 *   frame 0: solo b/big.bin   payload 32+8+5_000_000
 *   frame 1: solo b/over.bin  payload 32+11+262_145
 *   frame 2: group of 8 members, payload 263_490 B (<= GROUP_MAX)
 */

import { once } from "node:events";
import { createHash } from "node:crypto";
import {
  chmod,
  mkdir,
  mkdtemp,
  open as fsOpen,
  readFile,
  rm,
  symlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import { createWriteStream } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { Writable } from "node:stream";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { createFsStorage } from "../fsAdapter.js";
import { FdReader } from "../rangeReader.js";
import { StorageError } from "../errors.js";
import {
  ARCHIVE_END_MAGIC,
  ARCHIVE_MAGIC,
  ArchiveCorruptError,
  GROUP_MAX,
  MEMBER_HEADER_LEN,
} from "./format.js";
import {
  decodeMemberHeader,
  encodeMemberHeader,
  type MemberHeader,
} from "./memberStream.js";
import {
  decodeIndexWire,
  encodeIndexWire,
  pack,
  packToStorage,
  type ArchiveIndex,
  type PackReport,
} from "./pack.js";
import { readIndex } from "./readIndex.js";

const MTIME = new Date("2026-10-01T00:00:00.000Z");
const NOW = () => new Date("2026-10-16T09:00:00.000Z");
const MTIME_SEC = Math.floor(MTIME.getTime() / 1000);

const FILE_SIZES: Array<[string, number]> = [
  ["a/empty.txt", 0],
  ["a/one.txt", 1],
  ["a/k.txt", 1024],
  ["b/under.bin", 262_143],
  ["b/over.bin", 262_145],
  ["b/big.bin", 5_000_000],
];

/** Deterministic pseudo-random 256 B block, repeated to `size`. */
function contentFor(path: string, size: number): Buffer {
  if (size === 0) return Buffer.alloc(0);
  const block = Buffer.alloc(256);
  let x = 0x9e3779b9;
  for (const ch of path) x = (x ^ ch.charCodeAt(0)) >>> 0;
  for (let i = 0; i < 256; i++) {
    x = (x * 1664525 + 1013904223) >>> 0;
    block[i] = x >>> 24;
  }
  const buf = Buffer.alloc(size);
  buf.fill(block);
  return buf;
}

async function buildFixture(wsDir: string): Promise<void> {
  for (const [rel, size] of FILE_SIZES) {
    const abs = join(wsDir, rel);
    await mkdir(dirname(abs), { recursive: true });
    await writeFile(abs, contentFor(rel, size));
  }
  await chmod(join(wsDir, "a/k.txt"), 0o755);
  await mkdir(join(wsDir, "b/z"), { recursive: true });
  await symlink("../../a/one.txt", join(wsDir, "b/z/link"));
  // Fixed mtimes on EVERY entry (dirs, files, and the symlink itself —
  // utimes follows symlinks, so use lutimes for the link).
  const { lutimes } = await import("node:fs/promises");
  for (const [rel] of FILE_SIZES) await utimes(join(wsDir, rel), MTIME, MTIME);
  await utimes(join(wsDir, "a/k.txt"), MTIME, MTIME);
  for (const d of ["a", "b", "b/z"]) await utimes(join(wsDir, d), MTIME, MTIME);
  await lutimes(join(wsDir, "b/z/link"), MTIME, MTIME);
}

async function packToFile(
  wsDir: string,
  path: string,
  opts?: Parameters<typeof pack>[2],
): Promise<PackReport> {
  const ws = createWriteStream(path);
  const report = await pack(wsDir, ws, opts);
  ws.end();
  await once(ws, "close");
  return report;
}

describe("pack — OVIDWS-G1 fixture", () => {
  let tmp: string;
  let wsDir: string;
  let archivePath: string;
  let report: PackReport;
  let whole: Buffer;

  beforeAll(async () => {
    tmp = await mkdtemp(join(tmpdir(), "ovid-arch-"));
    wsDir = join(tmp, "ws");
    await buildFixture(wsDir);
    archivePath = join(tmp, "ws.ows");
    report = await packToFile(wsDir, archivePath, { now: NOW });
    whole = await readFile(archivePath);
  });

  afterAll(async () => {
    await rm(tmp, { recursive: true, force: true });
  });

  it("(a) head/tail magic and report counts", () => {
    expect(whole.subarray(0, 8).toString("latin1")).toBe(ARCHIVE_MAGIC);
    expect(whole.subarray(whole.length - 8).toString("latin1")).toBe(
      ARCHIVE_END_MAGIC,
    );
    expect(report.files).toBe(6);
    expect(report.dirs).toBe(3);
    expect(report.symlinks).toBe(1);
    expect(report.frames).toBe(3);
    expect(report.bytes).toBe(whole.length);
    expect(report.ms).toBeGreaterThanOrEqual(0);
  });

  it("(b) readIndex round-trips every record with exact hashes and metadata", async () => {
    const reader = new FdReader(archivePath);
    const index = await readIndex(reader);
    await reader.close();

    expect(index.archiveVersion).toBe(1);
    expect(index.format).toBe("ovid-ws-grouped-v1");
    expect(index.zstdLevel).toBe(9);
    expect(index.createdAt).toBe(NOW().toISOString());
    expect(index.files).toHaveLength(10); // 6 files + 3 dirs + 1 symlink
    expect(index.files.filter((f) => f.type === 0)).toHaveLength(6);
    expect(index.files.filter((f) => f.type === 1)).toHaveLength(3);
    expect(index.files.filter((f) => f.type === 2)).toHaveLength(1);

    // files[] is byte-wise path sorted (deterministic)
    const paths = index.files.map((f) => f.path);
    expect(paths).toEqual([
      "a",
      "a/empty.txt",
      "a/k.txt",
      "a/one.txt",
      "b",
      "b/big.bin",
      "b/over.bin",
      "b/under.bin",
      "b/z",
      "b/z/link",
    ]);

    for (const rec of index.files.filter((f) => f.type === 0)) {
      const content = await readFile(join(wsDir, rec.path));
      expect(rec.size).toBe(SIZE_OF(rec.path));
      expect(rec.mtime).toBe(MTIME_SEC);
      expect(rec.hashB64).toBe(
        createHash("sha256").update(content).digest("base64url"),
      );
    }

    const k = index.files.find((f) => f.path === "a/k.txt")!;
    expect(k.mode & 0o777).toBe(0o755);

    const dirA = index.files.find((f) => f.path === "a")!;
    expect(dirA.type).toBe(1);
    expect(dirA.hashB64).toBe("");
    expect(Number.isInteger(dirA.mode)).toBe(true); // umask-independent

    const link = index.files.find((f) => f.path === "b/z/link")!;
    expect(link.type).toBe(2);
    expect(link.target).toBe("../../a/one.txt");
    expect(link.size).toBe(15); // byte length of the target
    expect(link.hashB64).toBe("");
    expect(link.lengthInFrame).toBe(0);

    function SIZE_OF(p: string): number {
      return FILE_SIZES.find(([rel]) => rel === p)![1];
    }
  });

  it("(c) grouping: solos ride alone, small files share one group, frame count is the 3-frame minimum", async () => {
    const reader = new FdReader(archivePath);
    const index = await readIndex(reader);
    await reader.close();

    expect(index.frames).toHaveLength(3);
    const [f0, f1, f2] = index.frames;

    // solo frames: single member each
    expect(f0.members).toBe(1);
    expect(f0.decSize).toBe(MEMBER_HEADER_LEN + "b/big.bin".length + 5_000_000);
    expect(f1.members).toBe(1);
    expect(f1.decSize).toBe(
      MEMBER_HEADER_LEN + "b/over.bin".length + 262_145,
    );

    // the shared group: all 8 small members, within GROUP_MAX
    expect(f2.members).toBe(8);
    expect(f2.decSize).toBe(263_490);
    expect(f2.decSize).toBeLessThanOrEqual(GROUP_MAX);

    // offsets chain from just after the head magic
    expect(f0.offset).toBe(8);
    expect(f1.offset).toBe(8 + f0.length);
    expect(f2.offset).toBe(8 + f0.length + f1.length);

    // the solo frames did NOT flush the pending group: members from both
    // sides of the solos landed in the SAME trailing frame
    const byPath = new Map(index.files.map((f) => [f.path, f]));
    expect(byPath.get("a/empty.txt")!.frameIndex).toBe(2);
    expect(byPath.get("b/under.bin")!.frameIndex).toBe(2);
    expect(byPath.get("b/z/link")!.frameIndex).toBe(2);
    expect(byPath.get("b/big.bin")!.frameIndex).toBe(0);
    expect(byPath.get("b/over.bin")!.frameIndex).toBe(1);

    // content byte ranges inside the decompressed group payload
    expect(byPath.get("a/empty.txt")!.offsetInFrame).toBe(76);
    expect(byPath.get("b/under.bin")!.offsetInFrame).toBe(1257);
    expect(byPath.get("b/under.bin")!.lengthInFrame).toBe(262_143);
    // solo content ranges
    expect(byPath.get("b/big.bin")!.offsetInFrame).toBe(41);
    expect(byPath.get("b/big.bin")!.lengthInFrame).toBe(5_000_000);
  });

  it("(d) report.sha256Hex equals an independent hash of the archive file", () => {
    expect(report.sha256Hex).toBe(createHash("sha256").update(whole).digest("hex"));
  });

  it("(e) determinism: same now() repacks byte-identical; jobs=4 is byte-identical too", async () => {
    const again = await packToFile(wsDir, join(tmp, "ws-again.ows"), {
      now: NOW,
    });
    expect(again.sha256Hex).toBe(report.sha256Hex);
    expect(await readFile(join(tmp, "ws-again.ows"))).toEqual(whole);

    const parallel = await packToFile(wsDir, join(tmp, "ws-jobs.ows"), {
      now: NOW,
      jobs: 4,
    });
    expect(parallel.sha256Hex).toBe(report.sha256Hex);
    expect(await readFile(join(tmp, "ws-jobs.ows"))).toEqual(whole);
  });

  it("(f) packToStorage streams into the adapter with no temp file", async () => {
    const store = createFsStorage(join(tmp, "store"));
    const key = "users/u1/workspaces/s1.tar.zst";
    const stored = await packToStorage(wsDir, store, key, { now: NOW });

    const head = await store.head(key);
    expect(head).not.toBeNull();
    expect(head!.bytes).toBe(stored.bytes);
    expect(head!.bytes).toBe(report.bytes);
    expect(head!.sha256Hex).toBe(report.sha256Hex);

    const buf = await store.getBuffer(key);
    expect(buf).not.toBeNull();
    expect(buf!.equals(whole)).toBe(true);
  });

  it("(g) rejects files > 2 GiB with code unsupported_size before writing anything", async () => {
    const bigDir = join(tmp, "ws-big");
    await mkdir(bigDir);
    const fh = await fsOpen(join(bigDir, "huge.bin"), "w");
    await fh.truncate(2_254_857_830); // 2.1 GiB, sparse — no disk usage
    await fh.close();

    let written = 0;
    const sink = new Writable({
      write(chunk, _enc, cb) {
        written += chunk.length;
        cb();
      },
    });
    const p = pack(bigDir, sink);
    await expect(p).rejects.toBeInstanceOf(StorageError);
    await expect(p).rejects.toMatchObject({ code: "unsupported_size" });
    expect(written).toBe(0);
  });
});

describe("memberStream — 32-byte member header", () => {
  const header: MemberHeader = {
    nameLen: 11,
    targetLen: 15,
    mode: 0o755,
    mtimeSec: 1_792_812_800,
    size: 262_143,
    type: 2,
    flags: 0,
  };

  it("encodes exactly 32 bytes and round-trips (also at an offset)", () => {
    const buf = encodeMemberHeader(header);
    expect(buf).toHaveLength(MEMBER_HEADER_LEN);
    expect(decodeMemberHeader(buf)).toEqual(header);

    const padded = Buffer.concat([Buffer.alloc(4), buf]);
    expect(decodeMemberHeader(padded, 4)).toEqual(header);
  });

  it("rejects short buffers, bad types, and non-zero reserved bytes", () => {
    const buf = encodeMemberHeader(header);

    expect(() => decodeMemberHeader(buf.subarray(0, 31))).toThrow(
      ArchiveCorruptError,
    );

    const badType = encodeMemberHeader({ ...header, type: 0 });
    badType[24] = 7;
    expect(() => decodeMemberHeader(badType)).toThrow(ArchiveCorruptError);

    const badRsv = encodeMemberHeader({ ...header, type: 0 });
    badRsv[26] = 1;
    expect(() => decodeMemberHeader(badRsv)).toThrow(ArchiveCorruptError);
  });
});

describe("index wire codec", () => {
  const index: ArchiveIndex = {
    archiveVersion: 1,
    format: "ovid-ws-grouped-v1",
    zstdLevel: 9,
    createdAt: "2026-10-16T09:00:00.000Z",
    frames: [{ offset: 8, length: 100, decSize: 200, members: 2 }],
    files: [
      {
        path: "a",
        type: 1,
        size: 0,
        mode: 0o755,
        mtime: 1,
        frameIndex: 0,
        offsetInFrame: 0,
        lengthInFrame: 0,
        hashB64: "",
      },
      {
        path: "b/z/link",
        type: 2,
        size: 15,
        mode: 0o777,
        mtime: 2,
        frameIndex: 0,
        offsetInFrame: 55,
        lengthInFrame: 0,
        hashB64: "",
        target: "../x",
      },
      {
        path: "c.txt",
        type: 0,
        size: 3,
        mode: 0o644,
        mtime: 3,
        frameIndex: 0,
        offsetInFrame: 99,
        lengthInFrame: 3,
        hashB64: "abc",
      },
    ],
  };

  it("round-trips through the compact-array wire form", () => {
    const wire = encodeIndexWire(index);
    expect(decodeIndexWire(wire)).toEqual(index);

    const json = JSON.parse(wire.toString("utf8"));
    expect(json.files[0]).toEqual(["a", 1, 0, 0o755, 1, 0, 0, 0, ""]);
    expect(json.files[1]).toEqual([
      "b/z/link",
      2,
      15,
      0o777,
      2,
      0,
      55,
      0,
      "",
      "../x",
    ]);
    expect(json.frames[0]).toEqual([8, 100, 200, 2]);
    expect(json.checksumFlag).toBe(true);
    expect(json.groupMax).toBe(4 * 1024 * 1024);
    expect(json.soloMax).toBe(256 * 1024);
  });

  it("records the groupMax/soloMax actually used", () => {
    const wire = encodeIndexWire(index, { groupMax: 1024 * 1024, soloMax: 4096 });
    const json = JSON.parse(wire.toString("utf8"));
    expect(json.groupMax).toBe(1024 * 1024);
    expect(json.soloMax).toBe(4096);
    expect(decodeIndexWire(wire)).toEqual(index);
  });
});
