// SI spec §9 / plan Task 8.10 — the subagent CONTRACT.
//
// These tests pin the externally-visible promises of the cloud runtime:
//  • 50 active subagents per root, the 51st refused with a typed error;
//  • no nested subagents (roster + runtime, with depth/lineage backstops);
//  • an append-only full log at `<logDir>/subagent_{id}.log`;
//  • a strict five-key JSON result held to 300 tokens, truncated
//    deterministically with a marker;
//  • an 8-hour (configurable) cap that stops the run, reports `timeout` and
//    RELEASES the slot.

import { describe, expect, it } from "vitest";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { AgentEngine } from "./engine.js";
import type { AgentRunJob } from "./loop.js";
import type { HookEngine, SessionStateStore } from "./ports.js";
import { createMemoryStateStore } from "./ports.js";
import {
  createSubagentSupervisor,
  DEFAULT_SUBAGENT_MAX_RUNTIME_MS,
  MAX_SUBAGENTS_PER_ROOT,
  SubagentLimitError,
  SubagentNestedError,
  type RunStatus,
  type SubagentStore,
} from "./subagents.js";
import {
  createSubagentLog,
  subagentLogPath,
  SubagentLogPathError,
} from "./subagentLog.js";
import {
  buildSubagentSummary,
  enforceSubagentTokenBudget,
  parseSubagentSummary,
  serializeSubagentSummary,
  SUBAGENT_SUMMARY_KEYS,
  SUBAGENT_SUMMARY_TOKEN_BUDGET,
  SUBAGENT_TRUNCATION_MARKER,
  summaryTokens,
  validateSubagentSummary,
  type SubagentSummary,
} from "./subagentSummary.js";
import type { ToolContext } from "./types.js";
import { createToolRegistry } from "./types.js";

// ── fakes (in-memory, no Postgres/Redis) ───────────────────────────────────

interface FakeRun {
  id: string;
  sessionId: string;
  promptMessageId: string | null;
  status: RunStatus;
}

function fakeStore(lineages: Record<string, string[]> = {}) {
  let seq = 0;
  const runsById = new Map<string, FakeRun>();
  const messagesById = new Map<string, string>();
  const lastText = new Map<string, string | null>();
  let childCreates = 0;

  const store: SubagentStore = {
    async createChild(o) {
      childCreates += 1;
      const id = `child-${++seq}`;
      messagesById.set(`parent-of-${id}`, o.parentSessionId);
      return { sessionId: id };
    },
    async appendUserMessage(sessionId, content) {
      const id = `msg-${++seq}`;
      messagesById.set(id, content);
      return { messageId: id };
    },
    async createRun(o) {
      const id = `run-${++seq}`;
      runsById.set(id, {
        id,
        sessionId: o.sessionId,
        promptMessageId: o.promptMessageId,
        status: "queued",
      });
      return { runId: id };
    },
    async claimRun(runId) {
      const row = runsById.get(runId);
      if (row === undefined || row.status !== "queued") return false;
      row.status = "running";
      return true;
    },
    async runStatus(runId) {
      return runsById.get(runId)?.status ?? null;
    },
    async queuedRuns(sessionId) {
      return [...runsById.values()]
        .filter((r) => r.sessionId === sessionId && r.status === "queued")
        .map((r) => ({ runId: r.id, promptMessageId: r.promptMessageId }));
    },
    async promptText(messageId) {
      return messagesById.get(messageId) ?? null;
    },
    async lastAssistantText(sessionId) {
      return lastText.get(sessionId) ?? null;
    },
    async lineage(sessionId) {
      return lineages[sessionId] ?? [sessionId];
    },
    async listChildren() {
      return [];
    },
  };

  return {
    store,
    runsById,
    lastText,
    setLastText(sessionId: string, text: string | null): void {
      lastText.set(sessionId, text);
    },
    get childCreates(): number {
      return childCreates;
    },
  };
}

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

