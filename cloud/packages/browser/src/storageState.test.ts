import { describe, expect, it } from "vitest";

import {
  BROWSER_STATE_MAGIC,
  BrowserStateError,
  decodeBrowserState,
  encodeBrowserState,
  mergeStorageState,
  pruneStorageState,
  type StorageCookie,
  type StorageOrigin,
  type StorageState,
} from "./storageState.js";

const KEY = "test-master-key";

function cookie(
  partial: Partial<StorageCookie> & Pick<StorageCookie, "name" | "domain">,
): StorageCookie {
  return {
    value: "v",
    path: "/",
    expires: -1,
    httpOnly: false,
    secure: false,
    sameSite: "Lax",
    ...partial,
  };
}

function origin(originUrl: string, entries: { name: string; value: string }[] = []): StorageOrigin {
  return { origin: originUrl, localStorage: entries };
}

describe("mergeStorageState", () => {
  it("keeps stored entries for domains/origins the capture did not touch (Review Focus #1)", () => {
    const stored: StorageState = {
      cookies: [cookie({ name: "keep", domain: "other.test" })],
      origins: [origin("https://other.test/", [{ name: "k", value: "v" }])],
    };
    const captured: StorageState = {
      cookies: [cookie({ name: "fresh", domain: "site.test" })],
      origins: [origin("https://site.test/")],
    };
    const merged = mergeStorageState(stored, captured);
    expect(merged.cookies.map((c) => `${c.domain}:${c.name}`).sort()).toEqual([
      "other.test:keep",
      "site.test:fresh",
    ]);
    expect(merged.origins.map((o) => o.origin)).toEqual(["https://other.test/", "https://site.test/"]);
  });

  it("replaces same-domain cookies wholesale — the capture owns every domain it touched", () => {
    const stored: StorageState = {
      cookies: [
        cookie({ name: "a", domain: "site.test", value: "old-a" }),
        cookie({ name: "b", domain: "site.test", value: "old-b" }),
      ],
      origins: [],
    };
    const captured: StorageState = {
      cookies: [cookie({ name: "a", domain: "site.test", value: "new-a" })],
      origins: [],
    };
    const merged = mergeStorageState(stored, captured);
    expect(merged.cookies).toEqual([cookie({ name: "a", domain: "site.test", value: "new-a" })]);
  });

  it("ports CookieMerge.missingPairs semantics: own value wins, donor-only names are added", () => {
    // Dart lib/core/session_browser_profiles.dart:100 — every session keeps
    // its OWN value for every cookie it already holds and only receives the
    // names it lacks. "Own" = the fresh capture; "donor" = the stored state.
    const stored: StorageState = {
      cookies: [
        cookie({ name: "login_tok", domain: "site.test", value: "donor" }),
        cookie({ name: "donor_only", domain: "other.test", value: "x" }),
      ],
      origins: [],
    };
    const captured: StorageState = {
      cookies: [cookie({ name: "login_tok", domain: "site.test", value: "own" })],
      origins: [],
    };
    const merged = mergeStorageState(stored, captured);
    const own = merged.cookies.find((c) => c.name === "login_tok");
    expect(own?.value).toBe("own");
    expect(merged.cookies.some((c) => c.name === "donor_only")).toBe(true);
  });

  it("is idempotent: merge(merge(s,c),c) deep-equals merge(s,c)", () => {
    const stored: StorageState = {
      cookies: [
        cookie({ name: "a", domain: "a.test" }),
        cookie({ name: "b", domain: "b.test" }),
      ],
      origins: [origin("https://a.test/"), origin("https://b.test/")],
    };
    const captured: StorageState = {
      cookies: [cookie({ name: "c", domain: "c.test" }), cookie({ name: "a2", domain: "a.test" })],
      origins: [origin("https://c.test/")],
    };
    const once = mergeStorageState(stored, captured);
    const twice = mergeStorageState(once, captured);
    expect(twice).toEqual(once);
  });

  it("byte-stable: two merges of the same inputs are JSON.stringify-identical regardless of input order", () => {
    const cA = cookie({ name: "a", domain: "a.test" });
    const cB = cookie({ name: "b", domain: "b.test" });
    const cC = cookie({ name: "z", domain: "a.test" });
    const cD = cookie({ name: "d", domain: "c.test" });
    const oA = origin("https://a.test/");
    const oB = origin("https://b.test/");
    const oC = origin("https://c.test/");
    const s: StorageState = { cookies: [cA, cB, cC], origins: [oA, oB] };
    const c: StorageState = { cookies: [cD], origins: [oC] };
    const one = JSON.stringify(mergeStorageState(s, c));
    const two = JSON.stringify(mergeStorageState(s, c));
    expect(two).toBe(one);
    // permuted input arrays — the sorted output must not care
    const sPerm: StorageState = { cookies: [cC, cB, cA], origins: [oB, oA] };
    const cPerm: StorageState = { cookies: [cD], origins: [oC] };
    expect(JSON.stringify(mergeStorageState(sPerm, cPerm))).toBe(one);
  });

  it("returns the captured state sorted when stored is null", () => {
    const captured: StorageState = {
      cookies: [cookie({ name: "z", domain: "b.test" }), cookie({ name: "a", domain: "a.test" })],
      origins: [origin("https://b.test/"), origin("https://a.test/")],
    };
    const merged = mergeStorageState(null, captured);
    expect(merged.cookies.map((c) => c.domain)).toEqual(["a.test", "b.test"]);
    expect(merged.origins.map((o) => o.origin)).toEqual(["https://a.test/", "https://b.test/"]);
  });
});

