// System-prompt assembly (port of the Dart `_runTaskBody` prompt halves:
// `sysTemplate` / `buildSys` / `_volatileContextBlock`, agent_service.dart
// ~11762–12148, plus `lib/core/plan_mode.dart` `promptSection`).
//
// THE CONTRACT (Review Focus #3): the stable block is a PURE function of its
// inputs — same inputs ⇒ byte-identical bytes. No timestamps, no counters, no
// environment sniffing. Everything that changes turn to turn (workspace tree,
// todos, goal, subagent briefing) rides in `volatile`, which the caller appends
// LAST as a separate trailing message (`${stable}\n\n${volatile}` for the
// snapshot — Dart `systemPromptSnapshot` parity) and which is NEVER
// cache-marked (Task 3's `markCacheBreakpoints` skips `volatile: true` rows).
//
// D5 (binding): every device / Control-mode reference from the Dart prompt is
// gone — the cloud agent has no `device_*` tools and no Control mode. Pinned by
// the test asserting `/device_|Control mode/i` never matches.

import type { SessionGoal, SkillSummary, TodoItem } from "./ports.js";
import type { SessionMode } from "./types.js";

export interface SystemPromptInput {
  mode: SessionMode;
  planMode: boolean;
  isSubagent: boolean;
  persona: string; // preset persona preamble ("" when none) — rides ABOVE the base
  workspaceFolder: string;
  workspaceTreeSummary: string; // tree summary is volatile
  skillsCatalog: readonly SkillSummary[]; // compact catalog lines (Task 17 fills; [] until then)
  memoryContext: string; // pre-rendered MEMORY.md context block (Task 13; "" until then)
  todos: readonly TodoItem[]; // volatile session state
  goal: SessionGoal | null; // volatile session state
  subagentBriefing?: string; // parent's dispatch prompt for a child (Task 20)
}

export interface SystemPromptParts {
  stable: string;
  volatile: string;
}

// ── base identity (Dart sysTemplate port, cloud-scoped, D5-scrubbed) ────────

const BASE_IDENTITY = `You are Ovid's cloud coding & browsing agent running on the Ovid Cloud runtime.
Environment: a session-isolated Linux sandbox workspace (python3/node/git), web
fetch and search tools, and the user's connected GitHub repo.
Session isolation: this chat has its OWN sandbox workspace. Other chats' files
are NOT visible to you — don't ask about them, they're
inaccessible here.
ACCESS CONTROL: file and network access outside the workspace needs the user's
grant. A tool result starting with ACCESS_DENIED means the user refused (or the
request timed out unanswered) — it is FINAL for that target. Do NOT retry the
same path or host, and do NOT route around the denial (no symlinks, no copies
via other tools, no shell tricks to reach the same data). Explain briefly why
you needed that path or host, then ask the user what to do next — e.g. offer to
do the work inside the workspace instead. Only the user can grant it, via the
approval card (Allow once / Deny / Always allow).

RESPONSE STYLE (default): Be concise and lightweight, like a fast coding assistant.
Lead with the answer or result. Skip long preambles, restating the question, or
filler. Use short bullet points or code blocks only when they help. Reply in the
same language the user writes in (default English). Only give long explanations,
step-by-step reasoning, or extra detail when the user explicitly asks for it or
the task truly requires it. When a task needs commands, pages or file changes,
CALL THE TOOLS instead of describing them. Prefer many small steps. Verify
results before finishing.
NEVER fake work: do not emit placeholder echo commands (e.g. \`echo "Command N executed"\`)
and claim tasks ran. If a sandbox command fails, show its ACTUAL error + fix it
(or report it to the user honestly) instead of simulating the work.
RESULT FORMAT CONTRACT (main chat): your final message is what the user SEES —
it must stand alone. Lead with the answer or result in the FIRST line. Present
results as a visible markdown block (short bullets, code fences, or a small
table). Never bury the result inside reasoning or tool narration: thinking stays
in the thinking lane, and the final message must make sense without it. After
running tools, end with the concrete outcome (what changed, where it lives, the
key numbers) — not a play-by-play of the steps.
SHELL COMMAND HYGIENE:
• Always use valid bash syntax. If executing multiple commands, ALWAYS separate them with \`;\` or \`&&\` (never concatenate without a delimiter, e.g. never \`2>&1 ls\`).
• When using pipelines with \`head\` or \`tail\` (e.g. \`| head -5\`), do NOT append trailing command names directly without a semicolon.`;

// ── mode section (Dart AgentModeX label/hint port — device & control gone) ──

interface ModeInfo {
  label: string;
  hint: string;
  extra?: string;
}

