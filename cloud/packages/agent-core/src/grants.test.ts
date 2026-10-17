import { describe, expect, it } from "vitest";
import {
  findApplicableGrant,
  grantMatchesHost,
  grantMatchesPath,
  hostCoveredBy,
  normalizeGrantHost,
  normalizeGrantPath,
  pathCoveredBy,
  type GrantLike,
} from "./grants.js";

/**
 * Hierarchical grant matching — port of lib/core/grant_store.dart
 * (grant_store_test.dart + grant_store_blank_path_test.dart +
 * worker_d_grant_store_fixes_test.dart), expressed against the cloud's
 * function-level API. The brief's pinned vectors lead each group.
 */

const pathGrant = (pattern: string, decision: GrantLike["decision"] = "always"): GrantLike => ({
  kind: "path",
  pattern,
  decision,
});
const hostGrant = (pattern: string, decision: GrantLike["decision"] = "always"): GrantLike => ({
  kind: "host",
  pattern,
  decision,
});

describe("grantMatchesPath — hierarchical coverage", () => {
  it("the brief's pinned vector: /ws/a covers /ws/a/b/c, not /ws/ab, not /ws", () => {
    expect(grantMatchesPath("/ws/a", "/ws/a")).toBe(true);
    expect(grantMatchesPath("/ws/a", "/ws/a/b/c")).toBe(true);
    expect(grantMatchesPath("/ws/a", "/ws/ab")).toBe(false);
    expect(grantMatchesPath("/ws/a", "/ws")).toBe(false);
    expect(grantMatchesPath("/ws/a", "/ws/a/../other")).toBe(false); // escapes the grant root
  });

  it("parent folder covers the folder itself and every descendant, never siblings/parents", () => {
    expect(grantMatchesPath("/data/work", "/data/work/a.txt")).toBe(true);
    expect(grantMatchesPath("/data/work", "/data/work/sub/deep/b.txt")).toBe(true);
    expect(grantMatchesPath("/data/work", "/data/work")).toBe(true);
    expect(grantMatchesPath("/data/work", "/data/work2")).toBe(false);
    expect(grantMatchesPath("/data/work", "/data/work2/x.txt")).toBe(false);
    expect(grantMatchesPath("/data/work", "/data")).toBe(false);
    expect(grantMatchesPath("/data/work", "/other")).toBe(false);
  });

  it("dot segments and redundant slashes normalize before matching (no trailing-slash sensitivity)", () => {
    expect(grantMatchesPath("/data/work/", "/data/work/./sub/../f.txt")).toBe(true);
    expect(grantMatchesPath("/data/work", "//data//work//f.txt")).toBe(true);
    expect(grantMatchesPath("/data/work/", "/data/work")).toBe(true);
    expect(grantMatchesPath("/data/work", "/data/work/")).toBe(true);
    expect(grantMatchesPath("/data/work", "/data/work/../../etc/passwd")).toBe(false);
  });

  it("a root grant covers every absolute path (worker_d fix #2)", () => {
    expect(pathCoveredBy("/", "/")).toBe(true);
    expect(pathCoveredBy("/", "/etc/passwd")).toBe(true);
    expect(pathCoveredBy("/", "/a/b/c")).toBe(true);
    expect(grantMatchesPath("/", "/anywhere/at/all.txt")).toBe(true);
    expect(pathCoveredBy("/a/b", "/a/bc")).toBe(false);
    expect(pathCoveredBy("/a/b", "/a/b/c")).toBe(true);
  });

  it("blank / near-blank patterns match nothing (blank-path parity)", () => {
    for (const blank of ["", " ", "\t\n "]) {
      expect(grantMatchesPath(blank, "/etc/passwd")).toBe(false);
      expect(grantMatchesPath(blank, blank)).toBe(false);
      expect(pathCoveredBy(blank, "/etc/passwd")).toBe(false);
    }
  });

  it("blank targets never match, even a root grant", () => {
    for (const blank of ["", " ", "\t\n "]) {
      expect(grantMatchesPath("/", blank)).toBe(false);
    }
  });

  it("normalized an explicit root survives with its recursion explicit", () => {
    expect(normalizeGrantPath(" / ")).toBe("/");
    expect(normalizeGrantPath("/a/b/../c")).toBe("/a/c");
    expect(normalizeGrantPath("//data//work//")).toBe("/data/work");
    expect(normalizeGrantPath("/data/work/./sub/../f.txt")).toBe("/data/work/f.txt");
  });
});

