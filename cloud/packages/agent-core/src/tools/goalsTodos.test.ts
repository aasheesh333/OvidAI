import { describe, expect, it } from "vitest";

import { createMemoryStateStore, type EventSink, type SessionAgentState } from "../ports.js";
import type { ToolContext } from "../types.js";
import { createGoalTodoTools } from "./goalsTodos.js";

/**
 * P3 Task 13 — goals/todos tools over the Task-1 memory state store + a
 * recording EventSink. Pins Dart's full-list-replace todo_write semantics, the
 * todo_updated/goal_updated session events (additive members landed with the
 * shared event union in Task 12), partial-merge update_goal, and get_goal's
 * checklist rendering.
 */

function ctx(sessionId = "s1"): ToolContext {
  return {
    sessionId,
    runId: "r1",
    userId: "u1",
    mode: "auto",
    planMode: false,
    isSubagent: false,
    depth: 0,
    unattended: false,
    callKey: "k1",
    signal: new AbortController().signal,
  };
}

function recordingSink() {
  const events: Array<{ type: string; payload: Record<string, unknown> }> = [];
  const sink: EventSink = {
    async emit(type, payload) {
      events.push({ type, payload });
    },
  };
  return { events, sink };
}

const byName = (tools: ReturnType<typeof createGoalTodoTools>) =>
  new Map(tools.map((t) => [t.spec.name, t]));

function setup() {
  const state = createMemoryStateStore();
  const { events, sink } = recordingSink();
  const sinkFactory = (_sessionId: string) => sink;
  const tools = byName(createGoalTodoTools({ state, sinkFactory }));
  return { state, events, tools };
}

describe("todo_write", () => {
  it("REPLACES the whole list (Dart full-replace parity) and emits todo_updated with the EXACT todos", async () => {
    const { state, events, tools } = setup();
    await state.patch("s1", { todos: [{ content: "old item", status: "pending" }] });

    const todos = [
      { content: "step one", status: "completed" },
      { content: "step two", status: "in_progress" },
      { content: "step three", status: "pending" },
    ];
    const res = await tools.get("todo_write")!.execute({ todos }, ctx());
    expect(res.isError).toBeFalsy();
    expect(res.content).toContain("3 items");
    expect(res.content).toContain("1 completed");
    expect(res.content).toContain("1 in progress");

    // The old list is gone — replaced, not appended.
    const after = await state.get("s1");
    expect(after.todos).toEqual(todos);

    // Exactly one todo_updated event carrying the exact todos + runId.
    const emitted = events.filter((e) => e.type === "todo_updated");
    expect(emitted).toHaveLength(1);
    expect(emitted[0]!.payload).toEqual({ runId: "r1", todos });
  });

  it("an empty list clears the todos (and still emits)", async () => {
    const { state, events, tools } = setup();
    await state.patch("s1", { todos: [{ content: "x", status: "pending" }] });
    const res = await tools.get("todo_write")!.execute({ todos: [] }, ctx());
    expect(res.isError).toBeFalsy();
    expect((await state.get("s1")).todos).toEqual([]);
    expect(events.filter((e) => e.type === "todo_updated")).toHaveLength(1);
  });

  it("rejects malformed todo items instead of coercing them", async () => {
    const { tools } = setup();
    const bad = await tools.get("todo_write")!.execute(
      { todos: [{ content: "x", status: "bogus" }] },
      ctx(),
    );
    expect(bad.isError).toBe(true);

    const notArray = await tools.get("todo_write")!.execute({ todos: "nope" }, ctx());
    expect(notArray.isError).toBe(true);
  });

  it("is session-scoped: writing s1 never touches s2", async () => {
    const { state, tools } = setup();
    await tools.get("todo_write")!.execute(
      { todos: [{ content: "only s1", status: "pending" }] },
      ctx("s1"),
    );
    const s2 = await state.get("s2");
    expect(s2.todos).toEqual([]);
  });
});

