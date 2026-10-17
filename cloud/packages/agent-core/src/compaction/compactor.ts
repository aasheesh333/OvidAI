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
// Fold boundary (review round 1, I3): the Compactor input accepts an additive
// `foldBoundary` — the number of leading messages already folded into the
// persisted ledger — and the output returns the boundary of the RETURNED
// array (0 = nothing folded, 1 = the checkpoint row at index 0 is not part of
// the replayable conversation). Dart's equivalent is `s.compactedAtCount`.
// The caller MUST pass the persisted boundary when it rebuilds history from
// durable rows, otherwise a fresh run re-absorbs the whole history into the
// cumulative ledger and duplicates every user message/action. `applyCheckpoint`
// is the companion replay helper T16 should call when assembling a request.
//
// Per-session lock (review round 1, I2): Dart's `_compacting` set
// (PR26/C3) is ported as an in-process Set. Single Node process authority is
// the same assumption Task 12's approvals gate makes; a second concurrent
// compaction on one session no-ops (auto) or returns Dart's busy string
// (manual) instead of last-write-wins losing a ledger absorption.
//
// Pruner reachability (review round 1, I4): the brief pins 12 000 chars, but
// T9's tool-layer `finish()` already spills every P3 sandbox/git result at
// 6 000 and fetch_url at 8 000 (tools/spill.ts:15, tools/web.ts), and the
// worker disables the loop-level spill (spillToolResults:false). Those rows
// therefore never reach the pruner in the real flow. The reachable classes
// are P2-adapter results (adapted through agentToolAdapter, no `finish()`),
// MCP results (P5) and subagent report rows — exactly the rows the plan's F3
// relief was meant to catch for oversized third-party output. The constant
// stays at the brief-pinned 12 000; the unit test uses a 15 000-char
// P2-adapter row (the real reachable class) plus a synthetic 30 000-char
// boundary pin.
//
// Plan pin vs Dart: the checkpoint replays as a SYSTEM row (Dart: user row);
// `cutoffMessageId` stays null because cloud AgentMessages carry no ids (T16
// can populate it from durable message rows); `compactedAtCount` is the plan's
// compaction COUNT (Dart's same-named session field is the fold boundary
// INDEX) — the fold boundary is now carried separately as `foldBoundary` /
// `ledger.folded`.

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
  COMPACTED_SUMMARY_TAGS,
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

/**
 * Additive compaction input (review I3). `foldBoundary` is the number of
 * leading messages already folded into the persisted ledger — Dart's
 * `compactedAtCount` index. Omitted means 0 (a fresh history) unless the
 * first row is a checkpoint system row, in which case it defaults to 1.
 */
export interface CompactionInput {
  sessionId: string;
  messages: AgentMessage[];
  windowTokens: number;
  foldBoundary?: number;
}

export interface CompactionOutcome {
  compacted: boolean;
  messages: AgentMessage[];
  /**
   * Index into the RETURNED messages array of the first replayable message:
   * 0 when nothing was folded, 1 when `messages[0]` is the checkpoint system
   * row. Callers use it to truncate before the next `maybeCompact`.
   */
  foldBoundary: number;
}

export interface CompactNowResult {
  compacted: boolean;
  messages: AgentMessage[];
  status: string;
  narrative: boolean;
  foldBoundary: number;
}

