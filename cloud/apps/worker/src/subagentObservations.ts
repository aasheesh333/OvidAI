import { AsyncLocalStorage } from "node:async_hooks";

import type {
  AgentEngine,
  SandboxPort,
  Tool,
  ToolContext,
} from "@ovid/agent-core";

/** Exact admitted attempt and exact current turn; never a newest-attempt lookup. */
export interface SubagentObservationTurnContext {
  attemptId: string;
  childSessionId: string;
  turnRunId: string;
}

export type SubagentObservationChannel =
  | "direct_file_write"
  | "artifact_registration"
  | "shell"
  | "job"
  | "run_code"
  | "mcp"
  | "git"
  | "browser"
  | "image"
  | "unknown";

export type SubagentToolObservation =
  | { kind: "read_only" }
  | { kind: "direct_file_write"; path: string }
  | { kind: "unsupported"; channel: Exclude<SubagentObservationChannel, "direct_file_write" | "artifact_registration"> };

export interface SubagentAssistantAnswer {
  messageId: string;
  content: string;
}

export type SubagentAssistantAnswerCapture =
  | { state: "ready"; answer: SubagentAssistantAnswer | null }
  | { state: "unknown" };

export interface SubagentAssistantMessageStore {
  /** Latest assistant message reference before this exact run starts. */
  highWater(childSessionId: string): Promise<string | null>;
  /**
   * Only new assistant answers after that boundary; an old answer is not a
   * fallback. Zero new answers is known null; more than one is ambiguous and
   * must return unknown rather than selecting a racing follow-up's answer.
   */
  readAfter(input: {
    childSessionId: string;
    afterMessageId: string | null;
  }): Promise<SubagentAssistantAnswerCapture>;
}

export interface SubagentObservationTurn {
  context: SubagentObservationTurnContext;
  assistantHighWater: string | null;
  /** Null means the after-boundary capture has not finished. */
  answer: SubagentAssistantAnswerCapture | null;
}

export type SubagentOperationEvidence =
  | { kind: "file"; path: string }
  | { kind: "artifact"; artifactId: string };

export interface SubagentObservationOperation {
  operationId: string;
  context: SubagentObservationTurnContext;
  channel: SubagentObservationChannel;
  state: "open" | "succeeded" | "failed";
  evidence: SubagentOperationEvidence | null;
}

export interface SubagentObservationJournal {
  attemptId: string;
  settlementTurnRunId: string;
  turns: readonly SubagentObservationTurn[];
  operations: readonly SubagentObservationOperation[];
}

/**
 * Durable-store contract only. A production implementation must make
 * closeAttempt atomic and retain the closed snapshot; late operation finishes
 * may complete their journal rows but must not reopen/change that snapshot.
 * No table or SQL shape is assumed by this unwired Phase A0 module.
 */
export interface SubagentObservationStore {
  beginTurn(input: {
    context: SubagentObservationTurnContext;
    assistantHighWater: string | null;
  }): Promise<void>;
  contextForTurn(input: {
    childSessionId: string;
    turnRunId: string;
  }): Promise<SubagentObservationTurnContext | null>;
  beginOperation(input: {
    context: SubagentObservationTurnContext;
    channel: SubagentObservationChannel;
  }): Promise<{ operationId: string }>;
  finishOperation(input: {
    context: SubagentObservationTurnContext;
    operationId: string;
    state: "succeeded" | "failed";
    evidence?: SubagentOperationEvidence;
  }): Promise<void>;
  finishTurn(input: {
    context: SubagentObservationTurnContext;
    capture: SubagentAssistantAnswerCapture;
  }): Promise<void>;
  closeAttempt(input: {
    attemptId: string;
    settlementTurnRunId: string;
  }): Promise<SubagentObservationJournal>;
}

export type SubagentObservationUnknownReason =
  | "journal_inconsistent"
  | "settlement_turn_missing"
  | "open_turn"
  | "answer_unknown"
  | "open_operation"
  | "operation_failed"
  | "unsupported_channel"
  | "evidence_missing";

export type SubagentObservationFinal =
  | {
      status: "ready";
      attemptId: string;
      settlementTurnRunId: string;
      answer: SubagentAssistantAnswer | null;
      observedFiles: string[];
      observedArtifacts: string[];
    }
  | {
      status: "unknown_final";
      attemptId: string;
      settlementTurnRunId: string;
      reasons: SubagentObservationUnknownReason[];
    };

const READ_ONLY_TOOLS = new Set([
  "file_read",
  "read_file",
  "fs_glob",
  "fs_grep",
  "glob_files",
  "grep_files",
  "read_image",
  "git_status",
  "git_diff",
  "git_log",
  "web_search",
  "fetch_url",
  "memory_search",
  "session_search",
  "session_read",
  "job_output",
  "job_list",
  "list_agents",
]);
const DIRECT_WRITE_TOOLS = new Set([
  "file_write",
  "write_file",
  "edit_file",
  "multi_edit",
  "notebook_edit",
]);

