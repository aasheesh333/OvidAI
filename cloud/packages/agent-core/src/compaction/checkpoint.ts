// Checkpoint rendering + summarizer prompts — a port of
// lib/core/compaction/compaction_checkpoint.dart.
//
// Everything deterministic here comes from the transcript (via the ledger).
// The model writes ONLY the narrative sections (Decisions / Current Work /
// Next Steps / Key Context). Rendering is pure: identical inputs produce
// byte-identical output (no timestamps, no I/O, no provider calls).
//
// Cloud divergence (plan pin, binding): Dart replays the checkpoint as a
// USER-role row (agent_service.dart:10843-10849); the plan replays it as a
// SYSTEM row marked stable so it joins the cached prefix. The preamble text
// itself is kept byte-identical to Dart.

import type { SessionGoal, TodoItem } from "../ports.js";
import type { CompactionLedger } from "./ledger.js";
import { checkpointBudgetTokens } from "./policy.js";

/** Live session state snapshotted into the checkpoint's "Current state". */
export interface CheckpointState {
  todos: readonly TodoItem[];
  goal: SessionGoal | null;
  planMode: boolean;
  workingFolder: string | null;
  retainedMessages: number;
}

/** A rendered checkpoint and what it preserved. */
export interface Checkpoint {
  text: string;
  verbatimUsers: number;
  digestedUsers: number;
  files: number;
  actions: number;
  narrativeAvailable: boolean;
  /** One line for the compaction row's collapsed state (Dart parity). */
  preservedLine: string;
}

export const COMPACTED_SUMMARY_TAGS = {
  open: "<compacted-summary>",
  close: "</compacted-summary>",
} as const;

/**
 * The replay block. Byte-identical preamble to Dart; the plan pins this as a
 * SYSTEM row (Dart uses role:"user"), so the caller wraps it accordingly.
 */
export function compactedSystemBlock(summary: string): string {
  return (
    "This is an automatically generated checkpoint condensing an earlier " +
    "span of the conversation to free up context. Treat the captured " +
    "context as established background and build on it without restating " +
    "it. Continue the task directly from the messages that follow, without " +
    "acknowledging this checkpoint.\n\n" +
    `${COMPACTED_SUMMARY_TAGS.open}\n${summary}\n${COMPACTED_SUMMARY_TAGS.close}`
  );
}

export const NARRATIVE_SECTIONS = [
  "## Decisions",
  "## Current Work",
  "## Next Steps",
  "## Key Context",
] as const;

/** Dart `summarizerSystemPrompt` — exact text. */
export function summarizerSystemPrompt(o: { strict?: boolean } = {}): string {
  return (
    "You are the compaction engine for an AI coding agent. Another part of " +
    "the system ALREADY preserves, deterministically and verbatim: every " +
    "user message, the original goal, every file touched, every command " +
    "and tool call with its outcome, every error, and the todo list. " +
    "Do NOT restate those lists. Write only the NARRATIVE another model " +
    "needs to resume the work.\n" +
    "\n" +
    "Output EXACTLY these Markdown sections, in order, as terse bullets. " +
    'Write "(none)" for an empty section:\n' +
    "\n" +
    "## Decisions\n" +
    "- [decision: why it was made, including approaches rejected]\n" +
    "\n" +
    "## Current Work\n" +
    "- [precisely what was in progress at this point]\n" +
    "\n" +
    "## Next Steps\n" +
    "- [the next actions, in line with the most recent user request; " +
    "open questions for the user]\n" +
    "\n" +
    "## Key Context\n" +
    "- [technical concepts, conventions, root causes found, data needed " +
    "to continue that is not a raw list]\n" +
    "\n" +
    "Rules:\n" +
    "- Preserve exact file paths, commands, identifiers, error strings and " +
    "numbers.\n" +
    "- If the user corrected the agent, record the corrected understanding.\n" +
    "- If a PRIOR NARRATIVE is given, MERGE it: keep still-true decisions " +
    "and context, update Current Work and Next Steps, drop only what is " +
    "clearly superseded. Never shorten it into vagueness.\n" +
    "- If a FOCUS is given by the user, prioritise it.\n" +
    "- Do not mention summarisation or compaction. Do not call tools." +
    (o.strict === true
      ? "\n\nSTRICTNESS: the previous attempt was longer than its source — halve the length."
      : "")
  );
}

