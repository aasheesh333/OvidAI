// Subagents (P3 Task 20) — policy, depth precedence, child loop, stop gate,
// cancellation cascade, events. Port targets: claude_code_subagent_parity
// (roster projection, spawn refusal), subagent_ceiling (management tools stay,
// spawn tools never advertise), p2_subagent_races (FIFO/stop/cancel), and the
// plan's own Step-1 list.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import {
  createDb,
  messages,
  migrate,
  runs,
  sessions,
  users,
  type Db,
} from "@ovid/db";

import type { AgentEngine } from "./engine.js";
import type { AgentRunJob } from "./loop.js";
import type { HookEngine, HookStopResult, SessionStateStore } from "./ports.js";
import { createMemoryStateStore } from "./ports.js";
import { createPostgresSessionStateStore } from "./stateStore.js";
import { CHILD_DENIED_TOOLS } from "./roster.js";
import {
  createDbSubagentStore,
  createSubagentSupervisor,
  buildChildSummary,
  formatSubagentReports,
  REPORT_FAILURE_LIMIT,
  REPORT_SUMMARY_LIMIT,
  takePendingSubagentReports,
  MAX_SUBAGENT_STOP_BLOCKS,
  PENDING_SUBAGENT_REPORTS_KEY,
  projectChildRoster,
  storedSubagentTools,
  subagentPolicyAllows,
  subagentToolPolicy,
  type RunStatus,
  type SubagentReport,
  type SubagentStore,
} from "./subagents.js";
import type { ToolContext, ToolSpec } from "./types.js";
import { createToolRegistry } from "./types.js";

// ── fakes ───────────────────────────────────────────────────────────────────

interface FakeSession {
  id: string;
  parent: string | null;
  title: string | null;
  userId: string;
  messages: Array<{ id: string; role: string; content: string }>;
}

interface FakeRun {
  id: string;
  sessionId: string;
  promptMessageId: string | null;
  status: RunStatus;
}

function fakeStore(lineages: Record<string, string[]> = {}) {
  let seq = 0;
  const sessionsById = new Map<string, FakeSession>();
  const runRows = new Map<string, FakeRun>();
  const lastText = new Map<string, string | null>();
  const reports: Array<{ parentSessionId: string; report: SubagentReport }> = [];
  const runErrors = new Map<string, string | null>();
  let parentActive = false;
  let childCreates = 0;

  const store: SubagentStore = {
    async createChild(o) {
      childCreates += 1;
      const id = `child-${++seq}`;
      sessionsById.set(id, {
        id,
        parent: o.parentSessionId,
        title: o.title,
        userId: o.userId,
        messages: [],
      });
      return { sessionId: id };
    },
    async appendUserMessage(sessionId, content) {
      const id = `msg-${++seq}`;
      sessionsById.get(sessionId)!.messages.push({ id, role: "user", content });
      return { messageId: id };
    },
    async createRun(o) {
      const id = `run-${++seq}`;
      runRows.set(id, {
        id,
        sessionId: o.sessionId,
        promptMessageId: o.promptMessageId,
        status: "queued",
      });
      return { runId: id };
    },
    async claimRun(runId) {
      const row = runRows.get(runId);
      if (row === undefined || row.status !== "queued") return false;
      row.status = "running";
      return true;
    },
    async runStatus(runId) {
      return runRows.get(runId)?.status ?? null;
    },
    async runError(runId) {
      return runErrors.get(runId) ?? null;
    },
    async hasActiveRun() {
      return parentActive;
    },
    async queuedRuns(sessionId) {
      return [...runRows.values()]
        .filter((r) => r.sessionId === sessionId && r.status === "queued")
        .map((r) => ({ runId: r.id, promptMessageId: r.promptMessageId }));
    },
    async promptText(messageId) {
      for (const s of sessionsById.values()) {
        const m = s.messages.find((row) => row.id === messageId);
        if (m !== undefined) return m.content;
      }
      return null;
    },
    async lastAssistantText(sessionId) {
      return lastText.get(sessionId) ?? null;
    },
    async lineage(sessionId) {
      return lineages[sessionId] ?? [sessionId];
    },
    async listChildren(parentSessionId) {
      return [...sessionsById.values()]
        .filter((s) => s.parent === parentSessionId)
        .map((s) => s.id);
    },
    async reportToParent(parentSessionId, report) {
      reports.push({ parentSessionId, report });
    },
  };

  return {
    store,
    sessionsById,
    runRows,
    lastText,
    setLastText(sessionId: string, text: string | null): void {
      lastText.set(sessionId, text);
    },
    reports,
    runErrors,
    setParentActive(next: boolean): void {
      parentActive = next;
    },
    get childCreates(): number {
      return childCreates;
    },
  };
}

