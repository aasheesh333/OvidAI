/**
 * The P3 ADDITIVE tool set (ruling R1): these tools join the roster ALONGSIDE
 * P2's landed six (run_shell, read_file, write_file, edit_file, glob_files,
 * grep_files — which are NOT re-implemented here; agentToolAdapter.ts in
 * apps/worker adapts them onto the canonical seam).
 *
 * Every exec-class tool threads ctx.callKey through to sandbox.exec (so the
 * dispatch-level withToolTimeout can kill the call via sandbox.killCall), and
 * every result goes through spillToolOutput with toolOutputCapFor(name).
 *
 * Ported from lib/core/agent_service.dart (run_code/fs_edit/multi_edit/
 * notebook_edit/fs_glob/fs_grep/job_* dispatch); per-tool timeout budgets are
 * the Dart _toolTimeoutFor map.
 */

import type { SandboxPort } from "../ports.js";
import type { Tool, ToolContext, ToolResult } from "../types.js";
import {
  applyMultiEdit,
  applyNotebookEdit,
  parseEditList,
  parseNotebookEditMode,
} from "./structuredEdits.js";
import { spillToolOutput, toolOutputCapFor } from "./spill.js";

/** Dart _toolTimeoutFor parity (default 2 min everywhere else). */
const TOOL_TIMEOUTS: Record<string, number> = {
  run_code: 300_000, // 5 min
  job_start: 300_000, // 5 min
  fs_grep: 45_000,
  fs_glob: 45_000,
  job_output: 1_800_000, // exempt (waits on long jobs)
  job_list: 1_800_000,
};
const DEFAULT_TIMEOUT_MS = 120_000;

// -- shared plumbing -----------------------------------------------------------

function reqStr(args: Record<string, unknown>, key: string): string {
  const v = args[key];
  if (typeof v !== "string" || v === "") {
    throw new Error(`invalid_input: ${key} must be a non-empty string`);
  }
  return v;
}

function optStr(args: Record<string, unknown>, key: string): string | undefined {
  const v = args[key];
  return typeof v === "string" ? v : undefined;
}

function optInt(args: Record<string, unknown>, key: string): number | undefined {
  const v = args[key];
  return typeof v === "number" && Number.isInteger(v) ? v : undefined;
}

/** POSIX single-quotes a string for interpolation into a bash -c command. */
function shq(s: string): string {
  return `'${s.replace(/'/g, "'\\''")}'`;
}

function splitContentLines(content: string): string[] {
  const lines = content.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

/** Line-numbered windowing shared by file_read and fs_edit view. */
function numberedView(content: string, offset = 1, limit = 200, hardCap = 2000): string {
  const lines = splitContentLines(content);
  if (lines.length === 0) return "(empty file)";
  const start = Math.max(1, offset) - 1;
  const len = Math.min(Math.max(1, limit), hardCap);
  const slice = lines.slice(start, start + len);
  const body = slice.map((l, i) => `${String(start + i + 1).padStart(6)}\t${l}`).join("\n");
  const end = start + slice.length;
  return end < lines.length ? `${body}\n[showing lines ${start + 1}-${end} of ${lines.length}]` : body;
}

/**
 * Spills the content per the cap and wraps it as a ToolResult. Every tool
 * result goes through here (under the cap it is a verbatim no-op).
 */
async function finish(
  sandbox: SandboxPort,
  name: string,
  ctx: ToolContext,
  content: string,
  isError = false,
): Promise<ToolResult> {
  const text = await spillToolOutput(
    // The session workspace for the P3 additive tools is the sandbox workspace
    // root (P2's runProcessor model — uploads etc. live there too).
    { sandbox, userId: ctx.userId, workspaceRelDir: "" },
    name,
    content,
    toolOutputCapFor(name),
  );
  return { content: text, isError };
}

/** Runs a tool body; user-level failures become isError results, never throws. */
async function run(body: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await body();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const content = /outside the workspace/.test(msg) ? `confined: ${msg}` : msg;
    return { content, isError: true };
  }
}

/** [CC]-style glob: ** matches any depth, * one segment. */
function globToRegExp(pattern: string): RegExp {
  const segs = pattern.split("/");
  let re = "^";
  for (let i = 0; i < segs.length; i += 1) {
    const s = segs[i];
    if (s === "**") {
      re += "(?:[^/]+/)*";
      continue;
    }
    re += s.replace(/[.+?^${}()|[\]\\]/g, "\\$&").split("*").join("[^/]*");
    if (i < segs.length - 1) re += "/";
  }
  return new RegExp(`${re}$`);
}

// -- tool builders ---------------------------------------------------------------