/** Dart `summarizerUserPrompt` — exact text. */
export function summarizerUserPrompt(o: {
  replay: string;
  priorNarrative: string;
  ledger: CompactionLedger;
  focus?: string;
}): string {
  const parts: string[] = [];
  const f = (o.focus ?? "").trim();
  if (f.length > 0) parts.push(`FOCUS (from the user): ${f}\n`);
  const prior = o.priorNarrative.trim();
  if (prior.length > 0) {
    parts.push(`PRIOR NARRATIVE (merge into it):\n${prior}\n`);
  }
  if (o.ledger.goal !== null) {
    parts.push(`Original goal: ${clip(o.ledger.goal, 600)}`);
  }
  if (o.ledger.files.size > 0) {
    const paths = [...o.ledger.files.keys()].slice(0, 60).join(", ");
    parts.push(
      `Files touched: ${paths}${o.ledger.files.size > 60 ? " …" : ""}`,
    );
  }
  parts.push(`\nConversation span to condense:\n\n${o.replay}`);
  return parts.join("\n");
}

// ── rendering ──────────────────────────────────────────────────────────────

const CUE = new RegExp(
  "\\b(must|never|always|don'?t|do not|doesn'?t|only|should|shouldn'?t|" +
    "prefer|instead|actually|wrong|incorrect|avoid|make sure|ensure|" +
    "remember|no longer|stop|keep|use|not|need|required?|important|" +
    "constraint|rule|please|without|except|correction|rather)\\b",
  "i",
);
const URL_RE = /https?:\/\/[^\s)>\]]+/g;
const PATH_RE =
  /(?<![\w/])(?:~|\.{1,2})?\/?(?:[\w.\-]+\/)+[\w.\-]+\.\w{1,8}\b|(?<![\w/.])[\w\-]+\.(?:dart|py|js|ts|tsx|jsx|json|ya?ml|md|txt|sh|kt|java|swift|go|rs|c|cc|cpp|h|html|css|toml|lock|gradle|xml|csv|sql)\b/g;

function clip(s: string, max: number): string {
  return s.length <= max ? s : `${s.slice(0, max - 1)}…`;
}

function indent(s: string): string {
  return s.replace(/\n/g, "\n    ");
}

function splitNarrative(narrative: string): Map<string, string> {
  const out = new Map<string, string>();
  let head: string | null = null;
  let buf: string[] = [];
  const flush = (): void => {
    const body = buf.join("\n").trim();
    if (body.length > 0 || head !== null) {
      const key = head ?? "";
      const prev = out.get(key);
      out.set(key, [prev ?? "", body].filter((x) => x.length > 0).join("\n"));
    }
    buf = [];
  };
  for (const line of narrative.split("\n")) {
    const m = /^#{1,3}\s+(.+)$/.exec(line.trim());
    if (m !== null) {
      flush();
      head = m[1]!.trim();
    } else buf.push(line);
  }
  flush();
  return out;
}

/**
 * Faithful digest of an older user message: first sentence, every
 * directive/correction sentence VERBATIM, fact-like sentences (numbers,
 * key: value), referenced paths and URLs, and pasted code as a reference.
 */
