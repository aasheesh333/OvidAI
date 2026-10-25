// The never-stop turn loop (P3 Task 15) — the Dart `_runTaskBody` body
// (lib/core/agent_service.dart AS:12149–12805) re-homed onto the cloud seams.
//
// ORDER IS THE CONTRACT. The twelve steps below are the Dart order; every
// branch that could short-circuit a model reply is deliberately placed after
// the reply (Dart's AS:12335–12339 comment: the old code `continue`d right
// after `_callLlm` and threw away whole replies on budget-boundary turns).
//
// Two ladders folded into one (Dart is TWO-level: inner `_callLlm`
// 5×[3,9,27,60]s at AS:13670–13744, then an outer run-level ≤6×[5·n]s at
// AS:12452–12476). The cloud plan pins ONE ladder — P1's 5 attempts with
// 3/9/27/60 s sleeps — gated by `turnsWithoutProgress < NO_PROGRESS_LIMIT`
// (guards.ts), so a run that keeps failing without progress still
// terminalizes `model_transient_exhausted`.
//
// CACHE-STABLE WIRING (ruling R3, not unit-only): BEFORE every transport call
// the loop runs Task 3's pipeline over the ACTUAL request —
//   computeToolRoster (already canonicalTools-sorted) → markCacheBreakpoints
// — so the system block, the tool schemas and the rolling tail carry at most
// MAX_CACHE_BREAKPOINTS marks, volatile rows ride last and are never marked,
// and the openai leg stamps `prompt_cache_key: sessionId`.
//
// The loop owns its run's terminal events and run-row transitions (claim is
// the CALLER's: Task 16 keeps `claimNext` before `engine.run`). Engine.run
// wraps this with the per-session event sink and the never-throw mapping.

import { randomUUID } from "node:crypto";

import { messages, runs, type Db } from "@ovid/db";

import { createDeltaCoalescer, deltaCoalesceMsFromEnv } from "./deltaCoalescer.js";

import {
  isBudgetBoundary,
  newGuardState,
  NO_PROGRESS_LIMIT,
  recordToolResult,
  shouldSendTodoNudge,
  todoNudgeMessage,
  type GuardState,
} from "./guards.js";
import { applyCheckpoint, foldBoundaryFor, isCheckpointRow } from "./compaction/compactor.js";
import type { KeyResolver } from "./keys.js";
import { presetById, type AgentPreset } from "./presets.js";
import { canonicalTools, markCacheBreakpoints } from "./promptCache.js";
import type {
  ApprovalGate,
  Compactor,
  EventSink,
  HookEngine,
  SandboxPort,
  SessionAgentState,
  SessionStateStore,
  SkillCatalog,
  TodoItem,
} from "./ports.js";
import { sandboxFailureCode } from "./ports.js";
import {
  computeToolRoster,
  isToolPermitted,
  modePolicy,
  type RosterContext,
} from "./roster.js";
import { resolveRoute, type ResolvedRoute } from "./routing.js";
import { drainQueuedRuns } from "./steering.js";
import { drainDurableSubagentReportsForLoop } from "./durableSubagentReportLoop.js";
import { buildSystemPrompt } from "./systemPrompt.js";
import { spillToolOutput, toolOutputCapFor, withToolTimeout } from "./tools/spill.js";
import { TerminalModelError, TransientModelError } from "./transport/errors.js";
import type {
  AgentImage,
  AgentMessage,
  AgentRequest,
  AgentResponse,
  AgentTransport,
  SessionMode,
  Tool,
  ToolCall,
  ToolContext,
  ToolRegistry,
  ToolResult,
  ToolSpec,
} from "./types.js";

/** P1's HISTORY_LIMIT (runProcessor.ts:134). */
export const HISTORY_LIMIT = 100;
/** P1's ladder (runProcessor.ts:130–131). */
export const MAX_MODEL_ATTEMPTS = 5;
export const RETRY_BACKOFF_MS = [3_000, 9_000, 27_000, 60_000] as const;
/** P2's tool-event content cap (worker tools/systemPrompt.ts:17). */
export const TOOL_EVENT_CONTENT_CAP = 8_192;
/**
 * Heartbeat cadence for the stale-run sweeper (staleRuns.ts): the loop stamps
 * runs.last_active_at at most this often, far under the sweeper's 10-minute
 * stranded threshold (worker main.ts DEFAULT_RUN_STALE_MS), so a long run
 * still emitting never looks stranded.
 */
export const RUN_HEARTBEAT_INTERVAL_MS = 30_000;
export const CANCELLED_MESSAGE = "Stopped by user.";
export const BUDGET_CONTINUATION_NUDGE =
  "[system] Continue the task from the last tool results. Do not restart; keep working until the task is complete, then give your final answer.";

/**
 * The queue's AgentRunJob shape, restated structurally: agent-core must not
 * depend on @ovid/queue (dependency direction + lockfile rule), and this is
 * the same field set Task 16 passes through.
 */
export interface AgentRunJob {
  runId: string;
  sessionId: string;
  userId: string;
  prompt: string;
  /**
   * Images the model must SEE with this prompt (owner directive 2026-10-18).
   * The worker checks the model's vision capability before starting the run.
   */
  promptImages?: readonly AgentImage[];
  tier?: string;
  attachmentIds?: string[];
  /**
   * The user's max completion tokens (the Settings "Max output tokens" pick,
   * gateway-validated to int 1..8192). The loop maps it onto every model
   * request's `maxTokens` — both transports serialize that as `max_tokens`.
   * Absent = the provider's own default (and the anthropic transport's own
   * required 8192 floor).
   */
  maxOutputTokens?: number;
  /**
   * Wave 1a (R1): context from sessions the user explicitly @-tagged in this
   * message, already framed by the worker. Inserted as a system row right
   * before the current user turn of THIS run only — never persisted, so it
   * never leaks into a later run.
   */
  turnContext?: string;
  /**
   * W1: pre-rendered project memory for a Main Agent run whose session
   * belongs to a project. Built per run from `project:<uuid>` rows; absent
   * for standalone sessions and subagent runs, so memory never crosses
   * projects or leaks into unrelated chats (R1).
   */
  memoryContext?: string;
  // ── P3 Task 20 (additive child-loop seam) ────────────────────────────────
  // A subagent run is a normal engine run on a CHILD session; these fields
  // carry the facts the loop would otherwise read off the (absent) parent.
  // Top-level callers omit them and the loop keeps its T15 behavior exactly.
  /** True for a child session (layer 2 roster gate + system-prompt briefing). */
  isSubagent?: boolean;
  /** 0-based lineage depth (root = 0). A child runs at parent.depth + 1. */
  depth?: number;
  /** The parent's dispatch prompt — the child's system-prompt briefing. */
  subagentBriefing?: string;
  /**
   * The child roster projected by the supervisor (CHILD_DENIED_TOOLS +
   * subagentToolPolicy). When present the loop advertises AND gates exactly
   * this set; absent → the normal computeToolRoster projection.
   */
  roster?: readonly ToolSpec[];
}

export interface NormalizedRunJob extends AgentRunJob {
  unattended: boolean;
  /** Carried for Task 16/P4 (autonomy policy); the gate is `mode`. */
  autonomy?: "safe" | "auto";
  /** Absent → the engine resolves `state.mode` (default "auto", ruling R4). */
  mode?: SessionMode;
}

