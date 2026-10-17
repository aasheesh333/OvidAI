/**
 * storageState — the Playwright `context.storageState()` JSON: merge rules
 * (ported from Dart `CookieMerge.missingPairs` semantics), the raw-byte cap
 * prune, and the encrypted-at-rest binary envelope handed to P7's opaque-bytes
 * `BrowserStateBlobStore` (P6 never touches the browser_states table or the R2
 * object format — P7 owns both).
 *
 * Envelope v1 — compress-then-encrypt, RAW binary bytes (no base64/JSON
 * wrapper). Everything decode needs travels in the blob, `iv_w` included, or
 * the DEK could not be recovered:
 *
 *   "OVIDBS01" magic (8 B) ‖ version u8 = 1 ‖ iv_w (12 B) ‖ wrappedDek
 *   (48 B = AES-256-GCM(DEK, KEK, iv_w) ciphertext 32 B ‖ authTag 16 B) ‖
 *   iv (12 B) ‖ data (AES-256-GCM(zstd-9 JSON, DEK, iv) ciphertext ‖ authTag)
 *
 * IndexedDB limitation: capture is `context.storageState()` defaults =
 * cookies + localStorage ONLY. IndexedDB-backed logins (Firebase-style) do
 * NOT survive eviction. The `indexedDB:true` opt-in exists in Playwright
 * >= 1.51 (research §4.1) and is a deliberate P6 non-goal per the controller
 * dispatch.
 */

import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import * as nodeZlib from "node:zlib";
import { z } from "zod";

// Module-load guard: node:zlib zstd landed in Node 22.15. A missing named
// export must surface as OUR error message, not an opaque resolver failure —
// hence the namespace import + typeof check.
const zstdCompressSync = nodeZlib.zstdCompressSync;
const zstdDecompressSync = nodeZlib.zstdDecompressSync;
if (typeof zstdCompressSync !== "function" || typeof zstdDecompressSync !== "function") {
  throw new Error("node:zlib zstd requires Node >= 22.15");
}

export class BrowserStateError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "BrowserStateError";
  }
}

/** Playwright storageState() cookie — the pinned subset. */
export interface StorageCookie {
  name: string;
  value: string;
  domain: string;
  path: string;
  expires: number;
  httpOnly: boolean;
  secure: boolean;
  sameSite: "Strict" | "Lax" | "None";
}

export interface StorageOrigin {
  origin: string;
  localStorage: { name: string; value: string }[];
}

export interface StorageState {
  cookies: StorageCookie[];
  origins: StorageOrigin[];
}

const storageCookieSchema = z.object({
  name: z.string(),
  value: z.string(),
  domain: z.string(),
  path: z.string(),
  expires: z.number(),
  httpOnly: z.boolean(),
  secure: z.boolean(),
  sameSite: z.enum(["Strict", "Lax", "None"]),
});

const storageOriginSchema = z.object({
  origin: z.string(),
  localStorage: z.array(z.object({ name: z.string(), value: z.string() })),
});

export const storageStateSchema: z.ZodType<StorageState> = z.object({
  cookies: z.array(storageCookieSchema),
  origins: z.array(storageOriginSchema),
});

/** Hard bound on the raw (uncompressed, unencrypted) state JSON — 8 MB. */
export const MAX_RAW_STATE_BYTES = 8 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Merge
// ---------------------------------------------------------------------------

function compareCookies(a: StorageCookie, b: StorageCookie): number {
  if (a.domain !== b.domain) return a.domain < b.domain ? -1 : 1;
  if (a.name !== b.name) return a.name < b.name ? -1 : 1;
  if (a.path !== b.path) return a.path < b.path ? -1 : 1;
  return 0;
}

function sortState(cookies: StorageCookie[], origins: StorageOrigin[]): StorageState {
  return {
    cookies: [...cookies].sort(compareCookies),
    origins: [...origins].sort((a, b) => (a.origin < b.origin ? -1 : a.origin > b.origin ? 1 : 0)),
  };
}

/**
 * Merge a fresh capture into the stored state (ports
 * `CookieMerge.missingPairs` from lib/core/session_browser_profiles.dart:100 —
 * a merge can add logins but never clobbers untouched ones).
 *
 * The capture owns every cookie domain and origin it touched (wholesale
 * replacement there); every stored entry whose domain/origin the capture did
 * NOT touch survives verbatim. Output is sorted — cookies by
 * (domain, name, path), origins by origin — so the merged JSON is byte-stable
 * and `merge(merge(s, c), c)` deep-equals `merge(s, c)` (idempotent).
 */
export function mergeStorageState(stored: StorageState | null, captured: StorageState): StorageState {
  if (stored === null) {
    return sortState(captured.cookies, captured.origins);
  }
  const capturedDomains = new Set(captured.cookies.map((c) => c.domain));
  const capturedOriginSet = new Set(captured.origins.map((o) => o.origin));
  const cookies = [
    ...captured.cookies,
    ...stored.cookies.filter((c) => !capturedDomains.has(c.domain)),
  ];
  const origins = [
    ...captured.origins,
    ...stored.origins.filter((o) => !capturedOriginSet.has(o.origin)),
  ];
  return sortState(cookies, origins);
}

