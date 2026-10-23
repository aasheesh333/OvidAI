// Subagent management tools (P3 Task 20) — dispatch_agent / send_message /
// interrupt_agent / list_agents / report. Port targets: the plan's Step-1
// strings and the Dart handler copies in the T20 map (§2.8).

import { describe, expect, it } from "vitest";

import { createMemoryStateStore, type EventSink } from "../ports.js";
import {
  createSubagentTools,
  DISPATCH_AGENT_TIMEOUT_MS,
} from "./subagentTools.js";
import type { ChildHandle, ChildStatus, DispatchArgs, SubagentSupervisor } from "../subagents.js";
import type { ToolContext } from "../types.js";

function ctx(o: Partial<ToolContext> = {}): ToolContext {
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
    ...o,
  };
}

function handle(o: {
  sessionId?: string;
  status?: ChildStatus;
  prompt?: string;
  result?: string | null;
  interrupt?: (reason: string) => Promise<boolean>;
  sendMessage?: (text: string) => Promise<void>;
}): ChildHandle {
  let status = o.status ?? "running";
  const h: ChildHandle = {
    sessionId: o.sessionId ?? "child-1",
    runId: "child-run-1",
    parentSessionId: "root",
    rootSessionId: "root",
    depth: 1,
    prompt: o.prompt ?? "do the thing",
    agentType: "general-purpose",
    startedAt: 0,
    async interrupt(reason) {
      const stopped = o.interrupt ? await o.interrupt(reason) : true;
      if (stopped) status = "cancelled";
      return stopped;
    },
    async sendMessage(text) {
      await o.sendMessage?.(text);
    },
    status() {
      return status;
    },
    result() {
      return o.result ?? null;
    },
  };
  return h;
}

function fakeSupervisor(o: {
  children?: ChildHandle[];
  dispatch?: (parent: ToolContext, args: DispatchArgs) => Promise<ChildHandle>;
  reportOk?: boolean;
}): {
  supervisor: SubagentSupervisor;
  dispatched: DispatchArgs[];
  reports: Array<{ sessionId: string; summary: string }>;
} {
  const dispatched: DispatchArgs[] = [];
  const reports: Array<{ sessionId: string; summary: string }> = [];
  const supervisor: SubagentSupervisor = {
    async dispatch(parent, args) {
      dispatched.push(args);
      if (o.dispatch) return o.dispatch(parent, args);
      return handle({ result: "the answer" });
    },
    childrenOf() {
      return o.children ?? [];
    },
    recordReport(sessionId, summary) {
      reports.push({ sessionId, summary });
      return o.reportOk ?? true;
    },
  };
  return { supervisor, dispatched, reports };
}

function fakeSink(): { sink: EventSink; events: Array<{ type: string; payload: Record<string, unknown> }> } {
  const events: Array<{ type: string; payload: Record<string, unknown> }> = [];
  return {
    events,
    sink: {
      async emit(type, payload) {
        events.push({ type, payload });
      },
    },
  };
}