export interface LoopDeps {
  db: Db;
  sink: EventSink;
  state: SessionStateStore;
  keys: KeyResolver;
  transports: { openai: AgentTransport; anthropic: AgentTransport };
  litellmBaseUrl: string;
  defaultModel: string;
  registry: ToolRegistry;
  approvals: ApprovalGate;
  hooks: HookEngine;
  compactor: Compactor;
  skills: SkillCatalog;
  /** null → sandbox-backed tools are absent from the roster. */
  sandbox: SandboxPort | null;
  /** Model context window for compaction (env, default 128_000). */
  windowTokens: number;
  /**
   * Deployment feature flags (P3 Task 16 carry M-3): the roster is computed
   * from these, so the loop never advertises a tool family the composition
   * cannot honor. Both default true (the T15 behavior) when absent.
   */
  memoryEnabled?: boolean;
  githubConnected?: boolean;
  /**
   * Wave 4 (SE-007): the preset registry for this run — the built-ins plus
   * the user's custom presets. Absent = built-ins only (`presetById`).
   */
  presets?: (id: string | null) => AgentPreset | null;
  /**
   * P3 Task 16: spill oversized tool output to `.spill/` before the event /
   * tool row (default true). The P2-compat path passes false so P2's caps
   * stay byte-for-byte identical.
   */
  spillToolResults?: boolean;
  /** BOUNDED mode only (P2-compat passes 50); undefined = never-stop. */
  maxToolRounds?: number;
  /** BOUNDED mode only (P2-compat passes SYSTEM_PROMPT_V1). */
  systemPromptOverride?: string;
  /**
   * P3 Task 16 (P2-compat only): let a call that is absent from the
   * advertised roster reach the registry anyway. P2's loop answered an
   * unknown tool with `unknown_tool: <name>` (a model-visible result) rather
   * than the roster denial; the compat path wraps its registry with exactly
   * that fallback. The full path leaves this unset — roster admission stays
   * the single gate.
   */
  allowUnrosteredTools?: boolean;
  sleep?: (ms: number) => Promise<void>;
  /** Injectable clock seam (P1 parity; the loop itself is clock-free). */
  now?: () => Date;
  /**
   * message_delta merge window (capacity wave): first delta immediate, then
   * at most one event per window. Default OVID_DELTA_COALESCE_MS / 50 ms.
   */
  deltaCoalesceMs?: number;
}

/**
 * Per-session run token. `cancelled` + `generation` are the pinned contract;
 * the three optional fields are additive T15 seams:
 * - `signal` lets `engine.cancel` abort the in-flight transport;
 * - `cancelReason` rides the `run_cancelled` payload;
 * - `isStale` is the Dart `_runChainStale` guard — a newer run replaced this
 *   session's bucket, so the old chain must stop at its next await point.
 */
export interface RunTime {
  cancelled: boolean;
  generation: number;
  signal?: AbortSignal;
  cancelReason?: string;
  isStale?: () => boolean;
}

export interface LoopResult {
  status: "completed" | "failed" | "cancelled";
  code?: string;
  message?: string;
}

const defaultSleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Backoff sleep that loses to Stop: the retry ladder used to `await sleep()`
 * bare, so a cancel landing mid-backoff waited out the full RETRY_BACKOFF_MS
 * (up to 60 s) before the next isCancelled check — Stop visibly lagged.
 * engine.cancel flips `rt.cancelled` AND aborts the run's controller, so
 * racing the (injectable) sleep against the run's abort signal wakes the
 * ladder the instant Stop lands. Callers re-check cancellation right after:
 * the race also resolves on the plain timer, and isCancelled covers flag
 * flips that never abort (isStale, direct rt.cancelled writes).
 */
export function sleepUntilOrAbort(
  ms: number,
  signal: AbortSignal,
  sleep: (ms: number) => Promise<void> = defaultSleep,
): Promise<void> {
  if (signal.aborted) return Promise.resolve();
  return new Promise<void>((resolve) => {
    // once: the listener cannot outlive the run it guards.
    const onAbort = () => resolve();
    signal.addEventListener("abort", onAbort, { once: true });
    sleep(ms).then(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    });
  });
}

const VALID_MODES: ReadonlySet<SessionMode> = new Set(["safe", "auto", "drive", "studio"]);

// ── mutation / read-only policy (Dart _readOnlyBlock, AS:19234–…) ───────────

/** Tools whose IDENTITY mutates (Dart `_readOnlyBlock` switch). */
const MUTATING_TOOLS: ReadonlySet<string> = new Set([
  "generate_image",
  "edit_image",
  "edit_images",
  "resize_image",
  "crop_image",
  "file_write",
  "write_file",
  "multi_edit",
  "notebook_edit",
  "run_code",
  "dispatch_agent",
  "workflow",
  "ralph",
  "request_working_folder",
  "commit",
  "git_clone",
  "git_push",
  "git_pull",
  "job_start",
  "job_kill",
  "browser_click",
  "browser_type",
  "browser_press_key",
  "browser_navigate",
  "browser_open",
  "browser_evaluate",
  "browser_new_tab",
  "browser_switch_tab",
  "browser_close_tab",
  "browser_close",
]);

/** Conservative read-only shell allowlist (Dart `_readOnlyCommands` intent). */
const READ_ONLY_COMMAND_PREFIXES = [
  "ls",
  "cat",
  "head",
  "tail",
  "grep",
  "find",
  "wc",
  "file",
  "stat",
  "du",
  "df",
  "pwd",
  "whoami",
  "id",
  "uname",
  "uptime",
  "which",
  "command",
  "type",
  "echo",
  "date",
  "cal",
  "hostname",
  "tree",
  "git status",
  "git log",
  "git diff",
  "git branch",
  "git show",
  "git rev-parse",
  "sed -n",
];

/** Tokens that make even an allowlisted prefix mutating. */
const SHELL_MUTATION_TOKENS = [
  ">",
  ">>",
  "| tee",
  "sed -i",
  " rm ",
  " mv ",
  " cp ",
  "mkdir",
  "touch",
  "chmod",
  "chown",
  "-delete",
  "git add",
  "git commit",
  "git checkout",
  "git reset",
  "git clean",
  "curl",
  "wget",
];

function isReadOnlyShellCommand(cmd: string): boolean {
  const c = cmd.trim();
  if (c === "") return true;
  const lower = ` ${c.toLowerCase()} `;
  if (SHELL_MUTATION_TOKENS.some((t) => lower.includes(t))) return false;
  return READ_ONLY_COMMAND_PREFIXES.some(
    (p) => c === p || c.startsWith(`${p} `) || c.startsWith(`${p}\t`),
  );
}

/**
 * Destructive-command confirmation (Dart `SandboxService.defaultDeniedCommands`
 * — sandbox_service.dart:3691–3701 — plus Dart's `_destructivePatterns`
 * escapes). Applies to run_shell, job_start AND run_code payloads (Dart
 * AS:19108 `_maybeApprove` gate); every mode, Full Access included (the
 * plan's step 10 wording — Dart itself auto-allows in drive, so this is the
 * spec-correct stricter behavior), and it is checked BEFORE the ordinary
 * user prompt so a hook `permissionDecision:"allow"` can never widen it.
 */
