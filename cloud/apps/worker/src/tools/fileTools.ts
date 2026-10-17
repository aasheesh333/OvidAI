import { lstat, mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative, sep } from "node:path";
import { z } from "zod";
import { ConfinementError, resolveConfined } from "./confinement.js";
import {
  BINARY_SNIFF_BYTES,
  GLOB_MAX_ENTRIES,
  GREP_FILE_MAX_BYTES,
  GREP_LINE_CAP,
  GREP_MAX_RESULTS_DEFAULT,
  GREP_MAX_RESULTS_MAX,
  READ_FILE_CAP_BYTES,
  capWithSuffix,
} from "./systemPrompt.js";
import { invalidInput, type AgentTool, type ToolResult } from "./types.js";

/**
 * Host-side file tools (plan Task 12): read_file / write_file / edit_file /
 * glob_files / grep_files. They operate DIRECTLY on the handle's HOST
 * workspaceDir through resolveConfined — no jail spawn (the workspace is only
 * writable by the sandbox uid and the root-run worker; command-level access
 * goes through run_shell, which does jail).
 *
 * Every path is confined first; ConfinementError maps to the pinned
 * "confined: <path> is outside the workspace" isError result (Task 14 asserts
 * the prefix). Directory walks (glob/grep) skip symlinks entirely, so neither
 * tool can follow a link out of the workspace.
 */

// -- shared plumbing ---------------------------------------------------------

const pathSchema = z.string().min(1);

/** Resolves a model-supplied path against the workspace root, confined. */
function confined(ctx: { sandbox: { workspaceDir: string } }, p: string): Promise<string> {
  return resolveConfined(ctx.sandbox.workspaceDir, p);
}

function confinedErrorResult(err: ConfinementError): ToolResult {
  return { content: `confined: ${err.message}`, isError: true };
}

/** Runs `fn` with the confined path, mapping ConfinementError to the pinned result. */
async function withConfined(
  ctx: { sandbox: { workspaceDir: string } },
  p: string,
  fn: (host: string) => Promise<ToolResult>,
): Promise<ToolResult> {
  try {
    const host = await confined(ctx, p);
    return await fn(host);
  } catch (err) {
    if (err instanceof ConfinementError) return confinedErrorResult(err);
    throw err;
  }
}

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

function fileErrorResult(err: unknown, p: string): ToolResult | null {
  if (isErrnoException(err) && err.code === "ENOENT") {
    return { content: `no such file: ${p}`, isError: true };
  }
  return null;
}

/** NUL in the first BINARY_SNIFF_BYTES bytes ⇒ binary. */
function looksBinary(buf: Buffer): boolean {
  return buf.subarray(0, BINARY_SNIFF_BYTES).includes(0);
}

/** Depth-first walk collecting file paths relative to `dir`, skipping symlinks. */
async function walkFiles(dir: string, prefix: string, out: string[]): Promise<void> {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return; // raced-away subtree — report what we have
  }
  for (const e of entries) {
    const rel = prefix === "" ? e.name : `${prefix}/${e.name}`;
    if (e.isSymbolicLink()) continue; // never follow links out of (or around) the workspace
    const full = join(dir, e.name);
    if (e.isDirectory()) {
      await walkFiles(full, rel, out);
    } else if (e.isFile()) {
      out.push(rel);
    }
  }
}

/**
 * The optional search base directory: the root itself, or a confined subpath.
 * Results stay WORKSPACE-relative (prefixed with the base) so the model can
 * feed them straight back into read_file/edit_file, whose paths are
 * workspace-relative too.
 *
 * Confinement failures return the pinned isError TOOL RESULT (never throw —
 * the never-throws contract is part of the AgentTool seam, and Task 14 asserts
 * the "confined:" prefix): an escaping base path on glob_files/grep_files is a
 * benign model input, not an infra error.
 */
async function searchRoot(
  ctx: { sandbox: { workspaceDir: string } },
  p: string | undefined,
): Promise<{ dir: string; prefix: string } | { error: ToolResult }> {
  if (p === undefined) return { dir: ctx.sandbox.workspaceDir, prefix: "" };
  try {
    const host = await resolveConfined(ctx.sandbox.workspaceDir, p);
    const prefix = relative(ctx.sandbox.workspaceDir, host).split(sep).join("/");
    return { dir: host, prefix };
  } catch (err) {
    if (err instanceof ConfinementError) return { error: confinedErrorResult(err) };
    throw err;
  }
}

// -- glob → regex (translation pinned by the brief) --------------------------

