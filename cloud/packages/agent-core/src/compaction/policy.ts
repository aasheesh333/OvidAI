// Lossless compaction policy — a direct port of
// lib/core/compaction/compaction_policy.dart plus the constants from
// lib/core/agent_service.dart:10631-10648.
//
// Dart's transcript keeps a tool call and its result on ONE tool-card row
// (Message.kind == MsgKind.tool). The cloud AgentMessage seam splits them:
// {role:"assistant", toolCalls:[…]} followed by {role:"tool", toolCallId}.
// The invariant is the same: a retained tail must never START on a tool-result
// row whose issuing turn was folded. The "still-running tool" clause of the
// Dart policy has no cloud analog — the loop only pushes a tool row after the
// call settles — so it is structurally impossible here and intentionally
// absent.

import type { AgentMessage } from "../types.js";

/**
 * Constants EXACT (plan Task 19 interface, Dart agent_service.dart:10631-10648).
 *
 * Divergences, deliberate and flagged for review:
 *  - `oversizedToolResultChars: 12_000` is the plan/brief pin. Dart's pruner
 *    threshold is 8_000 with a 4_000 spill cap (agent_service.dart:11090,
 *    11098); 12_000 in Dart is the LIVE-STREAMING trim (19927-19931,
 *    24281-24283, 24915), not the pruner. The plan conflates the two; the
 *    brief is binding, so 12_000 is the threshold and the Dart spill cap
 *    (4_000) is kept for the replacement text.
 *  - `compactionThresholdTokens` uses Math.round per the plan. Dart FLOORS
 *    (`(window * 0.8).floor()`, agent_service.dart:11110). The difference is
 *    at most one token and the absolute 100_000 cap dominates large windows;
 *    the plan pin wins per the SDD binding hierarchy.
 */
export const COMPACTION = {
  thresholdRatio: 0.8,
  retainRatio: 0.16,
  absoluteThresholdTokens: 100_000,
  manualRetainMessages: 24,
  manualRetainTokens: 8_000,
  oversizedToolResultChars: 12_000,
} as const;

/** Dart `_pruneOversizedToolDetailsBeforeCompact` spills with `cap: 4000`. */
export const PRUNER_SPILL_CAP = 4_000;

/** Dart: `text.length ~/ 4 + 4` (chars/4 heuristic + framing overhead). */
export function estimateMessageTokens(text: string): number {
  return Math.floor(text.length / 4) + 4;
}

/** Dart `checkpointBudgetTokens`: round(window*0.12) clamped 2500..24000. */
export function checkpointBudgetTokens(window: number): number {
  return Math.min(24_000, Math.max(2_500, Math.round(window * 0.12)));
}

/** Plan pin: min(round(window*0.8), 100_000). Dart floors the ratio term. */
export function compactionThresholdTokens(window: number): number {
  return Math.min(
    Math.round(window * COMPACTION.thresholdRatio),
    COMPACTION.absoluteThresholdTokens,
  );
}

/** Dart `MsgKind.tool` — in the cloud seam, the tool-RESULT row. */
export function isToolResultRow(m: AgentMessage | undefined): boolean {
  return m !== undefined && m.role === "tool";
}

/** Dart `_isTurnStart`: a user row that is neither a tool card nor a compact row. */
function isTurnStart(m: AgentMessage | undefined): boolean {
  return m !== undefined && m.role === "user";
}

/**
 * Dart `_safeAt`: true when folding `[.., c)` leaves a valid request.
 *  - the retained tail may not start on a tool-result row;
 *  - (Dart also refuses to fold a still-running tool card; cloud rows only
 *    exist after settlement, so that clause has no state to test).
 */
function safeAt(msgs: readonly AgentMessage[], c: number): boolean {
  if (c <= 0 || c >= msgs.length) return true;
  return !isToolResultRow(msgs[c]);
}

/** True when cutting at [cutoff] would orphan a tool result from its turn. */
export function splitsToolRun(
  msgs: readonly AgentMessage[],
  cutoff: number,
): boolean {
  return !safeAt(msgs, cutoff);
}

/**
 * Move a proposed [cutoff] to a safe boundary in `(from, msgs.length]`.
 *
 * Order (Dart parity):
 *  1. at/after the end -> msgs.length;
 *  2. less than [minFold] foldable -> leave [cutoff] alone;
 *  3. prefer a user-turn start in the upper half of the intended fold;
 *  4. then any safe boundary at or before [cutoff] (at least [minFold]);
 *  5. then the nearest safe boundary AFTER [cutoff];
 *  6. no safe cut -> [from] (fold nothing).
 *
 * The cloud plan's signature has no minFold; it is an optional fourth
 * parameter (default 1) because auto/manual use 4 and the overflow path uses
 * 2 (Dart call sites).
 */
export function snapCutoff(
  msgs: readonly AgentMessage[],
  from: number,
  cutoff: number,
  minFold = 1,
): number {
  if (cutoff >= msgs.length) return msgs.length;
  if (cutoff - from < minFold) return cutoff;
  const intended = cutoff - from;
  const floor =
    from + Math.min(intended, Math.max(minFold, Math.ceil(intended / 2)));
  for (let c = cutoff; c >= floor; c -= 1) {
    if (isTurnStart(msgs[c]) && safeAt(msgs, c)) return c;
  }
  for (let c = cutoff; c >= from + minFold; c -= 1) {
    if (safeAt(msgs, c)) return c;
  }
  for (let c = cutoff + 1; c < msgs.length; c += 1) {
    if (safeAt(msgs, c)) return c;
  }
  return from;
}
