import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { createBrowserStateBlobStore } from "./browserState.js";
import { createFsStorage } from "./fsAdapter.js";
import { KeyLayoutError } from "./errors.js";
import { r2Keys } from "./keys.js";

describe("createBrowserStateBlobStore", () => {
  let root: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-browser-state-"));
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it("save → load round-trips byte-identical with matching sha256Hex", async () => {
    const store = createBrowserStateBlobStore(createFsStorage(root));
    const bytes = Buffer.from("zstd-ish opaque bytes");
    const saved = await store.save("u1", "profile-1", bytes);
    expect(saved.bytes).toBe(bytes.length);
    expect(saved.sha256Hex).toBe(createHash("sha256").update(bytes).digest("hex"));
    const back = await store.load("u1", "profile-1");
    expect(back).not.toBeNull();
    expect(back!.equals(bytes)).toBe(true);
  });

  it("load of a missing profile is null", async () => {
    const store = createBrowserStateBlobStore(createFsStorage(root));
    expect(await store.load("u1", "never-saved")).toBeNull();
  });

  it("remove deletes the blob", async () => {
    const store = createBrowserStateBlobStore(createFsStorage(root));
    await store.save("u1", "p1", Buffer.from("v"));
    await store.remove("u1", "p1");
    expect(await store.load("u1", "p1")).toBeNull();
  });

  it("profileId \"../evil\" rejects with KeyLayoutError", async () => {
    const store = createBrowserStateBlobStore(createFsStorage(root));
    await expect(store.save("u1", "../evil", Buffer.from("v"))).rejects.toBeInstanceOf(
      KeyLayoutError,
    );
    await expect(store.load("u1", "../evil")).rejects.toBeInstanceOf(KeyLayoutError);
  });

  it("uses the r2Keys.browserState key layout", async () => {
    const storage = createFsStorage(root);
    const store = createBrowserStateBlobStore(storage);
    const saved = await store.save("u1", "p1", Buffer.from("v"));
    expect(saved.key).toBe(r2Keys.browserState("u1", "p1"));
    expect(await storage.getBuffer(r2Keys.browserState("u1", "p1"))).not.toBeNull();
  });
});
