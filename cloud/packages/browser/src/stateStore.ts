/**
 * stateStore — the P7 blob-store seam + the storageState persistence service.
 *
 * P6 hands OPAQUE encrypted envelope bytes to `BrowserStateBlobStore` — P7's
 * landed Task-1 interface, exact shape. P7 OWNS the `browser_states` table and
 * the R2 object format (controller ruling R2): P6 never creates the table and
 * never inspects the bytes. `createLocalDiskBrowserStateStore` is the
 * local-disk impl for now; P7's `createBrowserStateBlobStore(storage)` is the
 * R2-backed impl — both satisfy this interface, so the swap is impl-only
 * (behavioral equality with P7's store is pinned in stateStore.test.ts via a
 * relative-source import).
 */

import { createHash, randomBytes } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

import {
  BrowserStateError,
  decodeBrowserState,
  encodeBrowserState,
  mergeStorageState,
  pruneStorageState,
  type StorageState,
} from "./storageState.js";

/** P7's landed interface, exact shape — opaque bytes in, opaque bytes out. */
export interface BrowserStateBlobStore {
  save(
    userId: string,
    profileId: string,
    blob: Uint8Array,
  ): Promise<{ key: string; bytes: number; sha256Hex: string }>;
  load(userId: string, profileId: string): Promise<Buffer | null>;
  remove(userId: string, profileId: string): Promise<void>;
}

export const DEFAULT_PROFILE_ID = "main";

/** `users/{userId}/browser/{profileId}.zst` — spec §10, identical to P7's r2Keys.browserState. */
export function browserStateKeyPath(userId: string, profileId: string): string {
  return `users/${userId}/browser/${profileId}.zst`;
}

// userId/profileId both land in filesystem paths — anything outside this set
// is a path-traversal attempt and throws before any fs call.
const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

function assertId(kind: "userId" | "profileId", id: string): void {
  if (!ID_RE.test(id)) {
    throw new BrowserStateError(
      `${kind} must match /^[A-Za-z0-9_-]{1,64}$/ (got ${JSON.stringify(id)})`,
    );
  }
}

/**
 * Local-disk `BrowserStateBlobStore`: raw blob bytes at
 * `${rootDir}/${browserStateKeyPath(...)}`, written atomically (tmp + rename)
 * so a torn write is never visible under the final key.
 */
export function createLocalDiskBrowserStateStore(rootDir: string): BrowserStateBlobStore {
  return {
    async save(userId, profileId, blob) {
      assertId("userId", userId);
      assertId("profileId", profileId);
      const key = browserStateKeyPath(userId, profileId);
      const path = join(rootDir, key);
      const bytes = Buffer.from(blob);
      const sha256Hex = createHash("sha256").update(bytes).digest("hex");
      await mkdir(dirname(path), { recursive: true });
      const tmp = `${path}.part-${process.pid}-${randomBytes(6).toString("hex")}`;
      try {
        await writeFile(tmp, bytes);
        await rename(tmp, path);
      } catch (err) {
        await rm(tmp, { force: true }).catch(() => {});
        throw err;
      }
      return { key, bytes: blob.byteLength, sha256Hex };
    },

    async load(userId, profileId) {
      assertId("userId", userId);
      assertId("profileId", profileId);
      try {
        return await readFile(join(rootDir, browserStateKeyPath(userId, profileId)));
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code === "ENOENT") return null;
        throw err;
      }
    },

    async remove(userId, profileId) {
      assertId("userId", userId);
      assertId("profileId", profileId);
      await rm(join(rootDir, browserStateKeyPath(userId, profileId)), { force: true });
    },
  };
}

// ---------------------------------------------------------------------------
// Persistence service (flush / restore)
// ---------------------------------------------------------------------------

export interface StorageStatePersistence {
  /** load → merge → prune → encode → store.save (per-user in-process mutex). */
  flush(userId: string, captured: StorageState): Promise<void>;
  /**
   * store.load → null when absent. A decode failure (corrupt/legacy blob) is
   * logged-and-swallowed → null — a fresh start, never a crash (RF#5).
   */
  restore(userId: string): Promise<StorageState | null>;
}

export interface StorageStatePersistenceOpts {
  /** Diagnostic sink for the swallow-and-fresh-start path. Defaults to console.warn. */
  log?: (msg: string, err?: unknown) => void;
}

export function createStorageStatePersistence(
  store: BrowserStateBlobStore,
  masterKey: string,
  opts?: StorageStatePersistenceOpts,
): StorageStatePersistence {
  const log: (msg: string, err?: unknown) => void =
    opts?.log ?? ((msg, err) => console.warn(`[storageState] ${msg}`, err ?? ""));

  // Per-user in-process mutex: a Map<userId, settled-when-released gate chain>.
  // Concurrent flushes for the SAME user serialize (load → merge → save must
  // be a read-modify-write, else the second flush would clobber the first);
  // different users never contend.
  const tails = new Map<string, Promise<void>>();
  async function withLock<T>(userId: string, fn: () => Promise<T>): Promise<T> {
    const prev = tails.get(userId) ?? Promise.resolve();
    let release!: () => void;
    const gate = new Promise<void>((res) => {
      release = res;
    });
    const entry = prev.then(
      () => gate,
      () => gate,
    );
    tails.set(userId, entry);
    await prev;
    try {
      return await fn();
    } finally {
      release();
      if (tails.get(userId) === entry) tails.delete(userId);
    }
  }

  async function loadStored(userId: string): Promise<StorageState | null> {
    const blob = await store.load(userId, DEFAULT_PROFILE_ID);
    if (blob === null) return null;
    try {
      return decodeBrowserState(blob, masterKey);
    } catch (err) {
      log(`undecodable stored browser state for user ${JSON.stringify(userId)} — starting fresh`, err);
      return null;
    }
  }

  return {
    async flush(userId, captured) {
      await withLock(userId, async () => {
        const stored = await loadStored(userId);
        const merged = mergeStorageState(stored, captured);
        const pruned = pruneStorageState(merged);
        const blob = encodeBrowserState(pruned, masterKey);
        await store.save(userId, DEFAULT_PROFILE_ID, blob);
      });
    },

    restore(userId) {
      return loadStored(userId);
    },
  };
}
