// Subagents (P3 Task 20) — in-process child loops + the durable child handle.
//
// PORT OF: lib/core/agent_service.dart `_handleDispatchAgent` (AS:24414–24564),
// `_runSubagentSession` (AS:24871–25066), `_maxSubagentDepth` /
// `_maxConcurrentSubagents` (AS:23048–23084), and lib/core/subagent_tools.dart
// (SubagentToolPolicy).
//
// RULINGS THIS FILE ENCODES (all binding):
//  • P3-Q2: a child is an IN-PROCESS loop, not a nested BullMQ job. The
//    parent's dispatch_agent tool call awaits `engine.run` on the child
//    session; cancellation is an engine.cancel flip (the parent's AbortSignal
//    cascades); the child has its own `runs` row, so the P1 stale-run sweeper
//    terminalizes a stranded child exactly like a parent.
//  • B20 (refusal precedence, INVERTED vs Dart on purpose): the durable
//    LINEAGE depth check runs FIRST; the `isSubagent` parent refusal is a
//    backstop (and the normal layer-3 gate for a depth-1 child). Do NOT
//    restore Dart's isSubagent-first order.
//  • T8 C1: a child session is born `planMode:false` — plan mode is NEVER
//    inherited. The parent's plan gate already refuses dispatch before a
//    child can exist.
//  • CHILD_DENIED_TOOLS (roster.ts, landed T8) is layer 2: a child never even
//    sees the spawn/user-facing tools. The management tools (send_message,
//    list_agents, interrupt_agent, report) deliberately stay.
//  • The dispatch tool result is the child's FINAL REPORT TEXT (the `report`
//    tool when used, else the last assistant message) — bare, with no Dart
//    `[id state · Ns]` wrapper. The 30-minute timeout is a cloud-only pin and
//    lives on the tool (tools/subagentTools.ts).

import { messages, runs, sessionState, sessions, type Db } from "@ovid/db";

import { nativeToolsFor } from "./claudeCodeTools.js";
import type { AgentEngine } from "./engine.js";
import type {
  EventSink,
  HookEngine,
  HookStopResult,
  SessionAgentState,
  SessionStateStore,
} from "./ports.js";
import { presetById, type AgentPreset } from "./presets.js";
import { canonicalTools } from "./promptCache.js";
import { CHILD_DENIED_TOOLS, computeToolRoster } from "./roster.js";
import type { ToolContext, ToolRegistry, ToolSpec } from "./types.js";

/** Dart `_maxSubagentDepth` (AS:23048): root = 0, child = 1, grandchild = 2. */
export const MAX_SUBAGENT_DEPTH = 2;
/** Dart `_maxSubagentStopBlocks` (AS:24807). */
export const MAX_SUBAGENT_STOP_BLOCKS = 3;
/**
 * Dart `_maxConcurrentSubagents` (AS:23052), per owning ROOT. Children are
 * SEQUENTIAL per parent in cloud (a dispatch is awaited), so this is a
 * defence-in-depth guard rather than a reachable limit — the refusal string
 * is ported anyway so a future parallel fan-out cannot silently lose it.
 */
export const MAX_CONCURRENT_SUBAGENTS = 50;

/** The JSONB key holding the durable parent link on a child's agent state. */
export const SUBAGENT_PARENT_KEY = "subagentParentSessionId";

/**
 * The JSONB key holding outcomes the parent has not read yet.
 *
 * A detached child cannot return anything to the tool call that started it, so
 * it leaves its outcome here; the parent's loop reads and clears the list at
 * its next request and folds it into the volatile system block. Keeping it in
 * state rather than in `messages` is deliberate: a subagent report is agent
 * context, not a turn in the conversation, so it must never render as a chat
 * bubble.
 */
export const PENDING_SUBAGENT_REPORTS_KEY = "pendingSubagentReports";

/** How many unread reports a parent keeps before the oldest are dropped. */
export const MAX_PENDING_SUBAGENT_REPORTS = 20;

/** One child's outcome, as the parent will read it. */
export interface SubagentReport {
  childSessionId: string;
  childRunId: string;
  agentType: string;
  status: Exclude<ChildStatus, "running">;
  /** The child's final text, clipped to a bounded summary. */
  summary: string;
  /** The dispatch prompt, clipped — the parent's only reminder of the task. */
  task: string;
  at: number;
}

/**
 * The parent-facing summary, bounded by outcome.
 *
 * A child that finished is summarised in ~300 tokens: the parent needs to know
 * what was done, not how. A child that FAILED, was CANCELLED or hit an error
 * gets ~1,000 tokens instead, because the parent's next decision depends on
 * what went wrong — retry it, do it itself, or tell the user. The failure text
 * carries the run's own error plus whatever partial answer the child reached.
 *
 * A raw execution log never reaches the parent at either budget: the full log
 * stays in the child's workspace (`/workspace/.ovid/logs/subagent_{id}.log`)
 * and the parent can read it deliberately.
 */