function pathArgument(
  name: string,
  args: Record<string, unknown>,
): string {
  const value = name === "notebook_edit"
    ? args.notebook_path
    : args.path ?? args.file ?? args.file_path;
  return typeof value === "string" ? value : "";
}

/** Classify by tool boundary only. Never inspect shell/result/answer prose. */
export function classifySubagentTool(
  name: string,
  args: Record<string, unknown>,
): SubagentToolObservation {
  if (name === "fs_edit") {
    return args.command === "view"
      ? { kind: "read_only" }
      : { kind: "direct_file_write", path: pathArgument(name, args) };
  }
  if (DIRECT_WRITE_TOOLS.has(name)) {
    return { kind: "direct_file_write", path: pathArgument(name, args) };
  }
  if (READ_ONLY_TOOLS.has(name)) return { kind: "read_only" };
  if (name === "run_shell") return { kind: "unsupported", channel: "shell" };
  if (name === "job_start" || name === "job_kill") {
    return { kind: "unsupported", channel: "job" };
  }
  if (name === "run_code") return { kind: "unsupported", channel: "run_code" };
  if (name.startsWith("mcp__") || name.startsWith("mcp_")) {
    return { kind: "unsupported", channel: "mcp" };
  }
  if (name.startsWith("git_")) return { kind: "unsupported", channel: "git" };
  if (name.startsWith("browser_")) return { kind: "unsupported", channel: "browser" };
  if (name === "generate_image" || name === "edit_image") {
    return { kind: "unsupported", channel: "image" };
  }
  return { kind: "unsupported", channel: "unknown" };
}

function unique(values: readonly string[]): string[] {
  return [...new Set(values)];
}

/** Pure close projection. Unknown is the default; [] requires full coverage. */
export function finalizeSubagentObservation(
  journal: SubagentObservationJournal,
): SubagentObservationFinal {
  const reasons = new Set<SubagentObservationUnknownReason>();
  const turns = journal.turns.filter((turn) => {
    if (turn.context.attemptId !== journal.attemptId) {
      reasons.add("journal_inconsistent");
      return false;
    }
    return true;
  });
  const operations = journal.operations.filter((operation) => {
    if (operation.context.attemptId !== journal.attemptId) {
      reasons.add("journal_inconsistent");
      return false;
    }
    return true;
  });
  const settlementTurns = turns.filter((turn) =>
    turn.context.turnRunId === journal.settlementTurnRunId);
  const settlementTurn = settlementTurns[0];
  if (settlementTurn === undefined) reasons.add("settlement_turn_missing");
  if (settlementTurns.length > 1) reasons.add("journal_inconsistent");
  for (const turn of turns) {
    if (turn.context.childSessionId.trim() === "") reasons.add("journal_inconsistent");
    if (turn.answer === null) reasons.add("open_turn");
  }
  const knownTurns = new Map(turns.map((turn) => [turn.context.turnRunId, turn.context]));
  for (const operation of operations) {
    const turn = knownTurns.get(operation.context.turnRunId);
    if (turn === undefined || turn.childSessionId !== operation.context.childSessionId) {
      reasons.add("journal_inconsistent");
    }
  }
  if (settlementTurn !== undefined && settlementTurn.answer?.state !== "ready") {
    reasons.add("answer_unknown");
  }

  const files: string[] = [];
  const artifacts: string[] = [];
  for (const operation of operations) {
    if (operation.state === "open") reasons.add("open_operation");
    if (operation.state === "failed") reasons.add("operation_failed");
    if (operation.channel !== "direct_file_write" &&
      operation.channel !== "artifact_registration") {
      reasons.add("unsupported_channel");
      continue;
    }
    if (operation.state !== "succeeded") continue;
    if (operation.channel === "direct_file_write") {
      if (operation.evidence?.kind !== "file" || operation.evidence.path.trim() === "") {
        reasons.add("evidence_missing");
      } else {
        files.push(operation.evidence.path);
      }
    } else if (operation.evidence?.kind !== "artifact" ||
      operation.evidence.artifactId.trim() === "") {
      reasons.add("evidence_missing");
    } else {
      artifacts.push(operation.evidence.artifactId);
    }
  }

  if (reasons.size > 0) {
    return {
      status: "unknown_final",
      attemptId: journal.attemptId,
      settlementTurnRunId: journal.settlementTurnRunId,
      reasons: [...reasons].sort(),
    };
  }
  // The checks above make this exhaustive without substituting an older answer.
  if (settlementTurn?.answer?.state !== "ready") {
    return {
      status: "unknown_final",
      attemptId: journal.attemptId,
      settlementTurnRunId: journal.settlementTurnRunId,
      reasons: ["answer_unknown"],
    };
  }
  return {
    status: "ready",
    attemptId: journal.attemptId,
    settlementTurnRunId: journal.settlementTurnRunId,
    answer: settlementTurn.answer.answer,
    observedFiles: unique(files),
    observedArtifacts: unique(artifacts),
  };
}

