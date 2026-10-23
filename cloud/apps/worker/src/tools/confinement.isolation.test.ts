// The agent's own path input cannot reach another user's tree.
//
// `resolveConfined` is the whole security boundary for the host-side file
// tools (they never spawn a jail). These cases pin the three escapes: `..`,
// an absolute path, and a symlink inside the workspace that points out of it.

import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";

import { ConfinementError, resolveConfined } from "./confinement.js";

const roots: string[] = [];
afterAll(() => {
  for (const r of roots) rmSync(r, { recursive: true, force: true });
});

function dirs() {
  const mine = mkdtempSync(join(tmpdir(), "ovid-confine-"));
  const other = mkdtempSync(join(tmpdir(), "ovid-confine-other-"));
  roots.push(mine, other);
  writeFileSync(join(other, "secret.txt"), "another user's data");
  mkdirSync(join(mine, "sub"), { recursive: true });
  return { mine, other };
}

describe("resolveConfined", () => {
  it("accepts a plain relative path inside the workspace", async () => {
    const { mine } = dirs();
    await expect(resolveConfined(mine, "sub/file.txt")).resolves.toBe(
      join(mine, "sub", "file.txt"),
    );
  });

  it("accepts the /workspace-prefixed jail spelling", async () => {
    const { mine } = dirs();
    await expect(resolveConfined(mine, "/workspace/sub/file.txt")).resolves.toBe(
      join(mine, "sub", "file.txt"),
    );
  });

  it("refuses .. that climbs above the root", async () => {
    const { mine } = dirs();
    await expect(resolveConfined(mine, "../secret.txt")).rejects.toBeInstanceOf(
      ConfinementError,
    );
  });

  it("refuses an absolute path outside the workspace", async () => {
    const { mine } = dirs();
    await expect(resolveConfined(mine, "/etc/passwd")).rejects.toBeInstanceOf(
      ConfinementError,
    );
  });

  it("refuses a symlink that points at another user's directory", async () => {
    const { mine, other } = dirs();
    symlinkSync(other, join(mine, "escape"));
    await expect(resolveConfined(mine, "escape/secret.txt")).rejects.toBeInstanceOf(
      ConfinementError,
    );
  });

  it("refuses a symlink that points at another user's directory even for a NEW file", async () => {
    const { mine, other } = dirs();
    symlinkSync(other, join(mine, "escape"));
    // The final segment does not exist; the nearest existing ancestor is the
    // symlink, and that is what must be confined.
    await expect(resolveConfined(mine, "escape/not-yet.txt")).rejects.toBeInstanceOf(
      ConfinementError,
    );
  });
});