const DESTRUCTIVE_PATTERNS: readonly RegExp[] = [
  // SandboxService.defaultDeniedCommands, verbatim.
  /\brm\s+(-{1,2}[a-zA-Z-]*[rf][a-zA-Z-]*\s+)+(\/[^\s]*|\$HOME\b|\$PREFIX\b|~)/,
  /\bdd\s+[^|]*if=\/dev\/(block|zero|random)/,
  /\bmkfs(\.\w+)?\s/,
  /:\s*\(\s*\)\s*\{.*\}\s*;\s*:/,
  /\bchmod\s+-R\s+777\s+\//,
  /\bchown\s+-R\s+\S+\s+\/\s*$/,
  /\b(reboot|shutdown|halt)\b/,
  />\s*\/dev\/sd[a-z]/,
  /\bfind\s+\/[^|;&]*-delete\b/,
  // Dart _destructivePatterns escapes beyond the default set.
  /\brm\s+(-{1,2}[a-zA-Z-]*[rf][a-zA-Z-]*\s+)+\.\.\//,
  /\bfind\b[^|;&]*\s-delete\b/,
  // Additional git-destructive commands (cloud addition; confirmation only).
  /\bgit\s+reset\s+--hard\b/,
  /\bgit\s+clean\s+-[a-zA-Z]*f/,
];

export function isDestructiveShellCommand(cmd: string): boolean {
  return DESTRUCTIVE_PATTERNS.some((re) => re.test(cmd));
}

/**
 * The payload text the destructive classifier inspects — the three tool
 * families Dart gates (run_shell/job_start/run_code). null = not a gated
 * family.
 */
function destructivePayloadOf(name: string, args: Record<string, unknown>): string | null {
  if (name === "run_shell") return shellCommandOf(args);
  if (name === "job_start") {
    return typeof args.command === "string" ? args.command : "";
  }
  if (name === "run_code") {
    const parts: string[] = [];
    if (typeof args.code === "string") parts.push(args.code);
    if (typeof args.lang === "string") parts.push(args.lang);
    return parts.join("\n");
  }
  return null;
}

function shellCommandOf(args: Record<string, unknown>): string {
  if (typeof args.cmd === "string") return args.cmd;
  if (typeof args.command === "string") return args.command;
  return "";
}

function isMutatingTool(name: string, args: Record<string, unknown>): boolean {
  if (name.startsWith("plugin_") || name.startsWith("mcp__") || name.startsWith("device_")) {
    return true;
  }
  if (name === "fs_edit") {
    return (args.command as string | undefined)?.toLowerCase() !== "view";
  }
  if (name === "run_shell") {
    return !isReadOnlyShellCommand(shellCommandOf(args));
  }
  return MUTATING_TOOLS.has(name);
}

/** Tool families Read-Only asks about even when they do not mutate (Wave 1a). */
const SAFE_MODE_ASK_TOOLS: ReadonlySet<string> = new Set([
  "run_shell",
  "run_code",
  "job_start",
  "job_kill",
  "fetch_url",
  "web_search",
]);

/**
 * Read-Only's ask set: every shell/code/job call (read-only commands too),
 * every browser_* call, network fetches, and every mutating tool. Pure reads
 * (file_read, fs_glob/grep, memory_read, session_search, todo/goal, skill)
 * never ask.
 */
function safeModeNeedsApproval(name: string, args: Record<string, unknown>): boolean {
  return (
    SAFE_MODE_ASK_TOOLS.has(name) ||
    name.startsWith("browser_") ||
    isMutatingTool(name, args)
  );
}

function safeModeApprovalDetail(name: string, args: Record<string, unknown>): string {
  const shell = destructivePayloadOf(name, args);
  if (shell !== null && shell !== "") return shell;
  let text: string;
  try {
    text = JSON.stringify(args);
  } catch {
    text = "";
  }
  if (text.length > 2000) text = `${text.slice(0, 2000)}…`;
  return `${name} ${text}`.trim();
}

const READ_ONLY_DENIAL =
  "READ-ONLY MODE: this action is blocked. The user " +
  "selected Read-Only — you may read, search, browse and run " +
  "read-only shell commands, but you may NOT write files, edit code, " +
  "start jobs or commit. Explain what you need to change and ask the " +
  "user to switch to General or Studio mode.";

function planModeDenial(name: string): string {
  return (
    `PLAN MODE ACTIVE: "${name}" is a mutating tool. Plan mode is the ` +
    "research phase — read, search and inspect with the allowlisted " +
    "tools (file_read, fs_glob, fs_grep, run_shell for read-only " +
    "commands, git_log, …), write the plan out as a message, then call " +
    "exit_plan_mode. Execution tools unlock once the user approves."
  );
}

/** Sandbox-backed tools disappear from the roster when `sandbox === null`. */
const SANDBOX_BACKED_TOOLS: ReadonlySet<string> = new Set([
  "run_shell",
  "run_code",
  "file_read",
  "file_write",
  "write_file",
  "read_file",
  "fs_view",
  "fs_edit",
  "fs_glob",
  "fs_grep",
  "glob_files",
  "grep_files",
  "job_start",
  "job_output",
  "job_kill",
  "job_list",
  "read_attachment",
  "fetch_url",
  "repo_sync",
  "repo_tree",
  "git_status",
  "git_log",
  "git_diff",
  "git_clone",
  "git_pull",
  "git_push",
  "commit",
]);

/** Path-ish args the mode gate inspects for outside-workspace targets. */
const PATH_ARGS = ["path", "file_path", "cwd", "dir", "target", "paths", "files"] as const;

/**
 * Heuristic outside-workspace target extraction for the mode gate. Tools own
 * their own richer approvals (fetch_url's host grants, git's push prompts);
 * this only covers the generic path class the plan pins ("auto/studio →
 * workspace-confined, outside targets prompt"). `..`-escaping relative paths
 * are outside; `/workspace` (the session jail) is inside.
 */
function outsideWorkspaceTargets(args: Record<string, unknown>): string[] {
  const found: string[] = [];
  for (const key of PATH_ARGS) {
    const raw = args[key];
    const values = Array.isArray(raw) ? raw : [raw];
    for (const value of values) {
      if (typeof value !== "string") continue;
      const path = value.trim();
      if (path === "") continue;
      const outside = path.startsWith("..") || (path.startsWith("/") && !path.startsWith("/workspace"));
      if (outside && !found.includes(path)) found.push(path);
    }
  }
  return found;
}

// ── context-overflow classification (Dart AS:19694–19705) ───────────────────

/**
 * The FULL Dart clause list (the plan's shorter regex is a subset; the map
 * pins the superset — 'exceed'+token and 'reduce the length' are real
 * provider phrasings).
 */
export function looksLikeContextOverflow(message: string): boolean {
  const l = message.toLowerCase();
  return (
    l.includes("context length") ||
    l.includes("context window") ||
    l.includes("maximum context") ||
    l.includes("too many tokens") ||
    (l.includes("exceed") && l.includes("token")) ||
    l.includes("prompt is too long") ||
    l.includes("prompt too large") ||
    l.includes("reduce the length")
  );
}

// ── helpers ─────────────────────────────────────────────────────────────────

function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function isCancelled(rt: RunTime): boolean {
  return rt.cancelled || rt.isStale?.() === true;
}

function pendingTodos(todos: readonly TodoItem[]): TodoItem[] {
  return todos.filter((t) => t.status !== "completed");
}

/** Dart `_applyPlanModeNow` + `_releasePlanOwnedMode` (AS:1560–1610). */
function planModePatch(s: SessionAgentState, next: boolean): Partial<SessionAgentState> {
  const patch: Partial<SessionAgentState> = { planMode: next, pendingPlanMode: null };
  if (!next) {
    if (s.planPreMode !== null) {
      patch.mode = VALID_MODES.has(s.planPreMode) ? s.planPreMode : "auto";
      patch.planPreMode = null;
    } else if (s.mode === "safe") {
      patch.mode = "auto";
    }
  }
  return patch;
}