function fakeEngine(
  fake: ReturnType<typeof fakeStore>,
  o: { onRun?: (job: AgentRunJob) => Promise<void> | void } = {},
): { engine: AgentEngine; jobs: AgentRunJob[] } {
  const jobs: AgentRunJob[] = [];
  return {
    jobs,
    engine: {
      async run(job): Promise<void> {
        jobs.push(job);
        await o.onRun?.(job);
        const row = fake.runRows.get(job.runId);
        if (row !== undefined && row.status === "running") row.status = "completed";
      },
      async cancel(): Promise<boolean> {
        return false;
      },
      activeRun() {
        return null;
      },
    },
  };
}

function fakeHooks(stops: HookStopResult[] = []): {
  hooks: HookEngine;
  stopCalls: Array<{ sessionId: string; payload: Record<string, unknown>; event?: string }>;
} {
  const stopCalls: Array<{
    sessionId: string;
    payload: Record<string, unknown>;
    event?: string;
  }> = [];
  const hooks: HookEngine = {
    async hasListeners() {
      return false;
    },
    async fire() {
      /* observe-only */
    },
    async fireDetailed() {
      return { output: "", systemMessages: [], promptBlockReason: null };
    },
    async fireGate() {
      return { decision: "allow" };
    },
    async fireStop(sessionId, payload, event) {
      stopCalls.push({ sessionId, payload, event });
      return stops.shift() ?? { veto: false };
    },
    sessionContextFor() {
      return "";
    },
    promptContextFor() {
      return null;
    },
  };
  return { hooks, stopCalls };
}

function fakeSinkFactory(): {
  sinkFactory: (sessionId: string) => {
    emit(type: string, payload: Record<string, unknown>): Promise<void>;
  };
  events: Array<{ sessionId: string; type: string; payload: Record<string, unknown> }>;
} {
  const events: Array<{
    sessionId: string;
    type: string;
    payload: Record<string, unknown>;
  }> = [];
  return {
    events,
    sinkFactory: (sessionId) => ({
      async emit(type, payload) {
        events.push({ sessionId, type, payload });
      },
    }),
  };
}

function spec(name: string): ToolSpec {
  return { name, description: name, parameters: { type: "object", properties: {} } };
}

const AVAILABLE: ToolSpec[] = [
  "file_read",
  "file_write",
  "fs_edit",
  "fs_grep",
  "run_shell",
  "job_start",
  "dispatch_agent",
  "workflow",
  "ralph",
  "ask_user_question",
  "send_message",
  "interrupt_agent",
  "list_agents",
  "report",
].map(spec);

function parentCtx(o: Partial<ToolContext> = {}): ToolContext {
  return {
    sessionId: "root",
    runId: "parent-run",
    userId: "u1",
    mode: "auto",
    planMode: false,
    isSubagent: false,
    depth: 0,
    unattended: false,
    callKey: "call-1",
    signal: new AbortController().signal,
    ...o,
  };
}

function build(o: {
  lineages?: Record<string, string[]>;
  onRun?: (job: AgentRunJob) => Promise<void> | void;
  stops?: HookStopResult[];
} = {}) {
  const fake = fakeStore(o.lineages);
  const { engine, jobs } = fakeEngine(fake, { onRun: o.onRun });
  const { hooks, stopCalls } = fakeHooks(o.stops);
  const { sinkFactory, events } = fakeSinkFactory();
  const state: SessionStateStore = createMemoryStateStore();
  const supervisor = createSubagentSupervisor({
    engine,
    db: {} as never,
    state,
    hooks,
    sinkFactory,
    registry: createToolRegistry(AVAILABLE.map((s) => ({
      spec: s,
      timeoutMs: 1000,
      async execute() {
        return { content: "" };
      },
    }))),
    store: fake.store,
  });
  return { fake, jobs, stopCalls, events, supervisor };
}

// ── waking a parent whose turn already ended ──────────────────────────────

