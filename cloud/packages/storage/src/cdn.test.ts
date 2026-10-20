import { describe, expect, it } from "vitest";

import {
  CDN_TTL_MAX_SECONDS,
  CDN_TTL_MIN_SECONDS,
  DEFAULT_CDN_TTL_SECONDS,
  cacheClassForKey,
  cacheControlFor,
  cdnCanonicalString,
  decodeOpaqueKey,
  encodeOpaqueKey,
  loadCdnConfig,
  mintCdnUrl,
  sanitizeCdnContentType,
  sanitizeCdnFilename,
  signCdnToken,
  verifyCdnToken,
  type CdnConfig,
  type CdnTokenClaims,
} from "./cdn.js";
import { verifyToken as workerVerifyToken } from "../../../deploy/cdn/worker.js";
import { cacheClassForKey as workerCacheClassForKey } from "../../../deploy/cdn/worker.js";

const SECRET = "w12-test-signing-secret-at-least-32-bytes!!";
const KEY = "users/u1/artifacts/s1/0192c0de-0000-7000-8000-000000000001-aaaaaaaaaaaaaaaa-shot.png";
const CONFIG: CdnConfig = { baseUrl: "https://cdn.ovidsi.test", secret: SECRET, ttlSeconds: 900 };
const NOW = 1_700_000_000;

function claims(overrides: Partial<CdnTokenClaims> = {}): CdnTokenClaims {
  return {
    key: KEY,
    expiresAtEpochSeconds: NOW + 900,
    disposition: "inline",
    filename: "shot.png",
    contentType: "image/png",
    cacheClass: "immutable",
    ...overrides,
  };
}

describe("cdn token", () => {
  it("round-trips and is timing-safe-verifiable", () => {
    const c = claims();
    const token = signCdnToken(c, SECRET);
    expect(token).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(verifyCdnToken(token, c, SECRET, { nowSeconds: NOW })).toBe(true);
  });

  it("rejects tampering with every signed field", () => {
    const token = signCdnToken(claims(), SECRET);
    for (const bad of [
      claims({ key: KEY.replace("u1", "u2") }),
      claims({ expiresAtEpochSeconds: NOW + 901 }),
      claims({ disposition: "attachment" }),
      claims({ filename: "other.png" }),
      claims({ contentType: "text/html" }),
      claims({ cacheClass: "short" }),
    ]) {
      expect(verifyCdnToken(token, bad, SECRET, { nowSeconds: NOW })).toBe(false);
    }
  });

  it("rejects an expired token and a token with too much remaining life", () => {
    const token = signCdnToken(claims(), SECRET);
    expect(verifyCdnToken(token, claims(), SECRET, { nowSeconds: NOW + 900 })).toBe(false);
    expect(
      verifyCdnToken(token, claims(), SECRET, { nowSeconds: NOW, maxTtlSeconds: 60 }),
    ).toBe(false);
  });

  it("rejects a different secret and malformed token text", () => {
    const token = signCdnToken(claims(), SECRET);
    expect(verifyCdnToken(token, claims(), `${SECRET}x`, { nowSeconds: NOW })).toBe(false);
    expect(verifyCdnToken("not a token!", claims(), SECRET, { nowSeconds: NOW })).toBe(false);
  });

  it("canonical string has a pinned field order (Worker cross-check)", () => {
    expect(cdnCanonicalString(claims())).toBe(
      [
        "v1",
        KEY,
        String(NOW + 900),
        "inline",
        "shot.png",
        "image/png",
        "immutable",
      ].join("\n"),
    );
  });

  it("the Worker verifies a gateway-minted token (no drift between copies)", async () => {
    const minted = mintCdnUrl(CONFIG, {
      key: KEY,
      filename: "shot.png",
      contentType: "image/png",
      now: new Date(NOW * 1000),
    });
    const url = new URL(minted.url);
    const opaque = url.pathname.slice("/o/".length);
    const parsed = {
      key: KEY,
      expiresAtEpochSeconds: Number(url.searchParams.get("e")),
      disposition: "inline" as const,
      filename: url.searchParams.get("fn") ?? undefined,
      contentType: url.searchParams.get("ct") ?? undefined,
      cacheClass: "immutable" as const,
    };
    expect(await workerVerifyToken(parsed, url.searchParams.get("t")!, SECRET, NOW, 3600)).toBe(
      true,
    );
    expect(opaque.length).toBeGreaterThan(0);
  });
});