function vetoMessage(reason: string | null): string {
  return (
    "[system] A plugin hook vetoed the end of this run" +
    (reason !== null ? ` (reason: ${reason})` : "") +
    ". Continue working on the task; do not repeat your last " +
    "message verbatim."
  );
}

function presetFor(
  state: SessionAgentState,
  deps: Pick<LoopDeps, "presets">,
): AgentPreset | null {
  return (deps.presets ?? presetById)(state.presetId);
}

function rosterContext(
  state: SessionAgentState,
  mode: SessionMode,
  deps: Pick<LoopDeps, "memoryEnabled" | "githubConnected" | "presets">,
  isSubagent = false,
): RosterContext {
  return {
    mode,
    planMode: state.planMode,
    isSubagent,
    // M-3 (T15 review): feature flags are composition inputs, not constants.
    // Absent = the T15 default (true) for callers that never wired them.
    memoryEnabled: deps.memoryEnabled ?? true,
    githubConnected: deps.githubConnected ?? true,
    preset: presetFor(state, deps),
    activeSkillScopes: state.activeSkillScopes,
  };
}

function availableSpecs(deps: LoopDeps) {
  return deps.registry
    .all()
    .filter((t) => deps.sandbox !== null || !SANDBOX_BACKED_TOOLS.has(t.spec.name))
    .map((t) => t.spec);
}

// ── the loop ────────────────────────────────────────────────────────────────

