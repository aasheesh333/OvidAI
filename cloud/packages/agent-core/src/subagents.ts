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
//    `[id state · Ns]` wrapper. The dispatch tool's timeout is aligned with
//    the 8-hour child budget (tools/subagentTools.ts) so the parent call can
//    never end while a legitimate child is still working.
//  • The 50-subagent ceiling is a LIFETIME TOTAL per root session, not a
//    count of active children: the durable store is the source of truth and
//    an in-memory counter only short-circuits the read once the ceiling is
//    known to be reached. Nothing frees a slot when a child finishes.
//  • A settled child owns no live sandbox resources: every settle path
//    (success, timeout, cancel, error) kills the child's background jobs and
//    in-flight exec calls before the dispatch returns.

import { messages, runs, sessionState, sessions, type Db } from "@ovid/db";

import { nativeToolsFor } from "./claudeCodeTools.js";
import type { AgentEngine } from "./engine.js";
import type {
  EventSink,
  HookEngine,
  HookStopResult,
  SandboxPort,
  SessionStateStore,
} from "./ports.js";
import { presetById, type AgentPreset } from "./presets.js";
import { canonicalTools } from "./promptCache.js";
import {
  computeToolRoster,
  isChildHardDeniedTool,
  isChildSensitiveTool,
} from "./roster.js";
import {
  clampSubagentLogTailLines,
  createSubagentLog,
  readSubagentLogTail,
  SUBAGENT_LOG_DIR,
  type SubagentLog,
  type CreateSubagentLogOptions,
  type SubagentLogReader,
  type SubagentLogTail,
} from "./subagentLog.js";
import {
  buildSubagentSummary,
  serializeSubagentSummary,
  type SubagentSummary,
  type SubagentSummaryStatus,
} from "./subagentSummary.js";
import type { ToolContext, ToolRegistry, ToolSpec } from "./types.js";

/** Dart `_maxSubagentDepth` (AS:23048): root = 0, child = 1, grandchild = 2. */
export const MAX_SUBAGENT_DEPTH = 2;
/** Dart `_maxSubagentStopBlocks` (AS:24807). */
export const MAX_SUBAGENT_STOP_BLOCKS = 3;
/**
 * SI spec §9: at most 50 subagents may be created under one ROOT session for
 * the whole life of that session. This is a TOTAL, not a concurrency cap: a
 * child that completes, fails, is cancelled or times out does NOT free a
 * slot. The 51st dispatch is refused with a typed SubagentLimitError — never
 * silently dropped. The durable store is the source of truth (so the count
 * survives worker restarts and is shared between dispatchers); the in-memory
 * cache is only a fast path in front of it. Kept under the old name for
 * callers that imported it.
 */
export const MAX_SUBAGENTS_PER_ROOT = 50;
export const MAX_CONCURRENT_SUBAGENTS = MAX_SUBAGENTS_PER_ROOT;
/** SI spec §9: a subagent may be active for at most 8 hours. */
export const DEFAULT_SUBAGENT_MAX_RUNTIME_MS = 8 * 60 * 60 * 1000;

/** The JSONB key holding the durable parent link on a child's agent state. */
export const SUBAGENT_PARENT_KEY = "subagentParentSessionId";

/** The main agent's on-demand log reader tool (never offered to a child). */
export const READ_SUBAGENT_LOG_TOOL_NAME = "read_subagent_log";

/**
 * Tools only a MAIN agent may call. Kept separate from CHILD_DENIED_TOOLS
 * (roster.ts) so this module can enforce the child-side denial without
 * widening the roster contract: `projectChildRoster` strips them even when a
 * dispatch policy explicitly lists them, and the tool itself re-checks
 * `ctx.isSubagent` at execution time (the no-nesting backstop).
 */
export const MAIN_AGENT_ONLY_TOOLS: ReadonlySet<string> = new Set([
  READ_SUBAGENT_LOG_TOOL_NAME,
]);

