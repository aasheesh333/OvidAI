import { mkdir, writeFile } from "node:fs/promises";
import { AsyncLocalStorage } from "node:async_hooks";
import { join } from "node:path";
import { attachments, eventMirror, grantsRepo, messages, runs, type Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import type { AgentRunJob } from "@ovid/queue";
import {
  RootfsUnavailable,
  SandboxAdmissionError,
  SandboxCapacityError,
  type ExecRequest,
  type ExecResult,
  type SandboxHandle,
  type SandboxManager,
} from "@ovid/sandbox";
import {
  imageMimeTypeFor,
  modelVisionSupport,
  visionRefusalMessage,
  type ModelCapabilityRow,
} from "./modelCapabilities.js";
import {
  sanitizeAttachmentName,
  type KeyResolver,
  type SessionEvent,
  type SessionEventType,
} from "@ovid/shared";
import type { AgentImage } from "@ovid/agent-core";
import type { ActivityTracker } from "@ovid/storage";
import type { Redis } from "ioredis";
import {
  APPROVAL_TIMEOUT_MS,
  AUTO_ALIASES,
  adaptLegacyTransport,
  commandPrePass,
  createAgentEngine,
  createAnthropicTransport,
  createApprovalGate,
  createCommandRunner,
  createCompactor,
  createExitPlanModeTool,
  createFetchUrlTool,
  createFileHookSource,
  createGitTools,
  createGoalTodoTools,
  createGuardedEgressFetch,
  createHookEngine,
  createMemoryTools,
  createOpenAiAgentTransport,
  createPostgresSessionStateStore,
  createRepoTools,
  createSandboxTools,
  createSessionSearchTool,
  createSkillActivation,
  createSkillCatalog,
  createSkillTool,
  createSsrfGuard,
  createSubagentSupervisor,
  createSubagentTools,
  createToolRegistry as createCoreToolRegistry,
  createWebSearchTool,
  findApplicableGrant,
  foldBoundaryFor,
  normalizeGrantHost,
  presetById,
  resolveRoute,
  type AgentTransport,
  type AgentEngine,
  type Compactor,
  type EgressFetch,
  type EgressHopHook,
  type GitHubApiPort,
  type HookEngine,
  type SandboxPort,
  type SessionMode,
  type SkillCatalog,
  type SsrfGuard,
  type Tool as CoreTool,
  type ToolRegistry as CoreToolRegistry,
} from "@ovid/agent-core";
import { createRedisApprovalBridge } from "./approvalBridge.js";
import { agentKeyFor } from "./keyResolver.js";
import {
  DEFAULT_STREAM_IDLE_TIMEOUT_MS,
  TerminalModelError,
  TransientModelError,
  withAgentStreamIdleTimeout,
  withLegacyStreamIdleTimeout,
  type ChatMessage,
  type ModelTransport,
  type ToolCall,
} from "./liteLlm.js";
import { createSandboxPort } from "./sandboxAdapter.js";
import { unattendedTimeoutPolicy, type UnattendedApprovalHook } from "./unattended.js";
import { adaptAgentTools } from "./tools/agentToolAdapter.js";
import { createToolRegistry, type ToolRegistry } from "./tools/registry.js";
import { MAX_TOOL_ROUNDS, SYSTEM_PROMPT_V1, TOOL_EVENT_CONTENT_CAP } from "./tools/systemPrompt.js";
import type { ToolContext, ToolResult } from "./tools/types.js";

/**
 * Agent-run processor v1 (P3 Task 16): the P2-compat contract backed by the
 * agent-core engine, plus the full-deps production processor.
 *
 * One BullMQ job = one run. The processor NEVER throws for run-level failures
 * (missing key, model errors, sandbox admission): those are terminal run
 * states, emitted as events and recorded on the run row, and the job must
 * COMPLETE (attempts: 1 — the retry ladder lives in the engine, not BullMQ).
 * Crashed/failed jobs are never redelivered; the stale-run sweeper
 * (staleRuns.ts) terminalizes runs they strand in 'running'. Only
 * infrastructure errors (db/redis down) propagate and fail the job loudly.
 *
 * Two processor shapes:
 *
 * - `createAgentRunProcessor(deps)` — the P2-compat contract. Its landed
 *   RunDeps shape is unchanged (ruling R1): P2's six-tool roster is ADAPTED
 *   through `agentToolAdapter` into the canonical seam, and the engine runs
 *   BOUNDED with `maxToolRounds = MAX_TOOL_ROUNDS (50)` and
 *   `systemPromptOverride = SYSTEM_PROMPT_V1`. A worker-side compat sink
 *   normalizes the wire back to P2's exact spellings (see compatEvent):
 *   tool_started carries `input` (no `args`), tool_completed carries
 *   `isError` (no `ok`), `model_transient_exhausted` carries no message, and
 *   the engine's `run_cancelled` becomes P2's `run_failed {code:"cancelled"}`.
 *   P1's tool-less composition (the e2e spine, no sandbox/tools) keeps the
 *   v0 streaming loop byte-for-byte — it is a documented legacy guard, not
 *   the P2 path.
 *
 * - `createFullAgentRunProcessor(deps)` — the production path: real openai +
 *   anthropic transports over guarded egress, the full roster (P2's six
 *   adapted + P3 sandbox/web/git/repo/memory/goals/todos/session_search/
 *   exit_plan_mode), the Postgres session-state store, the redis approval
 *   bridge and the never-stop loop.
 *
 * Event contract (every append is also mirrored to Postgres via
 * eventMirror.put — history beyond the stream's trim window):
 * - run_started        {runId}
 * - message_delta      {runId, text}          — per streamed delta, in arrival order
 * - run_started_retry  {attempt, nextBackoffMs} — attempt = the attempt ABOUT
 *   to start (2..5); emitted after a transient failure of the previous one
 * - tool_started        {runId, callId, name, input}   — v1 (P2 Task 12); per
 *   requested call, before execution; input = parsed arguments (or {raw})
 * - tool_completed      {runId, callId, name, isError, content ≤ 8192, truncated}
 * - system_note         {code:"command_blocked", message, command} — emitted BY
 *   the run_shell tool when layer 1 refuses a command (spec §7)
 * - message_completed  {messageId, content}
 * - run_completed      {runId}
 * - run_failed         {code: "key_not_minted" | "model_transient_exhausted"
 *                        | "run_queue_wait_timeout"
 *                        | {code:"sandbox_unavailable", message}
 *                        | {code:"tool_rounds_exhausted"}}
 *                      | {code: "model_terminal", message}
 *                      | {code: "cancelled", message: "Stopped by user."}
 *                      — the cancelled variant (P8 Task 1) is emitted BOTH by
 *                      the gateway (queued-run cancel) and by this processor
 *                      (mid-stream abort after the throttled flag check).
 *   (the stale-run sweeper emits a third variant, {runId, code:"run_lost"} —
 *   see staleRuns.ts)
 *
 * The FULL engine emits the P3 spellings (tool_started carries `args` and
 * `input`; tool_completed carries `ok` and `isError`; cancellation is
 * `run_cancelled`). Both spellings stay on the wire through this task; the
 * compat sink strips the additive ones so P2's suite passes unmodified.
 *
 * Terminal events are emitted BEFORE the run row's status flip on every path
 * (completed and failed alike): the C1 wait loop below unblocks the next
 * same-session run by watching the status flip, so event-first ordering is
 * what guarantees the next run's run_started lands strictly after this run's
 * terminal event. (The engine's cancel path flips first; a cancelled run's
 * successor is not part of the P1 spine and this is flagged in the report.)
 */

/**
 * P8 Task 3: the attachment-download seam — structurally
 * StorageAdapter.getBuffer from @ovid/storage, so the R2 adapter (or the fs
 * adapter in dev) satisfies it as-is. Injectable via RunDeps.storage; the
 * composition root wires it.
 */
export interface RunAttachmentStorage {
  /** null = object missing (the client never completed the upload). */
  getBuffer(key: string): Promise<Buffer | null>;
}

export interface RunDeps {
  db: Db;
  events: EventLog;
  /**
   * P9 Task 9: server-side resolution (LiteLLM key, BYOK escrow, or a signed
   * internal mint for unattended runs). The processor never reads mint's
   * Redis directly — the resolver owns that order.
   */
  keys: KeyResolver;
  transport: ModelTransport;
  litellmBaseUrl: string;
  defaultModel: string;
  /**
   * Push delivery for run failures the user must act on (owner directive
   * 2026-10-18). Absent → the failure still lands in the run log and the
   * session event stream; only the push is skipped.
   */
  notifier?: { notifyAgentFailed(a: {
    userId: string;
    sessionId: string;
    sessionTitle: string;
    code: string;
    message: string;
  }): Promise<void> };
  /**
   * The model catalog, read once per run only when the run carries images
   * (see modelCapabilities.ts). Absent → the static family list decides.
   */
  modelCatalog?: () => Promise<readonly ModelCapabilityRow[] | null>;
  /**
   * P2 Task 12: the sandbox the run's tools execute in, and the tool roster.
   * main.ts (composition root) always wires both. They are OPTIONAL in the
   * type because the processor carries a documented runtime guard for the
   * pre-P2 shape: when either is absent it runs the v0 tool-less loop
   * unchanged (no attach, no system prompt, no tools param). The P1 spine e2e
   * (apps/e2e spine.test.ts) constructs exactly that legacy shape and must
   * stay green unmodified.
   */
  sandbox?: SandboxManager;
  tools?: ToolRegistry;
  sleep?: (ms: number) => Promise<void>;
  /**
   * P10 Task 2: per-chunk SSE idle deadline (ms). No delta for this long ⇒
   * the in-flight request is aborted and classified TRANSIENT (enters the
   * 3/9/27/60 s ladder). Default DEFAULT_STREAM_IDLE_TIMEOUT_MS (120 s);
   * a fresh timer is armed for every attempt.
   */
  streamIdleTimeoutMs?: number;
  /**
   * Cap on how long a job may wait for older active runs of the same session
   * (C1), in ms. Default DEFAULT_RUN_QUEUE_WAIT_MS; the worker entry point
   * reads OVID_RUN_QUEUE_WAIT_MS.
   */
  runQueueWaitMs?: number;
  /**
   * P8 Task 1: throttle window of the cooperative-cancel flag poll, in ms.
   * Between streamed delta batches the processor checks
   * runs.isCancelRequested at most once per window (monotonic Date.now
   * guard). Default DEFAULT_CANCEL_CHECK_INTERVAL_MS (1 s) — the worker entry
   * point never overrides it; tests collapse the window to 0 to pin the
   * mid-stream abort.
   */
  cancelCheckIntervalMs?: number;
  /**
   * P8 Task 3: object-download seam for attachment materialization (see
   * RunAttachmentStorage). OPTIONAL for the same source-compat reason as
   * sandbox/tools: the P1 spine e2e's pre-P2 composition must stay green
   * unmodified. When a job carries attachmentIds but this is absent, the
   * run fails loudly with attachment_unavailable (never a silent skip);
   * main.ts always wires it.
   */
  storage?: RunAttachmentStorage;
  /**
   * P7 Task 11: hydrate the session workspace before any tool can run.
   * A rejection is a RUN-LEVEL failure (run_failed {code:"hydrate_failed"},
   * run row failed), never a job throw — the same shape as key_not_minted.
   * Optional so the legacy P1 composition keeps its v0 behavior; main.ts
   * always wires it.
   */
  ensureWarm?: (sessionId: string, userId: string) => Promise<void>;
  /**
   * P7 Task 11: the session activity tracker (redis-c, cache-class). Bumped
   * after the claim and after the run finishes; a bump failure is swallowed
   * (eviction/restart must never fail a run).
   */
  activity?: ActivityTracker;
}

/**
 * Production deps (P3 Task 16). `sandbox` is the P2 SandboxManager adapted
 * onto the canonical SandboxPort (`createSandboxPort`); `sandboxHandleFor`
 * optionally supplies the P2 handle used by the adapted six-tool roster
 * (main wires `manager.attach`). Without it the adapted tools run over a
 * port-backed handle (fine for shell/job tools; the host-side file tools
 * need the real handle).
 */
export interface FullRunDeps {
  db: Db;
  events: EventLog;
  /**
   * Push delivery for run failures the user must act on (owner directive
   * 2026-10-18). Absent → the failure still lands in the run log and the
   * session event stream; only the push is skipped.
   */
  notifier?: { notifyAgentFailed(a: {
    userId: string;
    sessionId: string;
    sessionTitle: string;
    code: string;
    message: string;
  }): Promise<void> };
  /**
   * The model catalog, read once per run only when the run carries images
   * (see modelCapabilities.ts). Absent → the static family list decides.
   */
  modelCatalog?: () => Promise<readonly ModelCapabilityRow[] | null>;

  /** P9 Task 9: see RunDeps.keys. */
  keys: KeyResolver;
  redisQ: Redis;
  sandbox: SandboxPort;
  github: GitHubApiPort | null;
  litellmBaseUrl: string;
  defaultModel: string;
  anthropicBaseUrl: string;
  windowTokens?: number;
  approvalTimeoutMs?: number;
  /** C1 cap (env OVID_RUN_QUEUE_WAIT_MS); default 10 min. */
  runQueueWaitMs?: number;
  sleep?: (ms: number) => Promise<void>;
  /**
   * P10 Task 2: per-chunk SSE idle deadline (ms) for BOTH provider
   * transports. Default 120000; a fresh timer is armed per attempt.
   */
  streamIdleTimeoutMs?: number;
  /** Optional P2 handle factory (production: SandboxManager.attach). */
  sandboxHandleFor?: (userId: string, tier: "free" | "pro") => Promise<SandboxHandle>;
  /**
   * P3 Task 16 review I2: per-tier SandboxPort. Production wires one port per
   * tier so the user's quota project is honoured (`free` 500 MB / `pro`
   * 2048 MB); absent → `sandbox` serves both tiers (tests/dev).
   */
  sandboxForTier?: (tier: "free" | "pro") => SandboxPort;
  /**
   * Test-only egress override. Production MUST omit this: the default is the
   * provider-origin allowlist over the SSRF-guarded fetch (spec D3/§11).
   * Tests inject a plain fetch to reach a loopback SSE mock (the T5-I1
   * pattern).
   */
  egress?: EgressFetch;
  /** Secrets scrubbed from hook payloads (env-provided; default none). */
  hookSecrets?: () => readonly string[];
  /** Optional attachment seam (see RunAttachmentStorage). */
  storage?: RunAttachmentStorage;
  /** P7 Task 11: hydrate before the run (see RunDeps.ensureWarm). */
  ensureWarm?: (sessionId: string, userId: string) => Promise<void>;
  /** P7 Task 11: last-activity tracker (see RunDeps.activity). */
  activity?: ActivityTracker;
  /**
   * P4 Task 10: the unattended-approval seam (Task 7's hook). Production
   * wires it; its presence installs the P3 `timeoutPolicy` so scheduled runs
   * get the pinned 120 s default-deny. Absent → the gate's pre-P4 behavior.
   */
  unattendedApprovalHook?: UnattendedApprovalHook;
  /**
   * P4 Task 13: extra tools registered on the per-run roster. The scheduler
   * tools (`createScheduleTools`) enter production this way. Canonical
   * `Tool[]` (not the P2 shape): they need no sandbox handle, so adapting
   * them through `adaptAgentTool` would force a needless per-call attach.
   * Additive (same pattern as `unattendedApprovalHook` above): absent → the
   * pre-P4 roster exactly.
   */
  extraTools?: readonly CoreTool[];
  /**
   * P6 browser tools (owner directive 2026-10-18): the full Playwright /
   * Lightpanda action suite, adapted onto the canonical Tool seam. Absent →
   * the agent cannot browse (the pre-2026-10-18 behaviour, kept for
   * deployments without a browser engine).
   */
  browserTools?: readonly CoreTool[];
  /**
   * Ends this run's browser session: stops the screencast, captures and
   * flushes `storageState`, closes the context and releases the pool slot.
   * Called in the run's terminal `finally` so a context never outlives its
   * run (the 15 s ephemeral lease is the backstop, not the contract).
   */
  browserReleaseSession?: (sessionId: string) => Promise<void>;
  /**
   * P5 Task 11 I4: release this run's MCP connections when it ends. Custom
   * stdio (and legacy SSE) connections are per-run; without this they would
   * live until process shutdown. The composition root wires the MCP router's
   * `releaseRun`; absent → no-op (deployments without an MCP runtime).
   */
  mcpReleaseRun?: (
    uid: string,
    runCtx: { sessionId: string; runId: string },
  ) => Promise<void>;
}

/** The full processor plus its shutdown handle (the redis approval bridge). */
export interface FullAgentRunProcessor {
  (
    job: {
      data: AgentRunJob & {
        unattended?: boolean;
        autonomy?: "safe" | "auto";
        mode?: "safe" | "auto" | "drive" | "studio";
      };
    },
  ): Promise<void>;
  /** Closes the approval bridge's subscription (graceful shutdown). */
  close(): Promise<void>;
}

/** Model-call retry policy (spec §6.1): 5 attempts, backoff 3/9/27/60 s between them. */
const MAX_MODEL_ATTEMPTS = 5;
const RETRY_BACKOFF_MS: readonly number[] = [3_000, 9_000, 27_000, 60_000];

/** Context window cap for v0: newest 100 stored messages, oldest-first. */
/**
 * Image-prompt bounds (owner directive 2026-10-18). Providers cap image count
 * and payload size; exceeding either fails the whole request, so the worker
 * forwards the first few and leaves the rest as workspace files the tools can
 * still open. 4 images / ~8 MB of base64 matches what the routed providers
 * accept today.
 */
const MAX_PROMPT_IMAGES = 4;
const MAX_PROMPT_IMAGE_BYTES = 8 * 1024 * 1024;

const HISTORY_LIMIT = 100;

/**
 * C1: poll interval of the single-active-run-per-session wait loop. Real
 * wall-clock waiting in production; tests inject their own sleep.
 */
const RUN_QUEUE_POLL_MS = 250;

/**
 * C1 default: a job may wait at most 10 minutes for older same-session runs
 * before it is terminalized as failed (run_queue_wait_timeout).
 */
const DEFAULT_RUN_QUEUE_WAIT_MS = 600_000;

/** The cancelled-run failure payload (P8 Task 1) — same words the gateway emits. */
const CANCELLED_MESSAGE = "Stopped by user.";

/**
 * P8 Task 1 default: the cooperative-cancel flag is polled at most once per
 * second between streamed delta batches (one pk-indexed read per window).
 */
const DEFAULT_CANCEL_CHECK_INTERVAL_MS = 1_000;

/** Full-processor default context window (P3 spec §6). */
const DEFAULT_WINDOW_TOKENS = 128_000;

const defaultSleep = (ms: number): Promise<void> =>
  new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });

// ---------------------------------------------------------------------------
// Engine plumbing shared by both processors
// ---------------------------------------------------------------------------

/**
 * No-op hooks until Task 18 wires the real plugin engine. `fireGate` allows,
 * `fireStop` never vetoes, contexts are empty, and nothing has listeners —
 * the loop's hook steps are pure no-ops.
 */
const NOOP_HOOKS: HookEngine = {
  async hasListeners() {
    return false;
  },
  async fire() {},
  async fireDetailed() {
    return { output: "", systemMessages: [], promptBlockReason: null };
  },
  async fireGate() {
    return { decision: "allow" };
  },
  async fireStop() {
    return { veto: false };
  },
  sessionContextFor() {
    return "";
  },
  promptContextFor() {
    return null;
  },
};

/** No-op compactor until Task 19: history passes through unchanged. */
const NOOP_COMPACTOR: Compactor = {
  async maybeCompact(i) {
    return { compacted: false, messages: i.messages };
  },
  async pruneOversizedToolResults(i) {
    return { pruned: 0, messages: i.messages };
  },
};

/** No-op skill catalog until Task 17: no catalog rows, no loadable skills. */
const NOOP_SKILLS: SkillCatalog = {
  async list() {
    return [];
  },
  async load() {
    return null;
  },
};