export async function runAgentLoop(
  job: NormalizedRunJob,
  deps: LoopDeps,
  rt: RunTime,
): Promise<LoopResult> {
  const sleep = deps.sleep ?? defaultSleep;
  const abortSignal = rt.signal ?? new AbortController().signal;
  const coalesceMs = deps.deltaCoalesceMs ?? deltaCoalesceMsFromEnv(process.env);
  const { sessionId, runId, userId } = job;
  // Stale-sweep heartbeat: every emitted event proves the run is live, but an
  // UPDATE per emit would dwarf the event traffic itself — so the per-run
  // emit wrapper stamps runs.last_active_at at most once per
  // RUN_HEARTBEAT_INTERVAL_MS (a cheap in-memory timestamp check per emit;
  // the write itself is a single-row UPDATE). The sweeper's stale test is
  // COALESCE(last_active_at, started_at) < cutoff (repos.listStaleRunning),
  // so a run longer than the sweep threshold that is still emitting never
  // looks stranded. Both worker processors reach the loop through the engine,
  // which makes THIS the one per-run emit chokepoint they share.
  let lastHeartbeatMs = 0;
  const emit = (
    type: Parameters<EventSink["emit"]>[0],
    payload: Record<string, unknown>,
  ): Promise<unknown> => {
    const nowMs = Date.now();
    if (nowMs - lastHeartbeatMs >= RUN_HEARTBEAT_INTERVAL_MS) {
      lastHeartbeatMs = nowMs;
      void runs.bumpLastActive(deps.db, runId).catch(() => {});
    }
    return deps.sink.emit(type, payload);
  };

  // ── key resolution precedes run_started (P1: key_not_minted has no
  // run_started event — runProcessor.ts:236–241) ────────────────────────────
  let state = await deps.state.get(sessionId);

  const routeFor = (s: SessionAgentState): Promise<ResolvedRoute | null> =>
    resolveRoute(
      {
        userId,
        requestedModel: s.modelPin,
        preset: (() => {
          const p = presetFor(s, deps);
          return p === null ? null : { model: p.model, temperature: p.temperature };
        })(),
      },
      { keys: deps.keys, litellmBaseUrl: deps.litellmBaseUrl, defaultModel: deps.defaultModel },
    );

  let route = await routeFor(state);
  if (route === null) {
    await emit("run_failed", { code: "key_not_minted" });
    await runs.finish(deps.db, runId, "failed", "key_not_minted");
    return { status: "failed", code: "key_not_minted" };
  }

  // ── run_started FIRST (P1: a claimed run always announces itself before
  // any terminal event; key_not_minted above is the one pre-start failure) ──
  await emit("run_started", { runId });

  // ── entry hooks (once per run; Dart AS:11594–11629) ──────────────────────
  await deps.hooks.fire("session_start", sessionId, { sessionId });
  const promptHook = await deps.hooks.fireDetailed("user_prompt_submit", sessionId, {
    prompt: job.prompt,
  });
  if (promptHook.promptBlockReason !== null) {
    await emit("run_failed", { code: "hook_blocked", message: promptHook.promptBlockReason });
    await runs.finish(deps.db, runId, "failed", "hook_blocked");
    return { status: "failed", code: "hook_blocked", message: promptHook.promptBlockReason };
  }
  const sessionContext = deps.hooks.sessionContextFor(sessionId);
  const promptContext = deps.hooks.promptContextFor(sessionId);

  // ── history: newest ≤100 reversed (P1 HISTORY_LIMIT contract); the prompt
  // is ALREADY persisted — never re-append (runProcessor.ts:246) ───────────
  const { rows } = await messages.page(deps.db, sessionId, { limit: HISTORY_LIMIT });
  const history: AgentMessage[] = [];
  for (let i = rows.length - 1; i >= 0; i -= 1) {
    const row = rows[i]!;
    if (row.role === "user" || row.role === "assistant" || row.role === "system") {
      // `id` is the durable-row seam for the compaction fold boundary (fix
      // round I-3); transports never serialize it.
      history.push({ role: row.role, content: row.content, id: row.id });
    }
  }
  let msgs: AgentMessage[] = history;
  // Checkpoint replay (T16 review I4): a persisted compaction summary is the
  // stable system row for every later run of the session. The tail starts at
  // the DURABLE fold boundary (fix round I-3): `cutoffMessageId` marks the last
  // persisted row already absorbed into the ledger, so folded originals are
  // neither re-sent below the summary nor re-absorbed by the next compaction.
  // The ledger's in-memory `foldedMessages` count cannot be used here (it
  // counts tool rows, which are never persisted).
  msgs = applyCheckpoint(
    state.compaction,
    msgs,
    foldBoundaryFor(state.compaction, msgs),
  );
  // The CURRENT turn's prompt is authoritative: a slash-command pre-pass
  // (full processor) may have rewritten it (e.g. a skill invocation). The
  // gateway persisted the raw composer line, so replace the trailing user row
  // rather than appending a second copy.
  const promptImages =
    job.promptImages !== undefined && job.promptImages.length > 0
      ? job.promptImages
      : undefined;
  if (msgs.length > 0) {
    const last = msgs[msgs.length - 1]!;
    if (last.role === "user" && last.content !== job.prompt) {
      msgs[msgs.length - 1] = {
        ...last,
        content: job.prompt,
        ...(promptImages !== undefined ? { images: promptImages } : {}),
      };
    } else if (last.role === "user" && promptImages !== undefined) {
      // Same text (the gateway persisted the composer line): the images still
      // belong to this turn, so attach them to that row.
      msgs[msgs.length - 1] = { ...last, images: promptImages };
    }
  }
  // Wave 1a (R1): @-tagged session context for THIS run only.
  const turnContext = job.turnContext?.trim() ?? "";
  if (turnContext !== "") {
    // Ephemeral: the compactor must never fold another session's context
    // into THIS session's durable summary (R1 — context crosses sessions
    // only for the run the user tagged it in).
    const row: AgentMessage = { role: "system", content: turnContext, ephemeral: true };
    const lastIndex = msgs.length - 1;
    if (lastIndex >= 0 && msgs[lastIndex]!.role === "user") {
      msgs = [...msgs.slice(0, lastIndex), row, msgs[lastIndex]!];
    } else {
      msgs = [...msgs, row];
    }
  }

  const g: GuardState = newGuardState();
  // "forceCompact ONCE" is a RUN-level flag (Dart AS:12170 declares it before
  // the turn loop), not a per-turn allowance.
  let overflowRecovered = false;
  let stopHookActive = false;
  let toolRounds = 0;

  // Wave 1b (CH-028): the run's token usage, summed over every model turn
  // that reported one; `contextTokens` is the conversation's size after the
  // LAST turn (its prompt + its reply) — what the client's context ring
  // shows against the model's window. Null until a
  // transport reports usage (run_completed then stays `{runId}`).
  let usage: { inputTokens: number; outputTokens: number; cacheReadTokens: number; contextTokens: number } | null = null;
  const addUsage = (u: AgentResponse["usage"]): void => {
    if (u === null || u === undefined) return;
    const cacheRead = u.cacheReadTokens ?? 0;
    usage = {
      inputTokens: (usage?.inputTokens ?? 0) + u.inputTokens,
      outputTokens: (usage?.outputTokens ?? 0) + u.outputTokens,
      cacheReadTokens: (usage?.cacheReadTokens ?? 0) + cacheRead,
      contextTokens: u.inputTokens + u.outputTokens,
    };
  };

  // Wave 1b (CH-005/CH-006): an assistant turn that does NOT end the run
  // (tool calls, a late steering drain, the todo nudge, a Stop veto) settles
  // its text as message_segment, so the live bubble closes at the right
  // place and a reloaded history shows it. Whitespace-only text is noise.
  const segment = async (content: string): Promise<void> => {
    if (content.trim() === "") return;
    await emit("message_segment", { runId, content });
  };

  const cancelled = async (): Promise<LoopResult> => {
    // P8-T1 / C1 EVENT-FIRST contract: the terminal event must precede the
    // status flip. `runs.finish` removes the row from the active set, which
    // unblocks the next same-session run — flipping first let a successor's
    // run_started land before this run's terminal event (T16 review I1).
    await emit("run_cancelled", {
      runId,
      ...(rt.cancelReason !== undefined ? { reason: rt.cancelReason } : {}),
    });
    // The code, not the prose (every engine-path finish writes a code — see
    // failed() below): the row's verdict column is machine-read, the
    // human-readable message lives in the event.
    await runs.finish(deps.db, runId, "cancelled", "cancelled");
    return { status: "cancelled", code: "cancelled", message: CANCELLED_MESSAGE };
  };

  const failed = async (code: string, message?: string): Promise<LoopResult> => {
    await emit("run_failed", { code, ...(message !== undefined ? { message } : {}) });
    // The run row carries the canonical failure CODE, never the provider's
    // prose: the scheduler's settle pass classifies retryability on an exact
    // match of last_error against RETRYABLE_RUN_CODES (schedulerSettle.ts),
    // so "upstream 500" terminalized the occurrence where
    // model_transient_exhausted must arm the retry ladder. The message stays
    // in the emitted event (same contract as runProcessor's model_terminal).
    await runs.finish(deps.db, runId, "failed", code);
    return { status: "failed", code, ...(message !== undefined ? { message } : {}) };
  };

  /** Step 2 + the run-unwind landing (Dart AS:12172 / AS:12826–12836). */
  const landPendingPlanMode = async (): Promise<void> => {
    const s = await deps.state.get(sessionId);
    if (s.pendingPlanMode === null) return;
    const next = s.pendingPlanMode;
    await deps.state.patch(sessionId, planModePatch(s, next));
    await emit("plan_mode_changed", { runId, planMode: next });
  };

  /**
   * Step 6's attempt ladder. `turnsWithoutProgress` gates transient retries
   * (folded Dart two-level ladder — see the file header).
   */
  const callModel = async (
    request: AgentRequest,
  ): Promise<
    | { kind: "ok"; response: AgentResponse }
    | { kind: "failed"; code: "model_transient_exhausted" | "model_terminal"; message: string }
    | { kind: "cancelled" }
  > => {
    const transport = deps.transports[route!.transportKind];
    for (let attempt = 0; attempt < MAX_MODEL_ATTEMPTS; attempt += 1) {
      if (isCancelled(rt)) return { kind: "cancelled" };
      await runs.bumpAttempt(deps.db, runId);

      // Per-attempt delta chain (P1 parity): order matches arrival order and
      // a failed attempt's text is NEVER folded into the next attempt. The
      // coalescer merges deltas (first one immediate, then ≤1 event per
      // window) so per-token events stop dominating redis/Postgres/WS load.
      const deltas = createDeltaCoalescer(
        async (text) => {
          await emit("message_delta", { runId, text });
        },
        { windowMs: coalesceMs },
      );
      try {
        const response = await transport.stream(
          request,
          {
            onTextDelta(text: string): void {
              deltas.push(text);
            },
          },
          abortSignal,
        );
        await deltas.drain();
        if (isCancelled(rt)) return { kind: "cancelled" };
        return { kind: "ok", response };
      } catch (err) {
        await deltas.drain().catch(() => {});
        if (isCancelled(rt)) return { kind: "cancelled" };
        const message = messageOf(err);

        if (err instanceof TransientModelError) {
          if (attempt >= MAX_MODEL_ATTEMPTS - 1) {
            return { kind: "failed", code: "model_transient_exhausted", message };
          }
          if (g.turnsWithoutProgress >= NO_PROGRESS_LIMIT) {
            return { kind: "failed", code: "model_transient_exhausted", message };
          }
          g.turnsWithoutProgress += 1;
          const nextBackoffMs = RETRY_BACKOFF_MS[attempt]!;
          await emit("run_started_retry", { attempt: attempt + 2, nextBackoffMs });
          // Stop must not wait out the backoff (see sleepUntilOrAbort): race
          // the sleep against the abort signal, then re-check immediately so
          // the ladder lands cancelled rather than 60 s late.
          await sleepUntilOrAbort(nextBackoffMs, abortSignal, sleep);
          if (isCancelled(rt)) return { kind: "cancelled" };
          continue;
        }
        if (err instanceof TerminalModelError) {
          return { kind: "failed", code: "model_terminal", message };
        }
        throw err; // infrastructure stays loud
      }
    }
    return { kind: "failed", code: "model_transient_exhausted", message: "model attempts exhausted" };
  };

  try {
    for (let turn = 0; ; turn += 1) {
      // ── 1. cancel check ────────────────────────────────────────────────
      if (isCancelled(rt)) return await cancelled();

      // Bounded mode (P2-compat): a run that has already used its tool-round
      // budget may not make another model call — P2's `for round 1..N` never
      // issued an (N+1)th request. Checked BEFORE the call so exactly N tool
      // rounds reach the transport.
      if (deps.maxToolRounds !== undefined && toolRounds >= deps.maxToolRounds) {
        return await failed("tool_rounds_exhausted");
      }

      // ── 2. pending plan mode at the turn boundary (G2) ─────────────────
      state = await deps.state.get(sessionId);
      if (state.pendingPlanMode !== null) {
        const next = state.pendingPlanMode;
        await deps.state.patch(sessionId, planModePatch(state, next));
        await emit("plan_mode_changed", { runId, planMode: next });
        state = await deps.state.get(sessionId);
      }
      const mode: SessionMode = job.mode ?? state.mode ?? "auto";

      // ── 3. rebuild the system prompt; stable block swapped in place ────
      const preset = presetFor(state, deps);
      const parts = await buildSystemPrompt({
        mode,
        planMode: state.planMode,
        isSubagent: job.isSubagent ?? false,
        persona: preset?.persona ?? "",
        workspaceFolder: "",
        workspaceTreeSummary: "",
        skillsCatalog: await deps.skills.list(sessionId),
        memoryContext: job.memoryContext ?? "",
        todos: state.todos,
        goal: state.goal,
        ...(job.subagentBriefing !== undefined
          ? { subagentBriefing: job.subagentBriefing }
          : {}),
      });
      // P2-compat mode (systemPromptOverride) keeps the prompt byte-identical
      // to SYSTEM_PROMPT_V1: no volatile block is appended.
      const stable = deps.systemPromptOverride ?? parts.stable;
      const volatile = deps.systemPromptOverride !== undefined ? "" : parts.volatile;

      const standingRows: AgentMessage[] = [];
      if (sessionContext.trim() !== "") {
        standingRows.push({ role: "system", content: `[session_start hook]\n${sessionContext}` });
      }
      if (promptContext !== null && promptContext.trim() !== "") {
        standingRows.push({
          role: "system",
          content: `[user_prompt_submit hook]\n${promptContext}`,
        });
      }
      // The stable block is the LAST non-volatile content-bearing system row
      // (hook notes insert BEFORE it), so markCacheBreakpoints lands the
      // system mark here — the cache-stable prefix (Task 3/7 invariant).
      const volatileRows: AgentMessage[] =
        volatile.trim() !== "" ? [{ role: "system", content: volatile, volatile: true }] : [];

      // ── finished subagents ─────────────────────────────────────────────
      // Durable reports replace the lossy in-memory queue. The adapter removes
      // the stable history copy and supplies one refreshed batch in the legacy
      // volatile position; it never synthesizes a response or starts work.
      const childReports = await drainDurableSubagentReportsForLoop({
        db: deps.db,
        sessionId,
        history: msgs,
      });
      msgs = childReports.history;
      volatileRows.push(...childReports.volatileRows);

      // ── 4. pre_request hook notes (leading system rows; observe-only) ──
      // Dart inserts each note at index 0, so the LAST systemMessage ends up
      // first; the output row is inserted after the loop and therefore rides
      // ABOVE all of them (AS:12238–12246). Standing session/prompt contexts
      // are inserted later still and ride first (AS:12263–12273) — the final
      // order is: session context, prompt context, pre_request output,
      // reversed pre_request notes, stable block, volatile block.
      const preRequest = await deps.hooks.fireDetailed("pre_request", sessionId, { turn });
      const hookRows: AgentMessage[] = [];
      if (preRequest.output.trim() !== "") {
        hookRows.push({
          role: "system",
          content: `[plugin hook context — on_pre_request]\n${preRequest.output}`,
        });
      }
      for (const sm of [...preRequest.systemMessages].reverse()) {
        hookRows.push({ role: "system", content: `[plugin hook]\n${sm}` });
      }
      if (preRequest.promptBlockReason !== null) {
        // An observe-only hook can never halt the run (Dart AS:12249–12255).
        await emit("system_note", {
          code: "hook_block_ignored",
          reason: preRequest.promptBlockReason,
        });
      }
      const systemRows: AgentMessage[] = [
        ...standingRows,
        ...hookRows,
        { role: "system", content: stable },
        ...volatileRows,
      ];

      // ── 5. steering drain — EVERY request, including the first ─────────
      const injected = await drainQueuedRuns(
        { db: deps.db, sink: deps.sink },
        { sessionId, activeRunId: runId },
      );
      if (injected.length > 0) msgs.push(...injected);

      // ── roster + route (preset pin from state.presetId) ────────────────
      // A child run carries the supervisor's projected roster (Task 20); the
      // dispatch gate below uses the SAME set, so "advertised" and "permitted"
      // still cannot disagree.
      const roster =
        job.roster !== undefined
          ? canonicalTools(job.roster)
          : computeToolRoster(
              rosterContext(state, mode, deps, job.isSubagent ?? false),
              availableSpecs(deps),
            );
      const rosterNames = new Set(roster.map((t) => t.name));
      route = await routeFor(state);
      if (route === null) return await failed("key_not_minted");

      // T5-C1 carry: the anthropic transport appends `/v1/messages`; a
      // `/v1`-suffixed route base would produce `/v1/v1/messages`.
      const baseUrl =
        route.transportKind === "anthropic"
          ? route.baseUrl.replace(/\/+$/, "").replace(/\/v1$/, "")
          : route.baseUrl;

      const buildRequest = (): AgentRequest => {
        // R3: canonical tools (already sorted by computeToolRoster) →
        // markCacheBreakpoints → transport.
        const marked = markCacheBreakpoints(systemRows, msgs, roster);
        return {
          model: route!.model,
          baseUrl,
          apiKey: route!.apiKey,
          system: marked.system,
          messages: marked.messages,
          tools: marked.tools,
          ...(route!.effort !== null ? { effort: route!.effort } : {}),
          ...(route!.temperature !== undefined ? { temperature: route!.temperature } : {}),
          // The user's Settings output cap → AgentRequest.maxTokens (the
          // transports serialize it as max_tokens; absent = provider default).
          ...(job.maxOutputTokens !== undefined ? { maxTokens: job.maxOutputTokens } : {}),
          cacheMode: route!.cacheMode,
          promptCacheKey: sessionId,
        };
      };

      // ── 6. model call (+ step 8 overflow recovery) ─────────────────────
      let response: AgentResponse | null = null;
      for (;;) {
        const attempt = await callModel(buildRequest());
        if (attempt.kind === "cancelled") return await cancelled();
        if (attempt.kind === "ok") {
          response = attempt.response;
          addUsage(response.usage);
          break;
        }
        if (!overflowRecovered && looksLikeContextOverflow(attempt.message)) {
          overflowRecovered = true;
          // Dart C1 fix: REBUILD the request from the compacted history —
          // insert-only grew the request and never recovered.
          const compacted = await deps.compactor.maybeCompact({
            sessionId,
            messages: msgs,
            windowTokens: deps.windowTokens,
            // The checkpoint row at index 0 is never part of the foldable
            // span (fix round I-3). Without a checkpoint this run's history
            // starts at a real row.
            foldBoundary: isCheckpointRow(msgs[0]) ? 1 : 0,
          });
          msgs = [...compacted.messages];
          continue;
        }
        return await failed(attempt.code, attempt.message);
      }

      // ── 7. post_request hook (fire-and-forget, never injected) ─────────
      void deps.hooks
        .fire("post_request", sessionId, {
          turn,
          reply: response.content.slice(0, 400),
          transcript_path: "",
        })
        .catch(() => {});

      // Dart re-checks cancel right after the model call (AS:12446–12451).
      if (isCancelled(rt)) return await cancelled();

      // Any non-null response consumes no-progress budget (floor 0).
      if (g.turnsWithoutProgress > 0) g.turnsWithoutProgress -= 1;

      const content = response.content;
      const toolCalls = response.toolCalls ?? [];

      // ── 9. no tool calls → finalize path ──────────────────────────────
      if (toolCalls.length === 0) {
        // (a) queued messages arrived during the final reply: keep the
        // assistant row in the request, drain, continue.
        const late = await drainQueuedRuns(
          { db: deps.db, sink: deps.sink },
          { sessionId, activeRunId: runId },
        );
        if (late.length > 0) {
          await segment(content);
          msgs.push({ role: "assistant", content });
          msgs.push(...late);
          continue;
        }

        // (b) todo follow-through nudge — exactly once per run.
        state = await deps.state.get(sessionId);
        if (shouldSendTodoNudge(g, state.todos)) {
          const pending = pendingTodos(state.todos);
          g.todoNudgeSent = true;
          await segment(content);
          msgs.push({ role: "assistant", content });
          msgs.push({ role: "user", content: todoNudgeMessage(pending) });
          continue;
        }

        // (c) Stop-hook gate. User cancel ALWAYS beats a veto: the flag is
        // checked first here and passed to the hook engine, whose contract
        // short-circuits to allow when it is set.
        if (isCancelled(rt)) return await cancelled();
        const stop = await deps.hooks.fireStop(
          sessionId,
          {
            turn,
            steps: toolRounds,
            stop_hook_active: stopHookActive,
            last_assistant_message: content,
            transcript_path: "",
            userStopRequested: isCancelled(rt),
          },
          "stop",
        );
        stopHookActive = stop.veto;
        if (stop.veto) {
          // Keep the final answer in the transcript AND the request.
          await segment(content);
          msgs.push({ role: "assistant", content });
          msgs.push({ role: "user", content: vetoMessage(stop.reason) });
          continue;
        }

        // (d) finalize: persist, message_completed, terminal event, flip.
        const assistant = await messages.append(deps.db, {
          sessionId,
          role: "assistant",
          content,
        });
        await emit("message_completed", { messageId: assistant.id, content });
        // P1 order: terminal event BEFORE the status flip. Wave 1b: the
        // run's usage rides the terminal (additive; absent when unknown).
        await emit("run_completed", usage === null ? { runId } : { runId, usage });
        await runs.finish(deps.db, runId, "completed");
        return { status: "completed" };
      }

      // ── 10. tool round (sequential, Dart parity) ───────────────────────
      toolRounds += 1;

      await segment(content);
      msgs.push({ role: "assistant", content, toolCalls });

      for (const call of toolCalls) {
        if (isCancelled(rt)) return await cancelled();

        // Dart reads planMode/mode from the LIVE session on every dispatch
        // (the `planMode` getter), so an exit_plan_mode earlier in this same
        // round opens the gate for the calls after it.
        state = await deps.state.get(sessionId);

        const args: Record<string, unknown> =
          call.args !== null && typeof call.args === "object" && !Array.isArray(call.args)
            ? call.args
            : {};

        await emit("tool_started", {
          runId,
          callId: call.id,
          name: call.name,
          args,
          // P2 wire spelling kept alongside the P3 one (client compatibility
          // across the Task-16 cutover — see the task report).
          input: args,
        });

        let effectiveArgs = args;
        let result: ToolResult | null = null;
        let bypassPermission = false;

        // pre_tool gate (awaited — a plugin may DENY the call outright).
        if (await deps.hooks.hasListeners("pre_tool", sessionId)) {
          const gate = await deps.hooks.fireGate(sessionId, { tool: call.name, args });
          if (gate.updatedInput !== undefined) {
            effectiveArgs = { ...effectiveArgs, ...gate.updatedInput };
          }
          bypassPermission = gate.bypassPermission === true;
          if (gate.decision === "deny") {
            result = {
              content: `DENIED by hook (${gate.deniedByPlugin ?? "plugin"}): ${gate.reason ?? ""}`,
              isError: true,
            };
          } else if (gate.decision === "ask") {
            const decision = await deps.approvals.approve(
              {
                sessionId,
                runId,
                userId,
                mode,
                planMode: state.planMode,
                unattended: job.unattended,
                signal: abortSignal,
              },
              {
                approvalId: randomUUID(),
                kind: "tool",
                tool: call.name,
                summary: `Hook "${gate.decidedByPlugin ?? "plugin"}" asked for a decision`,
                detail:
                  gate.reason ??
                  "A plugin hook asked you to decide whether this tool call may run.",
                allowAlways: false,
                pathTargets: [],
                hostTargets: [],
              },
            );
            if (decision !== "allow" && decision !== "always") {
              result = { content: "DENIED by user", isError: true };
            }
          }
        }

        // Roster/permission gate — the SAME single source as the roster.
        // A tool absent from the ADVERTISED roster is denied, unless the
        // permission projection still admits it. The distinction matters for
        // sandbox-backed tools: `availableSpecs` drops them when no sandbox
        // is wired (nothing to advertise), but the dispatch gate must still
        // admit them so the mode policy produces the pinned denial (the T15
        // mode-policy tests). Permission is the conjunctive source of truth.
        //
        // CONTAINMENT (fix round I-2): a CHILD run's roster is authoritative.
        // `job.roster` is the supervisor's projection after
        // CHILD_DENIED_TOOLS + the dispatch's `tools`/`disallowedTools`
        // policy, and `isToolPermitted` has no child-policy input — so for a
        // child, roster membership alone decides. Without this a
        // prompt-injected child could call a tool its policy removed simply
        // because the permission projection (which knows nothing about that
        // policy) admits it.
        if (result === null && !rosterNames.has(call.name)) {
          const admitted =
            job.roster === undefined &&
            (deps.allowUnrosteredTools === true ||
              isToolPermitted(
                call.name,
                rosterContext(state, mode, deps, job.isSubagent ?? false),
              ));
          if (!admitted) {
            result = {
              content: `DENIED: ${call.name} is not available in ${
                state.planMode ? "plan" : mode
              } mode`,
              isError: true,
            };
          }
        }

        const tool: Tool | undefined = deps.registry.get(call.name);
        if (result === null && tool === undefined) {
          result = {
            content: `DENIED: ${call.name} is not available in ${
              state.planMode ? "plan" : mode
            } mode`,
            isError: true,
          };
        }

        // Mode policy: safe/plan deny identity-mutating tools outright;
        // auto/studio prompt for outside-workspace path targets; drive never
        // prompts. `bypassPermission` only skips the ordinary user prompt —
        // the hard gates above are checked FIRST and never widened by a hook.
        const policy = modePolicy(mode, state.planMode);
        // Wave 1a (CH-001): attended Read-Only asks before every shell,
        // browser, network or write action. A user decision — so a hook's
        // bypassPermission never skips it — and an allow lets it run.
        let safeModeAsked = false;
        if (
          result === null &&
          policy.askBeforeActions &&
          !job.unattended &&
          safeModeNeedsApproval(call.name, effectiveArgs)
        ) {
          safeModeAsked = true;
          const decision = await deps.approvals.approve(
            {
              sessionId,
              runId,
              userId,
              mode,
              planMode: state.planMode,
              unattended: job.unattended,
              signal: abortSignal,
            },
            {
              approvalId: randomUUID(),
              kind: "tool",
              tool: call.name,
              summary: `Read-Only mode: allow ${call.name}?`,
              detail: safeModeApprovalDetail(call.name, effectiveArgs),
              allowAlways: false,
              pathTargets: [],
              hostTargets: [],
            },
          );
          if (decision !== "allow" && decision !== "always") {
            result = { content: "DENIED by user", isError: true };
          }
        }
        if (
          result === null &&
          !safeModeAsked &&
          !policy.canMutate &&
          isMutatingTool(call.name, effectiveArgs)
        ) {
          result = {
            content: state.planMode ? planModeDenial(call.name) : READ_ONLY_DENIAL,
            isError: true,
          };
        }
        // Destructive-command confirmation (Dart parity): run_shell,
        // job_start and run_code payloads; every mode, including Full Access;
        // deliberately NOT skippable by a hook `permissionDecision:"allow"`
        // (bypassPermission is not consulted).
        if (result === null) {
          const payload = destructivePayloadOf(call.name, effectiveArgs);
          if (payload !== null && isDestructiveShellCommand(payload)) {
            const decision = await deps.approvals.approve(
              {
                sessionId,
                runId,
                userId,
                mode,
                planMode: state.planMode,
                unattended: job.unattended,
                signal: abortSignal,
              },
              {
                approvalId: randomUUID(),
                kind: "tool",
                tool: call.name,
                summary: "Destructive command",
                detail: payload,
                allowAlways: false,
                pathTargets: [],
                hostTargets: [],
              },
            );
            if (decision !== "allow" && decision !== "always") {
              result = { content: "DENIED by user", isError: true };
            }
          }
        }
        // Plan mode asks NOTHING (Dart AS:19083–19099): a plan-allowed read
        // whose target is outside the workspace is refused OUTRIGHT — no
        // approval card is ever raised while planning.
        if (
          result === null &&
          policy.approvalForOutside &&
          policy.confineToWorkspace
        ) {
          const outside = outsideWorkspaceTargets(effectiveArgs);
          if (outside.length > 0) {
            if (state.planMode) {
              result = {
                content:
                  `DENIED: ${call.name} may not access targets outside the session ` +
                  `workspace while planning (${outside.join(", ")}). Plan mode asks ` +
                  "nothing — write the step into the plan instead.",
                isError: true,
              };
            } else if (!bypassPermission) {
              const decision = await deps.approvals.approve(
                {
                  sessionId,
                  runId,
                  userId,
                  mode,
                  planMode: state.planMode,
                  unattended: job.unattended,
                  signal: abortSignal,
                },
                {
                  approvalId: randomUUID(),
                  kind: "tool",
                  tool: call.name,
                  summary: `Access outside the workspace: ${outside.join(", ")}`,
                  detail:
                    `${call.name} wants to touch targets outside the session workspace:\n` +
                    outside.join("\n"),
                  allowAlways: true,
                  pathTargets: outside,
                  hostTargets: [],
                },
              );
              if (decision !== "allow" && decision !== "always") {
                result = { content: "DENIED by user", isError: true };
              }
            }
          }
        }

        const callKey = `${runId}:${call.id}`;
        let dispatched = false;
        if (result === null) {
          dispatched = true;
          const toolCtx: ToolContext = {
            sessionId,
            runId,
            userId,
            mode,
            planMode: state.planMode,
            isSubagent: job.isSubagent ?? false,
            depth: job.depth ?? 0,
            unattended: job.unattended,
            callKey,
            signal: abortSignal,
          };
          try {
            // T9-C1: toolName is part of the single withToolTimeout arity;
            // T9-I2: the dispatch budget is EXACTLY tool.timeoutMs (never a
            // shorter override — the adapter's kill primitive is clamped to
            // the same budget).
            result = await withToolTimeout(tool!.execute(effectiveArgs, toolCtx), {
              timeoutMs: tool!.timeoutMs,
              callKey,
              toolName: call.name,
              onKill: async () => {
                if (deps.sandbox !== null) await deps.sandbox.killCall(userId, callKey);
              },
            });
          } catch (err) {
            // T9-I1 carry: sandbox availability failures terminalize the RUN
            // (P1/P2 run_failed codes) — never a model-visible tool error the
            // model would fruitlessly retry.
            const sandboxCode = sandboxFailureCode(err);
            if (sandboxCode !== null) return await failed(sandboxCode, messageOf(err));
            // Any other tool failure is a model-visible result (Dart parity).
            result = { content: `tool error: ${messageOf(err)}`, isError: true };
          }
        }

        // A Stop-raced tool result is DROPPED — never rendered or fed to the
        // next request (Dart AS:12708–12712).
        if (isCancelled(rt)) return await cancelled();

        // Dart re-arms the todo follow-through nudge on every todo_write
        // (AS:21925 `todoNudgeSent = false` — "allow one more follow-through
        // nudge"). Only a DISPATCHED todo_write re-arms: a hook/roster
        // denial never ran the handler, so it must not extend the cadence.
        if (dispatched && call.name === "todo_write") g.todoNudgeSent = false;

        // Guard notes are computed on the RAW result, then the row is
        // spilled (Dart AS:12759–12763 order).
        const guarded = recordToolResult(g, call.name, effectiveArgs, result.content);
        let rowContent = guarded.result;
        if (deps.spillToolResults !== false && deps.sandbox !== null) {
          rowContent = await spillToolOutput(
            { sandbox: deps.sandbox, userId, workspaceRelDir: "" },
            call.name,
            rowContent,
            toolOutputCapFor(call.name),
          );
        }

        const truncated = rowContent.length > TOOL_EVENT_CONTENT_CAP;
        await emit("tool_completed", {
          runId,
          callId: call.id,
          name: call.name,
          ok: result.isError !== true,
          isError: result.isError === true,
          content: rowContent.slice(0, TOOL_EVENT_CONTENT_CAP),
          truncated,
        });

        // F11: the loop fires the FULL HookEvent set. post_tool is
        // fire-and-forget and observe-only (Task 18 implements the engine).
        // Dart fires PostToolUse only after `_dispatchInner` — a hook/roster/
        // mode/approval denial never reaches it (M-1).
        if (dispatched) {
          void deps.hooks
            .fire("post_tool", sessionId, {
              tool: call.name,
              result: rowContent.slice(0, 400),
              ok: result.isError !== true,
            })
            .catch(() => {});
        }

        msgs.push({ role: "tool", toolCallId: call.id, content: rowContent });
      }

      // ── 11. steering drain after the tool round ────────────────────────
      const afterTools = await drainQueuedRuns(
        { db: deps.db, sink: deps.sink },
        { sessionId, activeRunId: runId },
      );
      if (afterTools.length > 0) msgs.push(...afterTools);

      // ── 12. budget boundary (only after a real reply) ──────────────────
      if (isBudgetBoundary(turn)) {
        const compacted = await deps.compactor.maybeCompact({
          sessionId,
          messages: msgs,
          windowTokens: deps.windowTokens,
          foldBoundary: isCheckpointRow(msgs[0]) ? 1 : 0,
        });
        // T19 carry (T16 review I4): apply the RETURNED messages even when
        // `compacted === false` — prune-only relief rewrites oversized tool
        // rows without folding a summary, and discarding it would re-send the
        // full output on the next turn.
        msgs = [...compacted.messages];
        // Dart AS:12795–12801 appends the continuation nudge on EVERY budget
        // boundary (the plan's "if it folded … and inject" wording reads as
        // conditional; the map pins the always-append Dart behavior — the
        // nudge is what keeps a never-stop run going past turn 12).
        msgs.push({ role: "user", content: BUDGET_CONTINUATION_NUDGE });
        g.turnsWithoutProgress += 1;
      }
    }
  } finally {
    // G2: a transition queued during the LAST turn must not be stranded —
    // land it as the run unwinds (the Stop path included, AS:12826–12836).
    try {
      await landPendingPlanMode();
    } catch {
      // An unwind-time state read must never mask the run's real outcome.
    }
  }
}
