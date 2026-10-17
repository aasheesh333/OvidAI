import { describe, expect, it } from "vitest";
import {
  createEnvelopeCrypto,
  EnvelopeAuthError,
  type EncryptedEnvelope,
} from "./crypto.js";

// ---------------------------------------------------------------------------
// Envelope crypto (Task 8) — thin shim aligned EXACTLY to P9's canonical
// EnvelopeCrypto (@ovid/escrow, P9 Task 11): same method names, same recordId
// parameter, same structured envelope. Pure crypto, no DB. These tests pin the
// P9 consolidation contract: AAD = recordId on BOTH layers, every failure mode
// → EnvelopeAuthError (never garbage, never a raw crypto error).
// ---------------------------------------------------------------------------

// 64 hex chars = 32 bytes (AES-256). Test fixtures only — never real material.
const KEY_A = "a".repeat(64);
const KEY_B = "b".repeat(64);

const RECORD = "mcp_servers:018f3a2b-7c1d-7e2f-8a3b-4c5d6e7f8a9b";

function makeCrypto(): ReturnType<typeof createEnvelopeCrypto> {
  return createEnvelopeCrypto(KEY_A);
}

describe("createEnvelopeCrypto", () => {
  it("rejects a bad key length at construction", () => {
    // Too short (16 bytes), too long, and non-hex all throw — never construct
    // a half-usable instance.
    expect(() => createEnvelopeCrypto("a".repeat(32))).toThrow();
    expect(() => createEnvelopeCrypto("a".repeat(66))).toThrow();
    expect(() => createEnvelopeCrypto("z".repeat(64))).toThrow();
    expect(() => createEnvelopeCrypto("")).toThrow();
  });
});

describe("EnvelopeCrypto encrypt/decrypt", () => {
  it("round-trips unicode plaintext", () => {
    const c = makeCrypto();
    const plaintext = "secrets: πλån-日本語-🚀-naïve-\t\n\"quoted\"";
    const e = c.encrypt(plaintext, RECORD);
    expect(c.decrypt(e, RECORD)).toBe(plaintext);
  });

  it("serialized envelope never contains the plaintext", () => {
    const c = makeCrypto();
    const plaintext = "SUPER-SECRET-PLAINTEXT-VALUE-xyzzy";
    const e = c.encrypt(plaintext, RECORD);
    const serialized = JSON.stringify(e);
    expect(serialized).not.toContain(plaintext);
    // Also each individual field (defense in depth against, say, an iv that
    // happens to embed a prefix — impossible with random bytes, but pinned).
    expect(e.wrappedDek).not.toContain(plaintext);
    expect(e.iv).not.toContain(plaintext);
    expect(e.ciphertext).not.toContain(plaintext);
    expect(e.tag).not.toContain(plaintext);
  });

  it("same plaintext twice → different ciphertexts (random DEK/IVs)", () => {
    const c = makeCrypto();
    const e1 = c.encrypt("same input", RECORD);
    const e2 = c.encrypt("same input", RECORD);
    expect(e1.ciphertext).not.toBe(e2.ciphertext);
    expect(e1.iv).not.toBe(e2.iv);
    expect(e1.wrappedDek).not.toBe(e2.wrappedDek);
    // And both decrypt back to the same plaintext.
    expect(c.decrypt(e1, RECORD)).toBe("same input");
    expect(c.decrypt(e2, RECORD)).toBe("same input");
  });

  it("decrypt with a different recordId → EnvelopeAuthError (record-swap fails auth)", () => {
    const c = makeCrypto();
    const e = c.encrypt("cross-row secret", RECORD);
    // A row-swap attacker replays another row's envelope under a different id
    // — the AAD on BOTH layers must reject it.
    expect(() => c.decrypt(e, "mcp_servers:ffffffff-1111-7222-8333-444455556666")).toThrow(
      EnvelopeAuthError,
    );
  });

  it("tampered ciphertext → EnvelopeAuthError (one flipped base64 char)", () => {
    const c = makeCrypto();
    const e = c.encrypt("tamper target", RECORD);
    const tampered = flipOneBase64Char(e.ciphertext);
    expect(tampered).not.toBe(e.ciphertext);
    expect(() => c.decrypt({ ...e, ciphertext: tampered }, RECORD)).toThrow(EnvelopeAuthError);
  });

  it("tampered wrappedDek or tag or iv → EnvelopeAuthError", () => {
    const c = makeCrypto();
    const e = c.encrypt("tamper target", RECORD);
    // The wrapped-DEK layer: flipping any byte of it fails the wrap-layer auth.
    expect(() => c.decrypt({ ...e, wrappedDek: flipOneBase64Char(e.wrappedDek) }, RECORD)).toThrow(
      EnvelopeAuthError,
    );
    // The data-layer tag.
    expect(() => c.decrypt({ ...e, tag: flipOneBase64Char(e.tag) }, RECORD)).toThrow(
      EnvelopeAuthError,
    );
    // The data-layer IV.
    expect(() => c.decrypt({ ...e, iv: flipOneBase64Char(e.iv) }, RECORD)).toThrow(
      EnvelopeAuthError,
    );
  });

  it("wrong master key → EnvelopeAuthError", () => {
    const e = createEnvelopeCrypto(KEY_A).encrypt("under key A", RECORD);
    expect(() => createEnvelopeCrypto(KEY_B).decrypt(e, RECORD)).toThrow(EnvelopeAuthError);
  });

  it("decrypt of a malformed/garbage envelope → EnvelopeAuthError", () => {
    const c = makeCrypto();
    // Invalid base64.
    expect(() => c.decrypt({ wrappedDek: "!!!", iv: "%%%", ciphertext: "^", tag: "@" }, RECORD)).toThrow(
      EnvelopeAuthError,
    );
    // Valid base64 but wrong byte lengths.
    expect(() =>
      c.decrypt(
        { wrappedDek: Buffer.alloc(4).toString("base64"), iv: "AAAA", ciphertext: "AAAA", tag: "AAAA" },
        RECORD,
      ),
    ).toThrow(EnvelopeAuthError);
    // Empty fields.
    expect(() => c.decrypt({ wrappedDek: "", iv: "", ciphertext: "", tag: "" }, RECORD)).toThrow(
      EnvelopeAuthError,
    );
    // Wrong field types (JSON from an attacker-controlled row).
    expect(() =>
      c.decrypt(
        { wrappedDek: 42, iv: null, ciphertext: {}, tag: [] } as unknown as EncryptedEnvelope,
        RECORD,
      ),
    ).toThrow(EnvelopeAuthError);
  });

  it("errors carry no key or plaintext material in the message", () => {
    const c = makeCrypto();
    const plaintext = "SECRET-PLAINTEXT-NO-LEAK";
    const e = c.encrypt(plaintext, RECORD);
    const attempts: string[] = [];
    const grab = (fn: () => unknown): void => {
      try {
        fn();
      } catch (err) {
        attempts.push(err instanceof Error ? err.message : String(err));
      }
    };
    grab(() => c.decrypt(e, "mcp_servers:other"));
    grab(() => createEnvelopeCrypto(KEY_B).decrypt(e, RECORD));
    for (const msg of attempts) {
      expect(msg).not.toContain(plaintext);
      expect(msg).not.toContain(KEY_A);
    }
  });
});

/** Flip exactly one base64 char to a different valid base64 char. */
function flipOneBase64Char(s: string): string {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const i = Math.floor(s.length / 2); // deterministic: middle of the string
  const replacement = chars[(chars.indexOf(s[i]!) + 1) % chars.length]!;
  return s.slice(0, i) + replacement + s.slice(i + 1);
}
