import { createHash } from "node:crypto";
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { KeyLayoutError, NotFoundError, PreconditionFailedError, WorkspaceStateError } from "./errors.js";
import { writeWorkspaceFile, type HydrateDeps } from "./hydrate.js";
import { liveSubtree } from "./archive/uiTree.js";
import {
  deleteWorkspacePath,
  makeWorkspaceDir,
  moveWorkspacePath,
  type WorkspaceOpsDeps,
} from "./workspaceOps.js";
import { workspaceDir } from "./workspacePaths.js";

// Studio file management (Wave 2, ST-005/ST-007/ST-008/ST-015): the warm
// workspace mutations the worker file service exposes. Pure filesystem — no
// Postgres/Redis: the engines only need the uid resolver, the root and an
// activity tracker, so these run in every CI lane.

const UID = "u-ops";
const SID = "s-ops";

function sha(text: string): string {
  return createHash("sha256").update(Buffer.from(text)).digest("hex");
}

async function exists(p: string): Promise<boolean> {
  try {
    await lstat(p);
    return true;
  } catch {
    return false;
  }
}

describe("workspace ops (warm workspace mutations)", () => {
  let root: string;
  let dir: string;
  let bumps: string[];
  let deps: WorkspaceOpsDeps;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-wsops-"));
    dir = workspaceDir(root, UID, SID);
    await mkdir(dir, { recursive: true });
    bumps = [];
    deps = {
      sandboxUid: async (u: string) => u,
      workspacesRoot: root,
      activity: {
        bump: async (s: string) => {
          bumps.push(s);
        },
        read: async () => null,
        readMany: async () => new Map(),
      } as unknown as WorkspaceOpsDeps["activity"],
    };
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  const ref = { userId: UID, sessionId: SID };

  /** writeWorkspaceFile needs the manifest repo too (null row = no du refresh). */
  function writeDeps(): HydrateDeps {
    return {
      ...deps,
      fileManifests: {
        get: async () => null,
        upsertWarm: async () => {},
      },
    } as unknown as HydrateDeps;
  }

  // -- PUT preconditions (ST-007 / ST-005) ---------------------------------

  it("ifMatchSha256 equal to the current bytes → the write lands", async () => {
    await writeFile(join(dir, "a.txt"), "old");
    const out = await writeWorkspaceFile(writeDeps(), { ...ref, path: "a.txt" }, Buffer.from("new"), {
      ifMatchSha256: sha("old"),
    });
    expect(out.sha256Hex).toBe(sha("new"));
    expect(await readFile(join(dir, "a.txt"), "utf8")).toBe("new");
  });

  it("ifMatchSha256 that no longer matches → baseline_mismatch, bytes untouched", async () => {
    await writeFile(join(dir, "a.txt"), "agent-wrote-this");
    const err = await writeWorkspaceFile(
      writeDeps(),
      { ...ref, path: "a.txt" },
      Buffer.from("studio-draft"),
      { ifMatchSha256: sha("old") },
    ).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(PreconditionFailedError);
    expect((err as PreconditionFailedError).code).toBe("baseline_mismatch");
    expect(await readFile(join(dir, "a.txt"), "utf8")).toBe("agent-wrote-this");
  });

  it("ifMatchSha256 on a file that was deleted meanwhile → baseline_mismatch (no resurrection)", async () => {
    const err = await writeWorkspaceFile(writeDeps(), { ...ref, path: "gone.txt" }, Buffer.from("x"), {
      ifMatchSha256: sha("old"),
    }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(PreconditionFailedError);
    expect((err as PreconditionFailedError).code).toBe("baseline_mismatch");
    expect(await exists(join(dir, "gone.txt"))).toBe(false);
  });

  it("ifNoneMatch refuses to overwrite an existing file (already_exists)", async () => {
    await writeFile(join(dir, "README.md"), "real readme");
    const err = await writeWorkspaceFile(writeDeps(), { ...ref, path: "README.md" }, Buffer.from(""), {
      ifNoneMatch: true,
    }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(PreconditionFailedError);
    expect((err as PreconditionFailedError).code).toBe("already_exists");
    expect(await readFile(join(dir, "README.md"), "utf8")).toBe("real readme");
  });

  it("ifNoneMatch creates a new file (and its parents) and leaves no temp files", async () => {
    const out = await writeWorkspaceFile(writeDeps(), { ...ref, path: "src/new.ts" }, Buffer.from("x"), {
      ifNoneMatch: true,
    });
    expect(out.path).toBe("src/new.ts");
    expect(await readFile(join(dir, "src", "new.ts"), "utf8")).toBe("x");
    const { readdir } = await import("node:fs/promises");
    expect(await readdir(join(dir, "src"))).toEqual(["new.ts"]);
  });

  // -- delete (ST-008) ------------------------------------------------------

  it("delete removes a file and bumps activity", async () => {
    await writeFile(join(dir, "a.txt"), "x");
    const out = await deleteWorkspacePath(deps, { ...ref, path: "a.txt" });
    expect(out).toEqual({ path: "a.txt", type: "file" });
    expect(await exists(join(dir, "a.txt"))).toBe(false);
    expect(bumps).toEqual([SID]);
  });

  it("delete of a non-empty folder needs recursive; with it the whole folder goes", async () => {
    await mkdir(join(dir, "src", "deep"), { recursive: true });
    await writeFile(join(dir, "src", "deep", "x.ts"), "x");
    const err = await deleteWorkspacePath(deps, { ...ref, path: "src" }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(PreconditionFailedError);
    expect((err as PreconditionFailedError).code).toBe("not_empty");
    expect(await exists(join(dir, "src", "deep", "x.ts"))).toBe(true);

    const out = await deleteWorkspacePath(deps, { ...ref, path: "src" }, { recursive: true });
    expect(out).toEqual({ path: "src", type: "dir" });
    expect(await exists(join(dir, "src"))).toBe(false);
  });

  it("delete of a missing path → NotFoundError", async () => {
    await expect(deleteWorkspacePath(deps, { ...ref, path: "nope.txt" })).rejects.toThrowError(
      NotFoundError,
    );
  });

  it("delete never follows a symlink out of the workspace (removes the link only)", async () => {
    const outside = await mkdtemp(join(tmpdir(), "ovid-wsops-out-"));
    await writeFile(join(outside, "keep.txt"), "keep");
    await symlink(outside, join(dir, "link"));
    const out = await deleteWorkspacePath(deps, { ...ref, path: "link" }, { recursive: true });
    expect(out.type).toBe("symlink");
    expect(await exists(join(dir, "link"))).toBe(false);
    expect(await readFile(join(outside, "keep.txt"), "utf8")).toBe("keep");
    await rm(outside, { recursive: true, force: true });
  });

  it("delete refuses a path whose parent escapes through a symlink", async () => {
    const outside = await mkdtemp(join(tmpdir(), "ovid-wsops-out-"));
    await writeFile(join(outside, "victim.txt"), "v");
    await symlink(outside, join(dir, "escape"));
    await expect(
      deleteWorkspacePath(deps, { ...ref, path: "escape/victim.txt" }),
    ).rejects.toThrowError(NotFoundError);
    expect(await exists(join(outside, "victim.txt"))).toBe(true);
    await rm(outside, { recursive: true, force: true });
  });

  it("delete rejects traversal and the workspace root itself", async () => {
    await expect(deleteWorkspacePath(deps, { ...ref, path: "../x" })).rejects.toThrowError(
      KeyLayoutError,
    );
    await expect(deleteWorkspacePath(deps, { ...ref, path: "." })).rejects.toThrowError(
      KeyLayoutError,
    );
  });

  it("every mutation on a missing (cold) workspace dir → not_warm", async () => {
    await rm(dir, { recursive: true, force: true });
    for (const op of [
      () => deleteWorkspacePath(deps, { ...ref, path: "a.txt" }),
      () => moveWorkspacePath(deps, { ...ref, from: "a.txt", to: "b.txt" }),
      () => makeWorkspaceDir(deps, { ...ref, path: "d" }),
    ]) {
      const err = await op().catch((e: unknown) => e);
      expect(err).toBeInstanceOf(WorkspaceStateError);
      expect((err as WorkspaceStateError).code).toBe("not_warm");
    }
  });

  // -- move / rename (ST-008) -------------------------------------------------

  it("move renames a file into a new folder", async () => {
    await writeFile(join(dir, "a.txt"), "x");
    const out = await moveWorkspacePath(deps, { ...ref, from: "a.txt", to: "docs/b.txt" });
    expect(out).toEqual({ from: "a.txt", to: "docs/b.txt" });
    expect(await exists(join(dir, "a.txt"))).toBe(false);
    expect(await readFile(join(dir, "docs", "b.txt"), "utf8")).toBe("x");
  });

  it("move never overwrites an existing destination (already_exists)", async () => {
    await writeFile(join(dir, "a.txt"), "a");
    await writeFile(join(dir, "b.txt"), "b");
    const err = await moveWorkspacePath(deps, { ...ref, from: "a.txt", to: "b.txt" }).catch(
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(PreconditionFailedError);
    expect((err as PreconditionFailedError).code).toBe("already_exists");
    expect(await readFile(join(dir, "b.txt"), "utf8")).toBe("b");
    expect(await readFile(join(dir, "a.txt"), "utf8")).toBe("a");
  });

  it("move renames a folder; moving a folder into itself is refused", async () => {
    await mkdir(join(dir, "src"), { recursive: true });
    await writeFile(join(dir, "src", "x.ts"), "x");
    await expect(
      moveWorkspacePath(deps, { ...ref, from: "src", to: "src/inner" }),
    ).rejects.toThrowError(KeyLayoutError);
    await moveWorkspacePath(deps, { ...ref, from: "src", to: "lib" });
    expect(await readFile(join(dir, "lib", "x.ts"), "utf8")).toBe("x");
  });

  it("move of a missing source → NotFoundError", async () => {
    await expect(
      moveWorkspacePath(deps, { ...ref, from: "nope", to: "x" }),
    ).rejects.toThrowError(NotFoundError);
  });

  // -- mkdir (ST-008) ---------------------------------------------------------

  it("mkdir creates nested folders and is idempotent for an existing folder", async () => {
    expect(await makeWorkspaceDir(deps, { ...ref, path: "a/b" })).toEqual({
      path: "a/b",
      created: true,
    });
    expect((await lstat(join(dir, "a", "b"))).isDirectory()).toBe(true);
    expect(await makeWorkspaceDir(deps, { ...ref, path: "a/b" })).toEqual({
      path: "a/b",
      created: false,
    });
  });

  it("mkdir over an existing file → already_exists", async () => {
    await writeFile(join(dir, "f"), "x");
    const err = await makeWorkspaceDir(deps, { ...ref, path: "f" }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(PreconditionFailedError);
    expect((err as PreconditionFailedError).code).toBe("already_exists");
  });

  // -- subtree (ST-015) -------------------------------------------------------

  it("liveSubtree lists one folder with workspace-relative paths", async () => {
    await mkdir(join(dir, "src", "deep"), { recursive: true });
    await writeFile(join(dir, "src", "a.ts"), "aa");
    await writeFile(join(dir, "src", "deep", "b.ts"), "b");
    await writeFile(join(dir, "top.txt"), "t");
    const tree = await liveSubtree(dir, "src");
    const paths = tree.roots.map((n) => n.path).sort();
    expect(paths).toEqual(["src/a.ts", "src/deep"]);
    const deep = tree.roots.find((n) => n.path === "src/deep")!;
    expect(deep.children?.map((c) => c.path)).toEqual(["src/deep/b.ts"]);
    expect(tree.totals.files).toBe(2);
  });

  it("liveSubtree refuses a missing folder or one reached through a symlink", async () => {
    await expect(liveSubtree(dir, "missing")).rejects.toThrowError(NotFoundError);
    const outside = await mkdtemp(join(tmpdir(), "ovid-wsops-out-"));
    await symlink(outside, join(dir, "link"));
    await expect(liveSubtree(dir, "link")).rejects.toThrowError(NotFoundError);
    await rm(outside, { recursive: true, force: true });
  });
});
