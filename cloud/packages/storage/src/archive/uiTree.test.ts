/**
 * Task 4 — uiTree/liveTree tests (TDD step 6 of the brief).
 *
 * Same fixture shape as pack.test.ts:
 *   a/{empty.txt(0),k.txt(1024,0755),one.txt(1)}  b/{big.bin(5M),over.bin(262145),under.bin(262143)}
 *   b/z/link -> ../../a/one.txt
 *
 * totals (over type-0 recs only — symlinks are not counted, v1):
 *   files 6, dirs 3, bytes 5_525_313.
 */

import { once } from "node:events";
import { chmod, mkdir, mkdtemp, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { createWriteStream } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { UI_MANIFEST_MAX_BYTES } from "@ovid/shared";

import { FdReader } from "../rangeReader.js";
import { pack, type ArchiveIndex, type FileRec } from "./pack.js";
import { readIndex } from "./readIndex.js";
import { liveTree, uiTree } from "./uiTree.js";

const MTIME = new Date("2026-10-01T00:00:00.000Z");
const NOW = () => new Date("2026-10-16T09:00:00.000Z");
const MTIME_SEC = Math.floor(MTIME.getTime() / 1000);
const MTIME_ISO = "2026-10-01T00:00:00Z"; // second precision, no ms component

const FILE_SIZES: Array<[string, number]> = [
  ["a/empty.txt", 0],
  ["a/one.txt", 1],
  ["a/k.txt", 1024],
  ["b/under.bin", 262_143],
  ["b/over.bin", 262_145],
  ["b/big.bin", 5_000_000],
];

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
  const { lutimes } = await import("node:fs/promises");
  for (const [rel] of FILE_SIZES) await utimes(join(wsDir, rel), MTIME, MTIME);
  for (const d of ["a", "b", "b/z"]) await utimes(join(wsDir, d), MTIME, MTIME);
  await lutimes(join(wsDir, "b/z/link"), MTIME, MTIME);
}

/** Deep count of non-dir nodes currently visible in the tree. */
function visibleNonDirs(roots: Array<{ type: string; children?: unknown[] }>): number {
  let n = 0;
  const walk = (nodes: Array<{ type: string; children?: unknown[] }>): void => {
    for (const node of nodes) {
      if (node.type === "dir") {
        walk((node.children ?? []) as Array<{ type: string; children?: unknown[] }>);
      } else {
        n++;
      }
    }
  };
  walk(roots);
  return n;
}

/** Sum of every `omitted` counter anywhere in the tree. */
function sumOmitted(roots: Array<{ children?: unknown[]; omitted?: number }>): number {
  let n = 0;
  const walk = (nodes: Array<{ children?: unknown[]; omitted?: number }>): void => {
    for (const node of nodes) {
      n += node.omitted ?? 0;
      walk((node.children ?? []) as Array<{ children?: unknown[]; omitted?: number }>);
    }
  };
  walk(roots);
  return n;
}