/**
 * `**`→`.*`, `*`→`[^/]*`, `?`→`[^/]`, `{a,b}`→`(a|b)` (alternatives
 * recursively translated through the UNANCHORED core so nested anchors never
 * end up inside an alternation), everything else escaped. globToRegex anchors
 * the whole result at both ends and matches against workspace-RELATIVE paths.
 *
 * Note the pinned translation's one blind spot: a leading double-star requires
 * a slash after it, so root-level files match the single-star form but not the
 * double-star form — deliberate verbatim implementation (the translation IS
 * the spec).
 */
function globToRegexSource(pattern: string): string {
  const escape = (c: string): string => c.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  let re = "";
  let i = 0;
  while (i < pattern.length) {
    const c = pattern[i]!;
    if (c === "*") {
      if (pattern[i + 1] === "*") {
        re += ".*";
        i += 2;
      } else {
        re += "[^/]*";
        i += 1;
      }
    } else if (c === "?") {
      re += "[^/]";
      i += 1;
    } else if (c === "{") {
      const close = pattern.indexOf("}", i + 1);
      if (close === -1) {
        re += "\\{";
        i += 1;
      } else {
        const alts = pattern.slice(i + 1, close).split(",");
        re += `(${alts.map((a) => globToRegexSource(a)).join("|")})`;
        i = close + 1;
      }
    } else {
      re += escape(c);
      i += 1;
    }
  }
  return re;
}

export function globToRegex(pattern: string): RegExp {
  return new RegExp(`^${globToRegexSource(pattern)}$`);
}

// -- read_file ---------------------------------------------------------------

export function createReadFileTool(): AgentTool {
  const schema = z.object({ path: pathSchema });
  return {
    name: "read_file",
    description: "Read a UTF-8 text file from the workspace (up to 256 KiB).",
    parameters: {
      type: "object",
      properties: { path: { type: "string", description: "Workspace-relative file path." } },
      required: ["path"],
    },
    async execute(input, ctx): Promise<ToolResult> {
      const parsed = schema.safeParse(input);
      if (!parsed.success) return invalidInput(parsed.error);
      const p = parsed.data.path;
      return withConfined(ctx, p, async (host) => {
        let buf: Buffer;
        try {
          buf = await readFile(host);
        } catch (err) {
          const mapped = fileErrorResult(err, p);
          if (mapped !== null) return mapped;
          throw err;
        }
        if (looksBinary(buf)) return { content: `binary file: ${p}`, isError: true };
        return {
          content: capWithSuffix(buf.toString("utf8"), READ_FILE_CAP_BYTES),
          isError: false,
        };
      });
    },
  };
}

// -- write_file --------------------------------------------------------------

export function createWriteFileTool(): AgentTool {
  const schema = z.object({ path: pathSchema, content: z.string() });
  return {
    name: "write_file",
    description: "Write a file in the workspace, creating parent directories as needed.",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string", description: "Workspace-relative file path." },
        content: { type: "string", description: "The full file content to write." },
      },
      required: ["path", "content"],
    },
    async execute(input, ctx): Promise<ToolResult> {
      const parsed = schema.safeParse(input);
      if (!parsed.success) return invalidInput(parsed.error);
      const { path: p, content } = parsed.data;
      return withConfined(ctx, p, async (host) => {
        await mkdir(dirname(host), { recursive: true });
        await writeFile(host, content, "utf8");
        return { content: `wrote ${Buffer.byteLength(content, "utf8")} bytes`, isError: false };
      });
    },
  };
}

// -- edit_file ---------------------------------------------------------------

export function createEditFileTool(): AgentTool {
  const schema = z.object({
    path: pathSchema,
    oldString: z.string(),
    newString: z.string(),
    replaceAll: z.boolean().optional(),
  });
  return {
    name: "edit_file",
    description:
      "Replace exact string occurrences in a workspace file. oldString must match exactly once unless replaceAll is true.",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string", description: "Workspace-relative file path." },
        oldString: { type: "string", description: "The exact text to replace." },
        newString: { type: "string", description: "The replacement text." },
        replaceAll: { type: "boolean", description: "Replace every occurrence." },
      },
      required: ["path", "oldString", "newString"],
    },
    async execute(input, ctx): Promise<ToolResult> {
      const parsed = schema.safeParse(input);
      if (!parsed.success) return invalidInput(parsed.error);
      const { path: p, oldString, newString, replaceAll } = parsed.data;
      return withConfined(ctx, p, async (host) => {
        let text: string;
        try {
          text = await readFile(host, "utf8");
        } catch (err) {
          const mapped = fileErrorResult(err, p);
          if (mapped !== null) return mapped;
          throw err;
        }
        const count = text.split(oldString).length - 1;
        if (count === 0) {
          return { content: `edit_file: 0 matches for oldString in ${p}`, isError: true };
        }
        if (count > 1 && replaceAll !== true) {
          return {
            content: `edit_file: ${count} matches for oldString in ${p} (use replaceAll to replace them all)`,
            isError: true,
          };
        }
        const updated =
          replaceAll === true
            ? text.split(oldString).join(newString)
            : text.replace(oldString, newString);
        await writeFile(host, updated, "utf8");
        return {
          content: `replaced ${replaceAll === true ? count : 1} occurrence(s) in ${p}`,
          isError: false,
        };
      });
    },
  };
}

