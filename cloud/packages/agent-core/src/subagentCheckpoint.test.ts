// Spec §2.A.3: an 8-hour child "gracefully checkpoints and notifies the Main
// Agent to re-trigger".
//
// The supervisor killed the child at the deadline and said only "exceeded the
// maximum runtime". With the partial-output change the parent at least sees
// the tail of the work, but there was no CHECKPOINT — nothing durable saying
// where to resume — and the error text did not tell the parent what to do, so
// a long task restarted from zero.

import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import type { AgentEngine } from "./engine.js";
import type { AgentRunJob } from "./loop.js";
import type { EventSink, HookEngine } from "./ports.js";
import { createMemoryStateStore } from "./ports.js";
import {
  createSubagentSupervisor,
  type RunStatus,
  type SubagentStore,
} from "./subagents.js";
import { subagentLogPath } from "./subagentLog.js";
import { parseSubagentSummary } from "./subagentSummary.js";
import { createToolRegistry, type ToolContext } from "./types.js";

interface FakeRun {
  id: string;
  sessionId: string;
  promptMessageId: string | null;
  status: RunStatus;
}

function fakeStore() {
  let seq = 0;
  const runsById = new Map<string, FakeRun>();
  const store: SubagentStore = {
    async createChild() {
      return { sessionId: `child-${++seq}` };
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
      return "";
    },
    async lastAssistantText() {
      return null;
    },
    async lineage(sessionId) {
      return [sessionId];
    },
    async listChildren() {
      return [];
    },
    async countChildrenUnderRoot() {
      return 0;
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

function build(engine: AgentEngine, maxRuntimeMs: number) {
  const fake = fakeStore();
  const dir = mkdtempSync(join(tmpdir(), "ovid-subagent-checkpoint-"));
  const supervisor = createSubagentSupervisor({
    engine,
    db: {} as never,
    state: createMemoryStateStore(),
    registry: createToolRegistry([]),
    hooks: fakeHooks(),
    sinkFactory: (sessionId: string): EventSink => ({
      async emit() {
        void sessionId;
      },
    }),
    store: fake.store,
    logDir: dir,
    maxRuntimeMs,
  });
  return { supervisor, dir };
}

/** An engine that streams a bit of work, then hangs until cancelled. */
function hangingEngine() {
  let release: (() => void) | undefined;
  const engine: AgentEngine = {
    async run(job: AgentRunJob) {
      await job.sink?.emit("message_delta", {
        runId: job.runId,
        text: "Migrated 3 of 7 modules; next is billing.",
      });
      await new Promise<void>((resolve) => {
        release = resolve;
      });
    },
    async cancel() {
      release?.();
      return true;
    },
    activeRun() {
      return null;
    },
  };
  return engine;
}

describe("8-hour checkpoint", () => {
  it("writes a checkpoint line into the child's log at the deadline", async () => {
    const { supervisor, dir } = build(hangingEngine(), 25);
    const handle = await supervisor.dispatch(parentCtx(), { prompt: "migrate" });

    expect(handle.status()).toBe("timeout");

    const lines = readFileSync(subagentLogPath(handle.sessionId, dir), "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line) as Record<string, unknown>);

    const checkpoint = lines.find((l) => l["type"] === "subagent_checkpoint");
    expect(checkpoint).toBeDefined();
    expect(checkpoint).toMatchObject({ status: "timeout" });
    // The checkpoint carries the work done so far, so a re-dispatch resumes.
    expect(String(checkpoint!["partial_output"])).toContain("3 of 7 modules");
  });

  it("tells the parent how to continue instead of only that it failed", async () => {
    const { supervisor } = build(hangingEngine(), 25);
    const handle = await supervisor.dispatch(parentCtx(), { prompt: "migrate" });

    const parsed = parseSubagentSummary(handle.result() ?? "");
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.summary.status).toBe("timeout");
    // Actionable: it says the progress is saved and to dispatch again.
    expect(parsed.summary.error_if_any).toMatch(/checkpoint/i);
    expect(parsed.summary.error_if_any).toMatch(/dispatch/i);
    // And the work itself is still there.
    expect(parsed.summary.key_findings.join("\n")).toContain("3 of 7 modules");
  });

  it("does not write a checkpoint for a child that finished normally", async () => {
    const engine: AgentEngine = {
      async run(job: AgentRunJob) {
        await job.sink?.emit("message_completed", {
          messageId: "m1",
          content: JSON.stringify({
            subagent_id: job.sessionId,
            status: "completed",
            files_modified: [],
            artifacts_created: [],
            key_findings: ["done"],
            error_if_any: null,
          }),
        });
      },
      async cancel() {
        return true;
      },
      activeRun() {
        return null;
      },
    };
    const { supervisor, dir } = build(engine, 60_000);
    const handle = await supervisor.dispatch(parentCtx(), { prompt: "quick" });
    expect(handle.status()).toBe("completed");

    const text = readFileSync(subagentLogPath(handle.sessionId, dir), "utf8");
    expect(text).not.toContain("subagent_checkpoint");
  });
});