export function createSandboxTools(deps: { sandbox: SandboxPort }): Tool[] {
  const { sandbox } = deps;

  const tool = (
    name: string,
    description: string,
    parameters: Record<string, unknown>,
    execute: (args: Record<string, unknown>, ctx: ToolContext) => Promise<ToolResult>,
  ): Tool => ({
    spec: { name, description, parameters },
    timeoutMs: TOOL_TIMEOUTS[name] ?? DEFAULT_TIMEOUT_MS,
    execute: (args, ctx) => run(() => execute(args, ctx)),
  });

  const tools: Tool[] = [
    // -- run_code -------------------------------------------------------------
    tool(
      "run_code",
      "Run a Python or JavaScript snippet and return output.",
      {
        type: "object",
        properties: {
          code: { type: "string" },
          lang: { type: "string", enum: ["python", "javascript"] },
        },
        required: ["code"],
      },
      async (args, ctx) => {
        const code = reqStr(args, "code");
        const lang = optStr(args, "lang") ?? "python";
        if (lang !== "python" && lang !== "javascript") {
          return { content: `Unsupported language: ${lang}. Use python or javascript.`, isError: true };
        }
        const cmd =
          lang === "python" ? `python3 -c ${shq(code)}` : `node -e ${shq(code)}`;
        const res = await sandbox.exec(ctx.userId, {
          cmd,
          timeoutMs: TOOL_TIMEOUTS.run_code,
          callKey: ctx.callKey,
        });
        let content = res.stdout;
        if (res.stderr !== "") content += `\n[stderr]\n${res.stderr}`;
        content += `\n[exit ${res.exitCode}]`;
        return finish(sandbox, "run_code", ctx, content, res.exitCode !== 0);
      },
    ),

    // -- file_read --------------------------------------------------------------
    tool(
      "file_read",
      "Read a file from the workspace with line-numbered windowing. Use offset/limit to page large files.",
      {
        type: "object",
        properties: {
          path: { type: "string" },
          offset: { type: "integer", description: "1-based first line of the window (default 1)." },
          limit: { type: "integer", description: "Max lines to return (default 200, hard cap 2000)." },
        },
        required: ["path"],
      },
      async (args, ctx) => {
        const path = reqStr(args, "path");
        const content = await sandbox.readFile(ctx.userId, path);
        return finish(
          sandbox,
          "file_read",
          ctx,
          numberedView(content, optInt(args, "offset"), optInt(args, "limit") ?? 200),
        );
      },
    ),

    // -- file_write -------------------------------------------------------------
    tool(
      "file_write",
      "Create or update a file in the workspace, replacing its whole content.",
      {
        type: "object",
        properties: { path: { type: "string" }, content: { type: "string" } },
        required: ["path", "content"],
      },
      async (args, ctx) => {
        const path = reqStr(args, "path");
        const content = optStr(args, "content") ?? "";
        await sandbox.writeFile(ctx.userId, path, content);
        return finish(sandbox, "file_write", ctx, `wrote ${path} (${content.length} chars)`);
      },
    ),

    // -- fs_edit ----------------------------------------------------------------
    tool(
      "fs_edit",
      "Precise file editing — view, create, or replace an exact string in a workspace file. " +
        "Ops: view (show file with line numbers), create (new file), " +
        "str_replace (old_str must match EXACTLY once in the file), " +
        "insert (insert new_str after line N).",
      {
        type: "object",
        properties: {
          command: { type: "string", enum: ["view", "create", "str_replace", "insert"] },
          path: { type: "string" },
          file_text: { type: "string", description: "Content for create op" },
          old_str: { type: "string", description: "Exact string to replace (str_replace op)" },
          new_str: { type: "string", description: "Replacement string (str_replace/insert op)" },
          insert_line: { type: "integer", description: "Line number after which to insert (insert op)" },
        },
        required: ["command", "path"],
      },
      async (args, ctx) => {
        const command = reqStr(args, "command");
        const path = reqStr(args, "path");
        if (command === "view") {
          const content = await sandbox.readFile(ctx.userId, path);
          return finish(
            sandbox,
            "fs_edit",
            ctx,
            numberedView(content, optInt(args, "offset"), optInt(args, "limit") ?? 200),
          );
        }
        if (command === "create") {
          if (await sandbox.exists(ctx.userId, path)) {
            return { content: `file already exists: ${path}`, isError: true };
          }
          await sandbox.writeFile(ctx.userId, path, optStr(args, "file_text") ?? "");
          return finish(sandbox, "fs_edit", ctx, `created ${path}`);
        }
        if (command === "str_replace") {
          const oldStr = reqStr(args, "old_str");
          const newStr = optStr(args, "new_str") ?? "";
          const content = await sandbox.readFile(ctx.userId, path);
          const count = content.split(oldStr).length - 1;
          if (count === 0) {
            return { content: `str_replace failed: old_str not found in ${path}`, isError: true };
          }
          if (count > 1) {
            return {
              content: `str_replace failed: old_str matches ${count} times in ${path} — add surrounding context to make it unique`,
              isError: true,
            };
          }
          await sandbox.writeFile(ctx.userId, path, content.replace(oldStr, newStr));
          return finish(sandbox, "fs_edit", ctx, `replaced 1 occurrence in ${path}`);
        }
        if (command === "insert") {
          const newStr = reqStr(args, "new_str");
          const insertLine = optInt(args, "insert_line") ?? 0;
          const content = await sandbox.readFile(ctx.userId, path);
          const lines = content.split("\n");
          // a trailing "\n" is the last inserted line's terminator, not a new line
          const inserted = newStr.endsWith("\n") ? newStr.slice(0, -1).split("\n") : newStr.split("\n");
          lines.splice(Math.max(0, insertLine), 0, ...inserted);
          await sandbox.writeFile(ctx.userId, path, lines.join("\n"));
          return finish(sandbox, "fs_edit", ctx, `inserted after line ${insertLine} in ${path}`);
        }
        throw new Error(`invalid_input: fs_edit command must be view, create, str_replace or insert (got "${command}")`);
      },
    ),

    // -- multi_edit ---------------------------------------------------------------
    tool(
      "multi_edit",
      "[CC] MultiEdit: apply several exact string replacements to ONE file, in order, atomically — " +
        "every edit applies to the result of the previous one, and if any edit fails nothing is written. " +
        "Each old_string must match exactly once unless replace_all is true. Read the file first. " +
        "To create a file, give one edit with an empty old_string.",
      {
        type: "object",
        properties: {
          file_path: { type: "string" },
          edits: {
            type: "array",
            items: {
              type: "object",
              properties: {
                old_string: { type: "string" },
                new_string: { type: "string" },
                replace_all: { type: "boolean" },
              },
              required: ["old_string", "new_string"],
            },
          },
        },
        required: ["file_path", "edits"],
      },
      async (args, ctx) => {
        const path = reqStr(args, "file_path");
        const edits = parseEditList(args.edits);
        const exists = await sandbox.exists(ctx.userId, path);
        if (!exists && edits[0].oldString !== "") {
          return {
            content: `no such file: ${path} — to create it, make the first edit's old_string empty`,
            isError: true,
          };
        }
        const content = exists ? await sandbox.readFile(ctx.userId, path) : "";
        const out = applyMultiEdit(content, edits);
        await sandbox.writeFile(ctx.userId, path, out);
        return finish(sandbox, "multi_edit", ctx, `applied ${edits.length} edits to ${path}`);
      },
    ),

    // -- notebook_edit -------------------------------------------------------------
    tool(
      "notebook_edit",
      "[CC] NotebookEdit: edit ONE cell of a Jupyter .ipynb notebook by cell_id " +
        "(notebook metadata and other cells/outputs are preserved). " +
        "edit_mode: replace (default, overwrite the cell source), insert (new cell AFTER cell_id, " +
        "or first when cell_id is omitted; needs cell_type), delete.",
      {
        type: "object",
        properties: {
          notebook_path: { type: "string" },
          cell_id: { type: "string" },
          new_source: { type: "string" },
          cell_type: { type: "string", enum: ["code", "markdown"] },
          edit_mode: { type: "string", enum: ["replace", "insert", "delete"] },
        },
        required: ["notebook_path", "new_source"],
      },
      async (args, ctx) => {
        const path = reqStr(args, "notebook_path");
        const mode = parseNotebookEditMode(args.edit_mode);
        const source = await sandbox.readFile(ctx.userId, path);
        const out = applyNotebookEdit(source, {
          cellId: optStr(args, "cell_id"),
          newSource: optStr(args, "new_source") ?? "",
          cellType: optStr(args, "cell_type"),
          mode,
        });
        await sandbox.writeFile(ctx.userId, path, out);
        return finish(sandbox, "notebook_edit", ctx, `notebook ${path} updated (${mode})`);
      },
    ),

    // -- fs_glob --------------------------------------------------------------------
    tool(
      "fs_glob",
      "Find files by glob pattern in the workspace. ** matches any depth, * matches one segment. " +
        'Example: "**/*.ts", "lib/**/*.yaml", "src/*.js". Returns up to 100 matching paths (sorted).',
      {
        type: "object",
        properties: {
          pattern: { type: "string" },
          path: { type: "string", description: "Directory to search in (default: workspace root)" },
        },
        required: ["pattern"],
      },
      async (args, ctx) => {
        const pattern = reqStr(args, "pattern");
        const res = await sandbox.exec(ctx.userId, {
          cmd: "find . -type f",
          cwd: optStr(args, "path") ?? ".",
          timeoutMs: TOOL_TIMEOUTS.fs_glob,
          callKey: ctx.callKey,
        });
        const re = globToRegExp(pattern);
        const matches = res.stdout
          .split("\n")
          .map((l) => l.replace(/^\.\//, ""))
          .filter((l) => l !== "" && re.test(l))
          .sort()
          .slice(0, 100);
        if (matches.length === 0) return { content: `no matches for pattern ${pattern}` };
        return finish(sandbox, "fs_glob", ctx, matches.join("\n"));
      },
    ),

    // -- fs_grep ---------------------------------------------------------------------
    tool(
      "fs_grep",
      "Search file contents for a regex pattern in the workspace. Returns matching lines with file:line:content format.",
      {
        type: "object",
        properties: {
          pattern: { type: "string" },
          path: { type: "string", description: "Directory or file to search (default: workspace root)" },
          include: { type: "string", description: "Only search files whose path matches this glob" },
          context: { type: "integer", description: "Lines of context before/after each match (0-10)" },
        },
        required: ["pattern"],
      },
      async (args, ctx) => {
        const pattern = reqStr(args, "pattern");
        const include = optStr(args, "include");
        const contextLines = optInt(args, "context");
        const parts = ["grep", "-rn", "-E"];
        if (include) parts.push(`--include=${shq(include)}`);
        if (contextLines !== undefined) parts.push("-C", String(Math.min(10, Math.max(0, contextLines))));
        parts.push(shq(pattern), ".");
        const res = await sandbox.exec(ctx.userId, {
          cmd: parts.join(" "),
          cwd: optStr(args, "path") ?? ".",
          timeoutMs: TOOL_TIMEOUTS.fs_grep,
          callKey: ctx.callKey,
        });
        if (res.exitCode === 1) return { content: `no matches for ${pattern}` };
        let content = res.stdout;
        if (res.stderr !== "") content += `\n[stderr]\n${res.stderr}`;
        return finish(sandbox, "fs_grep", ctx, content, res.exitCode !== 0);
      },
    ),

    // -- job_start -----------------------------------------------------------------------
    tool(
      "job_start",
      "Start a background shell command (servers, watchers, installs). Returns an id immediately; poll with job_output, stop with job_kill.",
      {
        type: "object",
        properties: {
          command: { type: "string" },
          name: { type: "string", description: "Short label for the job (e.g. \"dev-server\")" },
        },
        required: ["command"],
      },
      async (args, ctx) => {
        const command = reqStr(args, "command");
        const { jobId } = await sandbox.jobStart(ctx.userId, { cmd: command });
        return finish(sandbox, "job_start", ctx, `job ${jobId} started: ${command}`);
      },
    ),

    // -- job_output ------------------------------------------------------------------------
    tool(
      "job_output",
      "Read the output of a background job, optionally from a byte offset (the returned endOffset round-trips as the next offset).",
      {
        type: "object",
        properties: {
          job_id: { type: "string" },
          offset: { type: "integer", description: "Byte offset to read from (default: start)" },
        },
        required: ["job_id"],
      },
      async (args, ctx) => {
        const jobId = reqStr(args, "job_id");
        const out = await sandbox.jobOutput(ctx.userId, jobId, {
          offset: optInt(args, "offset"),
        });
        const status = out.running ? "running" : out.exitCode !== null ? `exit ${out.exitCode}` : "killed";
        return finish(sandbox, "job_output", ctx, `${out.output}\n[job ${jobId} ${status}]`);
      },
    ),

    // -- job_list ---------------------------------------------------------------------------
    tool(
      "job_list",
      "List all background jobs with their status (running/stopped) and command.",
      { type: "object", properties: {} },
      async (_args, ctx) => {
        const jobs = await sandbox.jobList(ctx.userId);
        if (jobs.length === 0) return { content: "no background jobs" };
        const body = jobs
          .map((j) => `${j.jobId}\t${j.running ? "running" : "stopped"}\t${j.cmd}`)
          .join("\n");
        return finish(sandbox, "job_list", ctx, body);
      },
    ),

    // -- job_kill -----------------------------------------------------------------------------
    tool(
      "job_kill",
      "Stop a running background job by id.",
      {
        type: "object",
        properties: { job_id: { type: "string" } },
        required: ["job_id"],
      },
      async (args, ctx) => {
        const jobId = reqStr(args, "job_id");
        await sandbox.jobKill(ctx.userId, jobId);
        return finish(sandbox, "job_kill", ctx, `job ${jobId} killed`);
      },
    ),
  ];

  return tools;
}
