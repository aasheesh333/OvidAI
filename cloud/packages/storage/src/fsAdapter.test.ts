import { execFile as execFileCb } from "node:child_process";
import { mkdtemp, readdir, rm, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { Readable } from "node:stream";
import { afterEach, beforeEach, afterAll, beforeAll, describe, expect, it } from "vitest";

import { createFsStorage } from "./fsAdapter.js";
import { KeyLayoutError } from "./errors.js";
import { storageContractSuite } from "./contract.js";

const execFile = promisify(execFileCb);
const PKG_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DIST_INDEX = join(PKG_DIR, "dist", "index.js");

const describeStorageContract = storageContractSuite({
  describe,
  it,
  expect,
  beforeAll,
  afterAll,
});

describeStorageContract("fs", async () => {
  const root = await mkdtemp(join(tmpdir(), "ovid-storage-contract-"));
  return { adapter: createFsStorage(root), cleanup: () => rm(root, { recursive: true, force: true }) };
});

describe("package entry loads under plain Node", () => {
  // The contract suite takes injected framework fns precisely so no src
  // module imports vitest at runtime — dist/index.js must import cleanly
  // in a bare node process (M2, T9-blocking). Skipped when dist/ has not
  // been built yet (tests are usually run straight from src).
  it.skipIf(!existsSync(DIST_INDEX))("dist/index.js imports in a child node process", async () => {
    const { stderr } = await execFile(
      process.execPath,
      ["-e", "await import(process.argv[1])", DIST_INDEX],
      { encoding: "utf8" },
    );
    expect(stderr).toBe("");
  });
});

describe("createFsStorage — fs-specific pins", () => {
  let root: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-storage-fs-"));
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it("put of a multi-chunk Readable round-trips with sha256 + byte count", async () => {
    const adapter = createFsStorage(root);
    const chunks = ["hello ", "world ", "of ", "streams"];
    const body = Readable.from(chunks);
    const { key, bytes } = await adapter.put("users/u1/workspaces/s1.tar.zst", body, {
      contentType: "application/zstd",
      metadata: { sessionId: "s1" },
    });
    expect(key).toBe("users/u1/workspaces/s1.tar.zst");
    expect(bytes).toBe(chunks.join("").length);

    const head = await adapter.head(key);
    expect(head).not.toBeNull();
    expect(head!.bytes).toBe(chunks.join("").length);
    const expectedHash = await import("node:crypto").then(({ createHash }) =>
      createHash("sha256").update(chunks.join("")).digest("hex"),
    );
    expect(head!.sha256Hex).toBe(expectedHash);
    expect(head!.metadata).toEqual({ sessionId: "s1" });
    expect(head!.etag).toBeTypeOf("string");

    const back = await adapter.getBuffer(key);
    expect(back!.toString()).toBe(chunks.join(""));
  });

  it("get() stream reassembles to identical bytes", async () => {
    const adapter = createFsStorage(root);
    const payload = Buffer.from("0123456789abcdef".repeat(100));
    await adapter.put("blob.bin", payload);
    const stream = await adapter.get("blob.bin");
    expect(stream).not.toBeNull();
    const chunks: Buffer[] = [];
    for await (const c of stream!) chunks.push(c as Buffer);
    expect(Buffer.concat(chunks).equals(payload)).toBe(true);
  });

  it("missing key → get/getBuffer/head/readerSpec all null, delete idempotent", async () => {
    const adapter = createFsStorage(root);
    expect(await adapter.get("no/such/key")).toBeNull();
    expect(await adapter.getBuffer("no/such/key")).toBeNull();
    expect(await adapter.head("no/such/key")).toBeNull();
    expect(await adapter.readerSpec("no/such/key")).toBeNull();
    await expect(adapter.delete("no/such/key")).resolves.toBeUndefined();
  });

  it("put with an escaping key rejects with KeyLayoutError and writes nothing outside root", async () => {
    const adapter = createFsStorage(root);
    await expect(adapter.put("../escape", Buffer.from("x"))).rejects.toBeInstanceOf(KeyLayoutError);
    const entries = await readdir(root);
    expect(entries).toEqual([]);
    const outside = join(root, "..", "escape");
    await expect(stat(outside)).rejects.toThrow();
  });

  it("put with a traversal-form key (a/../../b) rejects", async () => {
    const adapter = createFsStorage(root);
    await expect(adapter.put("a/../../b", Buffer.from("x"))).rejects.toBeInstanceOf(KeyLayoutError);
  });

  it("an interrupted put leaves no final object (only a .part- file)", async () => {
    const adapter = createFsStorage(root);
    const boom = Readable.from(
      (async function* () {
        yield "chunk1";
        throw new Error("interrupted");
      })(),
    );
    await expect(adapter.put("partial.bin", boom)).rejects.toThrow(/interrupted/);
    // no final object
    expect(await adapter.getBuffer("partial.bin")).toBeNull();
    // ...and only a stray .part- file on disk (an implementation detail we
    // pin: the atomic-rename contract means no torn object is ever visible).
    const files = await readdir(join(root, "partial.bin", "..").normalize());
    expect(files.some((f) => f.startsWith("partial.bin.part-"))).toBe(true);
    expect(files).not.toContain("partial.bin");
  });

  it("presignGet/presignPut return fs pseudo-URLs with an expiry stamp", async () => {
    const adapter = createFsStorage(root);
    await adapter.put("k.bin", Buffer.from("v"));
    const g = await adapter.presignGet("k.bin", 60);
    const p = await adapter.presignPut("k.bin", 60);
    expect(g).toMatch(/^file:\/\/\/.*#ovid-exp=\d+$/);
    expect(p).toMatch(/^file:\/\/\/.*#ovid-exp=\d+$/);
  });

  it("delete removes the object (and its sidecars)", async () => {
    const adapter = createFsStorage(root);
    await adapter.put("gone.bin", Buffer.from("v"));
    await adapter.delete("gone.bin");
    expect(await adapter.getBuffer("gone.bin")).toBeNull();
    expect(await adapter.head("gone.bin")).toBeNull();
  });

  it("kind is \"fs\"", async () => {
    expect(createFsStorage(root).kind).toBe("fs");
  });
});
