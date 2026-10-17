import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { SandboxHandle } from "@ovid/sandbox";
import type { ToolContext } from "./types.js";
import { createEditFileTool, createGlobFilesTool, createGrepFilesTool, createReadFileTool, createWriteFileTool } from "./fileTools.js";

// ---------------------------------------------------------------------------
// Host-side file tools (P2 Task 12): a fake ToolContext whose sandbox handle
// points at a REAL tmpdir workspace — every tool hits the real filesystem
// through resolveConfined (no jail spawn).
// ---------------------------------------------------------------------------

const READ_CAP = 256 * 1024;

describe("file tools (host-side over a tmpdir workspace)", () => {
  let root: string;
  let ctx: ToolContext;

  beforeAll(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-filetools-"));
    // A symlink escaping the workspace — glob/grep walks must skip it and
    // read/edit/write through it must refuse.
    const outside = await mkdtemp(join(tmpdir(), "ovid-outside-"));
    await writeFile(join(outside, "escape.txt"), "outside\n", "utf8");
    await symlink(outside, join(root, "evil-link"));
    await symlink(join(root, "real"), join(root, "self-link"));
    ctx = {
      sandbox: { workspaceDir: root } as SandboxHandle,
      userId: "u1",
      sessionId: "s1",
      runId: "r1",
      emitEvent: async () => {},
    };
    // kept for the symlink tests; removed in afterAll together with root
    await mkdir(join(root, "real"), { recursive: true });
    await writeFile(join(root, "real", "f.txt"), "in workspace\n", "utf8");
    (ctx as { __outside?: string }).__outside = outside;
  });

  afterAll(async () => {
    const outside = (ctx as { __outside?: string }).__outside;
    await rm(root, { recursive: true, force: true }).catch(() => {});
    if (outside !== undefined) await rm(outside, { recursive: true, force: true }).catch(() => {});
  });

  // ---- write_file / read_file roundtrip ---------------------------------

  it("write→read roundtrip: write creates parents, reports byte count; read returns the content", async () => {
    const write = createWriteFileTool();
    const read = createReadFileTool();

    const w = await write.execute({ path: "notes/deep/x.md", content: "# hi" }, ctx);
    expect(w).toEqual({ content: "wrote 4 bytes", isError: false });
    expect(await readFile(join(root, "notes", "deep", "x.md"), "utf8")).toBe("# hi");

    const r = await read.execute({ path: "notes/deep/x.md" }, ctx);
    expect(r).toEqual({ content: "# hi", isError: false });

    // /workspace-prefixed path reads the same host file
    const r2 = await read.execute({ path: "/workspace/notes/deep/x.md" }, ctx);
    expect(r2).toEqual({ content: "# hi", isError: false });
  });

  it("read_file caps at 256 KiB with a [truncated] suffix", async () => {
    await writeFile(join(root, "big.txt"), "x".repeat(READ_CAP + 5_000), "utf8");
    const r = await createReadFileTool().execute({ path: "big.txt" }, ctx);
    expect(r.isError).toBe(false);
    expect(r.content.length).toBeLessThanOrEqual(READ_CAP);
    expect(r.content.endsWith("[truncated]")).toBe(true);
    expect(r.content.length).toBeGreaterThan(READ_CAP - 100);
  });

  it("read_file rejects binary files (NUL in the first 8 KiB)", async () => {
    const binary = Buffer.concat([Buffer.from("ok\x00binary"), Buffer.alloc(16_000, 0x41)]);
    await writeFile(join(root, "blob.bin"), binary);
    const r = await createReadFileTool().execute({ path: "blob.bin" }, ctx);
    expect(r.isError).toBe(true);
    expect(r.content).toContain("binary");
  });

  it("read_file on a missing file is an isError result, not a throw", async () => {
    const r = await createReadFileTool().execute({ path: "nope.txt" }, ctx);
    expect(r.isError).toBe(true);
    expect(r.content).toContain("nope.txt");
  });

  it("confinement: escaping paths return the pinned 'confined:' prefix", async () => {
    for (const tool of [createReadFileTool(), createWriteFileTool(), createEditFileTool()]) {
      const input =
        tool.name === "read_file"
          ? { path: "../../etc/passwd" }
          : tool.name === "write_file"
            ? { path: "../../etc/passwd", content: "x" }
            : { path: "../../etc/passwd", oldString: "a", newString: "b" };
      const r = await tool.execute(input, ctx);
      expect(r.isError).toBe(true);
      expect(r.content.startsWith("confined: ")).toBe(true);
    }
    // reading through the outside-pointing symlink refuses too
    const r = await createReadFileTool().execute({ path: "evil-link/escape.txt" }, ctx);
    expect(r.isError).toBe(true);
    expect(r.content.startsWith("confined: ")).toBe(true);
  });

  it("invalid input is a non-throwing isError result (invalid_input: …)", async () => {
    const r = await createReadFileTool().execute({ path: 42 }, ctx);
    expect(r.isError).toBe(true);
    expect(r.content.startsWith("invalid_input: ")).toBe(true);
    const r2 = await createReadFileTool().execute({}, ctx);
    expect(r2.isError).toBe(true);
    expect(r2.content.startsWith("invalid_input: ")).toBe(true);
  });

  // ---- edit_file ----------------------------------------------------------

  it("edit_file: exactly-one-match rule and replaceAll", async () => {
    const edit = createEditFileTool();

    // 1 match → replaced
    await writeFile(join(root, "e1.txt"), "alpha beta gamma\n", "utf8");
    const one = await edit.execute({ path: "e1.txt", oldString: "beta", newString: "BETA" }, ctx);
    expect(one.isError).toBe(false);
    expect(await readFile(join(root, "e1.txt"), "utf8")).toBe("alpha BETA gamma\n");

    // 0 matches → isError naming the count
    const zero = await edit.execute({ path: "e1.txt", oldString: "nope", newString: "x" }, ctx);
    expect(zero.isError).toBe(true);
    expect(zero.content).toContain("0");

    // 2 matches without replaceAll → isError naming the count
    await writeFile(join(root, "e2.txt"), "a a a\n", "utf8");
    const two = await edit.execute({ path: "e2.txt", oldString: "a", newString: "b" }, ctx);
    expect(two.isError).toBe(true);
    expect(two.content).toContain("2");

    // replaceAll → every occurrence
    const all = await edit.execute(
      { path: "e2.txt", oldString: "a", newString: "b", replaceAll: true },
      ctx,
    );
    expect(all.isError).toBe(false);
    expect(await readFile(join(root, "e2.txt"), "utf8")).toBe("b b b\n");
  });

  // ---- glob_files ---------------------------------------------------------

  it("glob_files: **/*.ts finds nested .ts files, sorted, and skips escaping symlinks", async () => {
    const glob = createGlobFilesTool();
    await mkdir(join(root, "g", "deep"), { recursive: true });
    await writeFile(join(root, "g", "a.ts"), "", "utf8");
    await writeFile(join(root, "g", "deep", "b.ts"), "", "utf8");
    await writeFile(join(root, "g", "c.txt"), "", "utf8");
    // The pinned translation is ** → .* (slash-requiring): root-level files
    // are matched by *.ts, not by **/*.ts.
    await writeFile(join(root, "top.ts"), "", "utf8");

    const r = await glob.execute({ pattern: "**/*.ts", path: "g" }, ctx);
    expect(r.isError).toBe(false);
    // Results are WORKSPACE-relative (directly reusable as read_file paths).
    // The pinned translation's blind spot: `**` requires a slash, so only
    // rooted paths match — which the "g/" prefix provides here.
    expect(r.content).toBe("g/a.ts\ng/deep/b.ts");

    const top = await glob.execute({ pattern: "*.ts" }, ctx);
    expect(top.isError).toBe(false);
    // single-star matches workspace-ROOT files only
    expect(top.content).toBe("top.ts");

    // The evil-link symlink subtree is never walked.
    const all = await glob.execute({ pattern: "**/*.txt" }, ctx);
    expect(all.content).not.toContain("evil-link");
    expect(all.content).not.toContain("escape.txt");
    // self-link (inside the workspace) is a symlink — also skipped.
    expect(all.content).not.toContain("self-link");
  });

  it("glob_files: brace alternation and ? translation", async () => {
    const glob = createGlobFilesTool();
    await mkdir(join(root, "alt"), { recursive: true });
    await writeFile(join(root, "alt", "one.ts"), "", "utf8");
    await writeFile(join(root, "alt", "two.ts"), "", "utf8");
    await writeFile(join(root, "alt", "three.ts"), "", "utf8");

    // Patterns match WORKSPACE-relative paths, so a scoped search carries its
    // prefix inside the pattern (same semantics as the reference agent tools:
    // results are always directly reusable as read_file paths).
    const r = await glob.execute({ pattern: "alt/{one,two}.ts" }, ctx);
    expect(r.content).toBe("alt/one.ts\nalt/two.ts");

    const q = await glob.execute({ pattern: "alt/???.ts" }, ctx);
    expect(q.content).toBe("alt/one.ts\nalt/two.ts");
  });

  it("glob_files caps at 1000 entries with a [truncated] line", async () => {
    const dir = join(root, "many");
    await mkdir(dir, { recursive: true });
    for (let i = 0; i < 1002; i += 1) {
      await writeFile(join(dir, `f${String(i).padStart(5, "0")}.txt`), "", "utf8");
    }
    const r = await createGlobFilesTool().execute(
      { pattern: "**/*.txt", path: "many" },
      ctx,
    );
    const lines = r.content.split("\n");
    expect(lines).toHaveLength(1001); // 1000 matches + the marker line
    expect(lines[1000]).toBe("[truncated]");
    expect(lines[0]).toBe("many/f00000.txt");
  });

  // ---- grep_files ---------------------------------------------------------

  it("grep_files: 1-based line numbers, path:line:text format, text ≤ 500 chars", async () => {
    await writeFile(
      join(root, "grepme.txt"),
      "nothing here\nthe needle is on line two\nmore text\nneedle again\n",
      "utf8",
    );
    const r = await createGrepFilesTool().execute({ pattern: "needle" }, ctx);
    expect(r.isError).toBe(false);
    expect(r.content).toBe("grepme.txt:2:the needle is on line two\ngrepme.txt:4:needle again");
  });

  it("grep_files: scoped path, maxResults cap (default 200), long line truncation", async () => {
    const dir = join(root, "grepsub");
    await mkdir(dir, { recursive: true });
    const lines: string[] = [];
    for (let i = 1; i <= 300; i += 1) lines.push(`hit number ${i}`);
    await writeFile(join(dir, "hits.txt"), `${lines.join("\n")}\n`, "utf8");
    await writeFile(join(dir, "big.txt"), `${"y".repeat(600)} zzz-target ${"y".repeat(600)}\n`, "utf8");

    const capped = await createGrepFilesTool().execute(
      { pattern: "hit number", path: "grepsub", maxResults: 5 },
      ctx,
    );
    expect(capped.content.split("\n")).toHaveLength(5);

    const defaulted = await createGrepFilesTool().execute(
      { pattern: "hit number", path: "grepsub" },
      ctx,
    );
    expect(defaulted.content.split("\n")).toHaveLength(200); // default cap

    const long = await createGrepFilesTool().execute(
      { pattern: "zzz-target", path: "grepsub" },
      ctx,
    );
    expect(long.content).toContain("grepsub/big.txt:1:");
    // text portion is truncated to 500 chars
    expect(long.content.split(":")[2]!.length).toBe(500);
  });

  it("grep_files: invalid regex → isError; binary files skipped; >1 MiB files skipped", async () => {
    const grep = createGrepFilesTool();
    const invalid = await grep.execute({ pattern: "(" }, ctx);
    expect(invalid.isError).toBe(true);
    expect(invalid.content).toContain("invalid");

    await writeFile(join(root, "bin.dat"), Buffer.concat([Buffer.from("target\x00"), Buffer.alloc(100)]), );
    await writeFile(join(root, "huge.txt"), `x${"target".repeat(220_000)}`, "utf8");
    const r = await grep.execute({ pattern: "^target" }, ctx);
    expect(r.content).not.toContain("bin.dat");
    expect(r.content).not.toContain("huge.txt");
  });

  it("confinement: glob_files with an escaping path returns the pinned isError result, never throws", async () => {
    const r = await createGlobFilesTool().execute(
      { pattern: "**/*", path: "../../etc" },
      ctx,
    );
    expect(r.isError).toBe(true);
    expect(r.content.startsWith("confined: ")).toBe(true);
  });

  it("confinement: grep_files with an escaping path returns the pinned isError result, never throws", async () => {
    const r = await createGrepFilesTool().execute({ pattern: "root", path: "/etc" }, ctx);
    expect(r.isError).toBe(true);
    expect(r.content.startsWith("confined: ")).toBe(true);
  });
});
