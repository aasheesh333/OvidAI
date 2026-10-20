import { describe, expect, it } from "vitest";

import {
  assertSafeRelPath,
  assertSafeSegment,
  r2Keys,
  sanitizeArtifactName,
} from "./keys.js";
import { KeyLayoutError } from "./errors.js";

describe("r2Keys — spec §10 exact strings", () => {
  it("workspaceArchive", () => {
    expect(r2Keys.workspaceArchive("u1", "s1")).toBe("users/u1/workspaces/s1.tar.zst");
  });

  it("workspaceManifest", () => {
    expect(r2Keys.workspaceManifest("u1", "s1")).toBe("users/u1/workspaces/s1.manifest.json");
  });

  it("browserState", () => {
    expect(r2Keys.browserState("u1", "p1")).toBe("users/u1/browser/p1.zst");
  });

  it("artifact — sanitizes the name into the key", () => {
    expect(r2Keys.artifact("u1", "s1", "0192c0de", "my shot.png")).toBe(
      "users/u1/artifacts/s1/0192c0de-my_shot.png",
    );
  });

  it("contentAddressedArtifact — unique id + sha256 prefix + sanitized name", () => {
    const sha = "a".repeat(64);
    expect(r2Keys.contentAddressedArtifact("u1", "s1", "0192c0de", sha, "my shot.png")).toBe(
      `users/u1/artifacts/s1/0192c0de-${"a".repeat(16)}-my_shot.png`,
    );
  });

  it("contentAddressedArtifact rejects a malformed digest", () => {
    expect(() => r2Keys.contentAddressedArtifact("u1", "s1", "x", "not-hex", "a")).toThrow(
      KeyLayoutError,
    );
  });
});

describe("assertSafeSegment", () => {
  it("throws KeyLayoutError on bad segments", () => {
    for (const bad of ["", ".", "..", "a/b", "a\\b", "a\nb"]) {
      expect(() => assertSafeSegment(bad)).toThrow(KeyLayoutError);
    }
  });

  it("accepts a plausible ULID-uuid7 id", () => {
    expect(() => assertSafeSegment("01J-test-uuid7")).not.toThrow();
  });
});

describe("assertSafeRelPath", () => {
  it("normalizes '.' segments", () => {
    expect(assertSafeRelPath("a/./b")).toBe("a/b");
  });

  it("throws on empty, absolute, traversal and control-char paths", () => {
    for (const bad of ["/etc/passwd", "../x", "a/../..\\b", ""]) {
      expect(() => assertSafeRelPath(bad)).toThrow(KeyLayoutError);
    }
  });
});

describe("sanitizeArtifactName", () => {
  it("neutralizes traversal and weird characters", () => {
    const out = sanitizeArtifactName("../../x y?.bin");
    expect(out).not.toContain("..");
    expect(out).toMatch(/^[A-Za-z0-9._-]+$/);
  });

  it("collapses runs, strips leading dots, truncates, defaults empty", () => {
    expect(sanitizeArtifactName("a???b")).toBe("a_b");
    expect(sanitizeArtifactName(".hidden")).toBe("hidden");
    expect(sanitizeArtifactName("x".repeat(200))).toHaveLength(80);
    expect(sanitizeArtifactName("")).toBe("artifact");
  });
});