export const REPORT_SUMMARY_LIMIT = 1200;
export const REPORT_FAILURE_LIMIT = 4000;

/**
 * Read and clear the parent's unread child reports.
 *
 * Clearing on read is what stops the same report being folded into every
 * later request. The window between the clear and the model call is a few
 * milliseconds; a run that dies inside it loses the note, and the child's work
 * is still in the trajectory — the alternative (never clearing) would repeat
 * fifty reports on every turn forever.
 */
export async function takePendingSubagentReports(
  state: SessionStateStore,
  sessionId: string,
): Promise<SubagentReport[]> {
  const raw = (await state.get(sessionId)) as unknown as Record<string, unknown>;
  const list = raw[PENDING_SUBAGENT_REPORTS_KEY];
  if (!Array.isArray(list) || list.length === 0) return [];
  const reports = (list as SubagentReport[]).filter(
    (r) => typeof r?.childSessionId === "string" && typeof r?.summary === "string",
  );
  await state.patch(sessionId, {
    [PENDING_SUBAGENT_REPORTS_KEY]: [],
  } as unknown as Partial<SessionAgentState>);
  return reports;
}

/**
 * The system block a parent reads before its next request.
 *
 * Written for a model, not a log: one line per child, the task it was given,
 * its status and its bounded summary. An empty summary is stated as such
 * rather than left blank, so "it finished and said nothing" is distinguishable
 * from "it is still running".
 */
export function formatSubagentReports(reports: readonly SubagentReport[]): string {
  const lines = reports.map((report) => {
    const task = report.task.replace(/\s+/g, " ").trim();
    const summary = report.summary.trim();
    return (
      `- ${report.childSessionId} (${report.agentType}) ${report.status}: ` +
      `${summary === "" ? "finished without a final answer" : summary}` +
      (task === "" ? "" : `\n  task: ${task}`)
    );
  });
  return (
    "Background subagents you dispatched have finished. Their results are " +
    "below.\n" +
    "Use them to answer the user. Do NOT dispatch these tasks again — the " +
    "work is already done; repeating it wastes the user's allowance.\n" +
    lines.join("\n")
  );
}

export function clipReport(
  text: string | null,
  limit: number = REPORT_SUMMARY_LIMIT,
): string {
  if (text === null) return "";
  const flat = text.trim();
  if (flat.length <= limit) return flat;
  return `${flat.slice(0, limit)}…`;
}

/** A child that did not simply finish earns the larger budget. */
export function isFailureStatus(status: Exclude<ChildStatus, "running">): boolean {
  return status === "failed" || status === "cancelled";
}

/**
 * The summary for one settled child.
 *
 * Success: the final answer, at the 300-token budget.
 *
 * Failure/cancel: a short header (status + the run's own error), then the
 * child's last text at the 1,000-token budget. The error goes FIRST because a
 * long partial answer would otherwise push it out of the window — and the
 * error is the part the parent must not miss.
 */
export function buildChildSummary(o: {
  status: Exclude<ChildStatus, "running">;
  answer: string | null;
  error: string | null;
}): string {
  if (!isFailureStatus(o.status)) return clipReport(o.answer);

  const head =
    o.status === "cancelled"
      ? "Stopped before finishing."
      : o.error !== null && o.error.trim() !== ""
        ? `Failed: ${o.error.trim()}`
        : "Failed without an error message.";
  const answer = clipReport(o.answer, REPORT_FAILURE_LIMIT);
  return answer === ""
    ? head
    : `${head}\n\nLast output before it ended:\n${answer}`;
}

export type ChildStatus = "running" | "completed" | "failed" | "cancelled";

export interface ChildHandle {
  sessionId: string;
  runId: string;
  parentSessionId: string;
  /** Owning root chat (Dart `_owningRoot`). */
  rootSessionId: string;
  /** 0-based depth of the child itself (parent.depth + 1). */
  depth: number;
  /** The dispatch prompt, verbatim (list_agents shows its first 80 chars). */
  prompt: string;
  agentType: string;
  startedAt: number;
  interrupt(reason: string): Promise<boolean>;
  sendMessage(text: string): Promise<void>;
  status(): ChildStatus;
  /** Final report text: the `report` tool when used, else the last answer. */
  result(): string | null;
  /**
   * Resolves when the child reaches a terminal status.
   *
   * `dispatch` returns while the child is still RUNNING, so this is the only
   * way to know it is done. The parent agent does not await it — it learns the
   * outcome from `subagent_completed` and the pending-report queue — but tests
   * and callers that genuinely need the end state can.
   */
  readonly settled: Promise<ChildStatus>;
}