describe("wakeParent", () => {
  function buildWithWake() {
    const fake = fakeStore();
    const { engine } = fakeEngine(fake, {
      onRun: (job) => {
        fake.setLastText(job.sessionId, "child done");
      },
    });
    const { hooks } = fakeHooks();
    const { sinkFactory } = fakeSinkFactory();
    const wakes: Array<{ sessionId: string; userId: string; text: string }> = [];
    const supervisor = createSubagentSupervisor({
      engine,
      db: {} as never,
      state: createMemoryStateStore(),
      hooks,
      sinkFactory,
      registry: createToolRegistry([]),
      store: fake.store,
      wakeParent: async (o) => {
        wakes.push(o);
      },
    });
    return { fake, supervisor, wakes };
  }

  it("wakes the parent when it has no run in flight", async () => {
    const { fake, supervisor, wakes } = buildWithWake();
    fake.setParentActive(false);

    const handle = await supervisor.dispatch(parentCtx(), { prompt: "audit" });
    await handle.settled;

    expect(wakes).toHaveLength(1);
    expect(wakes[0]!.sessionId).toBe("root");
    expect(wakes[0]!.userId).toBe("u1");
    expect(wakes[0]!.text).toContain("child done");
    expect(wakes[0]!.text).toContain("Background subagents you dispatched");
    expect(wakes[0]!.text).toContain("Do NOT dispatch these tasks again");
  });

  it("does not wake a parent that is still running — it reads the report itself", async () => {
    const { fake, supervisor, wakes } = buildWithWake();
    fake.setParentActive(true);

    const handle = await supervisor.dispatch(parentCtx(), { prompt: "audit" });
    await handle.settled;

    expect(wakes).toHaveLength(0);
    // The report is still durable, so nothing is lost.
    expect(fake.reports).toHaveLength(1);
  });

  it("three children settling together start ONE wake, not three", async () => {
    const fake = fakeStore();
    const jobs: AgentRunJob[] = [];
    const gates: Array<() => void> = [];
    const engine: AgentEngine = {
      async run(job): Promise<void> {
        jobs.push(job);
        await new Promise<void>((resolve) => gates.push(resolve));
        fake.setLastText(job.sessionId, "done");
        const row = fake.runRows.get(job.runId);
        if (row !== undefined && row.status === "running") row.status = "completed";
      },
      async cancel(): Promise<boolean> {
        return false;
      },
      activeRun() {
        return null;
      },
    };
    const { hooks } = fakeHooks();
    const { sinkFactory } = fakeSinkFactory();
    const wakes: string[] = [];
    const supervisor = createSubagentSupervisor({
      engine,
      db: {} as never,
      state: createMemoryStateStore(),
      hooks,
      sinkFactory,
      registry: createToolRegistry([]),
      store: fake.store,
      wakeParent: async (o) => {
        wakes.push(o.sessionId);
        // The wake starts a run, which is what the next attempt must see.
        fake.setParentActive(true);
      },
    });
    fake.setParentActive(false);

    const handles = [];
    for (let i = 0; i < 3; i += 1) {
      handles.push(await supervisor.dispatch(parentCtx(), { prompt: `task ${i}` }));
    }
    for (const release of gates) release();
    await Promise.all(handles.map((h) => h.settled));

    expect(wakes).toHaveLength(1);
  });

  it("a failing wake never fails the child", async () => {
    const fake = fakeStore();
    const { engine } = fakeEngine(fake);
    const { hooks } = fakeHooks();
    const { sinkFactory } = fakeSinkFactory();
    const supervisor = createSubagentSupervisor({
      engine,
      db: {} as never,
      state: createMemoryStateStore(),
      hooks,
      sinkFactory,
      registry: createToolRegistry([]),
      store: fake.store,
      wakeParent: async () => {
        throw new Error("queue down");
      },
    });

    const handle = await supervisor.dispatch(parentCtx(), { prompt: "x" });
    expect(await handle.settled).toBe("completed");
    expect(fake.reports).toHaveLength(1);
  });
});

// ── the summary budget depends on the outcome ─────────────────────────────

describe("buildChildSummary", () => {
  const long = (n: number): string => "word ".repeat(Math.ceil(n / 5)).slice(0, n);

  it("a completed child gets the small budget", () => {
    const summary = buildChildSummary({
      status: "completed",
      answer: long(5_000),
      error: null,
    });
    expect(summary.length).toBeLessThanOrEqual(REPORT_SUMMARY_LIMIT + 1);
    expect(summary.endsWith("…")).toBe(true);
  });

  it("a failed child gets the larger budget", () => {
    const summary = buildChildSummary({
      status: "failed",
      answer: long(5_000),
      error: "litellm 500",
    });
    // Bigger than a success summary, and still bounded.
    expect(summary.length).toBeGreaterThan(REPORT_SUMMARY_LIMIT);
    expect(summary.length).toBeLessThanOrEqual(REPORT_FAILURE_LIMIT + 120);
  });

  it("the reason leads, so a long partial answer cannot bury it", () => {
    const summary = buildChildSummary({
      status: "failed",
      answer: long(3_000),
      error: "context_length_exceeded",
    });
    expect(summary.startsWith("Failed: context_length_exceeded")).toBe(true);
    expect(summary).toContain("Last output before it ended:");
  });

  it("a cancelled child says it was stopped, not that it failed", () => {
    const summary = buildChildSummary({
      status: "cancelled",
      answer: "half done",
      error: null,
    });
    expect(summary.startsWith("Stopped before finishing.")).toBe(true);
    expect(summary).toContain("half done");
  });

  it("a failure with no message still says something useful", () => {
    expect(
      buildChildSummary({ status: "failed", answer: null, error: null }),
    ).toBe("Failed without an error message.");
  });

  it("a failure with no output is just the reason", () => {
    expect(
      buildChildSummary({ status: "failed", answer: null, error: "oom" }),
    ).toBe("Failed: oom");
  });

  it("a completed child with no answer stays empty (the formatter says so)", () => {
    expect(
      buildChildSummary({ status: "completed", answer: null, error: null }),
    ).toBe("");
  });
});