/**
 * A P2-compat event sink: the engine's P3 event payloads are normalized to
 * P2's exact wire shape before they reach Redis (and therefore the mirror).
 * The additive P3 spellings (`args`, `ok`) stay on the full processor's wire.
 */
function compatEvent(
  type: SessionEventType,
  payload: Record<string, unknown>,
): { type: SessionEventType; payload: Record<string, unknown> } {
  if (type === "run_cancelled") {
    return {
      type: "run_failed",
      payload: {
        code: "cancelled",
        message:
          typeof payload.message === "string" ? payload.message : CANCELLED_MESSAGE,
      },
    };
  }
  if (type === "tool_started") {
    const { args: _args, ...rest } = payload;
    return { type, payload: rest };
  }
  if (type === "tool_completed") {
    const { ok: _ok, ...rest } = payload;
    return { type, payload: rest };
  }
  if (type === "run_failed" && payload.code === "model_transient_exhausted") {
    // P2 pinned the bare code (the message is P3 additive).
    const { message: _message, ...rest } = payload;
    return { type, payload: rest };
  }
  return { type, payload };
}

/** EventLog wrapper applying `compatEvent` to every append (reads pass through). */
function compatEventLog(base: EventLog): EventLog {
  return {
    async append(sessionId, type, payload) {
      const mapped = compatEvent(type, payload);
      return base.append(sessionId, mapped.type, mapped.payload);
    },
    readSince(sessionId, lastSeq, limit) {
      return base.readSince(sessionId, lastSeq, limit);
    },
    subscribe(sessionId, onEvent) {
      return base.subscribe(sessionId, onEvent);
    },
  };
}

/**
 * A registry that answers unknown tool names with P2's pinned
 * `unknown_tool: <name>` result instead of the P3 roster denial. The synthetic
 * tool is never advertised (`all()` is untouched), so this only fires for a
 * hallucinated call — exactly P2's behavior.
 */
function withUnknownToolFallback(registry: CoreToolRegistry): CoreToolRegistry {
  return {
    get(name) {
      const known = registry.get(name);
      if (known !== undefined) return known;
      return {
        spec: { name, description: "", parameters: { type: "object", properties: {} } },
        timeoutMs: 120_000,
        async execute() {
          return { content: `unknown_tool: ${name}`, isError: true };
        },
      };
    },
    all() {
      return registry.all();
    },
  };
}

/**
 * Cooperative-cancel polling (P8 Task 1) for the engine path: the engine has
 * no per-delta DB hook, so the transport wrapper polls `runs.isCancelRequested`
 * on the same throttled cadence P2 used (first delta batch always polls;
 * later batches only after `intervalMs`). Pending checks are drained BEFORE
 * the stream returns, so the loop's post-stream `isCancelled` sees the flip.
 */
function withCancelPolling(
  base: AgentTransport,
  o: {
    intervalMs: number;
    isCancelRequested(): Promise<boolean>;
    onCancel(): Promise<void>;
  },
): AgentTransport {
  return {
    apiFormat: base.apiFormat,
    async stream(req, h, signal) {
      let lastCheck = 0;
      let pending: Promise<void> = Promise.resolve();
      const maybePoll = (): void => {
        const now = Date.now();
        if (now - lastCheck < o.intervalMs) return;
        lastCheck = now;
        pending = pending
          .then(async () => {
            if (await o.isCancelRequested()) await o.onCancel();
          })
          .catch(() => {});
      };
      const handlers = {
        onTextDelta(text: string): void {
          h.onTextDelta(text);
          maybePoll();
        },
        ...(h.onThinkingDelta !== undefined
          ? {
              onThinkingDelta(text: string): void {
                h.onThinkingDelta!(text);
              },
            }
          : {}),
      };
      try {
        const res = await base.stream(req, handlers, signal);
        await pending;
        return res;
      } catch (err) {
        await pending;
        throw err;
      }
    },
  };
}

/**
 * Provider egress (T16 review C1): the SSRF guard refuses loopback/private
 * hosts and non-80/443 ports, but the deployment's LiteLLM endpoint IS
 * `http://127.0.0.1:4000` (deploy/worker.env.example). Operator-configured
 * provider origins are therefore trusted EXACTLY (scheme + host + port) and
 * fetched directly; every other URL — every user-supplied URL — still goes
 * through the full guarded fetch (SSRF check, per-hop checks, redirect cap).
 *
 * Redirects on a provider origin are REFUSED: a provider response is not a
 * user grant, and following it could leave the trusted origin.
 */
export function createProviderEgress(o: {
  guard: SsrfGuard;
  providerBaseUrls: readonly string[];
  fetchImpl?: typeof fetch;
  maxRedirects?: number;
  onHop?: EgressHopHook;
}): EgressFetch {
  const fetchImpl = o.fetchImpl ?? fetch;
  const guarded = createGuardedEgressFetch(o.guard, fetchImpl, o.maxRedirects, o.onHop);
  const trusted = new Set<string>();
  for (const base of o.providerBaseUrls) {
    try {
      trusted.add(new URL(base).origin);
    } catch {
      // A malformed base URL is a config error the transport will surface;
      // it grants nothing here.
    }
  }
  return async (url, init) => {
    let origin: string | null = null;
    try {
      origin = new URL(url).origin;
    } catch {
      origin = null;
    }
    if (origin === null || !trusted.has(origin)) return guarded(url, init);
    const res = await fetchImpl(url, { ...init, redirect: "manual" });
    if (res.status >= 300 && res.status < 400) {
      // Release the body, then refuse: the provider must not redirect the
      // worker's credentialed request to an unvetted destination.
      try {
        await res.body?.cancel();
      } catch {
        /* already released */
      }
      throw new Error(`provider endpoint ${origin} returned a redirect; refusing to follow`);
    }
    return res;
  };
}

/**
 * A SandboxHandle synthesized over a SandboxPort — the full processor's
 * fallback when no P2 handle factory is wired. Shell/job tools work (exec is
 * delegated with the canonical callKey), but the P2 host-side file tools
 * resolve paths through `workspaceDir`, which this handle does NOT provide:
 * a missing factory must fail LOUD, never silently read/write the worker
 * host's filesystem (T16 review I5).
 */
function portBackedHandle(
  port: SandboxPort,
  ctx: { userId: string; callKey: string },
): SandboxHandle {
  const wiringError = (): never => {
    throw new Error(
      "worker wiring: FullRunDeps.sandboxHandleFor is required — the P2 " +
        "host-side file tools need the real sandbox handle (refusing to fall " +
        "back to the worker host filesystem)",
    );
  };
  return {
    userId: ctx.userId,
    uid: 0,
    get workspaceDir(): string {
      return wiringError();
    },
    get homeDir(): string {
      return wiringError();
    },
    jailWorkspaceDir: "/workspace",
    async exec(req: ExecRequest): Promise<ExecResult> {
      const res = await port.exec(ctx.userId, {
        cmd: req.command ?? (req.argv ?? []).join(" "),
        ...(req.cwd !== undefined ? { cwd: req.cwd } : {}),
        ...(req.timeoutMs !== undefined ? { timeoutMs: req.timeoutMs } : {}),
        ...(req.env !== undefined ? { env: req.env } : {}),
        callKey: ctx.callKey,
      });
      return {
        exitCode: res.exitCode,
        stdout: res.stdout,
        stderr: res.stderr,
        timedOut: false,
        truncated: false,
        blocked: false,
        refusal: null,
      };
    },
  } as unknown as SandboxHandle;
}