export interface DispatchArgs {
  prompt: string;
  tools?: string[];
  disallowedTools?: string[];
  agentType?: string;
}

export interface SubagentSupervisor {
  dispatch(parent: ToolContext, args: DispatchArgs): Promise<ChildHandle>;
  childrenOf(sessionId: string): readonly ChildHandle[];
  /** The `report` tool's write path; false = unknown/foreign child session. */
  recordReport(sessionId: string, summary: string): boolean;
}

/** A refusal the dispatch tool renders as an ordinary tool error. */
export class SubagentRefusalError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SubagentRefusalError";
  }
}

// ── SubagentToolPolicy (port of subagent_tools.dart:25–136) ────────────────

/**
 * The stored form is the Dart `agentAllowedTools` encoding: allow entries
 * verbatim, deny entries `!`-prefixed. The CLOUD projection is EAGER (the
 * map's binding divergence): entries are expanded through nativeToolsFor, so
 * `Bash` becomes run_shell + the job_* family and `Grep(x*)` becomes fs_grep.
 * Patterns (`mcp__srv__*`, trailing `*`) stay patterns.
 *
 * `allow: []` means INHERIT EVERYTHING (minus the always-denied set), exactly
 * like Dart's `inheritsAll`.
 */
export function subagentToolPolicy(stored: readonly string[]): {
  allow: string[];
  deny: string[];
} {
  const allow: string[] = [];
  const deny: string[] = [];
  for (const raw of stored) {
    const entry = raw.trim();
    if (entry === "") continue;
    if (entry.startsWith("!")) {
      const denyEntry = entry.slice(1).trim();
      if (denyEntry === "") continue;
      for (const expanded of nativeToolsFor(denyEntry)) {
        if (!deny.includes(expanded)) deny.push(expanded);
      }
    } else {
      for (const expanded of nativeToolsFor(entry)) {
        if (!allow.includes(expanded)) allow.push(expanded);
      }
    }
  }
  return { allow, deny };
}

/** Does one expanded policy entry cover [name]? (Dart `entryMatches`.) */
function entryMatches(entry: string, name: string): boolean {
  if (entry === "*") return true;
  if (entry.endsWith("*") && entry.length > 1) {
    return name.startsWith(entry.slice(0, -1));
  }
  return entry === name;
}

/**
 * The policy gate applied ON TOP of the roster (Dart `SubagentToolPolicy.
 * allows`): always-denied/spawn tools never pass even when explicitly listed;
 * deny entries subtract; an empty allow list inherits.
 */
export function subagentPolicyAllows(
  name: string,
  policy: { allow: readonly string[]; deny: readonly string[] },
): boolean {
  if (CHILD_DENIED_TOOLS.has(name)) return false;
  if (policy.deny.some((entry) => entryMatches(entry, name))) return false;
  if (policy.allow.length === 0 || policy.allow.includes("*")) return true;
  return policy.allow.some((entry) => entryMatches(entry, name));
}

/**
 * Project the child's model-visible roster: parent tools minus
 * CHILD_DENIED_TOOLS (layer 2), then the persisted subagent policy.
 * Canonicalized so the child's cache prefix is byte-stable (Task 3).
 */
export function projectChildRoster(
  available: readonly ToolSpec[],
  policy: { allow: readonly string[]; deny: readonly string[] },
): ToolSpec[] {
  return canonicalTools(available.filter((spec) => subagentPolicyAllows(spec.name, policy)));
}

/** Build the persisted stored-list form from the dispatch args. */
export function storedSubagentTools(args: {
  tools?: readonly string[];
  disallowedTools?: readonly string[];
}): string[] {
  const stored: string[] = [];
  for (const entry of args.tools ?? []) {
    const trimmed = entry.trim();
    if (trimmed !== "") stored.push(trimmed);
  }
  for (const entry of args.disallowedTools ?? []) {
    const trimmed = entry.trim();
    if (trimmed === "") continue;
    stored.push(trimmed.startsWith("!") ? trimmed : `!${trimmed}`);
  }
  return stored;
}

// ── store seam (keeps the supervisor testable without a live Postgres) ─────

export type RunStatus = "queued" | "running" | "completed" | "failed" | "cancelled";

