// Goals & todos tools (P3 Task 13) — the port of agent_service.dart's
// _handleTodoWrite/_handleCreateGoal/_handleUpdateGoal/_handleGetGoal onto
// the SessionStateStore + EventSink seams.
//
// Dart parity kept: todo_write REPLACES the whole list (never appends) and
// the status enum; get_goal's checklist rendering (- [ ]/- [~]/- [x] — the
// same marks systemPrompt.ts uses); goal state persisted per session.
// Cloud deltas (pinned by the P3 brief): the goal is {objective, notes}
// (SessionGoal, Task 1 — no Dart status/round/progressLog machine; P4's
// scheduler owns rounds), update_goal merges PARTIALS instead of a status
// transition, and every mutation emits the additive session events
// todo_updated / goal_updated (union members landed with Task 12) so the
// gateway's live UI rides the same ledger as the state write.

import type { EventSink, SessionGoal, SessionStateStore, TodoItem } from "../ports.js";
import type { Tool, ToolContext, ToolResult } from "../types.js";

const TODO_STATUSES = ["pending", "in_progress", "completed"] as const;
type TodoStatus = (typeof TODO_STATUSES)[number];

/** Dart _handleTodoWrite's summary line: item/completed/in-progress counts. */
function todoSummary(todos: TodoItem[]): string {
  const done = todos.filter((t) => t.status === "completed").length;
  const inProg = todos.filter((t) => t.status === "in_progress").length;
  const pending = todos.length - done - inProg;
  return `todo list updated: ${todos.length} items (${done} completed, ${inProg} in progress, ${pending} pending)`;
}

/** The checklist marks shared with systemPrompt.ts's volatile todos block. */
function todoMark(status: TodoStatus): string {
  return status === "completed" ? "x" : status === "in_progress" ? "~" : " ";
}

function parseTodos(raw: unknown): TodoItem[] {
  if (!Array.isArray(raw)) {
    throw new Error("invalid_input: todos must be an array of {content, status}");
  }
  return raw.map((item) => {
    if (typeof item !== "object" || item === null) {
      throw new Error("invalid_input: each todo must be an object");
    }
    const o = item as Record<string, unknown>;
    const content = typeof o.content === "string" ? o.content : undefined;
    const status = o.status;
    if (content === undefined || content === "") {
      throw new Error("invalid_input: each todo needs a non-empty content string");
    }
    if (typeof status !== "string" || !TODO_STATUSES.includes(status as TodoStatus)) {
      throw new Error(`invalid_input: todo status must be one of ${TODO_STATUSES.join("/")}`);
    }
    return { content, status: status as TodoStatus };
  });
}

/** Runs a tool body; user-level failures become isError results, never throws. */
async function run(body: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await body();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { content: msg, isError: true };
  }
}

/** Emits through the session's sink; sink failures stay loud (P2 convention). */
async function emit(
  sink: EventSink,
  type: "todo_updated" | "goal_updated",
  payload: Record<string, unknown>,
): Promise<void> {
  await sink.emit(type, payload);
}

export function createGoalTodoTools(deps: {
  state: SessionStateStore;
  sinkFactory(sessionId: string): EventSink;
}): Tool[] {
  const { state, sinkFactory } = deps;

  const todoWrite: Tool = {
    spec: {
      name: "todo_write",
      description:
        "Write the session's todo/task list — a checklist the user sees live. " +
        "Each call REPLACES the whole list. Use it to track multi-step work: " +
        "mark items in_progress as you work on them, completed when done.",
      parameters: {
        type: "object",
        properties: {
          todos: {
            type: "array",
            items: {
              type: "object",
              properties: {
                content: { type: "string" },
                status: { type: "string", enum: [...TODO_STATUSES] },
              },
              required: ["content", "status"],
            },
          },
        },
        required: ["todos"],
      },
    },
    timeoutMs: 30_000,
    async execute(args: Record<string, unknown>, ctx: ToolContext) {
      return run(async () => {
        const todos = parseTodos(args.todos);
        // FULL-LIST REPLACE (Dart parity): patch stores the exact list —
        // omitting an old item removes it.
        await state.patch(ctx.sessionId, { todos });
        await emit(sinkFactory(ctx.sessionId), "todo_updated", {
          runId: ctx.runId,
          todos,
        });
        return { content: todoSummary(todos) };
      });
    },
  };

  const createGoal: Tool = {
    spec: {
      name: "create_goal",
      description:
        "Set this session's goal (objective + notes). One goal per session — " +
        "creating replaces any existing goal; use update_goal to change it.",
      parameters: {
        type: "object",
        properties: {
          objective: { type: "string", description: "What the user wants achieved." },
          notes: { type: "string", description: "Constraints, context, success criteria (optional)." },
        },
        required: ["objective"],
      },
    },
    timeoutMs: 30_000,
    async execute(args: Record<string, unknown>, ctx: ToolContext) {
      return run(async () => {
        const objective = typeof args.objective === "string" ? args.objective.trim() : "";
        if (objective === "") {
          return { content: "invalid_input: objective is required", isError: true };
        }
        const notes = typeof args.notes === "string" ? args.notes : "";
        const goal: SessionGoal = { objective, notes };
        await state.patch(ctx.sessionId, { goal });
        await emit(sinkFactory(ctx.sessionId), "goal_updated", { runId: ctx.runId, goal });
        return { content: `Goal created: ${objective}` };
      });
    },
  };

  const updateGoal: Tool = {
    spec: {
      name: "update_goal",
      description:
        "Update the session goal — objective and/or notes; omitted fields are " +
        "left untouched (partial merge).",
      parameters: {
        type: "object",
        properties: {
          objective: { type: "string", description: "New objective (optional)." },
          notes: { type: "string", description: "New notes (optional)." },
        },
      },
    },
    timeoutMs: 30_000,
    async execute(args: Record<string, unknown>, ctx: ToolContext) {
      return run(async () => {
        const current = (await state.get(ctx.sessionId)).goal;
        if (current === null) {
          return { content: "No goal in this session.", isError: true };
        }
        // PARTIAL MERGE: only provided fields move.
        const objective =
          typeof args.objective === "string" ? args.objective.trim() : current.objective;
        const notes = typeof args.notes === "string" ? args.notes : current.notes;
        if (objective === "") {
          return { content: "invalid_input: objective must not be empty", isError: true };
        }
        const goal: SessionGoal = { objective, notes };
        await state.patch(ctx.sessionId, { goal });
        await emit(sinkFactory(ctx.sessionId), "goal_updated", { runId: ctx.runId, goal });
        return { content: `Goal updated: ${objective}` };
      });
    },
  };

  const getGoal: Tool = {
    spec: {
      name: "get_goal",
      description:
        "Read the session's goal (objective, notes) with the live todo checklist.",
      parameters: { type: "object", properties: {} },
    },
    timeoutMs: 30_000,
    async execute(_args: Record<string, unknown>, ctx: ToolContext) {
      return run(async () => {
        const s = await state.get(ctx.sessionId);
        if (s.goal === null) return { content: "No goal in this session." };
        const lines = [`Goal: ${s.goal.objective}`];
        const notes = s.goal.notes.trim();
        if (notes !== "") lines.push(`Notes: ${notes}`);
        if (s.todos.length > 0) {
          lines.push("Todos:");
          for (const t of s.todos) lines.push(`- [${todoMark(t.status)}] ${t.content}`);
        }
        return { content: lines.join("\n") };
      });
    },
  };

  return [todoWrite, createGoal, updateGoal, getGoal];
}