describe("goals", () => {
  it("create_goal sets objective+notes and emits goal_updated", async () => {
    const { state, events, tools } = setup();
    const res = await tools
      .get("create_goal")!
      .execute({ objective: "Ship the migration", notes: "first pass" }, ctx());
    expect(res.isError).toBeFalsy();
    expect(res.content).toContain("Ship the migration");

    const goal = (await state.get("s1")).goal;
    expect(goal).toEqual({ objective: "Ship the migration", notes: "first pass" });

    const emitted = events.filter((e) => e.type === "goal_updated");
    expect(emitted).toHaveLength(1);
    expect(emitted[0]!.payload).toEqual({
      runId: "r1",
      goal: { objective: "Ship the migration", notes: "first pass" },
    });
  });

  it("create_goal without notes defaults notes to ''", async () => {
    const { state, tools } = setup();
    await tools.get("create_goal")!.execute({ objective: "O" }, ctx());
    expect((await state.get("s1")).goal).toEqual({ objective: "O", notes: "" });
  });

  it("update_goal merges PARTIALS (objective and notes update independently)", async () => {
    const { state, events, tools } = setup();
    await tools.get("create_goal")!.execute({ objective: "O1", notes: "n1" }, ctx());

    await tools.get("update_goal")!.execute({ notes: "n2" }, ctx());
    expect((await state.get("s1")).goal).toEqual({ objective: "O1", notes: "n2" });

    await tools.get("update_goal")!.execute({ objective: "O2" }, ctx());
    expect((await state.get("s1")).goal).toEqual({ objective: "O2", notes: "n2" });

    // Neither create nor the two updates can pass without events.
    expect(events.filter((e) => e.type === "goal_updated")).toHaveLength(3);
    const last = events.filter((e) => e.type === "goal_updated").at(-1)!;
    expect(last.payload).toEqual({ runId: "r1", goal: { objective: "O2", notes: "n2" } });
  });

  it("update_goal with no existing goal is an error; empty objective is rejected", async () => {
    const { tools } = setup();
    const noGoal = await tools.get("update_goal")!.execute({ objective: "X" }, ctx());
    expect(noGoal.isError).toBe(true);
    expect(noGoal.content).toContain("No goal");

    const state = createMemoryStateStore();
    const { events, sink } = recordingSink();
    const tools2 = byName(createGoalTodoTools({ state, sinkFactory: () => sink }));
    await tools2.get("create_goal")!.execute({ objective: "O" }, ctx());
    const blank = await tools2.get("update_goal")!.execute({ objective: "  " }, ctx());
    expect(blank.isError).toBe(true);
    // A rejected update writes nothing and emits nothing new.
    expect(events.filter((e) => e.type === "goal_updated")).toHaveLength(1);
  });

  it("get_goal renders objective, notes and the todo checklist with - [~]/- [ ]/- [x]", async () => {
    const { state, tools } = setup();
    await tools
      .get("create_goal")!
      .execute({ objective: "Port the tools", notes: "see plan" }, ctx());
    await tools.get("todo_write")!.execute(
      {
        todos: [
          { content: "done thing", status: "completed" },
          { content: "active thing", status: "in_progress" },
          { content: "later thing", status: "pending" },
        ],
      },
      ctx(),
    );
    const res = await tools.get("get_goal")!.execute({}, ctx());
    expect(res.isError).toBeFalsy();
    expect(res.content).toContain("Port the tools");
    expect(res.content).toContain("see plan");
    expect(res.content).toContain("- [x] done thing");
    expect(res.content).toContain("- [~] active thing");
    expect(res.content).toContain("- [ ] later thing");
  });

  it("get_goal with no goal → 'No goal in this session.' (Dart copy)", async () => {
    const { tools } = setup();
    const res = await tools.get("get_goal")!.execute({}, ctx());
    expect(res.content).toBe("No goal in this session.");
    expect(res.isError).toBeFalsy();
  });
});

describe("state round-trip through the whole SessionAgentState shape", () => {
  it("goal and todos coexist with the other state fields (no clobbering)", async () => {
    const { state, tools } = setup();
    const before: Partial<SessionAgentState> = { presetId: "p1", mode: "drive", planMode: false };
    await state.patch("s1", before);
    await tools.get("create_goal")!.execute({ objective: "O" }, ctx());
    await tools.get("todo_write")!.execute(
      { todos: [{ content: "t", status: "pending" }] },
      ctx(),
    );
    const after = await state.get("s1");
    expect(after.presetId).toBe("p1");
    expect(after.mode).toBe("drive");
    expect(after.goal).toEqual({ objective: "O", notes: "" });
    expect(after.todos).toEqual([{ content: "t", status: "pending" }]);
  });
});
