import { describe, expect, it, vi } from "vitest";

import type { Tool, ToolContext as CoreToolContext } from "@ovid/agent-core";
import type { ExecRequest, ExecResult, SandboxHandle } from "@ovid/sandbox";
import type { SessionEventType } from "@ovid/shared";

import { adaptAgentTool, adaptAgentTools } from "./agentToolAdapter.js";
import { createRunShellTool } from "./shellTool.js";
import type { AgentTool, ToolContext as P2ToolContext } from "./types.js";

/**
 * R1/R2: P2's six landed tools are NOT re-implemented — this adapter is how the
 * P2 roster joins the canonical seam. P2's ToolContext only gains ADDITIVE
 * optional fields (callKey/signal/mode/planMode) so its own tests are
 * unaffected.
 */

const coreCtx = (): CoreToolContext => ({
  sessionId: "s1",
  runId: "r1",
  userId: "u1",
  mode: "auto",
  planMode: false,
  isSubagent: false,
  depth: 0,
  unattended: false,
  callKey: "toolcall-9",
  signal: new AbortController().signal,
});

function fakeHandle(execResult?: Partial<ExecResult>) {
  const execCalls: ExecRequest[] = [];
  const handle: SandboxHandle = {
    userId: "u1",
    uid: 1000,
    workspaceDir: "/tmp/unused",
    homeDir: "/tmp/unused",
    jailWorkspaceDir: "/workspace",
    exec: async (req: ExecRequest) => {
      execCalls.push(req);
      return {
        exitCode: 0,
        stdout: "hi",
        stderr: "",
        timedOut: false,
        truncated: false,
        blocked: false,
        refusal: null,
        ...execResult,
      };
    },
    createPty: async () => {
      throw new Error("not used");
    },
    getPty: () => undefined,
    jobs: {} as never,
    spawnProcess: async () => {
      throw new Error("not used");
    },
    destroy: async () => {},
  } as SandboxHandle;
  return { handle, execCalls };
}

function recordingTool(name: string) {
  const seen: Array<{ input: unknown; ctx: P2ToolContext }> = [];
  const tool: AgentTool = {
    name,
    description: "a fake P2 tool",
    parameters: { type: "object", properties: { a: { type: "string" } }, required: ["a"] },
    async execute(input, ctx) {
      seen.push({ input, ctx });
      return { content: "did it", isError: false };
    },
  };
  return { tool, seen };
}

describe("adaptAgentTool", () => {
  it("carries the AgentTool's own fields into the canonical spec", () => {
    const { handle } = fakeHandle();
    const { tool } = recordingTool("read_file");
    const adapted = adaptAgentTool(tool, { sandbox: handle, emitEvent: async () => {} });
    expect(adapted.spec).toEqual({
      name: "read_file",
      description: "a fake P2 tool",
      parameters: { type: "object", properties: { a: { type: "string" } }, required: ["a"] },
    });
  });

  it("timeoutMs is the tool's own clamp (run_shell 600s) else 120s", () => {
    const { handle } = fakeHandle();
    const emit = async () => {};
    expect(adaptAgentTool(recordingTool("run_shell").tool, { sandbox: handle, emitEvent: emit }).timeoutMs).toBe(600_000);
    expect(adaptAgentTool(recordingTool("grep_files").tool, { sandbox: handle, emitEvent: emit }).timeoutMs).toBe(120_000);
  });

  it("passes args through and bridges the canonical ctx onto P2's, with the additive fields", async () => {
    const { handle } = fakeHandle();
    const emit = vi.fn(async (_type: SessionEventType, _payload: Record<string, unknown>) => {});
    const { tool, seen } = recordingTool("read_file");
    const adapted = adaptAgentTool(tool, { sandbox: handle, emitEvent: emit });

    const args = { a: "x" };
    const ctx = coreCtx();
    const res = await adapted.execute(args, ctx);

    expect(seen).toHaveLength(1);
    expect(seen[0].input).toBe(args);
    const bridged = seen[0].ctx;
    expect(bridged.sandbox).toBe(handle);
    expect(bridged.userId).toBe("u1");
    expect(bridged.sessionId).toBe("s1");
    expect(bridged.runId).toBe("r1");
    expect(bridged.emitEvent).toBe(emit);
    // additive fields thread the canonical ctx through
    expect(bridged.callKey).toBe("toolcall-9");
    expect(bridged.signal).toBe(ctx.signal);
    expect(bridged.mode).toBe("auto");
    expect(bridged.planMode).toBe(false);

    expect(res.content).toBe("did it");
    expect(res.isError).toBe(false);
    expect(res.artifacts).toBeUndefined();
  });

  it("an isError P2 result passes through as a canonical isError result", async () => {
    const { handle } = fakeHandle();
    const tool: AgentTool = {
      name: "write_file",
      description: "d",
      parameters: { type: "object" },
      async execute() {
        return { content: "confined: nope is outside the workspace", isError: true };
      },
    };
    const res = await adaptAgentTool(tool, { sandbox: handle, emitEvent: async () => {} }).execute(
      {},
      coreCtx(),
    );
    expect(res).toEqual({
      content: "confined: nope is outside the workspace",
      isError: true,
    });
    expect(res.artifacts).toBeUndefined();
  });
});

describe("adaptAgentTools — the P2 roster joins the canonical seam", () => {
  it("adapts a real P2 tool end to end (run_shell) with callKey threading", async () => {
    const { handle, execCalls } = fakeHandle();
    const emit = vi.fn(async (_type: SessionEventType, _payload: Record<string, unknown>) => {});
    const adapted = adaptAgentTools([createRunShellTool()], { sandbox: handle, emitEvent: emit });

    expect(adapted).toHaveLength(1);
    const runShell: Tool = adapted[0];
    expect(runShell.spec.name).toBe("run_shell");
    expect(runShell.timeoutMs).toBe(600_000);

    const res = await runShell.execute({ command: "echo hi" }, coreCtx());
    expect(execCalls).toHaveLength(1);
    expect(res.content).toContain("hi");
    expect(res.content).toContain("[exit 0]");
    expect(res.isError).toBe(false);
  });

  it("a blocked command returns the pinned refusal and never spawns", async () => {
    const { handle, execCalls } = fakeHandle();
    const emit = vi.fn(async (_type: SessionEventType, _payload: Record<string, unknown>) => {});
    const [runShell] = adaptAgentTools([createRunShellTool()], { sandbox: handle, emitEvent: emit });
    const res = await runShell.execute({ command: "gradle assembleDebug" }, coreCtx());
    expect(execCalls).toEqual([]);
    expect(res.isError).toBe(true);
    expect(res.content).toContain("disabled on live cloud workspaces");
    expect(emit).toHaveBeenCalledWith(
      "system_note",
      expect.objectContaining({ code: "command_blocked" }),
    );
  });
});
