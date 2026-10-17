import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { FdReader, openReader } from "./rangeReader.js";
import { StorageError } from "./errors.js";

describe("FdReader", () => {
  let dir: string;
  let path: string;
  const data = Buffer.alloc(10_240);
  for (let i = 0; i < data.length; i++) data[i] = i % 251;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "ovid-range-"));
    path = join(dir, "blob.bin");
    await writeFile(path, data);
  });

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("size() reports the file length", async () => {
    const r = new FdReader(path);
    expect(await r.size()).toBe(10_240);
    await r.close();
  });

  it("read(4096, 100) returns the exact slice", async () => {
    const r = new FdReader(path);
    const got = await r.read(4096, 100);
    expect(got.equals(data.subarray(4096, 4196))).toBe(true);
    await r.close();
  });

  it("read(10200, 100) rejects StorageError (short read past EOF)", async () => {
    const r = new FdReader(path);
    await expect(r.read(10_200, 100)).rejects.toBeInstanceOf(StorageError);
    await r.close();
  });

  it("read() of the final exact byte range succeeds", async () => {
    const r = new FdReader(path);
    const got = await r.read(10_140, 100);
    expect(got.equals(data.subarray(10_140))).toBe(true);
    await r.close();
  });

  it("openReader({kind:\"fs\"}) returns an FdReader over the path", async () => {
    const r = await openReader({ kind: "fs", path });
    expect(r).toBeInstanceOf(FdReader);
    expect(await r.size()).toBe(10_240);
    const got = await r.read(0, 8);
    expect(got.equals(data.subarray(0, 8))).toBe(true);
    await r.close();
  });
});
