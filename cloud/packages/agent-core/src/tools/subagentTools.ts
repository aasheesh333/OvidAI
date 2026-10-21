// Subagent management tools (P3 Task 20) — dispatch_agent, send_message,
// interrupt_agent, list_agents, read_subagent_log, report.
//
// PORT OF: lib/core/agent_service.dart's tool schemas (dispatch_agent
// AS:9394–9465, send_message AS:9550–9561, interrupt_agent AS:9567–9578,
// list_agents AS:9584–9598, report AS:9663–9677) and their handlers
// (AS:23840–24151).
//
// CLOUD REDUCTIONS (binding, plan Task 20):
//  • dispatch_agent args = {prompt, tools?, disallowedTools?, agentType?} —
//    Dart's label/mode/run_in_background/continuable/persona/output-schema
//    surface is cut. agentType maps subagent_type.
//  • The dispatch tool's OWN timeout is aligned with the child budget: the
//    supervisor stops a child at DEFAULT_SUBAGENT_MAX_RUNTIME_MS (8 h) and
//    this tool waits a grace period longer. A shorter tool timeout would end
//    the parent's call while the 8-hour child kept running detached.
//  • send_message/interrupt_agent default to the NEWEST RUNNING CHILD when no
//    sessionId is given (a cloud convenience; Dart is handle-id based).
//  • list_agents renders children of the CURRENT session.
//  • read_subagent_log returns a BOUNDED tail of a child's append-only log
//    (default 200 lines, max 2,000, truncation marker) and is MAIN-AGENT ONLY:
//    a subagent calling it is refused with the same no-nesting guard as
//    dispatch_agent.
//  • report records the child's final report (the supervisor uses it as the
//    dispatch result) and returns the literal `Report delivered.`
//  • dispatch_agent's result is the strict five-key JSON summary
//    (subagentSummary.ts) — never the child's transcript and no
//    `[<id> <state> · <elapsed>s]` wrapper.

import type { EventSink } from "../ports.js";
import {
  DEFAULT_SUBAGENT_MAX_RUNTIME_MS,
  READ_SUBAGENT_LOG_TOOL_NAME,
  renderChildLine,
  subagentResultJson,
  SubagentRefusalError,
  type ChildHandle,
  type SubagentSupervisor,
} from "../subagents.js";
import {
  clampSubagentLogTailLines,
  SUBAGENT_LOG_TRUNCATION_MARKER,
} from "../subagentLog.js";
import type { SessionStateStore } from "../ports.js";
import type { Tool, ToolContext, ToolResult } from "../types.js";

/**
 * The dispatch tool's budget. It must EXCEED the supervisor's 8-hour child
 * deadline: the supervisor is the component that knows how to stop the child
 * (engine cancel + sandbox kill), so the tool must not win the race and leave
 * the child running after the parent's call has already returned an error.
 */
export const DISPATCH_AGENT_TIMEOUT_MS =
  DEFAULT_SUBAGENT_MAX_RUNTIME_MS + 2 * 60 * 1000;

function argString(args: Record<string, unknown>, key: string): string {
  const value = args[key];
  return typeof value === "string" ? value.trim() : "";
}

/** Number args tolerate a numeric string (models often send "500"). */
function argNumber(args: Record<string, unknown>, key: string): number | undefined {
  const value = args[key];
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return undefined;
}

function argStrings(args: Record<string, unknown>, key: string): string[] | undefined {
  const value = args[key];
  if (!Array.isArray(value)) return undefined;
  const out: string[] = [];
  for (const item of value) {
    if (typeof item === "string" && item.trim() !== "") out.push(item.trim());
  }
  return out;
}

function newestRunning(
  supervisor: SubagentSupervisor,
  sessionId: string,
): ChildHandle | undefined {
  const running = supervisor.childrenOf(sessionId).filter((h) => h.status() === "running");
  return running[running.length - 1];
}

function findChild(
  supervisor: SubagentSupervisor,
  sessionId: string,
  childSessionId: string,
): ChildHandle | undefined {
  return supervisor
    .childrenOf(sessionId)
    .find((h) => h.sessionId === childSessionId);
}

/**
 * The management tool set. The worker registers these for every session; the
 * roster layer (CHILD_DENIED_TOOLS) removes dispatch_agent from child rosters,
 * and the supervisor refuses a child dispatch anyway (layer 3 backstop).
 */
