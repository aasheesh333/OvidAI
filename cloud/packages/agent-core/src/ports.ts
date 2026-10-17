// Ports: the boundaries the agent core consumes. Adapters live in the apps
// (worker/gateway); agent-core itself imports only @ovid/shared — enforced by
// dependencyDirection.test.ts.

import type { SessionEventType } from "@ovid/shared";
import type { AgentMessage, SessionMode, ToolContext } from "./types.js";

export interface SandboxPort {            // adapter over the P2 SandboxManager exec/PTY API lives in apps/worker (Task 9)
  exec(userId: string, o: { cmd: string; cwd?: string; timeoutMs?: number; callKey?: string; env?: Record<string, string> }): Promise<{ exitCode: number; stdout: string; stderr: string }>;
  killCall(userId: string, callKey: string): Promise<void>;
  readFile(userId: string, path: string): Promise<string>;
  writeFile(userId: string, path: string, content: string): Promise<void>;
  exists(userId: string, path: string): Promise<boolean>;
  listDir(userId: string, path: string): Promise<string[]>;
  jobStart(userId: string, o: { cmd: string; cwd?: string }): Promise<{ jobId: string }>;
  jobOutput(userId: string, jobId: string, o?: { offset?: number }): Promise<{ output: string; running: boolean; exitCode: number | null }>;
  jobList(userId: string): Promise<Array<{ jobId: string; cmd: string; running: boolean }>>;
  jobKill(userId: string, jobId: string): Promise<void>;
}

/**
 * Sandbox availability failures that are RUN-level, not tool-level (P3 Task
 * 15 / T9-I1 carry). The worker's SandboxPort adapter rethrows the sandbox
 * package's typed errors (SandboxAdmissionError / SandboxCapacityError /
 * RootfsUnavailable); agent-core cannot import @ovid/sandbox (dependency
 * direction + lockfile rule), so classification is by the stable class NAME
 * the sandbox package pins — the same names its own wire mapping keys on
 * (worker ptyBridge.ts: `SandboxAdmissionError → sandbox_busy`,
 * `SandboxCapacityError → sandbox_unavailable`).
 */
export type SandboxFailureCode = "sandbox_busy" | "sandbox_unavailable";

export function sandboxFailureCode(err: unknown): SandboxFailureCode | null {
  const name = (err as { name?: unknown } | null)?.name;
  if (name === "SandboxAdmissionError") return "sandbox_busy";
  if (name === "SandboxCapacityError" || name === "RootfsUnavailable") {
    return "sandbox_unavailable";
  }
  return null;
}
export type EgressFetch = (url: string, init?: RequestInit) => Promise<Response>;   // SSRF-guarded (Task 2)
export type ApprovalDecision = "allow" | "deny" | "always";
export interface ApprovalRequest {
  approvalId: string; kind: "tool" | "question" | "plan"; tool: string;
  summary: string; detail: string; allowAlways: boolean;
  pathTargets: string[]; hostTargets: string[];
  questions?: Array<{ question: string; options?: string[] }>;
}
export interface ApprovalBridge {         // worker implements over session events + Redis pub/sub (Task 12)
  ask(req: ApprovalRequest, o: { sessionId: string; userId: string; timeoutMs: number; signal: AbortSignal }): Promise<ApprovalDecision | "timeout">;
}
export interface ApprovalGate {           // grants + bridge + events (Task 12)
  approve(ctx: Pick<ToolContext, "sessionId" | "runId" | "userId" | "mode" | "planMode" | "unattended" | "signal">, req: ApprovalRequest): Promise<ApprovalDecision>;
}
export type HookEvent = "session_start" | "user_prompt_submit" | "pre_request" | "post_request" | "pre_tool" | "post_tool" | "stop" | "subagent_stop" | "notification";
export interface HookGateResult { decision: "allow" | "deny" | "ask"; updatedInput?: Record<string, unknown>; reason?: string | null; bypassPermission?: boolean; decidedByPlugin?: string | null; deniedByPlugin?: string | null; }
export type HookStopResult = { veto: false } | { veto: true; reason: string | null; vetoedByPlugin: string | null };
/**
 * Full observe-fire result. `output`/`systemMessages`/`promptBlockReason` are
 * the original three fields (loop.ts consumes them). The rest are ADDITIVE
 * (T18 fix round) and carry the Dart `PostToolHookResult.fromFire` contract so
 * the worker can apply post_tool decisions/context to the tool row:
 *  • exit2Feedback       — exit 2 stderr on post_tool ("tool already ran");
 *  • blockReasons        — `decision:"block"` reasons on post_tool;
 *  • additionalContext   — extracted `additionalContext` values;
 *  • updatedToolOutput   — `hookSpecificOutput.updatedToolOutput` replacement
 *                          (last non-null wins), JSON-encoded when non-string;
 *  • hookOutputs         — each successful hook's published stdout.
 * T16 owns consuming these in the loop (see task-18-report.md).
 */
