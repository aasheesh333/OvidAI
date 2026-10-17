import { REFUSAL_MESSAGE } from "@ovid/sandbox";

/**
 * Pinned v1 loop constants (plan Task 12). The caps are named "_BYTES" but
 * enforced on string length (UTF-16 units) — output text here is ASCII-dominant
 * and the difference only ever rounds DOWN for multi-byte content, which is the
 * safe direction for every consumer.
 */

/** Hard cap on streaming tool-call rounds before tool_rounds_exhausted. */
export const MAX_TOOL_ROUNDS = 50;

/** run_shell result content cap ("[truncated]" suffix). */
export const TOOL_RESULT_CAP_BYTES = 32_768;

/** tool_completed event payload content cap. */
export const TOOL_EVENT_CONTENT_CAP = 8_192;

/** read_file content cap. */
export const READ_FILE_CAP_BYTES = 256 * 1024;

/** read_file/grep_files binary sniff window (NUL inside it → binary). */
export const BINARY_SNIFF_BYTES = 8 * 1024;

/** glob_files result entry cap ("[truncated]" line appended beyond it). */
export const GLOB_MAX_ENTRIES = 1_000;

/** grep_files per-line text cap. */
export const GREP_LINE_CAP = 500;

/** grep_files default and maximum result count. */
export const GREP_MAX_RESULTS_DEFAULT = 200;
export const GREP_MAX_RESULTS_MAX = 1_000;

/** grep_files file size ceiling — larger files are skipped. */
export const GREP_FILE_MAX_BYTES = 1024 * 1024;

/**
 * Slices `text` to `cap` (inclusive) appending the "[truncated]" marker so the
 * result never exceeds the cap. Use for single-string caps (read_file,
 * run_shell); list-shaped tools append their own marker line instead.
 */
export function capWithSuffix(text: string, cap: number): string {
  if (text.length <= cap) return text;
  return `${text.slice(0, cap - 12)}\n[truncated]`;
}

/**
 * The v1 agent identity (plan Task 12): identity, the /workspace jail facts,
 * the heavy-compilation refusal notice (verbatim, one source of truth with the
 * policy layer), and one line per roster tool. Constant text — the prefix is
 * prompt-cache-stable across runs (spec §6.1).
 */
export const SYSTEM_PROMPT_V1: string = [
  "You are Ovid, a helpful cloud coding agent. You answer, write code, and run commands for the user.",
  "Commands run in an isolated Linux workspace at /workspace (ubuntu noble; node/python/git/pnpm/uv preinstalled). Files persist in that workspace across the conversation.",
  `Tooling constraint: ${REFUSAL_MESSAGE}`,
  "Tools:",
  "- run_shell: run a shell command in the workspace (bash). Returns stdout, stderr and the exit code; timeoutMs defaults to 120000 and clamps to 600000.",
  "- read_file: read a UTF-8 text file from the workspace (up to 256 KiB).",
  "- write_file: write a file in the workspace, creating parent directories as needed.",
  "- edit_file: replace an exact string in a file (oldString must match exactly once unless replaceAll is true).",
  "- glob_files: list workspace files matching a glob pattern (**, *, ?, {a,b}).",
  "- grep_files: search workspace file contents with a regular expression.",
].join("\n");
