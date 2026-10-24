import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";

import { searchWorkspacePaths } from "./studioFiles.js";

const roots: string[] = [];
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

function fixture(): { root: string; workspaceDir: string; repoDir: string } {
  const root = mkdtempSync(join(tmpdir(), "ovid-studio-files-"));
  roots.push(root);
  const workspaceDir = join(root, "workspace");
  mkdirSync(join(workspaceDir, "app", ".git"), { recursive: true });
  return { root, workspaceDir, repoDir: "app" };
}

describe("confined Unicode workspace path search", () => {
  it("case-folds and normalizes the whole repo-relative path with deterministic results", async () => {
    const { workspaceDir, repoDir } = fixture();
    const directory = join(workspaceDir, "app", "docs", "Cafe\u0301");
    mkdirSync(directory, { recursive: true });
    const name = "NAÏVE Straße.TXT";
    writeFileSync(join(directory, name), "visible\n");
    writeFileSync(join(workspaceDir, "app", ".git", name), "metadata\n");
    writeFileSync(join(workspaceDir, "app", ".git", "config"), "secret metadata\n");

    const request = { workspaceDir, repoDir, query: "naïve strasse" } as const;
    const first = await searchWorkspacePaths(request);
    const second = await searchWorkspacePaths(request);
    const expected = [
      { path: `app/docs/Cafe\u0301/${name}`, name },
    ];
    expect(first).toEqual({ items: expected, truncated: false });
    expect(second).toEqual(first);

    const composedDirectory = await searchWorkspacePaths({
      workspaceDir,
      repoDir,
      query: "DOCS/CAFÉ",
    });
    expect(composedDirectory.items).toEqual(expected);

    const metadata = await searchWorkspacePaths({ workspaceDir, repoDir, query: ".git" });
    expect(metadata).toEqual({ items: [], truncated: false });
  });

  it("sorts deterministically and reports a result-limit truncation", async () => {
    const { workspaceDir, repoDir } = fixture();
    for (const name of ["b.txt", "a.txt", "A.txt"]) {
      writeFileSync(join(workspaceDir, "app", name), name);
    }

    const request = { workspaceDir, repoDir, query: "", limit: 2 } as const;
    const first = await searchWorkspacePaths(request);
    expect(first).toEqual({
      items: [
        { path: "app/A.txt", name: "A.txt" },
        { path: "app/a.txt", name: "a.txt" },
      ],
      truncated: true,
    });
    expect(await searchWorkspacePaths(request)).toEqual(first);
  });

  it("applies the default 50 and maximum 100 result limits", async () => {
    const { workspaceDir, repoDir } = fixture();
    for (let index = 0; index < 101; index += 1) {
      writeFileSync(join(workspaceDir, "app", `file-${String(index).padStart(3, "0")}.txt`), "x\n");
    }

    const defaultLimit = await searchWorkspacePaths({ workspaceDir, repoDir, query: "file-" });
    expect(defaultLimit.items).toHaveLength(50);
    expect(defaultLimit.truncated).toBe(true);
    expect(defaultLimit.items[0]?.path).toBe("app/file-000.txt");

    const maximum = await searchWorkspacePaths({
      workspaceDir,
      repoDir,
      query: "file-",
      limit: 1000,
    });
    expect(maximum.items).toHaveLength(100);
    expect(maximum.truncated).toBe(true);
    expect(maximum.items[99]?.path).toBe("app/file-099.txt");
  });

  it("never follows file or directory symlinks outside the workspace", async () => {
    const { root, workspaceDir, repoDir } = fixture();
    const outside = join(root, "outside");
    mkdirSync(outside);
    writeFileSync(join(outside, "outside-secret.txt"), "do not expose\n");
    symlinkSync(outside, join(workspaceDir, "app", "linked-directory"), "dir");
    symlinkSync(
      join(outside, "outside-secret.txt"),
      join(workspaceDir, "app", "linked-file.txt"),
      "file",
    );

    const result = await searchWorkspacePaths({
      workspaceDir,
      repoDir,
      query: "outside-secret",
    });
    expect(result).toEqual({ items: [], truncated: false });
  });

  it("rejects a symlinked search root and a .git search root", async () => {
    const { root, workspaceDir } = fixture();
    const outside = join(root, "outside");
    mkdirSync(outside);
    writeFileSync(join(outside, "secret.txt"), "do not expose\n");
    symlinkSync(outside, join(workspaceDir, "linked-root"), "dir");

    await expect(
      searchWorkspacePaths({ workspaceDir, repoDir: "linked-root", query: "secret" }),
    ).rejects.toMatchObject({ code: "invalid_path" });
    await expect(
      searchWorkspacePaths({ workspaceDir, repoDir: "app/.git", query: "config" }),
    ).rejects.toMatchObject({ code: "invalid_path" });
  });
});
