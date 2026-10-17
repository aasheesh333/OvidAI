// Never-stop turn loop (P3 Task 15) — TDD step 1.
//
// The P1 runProcessor.test.ts parity battery re-pinned at loop level, plus the
// plan's loop-mechanics matrix (plan:655) and the Dart cases the map classifies
// as portable (agent_double_response_test.dart — attempt discard;
// agent_retry_diagnostics_test.dart — failure mapping; agent_run_code_contract
// — dispatch leg; hard_stop/session_stop_isolation — cancel semantics, covered
// at engine level in engine.test.ts).
//
// DB-backed: the loop loads history, persists the assistant row and flips the
// run row through the real repos (the same convention as steering.test.ts).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createDb,
  messages,
  migrate,
  runs,
  sessions,
  users,
  type Db,
  type RunRow,
} from "@ovid/db";
import type { SessionEventType } from "@ovid/shared";

import type {
  ApprovalGate,
  ApprovalRequest,
  Compactor,
  EventSink,
  HookEngine,
  HookEvent,
  HookGateResult,
  HookStopResult,
  SandboxPort,
  SessionAgentState,
  SessionStateStore,
  SkillCatalog,
} from "./ports.js";
import { createMemoryStateStore } from "./ports.js";
import {
  BUDGET_CONTINUATION_NUDGE,
  runAgentLoop,
  TOOL_EVENT_CONTENT_CAP,
  type LoopDeps,
  type NormalizedRunJob,
  type RunTime,
} from "./loop.js";
import { TOOL_TIMEOUT_MESSAGE } from "./tools/spill.js";
import { createSandboxTools } from "./tools/sandboxTools.js";
import { convertMessagesToAnthropic } from "./transport/anthropic.js";
import { createToolRegistry, type AgentRequest, type AgentResponse, type AgentTransport, type Tool, type ToolContext, type ToolResult, type ToolSpec } from "./types.js";
import { TerminalModelError, TransientModelError } from "./transport/errors.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

// ── fixtures ────────────────────────────────────────────────────────────────

type Scripted =
  | { text: string; deltas?: string[]; toolCalls?: AgentResponse["toolCalls"]; delayMs?: number }
  | { error: Error; delayMs?: number }
  | { abort: true };

/** A stub transport: records every request, plays a script in order. */
function stubTransport(script: Scripted[]): {
  transport: AgentTransport;
  requests: AgentRequest[];
  calls: number;
} {
  const requests: AgentRequest[] = [];
  const state = { calls: 0 };
  const transport: AgentTransport = {
    apiFormat: "openai",
    async stream(req, h, signal) {
      requests.push(req);
      const step = script[Math.min(state.calls, script.length - 1)]!;
      state.calls += 1;
      if ("abort" in step) {
        await new Promise<void>((_resolve, reject) => {
          if (signal.aborted) {
            reject(new Error("aborted"));
            return;
          }
          signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
        });
      }
      if (step.delayMs !== undefined && step.delayMs > 0) {
        await new Promise<void>((resolve, reject) => {
          const timer = setTimeout(resolve, step.delayMs);
          signal.addEventListener(
            "abort",
            () => {
              clearTimeout(timer);
              reject(new Error("aborted"));
            },
            { once: true },
          );
        });
      }
      if ("error" in step) throw step.error;
      const deltas = step.deltas ?? (step.text === "" ? [] : [step.text]);
      for (const d of deltas) h.onTextDelta(d);
      return {
        content: step.text,
        thinking: "",
        toolCalls: step.toolCalls ?? [],
        finishReason: step.toolCalls !== undefined && step.toolCalls.length > 0 ? "tool_calls" : "stop",
        usage: null,
      };
    },
  };
  return {
    transport,
    requests,
    get calls() {
      return state.calls;
    },
  } as { transport: AgentTransport; requests: AgentRequest[]; calls: number };
}

interface Recorded {
  type: SessionEventType;
  payload: Record<string, unknown>;
}

function recordingSink(): { sink: EventSink; events: Recorded[] } {
  const events: Recorded[] = [];
  return {
    events,
    sink: {
      async emit(type, payload) {
        events.push({ type, payload });
      },
    },
  };
}

function tool(name: string, timeoutMs = 60_000): Tool & { calls: Array<{ args: Record<string, unknown>; ctx: ToolContext }> } {
  const calls: Array<{ args: Record<string, unknown>; ctx: ToolContext }> = [];
  return {
    calls,
    spec: { name, description: name, parameters: { type: "object" } },
    timeoutMs,
    async execute(args, ctx): Promise<ToolResult> {
      calls.push({ args, ctx });
      return { content: `${name} ok` };
    },
  };
}

function slowTool(name: string, timeoutMs: number): Tool & { started: boolean } {
  return {
    started: false,
    spec: { name, description: name, parameters: { type: "object" } },
    timeoutMs,
    async execute(): Promise<ToolResult> {
      (this as { started: boolean }).started = true;
      return new Promise<ToolResult>(() => {
        /* never resolves — the dispatch timeout answers */
      });
    },
  };
}

function recordingHooks(o: {
  listeners?: HookEvent[];
  gate?: HookGateResult;
  stop?: HookStopResult;
  preRequest?: { output: string; systemMessages: string[]; promptBlockReason: string | null };
  promptBlockReason?: string | null;
} = {}): HookEngine & { fired: HookEvent[] } {
  const fired: HookEvent[] = [];
  return {
    fired,
    async hasListeners(event) {
      return (o.listeners ?? []).includes(event);
    },
    async fire(event) {
      fired.push(event);
    },
    async fireDetailed(event) {
      fired.push(event);
      if (event === "user_prompt_submit") {
        return { output: "", systemMessages: [], promptBlockReason: o.promptBlockReason ?? null };
      }
      return o.preRequest ?? { output: "", systemMessages: [], promptBlockReason: null };
    },
    async fireGate() {
      fired.push("pre_tool");
      return o.gate ?? { decision: "allow", updatedInput: undefined, reason: null, bypassPermission: false, decidedByPlugin: null, deniedByPlugin: null };
    },
    async fireStop() {
      fired.push("stop");
      return o.stop ?? { veto: false };
    },
    sessionContextFor() {
      return "";
    },
    promptContextFor() {
      return null;
    },
  };
}

function recordingApprovals(decision: "allow" | "deny" | "always" = "allow"): ApprovalGate & {
  requests: ApprovalRequest[];
} {
  const requests: ApprovalRequest[] = [];
  return {
    requests,
    async approve(_ctx, req) {
      requests.push(req);
      return decision;
    },
  };
}

