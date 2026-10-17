import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

// P7's landed store — relative-source import per the accepted P7-T1 pattern:
// no new package edge / lockfile change mid-wave, and vitest transforms live
// src so a stale dist/ can never satisfy the equality pin. Tests are excluded
// from the build tsconfig, so this import never hits `tsc -p` rootDir.
import { createBrowserStateBlobStore } from "../../storage/src/browserState.js";
import { createFsStorage } from "../../storage/src/fsAdapter.js";
import { r2Keys } from "../../storage/src/keys.js";

import {
  browserStateKeyPath,
  createLocalDiskBrowserStateStore,
  createStorageStatePersistence,
  DEFAULT_PROFILE_ID,
  type BrowserStateBlobStore,
} from "./stateStore.js";
import {
  BROWSER_STATE_MAGIC,
  BrowserStateError,
  type StorageCookie,
  type StorageState,
} from "./storageState.js";

const KEY = "test-master-key";

function cookie(name: string, domain: string, extra: Partial<StorageCookie> = {}): StorageCookie {
  return {
    value: "v",
    path: "/",
    expires: -1,
    httpOnly: false,
    secure: false,
    sameSite: "Lax",
    ...extra,
    name,
    domain,
  };
}

describe("createLocalDiskBrowserStateStore", () => {
  let root: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-state-store-"));
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it("browserStateKeyPath is `users/{userId}/browser/{profileId}.zst` (spec §10)", () => {
    expect(browserStateKeyPath("u1", "main")).toBe("users/u1/browser/main.zst");
  });

  it("save → load round-trips byte-identical; save reports key/bytes/sha256Hex", async () => {
    const store = createLocalDiskBrowserStateStore(root);
    const blob = Buffer.from("opaque envelope bytes \x00\x01");
    const saved = await store.save("u1", "p1", blob);
    expect(saved).toEqual({
      key: browserStateKeyPath("u1", "p1"),
      bytes: blob.byteLength,
      sha256Hex: createHash("sha256").update(blob).digest("hex"),
    });
    const back = await store.load("u1", "p1");
    expect(back).not.toBeNull();
    expect(back!.equals(blob)).toBe(true);
  });

  it("load of a missing profile → null", async () => {
    const store = createLocalDiskBrowserStateStore(root);
    expect(await store.load("u1", DEFAULT_PROFILE_ID)).toBeNull();
  });

  it("remove → load → null, and remove is idempotent", async () => {
    const store = createLocalDiskBrowserStateStore(root);
    const blob = Buffer.from("opaque envelope bytes");
    await store.save("u1", DEFAULT_PROFILE_ID, blob);
    await store.remove("u1", DEFAULT_PROFILE_ID);
    expect(await store.load("u1", DEFAULT_PROFILE_ID)).toBeNull();
    await expect(store.remove("u1", DEFAULT_PROFILE_ID)).resolves.toBeUndefined();
  });

  it("path-traversal guard: `../evil` userId (or profileId) throws on save/load/remove", async () => {
    const store = createLocalDiskBrowserStateStore(root);
    const blob = Buffer.from("x");
    await expect(store.save("../evil", "p", blob)).rejects.toBeInstanceOf(BrowserStateError);
    await expect(store.load("../evil", "p")).rejects.toBeInstanceOf(BrowserStateError);
    await expect(store.remove("../evil", "p")).rejects.toBeInstanceOf(BrowserStateError);
    await expect(store.save("u1", "../evil", blob)).rejects.toBeInstanceOf(BrowserStateError);
    await expect(store.load("u1", "../evil")).rejects.toBeInstanceOf(BrowserStateError);
    await expect(store.remove("u1", "../evil")).rejects.toBeInstanceOf(BrowserStateError);
  });
});

