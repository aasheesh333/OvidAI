import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type {
  AgentEngine,
  SandboxPort,
  Tool,
  ToolContext,
  ToolResult,
} from "@ovid/agent-core";
import type { SandboxManager } from "@ovid/sandbox";
import { describe, expect, it } from "vitest";

import { createSandboxTools } from "../../../packages/agent-core/src/tools/sandboxTools.js";
import { createSandboxPort } from "./sandboxAdapter.js";

import {
  classifySubagentTool,
  closeSubagentAttempt,
  createSubagentObservationDecorators,
  type SubagentAssistantAnswerCapture,
  type SubagentObservationChannel,
  type SubagentObservationJournal,
  type SubagentObservationOperation,
  type SubagentObservationStore,
  type SubagentObservationTurn,
  type SubagentObservationTurnContext,
} from "./subagentObservations.js";

// Test-only in-memory port double, NOT the required durable journal. The
// production decorators below are exercised against this complete port shape.
class MemoryObservationStore implements SubagentObservationStore {
  readonly turns: SubagentObservationTurn[] = [];
  readonly operations: SubagentObservationOperation[] = [];
  readonly calls: string[] = [];
  private sequence = 0;
  private readonly closed = new Map<string, SubagentObservationJournal>();
  finishOperationFailure: Error | null = null;

  async beginTurn(input: {
    context: SubagentObservationTurnContext;
    assistantHighWater: string | null;
  }): Promise<void> {
    this.calls.push(`begin-turn:${input.context.attemptId}:${input.context.turnRunId}`);
    this.turns.push({ ...input, answer: null });
  }

  async contextForTurn(input: {
    childSessionId: string;
    turnRunId: string;
  }): Promise<SubagentObservationTurnContext | null> {
    const matches = this.turns.filter((turn) =>
      turn.context.childSessionId === input.childSessionId &&
      turn.context.turnRunId === input.turnRunId);
    if (matches.length > 1) throw new Error("ambiguous exact turn");
    return matches[0]?.context ?? null;
  }

  async beginOperation(input: {
    context: SubagentObservationTurnContext;
    channel: SubagentObservationChannel;
  }): Promise<{ operationId: string }> {
    const operationId = `operation-${++this.sequence}`;
    this.calls.push(`begin-operation:${operationId}`);
    this.operations.push({
      operationId,
      context: input.context,
      channel: input.channel,
      state: "open",
      evidence: null,
    });
    return { operationId };
  }

  async finishOperation(input: {
    context: SubagentObservationTurnContext;
    operationId: string;
    state: "succeeded" | "failed";
    evidence?: { kind: "file"; path: string } | { kind: "artifact"; artifactId: string };
  }): Promise<void> {
    this.calls.push(`finish-operation:${input.operationId}`);
    if (this.finishOperationFailure !== null) throw this.finishOperationFailure;
    const operation = this.operations.find((candidate) =>
      candidate.operationId === input.operationId &&
      candidate.context.attemptId === input.context.attemptId &&
      candidate.context.turnRunId === input.context.turnRunId);
    if (operation === undefined) throw new Error("unknown exact operation");
    operation.state = input.state;
    operation.evidence = input.evidence ?? null;
  }

  async finishTurn(input: {
    context: SubagentObservationTurnContext;
    capture: SubagentAssistantAnswerCapture;
  }): Promise<void> {
    const turn = this.turns.find((candidate) =>
      candidate.context.attemptId === input.context.attemptId &&
      candidate.context.turnRunId === input.context.turnRunId);
    if (turn === undefined) throw new Error("unknown exact turn");
    turn.answer = input.capture;
  }

  async closeAttempt(input: {
    attemptId: string;
    settlementTurnRunId: string;
  }): Promise<SubagentObservationJournal> {
    this.calls.push(`close:${input.attemptId}:${input.settlementTurnRunId}`);
    const key = `${input.attemptId}/${input.settlementTurnRunId}`;
    const existing = this.closed.get(key);
    if (existing !== undefined) return structuredClone(existing);
    const journal: SubagentObservationJournal = {
      attemptId: input.attemptId,
      settlementTurnRunId: input.settlementTurnRunId,
      turns: this.turns.filter((turn) => turn.context.attemptId === input.attemptId),
      operations: this.operations.filter((operation) =>
        operation.context.attemptId === input.attemptId),
    };
    const frozen = structuredClone(journal);
    this.closed.set(key, frozen);
    return structuredClone(frozen);
  }
}