export interface CompactorWithManual extends Compactor {
  maybeCompact(i: CompactionInput): Promise<CompactionOutcome>;
  /** Manual `/compact [focus]` — the 24-message / 8000-token retention path. */
  compactNow(i: {
    sessionId: string;
    messages: AgentMessage[];
    windowTokens: number;
    focus?: string;
    foldBoundary?: number;
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

/**
 * A row produced by `applyCheckpoint` / `maybeCompact` — the stable system
 * checkpoint block. Used to make replay and boundary detection idempotent.
 */
export function isCheckpointRow(m: AgentMessage | undefined): boolean {
  return (
    m !== undefined &&
    m.role === "system" &&
    m.content.includes("automatically generated checkpoint") &&
    m.content.includes(COMPACTED_SUMMARY_TAGS.open)
  );
}

function stableCheckpointRow(summary: string): AgentMessage {
  return {
    role: "system",
    content: compactedSystemBlock(summary),
    volatile: false,
  };
}

/**
 * Replay helper for the request assembler (T16): given the persisted
 * compaction state and the current history, return the stable checkpoint
 * system row followed by the UNFOLDED tail.
 *
 * Boundary resolution, in order:
 *  1. an explicit [foldBoundary] (the caller knows its window);
 *  2. a leading checkpoint row in [messages] (strip it — idempotent replay);
 *  3. the ledger's cumulative `folded` count (a full history rebuilt from
 *     durable rows, oldest-first).
 *
 * With no persisted summary the messages pass through unchanged.
 */
export function applyCheckpoint(
  compaction: CompactionStateJson | null,
  messages: readonly AgentMessage[],
  foldBoundary?: number,
): AgentMessage[] {
  const summary = compaction?.summary?.trim() ?? "";
  if (summary.length === 0) return [...messages];
  let tail: readonly AgentMessage[];
  if (foldBoundary !== undefined) {
    tail = messages.slice(clamp(foldBoundary, 0, messages.length));
  } else if (isCheckpointRow(messages[0])) {
    tail = messages.slice(1);
  } else {
    const ledger = CompactionLedger.of(compaction);
    const folded = ledger?.foldedMessages ?? 0;
    tail = messages.slice(clamp(folded, 0, messages.length));
  }
  return [stableCheckpointRow(summary), ...tail];
}

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}

/** Resolve the fold boundary for an input array (review I3). */
function boundaryOf(
  messages: readonly AgentMessage[],
  foldBoundary: number | undefined,
): number {
  const leading = isCheckpointRow(messages[0]) ? 1 : 0;
  return clamp(foldBoundary ?? leading, leading, messages.length);
}

/**
 * The summarizer replay. Dart's tool-card content is empty/short and the
 * body lives in `toolDetail`, so it renders `Assistant: [tool X]` plus one
 * `[tool output]` line. A cloud tool row's `content` IS the output, so the
 * assistant line carries only the marker — emitting the content there too
 * would send every tool result twice (review I1).
 */
function replaySpan(
  span: readonly AgentMessage[],
  calls: ReadonlyMap<string, ToolCall>,
): string {
  const out: string[] = [];
  for (const m of span) {
    // The checkpoint system row (or any standing system row) is not part of
    // the conversation span Dart replays; Dart skips MsgKind.compact.
    if (m.role === "system") continue;
    if (m.role === "tool") {
      const tool =
        m.toolCallId !== undefined
          ? (calls.get(m.toolCallId)?.name ?? "tool")
          : "tool";
      out.push(`Assistant: [tool ${tool}]`);
      const detail = m.content.trim();
      if (detail.length > 0) {
        out.push(`  [tool output] ${cleanTruncate(detail, 2_000)}`);
      }
      continue;
    }
    const who = m.role === "user" ? "User" : "Assistant";
    out.push(`${who}: ${m.content}`);
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
  // PR26/C3: one compaction at a time per session (Dart `_compacting`).
  // Single-process authority, the same assumption the approvals gate makes.
  const compacting = new Set<string>();

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
   * Fold `[from, cutoff)` and apply the checkpoint. Shared by auto and
   * manual. Returns the rebuilt request (checkpoint system row + retained
   * tail) and the fresh-narrative flag.
   */
  async function applyCompaction(o: {
    sessionId: string;
    messages: AgentMessage[];
    windowTokens: number;
    from: number;
    cutoff: number;
    focus?: string;
  }): Promise<{
    messages: AgentMessage[];
    narrative: boolean;
    checkpoint: Checkpoint;
    folded: number;
  }> {
    const { sessionId, messages, windowTokens, from, cutoff } = o;
    const state = await deps.state.get(sessionId);
    const prior = CompactionLedger.of(state.compaction);
    const span = messages.slice(from, cutoff);
    // Cumulative: the previous ledger absorbs ONLY the new span. A session
    // with no ledger (fresh, or old LLM-only format) absorbs its whole
    // retained prefix and adopts the legacy summary as prior narrative.
    const ledger = buildLedger(prior, span);
    if (
      prior === null &&
      state.compaction?.summary !== null &&
      state.compaction?.summary !== undefined
    ) {
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
    const folded = cutoff - from;
    const checkpoint = finalizeCheckpoint(ledger, {
      state: checkpointStateOf(
        state,
        workingFolder,
        messages.length - cutoff,
      ),
      windowTokens,
      folded,
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
      folded,
      retained: messages.length - cutoff,
      narrative: fresh,
    });

    return {
      messages: [stableCheckpointRow(checkpoint.text), ...messages.slice(cutoff)],
      narrative: fresh,
      checkpoint,
      folded,
    };
  }

  return {
    async maybeCompact(i) {
      const from = boundaryOf(i.messages, i.foldBoundary);
      // PR26/C3: a concurrent compaction on this session is a no-op, never a
      // second absorption from a stale base. (JS Set.add returns the Set, not
      // a boolean — test membership before adding.)
      if (compacting.has(i.sessionId)) {
        return { compacted: false, messages: i.messages, foldBoundary: from };
      }
      compacting.add(i.sessionId);
      try {
        const { sessionId, messages, windowTokens } = i;
        const threshold = compactionThresholdTokens(windowTokens);
        let measured = measuredTokens(messages);
        if (measured < threshold) {
          return { compacted: false, messages, foldBoundary: from };
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
            // Pressure relieved without a summary. The pruned rows are
            // returned with compacted:false; the caller must apply them
            // (T16 carry 3).
            return {
              compacted: false,
              messages: pruned.messages,
              foldBoundary: from,
            };
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
        while (cutoff > from) {
          if (
            tail >= retain &&
            pruned.messages.length - cutoff >= 6 &&
            cutoff - from >= 4
          ) {
            break;
          }
          tail += estimateMessageTokens(pruned.messages[cutoff - 1]!.content);
          cutoff -= 1;
        }
        cutoff = snapCutoff(pruned.messages, from, cutoff, 4);
        if (cutoff - from < 4) {
          return {
            compacted: false,
            messages: pruned.messages,
            foldBoundary: from,
          };
        }

        const applied = await applyCompaction({
          sessionId,
          messages: pruned.messages,
          windowTokens,
          from,
          cutoff,
        });
        return { compacted: true, messages: applied.messages, foldBoundary: 1 };
      } catch {
        // Compaction failure is non-fatal (Dart `_maybeCompactLocked`): the
        // run continues with full history.
        return { compacted: false, messages: i.messages, foldBoundary: from };
      } finally {
        compacting.delete(i.sessionId);
      }
    },

    async pruneOversizedToolResults(i) {
      const measured = measuredTokens(i.messages);
      if (measured < i.thresholdTokens) {
        return { pruned: 0, messages: i.messages };
      }
      return pruneRows(i.messages);
    },

    async compactNow(i) {
      const from = boundaryOf(i.messages, i.foldBoundary);
      if (compacting.has(i.sessionId)) {
        return {
          compacted: false,
          messages: i.messages,
          narrative: false,
          foldBoundary: from,
          status: "Compaction is already running in this chat.",
        };
      }
      compacting.add(i.sessionId);
      try {
        const { sessionId, messages, windowTokens } = i;
        // Manual retention: newest slice bounded by BOTH message count and
        // tokens, always >=6 retained and >=4 foldable (Dart compactNow).
        let tail = 0;
        let cutoff = messages.length;
        while (cutoff > from) {
          const retained = messages.length - cutoff;
          if (
            retained >= 6 &&
            (tail >= COMPACTION.manualRetainTokens ||
              retained >= COMPACTION.manualRetainMessages) &&
            cutoff - from >= 4
          ) {
            break;
          }
          tail += estimateMessageTokens(messages[cutoff - 1]!.content);
          cutoff -= 1;
        }
        cutoff = snapCutoff(messages, from, cutoff, 4);
        if (cutoff - from < 4) {
          const left = messages.length - from;
          return {
            compacted: false,
            messages,
            narrative: false,
            foldBoundary: from,
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
          from,
          cutoff,
          ...(focus.length > 0 ? { focus } : {}),
        });
        const foldedTokens = measuredTokens(messages.slice(from, cutoff));
        const human =
          `compacted ${applied.folded} message(s) (~${fmtK(foldedTokens)} ` +
          "tokens folded into the checkpoint)";
        return {
          compacted: true,
          messages: applied.messages,
          narrative: applied.narrative,
          foldBoundary: 1,
          status: applied.narrative
            ? `Session compacted — ${human}. View the checkpoint row in the transcript.`
            : "Session compacted from the transcript only — the model returned " +
              "no summary, so every user message and the work log were kept " +
              `verbatim (${human}).`,
        };
      } catch (err) {
        // Dart parity: report honestly and leave history untouched.
        return {
          compacted: false,
          messages: i.messages,
          narrative: false,
          foldBoundary: from,
          status:
            `Compaction failed: ${
              err instanceof Error
                ? (err.message.split("\n")[0] ?? err.message)
                : String(err)
            } — history is untouched.`,
        };
      } finally {
        compacting.delete(i.sessionId);
      }
    },
  };
}