describe("createStorageStatePersistence (local-disk store)", () => {
  let root: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-persistence-"));
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it("flush then restore round-trips through the encrypted envelope (no plaintext on disk)", async () => {
    const store = createLocalDiskBrowserStateStore(root);
    const persist = createStorageStatePersistence(store, KEY);
    const captured: StorageState = {
      cookies: [cookie("login_tok", "site.test", { value: "tok" })],
      origins: [{ origin: "https://site.test/", localStorage: [{ name: "theme", value: "dark" }] }],
    };
    await persist.flush("u1", captured);
    const restored = await persist.restore("u1");
    expect(restored).toEqual(captured);
    // what landed on disk is the binary envelope, not the JSON state
    const raw = await store.load("u1", DEFAULT_PROFILE_ID);
    expect(raw).not.toBeNull();
    expect(raw!.subarray(0, 8).toString("utf8")).toBe(BROWSER_STATE_MAGIC);
    expect(raw!.toString("utf8")).not.toContain("login_tok");
  });

  it("concurrent flushes with different captured domains both land (mutex + read-modify-write)", async () => {
    const persist = createStorageStatePersistence(createLocalDiskBrowserStateStore(root), KEY);
    const a: StorageState = { cookies: [cookie("a", "a.test")], origins: [] };
    const b: StorageState = { cookies: [cookie("b", "b.test")], origins: [] };
    await Promise.all([persist.flush("u1", a), persist.flush("u1", b)]);
    const restored = await persist.restore("u1");
    expect(restored).not.toBeNull();
    expect(restored!.cookies.map((c) => c.domain).sort()).toEqual(["a.test", "b.test"]);
  });

  it("restore of an absent state → null, nothing logged", async () => {
    const calls: unknown[][] = [];
    const persist = createStorageStatePersistence(createLocalDiskBrowserStateStore(root), KEY, {
      log: (msg, err) => calls.push([msg, err]),
    });
    expect(await persist.restore("u1")).toBeNull();
    expect(calls).toHaveLength(0);
  });

  it("corrupt stored blob → restore returns null and the BrowserStateError was logged (fresh start, RF#5)", async () => {
    const store = createLocalDiskBrowserStateStore(root);
    const calls: unknown[][] = [];
    const persist = createStorageStatePersistence(store, KEY, {
      log: (msg, err) => calls.push([msg, err]),
    });
    await store.save("u1", DEFAULT_PROFILE_ID, Buffer.from("not an ovid browser state blob"));
    expect(await persist.restore("u1")).toBeNull();
    expect(calls).toHaveLength(1);
    expect(calls[0][1]).toBeInstanceOf(BrowserStateError);
  });
});

describe("P7 seam equality (landed BrowserStateBlobStore)", () => {
  let root: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-p7-seam-"));
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it("browserStateKeyPath matches P7's r2Keys.browserState verbatim", () => {
    for (const [u, p] of [
      ["u1", "main"],
      ["user-2", "profile_3"],
    ] as const) {
      expect(browserStateKeyPath(u, p)).toBe(r2Keys.browserState(u, p));
    }
  });

  it("P7's landed store satisfies P6's BrowserStateBlobStore seam shape", async () => {
    const p7: BrowserStateBlobStore = createBrowserStateBlobStore(createFsStorage(root));
    const blob = Buffer.from("shared opaque envelope bytes");
    const saved = await p7.save("u1", DEFAULT_PROFILE_ID, blob);
    expect(saved.key).toBe(browserStateKeyPath("u1", DEFAULT_PROFILE_ID));
    expect(saved.bytes).toBe(blob.byteLength);
    expect(saved.sha256Hex).toBe(createHash("sha256").update(blob).digest("hex"));
    const back = await p7.load("u1", DEFAULT_PROFILE_ID);
    expect(back).not.toBeNull();
    expect(back!.equals(blob)).toBe(true);
    await p7.remove("u1", DEFAULT_PROFILE_ID);
    expect(await p7.load("u1", DEFAULT_PROFILE_ID)).toBeNull();
  });

  it("P6 local-disk store and P7's store agree on key/bytes/sha256 for the same blob", async () => {
    const p6 = createLocalDiskBrowserStateStore(join(root, "p6"));
    const p7 = createBrowserStateBlobStore(createFsStorage(join(root, "p7")));
    const blob = Buffer.from("same opaque bytes through both stores");
    const a = await p6.save("u1", "main", blob);
    const b = await p7.save("u1", "main", blob);
    expect(b).toEqual({ key: a.key, bytes: a.bytes, sha256Hex: a.sha256Hex });
    const fromP6 = await p6.load("u1", "main");
    const fromP7 = await p7.load("u1", "main");
    expect(fromP6).not.toBeNull();
    expect(fromP7).not.toBeNull();
    expect(fromP7!.equals(fromP6!)).toBe(true);
  });

  it("persistence runs end-to-end over P7's landed store (flush → restore)", async () => {
    const persist = createStorageStatePersistence(
      createBrowserStateBlobStore(createFsStorage(root)),
      KEY,
    );
    const captured: StorageState = {
      cookies: [cookie("login_tok", "site.test")],
      origins: [],
    };
    await persist.flush("u1", captured);
    expect(await persist.restore("u1")).toEqual(captured);
  });
});