export type ChildStatus = "running" | "completed" | "failed" | "cancelled" | "timeout";

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
  /**
   * The dispatch result: ALWAYS the strict five-key JSON summary (SI spec §9),
   * serialized. Never the child's transcript. Use `rawResult()` internally for
   * the pre-contract text.
   */
  result(): string | null;
  /** The last report/assistant text before summary serialization (internal). */
  rawResult(): string | null;
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
  /**
   * Read the bounded tail of a child's append-only log (the main agent's
   * `read_subagent_log` tool). Bounded by construction: default 200 lines,
   * hard cap 2,000, truncation marker when anything was omitted. The ACCESS
   * check (main agent only, child of the calling session) lives in the tool;
   * this seam only reads.
   */
  readLog(childSessionId: string, options?: { tailLines?: number }): Promise<SubagentLogTail>;
}

/** A refusal the dispatch tool renders as an ordinary tool error. */
export class SubagentRefusalError extends Error {
  /** Stable machine-readable discriminator (typed errors, never bare text). */
  readonly code: string;

  constructor(message: string, code = "subagent_refused") {
    super(message);
    this.name = "SubagentRefusalError";
    this.code = code;
  }
}

/** The subagent ceiling (SI spec §9): 50 TOTAL children per root session. */
export class SubagentLimitError extends SubagentRefusalError {
  readonly rootSessionId: string;
  readonly limit: number;

  constructor(rootSessionId: string, limit: number) {
    super(
      `dispatch_agent refused: the subagent ceiling (${limit} total per root ` +
        "session) is reached. This cap counts every subagent ever created " +
        "under this chat, not just the running ones — start a new chat for " +
        "more delegation or do this task yourself. Do not retry in a loop.",
      "subagent_limit_exceeded",
    );
    this.name = "SubagentLimitError";
    this.rootSessionId = rootSessionId;
    this.limit = limit;
  }
}