// ── the parent's inbox ─────────────────────────────────────────────────────

describe("pending subagent reports", () => {
  const report = (over: Partial<SubagentReport> = {}): SubagentReport => ({
    childSessionId: "child-1",
    childRunId: "run-1",
    agentType: "general-purpose",
    status: "completed",
    summary: "did the thing",
    task: "do the thing",
    at: 1,
    ...over,
  });

  it("reads the reports once and clears them", async () => {
    const state = createMemoryStateStore();
    await state.patch("root", {
      [PENDING_SUBAGENT_REPORTS_KEY]: [report()],
    } as never);

    const first = await takePendingSubagentReports(state, "root");
    expect(first).toHaveLength(1);
    expect(first[0]!.summary).toBe("did the thing");

    // Second read is empty: a report must not repeat on every request.
    expect(await takePendingSubagentReports(state, "root")).toEqual([]);
  });

  it("an unread inbox is empty, not an error", async () => {
    expect(await takePendingSubagentReports(createMemoryStateStore(), "root")).toEqual([]);
  });

  it("the system block names each child, its status and its task", () => {
    const text = formatSubagentReports([
      report(),
      report({ childSessionId: "child-2", status: "failed", summary: "boom", task: "other" }),
    ]);
    expect(text).toContain("child-1");
    expect(text).toContain("completed");
    expect(text).toContain("did the thing");
    expect(text).toContain("task: do the thing");
    expect(text).toContain("child-2");
    expect(text).toContain("failed");
    expect(text).toContain("boom");
  });

  it("an empty summary says so instead of leaving a blank", () => {
    const text = formatSubagentReports([report({ summary: "" })]);
    expect(text).toContain("finished without a final answer");
  });
});

// ── non-blocking dispatch (concurrency) ────────────────────────────────────

describe("dispatch does not block", () => {
  /**
   * A gated engine: each child parks inside run() until the test releases it,
   * which is the only way to observe two children alive at the same moment.
   */
  function gatedBuild() {
    const fake = fakeStore();
    const jobs: AgentRunJob[] = [];
    const gates: Array<() => void> = [];
    const started: Array<() => void> = [];
    const startedP = (n: number): Promise<void> =>
      new Promise((resolve) => {
        if (jobs.length >= n) resolve();
        else started.push(() => { if (jobs.length >= n) resolve(); });
      });
    const engine: AgentEngine = {
      async run(job): Promise<void> {
        jobs.push(job);
        for (const fire of started.splice(0)) fire();
        await new Promise<void>((resolve) => gates.push(resolve));
        const row = fake.runRows.get(job.runId);
        if (row !== undefined && row.status === "running") row.status = "completed";
        fake.setLastText(job.sessionId, `answer for ${job.sessionId}`);
      },
      async cancel(): Promise<boolean> {
        return false;
      },
      activeRun() {
        return null;
      },
    };
    const { hooks } = fakeHooks();
    const { sinkFactory, events } = fakeSinkFactory();
    const supervisor = createSubagentSupervisor({
      engine,
      db: {} as never,
      state: createMemoryStateStore(),
      hooks,
      sinkFactory,
      registry: createToolRegistry(AVAILABLE.map((s) => ({
        spec: s,
        timeoutMs: 1000,
        async execute() {
          return { content: "" };
        },
      }))),
      store: fake.store,
    });
    return { fake, jobs, gates, supervisor, startedP, events };
  }

  it("three dispatches are all running at the same time", async () => {
    const { supervisor, gates, startedP } = gatedBuild();
    const a = await supervisor.dispatch(parentCtx(), { prompt: "one" });
    const b = await supervisor.dispatch(parentCtx(), { prompt: "two" });
    const c = await supervisor.dispatch(parentCtx(), { prompt: "three" });

    // dispatch returned before any child finished — that is the contract.
    expect(a.status()).toBe("running");
    expect(b.status()).toBe("running");
    expect(c.status()).toBe("running");

    await startedP(3);
    // All three are inside run() simultaneously, not queued behind each other.
    expect(a.status()).toBe("running");
    expect(b.status()).toBe("running");
    expect(c.status()).toBe("running");

    for (const release of gates) release();
    expect(await Promise.all([a.settled, b.settled, c.settled])).toEqual([
      "completed",
      "completed",
      "completed",
    ]);
  });

  it("the 51st concurrent dispatch is refused, and a settled one frees a slot", async () => {
    const { supervisor, gates } = gatedBuild();
    const handles = [];
    for (let i = 0; i < 50; i += 1) {
      handles.push(await supervisor.dispatch(parentCtx(), { prompt: `task ${i}` }));
    }
    expect(handles).toHaveLength(50);

    await expect(
      supervisor.dispatch(parentCtx(), { prompt: "one too many" }),
    ).rejects.toThrow(/ceiling/);

    // Free exactly one slot and the next dispatch is accepted.
    gates[0]!();
    await handles[0]!.settled;
    const next = await supervisor.dispatch(parentCtx(), { prompt: "after one" });
    expect(next.status()).toBe("running");

    for (const release of gates) release();
  });
});