describe("pruneStorageState", () => {
  it("drops the largest origin whole, keeps the login cookie and the small origin (Review Focus #5)", () => {
    const bigValue = "x".repeat(9 * 1024 * 1024);
    const state: StorageState = {
      cookies: [cookie({ name: "login_tok", domain: "site.test", value: "tok", expires: -1 })],
      origins: [
        origin("https://small.test/", [{ name: "k", value: "v" }]),
        origin("https://big.test/", [{ name: "blob", value: bigValue }]),
      ],
    };
    const pruned = pruneStorageState(state, 1_000_000);
    expect(Buffer.byteLength(JSON.stringify(pruned))).toBeLessThanOrEqual(1_000_000);
    expect(pruned.origins.map((o) => o.origin)).toEqual(["https://small.test/"]);
    expect(pruned.cookies.map((c) => c.name)).toEqual(["login_tok"]);
  });

  it("session-cookie survival pin: definite past expiry dropped, the session cookie SURVIVES", () => {
    const nowSec = Math.floor(Date.now() / 1000);
    const state: StorageState = {
      cookies: [
        cookie({ name: "login_tok", domain: "site.test", value: "s".repeat(40), expires: -1 }),
        cookie({ name: "dead", domain: "site.test", value: "d".repeat(400), expires: nowSec - 3600 }),
      ],
      origins: [],
    };
    // Over the cap with both cookies; under it once the expired one is gone.
    const pruned = pruneStorageState(state, 300);
    expect(pruned.cookies.map((c) => c.name)).toEqual(["login_tok"]);
  });

  it("drops the longest NON-session value when over cap; a shorter session cookie survives", () => {
    const state: StorageState = {
      cookies: [
        cookie({ name: "sess", domain: "site.test", value: "s".repeat(10), expires: -1 }),
        cookie({ name: "big", domain: "site.test", value: "b".repeat(600), expires: 4102444800 }),
      ],
      origins: [],
    };
    const pruned = pruneStorageState(state, 300);
    expect(pruned.cookies.map((c) => c.name)).toEqual(["sess"]);
  });

  it("documented last resort: session cookies alone over the cap ⇒ empty state", () => {
    const state: StorageState = {
      cookies: [cookie({ name: "login_tok", domain: "site.test", value: "s".repeat(500), expires: -1 })],
      origins: [],
    };
    const pruned = pruneStorageState(state, 10);
    expect(pruned).toEqual({ cookies: [], origins: [] });
  });

  it("leaves an under-cap state with no expired cookies unchanged", () => {
    const state: StorageState = {
      cookies: [cookie({ name: "login_tok", domain: "site.test", value: "tok", expires: -1 })],
      origins: [origin("https://site.test/", [{ name: "theme", value: "dark" }])],
    };
    expect(pruneStorageState(state)).toEqual(state);
  });
});