// -- glob_files --------------------------------------------------------------

export function createGlobFilesTool(): AgentTool {
  const schema = z.object({ pattern: z.string().min(1), path: z.string().optional() });
  return {
    name: "glob_files",
    description: "List workspace files matching a glob pattern (**, *, ?, {a,b}).",
    parameters: {
      type: "object",
      properties: {
        pattern: { type: "string", description: 'Glob pattern, e.g. "**/*.ts".' },
        path: { type: "string", description: "Optional base directory inside the workspace." },
      },
      required: ["pattern"],
    },
    async execute(input, ctx): Promise<ToolResult> {
      const parsed = schema.safeParse(input);
      if (!parsed.success) return invalidInput(parsed.error);
      const { pattern, path: base } = parsed.data;
      const root = await searchRoot(ctx, base);
      if ("error" in root) return root.error;
      const rels: string[] = [];
      await walkFiles(root.dir, root.prefix, rels);
      const re = globToRegex(pattern);
      const matches = rels.filter((r) => re.test(r)).sort();
      const lines =
        matches.length > GLOB_MAX_ENTRIES
          ? [...matches.slice(0, GLOB_MAX_ENTRIES), "[truncated]"]
          : matches;
      return { content: lines.join("\n"), isError: false };
    },
  };
}

// -- grep_files --------------------------------------------------------------

export function createGrepFilesTool(): AgentTool {
  const schema = z.object({
    pattern: z.string().min(1),
    path: z.string().optional(),
    maxResults: z.number().int().positive().optional(),
  });
  return {
    name: "grep_files",
    description:
      "Search workspace file contents with a JavaScript regular expression. Returns path:line:text matches.",
    parameters: {
      type: "object",
      properties: {
        pattern: { type: "string", description: "JavaScript regular expression source." },
        path: { type: "string", description: "Optional base directory inside the workspace." },
        maxResults: { type: "integer", description: "Maximum matches (default 200, max 1000)." },
      },
      required: ["pattern"],
    },
    async execute(input, ctx): Promise<ToolResult> {
      const parsed = schema.safeParse(input);
      if (!parsed.success) return invalidInput(parsed.error);
      const { pattern, path: base } = parsed.data;
      const maxResults = Math.min(
        parsed.data.maxResults ?? GREP_MAX_RESULTS_DEFAULT,
        GREP_MAX_RESULTS_MAX,
      );
      let re: RegExp;
      try {
        re = new RegExp(pattern);
      } catch (err) {
        return {
          content: `invalid regex: ${err instanceof Error ? err.message : String(err)}`,
          isError: true,
        };
      }
      const root = await searchRoot(ctx, base);
      if ("error" in root) return root.error;
      const rels: string[] = [];
      await walkFiles(root.dir, root.prefix, rels);
      const out: string[] = [];
      for (const rel of rels) {
        if (out.length >= maxResults) break;
        // `rel` is workspace-relative (prefixed); the filesystem path strips
        // the prefix back off the search root.
        const inBase = root.prefix === "" ? rel : rel.slice(root.prefix.length + 1);
        const full = join(root.dir, inBase);
        let st;
        try {
          st = await lstat(full);
        } catch {
          continue; // raced away
        }
        if (!st.isFile()) continue;
        let size: number;
        try {
          ({ size } = await stat(full));
        } catch {
          continue;
        }
        if (size > GREP_FILE_MAX_BYTES) continue;
        let buf: Buffer;
        try {
          buf = await readFile(full);
        } catch {
          continue;
        }
        if (looksBinary(buf)) continue;
        const lines = buf.toString("utf8").split("\n");
        for (let i = 0; i < lines.length; i += 1) {
          const line = lines[i]!.replace(/\r$/, "");
          if (re.test(line)) {
            out.push(`${rel}:${i + 1}:${line.slice(0, GREP_LINE_CAP)}`);
            if (out.length >= maxResults) break;
          }
        }
      }
      return { content: out.join("\n"), isError: false };
    },
  };
}
