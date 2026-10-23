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
import { DEFAULT_SUBAGENT_MAX_RUNTIME_MS, SubagentLimitError } from "../subagents.js";
import type { SubagentLogTail } from "../subagentLog.js";
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
    rawResult() {
      return o.result ?? null;
    },
  };
  return h;
}

function fakeSupervisor(o: {
  children?: ChildHandle[];
  dispatch?: (parent: ToolContext, args: DispatchArgs) => Promise<ChildHandle>;
  reportOk?: boolean;
  /** Log tail returned by `readLog` (default: one line per entry of `logText`). */
  logText?: string;
  logTruncated?: boolean;
  readLog?: (sessionId: string, options?: { tailLines?: number }) => Promise<SubagentLogTail>;
}): {
  supervisor: SubagentSupervisor;
  dispatched: DispatchArgs[];
  reports: Array<{ sessionId: string; summary: string }>;
  logReads: Array<{ sessionId: string; tailLines?: number }>;
} {
  const dispatched: DispatchArgs[] = [];
  const reports: Array<{ sessionId: string; summary: string }> = [];
  const logReads: Array<{ sessionId: string; tailLines?: number }> = [];
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
    async readLog(sessionId, options) {
      logReads.push({
        sessionId,
        ...(options?.tailLines !== undefined ? { tailLines: options.tailLines } : {}),
      });
      if (o.readLog) return o.readLog(sessionId, options);
      const text = o.logText ?? "";
      return {
        sessionId,
        path: `/logs/subagent_${sessionId}.log`,
        tailLines: options?.tailLines ?? 200,
        lines: text === "" ? [] : text.split("\n"),
        truncated: o.logTruncated ?? false,
        text,
      };
    },
  };
  return { supervisor, dispatched, reports, logReads };
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
  it("registers the management tools; dispatch_agent waits past the 8 h child budget", () => {
    const list = tools({}).tools;
    expect(list.map((t) => t.spec.name)).toEqual([
      "dispatch_agent",
      "send_message",
      "interrupt_agent",
      "list_agents",
      "read_subagent_log",
      "report",
    ]);
    // The dispatch call must not end before the supervisor's 8 h deadline can
    // stop the child — otherwise the child keeps running detached.
    expect(DISPATCH_AGENT_TIMEOUT_MS).toBeGreaterThan(DEFAULT_SUBAGENT_MAX_RUNTIME_MS);
    expect(DISPATCH_AGENT_TIMEOUT_MS).toBeGreaterThan(1_800_000);
    expect(byName(list, "dispatch_agent").timeoutMs).toBe(DISPATCH_AGENT_TIMEOUT_MS);
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
  it("returns the strict five-key JSON summary and rejects non-contract text", async () => {
    const { tools: list, dispatched } = tools({
      dispatch: async () =>
        handle({ status: "completed", result: "RFC 4180 quoting required" }),
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
    expect(Object.keys(JSON.parse(result.content)).sort()).toEqual([
      "artifacts_created",
      "error_if_any",
      "files_modified",
      "key_findings",
      "status",
    ]);
    // Non-contract prose is never echoed up as a finding.
    expect(JSON.parse(result.content)).toMatchObject({
      status: "completed",
      key_findings: [],
    });
    expect(JSON.parse(result.content).error_if_any).toContain("five-key");
    expect(result.content).not.toContain("RFC 4180");
    expect(dispatched[0]).toEqual({
      prompt: "audit the CSV parser",
      tools: ["Read"],
      disallowedTools: ["Bash"],
      agentType: "reviewer",
    });
  });

  it("adopts a child's contract JSON result", async () => {
    const contract = JSON.stringify({
      status: "completed",
      files_modified: ["src/csv.ts"],
      artifacts_created: [],
      key_findings: ["RFC 4180 quoting required"],
      error_if_any: null,
    });
    const { tools: list } = tools({
      dispatch: async () => handle({ status: "completed", result: contract }),
    });
    const result = await byName(list, "dispatch_agent").execute({ prompt: "audit" }, ctx());
    expect(JSON.parse(result.content)).toMatchObject({
      status: "completed",
      files_modified: ["src/csv.ts"],
      key_findings: ["RFC 4180 quoting required"],
      error_if_any: null,
    });
  });

  it("empty final text still yields a valid summary with no findings", async () => {
    const { tools: list } = tools({
      dispatch: async () => handle({ status: "completed", result: null }),
    });
    const result = await byName(list, "dispatch_agent").execute({ prompt: "x" }, ctx());
    expect(JSON.parse(result.content)).toMatchObject({
      status: "completed",
      key_findings: [],
      files_modified: [],
      artifacts_created: [],
      error_if_any: null,
    });
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

  it("surfaces the typed limit code at the tool boundary", async () => {
    const { tools: list } = tools({
      dispatch: async () => {
        throw new SubagentLimitError("root", 50);
      },
    });
    const result = await byName(list, "dispatch_agent").execute({ prompt: "x" }, ctx());
    expect(result.isError).toBe(true);
    expect(result.content).toContain("subagent_limit_exceeded:");
    expect(result.content).toContain("50 subagents are already running");
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

describe("read_subagent_log", () => {
  const child = () => handle({ sessionId: "child-1", status: "completed" });

  it("the main agent reads a bounded tail of its own child's log", async () => {
    const { tools: list, logReads } = tools({
      children: [child()],
      logText: '{"type":"tool_started","name":"file_read"}\n{"type":"subagent_result"}',
    });
    const result = await byName(list, "read_subagent_log").execute(
      { subagentId: "child-1", tailLines: 50 },
      ctx(),
    );
    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("Subagent child-1 log");
    expect(result.content).toContain("2 lines");
    expect(result.content).toContain('"name":"file_read"');
    expect(result.content).toContain('"type":"subagent_result"');
    expect(logReads).toEqual([{ sessionId: "child-1", tailLines: 50 }]);
  });

  it("defaults to 200 lines and clamps the request to 2,000", async () => {
    const { tools: list, logReads } = tools({ children: [child()], logText: "a\nb" });
    await byName(list, "read_subagent_log").execute({ subagentId: "child-1" }, ctx());
    await byName(list, "read_subagent_log").execute(
      { subagentId: "child-1", tailLines: 999_999 },
      ctx(),
    );
    await byName(list, "read_subagent_log").execute(
      { subagentId: "child-1", tailLines: "75" },
      ctx(),
    );
    expect(logReads.map((r) => r.tailLines)).toEqual([200, 2_000, 75]);
  });

  it("refuses a subagent — same no-nesting guard, no read performed", async () => {
    const { tools: list, logReads } = tools({ children: [child()] });
    const result = await byName(list, "read_subagent_log").execute(
      { subagentId: "child-1" },
      ctx({ sessionId: "child-1", isSubagent: true, depth: 1 }),
    );
    expect(result.isError).toBe(true);
    expect(result.content).toContain("only available to the main agent");
    expect(logReads).toHaveLength(0);
  });

  it("depth alone is enough to refuse (missing isSubagent backstop)", async () => {
    const { tools: list, logReads } = tools({ children: [child()] });
    const result = await byName(list, "read_subagent_log").execute(
      { subagentId: "child-1" },
      ctx({ sessionId: "child-1", isSubagent: false, depth: 1 }),
    );
    expect(result.isError).toBe(true);
    expect(logReads).toHaveLength(0);
  });

  it("an unknown id is an error string, not a throw", async () => {
    const { tools: list, logReads } = tools({ children: [child()] });
    const result = await byName(list, "read_subagent_log").execute(
      { subagentId: "ghost" },
      ctx(),
    );
    expect(result).toEqual({
      content: "Subagent ghost not found (list_agents shows ids).",
      isError: true,
    });
    expect(logReads).toHaveLength(0);
  });

  it("requires a subagentId", async () => {
    const { tools: list } = tools({ children: [child()] });
    const result = await byName(list, "read_subagent_log").execute({}, ctx());
    expect(result).toEqual({ content: "subagentId is required", isError: true });
  });

  it("a missing log file is a tool error, not a throw", async () => {
    const { tools: list } = tools({
      children: [child()],
      readLog: async () => {
        throw new Error("no subagent log found for child-1");
      },
    });
    const result = await byName(list, "read_subagent_log").execute(
      { subagentId: "child-1" },
      ctx(),
    );
    expect(result.isError).toBe(true);
    expect(result.content).toContain("Could not read the log of subagent child-1");
    expect(result.content).toContain("no subagent log found");
  });

  it("always surfaces a truncation marker when the read was shortened", async () => {
    const { tools: list } = tools({
      children: [child()],
      logText: "line-1\nline-2",
      logTruncated: true,
    });
    const result = await byName(list, "read_subagent_log").execute(
      { subagentId: "child-1" },
      ctx(),
    );
    expect(result.content).toContain("earlier lines omitted");
    expect(result.content).toContain("…[truncated]");
  });

  it("never renders more than the requested tail even if the reader over-returns", async () => {
    const many = Array.from({ length: 500 }, (_, i) => `line-${i}`);
    const { tools: list } = tools({
      children: [child()],
      readLog: async (sessionId, options) => ({
        sessionId,
        path: "/logs/x.log",
        tailLines: options?.tailLines ?? 200,
        lines: many,
        truncated: false,
        text: many.join("\n"),
      }),
    });
    const result = await byName(list, "read_subagent_log").execute(
      { subagentId: "child-1", tailLines: 10 },
      ctx(),
    );
    const body = result.content.split("\n").slice(1);
    expect(body.filter((line) => line.startsWith("line-"))).toHaveLength(10);
    expect(result.content).toContain("line-499");
    expect(result.content).not.toContain("line-489");
    expect(result.content).toContain("…[truncated]");
  });

  it("leaves the dispatch result a strict five-key JSON summary", async () => {
    const { tools: list } = tools({
      children: [child()],
      logText: "a\nb",
      dispatch: async () => handle({ status: "completed", result: "found it" }),
    });
    const read = await byName(list, "read_subagent_log").execute(
      { subagentId: "child-1" },
      ctx(),
    );
    expect(read.isError).toBeUndefined();
    const dispatched = await byName(list, "dispatch_agent").execute(
      { prompt: "audit" },
      ctx(),
    );
    expect(Object.keys(JSON.parse(dispatched.content)).sort()).toEqual([
      "artifacts_created",
      "error_if_any",
      "files_modified",
      "key_findings",
      "status",
    ]);
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