export function digest(text: string): string {
  if (text.length <= 160) return text;
  const sentences = text
    .split(/(?<=[.!?])\s+|\n+/)
    .map((x) => x.trim())
    .filter((x) => x.length > 0 && !x.startsWith("```"));
  const kept: string[] = [];
  if (sentences.length > 0) kept.push(clip(sentences[0]!, 240));
  for (const x of sentences.slice(1)) {
    if (kept.includes(x)) continue;
    if (CUE.test(x)) kept.push(clip(x, 600));
    else if (/\d|\w[:=]\s*\S/.test(x) && x.length <= 200) kept.push(x);
  }
  const refs = new Set<string>();
  for (const m of text.matchAll(URL_RE)) refs.add(m[0]);
  for (const m of text.matchAll(PATH_RE)) refs.add(m[0]);
  const fences = Math.floor((text.match(/```/g) ?? []).length / 2);
  const out: string[] = [kept.join(" ")];
  if (fences > 0) {
    out.push(`[pasted ${fences} code block${fences === 1 ? "" : "s"}]`);
  }
  if (refs.size > 0) out.push(`refs: ${[...refs].slice(0, 20).join(", ")}`);
  return out.join(" · ");
}

/**
 * Render the checkpoint. `narrative` is the model's narrative; when null the
 * ledger's carried narrative is used (a failed summarizer keeps the previous
 * one). Deterministic for identical inputs.
 */
export function renderCheckpoint(
  ledger: CompactionLedger,
  narrative: string | null,
  state: CheckpointState,
  opts: {
    budgetTokens?: number;
    currentFocus?: string;
    narrativeAvailable?: boolean;
  } = {},
): string {
  return renderCheckpointDetailed(ledger, narrative, state, opts).text;
}

export function renderCheckpointDetailed(
  ledger: CompactionLedger,
  narrative: string | null,
  state: CheckpointState,
  opts: {
    budgetTokens?: number;
    currentFocus?: string;
    narrativeAvailable?: boolean;
  } = {},
): Checkpoint {
  const l = ledger;
  const budget = (opts.budgetTokens ?? checkpointBudgetTokens(100_000)) * 4;
  const currentFocus = opts.currentFocus ?? "";
  const narrativeText = (narrative ?? l.narrative ?? "").trim();
  const narrativeAvailable =
    opts.narrativeAvailable ?? narrativeText.length > 0;
  const lines: string[] = [];

  lines.push("# Session checkpoint");
  lines.push(
    `Compaction #${l.compactions} · ${l.foldedMessages} earlier ` +
      `message${l.foldedMessages === 1 ? "" : "s"} folded (the originals ` +
      "remain in the user's visible transcript). Goal, user instructions, " +
      "files, actions, errors and todos below were derived directly from " +
      "the transcript and are authoritative; Decisions / Current work / " +
      "Next steps / Context are the model's narrative.",
  );
  lines.push("");

  // Goal.
  lines.push("## Goal (original request, verbatim)");
  lines.push(l.goal ?? "(none)");
  lines.push("");

  // User instructions & constraints.
  const users = l.userMessages.filter(
    (u) => !(u.text === l.goal && u.seq === 1),
  );
  const userBudget = Math.floor(budget * 0.45);
  const total = users.reduce((a, u) => a + u.text.length + 12, 0);
  const verbatim = new Set<number>();
  if (total <= userBudget) {
    for (const u of users) verbatim.add(u.seq);
  } else {
    let used = 0;
    for (let i = users.length - 1; i >= 0; i -= 1) {
      const u = users[i]!;
      const recent = users.length - i <= 3;
      if (recent || used + u.text.length <= userBudget * 0.6) {
        verbatim.add(u.seq);
        used += u.text.length;
      } else break;
    }
  }
  const farOver = total > userBudget * 2;
  let digested = 0;
  lines.push("## User instructions & constraints (verbatim, chronological)");
  lines.push(
    '(numbered in order; "digest" rows keep every instruction sentence ' +
      "verbatim — their full text stays in the visible transcript)",
  );
  if (users.length === 0) lines.push("(no further user messages)");
  for (const u of users) {
    const atts =
      u.attachments === undefined || u.attachments.length === 0
        ? ""
        : `\n    [attached: ${u.attachments.join(", ")}]`;
    const keep =
      verbatim.has(u.seq) || (u.text.length <= 280 && !farOver);
    const d = keep ? u.text : digest(u.text);
    if (d === u.text) lines.push(`[#${u.seq}] ${indent(u.text)}${atts}`);
    else {
      digested += 1;
      lines.push(`[#${u.seq} · digest] ${indent(d)}${atts}`);
    }
  }
  lines.push("");

  // Facts & data the user provided.
  const facts: string[] = [];
  for (const u of l.userMessages) {
    for (const a of u.attachments ?? []) {
      facts.push(`#${u.seq} attachment: ${a}`);
    }
    const fences = Math.floor((u.text.match(/```/g) ?? []).length / 2);
    if (fences > 0) {
      facts.push(
        `#${u.seq} pasted ${fences} code block${fences === 1 ? "" : "s"}`,
      );
    }
    if (u.fullLength > u.text.length) {
      facts.push(`#${u.seq} pasted ${u.fullLength} chars (long paste)`);
    }
    const refs = new Set<string>();
    for (const m of u.text.matchAll(URL_RE)) refs.add(m[0]);
    for (const m of u.text.matchAll(PATH_RE)) refs.add(m[0]);
    if (refs.size > 0) facts.push(`#${u.seq} refs: ${[...refs].join(", ")}`);
  }
  lines.push("## Facts & data the user provided");
  if (facts.length === 0) lines.push("(none beyond the messages above)");
  for (const f of facts.length > 120 ? facts.slice(facts.length - 120) : facts) {
    lines.push(`- ${f}`);
  }
  if (facts.length > 120) {
    lines.push(`- (+${facts.length - 120} earlier references — see messages)`);
  }
  lines.push("");

  // Files & artifacts: every created/edited/deleted path, always.
  const withOp = (op: string): string[] => {
    const out: string[] = [];
    for (const [path, ops] of l.files) if (ops.has(op)) out.push(path);
    return out;
  };
  const created = withOp("created");
  const edited = withOp("edited");
  const deleted = withOp("deleted");
  const read = withOp("read");
  lines.push("## Files & artifacts");
  if (l.files.size === 0) lines.push("(none)");
  if (created.length > 0) lines.push(`- created: ${created.join(", ")}`);
  if (edited.length > 0) lines.push(`- edited: ${edited.join(", ")}`);
  if (deleted.length > 0) lines.push(`- deleted: ${deleted.join(", ")}`);
  if (read.length > 0) {
    lines.push(
      `- read: ${read.slice(0, 60).join(", ")}${
        read.length > 60 ? ` (+${read.length - 60} more)` : ""
      }`,
    );
  }
  lines.push("");

  // Actions: chronological; low-value entries collapse first.
  const actionBudget = Math.floor(budget * 0.3);
  const actionLine = (a: CompactionLedger["actions"][number]): string =>
    `#${a.seq} ${a.tool}: ${clip(a.input, 240)} → ${a.outcome}${
      a.note === undefined ? "" : ` — ${clip(a.note, 200)}`
    }`;
  const shown = [...l.actions];
  const localCollapsed = new Map(l.collapsed);
  const size = (): number =>
    shown.reduce((a, x) => a + actionLine(x).length + 1, 0);
  const passes: Array<(a: CompactionLedger["actions"][number]) => boolean> = [
    (a) => a.kind === "reply",
    (a) => a.kind === "read",
    (a) =>
      a.outcome !== "error" &&
      !(a.outcome.startsWith("exit ") && a.outcome !== "exit 0") &&
      (a.kind === "shell" || a.kind === "other"),
    (a) =>
      a.outcome !== "error" &&
      !(a.outcome.startsWith("exit ") && a.outcome !== "exit 0") &&
      (a.kind === "write" || a.kind === "delete"),
    // Failures, subagents, MCP calls and VCS actions are never collapsed.
  ];
  for (const pass of passes) {
    let i = 0;
    while (size() > actionBudget && i < shown.length - 15) {
      if (pass(shown[i]!)) {
        const removed = shown.splice(i, 1)[0]!;
        localCollapsed.set(
          removed.tool,
          (localCollapsed.get(removed.tool) ?? 0) + 1,
        );
      } else i += 1;
    }
  }
  lines.push("## Actions taken (chronological)");
  if (localCollapsed.size > 0) {
    const n = [...localCollapsed.values()].reduce((a, x) => a + x, 0);
    lines.push(
      `- (${n} earlier routine action${n === 1 ? "" : "s"} collapsed: ` +
        `${[...localCollapsed.entries()].map(([k, v]) => `${k}×${v}`).join(", ")}; ` +
        "every file they touched is listed above)",
    );
  }
  if (shown.length === 0 && localCollapsed.size === 0) lines.push("(none)");
  for (const a of shown) lines.push(`- ${actionLine(a)}`);
  lines.push("");

  const n = splitNarrative(narrativeText);
  const pick = (test: (k: string) => boolean): string | null => {
    for (const [k, v] of n) if (test(k.toLowerCase())) return v;
    return null;
  };
  const isDecision = (k: string): boolean => k.includes("decision");
  const isCurrent = (k: string): boolean => k.includes("current");
  const isNext = (k: string): boolean =>
    k.includes("next") || k.includes("pending");
  const isError = (k: string): boolean => k.includes("error");
  const unavailable =
    narrativeText.length === 0
      ? "(model summary unavailable — rely on the user instructions and " +
        "actions above)"
      : null;

  lines.push("## Decisions");
  lines.push(pick(isDecision) ?? unavailable ?? "(none recorded)");
  lines.push("");

  // Errors & fixes: deterministic, plus any narrative explanation.
  lines.push("## Errors & fixes");
  const errs =
    l.errors.length > 40 ? l.errors.slice(l.errors.length - 40) : l.errors;
  if (l.errors.length > 40) {
    lines.push(
      `- (${l.errors.length - 40} earlier errors, all resolved or superseded)`,
    );
  }
  if (errs.length === 0) lines.push("(none)");
  for (const e of errs) {
    lines.push(
      `- #${e.actionSeq} ${e.tool} ${clip(e.input, 160)}: ${e.error} → ` +
        `${e.fix === undefined ? "UNRESOLVED at checkpoint" : `fixed by ${e.fix}`}`,
    );
  }
  const errNarr = pick(isError);
  if (errNarr !== null && errNarr.trim().length > 0) lines.push(errNarr);
  lines.push("");

  // Current state.
  lines.push("## Current state / todos");
  if (state.todos.length === 0) {
    lines.push("- todos: (none)");
  } else {
    lines.push("- todos:");
    for (const t of state.todos) {
      const mark =
        t.status === "completed" ? "x" : t.status === "in_progress" ? "~" : " ";
      lines.push(`  - [${mark}] ${t.content}`);
    }
  }
  if (state.goal !== null && state.goal.objective.length > 0) {
    // Dart renders the goal's status when present; SessionGoal has none, so
    // the default Dart fallback ("active") is used.
    lines.push(`- active goal (active): ${state.goal.objective}`);
  }
  lines.push(
    `- plan mode: ${state.planMode ? "ON (read-only planning)" : "off"}`,
  );
  if ((state.workingFolder ?? "").length > 0) {
    lines.push(`- working folder: ${state.workingFolder}`);
  }
  const current = pick(isCurrent);
  if (current !== null) lines.push(current);
  lines.push(
    `- the ${state.retainedMessages} most recent message${
      state.retainedMessages === 1 ? "" : "s"
    } follow verbatim after this checkpoint`,
  );
  lines.push("");

  // Next steps.
  lines.push("## Next steps");
  const next = pick(isNext);
  if (next !== null) {
    lines.push(next);
  } else {
    for (const t of state.todos) {
      if (t.status !== "completed") lines.push(`- ${t.content}`);
    }
    const last =
      l.userMessages.length === 0
        ? null
        : l.userMessages[l.userMessages.length - 1]!;
    lines.push(
      last === null
        ? "- continue from the messages that follow"
        : `- continue from the latest user request (#${last.seq}) and the ` +
            "messages that follow",
    );
  }
  lines.push("");

  if (l.focus.length > 0) {
    lines.push("## Compaction focus (requested by the user)");
    for (const f of l.focus) {
      lines.push(`- ${f}${f === currentFocus ? " (this compaction)" : ""}`);
    }
    lines.push("");
  }

  const rest: string[] = [];
  for (const [k, v] of n) {
    const lk = k.toLowerCase();
    if (isDecision(lk) || isCurrent(lk) || isNext(lk) || isError(lk)) continue;
    if (v.trim().length === 0) continue;
    rest.push(k.length === 0 ? v : `### ${k}\n${v}`);
  }
  if (rest.length > 0) {
    lines.push("## Additional context");
    lines.push(clip(rest.join("\n\n"), Math.floor(budget * 0.2)));
    lines.push("");
  }

  const verbatimUsers = (l.goal === null ? 0 : 1) + users.length - digested;
  const files = l.files.size;
  const actions = l.actionCount;
  const totalUsers = verbatimUsers + digested;
  const preservedLine =
    `kept ${totalUsers} user message${totalUsers === 1 ? "" : "s"}` +
    `${digested > 0 ? ` (${digested} digested)` : ""} · ` +
    `${files} file${files === 1 ? "" : "s"} · ` +
    `${actions} action${actions === 1 ? "" : "s"}` +
    `${narrativeAvailable ? "" : " · no model summary"}`;

  return {
    text: lines.join("\n").trimEnd(),
    verbatimUsers,
    digestedUsers: digested,
    files,
    actions,
    narrativeAvailable,
    preservedLine,
  };
}

/**
 * Dart `CompactionEngine.finalize`: count the compaction, absorb the fold,
 * record focus and replace the narrative only when the model produced one,
 * then render with the window's checkpoint budget.
 */
export function finalizeCheckpoint(
  ledger: CompactionLedger,
  o: {
    state: CheckpointState;
    windowTokens: number;
    folded: number;
    narrative?: string | null;
    focus?: string | null;
  },
): Checkpoint {
  ledger.compactions += 1;
  ledger.foldedMessages += o.folded;
  const focus = (o.focus ?? "").trim();
  if (focus.length > 0) ledger.focus.push(focus);
  const fresh = (o.narrative ?? "").trim();
  if (fresh.length > 0) ledger.narrative = fresh;
  return renderCheckpointDetailed(ledger, null, o.state, {
    budgetTokens: checkpointBudgetTokens(o.windowTokens),
    currentFocus: focus,
    narrativeAvailable: fresh.length > 0,
  });
}