export interface HookFireResult {
  output: string;
  systemMessages: string[];
  promptBlockReason: string | null;
  exit2Feedback?: string[];
  blockReasons?: string[];
  additionalContext?: string[];
  updatedToolOutput?: string | null;
  hookOutputs?: string[];
}
export interface HookEngine {
  hasListeners(event: HookEvent, sessionId: string): Promise<boolean>;
  fire(event: HookEvent, sessionId: string, payload: Record<string, unknown>): Promise<void>;                       // observe-only
  fireDetailed(event: HookEvent, sessionId: string, payload: Record<string, unknown>): Promise<HookFireResult>;
  fireGate(sessionId: string, payload: { tool: string; args: Record<string, unknown> }): Promise<HookGateResult>;   // pre_tool
  fireStop(sessionId: string, payload: Record<string, unknown>, event?: "stop" | "subagent_stop"): Promise<HookStopResult>;
  sessionContextFor(sessionId: string): string;
  promptContextFor(sessionId: string): string | null;
}
export interface Compactor {              // Task 19
  /**
   * `foldBoundary` (additive, fix round I-3) is the window-relative index of
   * the first unfolded message — compute it for a DB-rebuilt history with
   * `foldBoundaryFor`. The returned `foldBoundary` is the boundary of the
   * RETURNED array (0 = nothing folded, 1 = the checkpoint row at index 0).
   */
  maybeCompact(i: { sessionId: string; messages: AgentMessage[]; windowTokens: number; foldBoundary?: number }): Promise<{ compacted: boolean; messages: AgentMessage[]; foldBoundary?: number }>;
  pruneOversizedToolResults(i: { sessionId: string; messages: AgentMessage[]; thresholdTokens: number }): Promise<{ pruned: number; messages: AgentMessage[] }>;
}
export interface TodoItem { content: string; status: "pending" | "in_progress" | "completed"; }
export interface SessionGoal { objective: string; notes: string; }
export interface CompactionStateJson { ledger: unknown; summary: string | null; cutoffMessageId: string | null; compactedAtCount: number; }
// ADDITIVE state fields (ruling R4): mode/modelPin give /permission and /model pinning storage;
// activeSkillScopes gives the skill tool (Task 17) its roster-scoping home. Dart's agent state is
// the parity reference for todos/goal/preset/plan fields; these three are cloud-session additions.
export interface SessionAgentState { todos: TodoItem[]; goal: SessionGoal | null; presetId: string | null; planMode: boolean; planPreMode: SessionMode | null; pendingPlanMode: boolean | null; compaction: CompactionStateJson | null; mode: SessionMode; modelPin: string | null; activeSkillScopes: string[]; }
export interface SessionStateStore {      // Task 13 (Postgres); in-memory fake for earlier tasks
  get(sessionId: string): Promise<SessionAgentState>;
  patch(sessionId: string, p: Partial<SessionAgentState>): Promise<void>;
}
export function createMemoryStateStore(): SessionStateStore {   // test/dev fake, exported for reuse
  const zero = (): SessionAgentState => ({
    todos: [],
    goal: null,
    presetId: null,
    planMode: false,
    planPreMode: null,
    pendingPlanMode: null,
    compaction: null,
    mode: "auto",
    modelPin: null,
    activeSkillScopes: [],
  });
  const sessions = new Map<string, SessionAgentState>();
  const ensure = (sessionId: string): SessionAgentState => {
    let state = sessions.get(sessionId);
    if (!state) {
      state = zero();
      sessions.set(sessionId, state);
    }
    return state;
  };
  return {
    async get(sessionId: string): Promise<SessionAgentState> {
      return ensure(sessionId);
    },
    async patch(sessionId: string, p: Partial<SessionAgentState>): Promise<void> {
      Object.assign(ensure(sessionId), p);
    },
  };
}
export interface SkillSummary { name: string; description: string; whenToUse: string; userInvocable: boolean; modelInvocable: boolean; }
export interface Skill { name: string; description: string; whenToUse: string; content: string; path: string; allowedTools: string[]; }
export interface SkillCatalog {           // Task 17
  list(sessionId: string): Promise<SkillSummary[]>;
  load(name: string, sessionId: string): Promise<Skill | null>;
}
export interface EventSink { emit(type: SessionEventType, payload: Record<string, unknown>): Promise<void>; }
export interface GitHubApiPort {          // Task 11
  getTree(userId: string, o: { owner: string; repo: string; ref?: string; recursive?: boolean }): Promise<Array<{ path: string; type: "blob" | "tree"; size?: number }>>;
}