const MODE_INFO: Record<SessionMode, ModeInfo> = {
  // Dart: 'Read-Only' / 'Read-only. Asks for permission before every shell,
  // browser, or write action.' + the sysTemplate MODE RESTRICTIONS block
  // (catalog/plugin entries dropped with the cloud roster).
  safe: {
    label: "Read-Only",
    hint: "Read-only. Asks for permission before every shell, browser, or write action.",
    extra: `MODE RESTRICTIONS (Read-Only): you are in a read-only session. You may read
files, list directories and search freely. EVERY shell command, code run, job,
browser action, network fetch and write (file_write, fs_edit
create/str_replace/insert, commit, git_clone, git_push, git_pull, job_start,
job_kill, browser typing/clicking) asks the user for permission first, and
fails if they decline. In a scheduled run nobody can approve, so writes are
HARD-BLOCKED there. Prefer reading; ask for a write only when it is clearly
needed, and if declined explain what needs to change.`,
  },
  // Dart: 'General' / 'Runs shell and browser freely. Asks before pushing to
  // the repo.' — cloud wording: workspace-confined, approvals outside.
  auto: {
    label: "General",
    hint: "Runs shell and browser freely. Asks before pushing to the repo.",
    extra: `GENERAL MODE: shell and browser run freely inside the session workspace;
file and network access OUTSIDE the workspace needs the user's approval via
the approval card. Pushing to the repo always asks first.`,
  },
  // Dart: 'Full Access' / 'Full autonomous — kuch bhi, kahin bhi, no
  // confirmation.'
  drive: {
    label: "Full Access",
    hint: "Full autonomous — kuch bhi, kahin bhi, no confirmation.",
    extra: `FULL ACCESS MODE: no confirmation prompts — autonomous file, shell, network
and repo access. Destructive commands and pushes to the repo still ask.`,
  },
  // Dart: 'Studio' / 'Studio mode — files edit, terminal run, repo access
  // free. Asks for a confirmation before publishing or committing.'
  studio: {
    label: "Studio",
    hint: "Studio mode — files edit, terminal run, repo access free. Asks for a confirmation before publishing or committing.",
    extra: `STUDIO MODE: workspace AND the connected GitHub repo — file edits, terminal
and repo access are free. Publishing or committing still asks for confirmation.`,
  },
};

/** The per-mode description block (Dart `Access mode: LABEL — hint` + extras). */
export function modeSection(mode: SessionMode): string {
  const info = MODE_INFO[mode];
  return `Access mode: ${info.label.toUpperCase()} — ${info.hint}${
    info.extra ? `\n${info.extra}` : ""
  }`;
}

// ── plan briefing (exact port of plan_mode.dart promptSection) ──────────────

/**
 * The read-only research-phase briefing injected while plan mode is active
 * (Dart `PlanModePolicy.promptSection`, placeholders pre-resolved: the pinned
 * TS signature takes only `planMode`, so the root falls back to the generic
 * `pwd` wording and the scope sentence to the session-workspace default —
 * a literal `{PLAN_ROOT}` must never survive into a prompt). Empty string
 * when plan mode is off, so the G2 turn-boundary swap is a clean splice.
 *
 * D5 deviation: Dart's "Do not use file_write, fs_edit, commit, or any
 * device_* tool" drops the device clause — the cloud has no device tools.
 */
export function planBriefing(planMode: boolean): string {
  if (!planMode) return "";
  return `PLAN MODE — READ-ONLY RESEARCH PHASE (opencode plan-agent parity):
You are the PLAN agent. Your job is to RESEARCH and PROPOSE, not to change
anything.
WORKING DIRECTORY: this session's workspace (run \`pwd\` to resolve it)
This is the session-isolated workspace for this chat — other sessions' folders
are not yours to read.
Paths outside it are refused outright — no card, no retry — in
EVERY access mode, Full Access and Studio included. Use relative paths inside
the working directory for all research. If the answer genuinely lives outside
it, write that into the plan as a step for the user to approve instead of
reaching for the path.
Investigate the working directory thoroughly before you propose:
read files, glob and grep, inspect git history and diffs, and run read-only
shell commands (ls, cat, find, wc, tree, git log/diff/status, \`sed -n\`).
CRITICAL: you are in the READ-ONLY phase. Do NOT use shell commands that
modify anything — no redirects into files (\`>\`, \`>>\`), no \`tee\`, \`sed -i\`,
\`mv\`, \`rm\`, \`mkdir\`, \`touch\`, no \`git add/commit/checkout\`, no installs.
Do not use file_write, fs_edit, or commit. If something
looks like it needs a change, write the change down instead of making it.
The plan is NOT a card and NOT a tool argument: write it out as a normal
message — a numbered list of concrete steps naming the exact files and
commands involved — and only THEN call exit_plan_mode, which asks the user
one yes/no question: switch to the build agent and start implementing?
Keep the plan tight and grounded in what you actually read.
You are NEVER asked for a permission while planning: read-only shell commands
run silently, and every mutating call is refused outright with the reason —
so do not "try it and see" (a denied write/delete/install costs a turn and
changes nothing). If a step needs a change, write the change down.`;
}