// ---------------------------------------------------------------------------
// Prune
// ---------------------------------------------------------------------------

function stateBytes(cookies: StorageCookie[], origins: StorageOrigin[]): number {
  return Buffer.byteLength(JSON.stringify({ cookies, origins }));
}

function localStorageBytes(o: StorageOrigin): number {
  let total = 0;
  for (const entry of o.localStorage) {
    total += Buffer.byteLength(entry.name, "utf8") + Buffer.byteLength(entry.value, "utf8");
  }
  return total;
}

/** Session cookies — Playwright marks them with `expires === -1`. */
function isSessionCookie(c: StorageCookie): boolean {
  return c.expires === -1;
}

/** Definite past expiry — `expires > 0 && expires < now` (epoch seconds). NEVER matches a session cookie. */
function isDefinitelyExpired(c: StorageCookie, nowSec: number): boolean {
  return typeof c.expires === "number" && c.expires > 0 && c.expires < nowSec;
}

/**
 * Cap the raw state JSON at `maxBytes` (default MAX_RAW_STATE_BYTES) with an
 * escalating cascade. Session cookies (`expires === -1`, Playwright's marker)
 * are NEVER dropped by any stage — a "past expiry" test would delete every
 * session cookie including `login_tok`-style logins, so the expiry rule only
 * ever matches a DEFINITE past expiry (`expires > 0 && expires < now`).
 *
 *  1. while over cap: drop the origin with the largest localStorage total
 *     (whole entry), repeat;
 *  2. while still over: drop cookies with a definite past expiry;
 *  3. while still over: drop the NON-session cookie with the longest value,
 *     one at a time;
 *  4. documented last resort — still over after every droppable entry is gone
 *     (session cookies alone exceed the cap) ⇒ `{cookies:[],origins:[]}`.
 *     The raw cap is a hard bound.
 */
export function pruneStorageState(state: StorageState, maxBytes: number = MAX_RAW_STATE_BYTES): StorageState {
  const cookies = [...state.cookies];
  const origins = [...state.origins];
  const nowSec = Date.now() / 1000;

  // Stage 1 — biggest localStorage origin first, whole entry.
  while (origins.length > 0 && stateBytes(cookies, origins) > maxBytes) {
    let worst = 0;
    let worstBytes = -1;
    for (let i = 0; i < origins.length; i++) {
      const total = localStorageBytes(origins[i]);
      if (total > worstBytes) {
        worstBytes = total;
        worst = i;
      }
    }
    origins.splice(worst, 1);
  }

  // Stage 2 — expired cookies are pure dead weight: definite past expiry ONLY.
  if (stateBytes(cookies, origins) > maxBytes) {
    for (let i = cookies.length - 1; i >= 0; i--) {
      if (isDefinitelyExpired(cookies[i], nowSec)) cookies.splice(i, 1);
    }
  }

  // Stage 3 — longest NON-session value, one at a time.
  while (stateBytes(cookies, origins) > maxBytes) {
    let worst = -1;
    let worstBytes = -1;
    for (let i = 0; i < cookies.length; i++) {
      if (isSessionCookie(cookies[i])) continue;
      const len = Buffer.byteLength(cookies[i].value, "utf8");
      if (len > worstBytes) {
        worstBytes = len;
        worst = i;
      }
    }
    if (worst === -1) break; // only session cookies remain — never dropped here
    cookies.splice(worst, 1);
  }

  // Last resort — the raw cap is a hard bound.
  if (stateBytes(cookies, origins) > maxBytes) {
    return { cookies: [], origins: [] };
  }
  return { cookies, origins };
}

// ---------------------------------------------------------------------------
// Binary envelope v1 (compress-then-encrypt)
// ---------------------------------------------------------------------------

export const BROWSER_STATE_MAGIC = "OVIDBS01";

const VERSION = 1;
const IV_LEN = 12;
const DEK_LEN = 32;
const TAG_LEN = 16;
const WRAPPED_DEK_LEN = DEK_LEN + TAG_LEN; // 48
// magic(8) + version(1) + iv_w(12) + wrappedDek(48) + iv(12)
const HEADER_LEN = 8 + 1 + IV_LEN + WRAPPED_DEK_LEN + IV_LEN; // 81
const MIN_BLOB_LEN = HEADER_LEN + TAG_LEN; // 97 — shortest possible data region

function deriveKek(masterKey: string): Buffer {
  // KEK = sha256(masterKey) — a 32-byte AES-256 key from any masterKey string.
  return createHash("sha256").update(masterKey, "utf8").digest();
}

function gcmSeal(plaintext: Buffer, key: Buffer, iv: Buffer): Buffer {
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  return Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
}

