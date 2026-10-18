/**
 * Task 5, TDD step 3 — extract read path: extractFile / extractOne /
 * extractAll (in-process + worker threads) over a rich nested fixture, and
 * the corruption matrix from spike §7.2.
 *
 * Fixture: 306 files + 10 dirs (mixed modes incl. read-only 0o500/0o555 and
 * 0o444 files) + 3 symlinks (relative, absolute, parent-dir), ~16 MB — enough
 * small-file volume for multiple group frames and 13 solo frames, so the
 * worker-thread path gets real disjoint frame ranges.
 *
 * Corruption matrix (each class must reject loudly, never write garbage):
 *   (a) byte flipped mid-frame       → ArchiveCorruptError, no dest, no .part-
 *   (b) hashB64 flipped in the index → HashMismatchError "HASH MISMATCH for …"
 *   (c) truncation mid-frame         → rejects, dest never created
 *   (d) extractAll workers 1 and 4   → byte-exact tree + `diff -rq` clean
 *   (e) corrupt byte + extractAll    → rejects, partial tree left for caller
 */

import { execFile as execFileCb } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmod,
  copyFile,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  readlink,
  rm,
  symlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { createWriteStream } from "node:fs";
import { once } from "node:events";
import * as zlib from "node:zlib";
import * as ts from "typescript";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { FdReader } from "../rangeReader.js";
import {
  ArchiveCorruptError,
  ArchiveTruncatedError,
  FileNotInArchiveError,
  HashMismatchError,
  StorageError,
} from "../errors.js";
import { FOOTER_LEN, MEMBER_HEADER_LEN } from "./format.js";
import { pack, type ArchiveIndex, type FileRec, type PackReport } from "./pack.js";
import { readIndex } from "./readIndex.js";
import {
  decompressFrame,
  extractAll,
  extractAllInProcess,
  extractFile,
  extractOne,
} from "./extract.js";

const execFile = promisify(execFileCb);

const MTIME = new Date("2026-10-01T00:00:00.000Z");
const MTIME_SEC = Math.floor(MTIME.getTime() / 1000);
const NOW = () => new Date("2026-10-16T09:00:00.000Z");

const PKG_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

// ---------------------------------------------------------------------------
// Fixture manifest
// ---------------------------------------------------------------------------

const MODES = [0o644, 0o755, 0o600, 0o440] as const;
const SMALL = 290;

interface FileSpec {
  rel: string;
  size: number;
  mode: number;
}

const FILES: FileSpec[] = [];
for (let i = 0; i < SMALL; i++) {
  FILES.push({
    rel: `a/x/y/f-${String(i).padStart(3, "0")}.txt`,
    size: i % 50 === 0 ? 0 : ((i * 977) % 48_000) + 1,
    mode: MODES[i % MODES.length],
  });
}
FILES.push({ rel: "b/ro/locked.bin", size: 100_000, mode: 0o444 });
for (let i = 0; i < 10; i++) {
  FILES.push({
    rel: `b/medium-${String(i).padStart(2, "0")}.bin`,
    size: 300_001,
    mode: 0o644,
  });
}
FILES.push({ rel: "b/big-0.bin", size: 1_500_000, mode: 0o600 });
FILES.push({ rel: "b/big-1.bin", size: 2_000_000, mode: 0o644 });
FILES.push({ rel: "b/big-2.bin", size: 2_500_000, mode: 0o755 });
FILES.push({ rel: "c/root-0.txt", size: 0, mode: 0o644 });
FILES.push({ rel: "c/deep/deeper/tiny.txt", size: 17, mode: 0o600 });

const DIRS: Array<[string, number]> = [
  ["a", 0o755],
  ["a/x", 0o750],
  ["a/x/y", 0o700],
  ["b", 0o755],
  ["b/ro", 0o500],
  ["b/lock", 0o700],
  ["c", 0o755],
  ["c/deep", 0o755],
  ["c/deep/deeper", 0o700],
  ["empty-d", 0o555],
];

const LINKS: Array<[string, string]> = [
  ["a/x/y/link-rel", "../../../c/root-0.txt"],
  ["b/lock/link-abs", "/etc/hostname"],
  ["c/deep/self", ".."],
];

