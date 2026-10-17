// Loop guards (P3 Task 14) — the Dart AgentRun loop-safety state machine.
//
// Ports the per-run "bucket" guard fields (lib/core/agent_service.dart
// AS:866–897: repeatKey AS:866, repeatStreak AS:867, consecutiveErrors AS:868,
// todoNudgeSent AS:897) plus the repeat-tool reminder (AS:12714–12741), the
// error-escalation guard (AS:12742–12753), the budget boundary formula
// (AS:12340), the no-progress transient-retry gate (the inlined `6` at
// AS:12459) and the todo follow-through nudge (AS:12516–12545).
//
// Pure state machine, no I/O: a GuardState instance IS the Dart run bucket —
// mutated in place, one per run, reset at run entry (Dart AS:11838 resets
// todoNudgeSent; Task 15's engine constructs a fresh state per run).
// `turnsWithoutProgress` is a LOCAL of Dart's `_runTaskBody` (AS:12156) — the
// TS GuardState hoists it per the plan (plan:601).

import type { TodoItem } from "./ports.js";
import { canonicalJson } from "./promptCache.js";

export interface GuardState {
  repeatKey: { name: string; canonArgs: string } | null;
  repeatStreak: number;
  consecutiveErrors: number;
  turnsWithoutProgress: number;
  todoNudgeSent: boolean;
}

/** The zero bucket (Dart field defaults; the first call moves the streak to 1). */
export function newGuardState(): GuardState {
  return {
    repeatKey: null,
    repeatStreak: 0,
    consecutiveErrors: 0,
    turnsWithoutProgress: 0,
    todoNudgeSent: false,
  };
}

/**
 * Dart _looksLikeToolError (AS:19753–19761), six clauses, verbatim:
 * lowercase startsWith 'error' / 'tool error', contains 'not found' /
 * 'permission denied' / 'failed:' / 'exception:'.
 *
 * PLAN-TEXT DIVERGENCE (plan:598 parenthetical lists "startsWith
 * 'Error'/'tool error'/'DENIED'/'fetch failed'/'search failed', exit-code
 * prefixes"): that is NOT what Dart does. DENIED results do NOT increment
 * consecutiveErrors anywhere in Dart — they drive the tool-card 'stopped'
 * state (AS:12693) and the ok/error event flags (AS:15158–15179) instead;
 * and 'fetch failed'/'search failed' (no colon) match no Dart clause. Dart
 * is the behavioral contract (AG4) → the six clauses win. Flagged in the
 * task report for the controller.
 */
export function looksLikeToolError(result: string): boolean {
  const l = result.toLowerCase();
  return (
    l.startsWith("error") ||
    l.startsWith("tool error") ||
    l.includes("not found") ||
    l.includes("permission denied") ||
    l.includes("failed:") ||
    l.includes("exception:")
  );
}

/**
 * The loop's guard hook — runs AFTER the tool result exists and BEFORE the
 * tool row is appended (Dart AS:12714, between the stale-drop check and the
 * spill). Returns the result with any repeat-note/escalation appended plus
 * the error classification; the GuardState bucket mutates in place (streak,
 * error ladder), the caller's `result` string is never mutated.
 */