function tools(o: Parameters<typeof fakeSupervisor>[0]) {
  const fake = fakeSupervisor(o);
  const { sink, events } = fakeSink();
  return {
    ...fake,
    events,
    tools: createSubagentTools({
      supervisor: fake.supervisor,
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

describe("createSubagentTools — registration", () => {
  it("registers the five management tools; dispatch_agent pins 1_800_000 ms", () => {
    const list = tools({}).tools;
    expect(list.map((t) => t.spec.name)).toEqual([
      "dispatch_agent",
      "send_message",
      "interrupt_agent",
      "list_agents",
      "report",
    ]);
    expect(byName(list, "dispatch_agent").timeoutMs).toBe(1_800_000);
    expect(DISPATCH_AGENT_TIMEOUT_MS).toBe(1_800_000);
    // Cloud-reduced args only.
    const params = byName(list, "dispatch_agent").spec.parameters as {
      properties: Record<string, unknown>;
    };
    expect(Object.keys(params.properties)).toEqual([
      "prompt",
      "tools",
      "disallowedTools",
      "agentType",
    ]);
  });
});

describe("dispatch_agent", () => {
  it("returns a started line, never the child's report", async () => {
    const { tools: list, dispatched } = tools({
      dispatch: async () => handle({ result: "RFC 4180 quoting required" }),
    });
    const result = await byName(list, "dispatch_agent").execute(
      {
        prompt: "  audit the CSV parser ",
        tools: ["Read"],
        disallowedTools: ["Bash"],
        agentType: "reviewer",
      },
      ctx(),
    );
    // Non-blocking contract: the tool cannot know the answer yet, so it must
    // not pretend to. The report arrives later as a system note.
    expect(result.content).toContain("child-1");
    expect(result.content).toContain("started");
    expect(result.content).not.toContain("RFC 4180 quoting required");
    expect(dispatched[0]).toEqual({
      prompt: "audit the CSV parser",
      tools: ["Read"],
      disallowedTools: ["Bash"],
      agentType: "reviewer",
    });
  });

  it("a child with no answer yet still reads as started, not finished", async () => {
    const { tools: list } = tools({
      dispatch: async () => handle({ result: null }),
    });
    const result = await byName(list, "dispatch_agent").execute({ prompt: "x" }, ctx());
    expect(result.content).toContain("started");
    expect(result.content).not.toContain("finished without a final answer");
  });

  it("renders a supervisor refusal as a tool error, never a throw", async () => {
    const { tools: list } = tools({
      dispatch: async () => {
        throw new Error("Subagent depth limit (2) reached — do the task yourself with the tools you have.");
      },
    });
    const result = await byName(list, "dispatch_agent").execute({ prompt: "x" }, ctx());
    expect(result.isError).toBe(true);
    expect(result.content).toContain("Subagent depth limit (2) reached");
  });

  it("requires a prompt", async () => {
    const { tools: list } = tools({});
    const result = await byName(list, "dispatch_agent").execute({ prompt: " " }, ctx());
    expect(result).toEqual({ content: "prompt is required", isError: true });
  });
});

describe("send_message", () => {
  it("defaults to the newest running child", async () => {
    const sent: string[] = [];
    const running = handle({
      sessionId: "child-new",
      sendMessage: async (text) => {
        sent.push(text);
      },
    });
    const { tools: list } = tools({ children: [handle({ sessionId: "child-old", status: "completed" }), running] });
    const result = await byName(list, "send_message").execute({ text: "next" }, ctx());
    expect(result.content).toBe("queued as the next turn for child-new");
    expect(sent).toEqual(["next"]);
  });

  it("with no running child answers the pinned cloud string", async () => {
    const { tools: list } = tools({ children: [handle({ status: "completed" })] });
    const result = await byName(list, "send_message").execute({ text: "next" }, ctx());
    expect(result).toEqual({ content: "No active subagent to message.", isError: true });
  });

  it("an explicit unknown session id answers the Dart not-found copy", async () => {
    const { tools: list } = tools({});
    const result = await byName(list, "send_message").execute(
      { sessionId: "nope", text: "next" },
      ctx(),
    );
    expect(result).toEqual({
      content: "Subagent nope not found (list_agents shows active ids).",
      isError: true,
    });
  });
});

describe("interrupt_agent", () => {
  it("stops a running child with the Dart copy", async () => {
    let reason = "";
    const running = handle({
      sessionId: "child-1",
      interrupt: async (r) => {
        reason = r;
        return true;
      },
    });
    const { tools: list } = tools({ children: [running] });
    const result = await byName(list, "interrupt_agent").execute(
      { sessionId: "child-1", reason: "user stop" },
      ctx(),
    );
    expect(result.content).toBe(
      "interrupted subagent child-1 and its descendants — their transcripts are kept.",
    );
    expect(reason).toBe("user stop");
  });

  it("an unknown id is an error string, not a throw", async () => {
    const { tools: list } = tools({});
    const result = await byName(list, "interrupt_agent").execute(
      { sessionId: "ghost" },
      ctx(),
    );
    expect(result).toEqual({ content: "Subagent ghost not found.", isError: true });
  });

  it("an already-finished child answers already finished", async () => {
    const { tools: list } = tools({ children: [handle({ sessionId: "child-1", status: "completed" })] });
    const result = await byName(list, "interrupt_agent").execute(
      { sessionId: "child-1" },
      ctx(),
    );
    expect(result).toEqual({
      content: "Subagent child-1 already finished.",
      isError: true,
    });
  });
});

describe("list_agents", () => {
  it("renders one status line per child of the CURRENT session", async () => {
    const { tools: list } = tools({
      children: [
        handle({ sessionId: "child-1", status: "running", prompt: "first task" }),
        handle({ sessionId: "child-2", status: "completed", prompt: "second task" }),
      ],
    });
    const result = await byName(list, "list_agents").execute({}, ctx());
    expect(result.content).toBe(
      [
        "Subagents (children, 2):",
        "child-1 [running] · first task",
        "child-2 [completed] · second task",
      ].join("\n"),
    );
  });

  it("answers the Dart empty copy", async () => {
    const { tools: list } = tools({ children: [] });
    const result = await byName(list, "list_agents").execute({}, ctx());
    expect(result.content).toBe("No subagents dispatched (children).");
  });
});

describe("report", () => {
  it("records the summary, emits system_note {code:'report'}, and returns Report delivered.", async () => {
    const { tools: list, events, reports } = tools({});
    const result = await byName(list, "report").execute(
      { summary: "found the bug" },
      ctx({ sessionId: "child-1", isSubagent: true }),
    );
    expect(result).toEqual({ content: "Report delivered." });
    expect(reports).toEqual([{ sessionId: "child-1", summary: "found the bug" }]);
    expect(events).toEqual([{ type: "system_note", payload: { code: "report" } }]);
  });

  it("refuses a top-level session with the Dart copy", async () => {
    const { tools: list, events } = tools({});
    const result = await byName(list, "report").execute(
      { summary: "hello" },
      ctx({ isSubagent: false }),
    );
    expect(result.isError).toBe(true);
    expect(result.content).toContain("report is only available to subagents");
    expect(events).toHaveLength(0);
  });

  it("requires content", async () => {
    const { tools: list } = tools({});
    const result = await byName(list, "report").execute(
      { summary: " " },
      ctx({ isSubagent: true }),
    );
    expect(result).toEqual({ content: "report content is required", isError: true });
  });
});