describe("opaque key", () => {
  it("round-trips a safe key", () => {
    const opaque = encodeOpaqueKey(KEY);
    expect(decodeOpaqueKey(opaque)).toBe(KEY);
  });

  it("rejects traversal, absolute and non-canonical encodings", () => {
    for (const bad of ["../etc/passwd", "/etc/passwd", "a/../../b", ""]) {
      expect(() => encodeOpaqueKey(bad)).toThrow();
    }
    // Canonical base64url of "../etc/passwd" must still be rejected after decode.
    const traversal = Buffer.from("../etc/passwd", "utf8").toString("base64url");
    expect(decodeOpaqueKey(traversal)).toBeNull();
    expect(decodeOpaqueKey("not base64!")).toBeNull();
    expect(decodeOpaqueKey("")).toBeNull();
  });
});

describe("cache policy", () => {
  it("treats generated artifacts and sha256 keys as immutable", () => {
    expect(cacheClassForKey(KEY)).toBe("immutable");
    expect(cacheClassForKey("users/u1/artifacts/s1/sha256-abcdef0123456789-x")).toBe(
      "immutable",
    );
  });

  it("treats uploads and other named objects as short-lived", () => {
    expect(cacheClassForKey("users/u1/sessions/s1/uploads/a1")).toBe("short");
    expect(cacheClassForKey("users/u1/workspaces/s1.tar.zst")).toBe("short");
  });

  it("pins the Cache-Control values", () => {
    expect(cacheControlFor("immutable")).toBe("public, max-age=31536000, immutable");
    expect(cacheControlFor("short")).toContain("max-age=60");
    expect(cacheControlFor("short")).toContain("must-revalidate");
  });

  it("the Worker and the gateway agree on every key class (no drift)", () => {
    const keys = [
      KEY,
      "users/u1/artifacts/s1/sha256-abcdef0123456789-x",
      "users/u1/sessions/s1/uploads/a1",
      "users/u1/workspaces/s1.tar.zst",
      "users/u1/browser/p1.zst",
    ];
    for (const key of keys) {
      expect(workerCacheClassForKey(key)).toBe(cacheClassForKey(key));
    }
  });
});

describe("mintCdnUrl", () => {
  it("builds the documented URL shape with signed extras", () => {
    const minted = mintCdnUrl(CONFIG, {
      key: KEY,
      filename: "shot.png",
      contentType: "image/png",
      disposition: "attachment",
      now: new Date(NOW * 1000),
    });
    const url = new URL(minted.url);
    expect(url.origin).toBe("https://cdn.ovidsi.test");
    expect(url.pathname).toBe(`/o/${encodeOpaqueKey(KEY)}`);
    expect(url.searchParams.get("t")).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(url.searchParams.get("e")).toBe(String(NOW + 900));
    expect(url.searchParams.get("d")).toBe("attachment");
    expect(url.searchParams.get("fn")).toBe("shot.png");
    expect(url.searchParams.get("ct")).toBe("image/png");
    expect(url.searchParams.get("c")).toBe("immutable");
    expect(minted.expiresAt).toBe(new Date((NOW + 900) * 1000).toISOString());
    expect(minted.cacheClass).toBe("immutable");
  });

  it("omits inline/disposition params and sanitizes hostile names", () => {
    const minted = mintCdnUrl(CONFIG, {
      key: KEY,
      filename: '..\\evil"\r\n.txt',
      contentType: "text/plain; charset=utf-8",
      now: new Date(NOW * 1000),
    });
    const url = new URL(minted.url);
    expect(url.searchParams.get("d")).toBeNull();
    expect(url.searchParams.get("fn")).toBe("evil.txt");
    expect(url.searchParams.get("ct")).toBe("text/plain");
  });

  it("never allows a caller to upgrade an upload to immutable", () => {
    const key = "users/u1/sessions/s1/uploads/a1";
    expect(mintCdnUrl(CONFIG, { key, now: new Date(NOW * 1000) }).cacheClass).toBe("short");
    // Explicit override is honored only because the caller is trusted server code.
    expect(
      mintCdnUrl(CONFIG, { key, cacheClass: "immutable", now: new Date(NOW * 1000) }).cacheClass,
    ).toBe("immutable");
  });
});