function fakeHooks(): HookEngine {
  return {
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
}

function sinkFactory() {
  const events: Array<{ sessionId: string; type: string; payload: Record<string, unknown> }> = [];
  return {
    events,
    factory: (sessionId: string) => ({
      async emit(type: string, payload: Record<string, unknown>) {
        events.push({ sessionId, type, payload });
      },
    }),
  };
}

function logDir(): string {
  return mkdtempSync(join(tmpdir(), "ovid-subagent-contract-"));
}

function build(o: {
  fake?: ReturnType<typeof fakeStore>;
  lineages?: Record<string, string[]>;
  engine: AgentEngine;
  state?: SessionStateStore;
  maxRuntimeMs?: number;
  maxSubagents?: number;
  dir?: string;
}) {
  const fake = o.fake ?? fakeStore(o.lineages);
  const sink = sinkFactory();
  const supervisor = createSubagentSupervisor({
    engine: o.engine,
    db: {} as never,
    state: o.state ?? createMemoryStateStore(),
    hooks: fakeHooks(),
    sinkFactory: sink.factory,
    registry: createToolRegistry([]),
    store: fake.store,
    maxRuntimeMs: o.maxRuntimeMs,
    maxSubagents: o.maxSubagents,
    logDir: o.dir ?? logDir(),
  });
  return { fake, supervisor, events: sink.events };
}

function completingEngine(
  fake: ReturnType<typeof fakeStore>,
  onRun?: (job: AgentRunJob) => Promise<void> | void,
): AgentEngine {
  return {
    async run(job) {
      await onRun?.(job);
      const row = fake.runsById.get(job.runId);
      if (row !== undefined && row.status === "running") row.status = "completed";
    },
    async cancel() {
      return false;
    },
    activeRun() {
      return null;
    },
  };
}

// ── 1. 50 active per root, 51st refused with a typed error ─────────────────

describe("subagent ceiling (SI spec §9: 50 per root)", () => {
  it("allows 50 concurrent children and rejects the 51st with SubagentLimitError", async () => {
    const fake = fakeStore();
    let started = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let fiftyStarted!: () => void;
    const allFifty = new Promise<void>((resolve) => {
      fiftyStarted = resolve;
    });

    const engine: AgentEngine = {
      async run(job) {
        started += 1;
        if (started === MAX_SUBAGENTS_PER_ROOT) fiftyStarted();
        await gate;
        const row = fake.runsById.get(job.runId);
        if (row !== undefined) row.status = "completed";
      },
      async cancel() {
        return true;
      },
      activeRun() {
        return null;
      },
    };

    const { supervisor } = build({ fake, engine });
    const dispatches = Array.from({ length: MAX_SUBAGENTS_PER_ROOT }, (_, i) =>
      supervisor.dispatch(parentCtx(), { prompt: `task ${i}` }),
    );
    await allFifty;

    // The 51st is a TYPED refusal, not a silent drop and not a hang.
    let refusal: unknown;
    try {
      await supervisor.dispatch(parentCtx(), { prompt: "task 51" });
    } catch (err) {
      refusal = err;
    }
    expect(refusal).toBeInstanceOf(SubagentLimitError);
    expect(refusal).toMatchObject({
      code: "subagent_limit_exceeded",
      rootSessionId: "root",
      limit: MAX_SUBAGENTS_PER_ROOT,
    });
    expect(fake.childCreates).toBe(MAX_SUBAGENTS_PER_ROOT);

    release();
    const handles = await Promise.all(dispatches);
    expect(handles.every((h) => h.status() === "completed")).toBe(true);

    // Slots are released on completion: the next dispatch is admitted.
    const after = await supervisor.dispatch(parentCtx(), { prompt: "after" });
    expect(after.status()).toBe("completed");
    expect(fake.childCreates).toBe(MAX_SUBAGENTS_PER_ROOT + 1);
  });

  it("counts per ROOT session: two roots each get their own ceiling", async () => {
    const fake = fakeStore();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let markStarted!: () => void;
    const started = new Promise<void>((resolve) => {
      markStarted = resolve;
    });
    const engine: AgentEngine = {
      async run(job) {
        markStarted();
        await gate;
        const row = fake.runsById.get(job.runId);
        if (row !== undefined) row.status = "completed";
      },
      async cancel() {
        return true;
      },
      activeRun() {
        return null;
      },
    };
    const { supervisor } = build({ fake, engine, maxSubagents: 1 });
    const first = supervisor.dispatch(parentCtx({ sessionId: "root-a" }), { prompt: "one" });
    await started;
    // A different root has its own slot even though the first is still active.
    const second = supervisor.dispatch(parentCtx({ sessionId: "root-b" }), { prompt: "two" });
    await expect(
      supervisor.dispatch(parentCtx({ sessionId: "root-a" }), { prompt: "three" }),
    ).rejects.toBeInstanceOf(SubagentLimitError);
    release();
    const handles = await Promise.all([first, second]);
    expect(handles.map((h) => h.status())).toEqual(["completed", "completed"]);
  });
});

// ── 2. no nested subagents ─────────────────────────────────────────────────

describe("no nested subagents (SI spec §9)", () => {
  it("a subagent run cannot dispatch another, even if the flag is missing", async () => {
    const fake = fakeStore();
    const { supervisor } = build({ fake, engine: completingEngine(fake) });

    let refusal: unknown;
    try {
      await supervisor.dispatch(
        parentCtx({ sessionId: "child", isSubagent: true, depth: 1 }),
        { prompt: "nested" },
      );
    } catch (err) {
      refusal = err;
    }
    expect(refusal).toBeInstanceOf(SubagentNestedError);
    expect(refusal).toMatchObject({ code: "subagent_nested" });
    expect(fake.childCreates).toBe(0);

    // Backstop: a depth-1 context with isSubagent=false is still a subagent.
    await expect(
      supervisor.dispatch(parentCtx({ sessionId: "child", isSubagent: false, depth: 1 }), {
        prompt: "nested",
      }),
    ).rejects.toBeInstanceOf(SubagentNestedError);

    // Lineage is the escape-proof backstop.
    const lineageFake = fakeStore({ child: ["root", "child"] });
    const { supervisor: byLineage } = build({
      fake: lineageFake,
      lineages: { child: ["root", "child"] },
      engine: completingEngine(lineageFake),
    });
    await expect(
      byLineage.dispatch(parentCtx({ sessionId: "child", depth: 0 }), { prompt: "nested" }),
    ).rejects.toBeInstanceOf(SubagentNestedError);
    expect(lineageFake.childCreates).toBe(0);
  });
});

// ── 3. append-only full log ────────────────────────────────────────────────

describe("subagent log (SI spec §9: /workspace/.ovid/logs/subagent_{id}.log)", () => {
  it("writes the full tool call + output trail at the contract path", async () => {
    const dir = logDir();
    const fake = fakeStore();
    const engine: AgentEngine = {
      async run(job) {
        await job.sink?.emit("tool_started", {
          runId: job.runId,
          callId: "call-1",
          name: "file_read",
          args: { path: "src/app.ts" },
        });
        await job.sink?.emit("tool_completed", {
          runId: job.runId,
          callId: "call-1",
          name: "file_read",
          ok: true,
          content: "export const answer = 42;\n",
        });
        await job.sink?.emit("message_completed", {
          runId: job.runId,
          content: "done reading",
        });
        fake.setLastText(job.sessionId, "done reading");
        const row = fake.runsById.get(job.runId);
        if (row !== undefined) row.status = "completed";
      },
      async cancel() {
        return false;
      },
      activeRun() {
        return null;
      },
    };
    const { supervisor } = build({ fake, engine, dir });
    const handle = await supervisor.dispatch(parentCtx(), { prompt: "read the app" });

    const path = subagentLogPath(handle.sessionId, dir);
    expect(path).toBe(join(dir, `subagent_${handle.sessionId}.log`));
    const lines = readFileSync(path, "utf8").trim().split("\n").map((line) => JSON.parse(line));
    expect(lines[0]).toMatchObject({
      type: "subagent_log_started",
      sessionId: handle.sessionId,
      parentSessionId: "root",
      prompt: "read the app",
    });
    expect(lines).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "tool_started",
          name: "file_read",
          args: { path: "src/app.ts" },
        }),
        expect.objectContaining({
          type: "tool_completed",
          name: "file_read",
          ok: true,
          content: "export const answer = 42;\n",
        }),
        expect.objectContaining({ type: "subagent_result", status: "completed" }),
      ]),
    );
  });

  it("is append-only: reopening the same id adds lines instead of truncating", async () => {
    const dir = join(logDir(), "nested", "logs");
    const first = await createSubagentLog({ sessionId: "child-1", dir, now: () => 1 });
    await first.append({ type: "marker", value: "first" });
    await first.close();

    const second = await createSubagentLog({ sessionId: "child-1", dir, now: () => 2 });
    await second.append({ type: "marker", value: "second" });
    await second.close();

    const lines = readFileSync(join(dir, "subagent_child-1.log"), "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    expect(lines.filter((l) => l.type === "subagent_log_started")).toHaveLength(2);
    expect(lines.filter((l) => l.type === "marker").map((l) => l.value)).toEqual([
      "first",
      "second",
    ]);
  });

  it("refuses an id that could escape the log directory", () => {
    const dir = logDir();
    expect(() => subagentLogPath("../evil", dir)).toThrow(SubagentLogPathError);
    expect(() => subagentLogPath("a/b", dir)).toThrow(SubagentLogPathError);
  });
});