/**
 * The shared C1 gate: wait until this run is the oldest still-active run of
 * its session, bounded by runQueueWaitMs. Returns false when the cap was hit
 * (the failure event + run-row flip have already been emitted).
 */
async function waitForSessionTurn(o: {
  db: Db;
  sessionId: string;
  runId: string;
  runQueueWaitMs: number;
  sleep: (ms: number) => Promise<void>;
  emit(type: SessionEventType, payload: Record<string, unknown>): Promise<unknown>;
}): Promise<boolean> {
  const waitDeadline = Date.now() + o.runQueueWaitMs;
  for (;;) {
    const oldest = await runs.activeForSession(o.db, o.sessionId);
    if (oldest === null || oldest.id === o.runId) return true;
    if (Date.now() >= waitDeadline) {
      await o.emit("run_failed", { code: "run_queue_wait_timeout" });
      await runs.finish(o.db, o.runId, "failed", "run_queue_wait_timeout");
      return false;
    }
    await o.sleep(RUN_QUEUE_POLL_MS);
  }
}

// ---------------------------------------------------------------------------
// P2-compat processor
// ---------------------------------------------------------------------------

export function createAgentRunProcessor(
  deps: RunDeps,
): (job: { data: AgentRunJob }) => Promise<void> {
  const sleep = deps.sleep ?? defaultSleep;
  const runQueueWaitMs = deps.runQueueWaitMs ?? DEFAULT_RUN_QUEUE_WAIT_MS;
  const cancelCheckIntervalMs = deps.cancelCheckIntervalMs ?? DEFAULT_CANCEL_CHECK_INTERVAL_MS;
  // P10 Task 2: one idle-guarded view of the injected transport; every
  // attempt (v0 and the tool engine) gets a fresh idle arm per stream call.
  const transport = withLegacyStreamIdleTimeout(
    deps.transport,
    deps.streamIdleTimeoutMs ?? DEFAULT_STREAM_IDLE_TIMEOUT_MS,
  );

  return async (job) => {
    const { runId, sessionId, userId } = job.data;
    // P9 Task 9: per-run resolution context. A scheduler-fired job is
    // unattended even when the payload predates the explicit flag.
    const runKeyCtx = {
      unattended: job.data.unattended ?? job.data.schedule !== undefined,
      byokKeyId: job.data.byokKeyId ?? null,
    };

    const emit = async (
      type: SessionEventType,
      payload: Record<string, unknown>,
    ): Promise<SessionEvent> => {
      const event = await deps.events.append(sessionId, type, payload);
      await eventMirror.put(deps.db, event);
      return event;
    };

    /**
     * P8 Task 1 cooperative-cancel terminalization (v0 path): the EXISTING
     * run_failed event type with the cancelled payload, then the conditional
     * 'cancelled' status flip — event-first, same ordering every terminal
     * path here pins.
     */
    const terminalizeCancelled = async (): Promise<void> => {
      await emit("run_failed", { code: "cancelled", message: CANCELLED_MESSAGE });
      await runs.finish(deps.db, runId, "cancelled", CANCELLED_MESSAGE);
    };

    // ---- C1: single active run per session --------------------------------
    // This is the SEED of P3's per-session run buckets: the same guarantee
    // (at most one active run per session, oldest-first) will hold there,
    // with structured per-session scheduling replacing this poll loop.
    //
    // Worker concurrency (8) + per-run claimNext would otherwise let two
    // runs of the SAME session execute concurrently — interleaved
    // message_delta events and a wrong transcript order on the client. So
    // BEFORE claiming, wait until this run is the oldest still-active
    // (queued|running) run of its session, deterministic on (createdAt, id)
    // — runs.activeForSession orders by exactly that.
    //
    // The wait is bounded by runQueueWaitMs. A waiting job occupies a worker
    // concurrency slot (deliberate: the alternative — requeueing — would
    // multiply BullMQ jobs per run); the 10-minute cap terminalizes waiters
    // instead of deadlocking them. The run stays 'queued' while waiting, so
    // the stale-run sweeper (which only sweeps 'running') never touches it.
    //
    // Terminal-event ordering: the previous run emits its terminal event
    // BEFORE its status flip (see the file header), and this loop unblocks
    // on that flip — so run N+1's run_started is guaranteed to land strictly
    // after run N's run_completed/run_failed in the session stream.
    const turn = await waitForSessionTurn({
      db: deps.db,
      sessionId,
      runId,
      runQueueWaitMs,
      sleep,
      emit,
    });
    if (!turn) return;

    // Race-safe claim: exactly one concurrent delivery flips queued → running.
    // false = duplicate/stale delivery (or already-finished run) → silent no-op.
    const claimed = await runs.claimNext(deps.db, runId);
    if (!claimed) return;

    // ---- P7 Task 11: activity + workspace hydration ----------------------
    // Bump on claim (the workspace is about to be touched), then ensure the
    // session dir is warm BEFORE any tool can run. A hydrate failure is a
    // run-level failure with the SAME shape as key_not_minted: emit the
    // terminal event, flip the row, return (the job completes — attempts: 1).
    const bumpActivity = async (): Promise<void> => {
      try {
        await deps.activity?.bump(sessionId);
      } catch {
        // Cache-class redis: a lost bump only degrades LRU ordering.
      }
    };
    await bumpActivity();
    try {
      await deps.ensureWarm?.(sessionId, userId);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      await emit("run_failed", { runId, code: "hydrate_failed", message });
      await runs.finish(deps.db, runId, "failed", "hydrate_failed");
      await bumpActivity();
      return;
    }

    try {

    const resolvedKey = await deps.keys.resolveForRun(userId, runKeyCtx);
    if (resolvedKey === null) {
      await emit("run_failed", { code: "key_not_minted" });
      await runs.finish(deps.db, runId, "failed", "key_not_minted");
      return; // NOT a throw: the job completes, the client sees the failure event
    }
    const apiKey = resolvedKey.kind === "litellm" ? resolvedKey.key : resolvedKey.apiKey;
    const keyBaseUrl =
      resolvedKey.kind === "litellm"
        ? resolvedKey.baseUrl || deps.litellmBaseUrl
        : resolvedKey.endpoint;

    // Runtime legacy-guard (see RunDeps): the P1 spine e2e constructs the
    // pre-P2 RunDeps shape and must stay green unmodified — without
    // sandbox/tools the processor runs the v0 tool-less loop below, exactly as
    // before. main.ts always wires both.
    const useTools = deps.sandbox !== undefined && deps.tools !== undefined;

    /**
     * P8 Task 3 failure helper: run_failed {code:"attachment_unavailable"},
     * then the conditional 'failed' flip — event-first, same as every
     * terminal path here. A job that asked for attachments the processor
     * cannot materialize must NEVER silently skip them.
     */
    const failAttachments = async (message: string): Promise<void> => {
      await emit("run_failed", { code: "attachment_unavailable", message });
      await runs.finish(deps.db, runId, "failed", "attachment_unavailable");
    };

    // P8 Task 3: deduped attachment ids the message was sent with (the
    // gateway validated every id at enqueue time). Empty/absent = no work.
    const requestedAttachmentIds = [...new Set(job.data.attachmentIds ?? [])];

    // v0 tool-less path (legacy P1 spine composition — no sandbox/tools):
    // there is no workspace to materialize into, so attachments CANNOT be
    // honored. Loud failure, never a silent drop (never-silent invariant);
    // production always wires the sandbox, so this only guards miscomposed
    // harnesses. Emit AFTER the C1 wait/claim so the run row exists.
    if (!useTools && requestedAttachmentIds.length > 0) {
      await failAttachments("attachments require a sandbox workspace (tool mode disabled)");
      return;
    }

    // The gateway persisted the user prompt BEFORE enqueueing, so the stored
    // history already ends with it — load, never re-append. page() is
    // newest-first: take the newest ≤100 and walk them in reverse for the
    // oldest-first model context (controller ruling).
    const { rows } = await messages.page(deps.db, sessionId, { limit: HISTORY_LIMIT });
    const history: ChatMessage[] = [];
    for (let i = rows.length - 1; i >= 0; i -= 1) {
      const row = rows[i]!;
      // 'tool' rows cannot occur in v0 (no tools) — skip them defensively.
      if (row.role === "user" || row.role === "assistant" || row.role === "system") {
        history.push({ role: row.role, content: row.content });
      }
    }

    if (!useTools) {
      await runLegacyV0({
        runId,
        sessionId,
        history,
        apiKey,
        baseUrl: keyBaseUrl,
        cancelCheckIntervalMs,
        emit,
        terminalizeCancelled,
      });
      return;
    }

    // ---- P2 Task 12 / P3 Task 16: attach + engine over the P2 machinery ----
    let handle: SandboxHandle | undefined;
    /** Image attachments forwarded to the model (bounded; see the loop). */
    const promptImages: AgentImage[] = [];
    try {
      // `useTools` above guarantees both are present (legacy path returned).
      handle = await deps.sandbox!.attach(userId, {
        tier: job.data.tier === "free" ? "free" : "pro",
      });

      // ---- P8 Task 3: attachment materialization -------------------------
      // The job payload's attachmentIds (validated by the gateway against
      // the session's attachment rows at enqueue time) resolve back to rows
      // here, and each object is downloaded through the storage seam into
      // uploads/{sanitizedName} inside the sandbox workspace — BEFORE the
      // first provider call, so the model's tools see the files from
      // round 1. Misses (row gone, object never uploaded, seam unwired)
      // are loud run-level failures; an unexpected storage/filesystem
      // error falls through to the catch below and fails the job loudly
      // (infra, not a run state — the stale-run sweeper is the recovery).
      if (requestedAttachmentIds.length > 0) {
        const rows = await attachments.getForSession(
          deps.db,
          sessionId,
          requestedAttachmentIds,
        );
        if (rows.length !== requestedAttachmentIds.length) {
          await failAttachments("attachment id has no attachment row for this session");
          return;
        }
        if (deps.storage === undefined) {
          await failAttachments("attachment storage is not configured");
          return;
        }

        // ---- Vision capability gate (owner directive 2026-10-18) ----------
        // An image attachment is about to be sent to the model. A model that
        // cannot see would either error mid-run or silently drop the visual
        // context; either way the user pays for a broken run and finds out
        // late. Refuse BEFORE any bytes move, with copy they can act on, and
        // push it so a backgrounded app still learns.
        const imageRows = rows.filter((r) => imageMimeTypeFor(r.name) !== null);
        if (imageRows.length > 0) {
          // The effective model is the session's pin (what the engine's key
          // adapter will pass to the provider), falling back to the fleet
          // default exactly like `agentKeyFor`.
          const agentState = await createPostgresSessionStateStore(deps.db).get(sessionId);
          const requested = (agentState.modelPin ?? "").trim();
          const model =
            requested === "" || (AUTO_ALIASES as readonly string[]).includes(requested)
              ? deps.defaultModel
              : requested;
          const catalog =
            deps.modelCatalog === undefined ? null : await deps.modelCatalog().catch(() => null);
          const decision = modelVisionSupport(model, catalog);
          if (!decision.supports) {
            const message = visionRefusalMessage(model);
            await emit("run_failed", {
              code: "model_no_vision",
              message,
              model,
              basis: decision.basis,
              imageCount: imageRows.length,
            });
            await runs.finish(deps.db, runId, "failed", "model_no_vision");
            // Best-effort: a push failure must never change the run outcome.
            await deps.notifier
              ?.notifyAgentFailed({
                userId,
                sessionId,
                // ScheduleRunRef carries no title, and the run path has no
                // session row in hand. The notifier's generic title applies;
                // the actionable copy is in the body either way.
                sessionTitle: "",
                code: "model_no_vision",
                message,
              })
              .catch(() => {});
            return;
          }
        }

        const uploadsDir = join(handle.workspaceDir, "uploads");
        await mkdir(uploadsDir, { recursive: true });
        for (const row of rows) {
          const buffer = await deps.storage.getBuffer(row.r2Key);
          if (buffer === null) {
            await failAttachments(`attachment object not found: ${row.r2Key}`);
            return;
          }
          // An image the model must SEE (owner directive 2026-10-18): the
          // bytes ride the prompt as content parts, and the file also lands in
          // the workspace so tools can still open it by path. Bounded — an
          // unbounded base64 payload would blow the request size and the
          // provider's own limits.
          const mime = imageMimeTypeFor(row.name);
          if (mime !== null && promptImages.length < MAX_PROMPT_IMAGES) {
            const total = promptImages.reduce((n, i) => n + i.dataBase64.length, 0);
            if (total + buffer.length * 4 / 3 <= MAX_PROMPT_IMAGE_BYTES) {
              promptImages.push({ mimeType: mime, dataBase64: buffer.toString("base64") });
            }
          }
          await writeFile(join(uploadsDir, sanitizeAttachmentName(row.name)), buffer);
        }
      }
    } catch (err) {
      if (
        err instanceof SandboxAdmissionError ||
        err instanceof SandboxCapacityError ||
        err instanceof RootfsUnavailable
      ) {
        // NOT a throw: terminal run state, event-first ordering, job
        // completes (same contract as key_not_minted — the client sees the
        // failure event and the run row flips).
        await emit("run_failed", { code: "sandbox_unavailable", message: err.message });
        await runs.finish(deps.db, runId, "failed", "sandbox_unavailable");
        return;
      }
      throw err; // unknown/infra error — fail the job loudly
    }

    const attached = handle;

    /**
     * The P2-compat sink: every engine append is normalized to P2's exact
     * spelling before it reaches Redis (and the mirror).
     */
    const compatEvents = compatEventLog(deps.events);
    const compatEmit = async (
      type: SessionEventType,
      payload: Record<string, unknown>,
    ): Promise<void> => {
      const event = await compatEvents.append(sessionId, type, payload);
      await eventMirror.put(deps.db, event);
    };

    // The engine's openai leg is P2's legacy transport adapted onto the
    // canonical seam; the anthropic leg is never selected (the LiteLLM
    // resolver always yields kind "litellm").
    const legacy = adaptLegacyTransport(transport);

    // Cancel polling needs the live engine; the engine needs the transport.
    let engine: ReturnType<typeof createAgentEngine> | undefined;
    const polled = withCancelPolling(legacy, {
      intervalMs: cancelCheckIntervalMs,
      isCancelRequested: () => runs.isCancelRequested(deps.db, runId),
      onCancel: async () => {
        await engine?.cancel(sessionId);
      },
    });

    engine = createAgentEngine({
      db: deps.db,
      events: compatEvents,
      // The engine replaces this with its per-session sink; the field is part
      // of the pinned LoopDeps shape.
      sink: { async emit() {} },
      state: createPostgresSessionStateStore(deps.db),
      keys: {
        async resolve(uid, requestedModel) {
          const key = await deps.keys.resolveForRun(uid, runKeyCtx);
          return key === null ? null : agentKeyFor(key, requestedModel, deps.defaultModel);
        },
      },
      transports: { openai: polled, anthropic: legacy },
      litellmBaseUrl: deps.litellmBaseUrl,
      defaultModel: deps.defaultModel,
      registry: withUnknownToolFallback(
        createCoreToolRegistry(
          adaptAgentTools(deps.tools!.tools, {
            sandbox: attached,
            emitEvent: (type, payload) => compatEmit(type, payload),
          }),
        ),
      ),
      // P2 had no approval cards; the compat engine must never block.
      approvals: {
        async approve() {
          return "allow";
        },
      },
      hooks: NOOP_HOOKS,
      compactor: NOOP_COMPACTOR,
      skills: NOOP_SKILLS,
      // Non-null so the sandbox-backed P2 roster is advertised. Spill is
      // disabled: P2's caps stay byte-for-byte (the P2 suite pins them).
      sandbox: createSandboxPort(deps.sandbox!),
      windowTokens: DEFAULT_WINDOW_TOKENS,
      maxToolRounds: MAX_TOOL_ROUNDS,
      systemPromptOverride: SYSTEM_PROMPT_V1,
      spillToolResults: false,
      allowUnrosteredTools: true,
      ...(deps.sleep !== undefined ? { sleep: deps.sleep } : {}),
    });

    await engine.run({
      runId,
      sessionId,
      userId,
      prompt: job.data.prompt,
      ...(job.data.tier !== undefined ? { tier: job.data.tier } : {}),
      ...(job.data.attachmentIds !== undefined
        ? { attachmentIds: job.data.attachmentIds }
        : {}),
      ...(promptImages.length > 0 ? { promptImages } : {}),
    });
    } finally {
      // "after finish": every terminal path above has already flipped the
      // row; the bump records the session as recently used for the LRU.
      await bumpActivity();
    }
  };

  /**
   * The v0 tool-less streaming loop (P1), retained ONLY for the legacy
   * composition the e2e spine pins. The P2 tool path above runs the engine.
   */
  async function runLegacyV0(o: {
    runId: string;
    sessionId: string;
    history: ChatMessage[];
    apiKey: string;
    /** P9 Task 9: the resolved route origin (LiteLLM or a BYOK endpoint). */
    baseUrl: string;
    cancelCheckIntervalMs: number;
    emit(type: SessionEventType, payload: Record<string, unknown>): Promise<SessionEvent>;
    terminalizeCancelled(): Promise<void>;
  }): Promise<void> {
    const { runId, sessionId } = o;
    await o.emit("run_started", { runId });

    for (let attempt = 1; attempt <= MAX_MODEL_ATTEMPTS; attempt += 1) {
      await runs.bumpAttempt(deps.db, runId);

      const deltas: string[] = [];
      // onDelta is synchronous; event appends are not. Serialize them on a
      // promise chain so message_delta order matches arrival order, and drain
      // the chain before any completion/retry/failure event is emitted.
      let flushed: Promise<void> = Promise.resolve();
      // v0 wires the AbortSignal through but sets no timeout (later: per-attempt caps).
      const controller = new AbortController();

      // P8 Task 1: cooperative-cancel poll state, per attempt. `lastCancelCheck`
      // is the monotonic Date.now() of the last poll; the first delta batch
      // always polls (epoch 0), later batches only once the window elapses.
      let cancelRequested = false;
      let lastCancelCheck = 0;
      const pollCancel = async (): Promise<void> => {
        const now = Date.now();
        if (now - lastCancelCheck < o.cancelCheckIntervalMs) return; // throttled
        lastCancelCheck = now;
        if (await runs.isCancelRequested(deps.db, runId)) {
          cancelRequested = true;
          // Best-effort transport stop: a real SSE/HTTP transport aborts on
          // the signal and lands in the catch below; a transport that ignores
          // it is still stopped at the post-flush flag check.
          controller.abort();
        }
      };

      try {
        const result = await transport.stream(
          {
            baseUrl: o.baseUrl,
            apiKey: o.apiKey,
            model: deps.defaultModel,
            messages: o.history,
          },
          {
            onDelta(text) {
              deltas.push(text);
              flushed = flushed
                .then(() => o.emit("message_delta", { runId, text }).then(() => undefined))
                // Cancel check between delta batches — ON the flush chain so
                // it never races the delta ordering, throttled to at most
                // one db poll per cancelCheckIntervalMs window.
                .then(() => pollCancel());
              // Mark the rejection handled NOW (transport may still be
              // streaming when an early append fails — an unawaited rejection
              // would surface as an unhandledRejection); the real error
              // resurfaces at the `await flushed` below.
              flushed.catch(() => {});
            },
          },
          controller.signal,
        );
        await flushed;

        // The flag flipped mid-stream and the (possibly abort-ignoring)
        // transport returned normally: terminalize before any completion
        // event. Not a throw — the job completes (same contract as the
        // run-level failures above).
        if (cancelRequested) {
          await o.terminalizeCancelled();
          return;
        }

        const content = deltas.join("");

        // v0 completion path (unchanged): persist the assistant text,
        // message_completed, run_completed.
        const assistant = await messages.append(deps.db, {
          sessionId,
          role: "assistant",
          content,
        });
        await o.emit("message_completed", { messageId: assistant.id, content });
        // Terminal event BEFORE the status flip (see file header): the next
        // same-session run (C1 wait loop) unblocks on the flip, so this order
        // is what pins run N+1's run_started strictly after run_completed.
        await o.emit("run_completed", { runId });
        await runs.finish(deps.db, runId, "completed");
        return;
      } catch (err) {
        // Keep ordering: pending deltas of the failed attempt settle (or are
        // abandoned) before the retry/failure event goes out.
        await flushed.catch(() => {});

        // P8 Task 1: an abort raised BY the cancel poll (the real transport
        // throws on the aborted signal) is a terminal cancel, never a
        // transient/terminal model error or an infra failure.
        if (cancelRequested) {
          await o.terminalizeCancelled();
          return;
        }

        if (err instanceof TransientModelError) {
          if (attempt >= MAX_MODEL_ATTEMPTS) {
            await o.emit("run_failed", { code: "model_transient_exhausted" });
            // The run row carries the canonical failure CODE, not the
            // provider's transient message: the scheduler's settle pass
            // classifies retryability on exactly this value
            // (RETRYABLE_RUN_CODES), so a transient exhaustion must arm the
            // schedule retry ladder rather than terminalize the occurrence.
            await runs.finish(deps.db, runId, "failed", "model_transient_exhausted");
            return;
          }
          const nextBackoffMs = RETRY_BACKOFF_MS[attempt - 1]!;
          await o.emit("run_started_retry", { attempt: attempt + 1, nextBackoffMs });
          await sleep(nextBackoffMs);
          continue;
        }

        if (err instanceof TerminalModelError) {
          await o.emit("run_failed", { code: "model_terminal", message: err.message });
          await runs.finish(deps.db, runId, "failed", err.message);
          return;
        }

        // Unknown/infra error (db or redis down, consumer bug): fail the job
        // loudly. With attempts:1 the job stays FAILED — BullMQ never
        // redelivers it (failed ≠ stalled; stalled handling with attempts:1
        // also fails rather than redelivers), and claimNext claims 'queued'
        // rows only, so even a redelivery would no-op. Recovery is the
        // stale-run sweeper's job (staleRuns.ts): it terminalizes runs
        // stranded in 'running' with run_failed {code:"run_lost"}.
        throw err;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Full production processor
// ---------------------------------------------------------------------------

export function createFullAgentRunProcessor(deps: FullRunDeps): FullAgentRunProcessor {
  const sleep = deps.sleep ?? defaultSleep;
  const windowTokens = deps.windowTokens ?? DEFAULT_WINDOW_TOKENS;

  const state = createPostgresSessionStateStore(deps.db);

  const sinkFor = (sessionId: string) => ({
    async emit(type: SessionEventType, payload: Record<string, unknown>): Promise<void> {
      const event = await deps.events.append(sessionId, type, payload);
      await eventMirror.put(deps.db, event);
    },
  });

  const bridge = createRedisApprovalBridge({
    redisQ: deps.redisQ,
    events: deps.events,
    db: deps.db,
  });

  // P4 Task 10 + P3 fix round: the P3-T12 approval seam. The hook's presence
  // (wired by main.ts) installs the per-request policy AND the run-scoped
  // side-effect callbacks; the gate still owns the structural attended
  // question/plan rule. `timeoutPolicy` now receives `runId`, and
  // `onRequested`/`onTimeout` forward to the hook's push/ledger methods for
  // unattended runs. Attended runs remain strict no-ops (checked here, not in
  // the gate, so the gate stays a generic seam).
  const unattendedHook = deps.unattendedApprovalHook;
  const timeoutPolicy = unattendedTimeoutPolicy(
    unattendedHook,
    deps.approvalTimeoutMs ?? APPROVAL_TIMEOUT_MS,
    // The env override applies to unattended requests too when explicitly set;
    // absent → the spec's 120 s constant.
    deps.approvalTimeoutMs,
  );

  const approvals = createApprovalGate({
    db: deps.db,
    bridge,
    sinkFactory: sinkFor,
    // The ONLY place the timeout override enters: env is parsed by main.ts
    // into FullRunDeps; the gate never reads env itself.
    ...(deps.approvalTimeoutMs !== undefined
      ? { timeoutMs: deps.approvalTimeoutMs }
      : {}),
    ...(timeoutPolicy !== undefined ? { timeoutPolicy } : {}),
    ...(unattendedHook !== undefined
      ? {
          onRequested: async (ctx, req) => {
            if (!ctx.unattended) return;
            await unattendedHook.onApprovalRequested(ctx.runId, {
              toolName: req.tool,
              summary: req.summary,
              question: req.kind === "question",
            });
          },
          onTimeout: async (ctx, req) => {
            if (!ctx.unattended) return;
            await unattendedHook.onApprovalAutoDenied(ctx.runId, {
              toolName: req.tool,
              summary: req.summary,
            });
          },
        }
      : {}),
  });

  // Guarded egress for EVERY provider/tool call (spec D3/§11). No raw fetch.
  const guard = createSsrfGuard();

  /**
   * Per-hop host-GRANT re-check (T12 carry, T10 review): the guarded egress
   * re-runs the SSRF check on every redirect hop but not the caller's grant,
   * so a granted site could bounce to a public host the user never approved.
   * The egress is shared, so the active tool context rides AsyncLocalStorage
   * (set by `withGrantHop` around each web-tool execution).
   */
  const toolContext = new AsyncLocalStorage<{ userId: string; sessionId: string }>();
  const grantHop = async (url: URL): Promise<void> => {
    const ctx = toolContext.getStore();
    if (ctx === undefined) return;
    const rows = await grantsRepo.listForSession(deps.db, ctx.userId, ctx.sessionId);
    const grants = rows.map((r) => ({
      kind: r.kind === "path" ? ("path" as const) : ("host" as const),
      pattern: r.pattern,
      decision: r.decision === "deny" ? ("deny" as const) : r.decision === "allow" ? ("allow" as const) : ("always" as const),
    }));
    const applicable = findApplicableGrant(grants, "host", normalizeGrantHost(url.hostname));
    if (applicable === null || applicable.decision === "deny") {
      throw new Error(`redirect host "${url.hostname}" is not granted for this session`);
    }
  };

  const providerEgress: EgressFetch =
    deps.egress ??
    createProviderEgress({
      guard,
      providerBaseUrls: [deps.litellmBaseUrl, deps.anthropicBaseUrl],
    });
  const toolEgress: EgressFetch =
    deps.egress ?? createGuardedEgressFetch(guard, fetch, 5, grantHop);

  const withGrantHop = (tool: CoreTool): CoreTool => ({
    ...tool,
    execute: (args, ctx) =>
      toolContext.run({ userId: ctx.userId, sessionId: ctx.sessionId }, () =>
        tool.execute(args, ctx),
      ),
  });

  // P9 Task 9: key resolution is PER RUN (the resolver needs the run's
  // unattended/byok context), so the agent-core adapter is built inside the
  // processor below — there is deliberately no long-lived resolver here.

  // Deployment feature flags (M-3): the roster never advertises a family the
  // composition cannot honor. Memory tools are always wired today (the
  // sandbox-backed store exists); repo tools exist only with a GitHub port.
  const memoryEnabled = true;
  const githubConnected = deps.github !== null;

  const workerRegistry = createToolRegistry();

  /**
   * Per-run registry: the sandbox-backed tools bind the run's TIERED port
   * (review I2) and the skill catalog/tool bind the run's userId (the catalog
   * API carries only a sessionId). Building it per run is cheap and keeps
   * per-user state out of the long-lived processor.
   */
  const buildRegistry = (o: {
    sandbox: SandboxPort;
    userId: string;
    tier: "free" | "pro";
    skills: SkillCatalog;
    /** Run-scoped tools that need the live engine/supervisor (Task 20). */
    extraTools?: readonly CoreTool[];
  }): CoreToolRegistry => {
    const p2Tools = adaptAgentTools(workerRegistry.tools, {
      sandboxFor: async (ctx) =>
        deps.sandboxHandleFor !== undefined
          ? deps.sandboxHandleFor(ctx.userId, o.tier)
          : portBackedHandle(o.sandbox, ctx),
      emitEvent: async () => {},
      emitEventFor: (ctx) => (type, payload) => sinkFor(ctx.sessionId).emit(type, payload),
    });

    // P4 Task 13: additive roster extension (schedule tools in production).
    // Canonical tools spread beside the built-ins; the registry stays the
    // only roster builder.
    const coreTools = [
      ...p2Tools,
      ...(deps.extraTools ?? []),
      ...(deps.browserTools ?? []),
      ...createSandboxTools({ sandbox: o.sandbox }),
      withGrantHop(
        createFetchUrlTool({
          egress: toolEgress,
          guard,
          approvals,
          sandbox: o.sandbox,
        }),
      ),
      withGrantHop(createWebSearchTool({ egress: toolEgress })),
      ...createGitTools({ sandbox: o.sandbox, approvals, github: deps.github }),
      ...createRepoTools({ github: deps.github }),
      ...(memoryEnabled ? createMemoryTools({ sandbox: o.sandbox }) : []),
      ...createGoalTodoTools({ state, sinkFactory: sinkFor }),
      createSessionSearchTool({ db: deps.db }),
      createExitPlanModeTool({ state, approvals }),
      // Task 17 (T16 review I4): the model-invocable skill tool.
      createSkillTool({
        catalog: o.skills,
        onActivate: createSkillActivation(state),
      }),
      // Task 20 (fix round I-1): the subagent family. The supervisor's engine
      // and registry are late-bound (both are constructed after this list —
      // the engine consumes the registry, and the supervisor reads it to
      // project a child's roster), so the five tools are reachable here
      // without a second registry.
      ...(o.extraTools ?? []),
    ];
    return createCoreToolRegistry(coreTools);
  };

  // P10 Task 2: both provider transports carry the per-chunk SSE idle
  // deadline; a stalled stream aborts and surfaces as TransientModelError,
  // so the engine's 3/9/27/60 s ladder retries it.
  const streamIdleTimeoutMs = deps.streamIdleTimeoutMs ?? DEFAULT_STREAM_IDLE_TIMEOUT_MS;
  const openai = withAgentStreamIdleTimeout(
    createOpenAiAgentTransport(providerEgress),
    streamIdleTimeoutMs,
  );
  const anthropic = withAgentStreamIdleTimeout(
    createAnthropicTransport(providerEgress),
    streamIdleTimeoutMs,
  );

  const processor = (async (job: {
    data: AgentRunJob & {
      unattended?: boolean;
      autonomy?: "safe" | "auto";
      mode?: "safe" | "auto" | "drive" | "studio";
    };
  }): Promise<void> => {
    const { runId, sessionId, userId } = job.data;
    // P9 Task 9: the per-run resolution context and the agent-core adapter.
    // Both the engine and the auxiliary model calls (hooks/compaction) ride
    // the SAME resolved key for this run.
    const runKeyCtx = {
      unattended: job.data.unattended ?? job.data.schedule !== undefined,
      byokKeyId: job.data.byokKeyId ?? null,
    };
    const keys = {
      async resolve(uid: string, requestedModel: string) {
        const key = await deps.keys.resolveForRun(uid, runKeyCtx);
        return key === null ? null : agentKeyFor(key, requestedModel, deps.defaultModel);
      },
    };

    // ---- C1: the identical single-active-run-per-session contract --------
    const turn = await waitForSessionTurn({
      db: deps.db,
      sessionId,
      runId,
      runQueueWaitMs: deps.runQueueWaitMs ?? DEFAULT_RUN_QUEUE_WAIT_MS,
      sleep,
      emit: (type, payload) => sinkFor(sessionId).emit(type, payload),
    });
    if (!turn) return;

    const claimed = await runs.claimNext(deps.db, runId);
    if (!claimed) return;

    // ---- P7 Task 11: activity + workspace hydration ----------------------
    // Identical contract to the compat path: bump on claim, hydrate before
    // any tool touches the workspace, and turn a hydrate rejection into a
    // run-level hydrate_failed (never a job throw).
    const bumpActivity = async (): Promise<void> => {
      try {
        await deps.activity?.bump(sessionId);
      } catch {
        // Cache-class redis: a lost bump only degrades LRU ordering.
      }
    };
    await bumpActivity();
    try {
      await deps.ensureWarm?.(sessionId, userId);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      await sinkFor(sessionId).emit("run_failed", {
        runId,
        code: "hydrate_failed",
        message,
      });
      await runs.finish(deps.db, runId, "failed", "hydrate_failed");
      await bumpActivity();
      return;
    }

    try {

    // Review I2: the user's tier drives the sandbox quota project on the
    // full path exactly as it did on the compat path. Raw DB tier text:
    // "free" → free, anything else → pro (P2 Task 12 convention).
    const tier: "free" | "pro" = job.data.tier === "free" ? "free" : "pro";
    const runSandbox = deps.sandboxForTier?.(tier) ?? deps.sandbox;

    // ---- attachments (never-silent) --------------------------------------
    // The compat path materializes into the attached workspace; the full
    // path needs a storage seam AND a P2 handle (host workspace). Without
    // both the run fails loudly instead of silently dropping the files.
    const requestedAttachmentIds = [...new Set(job.data.attachmentIds ?? [])];
    if (requestedAttachmentIds.length > 0) {
      const sink = sinkFor(sessionId);
      const fail = async (message: string): Promise<void> => {
        await sink.emit("run_failed", { code: "attachment_unavailable", message });
        await runs.finish(deps.db, runId, "failed", "attachment_unavailable");
      };
      if (deps.storage === undefined) {
        await fail("attachment storage is not configured");
        return;
      }
      if (deps.sandboxHandleFor === undefined) {
        await fail("attachment materialization requires a sandbox handle");
        return;
      }
      const rows = await attachments.getForSession(
        deps.db,
        sessionId,
        requestedAttachmentIds,
      );
      if (rows.length !== requestedAttachmentIds.length) {
        await fail("attachment id has no attachment row for this session");
        return;
      }
      const handle = await deps.sandboxHandleFor(userId, tier);
      const uploadsDir = join(handle.workspaceDir, "uploads");
      await mkdir(uploadsDir, { recursive: true });
      for (const row of rows) {
        const buffer = await deps.storage.getBuffer(row.r2Key);
        if (buffer === null) {
          await fail(`attachment object not found: ${row.r2Key}`);
          return;
        }
        await writeFile(join(uploadsDir, sanitizeAttachmentName(row.name)), buffer);
      }
    }

    // ---- mode feeding (ruling R4): job.mode ?? state.mode ?? "auto" ------
    const sessionState = await state.get(sessionId);
    const mode = job.data.mode ?? sessionState.mode ?? "auto";

    // ---- Task 17/18/19 (T16 review I4): the real per-run engines ---------
    // Skills catalog: the SkillCatalog API carries only a sessionId, so the
    // owner userId is bound per run (required by the factory).
    const skills = createSkillCatalog({ sandbox: runSandbox, userId });

    // Hooks: workspace `.dsh/hooks.json`, executing in the run owner's jail.
    // A missing userId resolver is a hard error by design (never a
    // sessionId-keyed fallback); the run's userId is the correct resolver.
    //
    // Prompt-type hooks (fix round I-6): a quiet one-shot model call on the
    // run's own route — no delta handlers, so nothing reaches the transcript
    // or the event stream. The hook engine owns the timeout race and parses
    // the reply through `parsePromptHookDecision`; a route/model failure
    // returns null (fail-open, the pinned hook contract).
    const promptEvaluator = async (prompt: string): Promise<string | null> => {
      try {
        const preset = presetById(sessionState.presetId);
        const route = await resolveRoute(
          {
            userId,
            requestedModel: sessionState.modelPin,
            preset:
              preset === null
                ? null
                : { model: preset.model, temperature: preset.temperature },
          },
          {
            keys,
            litellmBaseUrl: deps.litellmBaseUrl,
            defaultModel: deps.defaultModel,
          },
        );
        if (route === null) return null;
        const transport = route.transportKind === "anthropic" ? anthropic : openai;
        // The anthropic transport appends `/v1/messages`; a `/v1`-suffixed
        // route base would double it (the loop's T5-C1 carry).
        const baseUrl =
          route.transportKind === "anthropic"
            ? route.baseUrl.replace(/\/+$/, "").replace(/\/v1$/, "")
            : route.baseUrl;
        const response = await transport.stream(
          {
            model: route.model,
            baseUrl,
            apiKey: route.apiKey,
            system: [
              {
                role: "system",
                content:
                  "You are a plugin-hook rule evaluator. Follow the " +
                  "instruction in the user message exactly and reply with " +
                  "only the requested decision.",
              },
            ],
            messages: [{ role: "user", content: prompt }],
            tools: [],
            cacheMode: "none",
            ...(route.effort !== null ? { effort: route.effort } : {}),
            ...(route.temperature !== undefined
              ? { temperature: route.temperature }
              : {}),
          },
          { onTextDelta() {} },
          new AbortController().signal,
        );
        return response.content;
      } catch {
        return null;
      }
    };

    const hooks = createHookEngine({
      sandbox: runSandbox,
      sources: [createFileHookSource({ sandbox: runSandbox, userId })],
      promptEvaluator,
      secrets: deps.hookSecrets ?? (() => []),
      userIdForSession: () => userId,
      onNotification: (message, ctx) => {
        void sinkFor(ctx.sessionId)
          .emit("system_note", { code: "hook_notification", message, pluginId: ctx.pluginId })
          .catch(() => {});
      },
    });

    // Subagents (Task 20 / fix round I-1). The supervisor and its five tools
    // are part of every full-path registry. The engine is per-run and the
    // registry is built after this point, so both are reached through
    // late-bound proxies: the child loop only starts from a tool call, which
    // can only happen inside `engine.run` — by then both refs are set.
    let engineRef: ReturnType<typeof createAgentEngine> | undefined;
    let registryRef: CoreToolRegistry | undefined;
    const lateRegistry: CoreToolRegistry = {
      get: (name) => registryRef?.get(name),
      all: () => registryRef?.all() ?? [],
    };
    const lateEngine: AgentEngine = {
      async run(childJob) {
        if (engineRef === undefined) {
          throw new Error("subagent dispatch before the run engine is ready");
        }
        await engineRef.run(childJob);
      },
      async cancel(sessionIdToCancel, reason) {
        return (await engineRef?.cancel(sessionIdToCancel, reason)) ?? false;
      },
      activeRun(sessionIdToInspect) {
        return engineRef?.activeRun(sessionIdToInspect) ?? null;
      },
    };
    const subagentSupervisor = createSubagentSupervisor({
      engine: lateEngine,
      db: deps.db,
      state,
      hooks,
      sinkFactory: sinkFor,
      registry: lateRegistry,
      memoryEnabled,
      githubConnected,
    });
    const subagentTools = createSubagentTools({
      supervisor: subagentSupervisor,
      state,
      sink: sinkFor(sessionId),
    });

    // Compactor: per-run (state/sandbox/sink are per-session). The quiet
    // summarizer call rides the same provider route as the run.
    const compactor = createCompactor({
      state,
      sandbox: runSandbox,
      sink: sinkFor(sessionId),
      userId,
      runId,
      summarize: async (i) => {
        const key = await keys.resolve(userId, "");
        if (key === null) return null;
        const baseUrl =
          key.kind === "byok-anthropic"
            ? key.baseUrl.replace(/\/+$/, "").replace(/\/v1$/, "")
            : key.baseUrl;
        const transport =
          key.kind === "byok-anthropic" ? anthropic : openai;
        const res = await transport.stream(
          {
            model: key.model,
            baseUrl,
            apiKey: key.apiKey,
            system: [{ role: "system", content: i.systemPrompt }],
            messages: [{ role: "user", content: i.userPrompt }],
            tools: [],
            cacheMode: "none",
          },
          { onTextDelta() {} },
          new AbortController().signal,
        );
        return res.content;
      },
    });

    const registry = buildRegistry({
      sandbox: runSandbox,
      userId,
      tier,
      skills,
      extraTools: subagentTools,
    });
    registryRef = registry;

    // ---- slash-command pre-pass (T16 review I4) --------------------------
    // finish → message_completed with the feedback, no model call;
    // rewrite → the rewritten prompt becomes the run's current turn.
    let prompt = job.data.prompt;
    const commandRunner = createCommandRunner({
      state,
      skills,
      presets: presetById,
      compact: async (sid) => {
        const page = await messages.page(deps.db, sid, { limit: HISTORY_LIMIT });
        const history = [...page.rows]
          .reverse()
          .filter((r) => r.role === "user" || r.role === "assistant" || r.role === "system")
          .map((r) => ({
            role: r.role as "user" | "assistant" | "system",
            content: r.content,
            id: r.id,
          }));
        // Fix round I-3: the durable fold boundary keeps a manual /compact
        // from re-absorbing (and duplicating) rows an earlier compaction
        // already folded.
        const compactState = await state.get(sid);
        const out = await compactor.compactNow({
          sessionId: sid,
          messages: history,
          windowTokens,
          foldBoundary: foldBoundaryFor(compactState.compaction, history),
        });
        return out.status;
      },
      setMode: async (sid, next: SessionMode) => {
        await state.patch(sid, { mode: next });
        return `Mode set to ${next}.`;
      },
    });
    const prePass = await commandPrePass(commandRunner, sessionId, prompt);
    if (prePass.kind === "finish") {
      // The feedback IS the turn's output: persist it, complete the run, and
      // never call the model (Dart's composer-command contract).
      const sink = sinkFor(sessionId);
      await sink.emit("run_started", { runId });
      const assistant = await messages.append(deps.db, {
        sessionId,
        role: "assistant",
        content: prePass.feedback,
      });
      await sink.emit("message_completed", {
        messageId: assistant.id,
        content: prePass.feedback,
      });
      await sink.emit("run_completed", { runId });
      await runs.finish(deps.db, runId, "completed");
      return;
    }
    if (prePass.kind === "rewrite") prompt = prePass.prompt;

    // Cancel polling needs the live engine; build it per run (the engine is
    // cheap; the per-run binding is what keeps `cancel(sessionId)` pointed at
    // THIS run's token).
    let engine: ReturnType<typeof createAgentEngine> | undefined;
    const wrap = (base: AgentTransport): AgentTransport =>
      withCancelPolling(base, {
        intervalMs: DEFAULT_CANCEL_CHECK_INTERVAL_MS,
        isCancelRequested: () => runs.isCancelRequested(deps.db, runId),
        onCancel: async () => {
          await engine?.cancel(sessionId);
        },
      });

    engine = createAgentEngine({
      db: deps.db,
      events: deps.events,
      // The engine replaces this with its per-session sink; the field is part
      // of the pinned LoopDeps shape.
      sink: { async emit() {} },
      state,
      keys,
      transports: { openai: wrap(openai), anthropic: wrap(anthropic) },
      litellmBaseUrl: deps.litellmBaseUrl,
      defaultModel: deps.defaultModel,
      registry,
      approvals,
      hooks,
      compactor,
      skills,
      sandbox: runSandbox,
      windowTokens,
      memoryEnabled,
      githubConnected,
      ...(deps.sleep !== undefined ? { sleep: deps.sleep } : {}),
    });
    // Late-bound seams for the subagent tools (see their construction above).
    engineRef = engine;

    await engine.run({
      runId,
      sessionId,
      userId,
      prompt,
      ...(job.data.tier !== undefined ? { tier: job.data.tier } : {}),
      ...(job.data.attachmentIds !== undefined
        ? { attachmentIds: job.data.attachmentIds }
        : {}),
      // P4 Task 10: a scheduler-fired job carries `schedule`; that run has no
      // attending user, so it is unattended even though the scheduler's
      // enqueue payload predates the explicit flag.
      unattended: job.data.unattended ?? job.data.schedule !== undefined,
      ...(job.data.autonomy !== undefined ? { autonomy: job.data.autonomy } : {}),
      mode,
    });
    } finally {
      // P5 Task 11 I4: a run's per-run MCP stdio/legacy-SSE connection must
      // not outlive the run. This finally covers every terminal path inside
      // the try (completion, run-level failure, prepass finish, cancel).
      // Best-effort: release must never turn a finished run into a job throw.
      await deps.mcpReleaseRun?.(userId, { sessionId, runId }).catch(() => {});
      // P6: the browser context is per-run. Best-effort like the MCP release —
      // a finished run must never throw because teardown failed; the pool's
      // 15 s idle lease reaps anything this misses.
      await deps.browserReleaseSession?.(sessionId).catch(() => {});
      await bumpActivity();
    }
  }) as FullAgentRunProcessor;

  processor.close = async (): Promise<void> => {
    await bridge.close();
  };
  return processor;
}
