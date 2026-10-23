// The subagent ceiling is CONCURRENT, not a lifetime total.
//
// Owner correction: "50 se jyada subagents dispatch nahi kar sakta ek sath
// mtlb ek sath ek session me 50 concurrent subagent active nahi ho sakte jab
// purane subagent done to new dispatch"
//
// The runtime used to count every child a root had EVER created and never
// release a slot, so a chat that had once run 50 subagents could never
// delegate again — the opposite of what the product promises.

import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import type { AgentEngine } from "./engine.js";
import type { AgentRunJob } from "./loop.js";
import type { EventSink, HookEngine } from "./ports.js";
import {
  createSubagentSupervisor,
  MAX_SUBAGENTS_PER_ROOT,
  SubagentLimitError,
  type RunStatus,
  type SubagentStore,
} from "./subagents.js";
import { createToolRegistry, type ToolContext } from "./types.js";
import { createMemoryStateStore } from "./ports.js";

interface FakeRun {
  id: string;
  sessionId: string;
  promptMessageId: string | null;
  status: RunStatus;
}

function fakeStore() {
  let seq = 0;
  const runsById = new Map<string, FakeRun>();
  const parentById = new Map<string, string>();
  const store: SubagentStore = {
    async createChild(o) {
      const id = `child-${++seq}`;
      parentById.set(id, o.parentSessionId);
      return { sessionId: id };
    },
    async appendUserMessage() {
      return { messageId: `msg-${++seq}` };
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
    async queuedRuns() {
      return [];
    },
    async promptText() {
      return "done";
    },
    async lastAssistantText() {
      return JSON.stringify({
        status: "completed",
        files_modified: [],
        artifacts_created: [],
        key_findings: ["ok"],
        error_if_any: null,
      });
    },
    async lineage(sessionId) {
      return [sessionId];
    },
    async listChildren(parentSessionId) {
      return [...parentById.entries()]
        .filter(([, parent]) => parent === parentSessionId)
        .map(([id]) => id);
    },
    async countChildrenUnderRoot(rootSessionId) {
      return [...parentById.values()].filter((p) => p === rootSessionId).length;
    },
  };
  return { store, runsById };
}

function parentCtx(): ToolContext {
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

function build(o: { fake: ReturnType<typeof fakeStore>; engine: AgentEngine }) {
  const supervisor = createSubagentSupervisor({
    db: {} as never,
    state: createMemoryStateStore(),
    registry: createToolRegistry([]),
    logDir: mkdtempSync(join(tmpdir(), "ovid-subagent-concurrent-")),
    engine: o.engine,
    hooks: fakeHooks(),
    sinkFactory: (sessionId: string): EventSink => ({
      async emit() {
        void sessionId;
      },
    }),
    store: o.fake.store,
  });
  return { supervisor };
}

/** An engine whose runs block until the returned `release()` is called. */
function gatedEngine() {
  let started = 0;
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  let onFull!: () => void;
  const allStarted = new Promise<void>((resolve) => {
    onFull = resolve;
  });
  const engine: AgentEngine = {
    async run(job: AgentRunJob) {
      started += 1;
      if (started === MAX_SUBAGENTS_PER_ROOT) onFull();
      await gate;
      void job;
    },
    async cancel() {
      return true;
    },
    activeRun() {
      return null;
    },
  };
  return { engine, release: () => release(), allStarted, started: () => started };
}

describe("concurrent subagent ceiling", () => {
  it("refuses the 51st while 50 are ACTIVE", async () => {
    const fake = fakeStore();
    const gated = gatedEngine();
    const { supervisor } = build({ fake, engine: gated.engine });

    const running = Array.from({ length: MAX_SUBAGENTS_PER_ROOT }, (_, i) =>
      supervisor.dispatch(parentCtx(), { prompt: `task ${i}` }),
    );
    await gated.allStarted;

    await expect(
      supervisor.dispatch(parentCtx(), { prompt: "task 51" }),
    ).rejects.toBeInstanceOf(SubagentLimitError);

    gated.release();
    await Promise.all(running);
  });

  it("accepts a new child once an active one settles", async () => {
    const fake = fakeStore();
    const gated = gatedEngine();
    const { supervisor } = build({ fake, engine: gated.engine });

    const running = Array.from({ length: MAX_SUBAGENTS_PER_ROOT }, (_, i) =>
      supervisor.dispatch(parentCtx(), { prompt: `task ${i}` }),
    );
    await gated.allStarted;
    await expect(
      supervisor.dispatch(parentCtx(), { prompt: "task 51" }),
    ).rejects.toBeInstanceOf(SubagentLimitError);

    // Everything settles -> the whole pool is free again.
    gated.release();
    await Promise.all(running);

    const next = await supervisor.dispatch(parentCtx(), { prompt: "after" });
    expect(next.status()).toBe("completed");
  });

  it("a chat that has run more than 50 children in total can still delegate", async () => {
    const fake = fakeStore();
    const gated = gatedEngine();
    const { supervisor } = build({ fake, engine: gated.engine });

    // Two full waves of 50, one after the other: 100 children in total.
    for (let wave = 0; wave < 2; wave += 1) {
      const running = Array.from({ length: MAX_SUBAGENTS_PER_ROOT }, (_, i) =>
        supervisor.dispatch(parentCtx(), { prompt: `wave ${wave} task ${i}` }),
      );
      if (wave === 0) {
        // Let the first wave finish before starting the second.
        await new Promise((resolve) => setTimeout(resolve, 0));
        gated.release();
      }
      await Promise.all(running);
    }

    const after = await supervisor.dispatch(parentCtx(), { prompt: "still works" });
    expect(after.status()).toBe("completed");
  });

  it("reports the active count per root session", async () => {
    const fake = fakeStore();
    const gated = gatedEngine();
    const { supervisor } = build({ fake, engine: gated.engine });

    const a = supervisor.dispatch(parentCtx(), { prompt: "a" });
    const b = supervisor.dispatch(parentCtx(), { prompt: "b" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(supervisor.activeCount("root")).toBeGreaterThan(0);
    expect(supervisor.activeCount("another-root")).toBe(0);

    gated.release();
    await Promise.all([a, b]);
    expect(supervisor.activeCount("root")).toBe(0);
  });
});
