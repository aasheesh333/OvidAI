import { describe, expect, it } from "vitest";
import {
  createEnvelopeCrypto,
  EnvelopeAuthError,
  type EncryptedEnvelope,
} from "./envelope.js";

// ---------------------------------------------------------------------------
// Envelope crypto (spec §11) — AES-256-GCM with a per-record random DEK
// wrapped under the master key. AAD = UTF-8 recordId on BOTH layers, so an
// envelope replayed against another row fails authentication.
// ---------------------------------------------------------------------------

// 64 hex chars = 32 bytes (AES-256). Test fixtures only — never real material.
const KEY_A = "a".repeat(64);
const KEY_B = "b".repeat(64);
const RECORD = "byok_keys:018f3a2b-7c1d-7e2f-8a3b-4c5d6e7f8a9b";

describe("createEnvelopeCrypto", () => {
  it("rejects a non-64-hex master key at construction", () => {
    expect(() => createEnvelopeCrypto("a".repeat(32))).toThrow();
    expect(() => createEnvelopeCrypto("a".repeat(66))).toThrow();
    expect(() => createEnvelopeCrypto("z".repeat(64))).toThrow();
    expect(() => createEnvelopeCrypto("")).toThrow();
    expect(() => createEnvelopeCrypto(undefined as unknown as string)).toThrow();
  });
});

describe("EnvelopeCrypto encrypt/decrypt", () => {
  it("round-trips unicode plaintext", () => {
    const c = createEnvelopeCrypto(KEY_A);
    const plaintext = "sk-live-πλån-日本語-🚀-naïve-\t\n\"quoted\"";
    const e = c.encrypt(plaintext, RECORD);
    expect(c.decrypt(e, RECORD)).toBe(plaintext);
  });

  it("the serialized envelope never contains the plaintext", () => {
    const c = createEnvelopeCrypto(KEY_A);
    const plaintext = "SUPER-SECRET-PLAINTEXT-VALUE-xyzzy";
    const e = c.encrypt(plaintext, RECORD);
    expect(JSON.stringify(e)).not.toContain(plaintext);
    expect(e.wrappedDek).not.toContain(plaintext);
    expect(e.iv).not.toContain(plaintext);
    expect(e.ciphertext).not.toContain(plaintext);
    expect(e.tag).not.toContain(plaintext);
  });

  it("two encryptions of the same plaintext differ (random DEK + IVs)", () => {
    const c = createEnvelopeCrypto(KEY_A);
    const e1 = c.encrypt("same input", RECORD);
    const e2 = c.encrypt("same input", RECORD);
    expect(e1.ciphertext).not.toBe(e2.ciphertext);
    expect(e1.iv).not.toBe(e2.iv);
    expect(e1.wrappedDek).not.toBe(e2.wrappedDek);
    expect(c.decrypt(e1, RECORD)).toBe("same input");
    expect(c.decrypt(e2, RECORD)).toBe("same input");
  });

  it("decrypt with a different recordId → EnvelopeAuthError (record-swap fails)", () => {
    const c = createEnvelopeCrypto(KEY_A);
    const e = c.encrypt("cross-row secret", RECORD);
    expect(() => c.decrypt(e, "byok_keys:ffffffff-1111-7222-8333-444455556666")).toThrow(
      EnvelopeAuthError,
    );
  });

  it("a tampered ciphertext byte → EnvelopeAuthError", () => {
    const c = createEnvelopeCrypto(KEY_A);
    const e = c.encrypt("tamper target", RECORD);
    const tampered = flipOneBase64Char(e.ciphertext);
    expect(tampered).not.toBe(e.ciphertext);
    expect(() => c.decrypt({ ...e, ciphertext: tampered }, RECORD)).toThrow(EnvelopeAuthError);
  });

  it("tampered wrappedDek / tag / iv → EnvelopeAuthError", () => {
    const c = createEnvelopeCrypto(KEY_A);
    const e = c.encrypt("tamper target", RECORD);
    expect(() => c.decrypt({ ...e, wrappedDek: flipOneBase64Char(e.wrappedDek) }, RECORD)).toThrow(
      EnvelopeAuthError,
    );
    expect(() => c.decrypt({ ...e, tag: flipOneBase64Char(e.tag) }, RECORD)).toThrow(
      EnvelopeAuthError,
    );
    expect(() => c.decrypt({ ...e, iv: flipOneBase64Char(e.iv) }, RECORD)).toThrow(
      EnvelopeAuthError,
    );
  });

  it("a wrong master key → EnvelopeAuthError", () => {
    const e = createEnvelopeCrypto(KEY_A).encrypt("under key A", RECORD);
    expect(() => createEnvelopeCrypto(KEY_B).decrypt(e, RECORD)).toThrow(EnvelopeAuthError);
  });

  it("malformed/garbage envelopes → EnvelopeAuthError", () => {
    const c = createEnvelopeCrypto(KEY_A);
    expect(() =>
      c.decrypt({ wrappedDek: "!!!", iv: "%%%", ciphertext: "^", tag: "@" }, RECORD),
    ).toThrow(EnvelopeAuthError);
    expect(() =>
      c.decrypt(
        {
          wrappedDek: Buffer.alloc(4).toString("base64"),
          iv: "AAAA",
          ciphertext: "AAAA",
          tag: "AAAA",
        },
        RECORD,
      ),
    ).toThrow(EnvelopeAuthError);
    expect(() => c.decrypt({ wrappedDek: "", iv: "", ciphertext: "", tag: "" }, RECORD)).toThrow(
      EnvelopeAuthError,
    );
    expect(() =>
      c.decrypt(
        { wrappedDek: 42, iv: null, ciphertext: {}, tag: [] } as unknown as EncryptedEnvelope,
        RECORD,
      ),
    ).toThrow(EnvelopeAuthError);
  });

  it("errors carry no key or plaintext material", () => {
    const c = createEnvelopeCrypto(KEY_A);
    const plaintext = "SECRET-PLAINTEXT-NO-LEAK";
    const e = c.encrypt(plaintext, RECORD);
    const messages: string[] = [];
    const grab = (fn: () => unknown): void => {
      try {
        fn();
      } catch (err) {
        messages.push(err instanceof Error ? err.message : String(err));
      }
    };
    grab(() => c.decrypt(e, "byok_keys:other"));
    grab(() => createEnvelopeCrypto(KEY_B).decrypt(e, RECORD));
    for (const message of messages) {
      expect(message).not.toContain(plaintext);
      expect(message).not.toContain(KEY_A);
    }
  });
});

/** Flip exactly one base64 char to a different valid base64 char. */
function flipOneBase64Char(s: string): string {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const i = Math.floor(s.length / 2);
  const replacement = chars[(chars.indexOf(s[i]!) + 1) % chars.length]!;
  return s.slice(0, i) + replacement + s.slice(i + 1);
}
