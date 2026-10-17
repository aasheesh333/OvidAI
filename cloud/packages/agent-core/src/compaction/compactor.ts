// Lossless compaction orchestration — the port of agent_service.dart
// `_maybeCompactLocked` / `_compactSpan` / `_applyCompaction` / `compactNow`
// (10631-11304) onto the cloud Compactor port.
//
// Ordering is load-bearing:
//   1. measure pressure; below threshold -> untouched;
//   2. PRUNE oversized tool results first (cost-free relief); if that alone
//      drops pressure below the threshold, summarize NOTHING;
//   3. select a safe cut point (never inside a tool run);
//   4. absorb the newly folded span into the CUMULATIVE ledger (never
//      summarize a summary);
//   5. ask the model for the narrative — a failure NEVER blocks compaction
//      (the deterministic checkpoint is applied anyway);
//   6. render, persist CompactionStateJson, emit compaction_completed;
//   7. replay as [checkpoint system row, ...retained tail].
//
// Plan pin vs Dart: the checkpoint replays as a SYSTEM row (Dart: user row);
// `cutoffMessageId` stays null because cloud AgentMessages carry no ids (T16
// can populate it from durable message rows); `compactedAtCount` is the plan's
// compaction COUNT (Dart's same-named session field is the fold boundary
// INDEX).

import type {
  CompactionStateJson,
  Compactor,
  EventSink,
  SandboxPort,
  SessionStateStore,
} from "../ports.js";
import { spillToolOutput } from "../tools/spill.js";
import type { AgentMessage, ToolCall } from "../types.js";
import {
  compactedSystemBlock,
  finalizeCheckpoint,
  summarizerSystemPrompt,
  summarizerUserPrompt,
  type Checkpoint,
  type CheckpointState,
} from "./checkpoint.js";
import { buildLedger, CompactionLedger } from "./ledger.js";
import {
  COMPACTION,
  PRUNER_SPILL_CAP,
  checkpointBudgetTokens,
  compactionThresholdTokens,
  estimateMessageTokens,
  snapCutoff,
} from "./policy.js";

export interface CompactionSummarizeInput {
  /** The folded span (verbatim replay source). */
  messages: readonly AgentMessage[];
  budgetTokens: number;
  priorNarrative: string;
  focus?: string;
  /** Dart F4: the second attempt asks for a strictly shorter narrative. */
  strict?: boolean;
  /** Ready-to-send prompts (the worker's quiet model call supplies transport). */
  systemPrompt: string;
  userPrompt: string;
}

export interface CompactorDeps {
  state: SessionStateStore;
  sandbox: SandboxPort;
  sink: EventSink;
  summarize(i: CompactionSummarizeInput): Promise<string | null>;
  /** Sandbox identity for the spill path (per-run in the worker). */
  userId: string;
  workspaceRelDir?: string;
  /** Snapshot for the checkpoint's Current state section. */
  workingFolder?: string | null;
  /** Event payload runId (compaction_completed). */
  runId?: string;
}

export interface CompactNowResult {
  compacted: boolean;
  messages: AgentMessage[];
  status: string;
  narrative: boolean;
}

export interface CompactorWithManual extends Compactor {
  /** Manual `/compact [focus]` — the 24-message / 8000-token retention path. */
  compactNow(i: {
    sessionId: string;
    messages: AgentMessage[];
    windowTokens: number;
    focus?: string;
  }): Promise<CompactNowResult>;
}

/** Dart `cleanTruncate`: head(max) + ellipsis, never splitting a surrogate pair. */
function cleanTruncate(text: string, max: number): string {
  if (text.length <= max) return text;
  let cut = text.slice(0, max);
  const last = cut.charCodeAt(cut.length - 1);
  if (last >= 0xd800 && last <= 0xdbff) cut = cut.slice(0, -1);
  return `${cut}…`;
}