export interface SubagentStore {
  createChild(o: {
    parentSessionId: string;
    userId: string;
    title: string | null;
  }): Promise<{ sessionId: string }>;
  appendUserMessage(sessionId: string, content: string): Promise<{ messageId: string }>;
  createRun(o: { sessionId: string; promptMessageId: string }): Promise<{ runId: string }>;
  claimRun(runId: string): Promise<boolean>;
  runStatus(runId: string, userId: string): Promise<RunStatus | null>;
  /**
   * The run's own failure text (`runs.last_error`), or null.
   *
   * This is the "why" a parent needs when a child fails — without it the
   * failure report can only say that it failed.
   */
  runError(runId: string, userId: string): Promise<string | null>;
  /** True when the session has a queued or running run right now. */
  hasActiveRun(sessionId: string): Promise<boolean>;
  queuedRuns(
    sessionId: string,
  ): Promise<Array<{ runId: string; promptMessageId: string | null }>>;
  promptText(messageId: string): Promise<string | null>;
  lastAssistantText(sessionId: string): Promise<string | null>;
  /** Root → session chain, INCLUSIVE (Dart `lineageOf`), bounded 8 in cloud. */
  lineage(sessionId: string): Promise<string[]>;
  listChildren(parentSessionId: string, userId: string): Promise<string[]>;
  /** Leave a settled child's outcome for the parent's next request. */
  reportToParent(parentSessionId: string, report: SubagentReport): Promise<void>;
}

/**
 * The production store over the existing @ovid/db repos.
 *
 * DEVIATION (dispatched scope): the plan's `sessions.parentSessionId` /
 * `isSubagent` columns + `sessions.createChild/listChildren/lineage` are the
 * integration owner's migration; this task may only write agent-core files.
 * The durable link therefore lives in `session_agent_state.state` JSONB under
 * SUBAGENT_PARENT_KEY — the same row the state store already owns, atomic on
 * write and read back by `lineage`. Swapping this adapter for the dedicated
 * repo functions later is a one-file change.
 */
export function createDbSubagentStore(db: Db): SubagentStore {
  async function parentOf(sessionId: string): Promise<string | null> {
    const state = (await sessionState.get(db, sessionId)) as unknown as Record<
      string,
      unknown
    >;
    const parent = state[SUBAGENT_PARENT_KEY];
    return typeof parent === "string" && parent !== "" ? parent : null;
  }

  return {
    async createChild(o) {
      const row = await sessions.create(db, o.userId, o.title);
      // Persist the durable parent link. Cast: the JSONB row is intentionally
      // wider than SessionAgentStateJson (this key is the lineage seam).
      await sessionState.patch(db, row.id, {
        [SUBAGENT_PARENT_KEY]: o.parentSessionId,
      } as unknown as Parameters<typeof sessionState.patch>[2]);
      return { sessionId: row.id };
    },
    async appendUserMessage(sessionId, content) {
      const row = await messages.append(db, { sessionId, role: "user", content });
      return { messageId: row.id };
    },
    async createRun(o) {
      const row = await runs.create(db, o);
      return { runId: row.id };
    },
    async claimRun(runId) {
      return runs.claimNext(db, runId);
    },
    async runStatus(runId, userId) {
      const row = await runs.get(db, runId, userId);
      return row === null ? null : (row.status as RunStatus);
    },
    async runError(runId, userId) {
      const row = await runs.get(db, runId, userId);
      const error = row?.lastError;
      return typeof error === "string" && error.trim() !== "" ? error : null;
    },
    async hasActiveRun(sessionId) {
      return (await runs.activeForSession(db, sessionId)) !== null;
    },
    async queuedRuns(sessionId) {
      const rows = await runs.listQueuedForSession(db, sessionId);
      return rows.map((r) => ({ runId: r.id, promptMessageId: r.promptMessageId }));
    },
    async promptText(messageId) {
      const row = await messages.get(db, messageId);
      return row?.content ?? null;
    },
    async lastAssistantText(sessionId) {
      const { rows } = await messages.page(db, sessionId, { limit: 20 });
      // page() is newest-first; the final answer is the newest assistant row.
      const row = rows.find((r) => r.role === "assistant" && r.content.trim() !== "");
      return row?.content ?? null;
    },
    async lineage(sessionId) {
      // Dart lineageOf is root→session inclusive, walked with a seen-set. The
      // cloud bound (8) is a safety choice, not a parity value.
      const chain: string[] = [sessionId];
      let current = sessionId;
      for (let i = 0; i < 8; i += 1) {
        const parent = await parentOf(current);
        if (parent === null || chain.includes(parent)) break;
        chain.unshift(parent);
        current = parent;
      }
      return chain;
    },
    async reportToParent(parentSessionId, report) {
      const state = (await sessionState.get(db, parentSessionId)) as unknown as Record<
        string,
        unknown
      >;
      const existing = Array.isArray(state[PENDING_SUBAGENT_REPORTS_KEY])
        ? (state[PENDING_SUBAGENT_REPORTS_KEY] as SubagentReport[])
        : [];
      // Oldest dropped first: a parent that never reads its reports must not
      // grow its state row without bound.
      const next = [...existing, report].slice(-MAX_PENDING_SUBAGENT_REPORTS);
      await sessionState.patch(db, parentSessionId, {
        [PENDING_SUBAGENT_REPORTS_KEY]: next,
      } as unknown as Parameters<typeof sessionState.patch>[2]);
    },
    async listChildren(parentSessionId, userId) {
      // Only used by a cold-resume caller; the live registry is in-memory.
      const { rows } = await sessions.list(db, userId, 1000);
      const children: string[] = [];
      for (const row of rows) {
        if ((await parentOf(row.id)) === parentSessionId) children.push(row.id);
      }
      return children;
    },
  };
}