class MemoryAssistantMessages {
  readonly rows: Array<{ messageId: string; content: string }> = [
    { messageId: "message-old", content: "earlier turn answer" },
  ];
  after: SubagentAssistantAnswerCapture | "throw" | null = null;

  async highWater(_childSessionId: string): Promise<string | null> {
    return this.rows.at(-1)?.messageId ?? null;
  }

  async readAfter(input: {
    childSessionId: string;
    afterMessageId: string | null;
  }): Promise<SubagentAssistantAnswerCapture> {
    if (this.after === "throw") throw new Error("assistant read failed");
    if (this.after !== null) return this.after;
    const boundary = input.afterMessageId === null
      ? -1
      : this.rows.findIndex((row) => row.messageId === input.afterMessageId);
    if (input.afterMessageId !== null && boundary < 0) return { state: "unknown" };
    const added = this.rows.slice(boundary + 1).filter((row) => row.content.trim() !== "");
    // One run has at most one final assistant row. Multiple new rows can be a
    // racing follow-up, so they are ambiguous rather than evidence for this run.
    if (added.length > 1) return { state: "unknown" };
    return { state: "ready", answer: added[0] ?? null };
  }
}

function runJob(runId: string, childSessionId = "child-1"): Parameters<AgentEngine["run"]>[0] {
  return {
    runId,
    sessionId: childSessionId,
    userId: "user-1",
    prompt: "do work",
    isSubagent: true,
    depth: 1,
  };
}

function toolContext(runId: string, childSessionId = "child-1"): ToolContext {
  return {
    sessionId: childSessionId,
    runId,
    userId: "user-1",
    mode: "auto",
    planMode: false,
    isSubagent: true,
    depth: 1,
    unattended: false,
    callKey: `${runId}:call-1`,
    signal: new AbortController().signal,
  };
}

function harness(attemptByRun: Record<string, string> = {
  "run-1": "attempt-1",
}) {
  const store = new MemoryObservationStore();
  const assistantMessages = new MemoryAssistantMessages();
  const decorators = createSubagentObservationDecorators({
    store,
    assistantMessages,
    contextForRun(job) {
      const attemptId = attemptByRun[job.runId];
      if (attemptId === undefined) throw new Error("missing admitted attempt mapping");
      return {
        attemptId,
        childSessionId: job.sessionId,
        turnRunId: job.runId,
      };
    },
  });
  return { assistantMessages, decorators, store };
}

function passiveEngine(): AgentEngine {
  return {
    async run() {},
    async cancel() { return false; },
    activeRun() { return null; },
  };
}

const REAL_NOTEBOOK = JSON.stringify({
  cells: [{
    cell_type: "code",
    id: "calc",
    metadata: {},
    execution_count: 3,
    outputs: [],
    source: ["print(1)"],
  }],
  metadata: {},
  nbformat: 4,
  nbformat_minor: 5,
});

function confinedNotebookTool(
  workspaceDir: string,
  captured: { result?: ToolResult },
): { port: SandboxPort; tool: Tool } {
  const manager = {
    attach: async () => ({ workspaceDir }),
  } as unknown as SandboxManager;
  const port = createSandboxPort(manager);
  const actual = createSandboxTools({ sandbox: port })
    .find((candidate) => candidate.spec.name === "notebook_edit");
  if (actual === undefined) throw new Error("actual notebook_edit tool is missing");
  return {
    port,
    tool: {
      ...actual,
      async execute(args, ctx) {
        const result = await actual.execute(args, ctx);
        captured.result = result;
        return result;
      },
    },
  };
}

async function expectNotebookCellTwo(path: string): Promise<void> {
  const parsed = JSON.parse(await readFile(path, "utf8")) as {
    cells: Array<{ id: string; source: string[] }>;
  };
  expect(parsed.cells.find((cell) => cell.id === "calc")?.source).toEqual(["print(2)"]);
}