function fmtK(n: number): string {
  const trim = (v: number): string => {
    const s = v.toFixed(1);
    return s.endsWith(".0") ? s.slice(0, -2) : s;
  };
  if (n < 1_000) return String(Math.round(n));
  if (n < 1_000_000) return `${trim(n / 1_000)}K`;
  return `${trim(n / 1_000_000)}M`;
}

function measuredTokens(messages: readonly AgentMessage[]): number {
  let total = 0;
  for (const m of messages) total += estimateMessageTokens(m.content);
  return total;
}

/** Tool name for a result row, resolved from the issuing call when present. */
function toolNameFor(
  messages: readonly AgentMessage[],
  row: AgentMessage,
): string {
  if (row.toolCallId === undefined) return "tool";
  for (const m of messages) {
    if (m.role === "assistant" && m.toolCalls !== undefined) {
      const hit = m.toolCalls.find((c) => c.id === row.toolCallId);
      if (hit !== undefined) return hit.name;
    }
  }
  return "tool";
}

function replaySpan(
  span: readonly AgentMessage[],
  calls: ReadonlyMap<string, ToolCall>,
): string {
  const out: string[] = [];
  for (const m of span) {
    // The checkpoint system row (or any standing system row) is not part of
    // the conversation span Dart replays; Dart skips MsgKind.compact.
    if (m.role === "system") continue;
    const tool =
      m.role === "tool" && m.toolCallId !== undefined
        ? calls.get(m.toolCallId)?.name
        : undefined;
    const who = m.role === "user" ? "User" : "Assistant";
    const prefix = m.role === "tool" ? `[tool ${tool ?? "tool"}] ` : "";
    out.push(`${who}: ${prefix}${m.content}`);
    if (m.role === "tool" && m.content.trim().length > 0) {
      out.push(`  [tool output] ${cleanTruncate(m.content.trim(), 2_000)}`);
    }
  }
  return out.join("\n");
}

function checkpointStateOf(
  state: Awaited<ReturnType<SessionStateStore["get"]>>,
  workingFolder: string | null,
  retainedMessages: number,
): CheckpointState {
  return {
    todos: [...state.todos],
    goal: state.goal,
    planMode: state.planMode,
    workingFolder,
    retainedMessages,
  };
}