// ── supervisor ──────────────────────────────────────────────────────────────

export interface SubagentSupervisorDeps {
  engine: AgentEngine;
  db: Db;
  state: SessionStateStore;
  hooks: HookEngine;
  sinkFactory(sessionId: string): EventSink;
  /** The live registry — the source of the parent's available tools. */
  registry: ToolRegistry;
  /** Test seam; defaults to the @ovid/db-backed store above. */
  store?: SubagentStore;
  /** Composition flags (T16) — the same defaults as the loop when absent. */
  memoryEnabled?: boolean;
  githubConnected?: boolean;
  /** Wave 4 (SE-007): built-ins + the user's custom presets (absent = built-ins). */
  presets?: (id: string | null) => AgentPreset | null;
  now?: () => number;
  /**
   * Give a parent whose run already ended a new turn to read its reports.
   *
   * With 85 % of the work delegated, "the parent finishes before its children"
   * is the NORMAL case, not an edge one: it dispatches, runs out of things to
   * do, and ends its turn. Without this the child's report would sit unread
   * until the user happened to send another message.
   *
   * Absent → reports wait for the parent's next run (the previous behaviour).
   * The implementation must not start a run when the parent already has one:
   * that run will read the report itself at its next request.
   */
  wakeParent?: (o: {
    sessionId: string;
    userId: string;
    text: string;
  }) => Promise<void>;
}

class MutableChildHandle implements ChildHandle {
  readonly sessionId: string;
  runId: string;
  readonly parentSessionId: string;
  readonly rootSessionId: string;
  readonly depth: number;
  readonly prompt: string;
  readonly agentType: string;
  readonly startedAt: number;

  private state: ChildStatus = "running";
  private reportText: string | null = null;
  private lastText: string | null = null;
  private interrupted = false;
  private readonly interruptFn: (reason: string) => Promise<boolean>;
  private readonly sendFn: (text: string) => Promise<void>;
  private settleResolve: (status: ChildStatus) => void = () => {};
  readonly settled: Promise<ChildStatus> = new Promise<ChildStatus>((resolve) => {
    this.settleResolve = resolve;
  });

  constructor(o: {
    sessionId: string;
    runId: string;
    parentSessionId: string;
    rootSessionId: string;
    depth: number;
    prompt: string;
    agentType: string;
    startedAt: number;
    interrupt: (reason: string) => Promise<boolean>;
    sendMessage: (text: string) => Promise<void>;
  }) {
    this.sessionId = o.sessionId;
    this.runId = o.runId;
    this.parentSessionId = o.parentSessionId;
    this.rootSessionId = o.rootSessionId;
    this.depth = o.depth;
    this.prompt = o.prompt;
    this.agentType = o.agentType;
    this.startedAt = o.startedAt;
    this.interruptFn = o.interrupt;
    this.sendFn = o.sendMessage;
  }

  interrupt(reason: string): Promise<boolean> {
    return this.interruptFn(reason);
  }

  sendMessage(text: string): Promise<void> {
    return this.sendFn(text);
  }

  status(): ChildStatus {
    return this.state;
  }

  result(): string | null {
    return this.reportText ?? this.lastText;
  }

  // ── supervisor-internal ────────────────────────────────────────────────
  setStatus(status: ChildStatus): void {
    this.state = status;
    if (status !== "running") this.settleResolve(status);
  }

  setReport(text: string): void {
    this.reportText = text;
  }

  setLastText(text: string | null): void {
    this.lastText = text;
  }

  isInterrupted(): boolean {
    return this.interrupted;
  }

  markInterrupted(): void {
    this.interrupted = true;
  }
}

function depthRefusal(): SubagentRefusalError {
  return new SubagentRefusalError(
    `Subagent depth limit (${MAX_SUBAGENT_DEPTH}) reached — ` +
      "do the task yourself with the tools you have.",
  );
}

function subagentParentRefusal(): SubagentRefusalError {
  return new SubagentRefusalError(
    "SUBAGENT: a subagent cannot dispatch subagents — you are one. " +
      "Do the task yourself with the tools you have, or report back to " +
      "your parent with what you need.",
  );
}

function concurrencyRefusal(tool: string): SubagentRefusalError {
  return new SubagentRefusalError(
    `${tool} refused: the subagent ceiling (${MAX_CONCURRENT_SUBAGENTS} running ` +
      "at once per root session) is reached. Wait for a running subagent to finish " +
      "(list_agents shows them), interrupt one you no longer need, or do this " +
      "task yourself — do not retry in a loop.",
  );
}