function recordingCompactor(result?: (i: { messages: unknown[] }) => {
  compacted: boolean;
  messages: unknown[];
}): Compactor & { calls: Array<{ messages: unknown[]; windowTokens: number; foldBoundary?: number }> } {
  const calls: Array<{ messages: unknown[]; windowTokens: number; foldBoundary?: number }> = [];
  return {
    calls,
    async maybeCompact(i) {
      calls.push({
        messages: i.messages,
        windowTokens: i.windowTokens,
        ...(i.foldBoundary !== undefined ? { foldBoundary: i.foldBoundary } : {}),
      });
      if (result) {
        const out = result(i);
        return { compacted: out.compacted, messages: out.messages as never[] };
      }
      return { compacted: false, messages: i.messages };
    },
    async pruneOversizedToolResults(i) {
      return { pruned: 0, messages: i.messages };
    },
  };
}

const skills: SkillCatalog = {
  async list() {
    return [];
  },
  async load() {
    return null;
  },
};

function stubSandbox(): SandboxPort & { kills: string[]; writes: Array<{ path: string; content: string }> } {
  const kills: string[] = [];
  const writes: Array<{ path: string; content: string }> = [];
  return {
    kills,
    writes,
    async exec() {
      return { exitCode: 0, stdout: "", stderr: "" };
    },
    async killCall(_userId, callKey) {
      kills.push(callKey);
    },
    async readFile() {
      return "";
    },
    async writeFile(_userId, path, content) {
      writes.push({ path, content });
    },
    async exists() {
      return false;
    },
    async listDir() {
      return [];
    },
    async jobStart() {
      return { jobId: "j1" };
    },
    async jobOutput() {
      return { output: "", running: false, exitCode: 0 };
    },
    async jobList() {
      return [];
    },
    async jobKill() {},
  };
}

function keyResolver(nullKey = false) {
  return {
    async resolve() {
      return nullKey
        ? null
        : { kind: "litellm" as const, apiKey: "sk-test", baseUrl: "https://litellm.test", model: "ovid-test-model" };
    },
  };
}

// ── DB harness ──────────────────────────────────────────────────────────────