// ── the report the parent reads ────────────────────────────────────────────

describe("a settled child leaves a report for its parent", () => {
  it("records the bounded summary, the status and the task", async () => {
    const { fake, supervisor } = build({
      onRun: (job) => {
        fake.setLastText(job.sessionId, "  the answer  ");
      },
    });
    const handle = await supervisor.dispatch(parentCtx(), { prompt: "do it" });
    await handle.settled;

    expect(fake.reports).toHaveLength(1);
    const report = fake.reports[0]!;
    expect(report.parentSessionId).toBe("root");
    expect(report.report.status).toBe("completed");
    expect(report.report.summary).toBe("the answer");
    expect(report.report.task).toBe("do it");
    expect(report.report.childSessionId).toBe(handle.sessionId);
  });

  it("a failed child's report carries the run's error", async () => {
    const fake = fakeStore();
    const { engine } = fakeEngine(fake, {
      onRun: (job) => {
        fake.setLastText(job.sessionId, "partial work before the crash");
      },
    });
    // Fail the child's run the way the engine would: terminal status + reason.
    const failing: AgentEngine = {
      async run(job) {
        await engine.run(job);
        const row = fake.runRows.get(job.runId);
        if (row !== undefined) row.status = "failed";
        fake.runErrors.set(job.runId, "provider returned 500");
      },
      cancel: engine.cancel,
      activeRun: engine.activeRun,
    };
    const { hooks } = fakeHooks();
    const { sinkFactory } = fakeSinkFactory();
    const supervisor = createSubagentSupervisor({
      engine: failing,
      db: {} as never,
      state: createMemoryStateStore(),
      hooks,
      sinkFactory,
      registry: createToolRegistry([]),
      store: fake.store,
    });

    const handle = await supervisor.dispatch(parentCtx(), { prompt: "risky" });
    expect(await handle.settled).toBe("failed");

    const report = fake.reports[0]!.report;
    expect(report.status).toBe("failed");
    expect(report.summary).toContain("provider returned 500");
    expect(report.summary).toContain("partial work before the crash");
  });

  it("a report is never the raw log — it is clipped", async () => {
    const long = "x".repeat(5_000);
    const { fake, supervisor } = build({
      onRun: (job) => {
        fake.setLastText(job.sessionId, long);
      },
    });
    const handle = await supervisor.dispatch(parentCtx(), { prompt: "long" });
    await handle.settled;
    const summary = fake.reports[0]!.report.summary;
    expect(summary.length).toBeLessThanOrEqual(1_201);
    expect(summary.endsWith("…")).toBe(true);
  });
});

// ── SubagentToolPolicy (subagent_tools.dart:25–136) ────────────────────────

describe("subagentToolPolicy", () => {
  it("expands CC names eagerly and keeps MCP/prefix patterns", () => {
    const policy = subagentToolPolicy(["!Bash", "Edit", "mcp__srv__*", "Grep(x*)"]);
    expect(policy.deny).toEqual(
      expect.arrayContaining(["run_shell", "job_start", "job_output", "job_list", "job_kill"]),
    );
    expect(policy.allow).toEqual(
      expect.arrayContaining(["fs_edit", "mcp__srv__*", "fs_grep"]),
    );
    // Eager projection: no raw CC names leak through.
    expect(policy.deny).not.toContain("Bash");
    expect(policy.allow).not.toContain("Edit");
  });

  it("encodes dispatch args as the stored !-prefixed list", () => {
    expect(
      storedSubagentTools({ tools: ["Read"], disallowedTools: ["Bash(git push *)"] }),
    ).toEqual(["Read", "!Bash(git push *)"]);
  });

  it("always denies spawn and user-facing tools even when listed", () => {
    const policy = subagentToolPolicy(["dispatch_agent", "workflow", "ralph", "ask_user_question"]);
    for (const name of ["dispatch_agent", "workflow", "ralph", "ask_user_question"]) {
      expect(subagentPolicyAllows(name, policy)).toBe(false);
      expect(CHILD_DENIED_TOOLS.has(name)).toBe(true);
    }
  });

  it("a disallowedTools specifier scopes the WHOLE CC tool", () => {
    const policy = subagentToolPolicy(["!Bash(git push *)"]);
    expect(subagentPolicyAllows("run_shell", policy)).toBe(false);
    expect(subagentPolicyAllows("file_read", policy)).toBe(true);
  });
});