// ── 4. strict JSON + hard 300-token budget ─────────────────────────────────

describe("subagent result contract (strict JSON, ≤300 tokens)", () => {
  it("validates EXACTLY the five keys", () => {
    const good = {
      status: "completed",
      files_modified: ["a.ts"],
      artifacts_created: [],
      key_findings: ["found it"],
      error_if_any: null,
    };
    expect(validateSubagentSummary(good)).toEqual({ ok: true, summary: good });
    expect(Object.keys(good)).toEqual([...SUBAGENT_SUMMARY_KEYS]);

    expect(validateSubagentSummary({ ...good, extra: 1 }).ok).toBe(false);
    const { key_findings: _omit, ...missing } = good;
    expect(validateSubagentSummary(missing).ok).toBe(false);
    expect(validateSubagentSummary({ ...good, status: "running" }).ok).toBe(false);
    expect(validateSubagentSummary({ ...good, files_modified: "a.ts" }).ok).toBe(false);
    expect(validateSubagentSummary({ ...good, error_if_any: 42 }).ok).toBe(false);
    expect(validateSubagentSummary(null).ok).toBe(false);
    expect(parseSubagentSummary("not json").ok).toBe(false);
  });

  it("truncates deterministically with a marker and stays ≤300 tokens", () => {
    const huge = buildSubagentSummary({
      status: "completed",
      text: "x".repeat(20_000),
      filesModified: Array.from({ length: 100 }, (_, i) => `src/very/long/path/file-${i}.ts`),
      artifactsCreated: Array.from({ length: 100 }, (_, i) => `artifact-${i}.bin`),
      error: "y".repeat(5_000),
    });

    expect(summaryTokens(huge)).toBeLessThanOrEqual(SUBAGENT_SUMMARY_TOKEN_BUDGET);
    expect(Object.keys(JSON.parse(serializeSubagentSummary(huge))).sort()).toEqual(
      [...SUBAGENT_SUMMARY_KEYS].sort(),
    );
    const serialized = serializeSubagentSummary(huge);
    expect(serialized).toContain(SUBAGENT_TRUNCATION_MARKER);
    // Same input → byte-identical output.
    expect(serializeSubagentSummary(enforceSubagentTokenBudget(huge))).toBe(serialized);

    const parsed = parseSubagentSummary(serialized);
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.summary.status).toBe("completed");
      expect(parsed.summary.key_findings.length).toBeGreaterThan(0);
    }
  });

  it("leaves a small summary untouched", () => {
    const summary = buildSubagentSummary({
      status: "completed",
      text: "short finding",
      filesModified: ["a.ts"],
    });
    expect(summary.key_findings).toEqual(["short finding"]);
    expect(summary.files_modified).toEqual(["a.ts"]);
    expect(serializeSubagentSummary(summary)).not.toContain(SUBAGENT_TRUNCATION_MARKER);
  });

  it("the supervisor's result is the strict JSON summary, not the transcript", async () => {
    const fake = fakeStore();
    const engine = completingEngine(fake, (job) => {
      fake.setLastText(job.sessionId, "z".repeat(10_000));
    });
    const { supervisor } = build({ fake, engine });
    const handle = await supervisor.dispatch(parentCtx(), { prompt: "long answer" });
    const text = handle.result() ?? "";
    expect(summaryTokens(JSON.parse(text) as SubagentSummary)).toBeLessThanOrEqual(300);
    const parsed = parseSubagentSummary(text);
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.summary.status).toBe("completed");
      expect(serializeSubagentSummary(parsed.summary).length).toBeLessThan(10_000);
    }
  });
});

