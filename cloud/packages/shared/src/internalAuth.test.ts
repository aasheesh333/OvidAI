import { describe, expect, it } from "vitest";
import {
  INTERNAL_MINT_PATH,
  INTERNAL_WINDOW_S,
  signInternalRequest,
  verifyInternalRequest,
} from "./internalAuth.js";

/**
 * P9 Task 9 — HMAC request signing for the docker-internal mint API.
 * The payload is "METHOD\nPATH\nUID\nTIMESTAMP"; the timestamp window is
 * ±INTERNAL_WINDOW_S (300 s); the signature is base64 HMAC-SHA256.
 */

const SECRET = "unit-test-internal-secret-0123456789abcdef";
const NOW = 1_790_000_000;
const TS = Buffer.from(String(NOW), "utf8").toString("base64");

function sign(
  overrides: Partial<{
    secret: string;
    method: string;
    path: string;
    uid: string;
    timestamp: number;
  }> = {},
): string {
  return signInternalRequest(
    overrides.secret ?? SECRET,
    overrides.method ?? "POST",
    overrides.path ?? INTERNAL_MINT_PATH,
    overrides.uid ?? "uid-1",
    overrides.timestamp ?? NOW,
  );
}

function verify(overrides: {
  secret?: string;
  method?: string;
  path?: string;
  uid?: string;
  timestampHeader?: string;
  signatureHeader?: string;
  now?: number;
} = {}): boolean {
  return verifyInternalRequest(
    overrides.secret ?? SECRET,
    overrides.method ?? "POST",
    overrides.path ?? INTERNAL_MINT_PATH,
    overrides.uid ?? "uid-1",
    overrides.timestampHeader ?? TS,
    overrides.signatureHeader ?? sign(),
    overrides.now ?? NOW,
  );
}

describe("signInternalRequest / verifyInternalRequest", () => {
  it("pins the window at 300 s", () => {
    expect(INTERNAL_WINDOW_S).toBe(300);
  });

  it("round-trips a valid signature", () => {
    expect(verify()).toBe(true);
  });

  it("accepts a plain-decimal timestamp header as well as base64", () => {
    expect(verify({ timestampHeader: String(NOW) })).toBe(true);
  });

  it("rejects at the window edges (301 s old/new), accepts 300 s", () => {
    expect(verify({ now: NOW + 300 })).toBe(true);
    expect(verify({ now: NOW - 300 })).toBe(true);
    expect(verify({ now: NOW + 301 })).toBe(false);
    expect(verify({ now: NOW - 301 })).toBe(false);
  });

  it("binds the secret, method, path and uid", () => {
    expect(verify({ secret: `${SECRET}-wrong` })).toBe(false);
    expect(verify({ method: "GET" })).toBe(false);
    expect(verify({ path: "/internal/other" })).toBe(false);
    expect(verify({ uid: "uid-2" })).toBe(false);
  });

  it("rejects a tampered or malformed signature", () => {
    const good = sign();
    const tampered = `${good.slice(0, -2)}${good.endsWith("A=") ? "B=" : "A="}`;
    expect(verify({ signatureHeader: tampered })).toBe(false);
    expect(verify({ signatureHeader: "" })).toBe(false);
    expect(verify({ signatureHeader: "not base64 !!" })).toBe(false);
    expect(verify({ timestampHeader: "not-a-timestamp" })).toBe(false);
  });

  it("rejects an empty secret rather than signing with it", () => {
    expect(verify({ secret: "" })).toBe(false);
  });

  it("a different timestamp is a different signature (no replay across the window)", () => {
    const signature = sign({ timestamp: NOW });
    expect(verify({ timestampHeader: Buffer.from(String(NOW + 1)).toString("base64"), signatureHeader: signature })).toBe(
      false,
    );
  });
});