describe("projectChildRoster", () => {
  it("tools:['Read'] keeps only the Read family and never the spawn tools", () => {
    const policy = subagentToolPolicy(["Read"]);
    const names = projectChildRoster(AVAILABLE, policy).map((t) => t.name);
    expect(names).toContain("file_read");
    expect(names).not.toContain("run_shell");
    expect(names).not.toContain("file_write");
    expect(names).not.toContain("dispatch_agent");
  });

  it("an omitted tools list inherits everything except spawn/user-facing tools", () => {
    const policy = subagentToolPolicy([]);
    const names = projectChildRoster(AVAILABLE, policy).map((t) => t.name);
    expect(names).toEqual(
      expect.arrayContaining(["run_shell", "file_read", "fs_edit"]),
    );
    for (const denied of ["dispatch_agent", "workflow", "ralph", "ask_user_question"]) {
      expect(names).not.toContain(denied);
    }
    // Management tools deliberately stay (ceiling test :148).
    expect(names).toEqual(
      expect.arrayContaining(["send_message", "list_agents", "interrupt_agent", "report"]),
    );
  });
});

// ── dispatch: creation, events, roster, result ─────────────────────────────

describe("createSubagentSupervisor.dispatch", () => {
  it("creates a child session + run, emits started→completed, and returns the answer", async () => {
    const { fake, jobs, events, supervisor } = build({
      onRun: (job) => {
        fake.setLastText(job.sessionId, "the answer");
      },
    });

    const handle = await supervisor.dispatch(parentCtx(), {
      prompt: "do the thing",
      tools: ["Read"],
    });
    // Non-blocking contract: dispatch returns while the child runs.
    expect(handle.status()).toBe("running");
    await handle.settled;

    expect(fake.childCreates).toBe(1);
    expect(handle.sessionId).toBe("child-1");
    expect(handle.status()).toBe("completed");
    expect(handle.result()).toBe("the answer");

    // The child run is a real in-process engine run at depth+1.
    expect(jobs).toHaveLength(1);
    const job = jobs[0]!;
    expect(job.isSubagent).toBe(true);
    expect(job.depth).toBe(1);
    expect(job.subagentBriefing).toBe("do the thing");
    expect(job.prompt).toBe("do the thing");
    const rosterNames = (job.roster ?? []).map((t) => t.name);
    expect(rosterNames).toContain("file_read");
    expect(rosterNames).not.toContain("dispatch_agent");
    expect(rosterNames).not.toContain("run_shell");

    // Emission order is pinned (plan Step 1).
    const types = events.map((e) => e.type);
    expect(types).toEqual(["subagent_started", "subagent_completed"]);
    expect(events[0]!.payload).toMatchObject({
      runId: "parent-run",
      childSessionId: "child-1",
      childRunId: handle.runId,
      prompt: "do the thing",
    });
    expect(events[1]!.payload).toMatchObject({
      childRunId: handle.runId,
      status: "completed",
    });
    expect(events.every((e) => e.sessionId === "root")).toBe(true);
  });

  it("an omitted tools list inherits the parent roster minus the denied set", async () => {
    const { jobs, supervisor } = build();
    await supervisor.dispatch(parentCtx(), { prompt: "inherit" });
    const names = (jobs[0]!.roster ?? []).map((t) => t.name);
    expect(names).toEqual(
      expect.arrayContaining(["run_shell", "file_read", "fs_edit", "send_message", "report"]),
    );
    expect(names).not.toContain("dispatch_agent");
  });

  it("rejects an empty prompt", async () => {
    const { supervisor } = build();
    await expect(supervisor.dispatch(parentCtx(), { prompt: "   " })).rejects.toThrow(
      "prompt is required",
    );
  });

  it("refuses to start a child when the parent is already cancelled", async () => {
    const { fake, supervisor } = build();
    const controller = new AbortController();
    controller.abort();
    await expect(
      supervisor.dispatch(parentCtx({ signal: controller.signal }), { prompt: "too late" }),
    ).rejects.toThrow("parent run is cancelled");
    expect(fake.childCreates).toBe(0);
  });
});

// ── B20 refusal precedence ─────────────────────────────────────────────────