export function createCompactor(deps: CompactorDeps): CompactorWithManual {
  const workspaceRelDir = deps.workspaceRelDir ?? "";
  const workingFolder = deps.workingFolder ?? null;

  /** Spill every tool row at/over the pinned threshold. Pure (new array). */
  async function pruneRows(messages: readonly AgentMessage[]): Promise<{
    pruned: number;
    messages: AgentMessage[];
  }> {
    let pruned = 0;
    const out: AgentMessage[] = [];
    for (const m of messages) {
      if (
        m.role === "tool" &&
        m.content.length >= COMPACTION.oversizedToolResultChars
      ) {
        const replaced = await spillToolOutput(
          { sandbox: deps.sandbox, userId: deps.userId, workspaceRelDir },
          toolNameFor(messages, m),
          m.content,
          PRUNER_SPILL_CAP,
        );
        if (replaced.length < m.content.length) {
          pruned += 1;
          out.push({ ...m, content: replaced });
          continue;
        }
      }
      out.push(m);
    }
    return { pruned, messages: pruned > 0 ? out : [...messages] };
  }

  async function note(
    code: string,
    payload: Record<string, unknown>,
  ): Promise<void> {
    try {
      await deps.sink.emit("system_note", { code, ...payload });
    } catch {
      // An observability note must never fail compaction.
    }
  }

  /**
   * Ask the model for the narrative. Never throws; returns null on failure.
   * Dart F4: a summary that does not shrink its source is retried once with
   * the strict prompt, then accepted (or dropped when that attempt fails).
   */
  async function summarizeSafely(
    span: readonly AgentMessage[],
    ledger: CompactionLedger,
    priorNarrative: string,
    focus: string | undefined,
    windowTokens: number,
  ): Promise<string | null> {
    const calls = new Map<string, ToolCall>();
    for (const m of span) {
      if (m.role === "assistant" && m.toolCalls !== undefined) {
        for (const c of m.toolCalls) calls.set(c.id, c);
      }
    }
    const replay = replaySpan(span, calls);
    const spanTokens = measuredTokens(span);
    const budgetTokens = checkpointBudgetTokens(windowTokens);
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const systemPrompt = summarizerSystemPrompt({ strict: attempt > 0 });
      const userPrompt = summarizerUserPrompt({
        replay,
        priorNarrative,
        ledger,
        focus,
      });
      try {
        const text = await deps.summarize({
          messages: span,
          budgetTokens,
          priorNarrative,
          ...(focus !== undefined ? { focus } : {}),
          strict: attempt > 0,
          systemPrompt,
          userPrompt,
        });
        if (text === null || text.trim().length === 0) continue;
        if (estimateMessageTokens(text) < spanTokens || attempt > 0) {
          return text;
        }
      } catch (err) {
        await note("compaction_summary_failed", {
          message: err instanceof Error ? err.message : String(err),
        });
        return null;
      }
    }
    return null;
  }

  /**
   * Fold `[0, cutoff)` and apply the checkpoint. Shared by auto and manual.
   * Returns the rebuilt request (checkpoint system row + retained tail) and
   * the fresh-narrative flag.
   */
  async function applyCompaction(o: {
    sessionId: string;
    messages: AgentMessage[];
    windowTokens: number;
    cutoff: number;
    focus?: string;
  }): Promise<{ messages: AgentMessage[]; narrative: boolean; checkpoint: Checkpoint; folded: number }> {
    const { sessionId, messages, windowTokens, cutoff } = o;
    const state = await deps.state.get(sessionId);
    const prior = CompactionLedger.of(state.compaction);
    const span = messages.slice(0, cutoff);
    // Cumulative: the previous ledger absorbs ONLY the new span. A session
    // with no ledger (fresh, or old LLM-only format) absorbs its whole
    // retained prefix and adopts the legacy summary as prior narrative.
    const ledger = buildLedger(prior, span);
    if (prior === null && state.compaction?.summary !== null && state.compaction?.summary !== undefined) {
      const legacy = state.compaction.summary.trim();
      if (legacy.length > 0) ledger.narrative = legacy;
    }
    const priorNarrative =
      prior !== null ? prior.narrative : (state.compaction?.summary ?? "");
    const narrative = await summarizeSafely(
      span,
      ledger,
      priorNarrative,
      o.focus,
      windowTokens,
    );
    const checkpoint = finalizeCheckpoint(ledger, {
      state: checkpointStateOf(
        state,
        workingFolder,
        messages.length - cutoff,
      ),
      windowTokens,
      folded: cutoff,
      narrative,
      focus: o.focus ?? null,
    });

    const next: CompactionStateJson = {
      ledger: ledger.toJson(),
      summary: checkpoint.text,
      // AgentMessage carries no durable id; the plan's field is persisted as
      // null and T16 can fill it from the message rows it owns.
      cutoffMessageId: null,
      compactedAtCount: (state.compaction?.compactedAtCount ?? 0) + 1,
    };
    await deps.state.patch(sessionId, { compaction: next });

    const fresh = narrative !== null && narrative.trim().length > 0;
    await deps.sink.emit("compaction_completed", {
      ...(deps.runId !== undefined ? { runId: deps.runId } : {}),
      folded: cutoff,
      retained: messages.length - cutoff,
      narrative: fresh,
    });

    return {
      messages: [
        {
          role: "system",
          content: compactedSystemBlock(checkpoint.text),
          volatile: false,
        },
        ...messages.slice(cutoff),
      ],
      narrative: fresh,
      checkpoint,
      folded: cutoff,
    };
  }

  return {
    async maybeCompact(i) {
      const { sessionId, messages, windowTokens } = i;
      const threshold = compactionThresholdTokens(windowTokens);
      let measured = measuredTokens(messages);
      if (measured < threshold) {
        return { compacted: false, messages };
      }

      // F3: prune BEFORE spending a model call.
      const pruned = await pruneRows(messages);
      if (pruned.pruned > 0) {
        measured = measuredTokens(pruned.messages);
        await note("context_pruned", {
          pruned: pruned.pruned,
          message:
            `context pruned: ${pruned.pruned} oversized tool output(s) ` +
            `spilled to disk (~${Math.round((measured / windowTokens) * 100)}% now)`,
        });
        if (measured < threshold) {
          // Pressure relieved without a summary. The plan returns the pruned
          // rows with compacted:false (the loop currently applies a
          // compacted:false result as-is — T16 wiring note).
          return { compacted: false, messages: pruned.messages };
        }
      }

      // Retain the newest ~16% of the window verbatim; scale DOWN when the
      // absolute trigger fired (retaining 160k of a 1M window would fold
      // nothing). Always keep >=6 retained and >=4 foldable messages.
      let retain = Math.floor(windowTokens * COMPACTION.retainRatio);
      const scaled = Math.floor(measured * 0.25);
      if (scaled < retain) retain = scaled;
      let tail = 0;
      let cutoff = pruned.messages.length;
      while (cutoff > 0) {
        if (
          tail >= retain &&
          pruned.messages.length - cutoff >= 6 &&
          cutoff >= 4
        ) {
          break;
        }
        tail += estimateMessageTokens(pruned.messages[cutoff - 1]!.content);
        cutoff -= 1;
      }
      cutoff = snapCutoff(pruned.messages, 0, cutoff, 4);
      if (cutoff < 4) return { compacted: false, messages: pruned.messages };

      const applied = await applyCompaction({
        sessionId,
        messages: pruned.messages,
        windowTokens,
        cutoff,
      });
      return { compacted: true, messages: applied.messages };
    },

    async pruneOversizedToolResults(i) {
      const measured = measuredTokens(i.messages);
      if (measured < i.thresholdTokens) {
        return { pruned: 0, messages: i.messages };
      }
      return pruneRows(i.messages);
    },

    async compactNow(i) {
      const { sessionId, messages, windowTokens } = i;
      // Manual retention: newest slice bounded by BOTH message count and
      // tokens, always >=6 retained and >=4 foldable (Dart compactNow).
      let tail = 0;
      let cutoff = messages.length;
      while (cutoff > 0) {
        const retained = messages.length - cutoff;
        if (
          retained >= 6 &&
          (tail >= COMPACTION.manualRetainTokens ||
            retained >= COMPACTION.manualRetainMessages) &&
          cutoff >= 4
        ) {
          break;
        }
        tail += estimateMessageTokens(messages[cutoff - 1]!.content);
        cutoff -= 1;
      }
      cutoff = snapCutoff(messages, 0, cutoff, 4);
      if (cutoff < 4) {
        const left = messages.length;
        return {
          compacted: false,
          messages,
          narrative: false,
          status:
            left <= 0
              ? "Nothing to compact — this chat is already fully compacted."
              : `Nothing to compact yet — only ${left} message(s) after the ` +
                "last checkpoint (need ≥4 foldable + retained tail).",
        };
      }
      const focus = (i.focus ?? "").trim();
      const applied = await applyCompaction({
        sessionId,
        messages,
        windowTokens,
        cutoff,
        ...(focus.length > 0 ? { focus } : {}),
      });
      const foldedTokens = measuredTokens(messages.slice(0, cutoff));
      const human =
        `compacted ${applied.folded} message(s) (~${fmtK(foldedTokens)} ` +
        "tokens folded into the checkpoint)";
      return {
        compacted: true,
        messages: applied.messages,
        narrative: applied.narrative,
        status: applied.narrative
          ? `Session compacted — ${human}. View the checkpoint row in the transcript.`
          : "Session compacted from the transcript only — the model returned " +
            "no summary, so every user message and the work log were kept " +
            `verbatim (${human}).`,
      };
    },
  };
}
