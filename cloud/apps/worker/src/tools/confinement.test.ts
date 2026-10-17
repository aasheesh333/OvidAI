import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { PATH_ESCAPE_CORPUS } from "@ovid/sandbox";
import { ConfinementError, resolveConfined } from "./confinement.js";

// ---------------------------------------------------------------------------
// Path confinement (P2 Task 12). No services: everything happens inside one
// tmpdir "workspace root" — including an `evil → /etc` symlink so the
// realpath-escape proof runs against the REAL /etc (not a mock).
//
// Every PATH_ESCAPE_CORPUS entry (Task 4, one source of truth) must reject;
// workspace-relative and /workspace-prefixed paths must resolve to HOST paths
// inside the root.
// ---------------------------------------------------------------------------

describe("resolveConfined", () => {
  let root: string;

  beforeAll(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-confine-"));
    await mkdir(join(root, "sub"), { recursive: true });
    await writeFile(join(root, "sub", "ok.ts"), "export {};\n", "utf8");
    await symlink("/etc", join(root, "evil"));
    // A symlink that stays INSIDE the workspace is legitimate (relative tools
    // like pnpm/uv create them) — must resolve, not reject.
    await symlink(join(root, "sub"), join(root, "sub-link"));
    // A nested symlink pointing outside via a directory that exists.
    await mkdir(join(root, "nested"), { recursive: true });
    await symlink("/etc/passwd", join(root, "nested", "passwd-link"));
  });

  afterAll(async () => {
    await rm(root, { recursive: true, force: true }).catch(() => {});
  });

  it("resolves workspace-relative paths to the HOST path inside the root", async () => {
    await expect(resolveConfined(root, "sub/ok.ts")).resolves.toBe(join(root, "sub", "ok.ts"));
  });

  it("resolves /workspace-prefixed paths to the same HOST path", async () => {
    await expect(resolveConfined(root, "/workspace/sub/ok.ts")).resolves.toBe(
      join(root, "sub", "ok.ts"),
    );
  });

  it("resolves through a symlink that stays inside the workspace", async () => {
    await expect(resolveConfined(root, "sub-link/ok.ts")).resolves.toBe(
      join(root, "sub-link", "ok.ts"),
    );
  });

  it("resolves a not-yet-existing path whose nearest existing ancestor is inside the root", async () => {
    await expect(resolveConfined(root, "sub/new/deep/file.txt")).resolves.toBe(
      join(root, "sub", "new", "deep", "file.txt"),
    );
  });

  it("rejects every PATH_ESCAPE_CORPUS entry with ConfinementError", async () => {
    for (const p of PATH_ESCAPE_CORPUS) {
      await expect(resolveConfined(root, p)).rejects.toBeInstanceOf(ConfinementError);
    }
  });

  it("rejects a symlink to /etc (existing target outside the root)", async () => {
    await expect(resolveConfined(root, "evil/passwd")).rejects.toBeInstanceOf(ConfinementError);
    await expect(resolveConfined(root, "evil")).rejects.toBeInstanceOf(ConfinementError);
  });

  it("rejects a file symlink pointing outside the root", async () => {
    await expect(resolveConfined(root, "nested/passwd-link")).rejects.toBeInstanceOf(
      ConfinementError,
    );
  });

  it("rejects a not-yet-existing path under an outside-pointing symlink", async () => {
    // evil → /etc exists, but evil/nope-missing does not: the NEAREST EXISTING
    // ANCESTOR (evil) realpaths outside the root — the escape must still reject.
    await expect(resolveConfined(root, "evil/nope-missing")).rejects.toBeInstanceOf(
      ConfinementError,
    );
  });

  it("rejects absolute paths that are not /workspace-prefixed", async () => {
    for (const p of ["/etc", "/root/.ssh/id_rsa", "/workspaces/users/999999/x"]) {
      await expect(resolveConfined(root, p)).rejects.toBeInstanceOf(ConfinementError);
    }
  });

  it("error message names the offending path (file tools prefix it with 'confined:')", async () => {
    const err = await resolveConfined(root, "../../etc/passwd").then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(ConfinementError);
    expect((err as Error).message).toBe("../../etc/passwd is outside the workspace");
  });
});