describe("refusal precedence (B20: lineage depth FIRST)", () => {
  it("a fabricated two-deep lineage hits the depth limit and creates nothing", async () => {
    const { fake, supervisor } = build({
      lineages: { grandchild: ["root", "child", "grandchild"] },
    });
    await expect(
      supervisor.dispatch(
        parentCtx({ sessionId: "grandchild", isSubagent: true, depth: 2 }),
        { prompt: "third level" },
      ),
    ).rejects.toThrow("Subagent depth limit (2) reached — do the task yourself");
    expect(fake.childCreates).toBe(0);
  });

  it("a depth-1 child gets the layer-3 refusal, NOT the depth message", async () => {
    const { fake, supervisor } = build({ lineages: { child: ["root", "child"] } });
    let message = "";
    try {
      await supervisor.dispatch(
        parentCtx({ sessionId: "child", isSubagent: true, depth: 1 }),
        { prompt: "nested" },
      );
    } catch (err) {
      message = err instanceof Error ? err.message : String(err);
    }
    expect(message).toContain("SUBAGENT: a subagent cannot dispatch subagents");
    expect(message).not.toContain("depth limit");
    expect(fake.childCreates).toBe(0);
  });

  it("the depth check wins when BOTH rules match (depth 2 + isSubagent)", async () => {
    const { supervisor } = build({
      lineages: { grandchild: ["root", "child", "grandchild"] },
    });
    let message = "";
    try {
      await supervisor.dispatch(
        parentCtx({ sessionId: "grandchild", isSubagent: true, depth: 2 }),
        { prompt: "nested" },
      );
    } catch (err) {
      message = err instanceof Error ? err.message : String(err);
    }
    expect(message).toContain("Subagent depth limit (2) reached");
    expect(message).not.toContain("cannot dispatch subagents");
  });
});

// ── SubagentStop gate ──────────────────────────────────────────────────────

describe("SubagentStop gate", () => {
  it("blocks re-enter the child exactly MAX_SUBAGENT_STOP_BLOCKS times, then stop", async () => {
    const { jobs, stopCalls, events, supervisor } = build({
      stops: Array.from({ length: 4 }, () => ({
        veto: true as const,
        reason: "continue checking",
        vetoedByPlugin: "test",
      })),
    });

    const handle = await supervisor.dispatch(parentCtx(), { prompt: "initial" });
    await handle.settled;

    expect(jobs).toHaveLength(1 + MAX_SUBAGENT_STOP_BLOCKS);
    expect(stopCalls).toHaveLength(1 + MAX_SUBAGENT_STOP_BLOCKS);
    expect(stopCalls.every((c) => c.event === "subagent_stop")).toBe(true);
    // Every re-entry carries the hook's reason as the next instruction.
    expect(jobs.slice(1).map((j) => j.prompt)).toEqual([
      "continue checking",
      "continue checking",
      "continue checking",
    ]);
    // stop_hook_active is false on the first gate, true afterwards.
    expect(stopCalls[0]!.payload["stop_hook_active"]).toBe(false);
    expect(stopCalls[1]!.payload["stop_hook_active"]).toBe(true);
    expect(handle.status()).toBe("completed");
    expect(events.filter((e) => e.type === "subagent_completed")).toHaveLength(1);
  });

  it("exit 0 (no veto) settles after one run", async () => {
    const { jobs, stopCalls, supervisor } = build({ stops: [{ veto: false }] });
    const handle = await supervisor.dispatch(parentCtx(), { prompt: "once" });
    await handle.settled;
    expect(jobs).toHaveLength(1);
    expect(stopCalls).toHaveLength(1);
  });

  it("a throwing hook fails open and never wedges the child", async () => {
    const fake = fakeStore();
    const { engine } = fakeEngine(fake);
    const { sinkFactory } = fakeSinkFactory();
    const hooks = {
      async hasListeners() { return false; },
      async fire() {},
      async fireDetailed() { return { output: "", systemMessages: [], promptBlockReason: null }; },
      async fireGate() { return { decision: "allow" as const }; },
      async fireStop() { throw new Error("broken hook"); },
      sessionContextFor() { return ""; },
      promptContextFor() { return null; },
    } as unknown as HookEngine;
    const supervisor = createSubagentSupervisor({
      engine,
      db: {} as never,
      state: createMemoryStateStore(),
      hooks,
      sinkFactory,
      registry: createToolRegistry([]),
      store: fake.store,
    });
    const handle = await supervisor.dispatch(parentCtx(), { prompt: "x" });
    await handle.settled;
    expect(handle.status()).toBe("completed");
  });
});

// ── cancellation cascade ───────────────────────────────────────────────────