/** Store I/O failures remain infrastructure failures; they are not unknown coverage. */
export async function closeSubagentAttempt(
  store: SubagentObservationStore,
  input: { attemptId: string; settlementTurnRunId: string },
): Promise<SubagentObservationFinal> {
  if (input.attemptId.trim() === "" || input.settlementTurnRunId.trim() === "") {
    throw new Error("Exact attempt and settlement turn are required");
  }
  const journal = await store.closeAttempt(input);
  if (journal.attemptId !== input.attemptId ||
    journal.settlementTurnRunId !== input.settlementTurnRunId) {
    throw new Error("Closed observation journal identity mismatch");
  }
  return finalizeSubagentObservation(journal);
}

export interface SubagentObservationDecoratorDeps {
  store: SubagentObservationStore;
  assistantMessages: SubagentAssistantMessageStore;
  /** Supplied from admitted activation data, never selected by child session recency. */
  contextForRun(
    job: Parameters<AgentEngine["run"]>[0],
  ): SubagentObservationTurnContext | Promise<SubagentObservationTurnContext>;
}

function validContext(context: SubagentObservationTurnContext): boolean {
  return context.attemptId.trim() !== "" &&
    context.childSessionId.trim() !== "" &&
    context.turnRunId.trim() !== "";
}

/**
 * Uninstantiated decorators for later runtime composition. They have no global
 * store, SQL, sink, or production registration. A shared ALS ties sandbox and
 * artifact side effects to the exact engine turn; tool calls can also resolve
 * an already-registered turn by its exact session/run pair.
 */