export function recordToolResult(
  g: GuardState,
  name: string,
  args: Record<string, unknown>,
  result: string,
): { result: string; isError: boolean } {
  // canonArgs — Task 3's canonicalJson (recursive key-sort; promptCache.ts).
  // DART DEVIATION, mandated by the plan (plan:596): Dart jsonEncodes in
  // insertion order with a toString fallback, so two calls differing only in
  // key order do NOT collide there; the TS port deliberately strengthens the
  // repeat key to canonical form. canonicalToolJson is NOT usable here — it
  // is the tool-spec application (name-sorts a ToolSpec array) and cannot
  // stringify arbitrary args.
  //
  // T3-review minors folded: canonicalJson returns `undefined` (not a
  // string) for a top-level undefined — guarded so a repeatKey can never
  // hold a non-string. NaN serializes as `null` (so {x: NaN} and {x: null}
  // collide in canonical form) and undefined VALUES are dropped by
  // JSON.stringify (so {x: undefined} and {} collide) — tool args come from
  // JSON.parse of model output, where neither can occur; documented here
  // rather than patched (the pinned T3 resolution).
  const canonArgs = args === undefined || args === null ? "null" : canonicalJson(args);

  // Both name AND args must match (Dart AS:12720–12726); either changing
  // resets the streak to 1.
  if (
    g.repeatKey !== null &&
    g.repeatKey.name === name &&
    g.repeatKey.canonArgs === canonArgs
  ) {
    g.repeatStreak += 1;
  } else {
    g.repeatKey = { name, canonArgs };
    g.repeatStreak = 1;
  }

  // Escalating nudge at EXACTLY streak 3 / 5 / 8 (Dart AS:12728–12741,
  // byte-for-byte — em-dashes are U+2014). No note at any other value.
  let out = result;
  if (g.repeatStreak === 3) {
    out =
      `${out}\n\n[note] Same tool + identical args repeated 3 times — re-read the tool output or change approach.`;
  } else if (g.repeatStreak === 5) {
    out =
      `${out}\n\n[note] Same call now repeated 5 times — stop, reconsider the goal, or ask/notify the user.`;
  } else if (g.repeatStreak === 8) {
    out =
      `${out}\n\n[note] Same call repeated 8 times — STOP looping. Explain the blockage to the user and try a different approach.`;
  }

  // Classification runs on the result WITH any repeat note already appended
  // (Dart AS:12742–12743 — harmless: the note text contains no classifier
  // tokens). The second clause is Dart's verbatim case-sensitive prefix,
  // subsumed by the classifier's lowercase clause but kept for fidelity.
  const isError = looksLikeToolError(out) || out.startsWith("tool error");
  if (isError) {
    g.consecutiveErrors += 1;
  } else {
    g.consecutiveErrors = 0; // any success resets the ladder (AS:12744–12748)
  }

  // ≥3 appends on EVERY subsequent error while the ladder stays ≥3 (Dart
  // AS:12749–12753) — the count INCLUDING the current failure.
  if (g.consecutiveErrors >= 3) {
    out =
      `${out}\n\n[CRITICAL ESCALATION] Tool calls have failed ${g.consecutiveErrors} times consecutively. DO NOT continue repeating similar commands or querying missing files. Stop probing and clearly explain the exact problem to the user.`;
  }

  return { result: out, isError };
}

/**
 * Dart AS:12340: `msg != null && turn >= 12 && turn % 12 == 0`. The
 * `msg != null` guard exists because the boundary is REMEMBERED mid-turn but
 * APPLIED only at the end of the iteration — never short-circuit the
 * model's reply (the Dart comment AS:12335–12339 records that the old code
 * `continue`d right after _callLlm and threw away whole replies on turns
 * 12/24/36). Pure on `turn` here; Task 15's loop applies it only after a
 * non-null response.
 */
export function isBudgetBoundary(turn: number): boolean {
  return turn >= 12 && turn % 12 === 0;
}

/**
 * No Dart symbol names this — the plan's constant (plan:601) for Dart's
 * inlined literals: the run-level transient-retry gate `turnsWithoutProgress
 * < 6` (AS:12459). Retries may continue only below 6; any non-null model
 * response DECREMENTS (floor 0, decay not reset — AS:12493: a long task
 * with occasional hiccups never exhausts its budget); the budget-boundary
 * nudge (AS:12802) and each run-level transient retry (AS:12460) increment.
 *
 * DART SHAPE NOTE: Dart is a TWO-level ladder (inner _callLlm 5×[3,9,27,60]s
 * then outer run-level ≤6×[5·n]s); the cloud plan folds ONE ladder (P1's
 * 5×[3,9,27,60]) gated by this constant — Task 15 implements the fold.
 */
export const NO_PROGRESS_LIMIT = 6;

/**
 * The nudge text, byte-for-byte (Dart AS:12537–12542). `pending` is the
 * CALLER-FILTERED pending subset (status != 'completed', Dart AS:12519):
 * '- [~] item' for in_progress, '- [ ] item' otherwise.
 */
export function todoNudgeMessage(pending: readonly TodoItem[]): string {
  const lines = pending
    .map((t) => `- [${t.status === "in_progress" ? "~" : " "}] ${t.content}`)
    .join("\n");
  return (
    "[system] Your SESSION TODOS still has pending items:\n" +
    `${lines}\n\n` +
    "Continue working on them. Mark each item in_progress before starting it and completed when done. If a pending item is already done or no longer relevant, update the list with todo_write. Then give your final answer."
  );
}

/**
 * Dart AS:12519–12524: pending todos exist && !todoNudgeSent &&
 * turnsWithoutProgress < 5 — the 5 literal, NOT NO_PROGRESS_LIMIT (the nudge
 * budget is its own, one notch below the retry gate).
 *
 * Pure predicate; the LOOP sets `g.todoNudgeSent = true` BEFORE injecting
 * (Dart AS:12525) — exactly once per run, reset at run entry (AS:11838).
 */
export function shouldSendTodoNudge(g: GuardState, todos: readonly TodoItem[]): boolean {
  const pending = todos.some((t) => t.status !== "completed");
  return pending && !g.todoNudgeSent && g.turnsWithoutProgress < 5;
}