export function createSubagentTools(deps: {
  supervisor: SubagentSupervisor;
  state: SessionStateStore;
  sink: EventSink;
}): Tool[] {
  const dispatchAgent: Tool = {
    spec: {
      name: "dispatch_agent",
      description:
        "Delegate a focused task to a child agent that runs in-process with " +
        "its own transcript and tools. It cannot see this chat's history: " +
        "include all needed context. The call waits for the child to finish " +
        "and returns its final report.",
      parameters: {
        type: "object",
        properties: {
          prompt: {
            type: "string",
            description: "Detailed task description for the subagent",
          },
          tools: {
            type: "array",
            items: { type: "string" },
            description:
              "Restrict the child to these tools. Sensitive tools (browser, " +
              "MCP/plugin servers, web fetch/search, repo sync, scheduling) " +
              "are denied to children unless named here explicitly. [CC] " +
              "names such as Read, Edit, Bash and MCP patterns are accepted.",
          },
          disallowedTools: {
            type: "array",
            items: { type: "string" },
            description:
              "Remove these tools from the child's inherited roster. [CC] " +
              "names and permission-rule specifiers are accepted.",
          },
          agentType: {
            type: "string",
            description:
              'Optional subagent definition/type to run (default: "general-purpose").',
          },
        },
        required: ["prompt"],
      },
    },
    timeoutMs: DISPATCH_AGENT_TIMEOUT_MS,
    async execute(args: Record<string, unknown>, ctx: ToolContext): Promise<ToolResult> {
      const prompt = argString(args, "prompt");
      if (prompt === "") return { content: "prompt is required", isError: true };
      const tools = argStrings(args, "tools");
      const disallowedTools = argStrings(args, "disallowedTools");
      const agentType = argString(args, "agentType");
      try {
        const handle = await deps.supervisor.dispatch(ctx, {
          prompt,
          ...(tools !== undefined ? { tools } : {}),
          ...(disallowedTools !== undefined ? { disallowedTools } : {}),
          ...(agentType !== "" ? { agentType } : {}),
        });
        // SI spec §9: the parent receives ONLY the strict ≤300-token JSON
        // summary — never the child's transcript or bare report text.
        return { content: subagentResultJson(handle) };
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        // Surface the typed discriminator to the caller as well as the copy:
        // the model can distinguish the ceiling/nesting/depth refusals without
        // parsing prose (the supervisor throws typed errors).
        const code = err instanceof SubagentRefusalError ? `${err.code}: ` : "";
        return {
          content: `${code}${message}`,
          isError: true,
        };
      }
    },
  };

  const sendMessage: Tool = {
    spec: {
      name: "send_message",
      description:
        "Send a running subagent a follow-up turn. Defaults to the newest " +
        "running child of this session when sessionId is omitted.",
      parameters: {
        type: "object",
        properties: {
          sessionId: {
            type: "string",
            description: "Child session id (list_agents shows them)",
          },
          text: { type: "string", description: "The follow-up message" },
        },
        required: ["text"],
      },
    },
    timeoutMs: 30_000,
    async execute(args: Record<string, unknown>, ctx: ToolContext): Promise<ToolResult> {
      const text = argString(args, "text");
      if (text === "") return { content: "message is required", isError: true };
      const explicit = argString(args, "sessionId");
      const handle =
        explicit !== ""
          ? findChild(deps.supervisor, ctx.sessionId, explicit)
          : newestRunning(deps.supervisor, ctx.sessionId);
      if (handle === undefined) {
        return {
          content:
            explicit !== ""
              ? `Subagent ${explicit} not found (list_agents shows active ids).`
              : "No active subagent to message.",
          isError: true,
        };
      }
      if (handle.status() !== "running") {
        return {
          content: `Subagent ${handle.sessionId} already finished.`,
          isError: true,
        };
      }
      await handle.sendMessage(text);
      return { content: `queued as the next turn for ${handle.sessionId}` };
    },
  };

  const interruptAgent: Tool = {
    spec: {
      name: "interrupt_agent",
      description:
        "Stop a running subagent and every descendant below it. Their " +
        "transcripts are kept so you (and the user) can still read what they did.",
      parameters: {
        type: "object",
        properties: {
          sessionId: {
            type: "string",
            description: "Child session id (defaults to the newest running child)",
          },
          reason: { type: "string", description: "Why the child is being stopped" },
        },
      },
    },
    timeoutMs: 30_000,
    async execute(args: Record<string, unknown>, ctx: ToolContext): Promise<ToolResult> {
      const explicit = argString(args, "sessionId");
      const reason = argString(args, "reason");
      const handle =
        explicit !== ""
          ? findChild(deps.supervisor, ctx.sessionId, explicit)
          : newestRunning(deps.supervisor, ctx.sessionId);
      if (handle === undefined) {
        return {
          content:
            explicit !== ""
              ? `Subagent ${explicit} not found.`
              : "No active subagent to interrupt.",
          isError: true,
        };
      }
      if (handle.status() !== "running") {
        return {
          content: `Subagent ${handle.sessionId} already finished.`,
          isError: true,
        };
      }
      const stopped = await handle.interrupt(reason !== "" ? reason : "interrupted by parent");
      return {
        content: stopped
          ? `interrupted subagent ${handle.sessionId} and its descendants — their transcripts are kept.`
          : `Subagent ${handle.sessionId} already finished.`,
        ...(stopped ? {} : { isError: true }),
      };
    },
  };

  const listAgents: Tool = {
    spec: {
      name: "list_agents",
      description:
        "List the subagents of this session with their status and task prompt.",
      parameters: {
        type: "object",
        properties: {},
      },
    },
    timeoutMs: 30_000,
    async execute(_args: Record<string, unknown>, ctx: ToolContext): Promise<ToolResult> {
      const children = deps.supervisor.childrenOf(ctx.sessionId);
      if (children.length === 0) {
        return { content: "No subagents dispatched (children)." };
      }
      const lines = [`Subagents (children, ${children.length}):`];
      for (const child of children) lines.push(renderChildLine(child));
      return { content: lines.join("\n") };
    },
  };

  const readSubagentLog: Tool = {
    spec: {
      name: READ_SUBAGENT_LOG_TOOL_NAME,
      description:
        "Read the tail of a subagent's append-only log: the task prompt, " +
        "tool calls with their outputs, lifecycle events and the final " +
        "result. MAIN AGENT ONLY. Returns the last 200 lines by default " +
        "(maximum 2,000) and says when earlier lines were omitted.",
      parameters: {
        type: "object",
        properties: {
          subagentId: {
            type: "string",
            description: "Child session id (list_agents shows them)",
          },
          tailLines: {
            type: "number",
            description:
              "How many trailing lines to return (default 200, maximum 2,000)",
          },
        },
        required: ["subagentId"],
      },
    },
    timeoutMs: 30_000,
    async execute(args: Record<string, unknown>, ctx: ToolContext): Promise<ToolResult> {
      // Same no-nesting guard as dispatch_agent: a subagent never reads
      // subagent logs (it cannot even see this tool in its roster).
      if (ctx.isSubagent || ctx.depth > 0) {
        return {
          content:
            "read_subagent_log is only available to the main agent — a " +
            "subagent cannot read subagent logs. Put what you found in your " +
            "report or final answer instead.",
          isError: true,
        };
      }
      const id = argString(args, "subagentId");
      if (id === "") return { content: "subagentId is required", isError: true };
      const child = findChild(deps.supervisor, ctx.sessionId, id);
      if (child === undefined) {
        return {
          content: `Subagent ${id} not found (list_agents shows ids).`,
          isError: true,
        };
      }
      // Bound at the tool boundary too: a replaced reader must never make
      // this result unbounded.
      const tailLines = clampSubagentLogTailLines(argNumber(args, "tailLines"));
      try {
        const tail = await deps.supervisor.readLog(child.sessionId, { tailLines });
        let lines = tail.lines;
        let truncated = tail.truncated;
        if (lines.length > tailLines) {
          lines = lines.slice(lines.length - tailLines);
          truncated = true;
        }
        if (lines.length === 0) {
          return { content: `Subagent ${child.sessionId} log is empty.` };
        }
        const body = lines.join("\n");
        const marker =
          truncated && !body.includes(SUBAGENT_LOG_TRUNCATION_MARKER)
            ? `\n${SUBAGENT_LOG_TRUNCATION_MARKER}`
            : "";
        const scope = truncated
          ? `last ${lines.length} lines, earlier lines omitted`
          : `${lines.length} lines`;
        return {
          content: `Subagent ${child.sessionId} log (${scope}):\n${body}${marker}`,
        };
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return {
          content: `Could not read the log of subagent ${child.sessionId}: ${message}`,
          isError: true,
        };
      }
    },
  };

  const report: Tool = {
    spec: {
      name: "report",
      description:
        "SUBAGENTS ONLY: send selected progress or findings from this " +
        "subagent to the parent agent as its next-step context. Your final " +
        "answer still goes back as the dispatch result.",
      parameters: {
        type: "object",
        properties: {
          summary: {
            type: "string",
            description: "The report text for the parent agent",
          },
        },
        required: ["summary"],
      },
    },
    timeoutMs: 30_000,
    async execute(args: Record<string, unknown>, ctx: ToolContext): Promise<ToolResult> {
      const summary = argString(args, "summary");
      if (summary === "") return { content: "report content is required", isError: true };
      if (!ctx.isSubagent) {
        return {
          content:
            "report is only available to subagents — this session is a " +
            "top-level chat. Put your findings in your final answer instead.",
          isError: true,
        };
      }
      const delivered = deps.supervisor.recordReport(ctx.sessionId, summary);
      if (!delivered) {
        return { content: "parent session is gone — report undelivered", isError: true };
      }
      await deps.sink.emit("system_note", { code: "report" });
      return { content: "Report delivered." };
    },
  };

  return [dispatchAgent, sendMessage, interruptAgent, listAgents, readSubagentLog, report];
}