describe("uiTree — fixture index", () => {
  let tmp: string;
  let wsDir: string;
  let index: ArchiveIndex;

  beforeAll(async () => {
    tmp = await mkdtemp(join(tmpdir(), "ovid-tree-"));
    wsDir = join(tmp, "ws");
    await buildFixture(wsDir);
    const archivePath = join(tmp, "ws.ows");
    const ws = createWriteStream(archivePath);
    await pack(wsDir, ws, { now: NOW });
    ws.end();
    await once(ws, "close");
    const reader = new FdReader(archivePath);
    index = await readIndex(reader);
    await reader.close();
  });

  afterAll(async () => {
    await rm(tmp, { recursive: true, force: true });
  });

  it("depth-2 shape: roots expanded, depth-2 dirs carry rollups with no children", () => {
    const tree = uiTree(index, { now: NOW });
    expect(tree.version).toBe(1);
    expect(tree.truncated).toBe(false);

    const rootNames = tree.roots.map((r) => r.name);
    expect(rootNames).toEqual(["a", "b"]); // dirs first, byte-wise name order

    const a = tree.roots[0];
    expect(a.type).toBe("dir");
    expect(a.mtime).toBe(MTIME_ISO);
    expect(a.children!.map((c) => c.name)).toEqual(["k.txt", "one.txt", "empty.txt"]); // size desc
    expect(a.children!.map((c) => c.type)).toEqual(["file", "file", "file"]);
    expect(a.children![0].sizeBytes).toBe(1024);
    expect(a.children![0].mtime).toBe(MTIME_ISO);

    const b = tree.roots[1];
    expect(b.children!.map((c) => c.name)).toEqual([
      "z", // subdirs first
      "big.bin",
      "over.bin",
      "under.bin", // size desc, then name asc (262_145 vs 262_143 differ)
    ]);

    const z = b.children![0];
    expect(z.type).toBe("dir");
    expect(z.mtime).toBe(MTIME_ISO);
    // b/z holds only the symlink; symlinks are not counted in rollups (v1)
    expect(z.files).toBe(0);
    expect(z.bytes).toBe(0);
    expect(z.dirs).toBe(0);
    expect(z.children).toBeUndefined();

    // no root-level rollups on expanded dirs
    expect(a.files).toBeUndefined();
    expect(b.bytes).toBeUndefined();
  });

  it("depth-1: every dir pruned to rollups", () => {
    const tree = uiTree(index, { depth: 1, now: NOW });
    expect(tree.roots.map((r) => r.name)).toEqual(["a", "b"]);
    const [a, b] = tree.roots;
    expect(a.children).toBeUndefined();
    expect(a.files).toBe(3);
    expect(a.bytes).toBe(1025);
    expect(a.dirs).toBe(0);
    expect(b.children).toBeUndefined();
    expect(b.files).toBe(3);
    expect(b.bytes).toBe(262_143 + 262_145 + 5_000_000);
    expect(b.dirs).toBe(1);
  });

  it("totals are exact integers over the full index", () => {
    const tree = uiTree(index, { now: NOW });
    expect(tree.totals).toEqual({
      files: 6,
      dirs: 3,
      bytes: 5_525_313,
    });
  });

  it("serialized tree fits the UI manifest budget", () => {
    const tree = uiTree(index, { now: NOW });
    expect(Buffer.byteLength(JSON.stringify(tree))).toBeLessThanOrEqual(
      UI_MANIFEST_MAX_BYTES,
    );
  });

  it("deterministic: same input and now -> identical JSON", () => {
    const t1 = uiTree(index, { now: NOW });
    const t2 = uiTree(index, { now: NOW });
    expect(JSON.stringify(t1)).toBe(JSON.stringify(t2));
  });

  it("liveTree deep-equals uiTree of the packed index (modulo generatedAt)", async () => {
    const fromIndex = uiTree(index, { now: NOW });
    const fromLive = await liveTree(wsDir, { now: NOW });
    expect(fromLive.generatedAt).toBe(fromIndex.generatedAt);
    expect(JSON.stringify(fromLive)).toBe(JSON.stringify(fromIndex));
  });
});

describe("uiTree — synthetic 5000-file index", () => {
  const N = 5000;

  function syntheticIndex(): ArchiveIndex {
    const files: FileRec[] = [
      {
        // a visible symlink: sorts first among non-dirs (largest sizeBytes)
        path: "d/link0",
        type: 2,
        size: 99_999,
        mode: 0o777,
        mtime: MTIME_SEC,
        frameIndex: 0,
        offsetInFrame: 0,
        lengthInFrame: 0,
        hashB64: "",
        target: "../x",
      },
    ];
    for (let i = 0; i < N; i++) {
      files.push({
        path: `d/f${String(i).padStart(4, "0")}.txt`,
        type: 0,
        size: 100 + (i % 50),
        mode: 0o644,
        mtime: MTIME_SEC,
        frameIndex: 0,
        offsetInFrame: 0,
        lengthInFrame: 100 + (i % 50),
        hashB64: "h",
      });
    }
    return {
      archiveVersion: 1,
      format: "ovid-ws-grouped-v1",
      zstdLevel: 9,
      createdAt: NOW().toISOString(),
      frames: [{ offset: 8, length: 1, decSize: 1, members: 1 }],
      files,
    };
  }

  it("stays within the budget, flags truncated, and omitted sums close exactly", () => {
    const index = syntheticIndex();
    const tree = uiTree(index, { now: NOW });

    expect(Buffer.byteLength(JSON.stringify(tree))).toBeLessThanOrEqual(
      UI_MANIFEST_MAX_BYTES,
    );
    expect(tree.truncated).toBe(true);

    // visible non-dirs + dropped siblings === all 5001 non-dir records
    // (the symlink rides in the same sibling list as the files)
    const visible = visibleNonDirs(tree.roots);
    const omitted = sumOmitted(tree.roots);
    expect(visible).toBeGreaterThan(0);
    expect(omitted).toBeGreaterThan(0);
    expect(visible + omitted).toBe(N + 1);

    // totals are over the full index regardless of visibility
    // sum(100 + i%50) over i=0..4999 = 500000 + 100*(0+1+...+49) = 622500
    expect(tree.totals).toEqual({ files: N, dirs: 0, bytes: 622_500 });

    // the synthetic dir node exists even without a dir record
    expect(tree.roots.map((r) => r.name)).toEqual(["d"]);
    // the symlink is visible and sorts first among the non-dir siblings
    const d = tree.roots[0];
    expect(d.children![0].type).toBe("symlink");
    expect(d.children![0].sizeBytes).toBe(99_999);
  });
});