export function createSubagentObservationDecorators(
  deps: SubagentObservationDecoratorDeps,
) {
  const scope = new AsyncLocalStorage<SubagentObservationTurnContext>();

  async function withExactContext<T>(
    execution: { childSessionId: string; turnRunId: string } | null,
    operation: (context: SubagentObservationTurnContext) => Promise<T>,
  ): Promise<T> {
    const current = scope.getStore();
    if (current !== undefined) {
      if (execution !== null &&
        (current.childSessionId !== execution.childSessionId ||
          current.turnRunId !== execution.turnRunId)) {
        throw new Error("Observation execution does not match the active exact turn");
      }
      return operation(current);
    }
    if (execution === null) {
      throw new Error("Observed side effect has no exact attempt/turn context");
    }
    const context = await deps.store.contextForTurn(execution);
    if (context === null || !validContext(context) ||
      context.childSessionId !== execution.childSessionId ||
      context.turnRunId !== execution.turnRunId) {
      throw new Error("Observed side effect has no registered exact attempt/turn context");
    }
    return scope.run(context, () => operation(context));
  }

  async function beginOperation(
    context: SubagentObservationTurnContext,
    channel: SubagentObservationChannel,
  ): Promise<string> {
    const started = await deps.store.beginOperation({ context, channel });
    if (started.operationId.trim() === "") throw new Error("Observation operation ID is required");
    return started.operationId;
  }

  async function finishOperation(
    context: SubagentObservationTurnContext,
    operationId: string,
    state: "succeeded" | "failed",
    evidence?: SubagentOperationEvidence,
  ): Promise<void> {
    await deps.store.finishOperation({
      context,
      operationId,
      state,
      ...(evidence === undefined ? {} : { evidence }),
    });
  }

  async function finishAfterSideEffect(
    context: SubagentObservationTurnContext,
    operationId: string,
    state: "succeeded" | "failed",
    evidence?: SubagentOperationEvidence,
  ): Promise<void> {
    try {
      await finishOperation(context, operationId, state, evidence);
    } catch {
      // The real tool/sandbox/publisher result is authoritative and must stay
      // transparent. A finish that did not become durable leaves the operation
      // open, so close yields unknown_final rather than fabricated ready evidence.
    }
  }

  async function runUnknownOperation<T>(
    channel: SubagentObservationChannel,
    action: () => Promise<T>,
  ): Promise<T> {
    return withExactContext(null, async (context) => {
      const operationId = await beginOperation(context, channel);
      const result = await action();
      await finishAfterSideEffect(context, operationId, "succeeded");
      return result;
    });
  }

  function engine(engine: AgentEngine): AgentEngine {
    return {
      async run(job) {
        const context = await deps.contextForRun(job);
        if (!validContext(context) || context.childSessionId !== job.sessionId ||
          context.turnRunId !== job.runId) {
          throw new Error("Admitted observation context does not match the engine run");
        }
        const assistantHighWater = await deps.assistantMessages.highWater(context.childSessionId);
        await deps.store.beginTurn({ context, assistantHighWater });
        let executionThrew = false;
        try {
          return await scope.run(context, () => engine.run(job));
        } catch (error) {
          executionThrew = true;
          throw error;
        } finally {
          let capture: SubagentAssistantAnswerCapture;
          try {
            capture = await deps.assistantMessages.readAfter({
              childSessionId: context.childSessionId,
              afterMessageId: assistantHighWater,
            });
          } catch {
            capture = { state: "unknown" };
          }
          try {
            await deps.store.finishTurn({ context, capture });
          } catch (error) {
            // Preserve an existing engine failure. If the engine succeeded,
            // journal failure is an infrastructure failure and remains loud.
            if (!executionThrew) throw error;
          }
        }
      },
      cancel: (sessionId, reason) => engine.cancel(sessionId, reason),
      activeRun: (sessionId) => engine.activeRun(sessionId),
    };
  }

  function tool(tool: Tool): Tool {
    return {
      ...tool,
      async execute(args, ctx: ToolContext) {
        const classification = classifySubagentTool(tool.spec.name, args);
        if (classification.kind === "read_only") return tool.execute(args, ctx);
        return withExactContext(
          { childSessionId: ctx.sessionId, turnRunId: ctx.runId },
          async (context) => {
            const channel = classification.kind === "direct_file_write"
              ? "direct_file_write"
              : classification.channel;
            const operationId = await beginOperation(context, channel);
            // A throw (including a crash after the real side effect) deliberately
            // leaves the write-ahead operation open: unknown_final, never success.
            const result = await tool.execute(args, ctx);
            const succeeded = result.isError !== true;
            if (succeeded && classification.kind === "direct_file_write") {
              // A legal confined path may be whitespace. It is not representable
              // as non-empty report evidence, so leave the operation open rather
              // than throwing after the successful write or storing an empty path.
              if (classification.path.trim() !== "") {
                await finishAfterSideEffect(context, operationId, "succeeded", {
                  kind: "file",
                  path: classification.path,
                });
              }
            } else {
              await finishAfterSideEffect(
                context,
                operationId,
                succeeded ? "succeeded" : "failed",
              );
            }
            return result;
          },
        );
      },
    };
  }

  function sandbox(sandbox: SandboxPort): SandboxPort {
    return {
      exec: (userId, input) => runUnknownOperation("shell", () => sandbox.exec(userId, input)),
      killCall: (userId, callKey) =>
        runUnknownOperation("unknown", () => sandbox.killCall(userId, callKey)),
      readFile: (userId, path) => sandbox.readFile(userId, path),
      writeFile: (userId, path, content) => withExactContext(null, async (context) => {
        const operationId = await beginOperation(context, "direct_file_write");
        await sandbox.writeFile(userId, path, content);
        if (path.trim() !== "") {
          await finishAfterSideEffect(context, operationId, "succeeded", {
            kind: "file",
            path,
          });
        }
      }),
      exists: (userId, path) => sandbox.exists(userId, path),
      listDir: (userId, path) => sandbox.listDir(userId, path),
      jobStart: (userId, input) =>
        runUnknownOperation("job", () => sandbox.jobStart(userId, input)),
      jobOutput: (userId, jobId, input) => sandbox.jobOutput(userId, jobId, input),
      jobList: (userId) => sandbox.jobList(userId),
      jobKill: (userId, jobId) =>
        runUnknownOperation("job", () => sandbox.jobKill(userId, jobId)),
    };
  }

  function artifactPublisher<TInput extends { sessionId: string }, TOutput extends { id: string }>(
    publisher: (input: TInput) => Promise<TOutput>,
  ): (input: TInput) => Promise<TOutput> {
    return async (input) => withExactContext(null, async (context) => {
      if (input.sessionId !== context.childSessionId) {
        throw new Error("Artifact session does not match the exact observation turn");
      }
      const operationId = await beginOperation(context, "artifact_registration");
      const record = await publisher(input);
      // Registration already committed. An absent/unrepresentable returned ID
      // cannot become evidence, but it also cannot rewrite that committed result.
      if (typeof record.id === "string" && record.id.trim() !== "") {
        await finishAfterSideEffect(context, operationId, "succeeded", {
          kind: "artifact",
          artifactId: record.id,
        });
      }
      return record;
    });
  }

  return { engine, tool, sandbox, artifactPublisher };
}
