// The browser's file area is per USER, not per chat.
//
// Owner: "har user ka 100 percent workspace isolated ho and usme har session
// 100 percent isolated ho bass studio screen and browser screen shared ho"
//
// Studio is already shared (a /studio bind of the user's repo root). The
// browser was not: it resolved to {uid}/sessions/{sessionId}, so a file the
// agent downloaded in one chat was invisible in the next, and the browser
// looked like a different browser in every chat.

import { describe, expect, it } from "vitest";

import { workspacePathFor } from "./engine.js";

const ROOT = "/workspaces/users";

describe("browser workspace scope", () => {
  it("is the same directory for every session of one user", () => {
    const a = workspacePathFor(ROOT, "u1");
    const b = workspacePathFor(ROOT, "u1");
    expect(a).toBe(b);
    expect(a).toBe("/workspaces/users/u1/browser");
  });

  it("never crosses users", () => {
    expect(workspacePathFor(ROOT, "u1")).not.toBe(workspacePathFor(ROOT, "u2"));
  });

  it("stays inside the workspaces root", () => {
    expect(workspacePathFor(ROOT, "u1").startsWith(`${ROOT}/`)).toBe(true);
  });

  it("rejects a userId that could escape the root", () => {
    for (const bad of ["../escape", "u/1", "", "a".repeat(65)]) {
      expect(() => workspacePathFor(ROOT, bad)).toThrow(/userId/);
    }
  });
});