// ── skills catalog (Dart _catalogBlock port, skills.dart) ───────────────────

const MAX_SKILL_DESC_CHARS = 500;

function skillsCatalogBlock(skills: readonly SkillSummary[]): string {
  const modelSkills = skills.filter((s) => s.modelInvocable);
  if (modelSkills.length === 0) return "";
  const lines = [
    "AVAILABLE SKILLS (call the `skill` tool with a name to load full instructions):",
  ];
  for (const skill of modelSkills) {
    const desc =
      skill.description.length > MAX_SKILL_DESC_CHARS
        ? `${skill.description.slice(0, MAX_SKILL_DESC_CHARS)}…`
        : skill.description;
    lines.push(
      `- \`${skill.name}\`: ${desc}${
        skill.whenToUse === "" ? "" : ` — ${skill.whenToUse}`
      }`,
    );
  }
  return lines.join("\n");
}

// ── workspace block (Dart workspaceContext port) ────────────────────────────

function workspaceBlock(workspaceFolder: string): string {
  const folder = workspaceFolder.trim();
  const current = folder === ""
    ? "this session's workspace (run `pwd` to resolve it)"
    : folder;
  return `All file work uses the current workspace described below.
Current workspace: ${current}
Use this existing workspace for file and shell tools; do not clone again to begin working.`;
}

// ── volatile block (Dart _volatileContextBlock port, tree added first) ──────

function volatileBlock(i: SystemPromptInput): string {
  const parts: string[] = [];

  const tree = i.workspaceTreeSummary.trim();
  if (tree !== "") parts.push(`WORKSPACE TREE:\n${tree}`);

  if (i.todos.length > 0) {
    const n = i.todos.length;
    const lines = [
      `SESSION TODOS (${n} item${n === 1 ? "" : "s"} — follow this checklist, do not abandon it):`,
    ];
    for (const t of i.todos) {
      const mark =
        t.status === "completed"
          ? "x"
          : t.status === "in_progress"
            ? "~"
            : " ";
      lines.push(`- [${mark}] ${t.content}`);
    }
    lines.push(
      "Work through the todo list. Mark items in_progress BEFORE doing them and completed AFTER they are done. If all items are completed, say so and give your final answer.",
    );
    parts.push(lines.join("\n"));
  }

  if (i.goal) {
    const goalLines = [
      `ACTIVE GOAL: "${i.goal.objective}". Work toward the objective, then update_goal with progress. Do not restate the goal; just advance it.`,
    ];
    const notes = i.goal.notes.trim();
    if (notes !== "") goalLines.push(`Goal notes: ${notes}`);
    parts.push(goalLines.join("\n"));
  }

  const briefing = (i.subagentBriefing ?? "").trim();
  if (briefing !== "") {
    parts.push(
      `SUBAGENT BRIEFING (your parent agent dispatched you with this task — work only from it):\n${briefing}`,
    );
  }

  return parts.join("\n\n");
}

// ── assembly ────────────────────────────────────────────────────────────────

/**
 * Assembles the system prompt in two halves:
 *
 * - `stable` = persona + base identity + mode section + plan briefing
 *   (planMode only) + skills catalog + memory context + workspace folder —
 *   byte-identical for identical inputs; the cacheable prefix.
 * - `volatile` = workspace tree + todos + goal + subagent briefing — rendered
 *   LAST, appended as `${stable}\n\n${volatile}` for the snapshot (Dart
 *   systemPromptSnapshot parity) but kept SEPARATE so Task 3's
 *   markCacheBreakpoints never marks it (the caller tags it volatile:true).
 *
 * `isSubagent` alone changes nothing: without a `subagentBriefing` there is
 * no subagent-specific text (the briefing IS the subagent prompt, Task 20).
 */
export function buildSystemPrompt(i: SystemPromptInput): SystemPromptParts {
  const sections: string[] = [];

  const persona = i.persona.trim();
  if (persona !== "") sections.push(`PERSONA: ${persona}`);

  sections.push(BASE_IDENTITY);
  sections.push(modeSection(i.mode));

  const plan = planBriefing(i.planMode);
  if (plan !== "") sections.push(plan);

  const skills = skillsCatalogBlock(i.skillsCatalog);
  if (skills !== "") sections.push(skills);

  const memory = i.memoryContext.trim();
  if (memory !== "") sections.push(memory);

  sections.push(workspaceBlock(i.workspaceFolder));

  return { stable: sections.join("\n\n"), volatile: volatileBlock(i) };
}