// Authored RED before production observation code. All cases are UNEXECUTED.
describe("subagent observations (UNEXECUTED under pause; in-memory ports only)", () => {
  it("preserves the admitted attempt across follow-ups and captures only the settlement turn answer", async () => {
    const h = harness({
      "run-initial": "attempt-admitted",
      "run-follow-up": "attempt-admitted",
    });
    const engine = h.decorators.engine({
      ...passiveEngine(),
      run: async (job) => {
        h.assistantMessages.rows.push({
          messageId: `answer-${job.runId}`,
          content: `answer for ${job.runId}`,
        });
      },
    });
    await engine.run(runJob("run-initial"));
    await engine.run(runJob("run-follow-up"));
    const snapshot = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-admitted",
      settlementTurnRunId: "run-follow-up",
    });

    expect(snapshot).toEqual({
      status: "ready",
      attemptId: "attempt-admitted",
      settlementTurnRunId: "run-follow-up",
      answer: { messageId: "answer-run-follow-up", content: "answer for run-follow-up" },
      observedFiles: [],
      observedArtifacts: [],
    });
    expect(h.store.turns.map((turn) => turn.context.attemptId)).toEqual([
      "attempt-admitted",
      "attempt-admitted",
    ]);
    expect(h.store.turns.map((turn) => turn.assistantHighWater)).toEqual([
      "message-old",
      "answer-run-initial",
    ]);
  });

  it("finishes the after-boundary answer capture on a failed/partial engine path", async () => {
    const h = harness();
    const engine = h.decorators.engine({
      ...passiveEngine(),
      run: async () => {
        h.assistantMessages.rows.push({
          messageId: "answer-partial-failure",
          content: "partial answer before failure",
        });
        throw new Error("engine failed after partial answer");
      },
    });
    await expect(engine.run(runJob("run-1"))).rejects.toThrow("engine failed after partial answer");
    const snapshot = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
    });

    expect(snapshot).toEqual({
      status: "ready",
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
      answer: {
        messageId: "answer-partial-failure",
        content: "partial answer before failure",
      },
      observedFiles: [],
      observedArtifacts: [],
    });
  });

  it("writes each operation ahead of the actual sandbox side effect and finishes after success", async () => {
    const actual: string[] = [];
    const h = harness();
    const sandbox: SandboxPort = {
      async exec() { return { exitCode: 0, stdout: "", stderr: "" }; },
      async killCall() {},
      async readFile() { return ""; },
      async writeFile(_userId, path) {
        actual.push(`write:${path}`);
        h.store.calls.push(`side-effect:${path}`);
      },
      async exists() { return false; },
      async listDir() { return []; },
      async jobStart() { return { jobId: "job-1" }; },
      async jobOutput() { return { output: "", running: false, exitCode: 0 }; },
      async jobList() { return []; },
      async jobKill() {},
    };
    const observedSandbox = h.decorators.sandbox(sandbox);
    const engine = h.decorators.engine({
      ...passiveEngine(),
      run: async () => {
        h.assistantMessages.rows.push({ messageId: "answer-new", content: "done" });
        await observedSandbox.writeFile("user-1", "src/actual.ts", "content");
      },
    });
    await engine.run(runJob("run-1"));
    const snapshot = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
    });

    expect(snapshot).toMatchObject({
      status: "ready",
      observedFiles: ["src/actual.ts"],
      observedArtifacts: [],
    });
    const operationId = h.store.operations[0]!.operationId;
    expect(h.store.calls).toEqual([
      "begin-turn:attempt-1:run-1",
      `begin-operation:${operationId}`,
      "side-effect:src/actual.ts",
      `finish-operation:${operationId}`,
      "close:attempt-1:run-1",
    ]);
    expect(actual).toEqual(["write:src/actual.ts"]);
    expect(h.store.calls.indexOf(`begin-operation:${operationId}`))
      .toBeLessThan(h.store.calls.indexOf(`finish-operation:${operationId}`));
  });

  it("leaves a crash after the side effect but before finish as unknown_final", async () => {
    const writes: string[] = [];
    const sandbox = {
      async writeFile(_userId: string, path: string) {
        writes.push(path);
        throw new Error("crash after real write before finish");
      },
    } as unknown as SandboxPort;
    const h = harness();
    const observedSandbox = h.decorators.sandbox(sandbox);
    const engine = h.decorators.engine({
      ...passiveEngine(),
      run: async () => {
        await observedSandbox.writeFile("user-1", "src/side-effect-happened.ts", "x");
      },
    });
    await expect(engine.run(runJob("run-1"))).rejects.toThrow("crash after real write");
    const snapshot = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
    });

    expect(writes).toEqual(["src/side-effect-happened.ts"]);
    expect(h.store.operations[0]).toMatchObject({ state: "open", evidence: null });
    expect(snapshot.status).toBe("unknown_final");
    expect(snapshot).not.toHaveProperty("observedFiles");
    expect(snapshot).not.toHaveProperty("observedArtifacts");
    if (snapshot.status === "unknown_final") {
      expect(snapshot.reasons).toContain("open_operation");
    }
  });

  it("keeps shell and other unclassified channels unknown without inferring paths from command or result prose", async () => {
    const shell: Tool = {
      spec: { name: "run_shell", description: "shell", parameters: {} },
      timeoutMs: 1_000,
      async execute() {
        return { content: "wrote imaginary.ts and artifact-imagined", isError: false };
      },
    };
    const h = harness();
    const observedShell = h.decorators.tool(shell);
    const engine = h.decorators.engine({
      ...passiveEngine(),
      run: async () => {
        h.assistantMessages.rows.push({ messageId: "answer-shell", content: "shell done" });
        await observedShell.execute({ command: "cp one imaginary.ts" }, toolContext("run-1"));
      },
    });
    await engine.run(runJob("run-1"));
    const snapshot = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
    });

    expect(snapshot.status).toBe("unknown_final");
    expect(snapshot).not.toHaveProperty("observedFiles");
    expect(snapshot).not.toHaveProperty("observedArtifacts");
    if (snapshot.status === "unknown_final") {
      expect(snapshot.reasons).toContain("unsupported_channel");
    }
  });

  it("classifies known direct writes and reads but defaults every other channel to unknown", () => {
    expect(classifySubagentTool("file_write", { path: "a.ts" })).toEqual({
      kind: "direct_file_write",
      path: "a.ts",
    });
    expect(classifySubagentTool("notebook_edit", { notebook_path: "analysis.ipynb" }))
      .toEqual({ kind: "direct_file_write", path: "analysis.ipynb" });
    expect(classifySubagentTool("fs_edit", { command: "view", path: "a.ts" }))
      .toEqual({ kind: "read_only" });
    expect(classifySubagentTool("file_read", { path: "a.ts" }))
      .toEqual({ kind: "read_only" });
    expect(classifySubagentTool("run_shell", {})).toEqual({
      kind: "unsupported",
      channel: "shell",
    });
    expect(classifySubagentTool("job_start", {})).toEqual({
      kind: "unsupported",
      channel: "job",
    });
    expect(classifySubagentTool("run_code", {})).toEqual({
      kind: "unsupported",
      channel: "run_code",
    });
    expect(classifySubagentTool("mcp__github__write", {})).toEqual({
      kind: "unsupported",
      channel: "mcp",
    });
    expect(classifySubagentTool("git_push", {})).toEqual({
      kind: "unsupported",
      channel: "git",
    });
    expect(classifySubagentTool("browser_click", {})).toEqual({
      kind: "unsupported",
      channel: "browser",
    });
    expect(classifySubagentTool("generate_image", {})).toEqual({
      kind: "unsupported",
      channel: "image",
    });
    expect(classifySubagentTool("unclassified_future_mutation", {})).toEqual({
      kind: "unsupported",
      channel: "unknown",
    });
  });

  it("records a direct tool path only after actual success, not from result prose", async () => {
    const writeTool: Tool = {
      spec: { name: "file_write", description: "write", parameters: {} },
      timeoutMs: 1_000,
      async execute() {
        return { content: "wrote imaginary.ts", isError: false };
      },
    };
    const h = harness();
    const observedWrite = h.decorators.tool(writeTool);
    const engine = h.decorators.engine({
      ...passiveEngine(),
      run: async () => {
        h.assistantMessages.rows.push({ messageId: "answer-write", content: "write done" });
        await observedWrite.execute({ path: "src/actual-tool-write.ts" }, toolContext("run-1"));
      },
    });
    await engine.run(runJob("run-1"));
    const snapshot = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
    });

    expect(snapshot).toMatchObject({
      status: "ready",
      observedFiles: ["src/actual-tool-write.ts"],
      observedArtifacts: [],
    });
  });

  it("preserves the actual notebook_edit confined-write result and records notebook_path", async () => {
    const workspaceDir = await mkdtemp(join(tmpdir(), "ovid-observation-notebook-"));
    try {
      const captured: { result?: ToolResult } = {};
      const { port, tool } = confinedNotebookTool(workspaceDir, captured);
      await port.writeFile("user-1", "analysis.ipynb", REAL_NOTEBOOK);
      const h = harness();
      const observedNotebook = h.decorators.tool(tool);
      let returned: ToolResult | undefined;
      const engine = h.decorators.engine({
        ...passiveEngine(),
        run: async () => {
          h.assistantMessages.rows.push({ messageId: "answer-notebook", content: "notebook done" });
          returned = await observedNotebook.execute({
            notebook_path: "analysis.ipynb",
            cell_id: "calc",
            new_source: "print(2)",
          }, toolContext("run-1"));
        },
      });
      await engine.run(runJob("run-1"));
      const snapshot = await closeSubagentAttempt(h.store, {
        attemptId: "attempt-1",
        settlementTurnRunId: "run-1",
      });

      expect(returned).toBe(captured.result);
      expect(captured.result).toEqual({
        content: "notebook analysis.ipynb updated (replace)",
        isError: false,
      });
      await expectNotebookCellTwo(join(workspaceDir, "analysis.ipynb"));
      expect(h.store.operations[0]).toMatchObject({
        channel: "direct_file_write",
        state: "succeeded",
        evidence: { kind: "file", path: "analysis.ipynb" },
      });
      expect(snapshot).toEqual({
        status: "ready",
        attemptId: "attempt-1",
        settlementTurnRunId: "run-1",
        answer: { messageId: "answer-notebook", content: "notebook done" },
        observedFiles: ["analysis.ipynb"],
        observedArtifacts: [],
      });
    } finally {
      await rm(workspaceDir, { recursive: true, force: true });
    }
  });

  it("preserves a legal whitespace notebook path result and leaves unrepresentable evidence unknown", async () => {
    const workspaceDir = await mkdtemp(join(tmpdir(), "ovid-observation-whitespace-notebook-"));
    try {
      const captured: { result?: ToolResult } = {};
      const { port, tool } = confinedNotebookTool(workspaceDir, captured);
      await port.writeFile("user-1", " ", REAL_NOTEBOOK);
      const h = harness();
      const observedNotebook = h.decorators.tool(tool);
      let returned: ToolResult | undefined;
      const engine = h.decorators.engine({
        ...passiveEngine(),
        run: async () => {
          h.assistantMessages.rows.push({ messageId: "answer-whitespace", content: "whitespace done" });
          returned = await observedNotebook.execute({
            notebook_path: " ",
            cell_id: "calc",
            new_source: "print(2)",
          }, toolContext("run-1"));
        },
      });
      await engine.run(runJob("run-1"));
      const snapshot = await closeSubagentAttempt(h.store, {
        attemptId: "attempt-1",
        settlementTurnRunId: "run-1",
      });

      expect(returned).toBe(captured.result);
      expect(captured.result).toEqual({
        content: "notebook   updated (replace)",
        isError: false,
      });
      await expectNotebookCellTwo(join(workspaceDir, " "));
      expect(h.store.operations[0]).toMatchObject({
        channel: "direct_file_write",
        state: "open",
        evidence: null,
      });
      expect(snapshot.status).toBe("unknown_final");
      expect(snapshot).not.toHaveProperty("observedFiles");
      expect(snapshot).not.toHaveProperty("observedArtifacts");
      if (snapshot.status === "unknown_final") {
        expect(snapshot.reasons).toContain("open_operation");
      }
    } finally {
      await rm(workspaceDir, { recursive: true, force: true });
    }
  });

  it("records a committed artifact's returned ID, never the input name or result prose", async () => {
    const h = harness();
    const publisher = h.decorators.artifactPublisher(async (input: {
      sessionId: string;
      name: string;
    }) => ({ id: "artifact-actually-registered", name: input.name }));
    const engine = h.decorators.engine({
      ...passiveEngine(),
      run: async (job) => {
        h.assistantMessages.rows.push({ messageId: "answer-artifact", content: "artifact done" });
        await publisher({ sessionId: job.sessionId, name: "claimed-artifact-name" });
      },
    });
    await engine.run(runJob("run-1"));
    const snapshot = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
    });

    expect(snapshot).toMatchObject({
      status: "ready",
      observedFiles: [],
      observedArtifacts: ["artifact-actually-registered"],
    });
  });

  it("permits empty arrays only after complete no-write coverage and an exact answer capture", async () => {
    const h = harness();
    const engine = h.decorators.engine({
      ...passiveEngine(),
      run: async () => {
        h.assistantMessages.rows.push({ messageId: "answer-no-write", content: "read only" });
      },
    });
    await engine.run(runJob("run-1"));
    const ready = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
    });
    expect(ready).toMatchObject({ observedFiles: [], observedArtifacts: [] });

    const unknownStore = new MemoryObservationStore();
    unknownStore.turns.push({
      context: {
        attemptId: "attempt-unfinished",
        childSessionId: "child-1",
        turnRunId: "run-unfinished",
      },
      assistantHighWater: "message-old",
      answer: null,
    });
    const unknown = await closeSubagentAttempt(unknownStore, {
      attemptId: "attempt-unfinished",
      settlementTurnRunId: "run-unfinished",
    });
    expect(unknown.status).toBe("unknown_final");
    expect(unknown).not.toHaveProperty("observedFiles");
  });

  it("marks an unfinished answer capture unknown instead of reusing an earlier answer", async () => {
    const h = harness();
    h.assistantMessages.after = { state: "unknown" };
    const engine = h.decorators.engine(passiveEngine());
    await engine.run(runJob("run-1"));
    const snapshot = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
    });

    expect(snapshot.status).toBe("unknown_final");
    if (snapshot.status === "unknown_final") {
      expect(snapshot.reasons).toContain("answer_unknown");
    }
  });

  it("does not select a racing follow-up answer when multiple new assistant rows cross the boundary", async () => {
    const h = harness();
    const engine = h.decorators.engine({
      ...passiveEngine(),
      run: async () => {
        h.assistantMessages.rows.push(
          { messageId: "answer-this-run", content: "this run" },
          { messageId: "answer-racing-follow-up", content: "racing follow-up" },
        );
      },
    });
    await engine.run(runJob("run-1"));
    const snapshot = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
    });

    expect(snapshot.status).toBe("unknown_final");
    if (snapshot.status === "unknown_final") {
      expect(snapshot.reasons).toContain("answer_unknown");
    }
  });

  it("preserves every successful boundary result and leaves operations open when post-write finish fails", async () => {
    const directResult = { content: "direct write succeeded", isError: false };
    const unknownResult = { content: "unknown channel completed", isError: false };
    const artifactRecord = { id: "artifact-committed", name: "actual.txt" };
    const directTool: Tool = {
      spec: { name: "file_write", description: "write", parameters: {} },
      timeoutMs: 1_000,
      async execute() { return directResult; },
    };
    const unknownTool: Tool = {
      spec: { name: "run_shell", description: "shell", parameters: {} },
      timeoutMs: 1_000,
      async execute() { return unknownResult; },
    };
    const sandbox = {
      async writeFile() {},
    } as unknown as SandboxPort;
    const h = harness();
    h.store.finishOperationFailure = new Error("finish journal unavailable after side effect");
    const observedDirect = h.decorators.tool(directTool);
    const observedUnknown = h.decorators.tool(unknownTool);
    const observedSandbox = h.decorators.sandbox(sandbox);
    const publisher = h.decorators.artifactPublisher(async (_input: { sessionId: string }) => artifactRecord);
    let directReturned: ToolResult | undefined;
    let unknownReturned: ToolResult | undefined;
    let artifactReturned: { id: string; name: string } | undefined;
    const engine = h.decorators.engine({
      ...passiveEngine(),
      run: async () => {
        h.assistantMessages.rows.push({ messageId: "answer-finish-fault", content: "all effects done" });
        directReturned = await observedDirect.execute({ path: "actual.ts" }, toolContext("run-1"));
        unknownReturned = await observedUnknown.execute({ command: "true" }, toolContext("run-1"));
        await observedSandbox.writeFile("user-1", "sandbox.ts", "content");
        artifactReturned = await publisher({ sessionId: "child-1" });
      },
    });
    await engine.run(runJob("run-1"));
    const snapshot = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
    });

    expect(directReturned).toBe(directResult);
    expect(unknownReturned).toBe(unknownResult);
    expect(artifactReturned).toBe(artifactRecord);
    expect(h.store.operations).toHaveLength(4);
    expect(h.store.operations.every((operation) =>
      operation.state === "open" && operation.evidence === null)).toBe(true);
    expect(snapshot.status).toBe("unknown_final");
    expect(snapshot).not.toHaveProperty("observedFiles");
    expect(snapshot).not.toHaveProperty("observedArtifacts");
    if (snapshot.status === "unknown_final") {
      expect(snapshot.reasons).toContain("open_operation");
    }
  });

  it("does not throw after successful sandbox/publisher boundaries with unrepresentable evidence", async () => {
    const artifactRecord = { id: "   ", name: "blank-id.txt" };
    const h = harness();
    const observedSandbox = h.decorators.sandbox({
      async writeFile() {},
    } as unknown as SandboxPort);
    const publisher = h.decorators.artifactPublisher(async (_input: { sessionId: string }) => artifactRecord);
    let artifactReturned: { id: string; name: string } | undefined;
    const engine = h.decorators.engine({
      ...passiveEngine(),
      run: async () => {
        h.assistantMessages.rows.push({ messageId: "answer-unrepresentable", content: "effects done" });
        await observedSandbox.writeFile("user-1", " ", "content");
        artifactReturned = await publisher({ sessionId: "child-1" });
      },
    });
    await engine.run(runJob("run-1"));
    const snapshot = await closeSubagentAttempt(h.store, {
      attemptId: "attempt-1",
      settlementTurnRunId: "run-1",
    });

    expect(artifactReturned).toBe(artifactRecord);
    expect(h.store.operations).toHaveLength(2);
    expect(h.store.operations.every((operation) =>
      operation.state === "open" && operation.evidence === null)).toBe(true);
    expect(snapshot.status).toBe("unknown_final");
    expect(snapshot).not.toHaveProperty("observedFiles");
    expect(snapshot).not.toHaveProperty("observedArtifacts");
  });

  it("does not reopen a closed final snapshot when a late producer finishes its journal operation", async () => {
    const store = new MemoryObservationStore();
    const context: SubagentObservationTurnContext = {
      attemptId: "attempt-close",
      childSessionId: "child-close",
      turnRunId: "run-close",
    };
    await store.beginTurn({ context, assistantHighWater: null });
    const operation = await store.beginOperation({ context, channel: "direct_file_write" });
    await store.finishTurn({
      context,
      capture: { state: "ready", answer: null },
    });
    const first = await closeSubagentAttempt(store, {
      attemptId: context.attemptId,
      settlementTurnRunId: context.turnRunId,
    });
    expect(first.status).toBe("unknown_final");

    await store.finishOperation({
      context,
      operationId: operation.operationId,
      state: "succeeded",
      evidence: { kind: "file", path: "late.ts" },
    });
    const replay = await closeSubagentAttempt(store, {
      attemptId: context.attemptId,
      settlementTurnRunId: context.turnRunId,
    });
    expect(replay).toEqual(first);
    expect(replay.status).toBe("unknown_final");
  });
});