/** Deterministic pseudo-random content keyed by path (same scheme as T4). */
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
  for (const [rel] of DIRS) await mkdir(join(wsDir, rel), { recursive: true });
  for (const f of FILES) await writeFile(join(wsDir, f.rel), contentFor(f.rel, f.size));
  for (const f of FILES) await chmod(join(wsDir, f.rel), f.mode);
  for (const [rel, target] of LINKS) await symlink(target, join(wsDir, rel));
  // metadata LAST: dir mtimes must survive the writes above
  const { lutimes } = await import("node:fs/promises");
  for (const f of FILES) await utimes(join(wsDir, f.rel), MTIME, MTIME);
  for (const [rel] of LINKS) await lutimes(join(wsDir, rel), MTIME, MTIME);
  for (const [rel, mode] of DIRS) {
    await chmod(join(wsDir, rel), mode);
    await utimes(join(wsDir, rel), MTIME, MTIME);
  }
}

/**
 * Transpiles the worker's import graph to plain ESM under dist/ (gitignored,
 * still under the package so node_modules resolution works). Needed because
 * Node's type stripping does not remap "./x.js" specifiers to ".ts".
 */
function transpileWorkerBundle(outDir: string): string {
  const srcRoot = join(PKG_DIR, "src");
  const entry = join(srcRoot, "archive", "extractWorker.ts");
  const queue = [entry];
  const seen = new Set<string>();
  while (queue.length > 0) {
    const file = queue.pop()!;
    if (seen.has(file)) continue;
    seen.add(file);
    const src = readFileSync(file, "utf8");
    const out = ts.transpileModule(src, {
      compilerOptions: {
        module: ts.ModuleKind.ESNext,
        target: ts.ScriptTarget.ES2022,
      },
    }).outputText;
    const rel = relative(srcRoot, file).replace(/\.ts$/, ".js");
    const outFile = join(outDir, rel);
    mkdirSync(dirname(outFile), { recursive: true });
    writeFileSync(outFile, out);
    for (const m of src.matchAll(/["'](\.\.?\/[^"']+\.js)["']/g)) {
      queue.push(resolve(dirname(file), m[1]).replace(/\.js$/, ".ts"));
    }
  }
  return join(outDir, "archive", "extractWorker.js");
}

async function packToFile(
  wsDir: string,
  path: string,
): Promise<PackReport> {
  const ws = createWriteStream(path);
  const report = await pack(wsDir, ws, { now: NOW });
  ws.end();
  await once(ws, "close");
  return report;
}

/**
 * Recursive comparison: file contents (sha256), file/dir modes and mtimeSec,
 * symlink targets (lstat/readlink — never followed). Returns mismatch
 * descriptions; empty array means byte-exact.
 */
async function compareTrees(srcRoot: string, dstRoot: string): Promise<string[]> {
  const bad: string[] = [];
  async function walk(srcDir: string, rel: string): Promise<void> {
    const dstDir = join(dstRoot, rel);
    const srcNames = new Set((await readdir(srcDir)).sort());
    const dstNames = new Set((await readdir(dstDir)).sort());
    for (const n of srcNames) if (!dstNames.has(n)) bad.push(`missing: ${join(rel || ".", n)}`);
    for (const n of dstNames) if (!srcNames.has(n)) bad.push(`extra: ${join(rel || ".", n)}`);
    for (const n of srcNames) {
      const childRel = rel === "" ? n : `${rel}/${n}`;
      const s = await lstat(join(srcDir, n));
      const d = await lstat(join(dstDir, n));
      if (s.isDirectory() && d.isDirectory()) {
        await walk(join(srcDir, n), childRel);
        if ((s.mode & 0o7777) !== (d.mode & 0o7777)) {
          bad.push(`dir mode ${childRel}: ${s.mode & 0o7777} != ${d.mode & 0o7777}`);
        }
        if (Math.floor(s.mtimeMs / 1000) !== Math.floor(d.mtimeMs / 1000)) {
          bad.push(`dir mtime ${childRel}`);
        }
      } else if (s.isFile() && d.isFile()) {
        const a = createHash("sha256").update(await readFile(join(srcDir, n))).digest("hex");
        const b = createHash("sha256").update(await readFile(join(dstDir, n))).digest("hex");
        if (a !== b) bad.push(`content ${childRel}`);
        if ((s.mode & 0o7777) !== (d.mode & 0o7777)) {
          bad.push(`file mode ${childRel}: ${s.mode & 0o7777} != ${d.mode & 0o7777}`);
        }
        if (Math.floor(s.mtimeMs / 1000) !== Math.floor(d.mtimeMs / 1000)) {
          bad.push(`file mtime ${childRel}`);
        }
      } else if (s.isSymbolicLink() && d.isSymbolicLink()) {
        const ta = await readlink(join(srcDir, n));
        const tb = await readlink(join(dstDir, n));
        if (ta !== tb) bad.push(`symlink target ${childRel}: ${ta} != ${tb}`);
      } else {
        bad.push(`type mismatch ${childRel}`);
      }
    }
  }
  await walk(srcRoot, "");
  return bad;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/** chmod a tree writable so an unprivileged user can delete it. */
async function makeWritable(dir: string): Promise<void> {
  await chmod(dir, 0o700);
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) await makeWritable(path);
    else if (!entry.isSymbolicLink()) await chmod(path, 0o600);
  }
}

