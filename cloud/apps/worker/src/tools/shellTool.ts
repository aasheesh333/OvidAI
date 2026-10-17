import { checkCommandPolicy, REFUSAL_MESSAGE, type ExecResult } from "@ovid/sandbox";
import { z } from "zod";
import { TOOL_RESULT_CAP_BYTES, capWithSuffix } from "./systemPrompt.js";
import { invalidInput, type AgentTool, type ToolContext, type ToolResult } from "./types.js";

/**
 * run_shell (plan Task 12, spec §7): the model's shell access into the sandbox.
 *
 * Layer-1 policy runs HERE, before the sandbox exec: a blocked command must
 * have ZERO side effects (no jail spawn, no leaf cgroup — and the stub-sandbox
 * tests pin that exec is never invoked). The execOnce inside @ovid/sandbox
 * re-runs the same check (belt) for callers that bypass this tool.
 *
 * Blocked ⇒ BOTH a `system_note` event {code:"command_blocked"} AND the tool
 * result {content: REFUSAL_MESSAGE, isError: true} (spec §7: the refusal is the
 * tool result + a user-visible note).
 *
 * Content = stdout + "\n[stderr]\n…" (when non-empty) + "\n[exit <code>]",
 * capped at TOOL_RESULT_CAP_BYTES; isError = exitCode !== 0 || timedOut.
 */

const RUN_SHELL_TIMEOUT_DEFAULT_MS = 120_000;
const RUN_SHELL_TIMEOUT_MAX_MS = 600_000;

const inputSchema = z.object({
  command: z.string().min(1),
  timeoutMs: z.number().int().positive().optional(),
});

function formatShellResult(res: ExecResult): ToolResult {
  let content = res.stdout;
  if (res.stderr !== "") content += `\n[stderr]\n${res.stderr}`;
  content += `\n[exit ${res.exitCode === null ? "null" : res.exitCode}]`;
  return {
    content: capWithSuffix(content, TOOL_RESULT_CAP_BYTES),
    isError: res.exitCode !== 0 || res.timedOut,
  };
}

/** Emits the pinned command_blocked note and returns the pinned refusal result. */
async function blockedResult(command: string, ctx: ToolContext): Promise<ToolResult> {
  await ctx.emitEvent("system_note", {
    code: "command_blocked",
    message: REFUSAL_MESSAGE,
    command,
  });
  return { content: REFUSAL_MESSAGE, isError: true };
}

export function createRunShellTool(): AgentTool {
  return {
    name: "run_shell",
    description:
      "Run a shell command in the workspace (bash). Returns stdout, stderr and the exit code. timeoutMs defaults to 120000 and clamps to 600000.",
    parameters: {
      type: "object",
      properties: {
        command: { type: "string", description: "The shell command to run." },
        timeoutMs: {
          type: "integer",
          description: "Timeout in milliseconds (default 120000, max 600000).",
          minimum: 1,
        },
      },
      required: ["command"],
    },
    async execute(input, ctx): Promise<ToolResult> {
      const parsed = inputSchema.safeParse(input);
      if (!parsed.success) return invalidInput(parsed.error);

      const { command } = parsed.data;
      // Layer 1 (client-side pre-parse): blocked ⇒ zero side effects.
      const verdict = checkCommandPolicy(command);
      if (!verdict.allowed) return blockedResult(command, ctx);

      const timeoutMs = Math.min(
        parsed.data.timeoutMs ?? RUN_SHELL_TIMEOUT_DEFAULT_MS,
        RUN_SHELL_TIMEOUT_MAX_MS,
      );
      const res = await ctx.sandbox.exec({ command, timeoutMs });
      // execOnce re-checks the policy (argv-form normalization) — honor a
      // blocked verdict from that side identically.
      if (res.blocked) return blockedResult(command, ctx);
      return formatShellResult(res);
    },
  };
}
