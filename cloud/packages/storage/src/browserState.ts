/**
 * Browser-state blob store — the P6 seam. P6 does the zstd compress + encrypt
 * and hands the opaque bytes to save(); storage only moves them to the
 * `users/{uid}/browser/{profileId}.zst` key.
 */

import { createHash } from "node:crypto";

import type { StorageAdapter } from "./adapter.js";
import { KeyLayoutError } from "./errors.js";
import { r2Keys } from "./keys.js";

export interface BrowserStateBlobStore {
  save(
    userId: string,
    profileId: string,
    zstdBytes: Uint8Array,
  ): Promise<{ key: string; bytes: number; sha256Hex: string }>;
  load(userId: string, profileId: string): Promise<Buffer | null>;
  remove(userId: string, profileId: string): Promise<void>;
}

const PROFILE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

function assertProfileId(profileId: string): void {
  if (!PROFILE_ID_RE.test(profileId)) {
    throw new KeyLayoutError(
      `profileId must match /^[A-Za-z0-9_-]{1,64}$/ (got ${JSON.stringify(profileId)})`,
    );
  }
}

export function createBrowserStateBlobStore(storage: StorageAdapter): BrowserStateBlobStore {
  return {
    async save(userId, profileId, zstdBytes) {
      assertProfileId(profileId);
      const key = r2Keys.browserState(userId, profileId);
      const bytes = zstdBytes.byteLength;
      const sha256Hex = createHash("sha256").update(zstdBytes).digest("hex");
      await storage.put(key, Buffer.from(zstdBytes), { sha256Hex });
      return { key, bytes, sha256Hex };
    },

    async load(userId, profileId) {
      assertProfileId(profileId);
      return storage.getBuffer(r2Keys.browserState(userId, profileId));
    },

    async remove(userId, profileId) {
      assertProfileId(profileId);
      await storage.delete(r2Keys.browserState(userId, profileId));
    },
  };
}