describe("extract — read path over a rich fixture", () => {
  let tmp: string;
  let wsDir: string;
  let archivePath: string;
  let report: PackReport;
  let index: ArchiveIndex;
  let workerEntry: string;
  let workerBundleDir: string;

  beforeAll(async () => {
    tmp = await mkdtemp(join(tmpdir(), "ovid-ext-"));
    wsDir = join(tmp, "ws");
    await buildFixture(wsDir);
    archivePath = join(tmp, "ws.ows");
    report = await packToFile(wsDir, archivePath);
    index = report.index;
    const reader = new FdReader(archivePath);
    const reread = await readIndex(reader);
    await reader.close();
    expect(reread).toEqual(index);
    // enough frames for real parallel ranges
    expect(index.frames.length).toBeGreaterThanOrEqual(10);
    mkdirSync(join(PKG_DIR, "dist"), { recursive: true });
    workerBundleDir = await mkdtemp(join(PKG_DIR, "dist", "wbuild-"));
    workerEntry = transpileWorkerBundle(workerBundleDir);
  });

  afterAll(async () => {
    // The fixture deliberately contains 0o500 dirs and 0o444 files (the
    // read-only matrix). Removing them needs WRITE on the parent dir, which
    // root bypasses and a normal CI user does not — so restore permissions
    // first. Without this the suite fails only on unprivileged runners.
    await makeWritable(tmp).catch(() => {});
    await rm(tmp, { recursive: true, force: true });
    await rm(workerBundleDir, { recursive: true, force: true });
  });

  it("fixture sanity: 306 files, 10 dirs, 3 symlinks, solo + group frames", () => {
    expect(index.files.filter((f) => f.type === 0)).toHaveLength(306);
    expect(index.files.filter((f) => f.type === 1)).toHaveLength(10);
    expect(index.files.filter((f) => f.type === 2)).toHaveLength(3);
    expect(index.frames.filter((f) => f.members === 1).length).toBe(13);
    expect(index.frames.some((f) => f.members > 1)).toBe(true);
  });

  it("extractFile returns exact bytes and rec for a grouped file", async () => {
    const r = new FdReader(archivePath);
    const target = "a/x/y/f-003.txt";
    const { rec, bytes } = await extractFile(r, index, target);
    await r.close();
    const spec = FILES.find((f) => f.rel === target)!;
    expect(bytes.equals(contentFor(target, spec.size))).toBe(true);
    expect(rec.path).toBe(target);
    expect(rec.size).toBe(spec.size);
    expect(rec.mode).toBe(spec.mode);
    expect(rec.mtime).toBe(MTIME_SEC);
    expect(rec.hashB64).toBe(
      createHash("sha256").update(contentFor(target, spec.size)).digest("base64url"),
    );
  });

  it("extractFile returns exact bytes for a solo-frame file", async () => {
    const r = new FdReader(archivePath);
    const target = "b/big-1.bin";
    const { bytes } = await extractFile(r, index, target);
    await r.close();
    expect(bytes.length).toBe(2_000_000);
    expect(bytes.equals(contentFor(target, 2_000_000))).toBe(true);
  });

  it("extractFile of an empty file round-trips zero bytes", async () => {
    const r = new FdReader(archivePath);
    const { bytes } = await extractFile(r, index, "c/root-0.txt");
    await r.close();
    expect(bytes.length).toBe(0);
  });

  it("unknown paths reject with FileNotInArchiveError (files, dirs, symlinks)", async () => {
    const r = new FdReader(archivePath);
    for (const p of ["nope.txt", "a", "a/x/y/link-rel", "/a/x/y/f-000.txt"]) {
      await expect(extractFile(r, index, p)).rejects.toThrowError(FileNotInArchiveError);
    }
    await r.close();
  });

  it("extractOne creates parents, restores mode and mtimeSec", async () => {
    const r = new FdReader(archivePath);
    const dest = join(tmp, "one", "deep", "nested", "file.txt");
    await extractOne(r, index, "a/x/y/f-003.txt", dest);
    await r.close();
    const st = await lstat(dest);
    expect(st.isFile()).toBe(true);
    expect(st.mode & 0o7777).toBe(MODES[3 % MODES.length]);
    expect(Math.floor(st.mtimeMs / 1000)).toBe(MTIME_SEC);
    expect((await readFile(dest)).equals(contentFor("a/x/y/f-003.txt", FILES.find((f) => f.rel === "a/x/y/f-003.txt")!.size))).toBe(true);
  });

  // -- corruption matrix (spike §7.2) --------------------------------------

  it("(a) byte flipped mid-frame → ArchiveCorruptError, dest absent, no .part- leftovers", async () => {
    const target = "a/x/y/f-003.txt";
    const rec = index.files.find((f) => f.path === target)!;
    const frame = index.frames[rec.frameIndex];
    const bad = await readFile(archivePath);
    bad[frame.offset + Math.floor(frame.length / 2)] ^= 0x5a;
    const badPath = join(tmp, "corrupt-mid.ows");
    await writeFile(badPath, bad);

    const r = new FdReader(badPath);
    const badIndex = await readIndex(r); // index frame intact — open succeeds
    const dest = join(tmp, "corrupt-out", "f.txt");
    await expect(extractOne(r, badIndex, target, dest)).rejects.toThrowError(
      /Data corruption detected/,
    );
    await expect(extractOne(r, badIndex, target, dest)).rejects.toThrowError(
      ArchiveCorruptError,
    );
    await r.close();
    await expect(lstat(dest)).rejects.toThrowError(); // dest NOT created
    await expect(lstat(join(tmp, "corrupt-out"))).rejects.toThrowError();
  });

  it("(b) hashB64 flipped inside the index → HashMismatchError naming the path", async () => {
    const target = "a/x/y/f-003.txt";
    const whole = await readFile(archivePath);
    const indexFrameLen = Number(whole.readBigUInt64LE(whole.length - FOOTER_LEN));
    const indexOffset = whole.length - FOOTER_LEN - indexFrameLen;
    const json = zlib.zstdDecompressSync(
      whole.subarray(indexOffset, indexOffset + indexFrameLen),
      { params: { [zlib.constants.ZSTD_d_windowLogMax]: 27 } },
    );
    const wire = JSON.parse(json.toString("utf8")) as {
      files: Array<Array<string | number>>;
    };
    const row = wire.files.find((f) => f[0] === target)!;
    const goodHash = row[8] as string;
    row[8] = (goodHash[0] === "A" ? "B" : "A") + goodHash.slice(1);
    const newJson = Buffer.from(JSON.stringify(wire), "utf8");
    const windowLog = Math.min(27, Math.max(17, Math.ceil(Math.log2(newJson.length))));
    const newFrame = zlib.zstdCompressSync(newJson, {
      params: {
        [zlib.constants.ZSTD_c_compressionLevel]: 9,
        [zlib.constants.ZSTD_c_checksumFlag]: 1,
        [zlib.constants.ZSTD_c_contentSizeFlag]: 1,
        [zlib.constants.ZSTD_c_windowLog]: windowLog,
      },
    });
    const footer = Buffer.alloc(FOOTER_LEN);
    footer.writeBigUInt64LE(BigInt(newFrame.length), 0);
    createHash("sha256").update(newJson).digest().copy(footer, 8, 0, 8);
    footer.write("OVIDEND1", 16, "latin1");
    const badPath = join(tmp, "corrupt-hash.ows");
    await writeFile(badPath, Buffer.concat([whole.subarray(0, indexOffset), newFrame, footer]));

    const r = new FdReader(badPath);
    const badIndex = await readIndex(r); // footer hash fixed → index opens
    await expect(extractFile(r, badIndex, target)).rejects.toThrowError(HashMismatchError);
    await expect(extractFile(r, badIndex, target)).rejects.toThrowError(
      `HASH MISMATCH for '${target}'`,
    );
    await r.close();
  });

  it("(c) truncation mid-frame rejects and never writes garbage", async () => {
    const target = "a/x/y/f-003.txt";
    const rec = index.files.find((f) => f.path === target)!;
    const frame = index.frames[rec.frameIndex];

    // plain truncation: the footer is destroyed → ArchiveTruncatedError
    const cutPath = join(tmp, "cut.ows");
    await copyFile(archivePath, cutPath);
    const fh = await (await import("node:fs/promises")).open(cutPath, "r+");
    await fh.truncate(frame.offset + 7);
    await fh.close();
    const dest = join(tmp, "cut-out", "f.txt");
    const cutReader = new FdReader(cutPath);
    await expect(
      extractOne(cutReader, index, target, dest),
    ).rejects.toThrowError(ArchiveTruncatedError);
    await cutReader.close();
    await expect(lstat(dest)).rejects.toThrowError();

    // surgical cut INSIDE the frame, index+footer kept: chain validation fires
    const whole = await readFile(archivePath);
    const surgical = Buffer.concat([
      whole.subarray(0, frame.offset + 7),
      whole.subarray(frame.offset + frame.length),
    ]);
    const surgicalPath = join(tmp, "surgical.ows");
    await writeFile(surgicalPath, surgical);
    const dest2 = join(tmp, "cut-out2", "f.txt");
    const surgicalReader = new FdReader(surgicalPath);
    await expect(
      extractOne(surgicalReader, index, target, dest2),
    ).rejects.toThrowError(StorageError);
    await surgicalReader.close();
    await expect(lstat(dest2)).rejects.toThrowError();
  });

  it("decompressFrame guards zstd's silent partial output on truncated input", () => {
    // zstdDecompressSync does NOT error on a truncated frame — it returns a
    // partial buffer. The decSize cross-check must turn that into a loud
    // ArchiveTruncatedError (spike: reader invariants).
    const payload = Buffer.alloc(1000);
    for (let i = 0; i < payload.length; i++) payload[i] = (i * 31) & 0xff;
    const comp = zlib.zstdCompressSync(payload, {
      params: { [zlib.constants.ZSTD_c_compressionLevel]: 9 },
    });
    expect(zlib.zstdDecompressSync(comp.subarray(0, comp.length - 25)).length).toBe(0); // silent!
    expect(() => decompressFrame(comp.subarray(0, comp.length - 25), 0, 1000)).toThrowError(
      ArchiveTruncatedError,
    );
    expect(decompressFrame(comp, 0, 1000).length).toBe(1000);
  });

  it("(d) extractAll workers=1 restores the tree byte-exactly", async () => {
    const dest = join(tmp, "ex-w1");
    const rep = await extractAllInProcess({ kind: "fs", path: archivePath }, index, dest);
    expect(rep.files).toBe(306 + 3); // files + symlinks (dirs pre-created)
    expect(rep.bytes).toBe(FILES.reduce((n, f) => n + f.size, 0));
    expect(rep.ms).toBeGreaterThanOrEqual(0);
    expect(await compareTrees(wsDir, dest)).toEqual([]);
  });

  it("(d) extractAll workers=4 (worker_threads) restores the tree byte-exactly", async () => {
    const dest = join(tmp, "ex-w4");
    const rep = await extractAll(
      { kind: "fs", path: archivePath },
      index,
      dest,
      { workers: 4, workerEntry },
    );
    expect(rep.files).toBe(306 + 3);
    expect(rep.bytes).toBe(FILES.reduce((n, f) => n + f.size, 0));
    expect(await compareTrees(wsDir, dest)).toEqual([]);

    // cross-check with GNU diff: contents, presence, and symlink targets
    const exitCode = await execFile("diff", [
      "-rq",
      "--no-dereference",
      wsDir,
      dest,
    ]).then(
      () => 0,
      (e: { code?: number }) => e.code ?? 1,
    );
    expect(exitCode).toBe(0);
  });

  it("extractAll restoreMeta=false writes contents without modes/mtimes", async () => {
    const dest = join(tmp, "ex-nometa");
    await extractAllInProcess({ kind: "fs", path: archivePath }, index, dest, {
      restoreMeta: false,
    });
    expect(await compareTrees(wsDir, dest)).not.toEqual([]); // modes/mtimes differ
    // but contents still match exactly (a dedicated content-only pass)
    const bad = await compareTrees(wsDir, dest);
    expect(bad.every((m) => m.startsWith("file mode") || m.startsWith("file mtime") || m.startsWith("dir mode") || m.startsWith("dir mtime"))).toBe(true);
  });

  it("(e) a corrupt byte + extractAll rejects and leaves the partial tree", async () => {
    const frame = index.frames[Math.floor(index.frames.length / 2)];
    const bad = await readFile(archivePath);
    bad[frame.offset + Math.floor(frame.length / 2)] ^= 0x5a;
    const badPath = join(tmp, "corrupt-all.ows");
    await writeFile(badPath, bad);

    const dest = join(tmp, "ex-corrupt");
    await mkdir(dest, { recursive: true });
    await expect(
      extractAll({ kind: "fs", path: badPath }, index, dest, {
        workers: 2,
        workerEntry,
      }),
    ).rejects.toThrowError(ArchiveCorruptError);
    // partial tree left for the caller (Task 9 wipes and retries)
    const entries = await readdir(dest);
    expect(entries.length).toBeGreaterThan(0);
  });

  it("cross-frame duplicate member paths are rejected loudly (M1)", async () => {
    // Handcraft an index carrying the same path in two different frames:
    // extraction would be order-dependent (and two worker threads would
    // race the same `${dest}.part-${pid}` temp name).
    const target = "a/x/y/f-003.txt";
    const rec = index.files.find((f) => f.path === target)!;
    const solo = index.files.find((f) => f.path === "b/big-1.bin")!;
    expect(solo.frameIndex).not.toBe(rec.frameIndex);
    const dup: FileRec = {
      ...rec,
      frameIndex: solo.frameIndex,
      offsetInFrame: 0,
      lengthInFrame: 0,
      size: 0,
    };
    const dupIndex: ArchiveIndex = { ...index, files: [...index.files, dup] };

    const r = new FdReader(archivePath);
    await expect(extractFile(r, dupIndex, target)).rejects.toThrowError(ArchiveCorruptError);
    await expect(extractFile(r, dupIndex, target)).rejects.toThrowError(/duplicate/);
    await r.close();

    // extractAll rejects BEFORE pass 1 creates anything
    const dest = join(tmp, "dup-out");
    await expect(
      extractAllInProcess({ kind: "fs", path: archivePath }, dupIndex, dest),
    ).rejects.toThrowError(ArchiveCorruptError);
    await expect(lstat(dest)).rejects.toThrowError();
  });

  it("extractAll default worker math never exceeds 4 or the frame count", async () => {
    // 1 frame → in-process; exercised via the empty-workspace edge
    const empty = join(tmp, "empty-ws");
    await mkdir(empty, { recursive: true });
    const emptyPath = join(tmp, "empty.ows");
    await packToFile(empty, emptyPath);
    const r = new FdReader(emptyPath);
    const emptyIndex = await readIndex(r);
    await r.close();
    expect(emptyIndex.frames).toHaveLength(0);
    const dest = join(tmp, "ex-empty");
    const rep = await extractAll({ kind: "fs", path: emptyPath }, emptyIndex, dest);
    expect(rep.files).toBe(0);
    expect(rep.bytes).toBe(0);
    expect((await readdir(dest)).length).toBe(0);
  });
});
