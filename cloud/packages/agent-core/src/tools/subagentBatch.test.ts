// `dispatch_agents` — parallel delegation.
//
// The owner's model: the main agent does ~85% of the work THROUGH subagents.
// The loop runs one tool call at a time, so N separate `dispatch_agent` calls
// in one turn are serialised — with an 8-hour child budget, a 20-child plan
// would take days. One batch call runs its children concurrently.

import { describe, expect, it } from "vitest";

import { createMemoryStateStore } from "../ports.js";
import type { EventSink } from "../ports.js";
import type { DispatchArgs, ChildHandle, SubagentSupervisor } from "../subagents.js";
import { SubagentLimitError } from "../subagents.js";
import { createSubagentTools } from "./subagentTools.js";
import type { ToolContext } from "../types.js";

function ctx(): ToolContext {
  return {
    sessionId: "root",
    runId: "run-1",
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

/** A stable child id per finding, so subagent_id is a real value. */
function sessionIdFor(finding: string): string {
  return `child-${finding}`;
}

function summaryJson(finding: string): string {
  return JSON.stringify({
    subagent_id: sessionIdFor(finding),
    status: "completed",
    files_modified: [],
    artifacts_created: [],
    key_findings: [finding],
    error_if_any: null,
  });
}

function childHandle(sessionId: string, finding: string): ChildHandle {
  const result = summaryJson(finding);
  return {
    sessionId,
    runId: `${sessionId}-run`,
    parentSessionId: "root",
    rootSessionId: "root",
    depth: 1,
    prompt: finding,
    agentType: "general-purpose",
    startedAt: 0,
    async interrupt() {
      return true;
    },
    status() {
      return "completed";
    },
    result() {
      return result;
    },
    rawResult() {
      return result;
    },
  };
}

function tools(o: {
  dispatch?: (parent: ToolContext, args: DispatchArgs) => Promise<ChildHandle>;
}) {
  const dispatched: DispatchArgs[] = [];
  const supervisor: SubagentSupervisor = {
    async dispatch(parent, args) {
      dispatched.push(args);
      if (o.dispatch) return o.dispatch(parent, args);
      return childHandle(`child-${dispatched.length}`, "ok");
    },
    childrenOf() {
      return [];
    },
    activeCount() {
      return dispatched.length;
    },
    recordReport() {
      return true;
    },
    async readLog(sessionId: string) {
      return {
        sessionId,
        path: `/logs/subagent_${sessionId}.log`,
        tailLines: 200,
        lines: [],
        truncated: false,
        text: "",
      };
    },
  };
  const sink: EventSink = {
    async emit() {},
  };
  return {
    dispatched,
    list: createSubagentTools({
      supervisor,
      state: createMemoryStateStore(),
      sink,
    }),
  };
}

function byName(list: ReturnType<typeof createSubagentTools>, name: string) {
  const tool = list.find((t) => t.spec.name === name);
  if (tool === undefined) throw new Error(`missing tool ${name}`);
  return tool;
}

describe("dispatch_agents (batch)", () => {
  it("is registered alongside dispatch_agent", () => {
    const { list } = tools({});
    expect(list.map((t) => t.spec.name)).toContain("dispatch_agents");
  });

  it("returns one summary per task, in task order", async () => {
    const { list, dispatched } = tools({
      dispatch: async (_parent, args) =>
        childHandle(`child-${args.prompt}`, `finding:${args.prompt}`),
    });

    const result = await byName(list, "dispatch_agents").execute(
      { tasks: [{ prompt: "alpha" }, { prompt: "beta" }, { prompt: "gamma" }] },
      ctx(),
    );

    expect(result.isError).not.toBe(true);
    const parsed = JSON.parse(result.content) as Array<{
      index: number;
      prompt: string;
      summary: { key_findings: string[] };
    }>;
    expect(parsed.map((p) => p.prompt)).toEqual(["alpha", "beta", "gamma"]);
    expect(parsed.map((p) => p.summary.key_findings[0])).toEqual([
      "finding:alpha",
      "finding:beta",
      "finding:gamma",
    ]);
    expect(dispatched).toHaveLength(3);
  });

  it("runs the children CONCURRENTLY, not one after another", async () => {
    let inFlight = 0;
    let peak = 0;
    const { list } = tools({
      dispatch: async (_parent, args) => {
        inFlight += 1;
        peak = Math.max(peak, inFlight);
        await new Promise((resolve) => setTimeout(resolve, 15));
        inFlight -= 1;
        return childHandle(`child-${args.prompt}`, "ok");
      },
    });

    await byName(list, "dispatch_agents").execute(
      { tasks: [{ prompt: "a" }, { prompt: "b" }, { prompt: "c" }, { prompt: "d" }] },
      ctx(),
    );

    expect(peak).toBe(4);
  });

  it("one refused task does not fail the batch", async () => {
    const { list } = tools({
      dispatch: async (_parent, args) => {
        if (args.prompt === "boom") throw new SubagentLimitError("root", 50);
        return childHandle(`child-${args.prompt}`, "fine");
      },
    });

    const result = await byName(list, "dispatch_agents").execute(
      { tasks: [{ prompt: "ok-1" }, { prompt: "boom" }, { prompt: "ok-2" }] },
      ctx(),
    );

    expect(result.isError).not.toBe(true);
    const parsed = JSON.parse(result.content) as Array<{
      prompt: string;
      error?: string;
      summary?: unknown;
    }>;
    expect(parsed[0]?.summary).toBeDefined();
    expect(parsed[1]?.error).toContain("subagent_limit_exceeded");
    expect(parsed[2]?.summary).toBeDefined();
  });

  it("refuses an empty task list instead of silently doing nothing", async () => {
    const { list } = tools({});
    const result = await byName(list, "dispatch_agents").execute({ tasks: [] }, ctx());
    expect(result.isError).toBe(true);
    expect(result.content).toContain("tasks");
  });

  it("refuses a batch larger than the concurrency ceiling", async () => {
    const { list } = tools({});
    const tasks = Array.from({ length: 51 }, (_, i) => ({ prompt: `t${i}` }));
    const result = await byName(list, "dispatch_agents").execute({ tasks }, ctx());
    expect(result.isError).toBe(true);
    expect(result.content).toContain("50");
  });
});
