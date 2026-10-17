// Composer slash commands, server side (port of lib/core/commands.dart
// `CommandService.parse`/`execute` + the composer's user-skill invocation).
//
// Two kinds of result:
//   • `prompt` — a REWRITE: the command's text replaces the user prompt that
//     the model sees (skill invocation);
//   • `feedback` — an IMMEDIATE action: the run finishes with a
//     `message_completed` carrying this text and makes NO model call
//     (`/plan`, `/permission`, `/model`, `/compact`, `/todo`).
//
// Unknown `/name` returns null — the prompt goes to the model verbatim.
// Dart parity: unknown commands are NOT errors (`CommandService.execute`
// returns null when `find` misses).
//
// Dart commands that are on-device UI/state and have no cloud analogue are
// deleted-with-comment: /new, /clear, /export (device session store / ZIP),
// /feedback (device log), /preset's popup branch, /permission's
// confirmation/popup branches (the cloud approval gate is Task 12's) and the
// control-mode disclosure (D5).

import { presetById, type AgentPreset } from "./presets.js";
import type { SessionStateStore, SkillCatalog } from "./ports.js";
import type { SessionMode } from "./types.js";

export interface CommandResult {
  /** When set, this text is sent to the agent instead of the raw input. */
  prompt?: string;
  /** User-visible confirmation/error; feedback-only results finish the run. */
  feedback?: string;
  clearInput: boolean;
}

export type CommandRunner = (
  sessionId: string,
  input: string,
) => Promise<CommandResult | null>;

export interface CommandDeps {
  state: SessionStateStore;
  skills: SkillCatalog;
  /** The server's preset registry (`typeof presetById`). */
  presets: typeof presetById;
  /** Manual compaction (Task 19's Compactor; a no-op until then). */
  compact(sessionId: string): Promise<string>;
  /** Persist the access mode and return the user-facing confirmation. */
  setMode(sessionId: string, mode: SessionMode): Promise<string>;
}

/**
 * Parse a composer line. Null when the line is not a command.
 * Command grammar (Dart `CommandService.parse`): slash at byte 0, then
 * `[a-z0-9_-]+`; args are the raw remainder after the name, trimmed.
 * Quotes inside args are preserved for the handler.
 */
export function parseSlashCommand(
  input: string,
): { name: string; args: string } | null {
  if (!input.startsWith("/")) return null;
  const body = input.slice(1);
  const match = /^[a-z0-9_-]+/.exec(body);
  if (match === null) return null;
  const name = match[0];
  return { name, args: body.slice(name.length).trim() };
}

/**
 * [CC] slash-command argument substitution (exact Dart port):
 *   • `$ARGUMENTS` / `$@` → the full raw args string (untrimmed);
 *   • `$1`…`$N` → whitespace-split trimmed args (1-based, multi-digit);
 *   • an out-of-range positional is left AS-IS (never erased);
 *   • `\$` → a literal `$` (escape, no substitution).
 */
export function substituteCommandArguments(
  body: string,
  rawArgs: string,
): string {
  if (!body.includes("$")) return body;
  const trimmed = rawArgs.trim();
  const args = trimmed === "" ? [] : trimmed.split(/\s+/);
  let out = "";
  let i = 0;
  while (i < body.length) {
    const ch = body[i]!;
    if (ch === "\\" && i + 1 < body.length && body[i + 1] === "$") {
      out += "$";
      i += 2;
      continue;
    }
    if (ch === "$") {
      if (body.startsWith("$ARGUMENTS", i)) {
        out += rawArgs;
        i += "$ARGUMENTS".length;
        continue;
      }
      if (body.startsWith("$@", i)) {
        out += rawArgs;
        i += 2;
        continue;
      }
      const match = /^\$(\d+)/.exec(body.slice(i));
      if (match !== null) {
        const index = Number.parseInt(match[1]!, 10);
        if (index >= 1 && index <= args.length) {
          out += args[index - 1];
          i += match[0].length;
          continue;
        }
      }
    }
    out += ch;
    i += 1;
  }
  return out;
}

/** Dart `_hasCommandArgumentPlaceholders`, skipping `\$` escapes. */
function hasCommandArgumentPlaceholders(body: string): boolean {
  for (let i = 0; i < body.length; i += 1) {
    if (body[i] === "\\") {
      i += 1;
      continue;
    }
    if (body[i] !== "$") continue;
    const rest = body.slice(i + 1);
    if (rest.startsWith("ARGUMENTS") || rest.startsWith("@")) return true;
    if (rest.length > 0) {
      const c = rest.charCodeAt(0);
      if (c >= 0x30 && c <= 0x39) return true;
    }
  }
  return false;
}

/**
 * The legacy trailer appended when a command/skill body declares no argument
 * placeholders. Empty when the body substitutes its own placeholders or when
 * there are no arguments (Dart `commandArgumentTrailer`).
 */
export function commandArgumentTrailer(
  body: string,
  rawArgs: string,
  label: string,
): string {
  if (rawArgs === "" || hasCommandArgumentPlaceholders(body)) return "";
  return `\n\n${label}: ${rawArgs}`;
}

/** Dart `/permission` accepted names, including the on-device aliases. */
const MODE_ALIASES: Readonly<Record<string, SessionMode>> = {
  safe: "safe",
  "read-only": "safe",
  "read_only": "safe",
  auto: "auto",
  general: "auto",
  drive: "drive",
  "full-access": "drive",
  "full_access": "drive",
  studio: "studio",
};