function firstLine(text: string, max: number): string {
  const line = text.split(/\r?\n/, 1)[0]?.trim() ?? "";
  return line.length <= max ? line : `${line.slice(0, max)}…`;
}

function clip(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max)}…`;
}

const DEFAULT_STOP_REASON =
  "[system] Continue working on the task; do not repeat your last message verbatim.";

export function createSubagentSupervisor(deps: SubagentSupervisorDeps): SubagentSupervisor {
  /**
   * One wake attempt at a time, per parent session.
   *
   * Children that finish together (three `sleep 20` tasks, say) settle within
   * the same millisecond. Without this chain each of them would see "no active
   * run", and each would start one — three wake runs for one batch of reports.
   * Serialising makes the second attempt observe the run the first created and
   * stand down.
   */
  const wakeChains = new Map<string, Promise<void>>();

  async function wakeParentOnce(o: {
    sessionId: string;
    userId: string;
    text: string;
  }): Promise<void> {
    const previous = wakeChains.get(o.sessionId) ?? Promise.resolve();
    const next = previous
      .then(async () => {
        if (deps.wakeParent === undefined) return;
        // Re-checked inside the chain: a sibling may have just started one.
        if (await store.hasActiveRun(o.sessionId)) return;
        await deps.wakeParent(o);
      })
      .catch(() => {
        // A failed wake must not fail the child: the report is already durable
        // in the parent's state and the parent's next run will read it.
      });
    wakeChains.set(o.sessionId, next);
    await next;
    if (wakeChains.get(o.sessionId) === next) wakeChains.delete(o.sessionId);
  }
  const store = deps.store ?? createDbSubagentStore(deps.db);
  const now = deps.now ?? Date.now;
  const handles: MutableChildHandle[] = [];

  function findHandle(sessionId: string): MutableChildHandle | undefined {
    return handles.find((h) => h.sessionId === sessionId);
  }

  function childrenOf(sessionId: string): readonly ChildHandle[] {
    return handles.filter((h) => h.parentSessionId === sessionId);
  }

  /**
   * One durable turn of the child loop: append the user row, create + claim
   * the run. Returns the run id. The prompt row is persisted HERE (the loop
   * never re-appends — loop.ts's history comment).
   */
  async function startTurn(
    sessionId: string,
    prompt: string,
  ): Promise<{ runId: string; messageId: string }> {
    const message = await store.appendUserMessage(sessionId, prompt);
    const run = await store.createRun({
      sessionId,
      promptMessageId: message.messageId,
    });
    await store.claimRun(run.runId);
    return { runId: run.runId, messageId: message.messageId };
  }

  async function fireSubagentStop(
    handle: MutableChildHandle,
    lastAssistantMessage: string,
    stopBlocks: number,
  ): Promise<HookStopResult> {
    try {
      return await deps.hooks.fireStop(
        handle.sessionId,
        {
          agent_id: handle.sessionId,
          agent_type: handle.agentType,
          agent_transcript_path: "",
          transcript_path: "",
          last_assistant_message: lastAssistantMessage,
          stop_hook_active: stopBlocks > 0,
          subagentId: handle.sessionId,
          parentSessionId: handle.parentSessionId,
          state: handle.status(),
          interrupted: handle.isInterrupted(),
          result: clip(handle.result() ?? lastAssistantMessage, 400),
        },
        "subagent_stop",
      );
    } catch {
      // A broken hook must NEVER wedge a settled child (Dart fail-open).
      return { veto: false };
    }
  }

  return {
    async dispatch(parent: ToolContext, args: DispatchArgs): Promise<ChildHandle> {
      const prompt = (args.prompt ?? "").trim();
      if (prompt === "") throw new SubagentRefusalError("prompt is required");

      // ── B20 precedence: durable LINEAGE depth FIRST ────────────────────
      // `parent.depth` is the live loop's value; the durable chain is the
      // escape-proof source. Take the larger so neither can under-report.
      // A lineage read failure is the B20 "lineage unavailable" case: fall
      // back to the live depth + the isSubagent backstop.
      let chain: string[] = [];
      try {
        chain = await store.lineage(parent.sessionId);
      } catch {
        chain = [];
      }
      const lineageDepth = Math.max(0, chain.length - 1);
      const depth = Math.max(lineageDepth, parent.depth);
      if (depth >= MAX_SUBAGENT_DEPTH) throw depthRefusal();
      // Layer 3: a subagent parent (depth 1 in the real flow) may not spawn.
      if (parent.isSubagent) throw subagentParentRefusal();

      const rootSessionId = chain[0] ?? parent.sessionId;
      // A parent that was already stopped must not start new work (the
      // dispatch call can outlive a Stop that landed between turns).
      if (parent.signal.aborted) {
        throw new SubagentRefusalError("parent run is cancelled");
      }
      const liveForRoot = handles.filter(
        (h) => h.rootSessionId === rootSessionId && h.status() === "running",
      ).length;
      if (liveForRoot >= MAX_CONCURRENT_SUBAGENTS) {
        throw concurrencyRefusal("dispatch_agent");
      }

      const agentType = (args.agentType ?? "").trim() || "general-purpose";
      const policy = subagentToolPolicy(
        storedSubagentTools({ tools: args.tools, disallowedTools: args.disallowedTools }),
      );
      // The child inherits the PARENT'S roster (mode/preset/skill scopes),
      // then loses CHILD_DENIED_TOOLS + the subagent policy's deny set.
      const parentState = await deps.state.get(parent.sessionId);
      const parentRoster = computeToolRoster(
        {
          mode: parent.mode,
          planMode: parent.planMode,
          isSubagent: parent.isSubagent,
          memoryEnabled: deps.memoryEnabled ?? true,
          githubConnected: deps.githubConnected ?? true,
          preset: (deps.presets ?? presetById)(parentState.presetId),
          activeSkillScopes: parentState.activeSkillScopes,
        },
        deps.registry.all().map((tool) => tool.spec),
      );
      const roster = projectChildRoster(parentRoster, policy);

      // ── child session + run row (durable BEFORE the start event) ──────
      const child = await store.createChild({
        parentSessionId: parent.sessionId,
        userId: parent.userId,
        title: `subagent: ${clip(prompt.replace(/\s+/g, " "), 60)}`,
      });
      // T8 C1: a child is born planMode:false — NEVER inherit the parent's
      // plan flag. A fresh session's zero state already satisfies this; force
      // it defensively so a reused/cold-resumed row cannot leak the gate.
      const childState = await deps.state.get(child.sessionId);
      if (childState.planMode) {
        await deps.state.patch(child.sessionId, { planMode: false });
      }
      const first = await startTurn(child.sessionId, prompt);

      const handle = new MutableChildHandle({
        sessionId: child.sessionId,
        runId: first.runId,
        parentSessionId: parent.sessionId,
        rootSessionId,
        depth: depth + 1,
        prompt,
        agentType,
        startedAt: now(),
        interrupt: async (reason: string) => {
          if (handle.status() !== "running") return false;
          handle.markInterrupted();
          return deps.engine.cancel(child.sessionId, reason);
        },
        sendMessage: async (text: string) => {
          // Route to the LIVE loop: append + queue; the loop's steering drain
          // claims it at its next step boundary. Never start a second run.
          if (handle.status() !== "running") return;
          await startTurn(child.sessionId, text);
        },
      });
      handles.push(handle);

      const parentSink = deps.sinkFactory(parent.sessionId);
      await parentSink.emit("subagent_started", {
        runId: parent.runId,
        childSessionId: child.sessionId,
        childRunId: first.runId,
        prompt: prompt.slice(0, 200),
        // Wave 1b (additive): the live activity card's name.
        agentType,
      });

      // ── detached settle ────────────────────────────────────────────────
      // `dispatch` returns NOW, with the child already running. The parent can
      // issue its next dispatch immediately, which is the whole point: with an
      // awaited dispatch a parent could never have two children alive, so the
      // MAX_CONCURRENT_SUBAGENTS guard was unreachable decoration.
      //
      // The outcome reaches the parent through two channels, never through
      // this tool call's return value:
      //   • `subagent_completed` on the parent's sink (the live timeline), and
      //   • a bounded report queued in the parent's agent state, which the
      //     parent's loop folds into its next request.
      // Both happen even if the parent's own run has already ended.
      void (async (): Promise<void> => {
        // Parent cancel cascades (p2_subagent_races parity). The listener is
        // removed when the child settles so a long-lived signal never leaks.
        const onParentAbort = (): void => {
          void deps.engine
            .cancel(child.sessionId, "parent run cancelled")
            .catch(() => {});
        };
        if (parent.signal.aborted) onParentAbort();
        else parent.signal.addEventListener("abort", onParentAbort, { once: true });

        let runId = first.runId;
        let currentPrompt = prompt;
        let stopBlocks = 0;
        let finalStatus: ChildStatus = "running";
        /** The run's own error, kept for the failure report. */
        let runError: string | null = null;

        try {
          for (;;) {
            if (parent.signal.aborted) {
              finalStatus = "cancelled";
              break;
            }
            await deps.engine.run({
              runId,
              sessionId: child.sessionId,
              userId: parent.userId,
              prompt: currentPrompt,
              mode: parent.mode,
              isSubagent: true,
              depth: depth + 1,
              subagentBriefing: prompt,
              roster,
            });

            const runStatus = await store.runStatus(runId, parent.userId);

            // Read the child's latest answer on EVERY terminal path, including
            // failure. A failed child has usually done part of the work, and
            // that partial output is exactly what the parent needs to decide
            // whether to retry, finish it itself, or tell the user. Reading it
            // only on success threw it away.
            const answer = await store.lastAssistantText(child.sessionId);
            handle.setLastText(answer);

            if (runStatus === "cancelled" || handle.isInterrupted()) {
              finalStatus = "cancelled";
              break;
            }
            if (runStatus === "failed") {
              finalStatus = "failed";
              // The reason the parent will read. A missing one is possible
              // (older rows, an engine that terminalized without a message).
              runError = await store.runError(runId, parent.userId).catch(() => null);
              break;
            }

            // ── natural stop → [CC] SubagentStop gate (≤3 blocks) ─────────
            const stop = await fireSubagentStop(
              handle,
              answer ?? "",
              stopBlocks,
            );
            if (stop.veto && stopBlocks < MAX_SUBAGENT_STOP_BLOCKS) {
              stopBlocks += 1;
              currentPrompt =
                stop.reason !== null && stop.reason.trim() !== ""
                  ? stop.reason
                  : DEFAULT_STOP_REASON;
              const next = await startTurn(child.sessionId, currentPrompt);
              runId = next.runId;
              continue;
            }

            // ── follow-up that arrived AFTER the final drain ─────────────
            const queued = await store.queuedRuns(child.sessionId);
            const next = queued[0];
            if (next !== undefined) {
              await store.claimRun(next.runId);
              currentPrompt =
                next.promptMessageId !== null
                  ? ((await store.promptText(next.promptMessageId)) ?? "")
                  : "";
              runId = next.runId;
              continue;
            }

            finalStatus = "completed";
            break;
          }
        } catch {
          // Run-level failures are the engine's terminal states; an escape here
          // is infrastructure — the child still settles as failed rather than
          // leaving a handle stuck in "running" forever.
          finalStatus = "failed";
        } finally {
          parent.signal.removeEventListener("abort", onParentAbort);
        }

        // TypeScript proves the loop above cannot leave "running" behind, so
        // the narrowing is a plain assignment rather than a defensive branch.
        const settledStatus = finalStatus as Exclude<ChildStatus, "running">;
        // Success gets ~300 tokens; a failure or a stop gets ~1,000 and leads
        // with the reason, so the parent can decide what to do next.
        const summary = buildChildSummary({
          status: settledStatus,
          answer: handle.result(),
          error: runError,
        });

        await parentSink.emit("subagent_completed", {
          childRunId: first.runId,
          status: settledStatus,
          childSessionId: child.sessionId,
          agentType,
          summary,
        });

        // The parent's loop reads this at its next request. A failure here is
        // not the child's failure: the run already settled and the event went
        // out, so it is logged and dropped rather than retried into a loop.
        try {
          await store.reportToParent(parent.sessionId, {
            childSessionId: child.sessionId,
            childRunId: first.runId,
            agentType,
            status: settledStatus,
            summary,
            task: clipReport(prompt),
            at: now(),
          });
        } catch {
          // Swallowed deliberately — see above.
        }

        // ── wake the parent if its turn is already over ───────────────────
        // The parent's loop folds pending reports in at every model request,
        // so a running parent needs nothing. A parent that has ended has no
        // next request — and with most work delegated, that is the common
        // case, not the rare one.
        if (deps.wakeParent !== undefined) {
          await wakeParentOnce({
            sessionId: parent.sessionId,
            userId: parent.userId,
            // The report itself. The parent's loop injects everything pending
            // into its next request, so a wake that starts a little late still
            // carries every report in the batch, not just this child's.
            text: formatSubagentReports([
              {
                childSessionId: child.sessionId,
                childRunId: first.runId,
                agentType,
                status: settledStatus,
                summary,
                task: clipReport(prompt),
                at: now(),
              },
            ]),
          });
        }

        // LAST: `settled` means "done AND reported", so a caller that awaits
        // it can read the report the parent will read. Setting the status
        // earlier would resolve the promise before the report existed.
        handle.setStatus(settledStatus);
      })();

      return handle;
    },

    childrenOf(sessionId: string): readonly ChildHandle[] {
      return childrenOf(sessionId);
    },

    recordReport(sessionId: string, summary: string): boolean {
      const handle = findHandle(sessionId);
      if (handle === undefined) return false;
      handle.setReport(summary);
      return true;
    },
  };
}

/** `list_agents` line: status + the first 80 chars of the prompt. */
export function renderChildLine(handle: ChildHandle): string {
  return `${handle.sessionId} [${handle.status()}] · ${firstLine(handle.prompt, 80)}`;
}