describe("encodeBrowserState / decodeBrowserState", () => {
  const state: StorageState = {
    cookies: [
      cookie({ name: "login_tok", domain: "site.test", value: "tok", expires: -1 }),
      cookie({ name: "prefs", domain: "site.test", value: "dark", expires: 4102444800 }),
    ],
    origins: [origin("https://site.test/", [{ name: "theme", value: "dark" }])],
  };

  it("envelope structure: OVIDBS01 magic, version byte === 1, length ≥ 81 + 16", () => {
    const blob = encodeBrowserState(state, KEY);
    expect(blob.subarray(0, 8).toString("utf8")).toBe(BROWSER_STATE_MAGIC);
    expect(blob[8]).toBe(1);
    expect(blob.byteLength).toBeGreaterThanOrEqual(81 + 16);
  });

  it("round-trips deep-equal — the blob is self-sufficient (iv_w travels in it)", () => {
    const blob = encodeBrowserState(state, KEY);
    expect(decodeBrowserState(blob, KEY)).toEqual(state);
    // decode also accepts a plain Uint8Array view of the same bytes
    expect(decodeBrowserState(new Uint8Array(blob), KEY)).toEqual(state);
  });

  it("a flipped byte in the data region ⇒ BrowserStateError with a cause (GCM auth, never garbage)", () => {
    const blob = encodeBrowserState(state, KEY);
    for (const offset of [81 + 3, blob.length - 1]) {
      const corrupt = Buffer.from(blob);
      corrupt[offset] ^= 0xff;
      let err: unknown;
      try {
        decodeBrowserState(corrupt, KEY);
        expect.unreachable("decode must throw on tampered data");
      } catch (e) {
        err = e;
      }
      expect(err).toBeInstanceOf(BrowserStateError);
      expect((err as BrowserStateError).cause).toBeDefined();
    }
  });

  it("wrong masterKey ⇒ BrowserStateError", () => {
    const blob = encodeBrowserState(state, KEY);
    expect(() => decodeBrowserState(blob, "other-master-key")).toThrow(BrowserStateError);
  });

  it("corrupted magic / bumped version byte / truncation to 40 B ⇒ BrowserStateError", () => {
    const blob = encodeBrowserState(state, KEY);
    const badMagic = Buffer.from(blob);
    badMagic[0] ^= 0xff;
    expect(() => decodeBrowserState(badMagic, KEY)).toThrow(BrowserStateError);
    const badVersion = Buffer.from(blob);
    badVersion[8] = 2;
    expect(() => decodeBrowserState(badVersion, KEY)).toThrow(BrowserStateError);
    expect(() => decodeBrowserState(blob.subarray(0, 40), KEY)).toThrow(BrowserStateError);
  });

  it("TEST SEAM ONLY: fixed {dek, ivW, iv} ⇒ byte-identical encodes; a different DEK differs", () => {
    const dek = Buffer.alloc(32, 7);
    const ivW = Buffer.alloc(12, 1);
    const iv = Buffer.alloc(12, 2);
    const a = encodeBrowserState(state, KEY, { dek, ivW, iv });
    const b = encodeBrowserState(state, KEY, { dek, ivW, iv });
    expect(b.equals(a)).toBe(true);
    const c = encodeBrowserState(state, KEY, { dek: Buffer.alloc(32, 9), ivW, iv });
    expect(c.equals(a)).toBe(false);
    // seam-encoded blobs still decode under the production path
    expect(decodeBrowserState(a, KEY)).toEqual(state);
  });

  it("production path is NON-deterministic: two encodes differ, both round-trip", () => {
    const a = encodeBrowserState(state, KEY);
    const b = encodeBrowserState(state, KEY);
    expect(a.equals(b)).toBe(false);
    expect(decodeBrowserState(a, KEY)).toEqual(state);
    expect(decodeBrowserState(b, KEY)).toEqual(state);
  });
});