describe("parent cancel cascades", () => {
  it("aborting the parent signal cancels the child run", async () => {
    const fake = fakeStore();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let started!: () => void;
    const startedP = new Promise<void>((resolve) => {
      started = resolve;
    });
    let cancelCalls = 0;
    const jobs: AgentRunJob[] = [];
    const engine: AgentEngine = {
      async run(job) {
        jobs.push(job);
        started();
        await gate;
        const row = fake.runRows.get(job.runId);
        if (row !== undefined) row.status = "cancelled";
      },
      async cancel() {
        cancelCalls += 1;
        release();
        return true;
      },
      activeRun() {
        return null;
      },
    };
    const { hooks } = fakeHooks();
    const { sinkFactory } = fakeSinkFactory();
    const supervisor = createSubagentSupervisor({
      engine,
      db: {} as never,
      state: createMemoryStateStore(),
      hooks,
      sinkFactory,
      registry: createToolRegistry([]),
      store: fake.store,
    });
    const controller = new AbortController();
    const pending = supervisor.dispatch(
      parentCtx({ signal: controller.signal }),
      { prompt: "long task" },
    );
    await startedP;
    controller.abort();
    const handle = await pending;
    expect(cancelCalls).toBeGreaterThan(0);
    // The cascade is asynchronous now: the child's loop observes the abort and
    // settles as cancelled, so the handle's own promise is the signal.
    expect(await handle.settled).toBe("cancelled");
    expect(handle.status()).toBe("cancelled");
  });
});

// ── follow-up inbox (send_message) ─────────────────────────────────────────

describe("follow-up turns", () => {
  it("a message queued during the final stop hook is consumed before settlement", async () => {
    const fake = fakeStore();
    let firstRun = true;
    const { engine, jobs } = fakeEngine(fake, {
      onRun: async (job) => {
        fake.setLastText(job.sessionId, `answer:${job.prompt}`);
        if (firstRun) {
          firstRun = false;
          // Simulate a send_message that landed after the loop's last drain:
          // a queued run with its prompt row already persisted.
          const msg = await fake.store.appendUserMessage(job.sessionId, "during-stop");
          await fake.store.createRun({
            sessionId: job.sessionId,
            promptMessageId: msg.messageId,
          });
        }
      },
    });
    const { hooks } = fakeHooks([{ veto: false }]);
    const { sinkFactory } = fakeSinkFactory();
    const supervisor = createSubagentSupervisor({
      engine,
      db: {} as never,
      state: createMemoryStateStore(),
      hooks,
      sinkFactory,
      registry: createToolRegistry([]),
      store: fake.store,
    });
    const handle = await supervisor.dispatch(parentCtx(), { prompt: "initial" });
    await handle.settled;
    expect(jobs.map((j) => j.prompt)).toEqual(["initial", "during-stop"]);
    expect(handle.result()).toBe("answer:during-stop");
  });
});

// ── real Postgres (TEST_DATABASE_URL) ──────────────────────────────────────

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL)("createSubagentSupervisor (real postgres)", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  });

  afterAll(async () => {
    await db.$client.end({ timeout: 5 });
  });

  it("persists the durable parent link and settles the child run", async () => {
    const uid = `u-${randomUUID()}`;
    await users.ensure(db, uid, null);
    const root = await sessions.create(db, uid, "root");

    const childJobs: Array<Record<string, unknown>> = [];
    const engine: AgentEngine = {
      async run(job): Promise<void> {
        childJobs.push(job as unknown as Record<string, unknown>);
        await messages.append(db, {
          sessionId: job.sessionId,
          role: "assistant",
          content: "real answer",
        });
        await runs.finish(db, job.runId, "completed");
      },
      async cancel(): Promise<boolean> {
        return false;
      },
      activeRun() {
        return null;
      },
    };
    const { hooks } = fakeHooks([{ veto: false }]);
    const { sinkFactory, events } = fakeSinkFactory();
    const supervisor = createSubagentSupervisor({
      engine,
      db,
      state: createPostgresSessionStateStore(db),
      hooks,
      sinkFactory,
      registry: createToolRegistry([]),
    });

    const handle = await supervisor.dispatch(
      parentCtx({ sessionId: root.id, userId: uid }),
      { prompt: "real task", agentType: "CodeSubagent" },
    );

    expect(handle.status()).toBe("completed");
    // Wave 1b: the card names the agent, and the child never inherits the
    // parent's @-tag context (R1) — only the dispatch prompt crosses.
    expect(events[0]!.payload).toMatchObject({ agentType: "CodeSubagent", childSessionId: handle.sessionId });
    expect(childJobs[0]).not.toHaveProperty("turnContext");
    expect(childJobs[0]).not.toHaveProperty("sessionRefs");
    expect(handle.result()).toBe("real answer");
    expect(await sessions.get(db, handle.sessionId, uid)).not.toBeNull();
    // Durable lineage: root → child (the JSONB parent-link seam).
    expect(await createDbSubagentStore(db).lineage(handle.sessionId)).toEqual([
      root.id,
      handle.sessionId,
    ]);
    expect(events.map((e) => e.type)).toEqual(["subagent_started", "subagent_completed"]);
  });
});