/** A subagent run tried to dispatch another subagent (SI spec §9). */
export class SubagentNestedError extends SubagentRefusalError {
  constructor() {
    super(
      "SUBAGENT: a subagent cannot dispatch subagents — you are one. " +
        "Do the task yourself with the tools you have, or report back to " +
        "your parent with what you need.",
      "subagent_nested",
    );
    this.name = "SubagentNestedError";
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
 * allows`): always-denied/spawn/scheduler tools and main-agent-only tools
 * never pass even when explicitly listed; deny entries subtract; an empty
 * allow list inherits — EXCEPT the credential/egress class, which is
 * default-deny and opens only to an explicit name/pattern allow.
 */
export function subagentPolicyAllows(
  name: string,
  policy: { allow: readonly string[]; deny: readonly string[] },
): boolean {
  if (isChildHardDeniedTool(name)) return false;
  if (MAIN_AGENT_ONLY_TOOLS.has(name)) return false;
  if (policy.deny.some((entry) => entryMatches(entry, name))) return false;
  // A bare `*` is inheritance, not a credential grant: only an explicit
  // (non-wildcard) entry re-admits a sensitive tool.
  const explicitlyAllowed = policy.allow.some(
    (entry) => entry !== "*" && entryMatches(entry, name),
  );
  if (isChildSensitiveTool(name) && !explicitlyAllowed) return false;
  if (policy.allow.length === 0 || policy.allow.includes("*")) return true;
  return explicitlyAllowed;
}

/**
 * Project the child's model-visible roster: parent tools minus
 * CHILD_DENIED_TOOLS (layer 2) — plus the main-agent-only set, denied by the
 * same policy gate — then the persisted subagent policy. Canonicalized so the
 * child's cache prefix is byte-stable (Task 3).
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
  queuedRuns(
    sessionId: string,
  ): Promise<Array<{ runId: string; promptMessageId: string | null }>>;
  promptText(messageId: string): Promise<string | null>;
  lastAssistantText(sessionId: string): Promise<string | null>;
  /** Root → session chain, INCLUSIVE (Dart `lineageOf`), bounded 8 in cloud. */
  lineage(sessionId: string): Promise<string[]>;
  listChildren(parentSessionId: string, userId: string): Promise<string[]>;
  /**
   * The DURABLE lifetime total of children created under [rootSessionId].
   * This is the source of truth for the 50-per-root ceiling: it is never
   * decremented when a child settles, so sequential dispatch cannot mint
   * fresh slots. No nesting is possible (a child cannot dispatch), so the
   * direct children of the root are every subagent the root ever created.
   */
  countChildrenUnderRoot(rootSessionId: string, userId: string): Promise<number>;
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

  async function childrenOf(
    parentSessionId: string,
    userId: string,
  ): Promise<string[]> {
    // Only used by a cold-resume caller; the live registry is in-memory.
    const { rows } = await sessions.list(db, userId, 1000);
    const children: string[] = [];
    for (const row of rows) {
      if ((await parentOf(row.id)) === parentSessionId) children.push(row.id);
    }
    return children;
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
    async listChildren(parentSessionId, userId) {
      return childrenOf(parentSessionId, userId);
    },
    async countChildrenUnderRoot(rootSessionId, userId) {
      // The row scan is bounded at 1000 — far above the 50-per-root ceiling,
      // so it can never under-count a root that is at (or near) the cap.
      return (await childrenOf(rootSessionId, userId)).length;
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
  /** SI spec §9 hard runtime cap per subagent (default 8 h). */
  maxRuntimeMs?: number;
  /** SI spec §9 TOTAL-subagent cap per root (default 50; test seam). */
  maxSubagents?: number;
  /**
   * Sandbox seam. When provided, a settled child's background jobs and
   * in-flight exec calls are killed on EVERY settle path (success, timeout,
   * cancel, error) — an engine cancel alone only aborts the model transport,
   * it does not stop detached sandbox work.
   */
  sandbox?: SandboxPort | null;
  /** Log directory (default /workspace/.ovid/logs; tests inject a temp dir). */
  logDir?: string;
  /**
   * Integration seam: replace the default host-filesystem writer with one
   * that writes through the sandbox (the spec path lives INSIDE the jail).
   */
  logFactory?: (options: CreateSubagentLogOptions) => Promise<SubagentLog>;
  /**
   * Read seam, the counterpart of `logFactory`: a sandbox-backed writer must
   * be paired with a sandbox-backed reader or `read_subagent_log` will look
   * on the worker host. Defaults to `readSubagentLogTail` over `logDir`.
   */
  logReader?: SubagentLogReader;
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
  private summaryJson: string | null = null;
  private summaryValue: SubagentSummary | null = null;
  private interrupted = false;
  private readonly interruptFn: (reason: string) => Promise<boolean>;
  private readonly sendFn: (text: string) => Promise<void>;

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
    return this.summaryJson ?? this.reportText ?? this.lastText;
  }

  rawResult(): string | null {
    return this.reportText ?? this.lastText;
  }

  summary(): SubagentSummary | null {
    return this.summaryValue;
  }

  // ── supervisor-internal ────────────────────────────────────────────────
  setStatus(status: ChildStatus): void {
    this.state = status;
  }

  setSummary(summary: SubagentSummary): void {
    this.summaryValue = summary;
    this.summaryJson = serializeSubagentSummary(summary);
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
    "subagent_depth_exceeded",
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

/**
 * How long a cancelled/timed-out child's engine run may take to unwind before
 * its sandbox resources are killed. Bounded so a wedged transport can never
 * hold the parent's dispatch call open.
 */
const CHILD_CANCEL_GRACE_MS = 5_000;

export function createSubagentSupervisor(deps: SubagentSupervisorDeps): SubagentSupervisor {
  const store = deps.store ?? createDbSubagentStore(deps.db);
  const now = deps.now ?? Date.now;
  const handles: MutableChildHandle[] = [];
  const maxRuntimeMs = deps.maxRuntimeMs ?? DEFAULT_SUBAGENT_MAX_RUNTIME_MS;
  const maxSubagents = deps.maxSubagents ?? MAX_SUBAGENTS_PER_ROOT;
  /**
   * rootSessionId → a LIFETIME total of children created under it. This is an
   * in-memory cache IN FRONT of the durable store count (`slotCounts`), never
   * the source of truth: a worker restart loses the cache and re-reads the
   * store, and a second dispatcher sharing the same store still sees the
   * total. Nothing decrements it when a child settles — the cap is on TOTAL
   * subagents per session, not on active ones.
   *
   * `slotLocks` serializes check-and-increment per root so parallel
   * dispatches cannot both observe 49 and race past the ceiling.
   */
  const slotCounts = new Map<string, number>();
  const slotLocks = new Map<string, Promise<void>>();

  function withRootLock<T>(rootSessionId: string, fn: () => Promise<T>): Promise<T> {
    const previous = slotLocks.get(rootSessionId) ?? Promise.resolve();
    const run = previous.then(fn, fn);
    const tail = run.then(
      () => undefined,
      () => undefined,
    );
    slotLocks.set(rootSessionId, tail);
    void tail.then(() => {
      if (slotLocks.get(rootSessionId) === tail) slotLocks.delete(rootSessionId);
    });
    return run;
  }

  /** Reserve one of the root's 50 lifetime slots; false = ceiling reached. */
  function reserveSlot(rootSessionId: string, userId: string): Promise<boolean> {
    return withRootLock(rootSessionId, async () => {
      const cached = slotCounts.get(rootSessionId) ?? 0;
      // Fast path: the cache already proves the ceiling is reached; skip the
      // durable read (the common refusal path).
      if (cached >= maxSubagents) return false;
      // Slow path: the durable count is authoritative — it survives restarts
      // and is shared by every dispatcher for this root.
      const durable = await store.countChildrenUnderRoot(rootSessionId, userId);
      const total = Math.max(cached, durable);
      if (total >= maxSubagents) {
        slotCounts.set(rootSessionId, total);
        return false;
      }
      slotCounts.set(rootSessionId, total + 1);
      return true;
    });
  }

  /**
   * Give a reservation back when NO child was created (an infrastructure
   * failure before `store.createChild`). A created child keeps its slot even
   * if the run then fails: the durable row exists, so the total is real.
   */
  function unreserveSlot(rootSessionId: string): Promise<void> {
    return withRootLock(rootSessionId, async () => {
      const current = slotCounts.get(rootSessionId) ?? 0;
      if (current <= 1) slotCounts.delete(rootSessionId);
      else slotCounts.set(rootSessionId, current - 1);
    });
  }

  /**
   * Sandbox resources (background jobs + in-flight exec calls) started by one
   * child. The child's event stream is the only place these ids appear: the
   * loop emits `tool_started` with `runId`+`callId` (the sandbox callKey is
   * `${runId}:${callId}`) and `tool_completed` with the job_start/job_kill
   * result text that carries the job id.
   */
  interface ChildResources {
    calls: Set<string>;
    jobs: Set<string>;
    /**
     * Set once the child has settled and its resources were killed. Late
     * events (an engine that ignores a cancel for longer than the grace) are
     * killed IMMEDIATELY instead of being tracked, so nothing outlives the
     * dispatch call.
     */
    settled: boolean;
  }

  const childResources = new Map<string, ChildResources>();

  function resourcesOf(sessionId: string): ChildResources {
    let resources = childResources.get(sessionId);
    if (resources === undefined) {
      resources = { calls: new Set(), jobs: new Set(), settled: false };
      childResources.set(sessionId, resources);
    }
    return resources;
  }

  /**
   * Kill everything the child started in the sandbox. Idempotent: the sets
   * are cleared first, so a later backstop call has nothing left to do.
   * `drop` removes the bookkeeping entirely (the child is fully settled).
   */
  async function killChildResources(
    childSessionId: string,
    userId: string,
    drop = false,
  ): Promise<void> {
    const resources = childResources.get(childSessionId);
    if (resources === undefined) return;
    const calls = [...resources.calls];
    const jobs = [...resources.jobs];
    resources.calls.clear();
    resources.jobs.clear();
    resources.settled = true;
    if (drop) childResources.delete(childSessionId);
    const sandbox = deps.sandbox ?? null;
    if (sandbox === null) return;
    await Promise.allSettled([
      ...calls.map((callKey) => sandbox.killCall(userId, callKey)),
      ...jobs.map((jobId) => sandbox.jobKill(userId, jobId)),
    ]);
  }

  /**
   * The child's log observer + resource tracker. The engine persists the
   * event first and then mirrors it here; message deltas are coalesced out
   * (the completed message carries the same text), everything else —
   * including full tool output — is appended verbatim so the log is the
   * complete audit trail. Tracking runs even when logging is unavailable.
   */
  function childSink(
    log: SubagentLog | null,
    resources: ChildResources,
    userId: string,
  ): EventSink {
    const sandbox = deps.sandbox ?? null;
    const killNow = (kill: Promise<void>): void => {
      void kill.catch(() => {});
    };
    return {
      async emit(type, payload) {
        if (type === "tool_started") {
          const runId = payload["runId"];
          const callId = payload["callId"];
          if (typeof runId === "string" && typeof callId === "string") {
            const callKey = `${runId}:${callId}`;
            if (resources.settled) {
              if (sandbox !== null) killNow(sandbox.killCall(userId, callKey));
            } else {
              resources.calls.add(callKey);
            }
          }
        } else if (type === "tool_completed") {
          const runId = payload["runId"];
          const callId = payload["callId"];
          if (typeof runId === "string" && typeof callId === "string") {
            resources.calls.delete(`${runId}:${callId}`);
          }
          const name = payload["name"];
          const content = payload["content"];
          if (typeof content === "string") {
            if (name === "job_start") {
              const match = /^job (\S+) started\b/.exec(content);
              if (match !== null) {
                if (resources.settled && sandbox !== null) {
                  killNow(sandbox.jobKill(userId, match[1]!));
                } else {
                  resources.jobs.add(match[1]!);
                }
              }
            } else if (name === "job_kill") {
              const match = /^job (\S+) killed\b/.exec(content);
              if (match !== null) resources.jobs.delete(match[1]!);
            }
          }
        }
        if (type === "message_delta") return;
        await log?.append({ type, ...payload });
      },
    };
  }

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
          result: clip(handle.rawResult() ?? lastAssistantMessage, 400),
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
      // SI spec §9: a subagent can NEVER dispatch another subagent. The flag is
      // the live contract; depth/lineage are escape-proof backstops in case a
      // caller constructs a child context with isSubagent=false.
      if (parent.isSubagent || parent.depth >= 1 || lineageDepth >= 1) {
        throw new SubagentNestedError();
      }

      const rootSessionId = chain[0] ?? parent.sessionId;
      // A parent that was already stopped must not start new work (the
      // dispatch call can outlive a Stop that landed between turns).
      if (parent.signal.aborted) {
        throw new SubagentRefusalError("parent run is cancelled");
      }

      // Hard ceiling: 50 TOTAL subagents per root session (SI spec §9). The
      // durable store count is authoritative; the in-memory cache only
      // short-circuits the read. Never released on settle — see reserveSlot.
      if (!(await reserveSlot(rootSessionId, parent.userId))) {
        throw new SubagentLimitError(rootSessionId, maxSubagents);
      }

      const startedAt = now();
      const deadline = startedAt + maxRuntimeMs;
      let timeoutTimer: ReturnType<typeof setTimeout> | undefined;
      let log: SubagentLog | null = null;
      let handle: MutableChildHandle | undefined;
      let childSessionId: string | null = null;
      // A reservation is only real once the child row exists. Before that an
      // infrastructure failure must hand the slot back.
      let childCreated = false;

      try {
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
        childCreated = true;
        childSessionId = child.sessionId;
        // T8 C1: a child is born planMode:false — NEVER inherit the parent's
        // plan flag. A fresh session's zero state already satisfies this; force
        // it defensively so a reused/cold-resumed row cannot leak the gate.
        const childState = await deps.state.get(child.sessionId);
        if (childState.planMode) {
          await deps.state.patch(child.sessionId, { planMode: false });
        }
        const first = await startTurn(child.sessionId, prompt);

        const parentSink = deps.sinkFactory(parent.sessionId);

        // ── append-only full log (SI spec §9) ─────────────────────────────
        // Logging is fail-open: a host that cannot create /workspace/.ovid/logs
        // must not make delegation impossible, but the parent is told.
        try {
          log = await (deps.logFactory ?? createSubagentLog)({
            sessionId: child.sessionId,
            ...(deps.logDir !== undefined ? { dir: deps.logDir } : {}),
            now,
            header: {
              parentSessionId: parent.sessionId,
              rootSessionId,
              agentType,
              depth: depth + 1,
              prompt,
              startedAt,
              maxRuntimeMs,
            },
          });
        } catch (err) {
          log = null;
          await parentSink.emit("system_note", {
            code: "subagent_log_failed",
            childSessionId: child.sessionId,
            message: err instanceof Error ? err.message : String(err),
          });
        }

        // Track the child's sandbox resources even when the log writer is
        // unavailable: a settle must kill them either way.
        const sinkForRun = childSink(log, resourcesOf(child.sessionId), parent.userId);

        handle = new MutableChildHandle({
          sessionId: child.sessionId,
          runId: first.runId,
          parentSessionId: parent.sessionId,
          rootSessionId,
          depth: depth + 1,
          prompt,
          agentType,
          startedAt,
          interrupt: async (reason: string) => {
            if (handle === undefined || handle.status() !== "running") return false;
            handle.markInterrupted();
            return deps.engine.cancel(child.sessionId, reason);
          },
          sendMessage: async (text: string) => {
            // Route to the LIVE loop: append + queue; the loop's steering drain
            // claims it at its next step boundary. Never start a second run.
            if (handle === undefined || handle.status() !== "running") return;
            await startTurn(child.sessionId, text);
          },
        });
        const childHandle = handle;
        handles.push(childHandle);

        await parentSink.emit("subagent_started", {
          runId: parent.runId,
          childSessionId: child.sessionId,
          childRunId: first.runId,
          prompt: prompt.slice(0, 200),
          // Wave 1b (additive): the live activity card's name.
          agentType,
        });

        // Parent cancel cascades (p2_subagent_races parity). The listener is
        // removed when the child settles so a long-lived signal never leaks.
        const onParentAbort = (): void => {
          void deps.engine
            .cancel(child.sessionId, "parent run cancelled")
            .catch(() => {});
        };
        if (parent.signal.aborted) onParentAbort();
        else parent.signal.addEventListener("abort", onParentAbort, { once: true });

        // One timer for the WHOLE subagent (all turns), not per engine run.
        const timeoutSignal = new Promise<"timeout">((resolve) => {
          const remaining = Math.max(0, deadline - now());
          timeoutTimer = setTimeout(() => resolve("timeout"), remaining);
          // Never keep the worker process alive just for a deadline.
          timeoutTimer.unref?.();
        });

        let runId = first.runId;
        let currentPrompt = prompt;
        let stopBlocks = 0;
        let finalStatus: ChildStatus = "running";
        /** The in-flight engine promise, kept so a cancelled run can unwind. */
        let lastRun: Promise<void> | null = null;

        try {
          for (;;) {
            if (parent.signal.aborted) {
              finalStatus = "cancelled";
              break;
            }
            if (now() >= deadline) {
              finalStatus = "timeout";
              break;
            }

            const runPromise = deps.engine.run({
              runId,
              sessionId: child.sessionId,
              userId: parent.userId,
              prompt: currentPrompt,
              mode: parent.mode,
              isSubagent: true,
              depth: depth + 1,
              subagentBriefing: prompt,
              roster,
              sink: sinkForRun,
            });
            lastRun = runPromise;
            // The timeout branch may return while the run is still unwinding
            // (engine.cancel aborts it); never surface that as unhandled.
            void runPromise.catch(() => {});

            const outcome = await Promise.race([
              runPromise.then(() => "done" as const),
              timeoutSignal,
            ]);
            if (outcome === "timeout") {
              finalStatus = "timeout";
              await deps.engine
                .cancel(child.sessionId, "subagent timeout")
                .catch(() => false);
              await log?.append({
                type: "subagent_timeout",
                maxRuntimeMs,
                deadline,
              });
              break;
            }

            const runStatus = await store.runStatus(runId, parent.userId);
            if (runStatus === "cancelled" || childHandle.isInterrupted()) {
              finalStatus = "cancelled";
              break;
            }
            if (runStatus === "failed") {
              finalStatus = "failed";
              break;
            }

            const answer = await store.lastAssistantText(child.sessionId);
            childHandle.setLastText(answer);

            // ── natural stop → [CC] SubagentStop gate (≤3 blocks) ─────────
            const stop = await fireSubagentStop(childHandle, answer ?? "", stopBlocks);
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
          // Run-level failures are the engine's terminal states; an escape
          // here is infrastructure — the handle still settles as failed rather
          // than leaving the parent's dispatch hanging.
          finalStatus = "failed";
        } finally {
          parent.signal.removeEventListener("abort", onParentAbort);
        }

        childHandle.setStatus(finalStatus);

        // ── the child owns no live sandbox resources once it settles ─────
        // An engine cancel only aborts the model transport; a sandbox job or
        // an in-flight exec keeps running detached. Give a cancelled/timed-out
        // run a short grace to unwind (so calls it started are tracked), then
        // kill every remaining job and call. This runs on EVERY settle path:
        // completed, timeout, cancelled and failed.
        if (finalStatus !== "completed" && lastRun !== null) {
          await Promise.race([
            lastRun.catch(() => undefined),
            new Promise<void>((resolve) => {
              const timer = setTimeout(resolve, CHILD_CANCEL_GRACE_MS);
              timer.unref?.();
            }),
          ]);
        }
        await killChildResources(child.sessionId, parent.userId);

        // ── strict ≤300-token JSON result (SI spec §9) ────────────────────
        const terminalStatus: SubagentSummaryStatus = finalStatus;
        const summary = buildSubagentSummary({
          status: terminalStatus,
          text: childHandle.rawResult(),
          error:
            finalStatus === "timeout"
              ? `Subagent exceeded the maximum runtime of ${maxRuntimeMs} ms and was stopped.`
              : finalStatus === "failed"
                ? "Subagent run failed."
                : finalStatus === "cancelled"
                  ? "Subagent run was cancelled."
                  : null,
        });
        childHandle.setSummary(summary);
        await log?.append({ type: "subagent_result", ...summary });

        await parentSink.emit("subagent_completed", {
          childRunId: first.runId,
          status: finalStatus,
        });
        return childHandle;
      } catch (err) {
        // Infrastructure escape before the child loop settled: never leave a
        // handle stuck in `running`, and never leave the child's sandbox work
        // behind (this is a settle path too).
        if (childSessionId !== null) {
          await killChildResources(childSessionId, parent.userId);
        }
        if (handle !== undefined && handle.status() === "running") {
          handle.setStatus("failed");
        }
        throw err;
      } finally {
        if (timeoutTimer !== undefined) clearTimeout(timeoutTimer);
        // Backstop for every path (including a throw while building the
        // summary): idempotent because the previous pass emptied the sets.
        if (childSessionId !== null) {
          await killChildResources(childSessionId, parent.userId, true);
        }
        if (log !== null) await log.close();
        if (!childCreated) await unreserveSlot(rootSessionId);
      }
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

    readLog(childSessionId, options = {}) {
      // Clamp HERE as well as in the default reader: a replaced reader must
      // never be handed an unbounded tailLines.
      const tailLines = clampSubagentLogTailLines(options.tailLines);
      const reader = deps.logReader ?? readSubagentLogTail;
      return reader({
        sessionId: childSessionId,
        dir: deps.logDir ?? SUBAGENT_LOG_DIR,
        tailLines,
      });
    },
  };
}

/**
 * The dispatch tool's return value: strict five-key JSON, always within the
 * 300-token budget. A handle that already settled carries the serialized
 * summary; a fake/legacy handle's raw text is validated here too — text that
 * does not match the five-key contract is REJECTED (never echoed as a
 * finding) so the contract holds at the tool boundary.
 */
export function subagentResultJson(handle: ChildHandle): string {
  const current = handle.status();
  const status: SubagentSummaryStatus = current === "running" ? "failed" : current;
  return serializeSubagentSummary(
    buildSubagentSummary({ status, text: handle.result() }),
  );
}

/** `list_agents` line: status + the first 80 chars of the prompt. */
export function renderChildLine(handle: ChildHandle): string {
  return `${handle.sessionId} [${handle.status()}] · ${firstLine(handle.prompt, 80)}`;
}