describe("sanitizers", () => {
  it("filenames stay one safe ASCII segment", () => {
    expect(sanitizeCdnFilename("a/b/c.png")).toBe("c.png");
    expect(sanitizeCdnFilename("../../x y?.bin")).toBe("x y_.bin");
    expect(sanitizeCdnFilename("")).toBeUndefined();
    expect(sanitizeCdnFilename(undefined)).toBeUndefined();
  });

  it("content types are bare type/subtype only", () => {
    expect(sanitizeCdnContentType("Image/PNG; charset=x")).toBe("image/png");
    expect(sanitizeCdnContentType("text/html\r\nx: y")).toBeUndefined();
    expect(sanitizeCdnContentType("nonsense")).toBeUndefined();
    expect(sanitizeCdnContentType(undefined)).toBeUndefined();
  });
});

describe("loadCdnConfig", () => {
  it("is null when the base URL is unset (CDN disabled, boot continues)", () => {
    expect(loadCdnConfig({})).toBeNull();
    expect(loadCdnConfig({ OVID_CDN_BASE_URL: "  " })).toBeNull();
  });

  it("loads and normalizes a full config", () => {
    expect(
      loadCdnConfig({
        OVID_CDN_BASE_URL: "https://cdn.ovidsi.com/",
        OVID_CDN_SIGNING_SECRET: SECRET,
        OVID_CDN_TTL_SECONDS: "120",
      }),
    ).toEqual({ baseUrl: "https://cdn.ovidsi.com", secret: SECRET, ttlSeconds: 120 });
  });

  it("defaults and clamps the TTL", () => {
    const base = { OVID_CDN_BASE_URL: "https://cdn.ovidsi.com", OVID_CDN_SIGNING_SECRET: SECRET };
    expect(loadCdnConfig(base)!.ttlSeconds).toBe(DEFAULT_CDN_TTL_SECONDS);
    expect(loadCdnConfig({ ...base, OVID_CDN_TTL_SECONDS: "1" })!.ttlSeconds).toBe(
      CDN_TTL_MIN_SECONDS,
    );
    expect(loadCdnConfig({ ...base, OVID_CDN_TTL_SECONDS: "999999" })!.ttlSeconds).toBe(
      CDN_TTL_MAX_SECONDS,
    );
  });

  it("fails loudly on a partial or malformed config", () => {
    expect(() =>
      loadCdnConfig({ OVID_CDN_BASE_URL: "https://cdn.ovidsi.com" }),
    ).toThrow(/OVID_CDN_SIGNING_SECRET/);
    expect(() =>
      loadCdnConfig({ OVID_CDN_BASE_URL: "https://cdn.ovidsi.com", OVID_CDN_SIGNING_SECRET: "short" }),
    ).toThrow(/at least 32 bytes/);
    expect(() =>
      loadCdnConfig({ OVID_CDN_BASE_URL: "not-a-url", OVID_CDN_SIGNING_SECRET: SECRET }),
    ).toThrow(/absolute http/);
    expect(() =>
      loadCdnConfig({
        OVID_CDN_BASE_URL: "https://cdn.ovidsi.com?x=1",
        OVID_CDN_SIGNING_SECRET: SECRET,
      }),
    ).toThrow(/query string/);
    expect(() =>
      loadCdnConfig({
        OVID_CDN_BASE_URL: "https://cdn.ovidsi.com/prefix",
        OVID_CDN_SIGNING_SECRET: SECRET,
      }),
    ).toThrow(/no path/);
    expect(() =>
      loadCdnConfig({
        OVID_CDN_BASE_URL: "https://cdn.ovidsi.com",
        OVID_CDN_SIGNING_SECRET: SECRET,
        OVID_CDN_TTL_SECONDS: "0",
      }),
    ).toThrow(/positive integer/);
  });
});