describe("grantMatchesHost — child domains, not siblings", () => {
  it("the brief's pinned vector: example.com covers api.example.com, not notexample.com", () => {
    expect(grantMatchesHost("example.com", "example.com")).toBe(true);
    expect(grantMatchesHost("example.com", "api.example.com")).toBe(true);
    expect(grantMatchesHost("example.com", "deep.api.example.com")).toBe(true);
    expect(grantMatchesHost("example.com", "notexample.com")).toBe(false);
    expect(grantMatchesHost("example.com", "example.com.evil.org")).toBe(false);
    expect(grantMatchesHost("example.com", "com")).toBe(false);
  });

  it("a host grant covers every port on that host", () => {
    expect(grantMatchesHost("127.0.0.1", "127.0.0.1:8080")).toBe(true);
    expect(grantMatchesHost("127.0.0.1", "127.0.0.1")).toBe(true);
    expect(grantMatchesHost("127.0.0.1", "127.0.0.2")).toBe(false);
    expect(grantMatchesHost("127.0.0.1", "localhost")).toBe(false);
  });

  it("host normalization: case, port, brackets, trailing dot", () => {
    expect(grantMatchesHost("Example.COM:8443", "example.com")).toBe(true);
    expect(grantMatchesHost("Example.COM", "EXAMPLE.com.")).toBe(true);
    expect(grantMatchesHost("[::1]", "::1")).toBe(true);
    expect(grantMatchesHost("::1", "[::1]:443")).toBe(true);
    expect(normalizeGrantHost("EXAMPLE.com:8443")).toBe("example.com");
    expect(normalizeGrantHost("[::1]")).toBe("::1");
    expect(normalizeGrantHost("example.com.")).toBe("example.com");
    expect(normalizeGrantHost("  ")).toBe("");
  });

  it("IP literals match only themselves — no suffix lookalikes (worker_d fix #1)", () => {
    expect(hostCoveredBy("127.0.0.1", "127.0.0.1")).toBe(true);
    expect(hostCoveredBy("127.0.0.1", "127.0.0.1:8080")).toBe(true);
    expect(hostCoveredBy("127.0.0.1", "evil.127.0.0.1")).toBe(false);
    expect(hostCoveredBy("127.0.0.1", "127.0.0.2")).toBe(false);
    expect(hostCoveredBy("::1", "::1")).toBe(true);
    expect(hostCoveredBy("[::1]", "::1")).toBe(true);
    expect(hostCoveredBy("::1", "evil.::1")).toBe(false);
    expect(hostCoveredBy("example.com", "api.example.com")).toBe(true);
    expect(hostCoveredBy("example.com", "notexample.com")).toBe(false);
  });

  it("blank hosts match nothing", () => {
    expect(grantMatchesHost("", "example.com")).toBe(false);
    expect(grantMatchesHost("example.com", "")).toBe(false);
    expect(grantMatchesHost("  ", "  ")).toBe(false);
  });
});

describe("findApplicableGrant — specificity and deny precedence", () => {
  it("returns null when nothing matches", () => {
    expect(findApplicableGrant([pathGrant("/ws/a")], "path", "/ws/b")).toBeNull();
    expect(findApplicableGrant([hostGrant("example.com")], "host", "other.org")).toBeNull();
    expect(findApplicableGrant([hostGrant("example.com")], "path", "example.com")).toBeNull(); // kind mismatch
    expect(findApplicableGrant([], "path", "/ws/a")).toBeNull();
  });

  it("deny beats allow at EQUAL specificity (the same pattern)", () => {
    const grants = [pathGrant("/ws/a", "allow"), pathGrant("/ws/a", "deny")];
    expect(findApplicableGrant(grants, "path", "/ws/a/b")).toMatchObject({ decision: "deny" });
    // Order does not matter.
    const reversed = [pathGrant("/ws/a", "deny"), pathGrant("/ws/a", "allow")];
    expect(findApplicableGrant(reversed, "path", "/ws/a/b")).toMatchObject({ decision: "deny" });
  });

  it("deeper pattern wins over shallower — a specific allow beats a shallow deny", () => {
    const grants = [pathGrant("/ws", "deny"), pathGrant("/ws/a", "allow")];
    expect(findApplicableGrant(grants, "path", "/ws/a/b")).toMatchObject({
      pattern: "/ws/a",
      decision: "allow",
    });
    // …and the shallow deny still applies outside the specific grant.
    expect(findApplicableGrant(grants, "path", "/ws/c/d")).toMatchObject({
      pattern: "/ws",
      decision: "deny",
    });
  });

  it("deeper host wins over shallower host", () => {
    const grants = [hostGrant("example.com", "deny"), hostGrant("api.example.com", "allow")];
    expect(findApplicableGrant(grants, "host", "x.api.example.com")).toMatchObject({
      pattern: "api.example.com",
      decision: "allow",
    });
    expect(findApplicableGrant(grants, "host", "www.example.com")).toMatchObject({
      pattern: "example.com",
      decision: "deny",
    });
  });

  it("a root path grant is the LEAST specific (anything deeper wins)", () => {
    const grants = [pathGrant("/", "deny"), pathGrant("/ws", "allow")];
    expect(findApplicableGrant(grants, "path", "/ws/a")).toMatchObject({
      pattern: "/ws",
      decision: "allow",
    });
    expect(findApplicableGrant(grants, "path", "/etc/passwd")).toMatchObject({
      pattern: "/",
      decision: "deny",
    });
  });

  it("host child-domain coverage composes with deny at the parent", () => {
    const grants = [hostGrant("example.com", "always"), hostGrant("example.com", "deny")];
    expect(findApplicableGrant(grants, "host", "api.example.com")).toMatchObject({
      decision: "deny",
    });
  });

  it("matching ignores grant rows of the other kind and blank patterns", () => {
    const grants = [hostGrant("example.com", "always"), pathGrant("  ", "allow")];
    expect(findApplicableGrant(grants, "path", "/ws/a")).toBeNull();
    expect(findApplicableGrant(grants, "host", "api.example.com")).toMatchObject({
      pattern: "example.com",
    });
  });
});