// ── 5. 8-hour cap stops the run, reports timeout, releases the slot ────────

describe("subagent runtime cap (SI spec §9: 8 h)", () => {
  it("defaults to 8 hours", () => {
    expect(DEFAULT_SUBAGENT_MAX_RUNTIME_MS).toBe(8 * 60 * 60 * 1000);
  });

  it("on expiry: stops the run, writes status timeout, releases the slot", async () => {
    const dir = logDir();
    const fake = fakeStore();
    let cancelCalls = 0;
    let runs = 0;
    const engine: AgentEngine = {
      async run(job) {
        runs += 1;
        if (runs === 1) {
          // A stuck child: the deadline, not the loop, must end this dispatch.
          return new Promise<void>(() => {});
        }
        fake.setLastText(job.sessionId, "second answer");
        const row = fake.runsById.get(job.runId);
        if (row !== undefined) row.status = "completed";
      },
      async cancel() {
        cancelCalls += 1;
        return true;
      },
      activeRun() {
        return null;
      },
    };

    // maxSubagents: 1 makes slot release observable: if the timed-out child
    // kept its slot, the second dispatch would be refused.
    const { supervisor } = build({ fake, engine, maxRuntimeMs: 25, maxSubagents: 1, dir });

    const started = Date.now();
    const timedOut = await supervisor.dispatch(parentCtx(), { prompt: "hang" });
    expect(Date.now() - started).toBeGreaterThanOrEqual(20);
    expect(timedOut.status()).toBe("timeout");
    expect(cancelCalls).toBeGreaterThan(0);

    const parsed = parseSubagentSummary(timedOut.result() ?? "");
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.summary.status).toBe("timeout");
      expect(parsed.summary.error_if_any).toContain("maximum runtime");
    }

    const logLines = readFileSync(
      subagentLogPath(timedOut.sessionId, dir),
      "utf8",
    )
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    expect(logLines).toEqual(
      expect.arrayContaining([expect.objectContaining({ type: "subagent_timeout" })]),
    );

    // The slot was released: a fresh dispatch is admitted.
    const next = await supervisor.dispatch(parentCtx(), { prompt: "after timeout" });
    expect(next.status()).toBe("completed");
    expect(parseSubagentSummary(next.result() ?? "")).toMatchObject({
      ok: true,
      summary: { status: "completed", key_findings: ["second answer"] },
    });
  });
});