function gcmOpen(ciphertext: Buffer, tag: Buffer, key: Buffer, iv: Buffer): Buffer {
  const decipher = createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

export interface EncodeBrowserStateOpts {
  /** TEST SEAM ONLY — determinism pin. Production always generates a fresh random 32-byte DEK. */
  dek?: Buffer;
  /** TEST SEAM ONLY — fixed DEK-wrap IV. Production always generates a fresh random 12-byte IV. */
  ivW?: Buffer;
  /** TEST SEAM ONLY — fixed data IV. Production always generates a fresh random 12-byte IV. */
  iv?: Buffer;
}

/**
 * Encode a StorageState into the encrypted-at-rest binary envelope. The
 * `opts` seam exists ONLY so tests can pin determinism; production never
 * passes it and every encode rolls a fresh random DEK and two random IVs, so
 * two production encodes of the same state are never byte-identical.
 */
export function encodeBrowserState(
  state: StorageState,
  masterKey: string,
  opts?: EncodeBrowserStateOpts,
): Buffer {
  const kek = deriveKek(masterKey);
  const dek = opts?.dek ?? randomBytes(DEK_LEN);
  const ivW = opts?.ivW ?? randomBytes(IV_LEN);
  const iv = opts?.iv ?? randomBytes(IV_LEN);
  if (dek.length !== DEK_LEN) {
    throw new BrowserStateError(`dek must be ${DEK_LEN} bytes (got ${dek.length})`);
  }
  if (ivW.length !== IV_LEN || iv.length !== IV_LEN) {
    throw new BrowserStateError(`iv/ivW must be ${IV_LEN} bytes`);
  }
  const wrappedDek = gcmSeal(dek, kek, ivW); // 48 B — travels in the blob
  const json = Buffer.from(JSON.stringify(state), "utf8");
  // zstd level is an indexed param (ZSTD_c_compressionLevel = 100) — a bare
  // `level` key is silently ignored by node:zlib, which would quietly pin the
  // default level 3 instead of the pinned zstd-9.
  const compressed = zstdCompressSync(json, {
    params: { [nodeZlib.constants.ZSTD_c_compressionLevel]: 9 },
  });
  const data = gcmSeal(compressed, dek, iv);
  return Buffer.concat([
    Buffer.from(BROWSER_STATE_MAGIC, "utf8"),
    Buffer.from([VERSION]),
    ivW,
    wrappedDek,
    iv,
    data,
  ]);
}

/**
 * Decode the binary envelope back into a validated StorageState. Every failure
 * path — short buffer, bad magic, bad version, GCM auth failure (tampered
 * data, wrong masterKey), zstd/JSON/schema garbage — throws a
 * `BrowserStateError` carrying `{cause}`, never a raw crash and never silent
 * garbage.
 */
export function decodeBrowserState(blob: Buffer | Uint8Array, masterKey: string): StorageState {
  const buf = Buffer.isBuffer(blob) ? blob : Buffer.from(blob);
  if (buf.length < MIN_BLOB_LEN) {
    throw new BrowserStateError(`browser state blob too short (${buf.length} B, min ${MIN_BLOB_LEN})`);
  }
  const magic = buf.subarray(0, 8).toString("utf8");
  if (magic !== BROWSER_STATE_MAGIC) {
    throw new BrowserStateError(`bad browser state magic ${JSON.stringify(magic)}`);
  }
  const version = buf[8];
  if (version !== VERSION) {
    throw new BrowserStateError(`unsupported browser state version ${version}`);
  }
  const ivW = buf.subarray(9, 21);
  const wrappedDek = buf.subarray(21, 69);
  const iv = buf.subarray(69, HEADER_LEN);
  const data = buf.subarray(HEADER_LEN);

  const kek = deriveKek(masterKey);
  let dek: Buffer;
  let decompressed: Buffer;
  try {
    dek = gcmOpen(wrappedDek.subarray(0, DEK_LEN), wrappedDek.subarray(DEK_LEN), kek, ivW);
    if (dek.length !== DEK_LEN) {
      throw new Error(`unwrapped DEK is ${dek.length} B, expected ${DEK_LEN}`);
    }
    const compressed = gcmOpen(
      data.subarray(0, data.length - TAG_LEN),
      data.subarray(data.length - TAG_LEN),
      dek,
      iv,
    );
    decompressed = zstdDecompressSync(compressed);
  } catch (err) {
    throw new BrowserStateError("browser state blob failed AES-256-GCM/zstd decode", { cause: err });
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(decompressed.toString("utf8"));
  } catch (err) {
    throw new BrowserStateError("browser state payload is not valid JSON", { cause: err });
  }
  const checked = storageStateSchema.safeParse(parsed);
  if (!checked.success) {
    throw new BrowserStateError("browser state payload failed schema validation", {
      cause: checked.error,
    });
  }
  return checked.data;
}