const TODO_MARKS: Readonly<Record<string, string>> = {
  completed: "x",
  in_progress: "~",
  pending: " ",
};

/**
 * Build the server-side command runner. The seeded set is:
 *   /plan on|off|<message>   — preset toggle → pendingPlanMode
 *   /permission <mode>       — state.patch({mode})
 *   /model <id>              — state.patch({modelPin})
 *   /compact                 — deps.compact (manual compaction)
 *   /todo                    — render state.todos
 *   /<user-invocable skill>  — rewrite the prompt with the skill content
 * Everything else → null.
 */
export function createCommandRunner(deps: CommandDeps): CommandRunner {
  return async (sessionId, input) => {
    const parsed = parseSlashCommand(input);
    if (parsed === null) return null;
    const { name, args } = parsed;

    switch (name) {
      case "plan": {
        // The plan preset is the deployment's switch for this policy; if it
        // was removed, say so rather than silently flipping a state bit.
        if (deps.presets("plan") === null) {
          return {
            feedback: "Plan mode is not available in this deployment.",
            clearInput: true,
          };
        }
        const q = args.trim();
        if (q.toLowerCase() === "off") {
          await deps.state.patch(sessionId, { pendingPlanMode: false });
          return { feedback: "Plan mode off.", clearInput: true };
        }
        await deps.state.patch(sessionId, { pendingPlanMode: true });
        // Dart `/plan <message>`: enter plan mode AND send the message as the
        // prompt. A bare `/plan on` (or `/plan`) is feedback-only.
        if (q === "" || q.toLowerCase() === "on") {
          return { feedback: "Plan mode on.", clearInput: true };
        }
        return { prompt: q, feedback: "Plan mode on.", clearInput: true };
      }

      case "permission": {
        const q = args.trim().toLowerCase().replace(/_/g, "-");
        if (q === "") {
          const state = await deps.state.get(sessionId);
          return {
            feedback: `Permission mode: ${state.mode}`,
            clearInput: true,
          };
        }
        const mode = MODE_ALIASES[q];
        if (mode === undefined) {
          return {
            feedback:
              `Unknown permission "${q}". Options: ` +
              "safe, auto, drive, studio.",
            clearInput: true,
          };
        }
        return { feedback: await deps.setMode(sessionId, mode), clearInput: true };
      }

      case "model": {
        const id = args.trim();
        if (id === "") {
          const state = await deps.state.get(sessionId);
          return {
            feedback:
              state.modelPin === null
                ? "No model pinned — using the session default."
                : `Model: ${state.modelPin}`,
            clearInput: true,
          };
        }
        // Ruling R4: the pin is session state; Task 15's resolveRoute reads it
        // on the NEXT run (precedence: preset pin > modelPin).
        await deps.state.patch(sessionId, { modelPin: id });
        return { feedback: `Model → ${id}`, clearInput: true };
      }

      case "compact": {
        // Dart's /compact is idle-only and returns an HONEST status line.
        // The cloud compactor (Task 19) owns the status; until then the
        // no-op reports that nothing changed.
        const status = await deps.compact(sessionId);
        return { feedback: status, clearInput: true };
      }

      case "todo": {
        const state = await deps.state.get(sessionId);
        if (state.todos.length === 0) {
          return { feedback: "No todos.", clearInput: true };
        }
        const lines = state.todos.map(
          (t) => `- [${TODO_MARKS[t.status] ?? " "}] ${t.content}`,
        );
        return { feedback: lines.join("\n"), clearInput: true };
      }

      default: {
        // User-invocable skill: `/<skill-name> [args]` rewrites the prompt
        // with the skill body (Dart composer `parseSkillInvocation` path).
        // Built-ins win over same-named skills (the switch above).
        const summaries = await deps.skills.list(sessionId);
        const match = summaries.find(
          (s) => s.userInvocable && s.name.toLowerCase() === name.toLowerCase(),
        );
        if (match === undefined) return null;
        const skill = await deps.skills.load(match.name, sessionId);
        if (skill === null) return null;
        const content = substituteCommandArguments(skill.content, args);
        const trailer = commandArgumentTrailer(
          skill.content,
          args,
          "User instruction",
        );
        return {
          prompt: `<skill_content>\n${content}\n</skill_content>${trailer}`,
          clearInput: true,
        };
      }
    }
  };
}

/**
 * The engine hook point: run the command pre-pass BEFORE the loop when the
 * prompt starts with `/`.
 *
 * - `rewrite` → replace the prompt handed to the loop;
 * - `finish`  → emit `message_completed` with the feedback and complete the
 *   run WITHOUT a model call;
 * - `none`    → the raw prompt goes to the model verbatim.
 *
 * Exported as a pure decision so `engine.run` can wire it in one call; the
 * engine (Task 15) owns the event/run-row writes.
 */
export type CommandPrePass =
  | { kind: "none" }
  | { kind: "rewrite"; prompt: string }
  | { kind: "finish"; feedback: string };

export async function commandPrePass(
  run: CommandRunner,
  sessionId: string,
  input: string,
): Promise<CommandPrePass> {
  const result = await run(sessionId, input);
  if (result === null) return { kind: "none" };
  if (result.prompt !== undefined) {
    return { kind: "rewrite", prompt: result.prompt };
  }
  return { kind: "finish", feedback: result.feedback ?? "" };
}

/** Re-exported so callers can type a preset registry without importing presets. */
export type CommandPreset = AgentPreset;