describe.skipIf(!TEST_DATABASE_URL)("runAgentLoop (real postgres)", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function seedSession(): Promise<{ userId: string; sessionId: string }> {
    const uid = `lp-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    await users.ensure(db, uid, null);
    const row = await sessions.create(db, uid, null);
    return { userId: uid, sessionId: row.id };
  }

  async function seedPrompt(sessionId: string, content: string): Promise<string> {
    const row = await messages.append(db, { sessionId, role: "user", content });
    return row.id;
  }

  async function seedRun(sessionId: string, promptMessageId: string): Promise<string> {
    const row = await runs.create(db, { sessionId, promptMessageId });
    await runs.claimNext(db, row.id);
    return row.id;
  }

  interface Ctx {
    deps: LoopDeps;
    job: NormalizedRunJob;
    rt: RunTime;
    events: Recorded[];
    requests: AgentRequest[];
    state: SessionStateStore;
    controller: AbortController;
  }

  async function makeCtx(o: {
    script: Scripted[];
    tools?: Tool[];
    state?: SessionStateStore;
    hooks?: HookEngine;
    approvals?: ApprovalGate;
    compactor?: Compactor;
    sandbox?: SandboxPort | null;
    nullKey?: boolean;
    maxToolRounds?: number;
    systemPromptOverride?: string;
    sleep?: (ms: number) => Promise<void>;
    statePatch?: Partial<SessionAgentState>;
    mode?: NormalizedRunJob["mode"];
    prompt?: string;
    /** Pre-seeded session (the caller appends the durable history itself). */
    preSeeded?: { userId: string; sessionId: string };
    /** A child run's supervisor-projected roster (fix I-2). */
    roster?: ToolSpec[];
    isSubagent?: boolean;
    windowTokens?: number;
  }): Promise<Ctx & { transport: AgentTransport; seedRunId: string; runRow: () => Promise<RunRow | null> }> {
    const seeded = o.preSeeded ?? (await seedSession());
    const { userId, sessionId } = seeded;
    const prompt = o.prompt ?? "do the task";
    const promptMessageId = await seedPrompt(sessionId, prompt);
    const runId = await seedRun(sessionId, promptMessageId);

    const state = o.state ?? createMemoryStateStore();
    if (o.statePatch !== undefined) await state.patch(sessionId, o.statePatch);

    const { sink, events } = recordingSink();
    const stub = stubTransport(o.script);
    const deps: LoopDeps = {
      db,
      sink,
      state,
      keys: keyResolver(o.nullKey ?? false) as LoopDeps["keys"],
      transports: { openai: stub.transport, anthropic: stub.transport },
      litellmBaseUrl: "https://litellm.test",
      defaultModel: "ovid-test-model",
      registry: createToolRegistry(o.tools ?? []),
      approvals: o.approvals ?? recordingApprovals(),
      hooks: o.hooks ?? recordingHooks(),
      compactor: o.compactor ?? recordingCompactor(),
      skills,
      sandbox: o.sandbox === undefined ? null : o.sandbox,
      windowTokens: o.windowTokens ?? 128_000,
      ...(o.maxToolRounds !== undefined ? { maxToolRounds: o.maxToolRounds } : {}),
      ...(o.systemPromptOverride !== undefined ? { systemPromptOverride: o.systemPromptOverride } : {}),
      sleep: o.sleep ?? (async () => {}),
    };
    const job: NormalizedRunJob = {
      runId,
      sessionId,
      userId,
      prompt,
      unattended: false,
      ...(o.mode !== undefined ? { mode: o.mode } : {}),
      ...(o.roster !== undefined ? { roster: o.roster } : {}),
      ...(o.isSubagent !== undefined ? { isSubagent: o.isSubagent } : {}),
    };
    const controller = new AbortController();
    const rt: RunTime = { cancelled: false, generation: 1, signal: controller.signal };

    return {
      deps,
      job,
      rt,
      events,
      requests: stub.requests,
      state,
      controller,
      transport: stub.transport,
      seedRunId: runId,
      runRow: async () => runs.get(db, runId, userId),
    };
  }

  const types = (events: Recorded[]): SessionEventType[] => events.map((e) => e.type);
  const payloads = (events: Recorded[], type: SessionEventType) =>
    events.filter((e) => e.type === type).map((e) => e.payload);

  // ── P1 parity battery ────────────────────────────────────────────────────

  it("tool-less run emits run_started, deltas, message_completed, run_completed and persists the full text", async () => {
    const c = await makeCtx({ script: [{ text: "Hello world", deltas: ["Hello ", "world"] }] });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toEqual({ status: "completed" });
    expect(types(c.events)).toEqual([
      "run_started",
      "message_delta",
      "message_delta",
      "message_completed",
      "run_completed",
    ]);
    expect(payloads(c.events, "message_delta")).toEqual([
      { runId: c.job.runId, text: "Hello " },
      { runId: c.job.runId, text: "world" },
    ]);
    expect(payloads(c.events, "message_completed")[0]).toMatchObject({ content: "Hello world" });
    expect((await c.runRow())!.status).toBe("completed");

    const { rows } = await messages.page(db, c.job.sessionId, { limit: 10 });
    expect(rows[0]!.role).toBe("assistant");
    expect(rows[0]!.content).toBe("Hello world");
  });

  it("retries transients with the P1 ladder (sleeps 3000/9000) and reports the attempt about to run", async () => {
    const sleeps: number[] = [];
    const c = await makeCtx({
      script: [
        { error: new TransientModelError("429") },
        { error: new TransientModelError("502") },
        { text: "recovered" },
      ],
      sleep: async (ms) => {
        sleeps.push(ms);
      },
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toEqual({ status: "completed" });
    expect(sleeps).toEqual([3_000, 9_000]);
    expect(payloads(c.events, "run_started_retry")).toEqual([
      { attempt: 2, nextBackoffMs: 3_000 },
      { attempt: 3, nextBackoffMs: 9_000 },
    ]);
    // agent_double_response_test.dart :96 — the failed attempts' deltas never
    // survive into the final text.
    expect(payloads(c.events, "message_completed")[0]).toMatchObject({ content: "recovered" });
  });

  it("a failed attempt's partial deltas are never appended to the retry's text (attempt discard)", async () => {
    const partial: AgentTransport = {
      apiFormat: "openai",
      async stream(_req, h) {
        h.onTextDelta("HALF");
        throw new TransientModelError("stream reset");
      },
    };
    const good = stubTransport([{ text: "complete" }]);
    const c = await makeCtx({ script: [{ text: "unused" }] });
    c.deps.transports = { openai: partial, anthropic: partial };
    let calls = 0;
    c.deps.transports = {
      openai: {
        apiFormat: "openai",
        async stream(req, h, signal) {
          calls += 1;
          if (calls === 1) return partial.stream(req, h, signal);
          return good.transport.stream(req, h, signal);
        },
      },
      anthropic: good.transport,
    };

    const result = await runAgentLoop(c.job, c.deps, c.rt);
    expect(result.status).toBe("completed");
    expect(payloads(c.events, "message_completed")[0]).toMatchObject({ content: "complete" });
    // The failed attempt's delta DID stream (P1 parity), but it is not part of
    // the persisted completion.
    expect(payloads(c.events, "message_completed")[0]!.content).not.toContain("HALF");
  });

  it("five transient failures exhaust the ladder as model_transient_exhausted", async () => {
    const sleeps: number[] = [];
    const c = await makeCtx({
      script: [{ error: new TransientModelError("503") }],
      sleep: async (ms) => {
        sleeps.push(ms);
      },
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toMatchObject({ status: "failed", code: "model_transient_exhausted" });
    expect(sleeps).toEqual([3_000, 9_000, 27_000, 60_000]);
    expect(payloads(c.events, "run_started_retry")).toHaveLength(4);
    expect(types(c.events).slice(-1)).toEqual(["run_failed"]);
    expect((await c.runRow())!.status).toBe("failed");
  });

  it("a terminal model error fails immediately with model_terminal", async () => {
    const c = await makeCtx({ script: [{ error: new TerminalModelError("400 bad request") }] });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toMatchObject({ status: "failed", code: "model_terminal", message: "400 bad request" });
    expect(types(c.events)).toEqual(["run_started", "run_failed"]);
    expect((await c.runRow())!.status).toBe("failed");
  });

  it("a null key fails key_not_minted before run_started (P1 order)", async () => {
    const c = await makeCtx({ script: [{ text: "unused" }], nullKey: true });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toMatchObject({ status: "failed", code: "key_not_minted" });
    expect(types(c.events)).toEqual(["run_failed"]);
    expect((await c.runRow())!.status).toBe("failed");
  });

  // ── tool rounds ──────────────────────────────────────────────────────────

  it("brackets one tool call, appends the tool row, and continues to the final text", async () => {
    const echo = tool("echo_tool");
    const c = await makeCtx({
      tools: [echo],
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "echo_tool", args: { q: "hi" } }] },
        { text: "done" },
      ],
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toEqual({ status: "completed" });
    expect(types(c.events)).toEqual([
      "run_started",
      "tool_started",
      "tool_completed",
      "message_delta",
      "message_completed",
      "run_completed",
    ]);
    expect(payloads(c.events, "tool_started")[0]).toMatchObject({ runId: c.job.runId, callId: "c1", name: "echo_tool", args: { q: "hi" } });
    // M-6: the P2 wire aliases stay present (P8's projector consumes `input`).
    expect(payloads(c.events, "tool_started")[0]!.input).toEqual({ q: "hi" });
    expect(payloads(c.events, "tool_completed")[0]).toMatchObject({ callId: "c1", name: "echo_tool", ok: true });
    expect(payloads(c.events, "tool_completed")[0]!.isError).toBe(false);
    expect(echo.calls[0]!.args).toEqual({ q: "hi" });

    // The second request carries the assistant tool_calls row and the tool row
    // keyed by toolCallId.
    const second = c.requests[1]!;
    const assistant = second.messages.find((m) => m.role === "assistant" && m.toolCalls !== undefined);
    expect(assistant!.toolCalls![0]!.id).toBe("c1");
    const toolRow = second.messages.find((m) => m.role === "tool");
    expect(toolRow).toMatchObject({ toolCallId: "c1", content: "echo_tool ok" });
  });

  it("an unknown tool yields a DENIED-prefixed result and the loop continues", async () => {
    const c = await makeCtx({
      tools: [],
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "ghost_tool", args: {} }] },
        { text: "done" },
      ],
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result.status).toBe("completed");
    const row = c.requests[1]!.messages.find((m) => m.role === "tool")!;
    expect(row.content.startsWith("DENIED")).toBe(true);
  });

  it("a child run's projected roster is authoritative (fix I-2: run_shell is DENIED)", async () => {
    const shell = tool("run_shell");
    const read = tool("file_read");
    const script = (): Scripted[] => [
      {
        text: "",
        toolCalls: [{ id: "c1", name: "run_shell", args: { command: "echo hi" } }],
      },
      { text: "done" },
    ];

    // The supervisor projected a roster from `tools:["Read"]`: run_shell is
    // absent even though `isToolPermitted` (which has no child-policy input)
    // would admit it. Roster membership alone must decide.
    const child = await makeCtx({
      tools: [shell, read],
      roster: [read.spec],
      isSubagent: true,
      script: script(),
    });
    const result = await runAgentLoop(child.job, child.deps, child.rt);
    expect(result.status).toBe("completed");
    expect(shell.calls).toHaveLength(0);
    const row = child.requests[1]!.messages.find((m) => m.role === "tool")!;
    expect(row.content).toContain("DENIED: run_shell");

    // Control: the same call on a top-level run still reaches the registry
    // through the permission projection (the pre-fix behavior).
    const top = await makeCtx({ tools: [shell], script: script() });
    await runAgentLoop(top.job, top.deps, top.rt);
    expect(shell.calls).toHaveLength(1);
  });

  it("repeat guard fires at exactly the third identical call inside the tool row", async () => {
    const echo = tool("echo_tool");
    const call = { id: "c", name: "echo_tool", args: { q: "same" } };
    const c = await makeCtx({
      tools: [echo],
      script: [
        { text: "", toolCalls: [call] },
        { text: "", toolCalls: [call] },
        { text: "", toolCalls: [call] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);

    const toolRows = c.requests[3]!.messages.filter((m) => m.role === "tool");
    expect(toolRows).toHaveLength(3);
    expect(toolRows[0]!.content).not.toContain("[note]");
    expect(toolRows[1]!.content).not.toContain("[note]");
    expect(toolRows[2]!.content).toContain(
      "[note] Same tool + identical args repeated 3 times — re-read the tool output or change approach.",
    );
  });

  it("a timed-out tool kills the call and returns the exact KILLED message", async () => {
    const slow = slowTool("slow_tool", 10);
    const sandbox = stubSandbox();
    const c = await makeCtx({
      tools: [slow],
      sandbox,
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "slow_tool", args: {} }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);

    expect(sandbox.kills).toHaveLength(1);
    expect(sandbox.kills[0]).toContain("c1");
    const row = c.requests[1]!.messages.find((m) => m.role === "tool")!;
    expect(row.content).toContain(TOOL_TIMEOUT_MESSAGE("slow_tool", 0));
    expect(payloads(c.events, "tool_completed")[0]).toMatchObject({ ok: false });
  });

  it("mode policy denies a mutating tool in safe mode with the Read-Only copy", async () => {
    const writer = tool("file_write");
    const c = await makeCtx({
      tools: [writer],
      statePatch: { mode: "safe" },
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "file_write", args: { path: "a.txt", content: "x" } }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);

    expect(writer.calls).toHaveLength(0);
    const row = c.requests[1]!.messages.find((m) => m.role === "tool")!;
    expect(row.content.startsWith("READ-ONLY MODE: this action is blocked.")).toBe(true);
  });

  it("mode policy prompts for an outside-workspace path in auto mode", async () => {
    const reader = tool("file_read");
    const approvals = recordingApprovals("deny");
    const c = await makeCtx({
      tools: [reader],
      approvals,
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "file_read", args: { path: "/etc/passwd" } }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);

    expect(approvals.requests).toHaveLength(1);
    expect(approvals.requests[0]!.pathTargets).toEqual(["/etc/passwd"]);
    expect(reader.calls).toHaveLength(0);
    const row = c.requests[1]!.messages.find((m) => m.role === "tool")!;
    expect(row.content).toBe("DENIED by user");
  });

  // ── hook gates ───────────────────────────────────────────────────────────

  it("pre_tool updatedInput is merged before dispatch", async () => {
    const echo = tool("echo_tool");
    const hooks = recordingHooks({
      listeners: ["pre_tool"],
      gate: { decision: "allow", updatedInput: { q: "rewritten" }, reason: null, bypassPermission: false, decidedByPlugin: null, deniedByPlugin: null },
    });
    const c = await makeCtx({
      tools: [echo],
      hooks,
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "echo_tool", args: { q: "original" } }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(echo.calls[0]!.args).toEqual({ q: "rewritten" });
  });

  it("pre_tool deny produces the exact DENIED by hook row", async () => {
    const echo = tool("echo_tool");
    const hooks = recordingHooks({
      listeners: ["pre_tool"],
      gate: { decision: "deny", reason: "not allowed", bypassPermission: false, decidedByPlugin: null, deniedByPlugin: "p1" },
    });
    const c = await makeCtx({
      tools: [echo],
      hooks,
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "echo_tool", args: {} }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(echo.calls).toHaveLength(0);
    const row = c.requests[1]!.messages.find((m) => m.role === "tool")!;
    expect(row.content).toBe("DENIED by hook (p1): not allowed");
    // M-1: a denied call never executed → no post_tool.
    expect(hooks.fired).not.toContain("post_tool");
  });

  it("fires post_tool after tool_completed (F11 ordering)", async () => {
    const echo = tool("echo_tool");
    const order: string[] = [];
    const hooks = recordingHooks({ listeners: ["pre_tool"] });
    const baseFire = hooks.fire;
    hooks.fire = async (event, sid, payload) => {
      order.push(event);
      return baseFire(event, sid, payload);
    };
    const baseGate = hooks.fireGate;
    hooks.fireGate = async (...args) => {
      order.push("pre_tool");
      return baseGate(...args);
    };
    const c = await makeCtx({
      tools: [echo],
      hooks,
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "echo_tool", args: {} }] },
        { text: "done" },
      ],
    });
    const originalSink = c.deps.sink;
    c.deps.sink = {
      async emit(type, payload) {
        if (type === "tool_completed") order.push("tool_completed");
        await originalSink.emit(type, payload);
      },
    };
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(order.indexOf("pre_tool")).toBeLessThan(order.indexOf("tool_completed"));
    expect(order.indexOf("tool_completed")).toBeLessThan(order.indexOf("post_tool"));
  });

  it("pre_tool ask routes through the approval gate (a no is the user-denial shape)", async () => {
    const echo = tool("echo_tool");
    const approvals = recordingApprovals("deny");
    const hooks = recordingHooks({
      listeners: ["pre_tool"],
      gate: { decision: "ask", reason: "hook defers", bypassPermission: false, decidedByPlugin: "p1", deniedByPlugin: null },
    });
    const c = await makeCtx({
      tools: [echo],
      hooks,
      approvals,
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "echo_tool", args: {} }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(approvals.requests).toHaveLength(1);
    expect(echo.calls).toHaveLength(0);
    const row = c.requests[1]!.messages.find((m) => m.role === "tool")!;
    expect(row.content).toBe("DENIED by user");
  });

  it("bypassPermission skips the ordinary prompt but never widens the hard mode gate", async () => {
    const writer = tool("file_write");
    const approvals = recordingApprovals("allow");
    const hooks = recordingHooks({
      listeners: ["pre_tool"],
      gate: { decision: "allow", bypassPermission: true, reason: null, decidedByPlugin: "p1", deniedByPlugin: null },
    });
    const c = await makeCtx({
      tools: [writer],
      hooks,
      approvals,
      statePatch: { mode: "safe" },
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "file_write", args: { path: "/etc/x", content: "x" } }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    // No prompt was raised, and the Read-Only hard gate still refused.
    expect(approvals.requests).toHaveLength(0);
    expect(writer.calls).toHaveLength(0);
    const row = c.requests[1]!.messages.find((m) => m.role === "tool")!;
    expect(row.content.startsWith("READ-ONLY MODE")).toBe(true);
  });

  it("bypassPermission skips the outside-workspace prompt in auto mode", async () => {
    const reader = tool("file_read");
    const approvals = recordingApprovals("deny");
    const hooks = recordingHooks({
      listeners: ["pre_tool"],
      gate: { decision: "allow", bypassPermission: true, reason: null, decidedByPlugin: "p1", deniedByPlugin: null },
    });
    const c = await makeCtx({
      tools: [reader],
      hooks,
      approvals,
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "file_read", args: { path: "/etc/passwd" } }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(approvals.requests).toHaveLength(0);
    expect(reader.calls).toHaveLength(1);
  });

  it("confirms a destructive shell command even in drive mode and despite a hook allow", async () => {
    const shell = tool("run_shell");
    const approvals = recordingApprovals("deny");
    const hooks = recordingHooks({
      listeners: ["pre_tool"],
      gate: { decision: "allow", bypassPermission: true, reason: null, decidedByPlugin: "p1", deniedByPlugin: null },
    });
    const c = await makeCtx({
      tools: [shell],
      hooks,
      approvals,
      mode: "drive",
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "run_shell", args: { cmd: "rm -rf /tmp/data" } }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);

    expect(approvals.requests).toHaveLength(1);
    expect(approvals.requests[0]!.summary).toBe("Destructive command");
    expect(approvals.requests[0]!.allowAlways).toBe(false);
    expect(shell.calls).toHaveLength(0);
    const row = c.requests[1]!.messages.find((m) => m.role === "tool")!;
    expect(row.content).toBe("DENIED by user");
  });

  it("dispatches a run_code call through the loop (agent_run_code_contract_test.dart)", async () => {
    const runCode = tool("run_code");
    const c = await makeCtx({
      tools: [runCode],
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "run_code", args: { language: "python", code: "print(1)" } }] },
        { text: "done" },
      ],
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);
    expect(result.status).toBe("completed");
    expect(runCode.calls[0]!.args).toEqual({ language: "python", code: "print(1)" });
    expect(payloads(c.events, "tool_completed")[0]).toMatchObject({ name: "run_code", ok: true });
  });

  it("a blocking user_prompt_submit hook fails the run with its reason", async () => {
    const hooks = recordingHooks({ promptBlockReason: "prompt refused by policy" });
    const c = await makeCtx({ hooks, script: [{ text: "never" }] });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toMatchObject({ status: "failed", code: "hook_blocked", message: "prompt refused by policy" });
    expect(types(c.events)).toEqual(["run_started", "run_failed"]);
    expect(c.requests).toHaveLength(0);
    expect((await c.runRow())!.status).toBe("failed");
  });

  it("a pre_request block reason is observe-only — noted, never fatal", async () => {
    const hooks = recordingHooks({
      preRequest: { output: "hook context", systemMessages: ["note one"], promptBlockReason: "would block" },
    });
    const c = await makeCtx({ hooks, script: [{ text: "done" }] });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toEqual({ status: "completed" });
    expect(payloads(c.events, "system_note")[0]).toMatchObject({ code: "hook_block_ignored" });
    const systemTexts = c.requests[0]!.system.map((m) => m.content);
    // Dart insertion order (M-5): the output row rides above the reversed
    // systemMessages; standing contexts would ride above both.
    expect(systemTexts[0]).toBe("[plugin hook context — on_pre_request]\nhook context");
    expect(systemTexts[1]).toBe("[plugin hook]\nnote one");
  });

  // ── plan mode: asks nothing (I-1) ────────────────────────────────────────

  it("plan mode denies an outside-workspace read outright — no approval card", async () => {
    const reader = tool("file_read");
    const approvals = recordingApprovals("allow");
    const c = await makeCtx({
      tools: [reader],
      approvals,
      statePatch: { planMode: true },
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "file_read", args: { path: "/etc/passwd" } }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);

    expect(approvals.requests).toHaveLength(0);
    expect(reader.calls).toHaveLength(0);
    const row = c.requests[1]!.messages.find((m) => m.role === "tool")!;
    expect(row.content).toMatch(/^DENIED: file_read may not access targets outside/);
  });

  it("plan mode still allows an in-workspace read with no card", async () => {
    const reader = tool("file_read");
    const approvals = recordingApprovals("deny");
    const c = await makeCtx({
      tools: [reader],
      approvals,
      statePatch: { planMode: true },
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "file_read", args: { path: "src/index.ts" } }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(approvals.requests).toHaveLength(0);
    expect(reader.calls).toHaveLength(1);
  });

  // ── destructive confirmation: all three families (I-2) ───────────────────

  it("job_start destructive payload prompts (drive mode too) and denies without running", async () => {
    const jobStart = tool("job_start");
    const approvals = recordingApprovals("deny");
    const c = await makeCtx({
      tools: [jobStart],
      approvals,
      mode: "drive",
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "job_start", args: { command: "rm -rf /var/data" } }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(approvals.requests).toHaveLength(1);
    expect(approvals.requests[0]!.tool).toBe("job_start");
    expect(jobStart.calls).toHaveLength(0);
  });

  it("run_code destructive payload prompts (drive mode too) and denies without running", async () => {
    const runCode = tool("run_code");
    const approvals = recordingApprovals("deny");
    const c = await makeCtx({
      tools: [runCode],
      approvals,
      mode: "drive",
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "run_code", args: { lang: "python", code: "os.system('rm -rf /')" } }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(approvals.requests).toHaveLength(1);
    expect(approvals.requests[0]!.tool).toBe("run_code");
    expect(runCode.calls).toHaveLength(0);
  });

  it("a benign run_code payload raises no destructive card", async () => {
    const runCode = tool("run_code");
    const approvals = recordingApprovals("deny");
    const c = await makeCtx({
      tools: [runCode],
      approvals,
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "run_code", args: { lang: "python", code: "print(1)" } }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(approvals.requests).toHaveLength(0);
    expect(runCode.calls).toHaveLength(1);
  });

  it("matches the Dart defaultDeniedCommands clauses (chmod/chown/dd/reboot/fork bomb)", async () => {
    for (const cmd of [
      "chmod -R 777 /",
      "chown -R root /",
      "dd if=/dev/zero of=/dev/sda",
      "reboot",
      ":(){ :|:& };:",
      "find / -name x -delete",
      "echo x > /dev/sda",
    ]) {
      const shell = tool("run_shell");
      const approvals = recordingApprovals("deny");
      const c = await makeCtx({
        tools: [shell],
        approvals,
        mode: "drive",
        script: [
          { text: "", toolCalls: [{ id: "c1", name: "run_shell", args: { cmd } }] },
          { text: "done" },
        ],
      });
      await runAgentLoop(c.job, c.deps, c.rt);
      expect(approvals.requests, cmd).toHaveLength(1);
      expect(shell.calls, cmd).toHaveLength(0);
    }
  });

  // ── sandbox availability is a RUN failure (I-3) ──────────────────────────

  it("SandboxAdmissionError from a tool terminalizes the run as sandbox_busy", async () => {
    const failing: Tool = {
      spec: { name: "run_shell", description: "x", parameters: { type: "object" } },
      timeoutMs: 1_000,
      async execute() {
        const err = new Error("admission timed out");
        err.name = "SandboxAdmissionError";
        throw err;
      },
    };
    const c = await makeCtx({
      tools: [failing],
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "run_shell", args: { cmd: "ls" } }] },
        { text: "never" },
      ],
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);
    expect(result).toMatchObject({ status: "failed", code: "sandbox_busy" });
    expect(payloads(c.events, "run_failed")).toEqual([
      { code: "sandbox_busy", message: "admission timed out" },
    ]);
    expect((await c.runRow())!.status).toBe("failed");
  });

  it("SandboxCapacityError / RootfsUnavailable terminalize as sandbox_unavailable", async () => {
    for (const name of ["SandboxCapacityError", "RootfsUnavailable"]) {
      const failing: Tool = {
        spec: { name: "run_shell", description: "x", parameters: { type: "object" } },
        timeoutMs: 1_000,
        async execute() {
          const err = new Error(`${name} boom`);
          err.name = name;
          throw err;
        },
      };
      const c = await makeCtx({
        tools: [failing],
        script: [
          { text: "", toolCalls: [{ id: "c1", name: "run_shell", args: { cmd: "ls" } }] },
          { text: "never" },
        ],
      });
      const result = await runAgentLoop(c.job, c.deps, c.rt);
      expect(result, name).toMatchObject({ status: "failed", code: "sandbox_unavailable" });
    }
  });

  it("sandboxTools.run rethrows typed sandbox failures instead of making them tool errors", async () => {
    const sandbox = stubSandbox();
    sandbox.exec = async () => {
      const err = new Error("sandbox gate full");
      err.name = "SandboxAdmissionError";
      throw err;
    };
    const registry = createSandboxTools({ sandbox });
    const runCode = registry.find((t) => t.spec.name === "run_code")!;
    const c = await makeCtx({
      tools: [runCode],
      sandbox,
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "run_code", args: { lang: "python", code: "print(1)" } }] },
        { text: "never" },
      ],
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);
    expect(result).toMatchObject({ status: "failed", code: "sandbox_busy" });
  });

  // ── residual test gaps (M-7) ─────────────────────────────────────────────

  it("pins runs.bumpAttempt per model attempt", async () => {
    const c = await makeCtx({
      script: [{ error: new TransientModelError("503") }, { text: "ok" }],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect((await c.runRow())!.attempts).toBe(2);
  });

  it("the turnsWithoutProgress gate stops transient retries below the attempt cap", async () => {
    // Turn 1: 4 retries (twp 4) then success (decays to 3).
    // Turn 2: 3 retries push twp to 6; the 4th transient hits the gate and
    // fails instead of using the 5th attempt.
    const script: Scripted[] = [
      { error: new TransientModelError("503") },
      { error: new TransientModelError("503") },
      { error: new TransientModelError("503") },
      { error: new TransientModelError("503") },
      { text: "", toolCalls: [{ id: "c1", name: "echo_tool", args: {} }] },
      { error: new TransientModelError("503") },
      { error: new TransientModelError("503") },
      { error: new TransientModelError("503") },
      { error: new TransientModelError("503") },
      { error: new TransientModelError("503") },
      { text: "unreachable" },
    ];
    const c = await makeCtx({ tools: [tool("echo_tool")], script });
    const result = await runAgentLoop(c.job, c.deps, c.rt);
    expect(result).toMatchObject({ status: "failed", code: "model_transient_exhausted" });
    // 4 retries on turn 1 + 3 on turn 2 = 7 retry events (not 8).
    expect(payloads(c.events, "run_started_retry")).toHaveLength(7);
  });

  it("fires session_start once and post_request after every response", async () => {
    const hooks = recordingHooks();
    const c = await makeCtx({
      hooks,
      tools: [tool("echo_tool")],
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "echo_tool", args: {} }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(hooks.fired.filter((e) => e === "session_start")).toHaveLength(1);
    expect(hooks.fired.filter((e) => e === "user_prompt_submit")).toHaveLength(1);
    expect(hooks.fired.filter((e) => e === "post_request")).toHaveLength(2);
  });

  it("lands a pending plan-mode transition as the run unwinds", async () => {
    const c = await makeCtx({ script: [{ text: "done" }] });
    const baseStream = c.transport.stream;
    c.deps.transports = {
      openai: {
        apiFormat: "openai",
        async stream(req, h, signal) {
          const res = await baseStream(req, h, signal);
          // The user flips plan mode while the LAST turn is still open.
          await c.state.patch(c.job.sessionId, { pendingPlanMode: true });
          return res;
        },
      },
      anthropic: c.transport,
    };
    const result = await runAgentLoop(c.job, c.deps, c.rt);
    expect(result).toEqual({ status: "completed" });
    expect((await c.state.get(c.job.sessionId)).planMode).toBe(true);
    expect((await c.state.get(c.job.sessionId)).pendingPlanMode).toBeNull();
    expect(payloads(c.events, "plan_mode_changed")).toHaveLength(1);
  });

  it("strips a /v1 suffix from an anthropic route base (T5-C1)", async () => {
    const c = await makeCtx({ script: [{ text: "done" }] });
    c.deps.keys = {
      async resolve() {
        return { kind: "byok-anthropic", apiKey: "sk-ant", baseUrl: "https://api.anthropic.com/v1/", model: "claude-test" };
      },
    };
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(c.requests[0]!.baseUrl).toBe("https://api.anthropic.com");
  });

  it("recovers from overflow at most ONCE per run (M-2)", async () => {
    const compactor = recordingCompactor(() => ({ compacted: true, messages: [{ role: "user", content: "c" }] }));
    const c = await makeCtx({
      compactor,
      script: [
        { error: new TerminalModelError("maximum context length exceeded") },
        { error: new TerminalModelError("maximum context length exceeded") },
      ],
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);
    expect(result).toMatchObject({ status: "failed", code: "model_terminal" });
    expect(compactor.calls).toHaveLength(1);
  });

  // ── stop / todo / steering ───────────────────────────────────────────────
  it("Stop veto without cancel injects the exact veto row and continues", async () => {
    let stops = 0;
    const hooks = recordingHooks();
    hooks.fireStop = async () => {
      stops += 1;
      return stops === 1 ? { veto: true, reason: "tests failing", vetoedByPlugin: "p1" } : { veto: false };
    };
    const c = await makeCtx({ hooks, script: [{ text: "first" }, { text: "second" }] });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toEqual({ status: "completed" });
    expect(payloads(c.events, "message_completed")[0]).toMatchObject({ content: "second" });
    const vetoRow = c.requests[1]!.messages.find(
      (m) => m.role === "user" && m.content.startsWith("[system] A plugin hook vetoed"),
    )!;
    expect(vetoRow.content).toBe(
      "[system] A plugin hook vetoed the end of this run (reason: tests failing). Continue working on the task; do not repeat your last message verbatim.",
    );
    // The vetoed answer stays in the request too (Dart keeps it).
    expect(c.requests[1]!.messages.some((m) => m.role === "assistant" && m.content === "first")).toBe(true);
  });

  it("user cancel beats a Stop veto", async () => {
    const hooks = recordingHooks({ stop: { veto: true, reason: "never", vetoedByPlugin: "p1" } });
    const c = await makeCtx({ hooks, script: [{ text: "answer" }] });
    // Flip the token from inside the model call — the loop's post-response
    // cancel check fires before the stop gate.
    const baseStream = c.transport.stream;
    c.deps.transports = {
      openai: {
        apiFormat: "openai",
        async stream(req, h, signal) {
          const res = await baseStream(req, h, signal);
          c.rt.cancelled = true;
          return res;
        },
      },
      anthropic: c.transport,
    };
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toMatchObject({ status: "cancelled" });
    expect(payloads(c.events, "run_cancelled")[0]).toMatchObject({ runId: c.job.runId });
    expect(payloads(c.events, "run_cancelled")[0]!.reason).toBeUndefined();
    expect(hooks.fired).not.toContain("stop");
    expect((await c.runRow())!.status).toBe("cancelled");
  });

  it("todo nudge is injected once, then the next stop finalizes", async () => {
    const c = await makeCtx({
      statePatch: { todos: [{ content: "finish it", status: "in_progress" }, { content: "done", status: "completed" }] },
      script: [{ text: "first" }, { text: "second" }],
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toEqual({ status: "completed" });
    const nudge = c.requests[1]!.messages.find(
      (m) => m.role === "user" && m.content.startsWith("[system] Your SESSION TODOS"),
    )!;
    expect(nudge.content).toBe(
      "[system] Your SESSION TODOS still has pending items:\n- [~] finish it\n\nContinue working on them. Mark each item in_progress before starting it and completed when done. If a pending item is already done or no longer relevant, update the list with todo_write. Then give your final answer.",
    );
    // Exactly one nudge across the whole run (the second stop finalized).
    const nudges = c.requests
      .flatMap((r) => r.messages)
      .filter((m) => m.role === "user" && m.content.startsWith("[system] Your SESSION TODOS"));
    expect(nudges).toHaveLength(1);
  });

  it("todo_write re-arms the nudge (Dart AS:21925) — a second no-progress stretch nudges again", async () => {
    const todoWrite = tool("todo_write");
    const c = await makeCtx({
      tools: [todoWrite],
      statePatch: { todos: [{ content: "a", status: "pending" }] },
      script: [
        // 1st stop: nudge #1
        { text: "first" },
        // todo_write re-arms the cadence, then another pending stop nudges again
        { text: "", toolCalls: [{ id: "c1", name: "todo_write", args: { todos: [] } }] },
        { text: "second" },
        { text: "third" },
      ],
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toEqual({ status: "completed" });
    const last = c.requests[c.requests.length - 1]!.messages.filter(
      (m) => m.role === "user" && m.content.startsWith("[system] Your SESSION TODOS"),
    );
    expect(last).toHaveLength(2);
    expect(payloads(c.events, "message_completed")[0]).toMatchObject({ content: "third" });
  });

  it("steering: a queued run seeded mid-loop joins the next request and merges once", async () => {
    const c = await makeCtx({
      tools: [tool("echo_tool")],
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "echo_tool", args: {} }] },
        { text: "done" },
      ],
    });
    // Seed a queued run while the loop is between requests: the tool execute
    // is the mid-loop hook.
    const echo = c.deps.registry.get("echo_tool")!;
    const baseExecute = echo.execute.bind(echo);
    (echo as { execute: Tool["execute"] }).execute = async (args, ctx) => {
      const msg = await messages.append(db, { sessionId: c.job.sessionId, role: "user", content: "steer me" });
      await runs.create(db, { sessionId: c.job.sessionId, promptMessageId: msg.id });
      return baseExecute(args, ctx);
    };

    const result = await runAgentLoop(c.job, c.deps, c.rt);
    expect(result).toEqual({ status: "completed" });

    const second = c.requests[1]!;
    expect(second.messages.some((m) => m.role === "user" && m.content === "steer me")).toBe(true);
    const notes = payloads(c.events, "system_note").filter((p) => p.code === "run_merged");
    expect(notes).toHaveLength(1);
    expect(notes[0]!.runId).toBe(c.job.runId);
  });

  // ── budget boundary + overflow ───────────────────────────────────────────

  it("compacts at turn 12 and rebuilds the request from the compacted history", async () => {
    const echo = tool("echo_tool");
    let turn = 0;
    const compactor = recordingCompactor(({ messages: msgs }) => ({
      compacted: true,
      // Fold everything before the last tool row — the pre-cut rows must
      // disappear from the rebuilt request.
      messages: msgs.slice(-2) as never[],
    }));
    const c = await makeCtx({
      tools: [echo],
      compactor,
      script: Array.from({ length: 14 }, (_, i) => ({
        text: "",
        toolCalls: [{ id: `c${i}`, name: "echo_tool", args: { i } }],
      })),
    });
    // 13 tool turns then a final answer.
    const scripted: Scripted[] = [
      ...Array.from({ length: 13 }, (_, i) => ({
        text: "",
        toolCalls: [{ id: `c${i}`, name: "echo_tool", args: { i } }],
      })),
      { text: "final" },
    ];
    const stub = stubTransport(scripted);
    c.deps.transports = { openai: stub.transport, anthropic: stub.transport };

    const result = await runAgentLoop(c.job, c.deps, c.rt);
    expect(result).toEqual({ status: "completed" });

    expect(compactor.calls.length).toBeGreaterThanOrEqual(1);
    const afterCompact = stub.requests[13]!;
    // Rebuilt from the compacted history + the continuation nudge.
    expect(afterCompact.messages.some((m) => m.role === "user" && m.content === BUDGET_CONTINUATION_NUDGE)).toBe(true);
    expect(afterCompact.messages.some((m) => m.role === "tool" && m.content === "echo_tool ok" && m.toolCallId === "c0")).toBe(false);
    void turn;
  });

  it("replays a persisted checkpoint with the DURABLE fold boundary (fix I-3: no folded originals re-sent)", async () => {
    const seeded = await seedSession();
    const oldIds: string[] = [];
    for (let i = 0; i < 6; i += 1) {
      const row = await messages.append(db, {
        sessionId: seeded.sessionId,
        role: i % 2 === 0 ? "user" : "assistant",
        content: `OLD-${i}`,
      });
      oldIds.push(row.id);
    }
    const state = createMemoryStateStore();
    await state.patch(seeded.sessionId, {
      compaction: {
        ledger: {},
        summary: "PERSISTED-CHECKPOINT",
        // The first four durable rows are already represented by the summary.
        cutoffMessageId: oldIds[3]!,
        compactedAtCount: 1,
      },
    });

    const c = await makeCtx({
      preSeeded: seeded,
      state,
      prompt: "NEW-PROMPT",
      script: [{ text: "done" }],
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);
    expect(result.status).toBe("completed");

    const sent = c.requests[0]!.messages;
    // The stable checkpoint row leads; the tail starts AFTER the cutoff.
    expect(sent[0]!.role).toBe("system");
    expect(sent[0]!.content).toContain("<compacted-summary>");
    expect(sent[0]!.content).toContain("PERSISTED-CHECKPOINT");
    const contents = sent.map((m) => m.content);
    for (const folded of ["OLD-0", "OLD-1", "OLD-2", "OLD-3"]) {
      expect(contents).not.toContain(folded);
    }
    for (const kept of ["OLD-4", "OLD-5", "NEW-PROMPT"]) {
      expect(contents).toContain(kept);
    }
  });

  it("recovers from a context-overflow terminal by compacting and rebuilding the request", async () => {
    const compactor = recordingCompactor(() => ({ compacted: true, messages: [{ role: "user", content: "compacted" }] as never[] }));
    const c = await makeCtx({
      compactor,
      script: [
        { error: new TerminalModelError("maximum context length exceeded") },
        { text: "after compaction" },
      ],
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toEqual({ status: "completed" });
    expect(compactor.calls).toHaveLength(1);
    // The retry request is the REBUILT (shorter) history, not the original.
    expect(c.requests[1]!.messages.map((m) => ({ role: m.role, content: m.content }))).toEqual([
      { role: "user", content: "compacted" },
    ]);
  });

  it("a non-overflow terminal never invokes the compactor", async () => {
    const compactor = recordingCompactor();
    const c = await makeCtx({ compactor, script: [{ error: new TerminalModelError("401 unauthorized") }] });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(compactor.calls).toHaveLength(0);
  });

  // ── cache-stable request wiring (ruling R3, end-to-end) ──────────────────

  it("every request carries canonical sorted tools, ≤4 marks, no volatile mark, and a session cache key", async () => {
    const alpha = tool("alpha_tool");
    const zeta = tool("zeta_tool");
    const c = await makeCtx({
      tools: [zeta, alpha],
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "alpha_tool", args: {} }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);

    expect(c.requests).toHaveLength(2);
    for (const req of c.requests) {
      expect(req.tools.map((t) => t.name)).toEqual(["alpha_tool", "zeta_tool"]);
      expect(JSON.stringify(req.tools)).toBe(JSON.stringify(c.requests[0]!.tools));
      const marks =
        req.system.filter((m) => m.cacheControl !== undefined).length +
        req.messages.filter((m) => m.cacheControl !== undefined).length +
        req.tools.filter((t) => (t as { cacheControl?: unknown }).cacheControl !== undefined).length;
      expect(marks).toBeLessThanOrEqual(4);
      expect(marks).toBeGreaterThan(0);
      // Volatile rows are never marked.
      expect(req.system.filter((m) => m.volatile === true && m.cacheControl !== undefined)).toEqual([]);
      expect(req.messages.filter((m) => m.volatile === true && m.cacheControl !== undefined)).toEqual([]);
      expect(req.promptCacheKey).toBe(c.job.sessionId);
    }
    // The stable system block is the LAST non-volatile system row.
    const stable = [...c.requests[0]!.system].reverse().find((m) => m.volatile !== true && m.content.trim() !== "")!;
    expect(stable.cacheControl).toEqual({ type: "ephemeral" });
  });

  it("volatile context rides last and is never cache-marked", async () => {
    const c = await makeCtx({
      statePatch: { todos: [{ content: "volatile todo", status: "pending" }] },
      script: [{ text: "done" }],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    const sys = c.requests[0]!.system;
    expect(sys[sys.length - 1]!.volatile).toBe(true);
    expect(sys[sys.length - 1]!.content).toContain("SESSION TODOS");
    expect(sys[sys.length - 1]!.cacheControl).toBeUndefined();
  });

  it("the anthropic route stamps cacheMode anthropicNative so the transport serializes cache_control blocks", async () => {
    const c = await makeCtx({ script: [{ text: "done" }] });
    c.deps.keys = {
      async resolve() {
        return { kind: "byok-anthropic", apiKey: "sk-ant", baseUrl: "https://api.anthropic.com", model: "claude-test" };
      },
    };
    await runAgentLoop(c.job, c.deps, c.rt);
    const req = c.requests[0]!;
    expect(req.cacheMode).toBe("anthropicNative");
    expect(req.baseUrl).toBe("https://api.anthropic.com");
    expect(req.system.some((m) => m.cacheControl !== undefined)).toBe(true);
    // The loop's marks reach Task 5's wire conversion as cache_control blocks.
    const wire = convertMessagesToAnthropic([...req.system, ...req.messages], {
      cacheControl: req.cacheMode === "anthropicNative",
    });
    expect(wire.system.some((b) => b.cache_control !== undefined)).toBe(true);
  });

  // ── plan mode + bounded mode + mode feeding ──────────────────────────────

  it("applies pendingPlanMode at the turn boundary and emits plan_mode_changed", async () => {
    const c = await makeCtx({
      statePatch: { pendingPlanMode: true, mode: "auto" },
      script: [{ text: "done" }],
    });
    await runAgentLoop(c.job, c.deps, c.rt);

    expect(payloads(c.events, "plan_mode_changed")[0]).toMatchObject({ planMode: true });
    expect((await c.state.get(c.job.sessionId)).planMode).toBe(true);
    expect((await c.state.get(c.job.sessionId)).pendingPlanMode).toBeNull();
  });

  it("bounded mode fails with tool_rounds_exhausted after exactly N rounds", async () => {
    const echo = tool("echo_tool");
    const c = await makeCtx({
      tools: [echo],
      maxToolRounds: 2,
      script: [{ text: "", toolCalls: [{ id: "c1", name: "echo_tool", args: {} }] }],
    });
    const result = await runAgentLoop(c.job, c.deps, c.rt);

    expect(result).toMatchObject({ status: "failed", code: "tool_rounds_exhausted" });
    expect(echo.calls).toHaveLength(2);
    expect(payloads(c.events, "run_failed")).toEqual([{ code: "tool_rounds_exhausted" }]);
  });

  it("feeds ToolContext.mode from state when the job has no mode", async () => {
    const echo = tool("echo_tool");
    const c = await makeCtx({
      tools: [echo],
      statePatch: { mode: "safe" },
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "echo_tool", args: {} }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(echo.calls[0]!.ctx.mode).toBe("safe");
  });

  it("feeds ToolContext.mode from the job when provided", async () => {
    const echo = tool("echo_tool");
    const c = await makeCtx({
      tools: [echo],
      mode: "drive",
      script: [
        { text: "", toolCalls: [{ id: "c1", name: "echo_tool", args: {} }] },
        { text: "done" },
      ],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(echo.calls[0]!.ctx.mode).toBe("drive");
  });

  it("systemPromptOverride replaces the stable block byte-for-byte (P2-compat)", async () => {
    const c = await makeCtx({
      systemPromptOverride: "SYSTEM_PROMPT_V1",
      script: [{ text: "done" }],
    });
    await runAgentLoop(c.job, c.deps, c.rt);
    expect(c.requests[0]!.system.map((m) => m.content)).toEqual(["SYSTEM_PROMPT_V1"]);
    expect(c.requests[0]!.system.some((m) => m.volatile === true)).toBe(false);
  });
});
