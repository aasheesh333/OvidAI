// Subagents (P3 Task 20) — policy, depth precedence, child loop, stop gate,
// cancellation cascade, events. Port targets: claude_code_subagent_parity
// (roster projection, spawn refusal), subagent_ceiling (management tools stay,
// spawn tools never advertise), p2_subagent_races (FIFO/stop/cancel), and the
// plan's own Step-1 list.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
  MAX_SUBAGENT_STOP_BLOCKS,
  projectChildRoster,
  storedSubagentTools,
  subagentPolicyAllows,
  subagentToolPolicy,
  type RunStatus,
  type SubagentStore,
  type ChildHandle,
} from "./subagents.js";
import { parseSubagentSummary } from "./subagentSummary.js";
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
  };

  return {
    store,
    sessionsById,
    runRows,
    lastText,
    setLastText(sessionId: string, text: string | null): void {
      lastText.set(sessionId, text);
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
  "read_subagent_log",
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
    logDir: mkdtempSync(join(tmpdir(), "ovid-subagent-")),
  });
  return { fake, jobs, stopCalls, events, supervisor };
}

// ── SubagentToolPolicy (subagent_tools.dart:25–136) ────────────────────────

function summaryOf(handle: ChildHandle) {
  const parsed = parseSubagentSummary(handle.result() ?? "");
  if (!parsed.ok) throw new Error(`not a strict summary: ${parsed.error}`);
  return parsed.summary;
}

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
    // Main-agent-only tools never reach a child roster.
    expect(names).not.toContain("read_subagent_log");
  });

  it("read_subagent_log stays denied even when the policy explicitly allows it", () => {
    const policy = subagentToolPolicy(["read_subagent_log", "*"]);
    expect(subagentPolicyAllows("read_subagent_log", policy)).toBe(false);
    const names = projectChildRoster(AVAILABLE, policy).map((t) => t.name);
    expect(names).not.toContain("read_subagent_log");
    expect(names).toContain("file_read");
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

    expect(fake.childCreates).toBe(1);
    expect(handle.sessionId).toBe("child-1");
    expect(handle.status()).toBe("completed");
    expect(summaryOf(handle)).toMatchObject({
      status: "completed",
      files_modified: [],
      artifacts_created: [],
      key_findings: ["the answer"],
      error_if_any: null,
    });

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
    await supervisor.dispatch(parentCtx(), { prompt: "once" });
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
    expect(jobs.map((j) => j.prompt)).toEqual(["initial", "during-stop"]);
    expect(summaryOf(handle).key_findings).toEqual(["answer:during-stop"]);
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
      logDir: mkdtempSync(join(tmpdir(), "ovid-subagent-pg-")),
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
    expect(summaryOf(handle).key_findings).toEqual(["real answer"]);
    expect(await sessions.get(db, handle.sessionId, uid)).not.toBeNull();
    // Durable lineage: root → child (the JSONB parent-link seam).
    expect(await createDbSubagentStore(db).lineage(handle.sessionId)).toEqual([
      root.id,
      handle.sessionId,
    ]);
    expect(events.map((e) => e.type)).toEqual(["subagent_started", "subagent_completed"]);
  });
});
