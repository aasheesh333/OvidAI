/**
 * Envelope crypto (spec §11) — the CANONICAL P9 implementation.
 *
 * AES-256-GCM with a per-record random 32-byte DEK:
 *   - the DEK is wrapped under the 32-byte master key (`OVID_MASTER_KEY`)
 *     with its own random IV and GCM tag;
 *   - the payload is encrypted under the DEK with a fresh IV;
 *   - AAD = UTF-8 recordId on BOTH layers, so an envelope replayed against a
 *     different row (record-swap) fails authentication.
 *
 * The four-field envelope shape is pinned by the DB columns
 * (wrappedDek/iv/ciphertext/tag): the wrap-layer IV and tag travel INSIDE
 * `wrappedDek` as `base64(wrapIV(12) ‖ wrapCiphertext(32) ‖ wrapTag(16))`.
 *
 * Key material is never logged and never appears in error messages.
 *
 * recordId convention (shared with the gateway routes and the worker provider):
 *   byok_keys:{row.id}
 */

import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

/** AES-256-GCM envelope — every field base64. */
export interface EncryptedEnvelope {
  /** base64(wrapIV(12) ‖ wrapCiphertext(32) ‖ wrapTag(16)). */
  wrappedDek: string;
  /** base64 data-layer IV (12 bytes). */
  iv: string;
  /** base64 data-layer ciphertext. */
  ciphertext: string;
  /** base64 data-layer GCM tag (16 bytes). */
  tag: string;
}

export interface EnvelopeCrypto {
  encrypt(plaintext: string, recordId: string): EncryptedEnvelope;
  decrypt(envelope: EncryptedEnvelope, recordId: string): string;
}

/**
 * Any decrypt failure (wrong key, wrong recordId, tampered byte, malformed
 * envelope). Callers never see raw crypto errors or partial plaintext.
 */
export class EnvelopeAuthError extends Error {
  constructor(message = "envelope failed authentication") {
    super(message);
    this.name = "EnvelopeAuthError";
  }
}

const IV_LEN = 12;
const TAG_LEN = 16;
const DEK_LEN = 32; // AES-256
const WRAPPED_DEK_LEN = IV_LEN + DEK_LEN + TAG_LEN; // 60 bytes decoded

const MASTER_KEY_HEX_RE = /^[0-9a-fA-F]{64}$/;
const BASE64_RE = /^[A-Za-z0-9+/]*={0,2}$/;

interface GcmSealed {
  ciphertext: Buffer;
  tag: Buffer;
}

function gcmSeal(key: Buffer, iv: Buffer, plaintext: Buffer, aad: Buffer): GcmSealed {
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(aad);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return { ciphertext, tag: cipher.getAuthTag() };
}

/** Throws on ANY auth failure (wrong key / AAD / tag / tampered byte). */
function gcmOpen(key: Buffer, iv: Buffer, sealed: GcmSealed, aad: Buffer): Buffer {
  const decipher = createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAAD(aad);
  decipher.setAuthTag(sealed.tag);
  return Buffer.concat([decipher.update(sealed.ciphertext), decipher.final()]);
}

/**
 * Master key: exactly 64 hex chars (32 bytes — AES-256). Anything else throws
 * at construction, so a misconfigured key can never half-work.
 */
export function createEnvelopeCrypto(masterKeyHex: string): EnvelopeCrypto {
  if (typeof masterKeyHex !== "string" || !MASTER_KEY_HEX_RE.test(masterKeyHex)) {
    throw new Error("masterKeyHex must be exactly 64 hex chars (32 bytes)");
  }
  const masterKey = Buffer.from(masterKeyHex, "hex");

  return {
    encrypt(plaintext: string, recordId: string): EncryptedEnvelope {
      // AAD = UTF-8 recordId on BOTH layers: an envelope replayed against a
      // different row (record-swap) fails authentication.
      const aad = Buffer.from(recordId, "utf8");
      // Per-record random DEK seals the data layer…
      const dek = randomBytes(DEK_LEN);
      const iv = randomBytes(IV_LEN);
      const data = gcmSeal(dek, iv, Buffer.from(plaintext, "utf8"), aad);
      // …and the DEK itself is wrapped under the master key with its own IV.
      const wrapIv = randomBytes(IV_LEN);
      const wrapped = gcmSeal(masterKey, wrapIv, dek, aad);
      return {
        wrappedDek: Buffer.concat([wrapIv, wrapped.ciphertext, wrapped.tag]).toString("base64"),
        iv: iv.toString("base64"),
        ciphertext: data.ciphertext.toString("base64"),
        tag: data.tag.toString("base64"),
      };
    },

    decrypt(envelope: EncryptedEnvelope, recordId: string): string {
      // Every failure path funnels into ONE EnvelopeAuthError — never a raw
      // crypto error, never garbage output. (Buffer.from(…, "base64") is
      // lenient, so shape/regex/length checks run first; a well-formed but
      // forged envelope is then rejected by GCM authentication itself.)
      try {
        if (
          typeof envelope?.wrappedDek !== "string" ||
          typeof envelope?.iv !== "string" ||
          typeof envelope?.ciphertext !== "string" ||
          typeof envelope?.tag !== "string" ||
          !BASE64_RE.test(envelope.wrappedDek) ||
          !BASE64_RE.test(envelope.iv) ||
          !BASE64_RE.test(envelope.ciphertext) ||
          !BASE64_RE.test(envelope.tag)
        ) {
          throw new Error("malformed envelope");
        }
        const wrappedDek = Buffer.from(envelope.wrappedDek, "base64");
        const iv = Buffer.from(envelope.iv, "base64");
        const ciphertext = Buffer.from(envelope.ciphertext, "base64");
        const tag = Buffer.from(envelope.tag, "base64");
        if (
          wrappedDek.length !== WRAPPED_DEK_LEN ||
          iv.length !== IV_LEN ||
          tag.length !== TAG_LEN
        ) {
          throw new Error("malformed envelope");
        }
        const aad = Buffer.from(recordId, "utf8");
        const wrapIv = wrappedDek.subarray(0, IV_LEN);
        const wrapCiphertext = wrappedDek.subarray(IV_LEN, IV_LEN + DEK_LEN);
        const wrapTag = wrappedDek.subarray(IV_LEN + DEK_LEN, WRAPPED_DEK_LEN);
        const dek = gcmOpen(
          masterKey,
          wrapIv,
          { ciphertext: wrapCiphertext, tag: wrapTag },
          aad,
        );
        if (dek.length !== DEK_LEN) throw new Error("malformed envelope");
        return gcmOpen(dek, iv, { ciphertext, tag }, aad).toString("utf8");
      } catch {
        // Fixed message: no key material, no plaintext, no underlying crypto
        // error text leaks into logs or API responses.
        throw new EnvelopeAuthError();
      }
    },
  };
}
