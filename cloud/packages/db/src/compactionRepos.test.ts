import { createHash } from "node:crypto";
import { afterAll, beforeAll, describe, expect, expectTypeOf, it } from "vitest";
import { eq } from "drizzle-orm";
import { createDb, migrate, type Db } from "./client.js";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";
import { createEnvelopeCrypto } from "../../escrow/src/envelope.js";
import { lockCompactionSession, messages, newId, runs, sessions, sessionState, users } from "./repos.js";
import {
  subagentAttempts,
  subagentLogicalWorkers,
  systemRequestResponses,
  systemRequests,
  workspaceObjects,
} from "./schema.js";
import { admitDispatches, settleAttemptAndMaybeWake } from "./subagentAdmission.js";
import {
  appendExactItem,
  compactionMessageStableId,
  createCompactionRepository,
  readExactHistory,
  toolCallHistoryPayload,
  type CompactionActor,
  type CompactionExactObjectReader,
  type CompactionInput,
  type CompactionMessage,
  type CompactionOutcome,
  type ContextUsage,
  type ExactHistoryItem,
  type FoldCheckpointInput,
  type ModelContextProfile,
} from "./compactionRepos.js";

// FIX ROUND 2: new and modified regressions are UNEXECUTED under
// HEAVY-COMMANDS-PAUSED.md. Historical logs predate every fix round.
const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const SECRET_CANARY = "sk-task9-0039-secret-canary-never-copy-7f39c2";
const TEST_MASTER_KEY = "0039".repeat(16);
const exactCrypto = createEnvelopeCrypto(TEST_MASTER_KEY);
const sealedObjects = new Map<string, { recordId: string; envelope: ReturnType<typeof exactCrypto.encrypt> }>();
const exactObjectReader: CompactionExactObjectReader = {
  async openReference(reference: string): Promise<unknown> {
    const sealed = sealedObjects.get(reference);
    if (!sealed) return null;
    return JSON.parse(exactCrypto.decrypt(sealed.envelope, sealed.recordId));
  },
};

function sealExact(value: unknown, kind: string, stableId: string): string {
  const serialized = JSON.stringify(value);
  const hash = createHash("sha256").update(serialized).digest("hex");
  const reference = `sealed:test:${kind}:${stableId}:${hash}`;
  if (!sealedObjects.has(reference)) {
    const recordId = `compaction_history:${kind}:${stableId}:${hash}`;
    sealedObjects.set(reference, { recordId, envelope: exactCrypto.encrypt(serialized, recordId) });
  }
  return reference;
}

async function appendSealedExact(
  db: Db,
  item: Omit<ExactHistoryItem, "objectRef" | "inlinePayload" | "byteLength">,
  payload: unknown,
): Promise<void> {
  await appendExactItem(db, {
    ...item,
    objectRef: sealExact(payload, item.kind, item.stableId),
    byteLength: Buffer.byteLength(JSON.stringify(payload), "utf8"),
  }, exactObjectReader);
}

function isCheckpoint(message: CompactionMessage): boolean {
  return message.role === "system" && message.content.includes("<compacted-summary>");
}

function canonicalMessage(message: CompactionMessage): boolean {
  return !!message.id && message.images === undefined && message.toolCalls === undefined &&
    message.cacheControl === undefined && message.volatile === undefined;
}

async function seedFoldHistory(db: Db, input: FoldCheckpointInput): Promise<void> {
  if (input.usage.beforeTokens * 100 < input.profile.contextLimit * 80) return;
  const results = new Map<string, string>();
  for (const message of input.messages) {
    if (message.role === "tool" && message.toolCallId) results.set(message.toolCallId, message.content);
  }
  for (const message of input.messages) {
    if (message.ephemeral === true || isCheckpoint(message)) continue;
    if (message.role === "tool" && message.toolCallId && !message.id) continue;
    for (const call of message.toolCalls ?? []) {
      const result = results.get(call.id);
      if (result === undefined) continue;
      const payload = toolCallHistoryPayload(call, message, result);
      await appendSealedExact(db, {
        stableId: call.id,
        kind: "tool_call",
        sessionId: input.actor.sessionId,
        rootTaskRunId: input.actor.rootTaskRunId,
        logicalWorkerId: input.actor.logicalWorkerId,
        attemptId: input.actor.attemptId,
        eventCursor: `test:tool_call:${call.id}:${createHash("sha256").update(JSON.stringify(payload)).digest("hex")}`,
      }, payload);
    }
    if (message.toolCalls && message.toolCalls.length > 0 && !message.id && !message.content) continue;
    if (canonicalMessage(message)) continue;
    const stableId = compactionMessageStableId(input.actor, message);
    await appendSealedExact(db, {
      stableId,
      kind: "message",
      sessionId: input.actor.sessionId,
      rootTaskRunId: input.actor.rootTaskRunId,
      logicalWorkerId: input.actor.logicalWorkerId,
      attemptId: input.actor.attemptId,
      eventCursor: `test:message:${stableId}:${createHash("sha256").update(JSON.stringify(message)).digest("hex")}`,
    }, message);
  }
}

async function fold(db: Db, repo: ReturnType<typeof createCompactionRepository>, input: FoldCheckpointInput) {
  await seedFoldHistory(db, input);
  return repo.foldCheckpoint(input);
}

async function readHistory(
  db: Db,
  input: Parameters<typeof readExactHistory>[1],
) {
  return readExactHistory(db, input, exactObjectReader);
}

async function within<T>(promise: Promise<T>, label: string, timeoutMs = 10_000): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), timeoutMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function workerFoldFixture(db: Db, label: string) {
  const { fixture, actor } = await parentWorkerEventFixture(db, label);
  const { window } = await conversation(db, { ...fixture, sessionId: actor.sessionId }, label);
  const input: FoldCheckpointInput = { messages: window, profile: PROFILE, usage: USAGE, actor };
  return { fixture, actor, input };
}

async function parentWorkerEventFixture(db: Db, label: string) {
  const fixture = await seedMain(db, label);
  const [admission] = await admitDispatches(db, [{
    requestId: newId(), index: 0, sessionId: fixture.sessionId, userId: fixture.userId,
    rootTaskRunId: fixture.rootTaskRunId, parentRunId: fixture.rootTaskRunId,
    batchId: newId(), prompt: `${label} worker`, provenance: "server", requestedAt: new Date(),
    modelContext: { requestedModel: null, byokKeyId: null, actorUserId: fixture.userId },
  }]);
  expect(admission?.admission).toBe("admitted");
  const actor: CompactionActor = {
    sessionId: admission!.childSessionId!,
    rootTaskRunId: fixture.rootTaskRunId,
    logicalWorkerId: admission!.logicalWorkerId!,
    attemptId: admission!.attemptId!,
    kind: "worker",
  };
  const seq = "1-0";
  const payload = { runId: admission!.childRunId!, attemptId: actor.attemptId, label };
  await db.$client`INSERT INTO session_event_mirror (session_id, seq, type, payload, ts)
    VALUES (${fixture.sessionId}, ${seq}, 'tool_terminal', ${db.$client.json(payload)}, now())`;
  const item: ExactHistoryItem = {
    stableId: seq,
    kind: "event",
    sessionId: actor.sessionId,
    rootTaskRunId: actor.rootTaskRunId,
    logicalWorkerId: actor.logicalWorkerId,
    attemptId: actor.attemptId,
    eventCursor: seq,
    objectRef: `postgres:session_event_mirror/${fixture.sessionId}/${seq}`,
    byteLength: Buffer.byteLength(JSON.stringify(payload)),
  };
  return { fixture, actor, item, payload };
}

type MainFixture = Awaited<ReturnType<typeof seedMain>>;

async function seedMain(db: Db, label: string) {
  const userId = newId();
  await users.ensure(db, userId, null);
  const session = await sessions.create(db, userId, label);
  const prompt = await messages.append(db, {
    sessionId: session.id,
    role: "user",
    content: `${label} canonical root`,
  });
  const root = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
  expect(await runs.claimNext(db, root.id)).toBe(true);
  return { userId, sessionId: session.id, rootTaskRunId: root.id, promptMessageId: prompt.id };
}

function actorFor(fixture: MainFixture): CompactionActor {
  return {
    sessionId: fixture.sessionId,
    rootTaskRunId: fixture.rootTaskRunId,
    logicalWorkerId: null,
    attemptId: null,
    kind: "main",
  };
}

const PROFILE: ModelContextProfile = {
  model: "resolved-task9-model",
  contextLimit: 1_000,
  outputReserveTokens: 100,
  providerReserveTokens: 10,
};
const USAGE: ContextUsage = { usageSource: "measured", beforeTokens: 800 };

async function conversation(db: Db, fixture: MainFixture, label: string, secret = false) {
  const durable: Array<{ id: string; role: "user" | "assistant"; content: string }> = [];
  for (let index = 0; index < 12; index += 1) {
    const role = index % 2 === 0 ? "user" as const : "assistant" as const;
    const row = await messages.append(db, {
      sessionId: fixture.sessionId,
      role,
      content: index === 0 && secret
        ? `canonical exact secret ${SECRET_CANARY}`
        : `${label}-${index}-${"x".repeat(110)}`,
      ...(role === "assistant" ? { reasoning: `${label}-reasoning-${index}` } : {}),
    });
    durable.push({ id: row.id, role, content: row.content });
  }
  const callId = `call-${label}-${newId()}`;
  const args = {
    command: `printf '%s' '${"long-command-".repeat(900)}'`,
    nested: { exact: "y".repeat(17_000), number: 42, boolean: true },
  };
  const result = `terminal-tool-result-${Array.from({ length: 311 }, () => "z".repeat(100)).join(" ")}`;
  const window: CompactionInput["messages"] = [
    ...durable.slice(0, 4),
    { role: "assistant", content: "", toolCalls: [{ id: callId, name: "run_shell", args }] },
    { role: "tool", content: result, toolCallId: callId },
    ...durable.slice(4),
  ];
  return { window, durable, callId, args, result };
}

function foldInput(
  fixture: MainFixture,
  window: CompactionInput["messages"],
  overrides: Partial<FoldCheckpointInput> = {},
): FoldCheckpointInput {
  return {
    messages: window,
    profile: PROFILE,
    usage: USAGE,
    actor: actorFor(fixture),
    ...overrides,
  };
}

async function counts(scratch: MigrationScratch, fixture: MainFixture) {
  const [row] = await scratch.client`
    SELECT
      (SELECT count(*)::int FROM compaction_cursors WHERE session_id = ${fixture.sessionId}) AS cursors,
      (SELECT count(*)::int FROM compaction_checkpoints WHERE session_id = ${fixture.sessionId}) AS checkpoints,
      (SELECT count(*)::int FROM compaction_history_items WHERE session_id = ${fixture.sessionId}) AS history`;
  return row!;
}

describe.skipIf(!TEST_DATABASE_URL).sequential("0039 compaction repository on isolated real Postgres — FIX ROUND 2 UNEXECUTED", () => {
  let scratch: MigrationScratch;
  let db: Db;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "contracts_0039_repos");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 8 });
  }, 180_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  it("pins the db-bound fold API and leaves a 79% request completely untouched", async () => {
    const fixture = await seedMain(db, "threshold");
    const repo = createCompactionRepository(db, exactObjectReader);
    expectTypeOf(repo.foldCheckpoint).parameter(0).toEqualTypeOf<FoldCheckpointInput>();
    expectTypeOf(repo.foldCheckpoint).returns.toEqualTypeOf<Promise<CompactionOutcome>>();
    expectTypeOf<FoldCheckpointInput>().toEqualTypeOf<
      Omit<CompactionInput, "windowTokens" | "sessionId"> & {
        profile: ModelContextProfile;
        usage: ContextUsage;
        actor: CompactionActor;
      }
    >();
    const { window } = await conversation(db, fixture, "threshold");
    const before = await counts(scratch, fixture);
    const outcome = await fold(db, repo, foldInput(fixture, window, {
      usage: { usageSource: "deterministic_fallback", beforeTokens: 790 },
    }));
    expect(outcome).toEqual({ compacted: false, messages: window, foldBoundary: 0 });
    expect(await counts(scratch, fixture)).toEqual(before);
  });

  it("folds at exactly 80%, populates every production field, and replays without duplicate side effects", async () => {
    const fixture = await seedMain(db, "replay");
    const repo = createCompactionRepository(db, exactObjectReader);
    const { window, callId, args, result } = await conversation(db, fixture, "replay");
    const first = await fold(db, repo, foldInput(fixture, window));
    expect(first.compacted).toBe(true);
    expect(first.foldBoundary).toBe(1);
    expect(first.compactionId).toMatch(/^[0-9a-f-]{36}$/);
    expect(first.checkpointId).toMatch(/^[0-9a-f-]{36}$/);
    expect(first.cutoffCursor).toEqual(expect.any(String));
    expect(first.contextLimit).toBe(1_000);
    expect(first.beforeTokens).toBe(800);
    expect(first.afterTokens).toEqual(expect.any(Number));
    expect(first.usageSource).toBe("measured");
    expect(first.continuation).toBe("continuing_existing_task");
    expect(first.messages[0]).toMatchObject({ role: "system", volatile: false });
    expect(first.messages[0]?.content).toContain("continuing_existing_task");
    expect(first.messages.length).toBeLessThan(window.length);
    expect(first.afterTokens).toBe(
      Buffer.byteLength(JSON.stringify(first.messages), "utf8") + 4 + first.messages.length * 4,
    );

    const replay = await fold(db, repo, foldInput(fixture, window));
    expect(replay).toEqual(first);
    expect(await counts(scratch, fixture)).toMatchObject({ cursors: 1, checkpoints: 1 });

    const history = await readHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "tool_call", id: callId },
      limit: 50,
    });
    expect(history.items).toHaveLength(1);
    expect(history.items[0]?.data).toMatchObject({
      id: callId,
      name: "run_shell",
      args,
      status: "completed",
      result,
      idempotencyKey: callId,
    });
    const [cursor] = await scratch.client`
      SELECT ledger_version, continuation FROM compaction_cursors WHERE session_id = ${fixture.sessionId}`;
    expect(cursor).toMatchObject({ ledger_version: 1, continuation: "continuing_existing_task" });
  });

  it("keeps active goal/todo text in canonical state instead of copying unrecognized secret material", async () => {
    const fixture = await seedMain(db, "opaque-active-state");
    const opaqueCanary = "opaque-user-credential-93b741e6c2a84f0b-not-pattern-detectable";
    await sessionState.patch(db, fixture.sessionId, {
      goal: { objective: opaqueCanary, notes: opaqueCanary },
      todos: [{ content: opaqueCanary, status: "in_progress" }],
    });
    const { window } = await conversation(db, fixture, "opaque-active-state");
    const outcome = await fold(db, createCompactionRepository(db, exactObjectReader), foldInput(fixture, window));
    const [checkpoint] = await scratch.client`
      SELECT summary, active_state FROM compaction_checkpoints WHERE checkpoint_id = ${outcome.checkpointId!}`;
    expect(JSON.stringify(checkpoint)).not.toContain(opaqueCanary);
    expect(checkpoint?.active_state).toMatchObject({
      goal: { stateRef: `postgres:session_agent_state/${fixture.sessionId}#goal` },
      todos: { stateRef: `postgres:session_agent_state/${fixture.sessionId}#todos`, count: 1 },
    });
    expect((await sessionState.get(db, fixture.sessionId)).goal?.objective).toBe(opaqueCanary);
  });

  it("recovers exact canonical messages, full tool calls, approvals and artifacts without copying a secret into new stores", async () => {
    const fixture = await seedMain(db, "exact");
    const repo = createCompactionRepository(db, exactObjectReader);
    const { window, durable, callId, args, result } = await conversation(db, fixture, "exact", true);
    const approvalId = `approval-${newId()}`;
    const responseId = newId();
    await db.insert(systemRequests).values({
      requestId: approvalId,
      userId: fixture.userId,
      sessionId: fixture.sessionId,
      runId: fixture.rootTaskRunId,
      kind: "approval",
      safePayload: { tool: "run_shell", summary: "run the exact command" },
      sensitive: false,
      status: "resolved",
      expiresAt: new Date("2026-10-26T23:00:00.000Z"),
      version: 1,
    });
    await db.insert(systemRequestResponses).values({
      responseId,
      requestId: approvalId,
      userId: fixture.userId,
      requestVersion: 1,
      clientResponseId: `client-${newId()}`,
      response: { decision: "allow" },
      responseDigest: "a".repeat(64),
    });
    const artifactId = newId();
    await db.insert(workspaceObjects).values({
      id: artifactId,
      userId: fixture.userId,
      sessionId: fixture.sessionId,
      kind: "artifact",
      r2Key: `users/${fixture.userId}/sessions/${fixture.sessionId}/artifacts/exact.txt`,
      bytes: 19,
      sha256: createHash("sha256").update("exact-artifact-body").digest("hex"),
      contentType: "text/plain",
    });

    const outcome = await fold(db, repo, foldInput(fixture, window));
    expect(outcome.compacted).toBe(true);
    const page = await readHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      limit: 100,
    });
    expect(page.nextCursor).toBeNull();
    const message = page.items.find((entry) => entry.item.stableId === durable[0]!.id);
    expect(message?.data).toMatchObject({
      id: durable[0]!.id,
      content: `canonical exact secret ${SECRET_CANARY}`,
    });
    const tool = page.items.find((entry) => entry.item.kind === "tool_call" && entry.item.stableId === callId);
    expect(tool?.data).toMatchObject({ args, result, status: "completed" });
    expect(page.items.find((entry) => entry.item.stableId === approvalId)?.data).toMatchObject({
      request_id: approvalId,
      status: "resolved",
      safe_payload: { tool: "run_shell", summary: "run the exact command" },
      response: { decision: "allow" },
      response_version: 1,
    });
    expect(page.items.find((entry) => entry.item.stableId === responseId)?.data).toMatchObject({
      response_id: responseId,
      request_version: 1,
      response: { decision: "allow" },
    });
    expect(page.items.find((entry) => entry.item.stableId === artifactId)?.data).toMatchObject({
      id: artifactId,
      r2_key: `users/${fixture.userId}/sessions/${fixture.sessionId}/artifacts/exact.txt`,
    });
    expect(page.items.some((entry) => entry.item.kind === "checkpoint" && entry.item.stableId === outcome.checkpointId)).toBe(true);
    expect(page.items.some((entry) => entry.item.kind === "compaction" && entry.item.stableId === outcome.compactionId)).toBe(true);

    const newRows = await scratch.client`
      SELECT c.summary::text AS summary, c.active_state::text AS active_state,
             h.inline_payload::text AS inline_payload, h.object_ref
        FROM compaction_checkpoints c
        FULL OUTER JOIN compaction_history_items h ON h.session_id = c.session_id
       WHERE c.session_id = ${fixture.sessionId} OR h.session_id = ${fixture.sessionId}`;
    for (const row of newRows) {
      expect(JSON.stringify(row)).not.toContain(SECRET_CANARY);
    }
    const [canonical] = await scratch.client`
      SELECT content FROM messages WHERE id = ${durable[0]!.id}`;
    expect(canonical?.content).toContain(SECRET_CANARY);
  });

  it("recalls a compacted durable tool-result row by its own stable message ID", async () => {
    const fixture = await seedMain(db, "tool-message-id");
    const repo = createCompactionRepository(db, exactObjectReader);
    const { window, result } = await conversation(db, fixture, "tool-message-id");
    const toolMessage = await messages.append(db, {
      sessionId: fixture.sessionId,
      role: "tool",
      content: result,
    });
    const durableWindow = window.map((message) => message.role === "tool"
      ? { ...message, id: toolMessage.id }
      : message);
    const outcome = await fold(db, repo, foldInput(fixture, durableWindow));
    expect(outcome.compacted).toBe(true);
    const recalled = await readHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "message", id: toolMessage.id },
    });
    expect(recalled.items).toHaveLength(1);
    expect(recalled.items[0]?.data).toMatchObject({ id: toolMessage.id, role: "tool", content: result });
  });

  it("advances ledger versions across repeated compactions without absorbing a checkpoint as conversation", async () => {
    const fixture = await seedMain(db, "repeat");
    const repo = createCompactionRepository(db, exactObjectReader);
    const firstWindow = await conversation(db, fixture, "repeat-a");
    const first = await fold(db, repo, foldInput(fixture, firstWindow.window));
    const added = await conversation(db, fixture, "repeat-b");
    const secondWindow = [...first.messages, ...added.durable.slice(0, 6)];
    const second = await fold(db, repo, foldInput(fixture, secondWindow, {
      foldBoundary: 1,
      usage: { usageSource: "deterministic_fallback", beforeTokens: 900 },
    }));
    expect(second.compacted).toBe(true);
    expect(second.compactionId).not.toBe(first.compactionId);
    expect(second.checkpointId).not.toBe(first.checkpointId);
    const cursors = await scratch.client`
      SELECT ledger_version FROM compaction_cursors WHERE session_id = ${fixture.sessionId}`;
    expect(cursors).toEqual([{ ledger_version: 2 }]);
    const checkpoints = await scratch.client`
      SELECT ledger_version, previous_checkpoint_id, summary FROM compaction_checkpoints
       WHERE session_id = ${fixture.sessionId} ORDER BY created_at, checkpoint_id`;
    expect(checkpoints).toHaveLength(2);
    expect(checkpoints[1]).toMatchObject({ ledger_version: 2, previous_checkpoint_id: first.checkpointId });
    expect(checkpoints[1]?.summary).not.toContain("Conversation span to condense");
    expect(checkpoints[1]?.summary).not.toContain(checkpoints[0]?.summary ?? "not-a-summary");
    const sideEffects = await readHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "tool_call", id: firstWindow.callId },
    });
    expect(sideEffects.items).toHaveLength(1);
  });

  it("uses the last signed exit code when classifying terminal tool history", async () => {
    const fixture = await seedMain(db, "exit-status");
    const repo = createCompactionRepository(db, exactObjectReader);
    const { window, callId } = await conversation(db, fixture, "exit-status");
    const first = await fold(db, repo, foldInput(fixture, window.map((message) =>
      message.role === "tool" ? { ...message, content: "terminal failure\n[exit -1]" } : message,
    )));
    const failed = await readHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "tool_call", id: callId },
    });
    expect(failed.items[0]?.data).toMatchObject({ status: "error" });

    const next = await conversation(db, fixture, "exit-recovery");
    const second = await fold(db, repo, foldInput(fixture, [
      ...first.messages,
      ...next.window.map((message) => message.role === "assistant" && message.toolCalls?.length
        ? { ...message, toolCalls: [{ ...message.toolCalls[0]!, id: callId }] }
        : message.role === "tool"
          ? { ...message, toolCallId: callId, content: "earlier [exit 7]\nrecovered [exit 0]" }
          : message),
    ], { foldBoundary: 1 }));
    expect(second.compacted).toBe(true);
    const latest = await readHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "tool_call", id: callId },
    });
    expect(latest.items.map((entry) => (entry.data as { status: string }).status)).toEqual(["error", "completed"]);
  });

  it("keeps immutable error history but clears resolved errors from the next active state", async () => {
    const fixture = await seedMain(db, "error-resolution");
    const repo = createCompactionRepository(db, exactObjectReader);
    const failedWindow = await conversation(db, fixture, "failed-call");
    const failedCallId = failedWindow.callId;
    const failed = await fold(db, repo, foldInput(fixture, failedWindow.window.map((message) =>
      message.role === "tool" ? { ...message, content: "tool error: injected terminal failure" } : message,
    )));
    const successWindow = await conversation(db, fixture, "successful-call");
    const second = await fold(db, repo, foldInput(fixture, [
      ...failed.messages,
      ...successWindow.window.map((message) => message.role === "assistant" && message.toolCalls?.length
        ? { ...message, toolCalls: [{ ...message.toolCalls[0]!, id: failedCallId }] }
        : message.role === "tool"
          ? { ...message, toolCallId: failedCallId }
          : message),
    ], { foldBoundary: 1 }));
    expect(second.compacted).toBe(true);
    const checkpoints = await scratch.client`
      SELECT checkpoint_id, active_state->'unresolvedErrorRefs' AS errors
        FROM compaction_checkpoints WHERE session_id = ${fixture.sessionId}`;
    const firstErrors = checkpoints.find((row) => row.checkpoint_id === failed.checkpointId)?.errors;
    const secondErrors = checkpoints.find((row) => row.checkpoint_id === second.checkpointId)?.errors;
    expect(firstErrors).toHaveLength(1);
    expect(firstErrors?.[0]?.stableId).toBe(failedCallId);
    expect(secondErrors).toEqual([]);
    const exactFailure = await readHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "tool_call", id: failedCallId },
    });
    expect(exactFailure.items[0]?.data).toMatchObject({ status: "error", result: "tool error: injected terminal failure" });
  });

  it("preserves worker error lineage across a fresh attempt without duplicating terminal side effects", async () => {
    const fixture = await seedMain(db, "worker-resume");
    const [admission] = await admitDispatches(db, [{
      requestId: newId(), index: 0, sessionId: fixture.sessionId, userId: fixture.userId,
      rootTaskRunId: fixture.rootTaskRunId, parentRunId: fixture.rootTaskRunId,
      batchId: newId(), prompt: "worker resume prompt", provenance: "server", requestedAt: new Date(),
      modelContext: { requestedModel: null, byokKeyId: null, actorUserId: fixture.userId },
    }]);
    expect(admission?.admission).toBe("admitted");
    const childFixture = { ...fixture, sessionId: admission!.childSessionId! };
    const actor: CompactionActor = {
      sessionId: admission!.childSessionId!,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: admission!.logicalWorkerId!,
      attemptId: admission!.attemptId!,
      kind: "worker",
    };
    const repo = createCompactionRepository(db, exactObjectReader);
    const failedWindow = await conversation(db, childFixture, "worker-resume-failure");
    const failedCallId = failedWindow.callId;
    const first = await fold(db, repo, {
      messages: failedWindow.window.map((message) => message.role === "tool"
        ? { ...message, content: "tool error: failure before restart" }
        : message),
      profile: PROFILE, usage: USAGE, actor,
    });
    expect(first.compacted).toBe(true);
    await settleAttemptAndMaybeWake(db, { attemptId: actor.attemptId!, outcome: "failed" });

    const resumePrompt = await messages.append(db, {
      sessionId: actor.sessionId, role: "user", content: "resume the same logical worker",
    });
    const resumedRun = await runs.create(db, {
      sessionId: actor.sessionId, promptMessageId: resumePrompt.id,
    });
    expect(await runs.claimNext(db, resumedRun.id)).toBe(true);
    const resumedAttemptId = newId();
    await db.insert(subagentAttempts).values({
      id: resumedAttemptId,
      logicalWorkerId: actor.logicalWorkerId!,
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      executionEpoch: 1,
      attemptNumber: 2,
      childSessionId: actor.sessionId,
      childRunId: resumedRun.id,
      promptMessageId: resumePrompt.id,
      status: "running",
      admittedAt: new Date(),
      startedAt: new Date(),
    });
    await db.update(subagentLogicalWorkers).set({ status: "running" })
      .where(eq(subagentLogicalWorkers.id, actor.logicalWorkerId!));
    const resumedActor = { ...actor, attemptId: resumedAttemptId };
    const more = await conversation(db, childFixture, "worker-after-resume");
    const second = await fold(db, repo, {
      messages: [...first.messages, ...more.window],
      profile: PROFILE, usage: USAGE, actor: resumedActor, foldBoundary: 1,
    });
    expect(second.compacted).toBe(true);
    const [checkpoint] = await scratch.client`
      SELECT active_state->'unresolvedErrorRefs' AS errors FROM compaction_checkpoints
       WHERE checkpoint_id = ${second.checkpointId!}`;
    expect(checkpoint?.errors).toHaveLength(1);
    expect(checkpoint?.errors?.[0]?.stableId).toBe(failedCallId);

    const original = await readHistory(db, {
      sessionId: actor.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: actor.logicalWorkerId,
      attemptId: actor.attemptId,
      reference: { kind: "tool_call", id: failedCallId },
    });
    expect(original.items).toHaveLength(1);
    const originalItem = original.items[0]!.item;
    await appendExactItem(db, {
      ...originalItem,
      rootTaskRunId: fixture.rootTaskRunId,
      attemptId: resumedAttemptId,
    }, exactObjectReader);
    const afterReplay = await readHistory(db, {
      sessionId: actor.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: actor.logicalWorkerId,
      attemptId: actor.attemptId,
      reference: { kind: "tool_call", id: failedCallId },
    });
    expect(afterReplay.items).toHaveLength(1);
    expect(afterReplay.items[0]?.item.attemptId).toBe(actor.attemptId);
    expect(afterReplay.items[0]?.data).toMatchObject({ status: "error" });

    // A late old-attempt request can neither replay nor advance the new chain.
    await expect(repo.foldCheckpoint({
      messages: failedWindow.window,
      profile: PROFILE,
      usage: USAGE,
      actor,
    })).rejects.toMatchObject({ code: "stale_attempt" });
    await expect(repo.foldCheckpoint({
      messages: [...first.messages, ...more.window],
      profile: PROFILE,
      usage: USAGE,
      actor,
      foldBoundary: 1,
    })).rejects.toMatchObject({ code: "stale_attempt" });
    const fenced = await scratch.client`
      SELECT attempt_id, ledger_version FROM compaction_cursors
       WHERE session_id = ${actor.sessionId} AND logical_worker_id = ${actor.logicalWorkerId}`;
    expect(fenced).toEqual([{ attempt_id: resumedAttemptId, ledger_version: 2 }]);
  });

  it("isolates concurrent main and parallel-worker cursors on two real connections", async () => {
    const fixture = await seedMain(db, "workers");
    const admitted = await admitDispatches(db, [0, 1].map((index) => ({
      requestId: newId(), index, sessionId: fixture.sessionId, userId: fixture.userId,
      rootTaskRunId: fixture.rootTaskRunId, parentRunId: fixture.rootTaskRunId,
      batchId: newId(), prompt: `worker-${index}`, provenance: index === 0 ? "web" as const : "android" as const,
      requestedAt: new Date(),
      modelContext: { requestedModel: null, byokKeyId: null, actorUserId: fixture.userId },
    })));
    expect(admitted.map((outcome) => outcome.admission)).toEqual(["admitted", "admitted"]);
    const mainWindow = await conversation(db, fixture, "main-parallel");
    const mainOutcome = await fold(db, createCompactionRepository(db, exactObjectReader), foldInput(fixture, mainWindow.window));
    expect(mainOutcome.compacted).toBe(true);
    const secondDb = createDb(scratch.url, { max: 4 });
    try {
      const repos = [createCompactionRepository(db, exactObjectReader), createCompactionRepository(secondDb, exactObjectReader)];
      const outcomes = await Promise.all(admitted.map(async (admission, index) => {
        const childFixture = { ...fixture, sessionId: admission.childSessionId! };
        const { window } = await conversation(index === 0 ? db : secondDb, childFixture, `worker-${index}`);
        const actor: CompactionActor = {
          sessionId: admission.childSessionId!,
          rootTaskRunId: fixture.rootTaskRunId,
          logicalWorkerId: admission.logicalWorkerId!,
          attemptId: admission.attemptId!,
          kind: "worker",
        };
        return fold(db, repos[index]!, {
          messages: window, profile: PROFILE, usage: USAGE, actor,
        });
      }));
      expect(outcomes.every((outcome) => outcome.compacted)).toBe(true);
      expect(outcomes[0]?.checkpointId).not.toBe(outcomes[1]?.checkpointId);
      expect(outcomes[0]?.cutoffCursor).not.toBe(outcomes[1]?.cutoffCursor);
      const cursors = await scratch.client`
        SELECT logical_worker_id, attempt_id, cutoff_cursor, ledger_version
          FROM compaction_cursors WHERE root_task_run_id = ${fixture.rootTaskRunId}
         ORDER BY logical_worker_id`;
      expect(cursors).toHaveLength(3);
      expect(cursors.filter((row) => row.logical_worker_id !== null).map((row) => row.logical_worker_id).sort()).toEqual(
        admitted.map((outcome) => outcome.logicalWorkerId).sort(),
      );
      expect(cursors.filter((row) => row.logical_worker_id === null)).toHaveLength(1);
      expect(cursors.every((row) => row.ledger_version === 1 && row.cutoff_cursor !== null)).toBe(true);
    } finally {
      await secondDb.$client.end({ timeout: 5 });
    }
  });

  it("canonicalizes parent and child worker aliases into one cursor and replay chain", async () => {
    const fixture = await seedMain(db, "worker-alias");
    const [admission] = await admitDispatches(db, [{
      requestId: newId(), index: 0, sessionId: fixture.sessionId, userId: fixture.userId,
      rootTaskRunId: fixture.rootTaskRunId, parentRunId: fixture.rootTaskRunId,
      batchId: newId(), prompt: "worker alias", provenance: "server", requestedAt: new Date(),
      modelContext: { requestedModel: null, byokKeyId: null, actorUserId: fixture.userId },
    }]);
    const actor: CompactionActor = {
      sessionId: admission!.childSessionId!,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: admission!.logicalWorkerId!,
      attemptId: admission!.attemptId!,
      kind: "worker",
    };
    const childFixture = { ...fixture, sessionId: actor.sessionId };
    const { window } = await conversation(db, childFixture, "worker-alias");
    const parentInput: FoldCheckpointInput = {
      messages: window,
      profile: PROFILE,
      usage: USAGE,
      actor: { ...actor, sessionId: fixture.sessionId },
    };
    await seedFoldHistory(db, { ...parentInput, actor });
    const repo = createCompactionRepository(db, exactObjectReader);
    const fromParent = await repo.foldCheckpoint(parentInput);
    const fromChild = await repo.foldCheckpoint({ ...parentInput, actor });
    const parentReplay = await repo.foldCheckpoint(parentInput);
    expect(fromParent.compacted).toBe(true);
    expect(fromChild).toEqual(fromParent);
    expect(parentReplay).toEqual(fromParent);
    const cursors = await scratch.client`
      SELECT session_id, ledger_version FROM compaction_cursors
       WHERE root_task_run_id = ${fixture.rootTaskRunId} AND logical_worker_id = ${actor.logicalWorkerId}`;
    expect(cursors).toEqual([{ session_id: actor.sessionId, ledger_version: 1 }]);
    const split = await scratch.client`
      SELECT count(*)::int AS count FROM compaction_cursors
       WHERE root_task_run_id = ${fixture.rootTaskRunId} AND logical_worker_id = ${actor.logicalWorkerId}
         AND session_id <> ${actor.sessionId}`;
    expect(split).toEqual([{ count: 0 }]);
  });

  it("UNEXECUTED: fold-first and settlement share parent-child-worker-attempt ordering", async () => {
    const { fixture, actor, input } = await workerFoldFixture(db, "fold-before-settlement");
    const otherDb = createDb(scratch.url, { max: 4 });
    await seedFoldHistory(db, input);
    let folded!: () => void;
    const foldDone = new Promise<void>((resolve) => { folded = resolve; });
    let release!: () => void;
    const released = new Promise<void>((resolve) => { release = resolve; });
    const holder = otherDb.transaction(async (tx) => {
      const outcome = await createCompactionRepository(tx as unknown as Db, exactObjectReader)
        .foldCheckpoint(input);
      folded();
      await released;
      return outcome;
    });
    try {
      await within(foldDone, "first fold acquiring its locks");
      const settlement = settleAttemptAndMaybeWake(db, {
        attemptId: actor.attemptId!, outcome: "failed",
      });
      release();
      const [foldOutcome, settled] = await Promise.all([
        within(holder, "fold-first transaction"),
        within(settlement, "settlement after fold"),
      ]);
      expect(foldOutcome.compacted).toBe(true);
      expect(settled).toEqual({ rootTaskRunId: fixture.rootTaskRunId, shouldWake: false });
      const attempt = await scratch.client`
        SELECT status FROM subagent_attempts WHERE id = ${actor.attemptId}`;
      expect(attempt).toEqual([{ status: "failed" }]);
    } finally {
      release();
      await holder;
      await otherDb.$client.end({ timeout: 5 });
    }
  }, 20_000);

  it("UNEXECUTED: a held worker lock cannot invert settlement into an attempt deadlock", async () => {
    const { actor } = await workerFoldFixture(db, "worker-lock-settlement-order");
    const otherDb = createDb(scratch.url, { max: 4 });
    let workerLocked!: () => void;
    const locked = new Promise<void>((resolve) => { workerLocked = resolve; });
    let probe!: () => void;
    const probeReady = new Promise<void>((resolve) => { probe = resolve; });
    // Simulate compaction's parent/child/worker prefix, then probe the attempt
    // only after settlement starts. Old attempt-first settlement would hold
    // the attempt while waiting for this worker and deadlock with the probe.
    const orderedHolder = otherDb.transaction(async (tx) => {
      const lineage = await tx.select({
        parentSessionId: subagentAttempts.sessionId,
        childSessionId: subagentAttempts.childSessionId,
        logicalWorkerId: subagentAttempts.logicalWorkerId,
      }).from(subagentAttempts).where(eq(subagentAttempts.id, actor.attemptId!)).limit(1);
      await lockCompactionSession(tx, lineage[0]!.parentSessionId, { mode: "shared" });
      await lockCompactionSession(tx, lineage[0]!.childSessionId, { mode: "shared" });
      await tx.select({ id: subagentLogicalWorkers.id }).from(subagentLogicalWorkers)
        .where(eq(subagentLogicalWorkers.id, lineage[0]!.logicalWorkerId)).for("update").limit(1);
      workerLocked();
      await probeReady;
      await tx.select({ id: subagentAttempts.id }).from(subagentAttempts)
        .where(eq(subagentAttempts.id, actor.attemptId!)).for("update").limit(1);
    });
    try {
      await within(locked, "controlled worker lock");
      const settlement = settleAttemptAndMaybeWake(db, {
        attemptId: actor.attemptId!, outcome: "failed",
      });
      const early = await Promise.race([
        settlement.then(() => "settled"),
        new Promise<string>((resolve) => setTimeout(() => resolve("waiting"), 50)),
      ]);
      expect(early).toBe("waiting");
      probe();
      await within(orderedHolder, "worker/attempt lock probe");
      expect(await within(settlement, "settlement after worker release"))
        .toEqual({ rootTaskRunId: actor.rootTaskRunId, shouldWake: false });
    } finally {
      probe();
      await orderedHolder;
      await otherDb.$client.end({ timeout: 5 });
    }
  }, 20_000);

  it("UNEXECUTED: truncation is fenced, while an externally stale cutoff fails recall and replay honestly", async () => {
    const fixture = await seedMain(db, "truncated-cutoff");
    const repo = createCompactionRepository(db, exactObjectReader);
    const { window } = await conversation(db, fixture, "truncated-cutoff");
    const input = foldInput(fixture, window);
    const outcome = await fold(db, repo, input);
    expect(outcome.compacted).toBe(true);
    const [cursor] = await scratch.client`
      SELECT cutoff_message_id FROM compaction_cursors WHERE session_id = ${fixture.sessionId}`;
    expect(cursor?.cutoff_message_id).toEqual(expect.any(String));
    const scope = {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "message" as const, id: cursor!.cutoff_message_id },
    };
    await expect(messages.truncateFrom(db, fixture.sessionId, cursor!.cutoff_message_id))
      .rejects.toMatchObject({ code: "compacted_history_truncation" });
    expect((await readHistory(db, scope)).items[0]?.data).toMatchObject({ id: cursor!.cutoff_message_id });
    expect(await repo.foldCheckpoint(input)).toEqual(outcome);

    // Simulate a legacy/out-of-band deletion, not the guarded repository path.
    // Exact recall and replay must never present data:null or a stale tail.
    await scratch.client`DELETE FROM messages WHERE id = ${cursor!.cutoff_message_id}`;
    await expect(readHistory(db, scope)).rejects.toMatchObject({ code: "history_reference_unavailable" });
    await expect(repo.foldCheckpoint(input))
      .rejects.toMatchObject({ code: "stale_compaction_input" });
    const deleted = await messages.get(db, cursor!.cutoff_message_id);
    expect(deleted).toBeNull();
    await expect(appendExactItem(db, {
      stableId: cursor!.cutoff_message_id,
      kind: "message",
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: null,
      attemptId: null,
      eventCursor: cursor!.cutoff_message_id,
      objectRef: `postgres:messages/${cursor!.cutoff_message_id}`,
      byteLength: 1,
    }, exactObjectReader)).rejects.toMatchObject({ code: "history_reference_not_found" });
  });

  // FIX ROUND 1 / truncation handoff — UNEXECUTED under HEAVY-COMMANDS-PAUSED.
  it("UNEXECUTED: parent truncation fences a backfilled child-scoped worker event", async () => {
    const { fixture, actor, item, payload } = await parentWorkerEventFixture(db, "backfilled-parent-event");
    await appendExactItem(db, item, exactObjectReader);
    // No main cursor/checkpoint exists: only the parent/child reference
    // predicate can protect this existing 0039-backfilled event shape.
    expect(await counts(scratch, fixture)).toMatchObject({ cursors: 0, checkpoints: 0 });
    await expect(messages.truncateFrom(db, fixture.sessionId, fixture.promptMessageId, {
      eventsFrom: new Date(0),
    })).rejects.toMatchObject({ code: "compacted_history_truncation" });
    const canonical = await scratch.client`
      SELECT payload FROM session_event_mirror WHERE session_id = ${fixture.sessionId} AND seq = '1-0'`;
    expect(canonical).toHaveLength(1);
    const recalled = await readHistory(db, {
      sessionId: actor.sessionId,
      rootTaskRunId: actor.rootTaskRunId,
      logicalWorkerId: actor.logicalWorkerId,
      attemptId: actor.attemptId,
      reference: { kind: "event", id: item.stableId },
    });
    expect(recalled.items[0]?.data).toMatchObject({ type: "tool_terminal", payload });
  });

  it("UNEXECUTED: writer-first parent lock commits the worker event before parent truncation fences", async () => {
    const { fixture, actor, item, payload } = await parentWorkerEventFixture(db, "worker-parent-writer-first");
    const otherDb = createDb(scratch.url, { max: 4 });
    let locked!: () => void;
    const ready = new Promise<void>((resolve) => { locked = resolve; });
    let release!: () => void;
    const released = new Promise<void>((resolve) => { release = resolve; });
    const holder = otherDb.transaction(async (tx) => {
      await lockCompactionSession(tx, fixture.sessionId, { mode: "shared" });
      locked();
      await released;
    });
    try {
      await ready;
      // The writer acquires the same parent shared gate and commits before
      // truncation can upgrade to exclusive. The shared holder then releases.
      await appendExactItem(db, item, exactObjectReader);
      const truncation = messages.truncateFrom(otherDb, fixture.sessionId, fixture.promptMessageId, {
        eventsFrom: new Date(0),
      });
      release();
      await holder;
      await expect(truncation).rejects.toMatchObject({ code: "compacted_history_truncation" });
      const recalled = await readHistory(db, {
        sessionId: actor.sessionId,
        rootTaskRunId: actor.rootTaskRunId,
        logicalWorkerId: actor.logicalWorkerId,
        attemptId: actor.attemptId,
        reference: { kind: "event", id: item.stableId },
      });
      expect(recalled.items[0]?.data).toMatchObject({ payload });
    } finally {
      release();
      await holder;
      await otherDb.$client.end({ timeout: 5 });
    }
  }, 15_000);

  it("UNEXECUTED: truncation-first parent lock makes a later worker append fail without dangling history", async () => {
    const { fixture, actor, item } = await parentWorkerEventFixture(db, "worker-parent-truncate-first");
    const otherDb = createDb(scratch.url, { max: 4 });
    let truncated!: () => void;
    const ready = new Promise<void>((resolve) => { truncated = resolve; });
    let release!: () => void;
    const released = new Promise<void>((resolve) => { release = resolve; });
    const holder = otherDb.transaction(async (tx) => {
      await lockCompactionSession(tx, fixture.sessionId, { mode: "exclusive" });
      // Nested savepoint: the outer transaction still owns the parent gate
      // until release, while the real truncation implementation has run.
      await messages.truncateFrom(tx as unknown as Db, fixture.sessionId, fixture.promptMessageId, {
        eventsFrom: new Date(0),
      });
      truncated();
      await released;
    });
    try {
      await ready;
      const appendOutcome = appendExactItem(db, item, exactObjectReader).then(
        () => ({ status: "fulfilled" as const }),
        (error: unknown) => ({ status: "rejected" as const, error }),
      );
      release();
      await holder;
      const outcome = await appendOutcome;
      expect(outcome.status).toBe("rejected");
      if (outcome.status === "rejected") {
        expect(outcome.error).toMatchObject({ code: "history_reference_not_found" });
      }
      expect(await counts(scratch, { ...fixture, sessionId: actor.sessionId }))
        .toMatchObject({ cursors: 0, checkpoints: 0, history: 0 });
      const canonical = await scratch.client`
        SELECT count(*)::int AS count FROM session_event_mirror
         WHERE session_id = ${fixture.sessionId} AND seq = '1-0'`;
      expect(canonical).toEqual([{ count: 0 }]);
    } finally {
      release();
      await holder;
      await otherDb.$client.end({ timeout: 5 });
    }
  }, 15_000);

  it("UNEXECUTED: a stale first fold cannot preserve a deleted retained tail", async () => {
    const fixture = await seedMain(db, "stale-first-tail");
    const repo = createCompactionRepository(db, exactObjectReader);
    const { window, durable } = await conversation(db, fixture, "stale-first-tail");
    const tail = durable[durable.length - 1]!;
    expect(await messages.truncateFrom(db, fixture.sessionId, tail.id)).toBe(1);
    await expect(repo.foldCheckpoint(foldInput(fixture, window)))
      .rejects.toMatchObject({ code: "stale_compaction_input" });
    expect(await counts(scratch, fixture)).toMatchObject({ cursors: 0, checkpoints: 0, history: 0 });
  });

  it("UNEXECUTED: changed retained-tail content is stale before any cursor or replay exists", async () => {
    const fixture = await seedMain(db, "stale-tail-content");
    const repo = createCompactionRepository(db, exactObjectReader);
    const { window, durable } = await conversation(db, fixture, "stale-tail-content");
    const tail = durable[durable.length - 1]!;
    await scratch.client`UPDATE messages SET content = 'externally changed retained tail' WHERE id = ${tail.id}`;
    await expect(repo.foldCheckpoint(foldInput(fixture, window)))
      .rejects.toMatchObject({ code: "stale_compaction_input" });
    expect(await counts(scratch, fixture)).toMatchObject({ cursors: 0, checkpoints: 0, history: 0 });
  });

  it("UNEXECUTED: two connections serialize first fold versus retained-tail truncation", async () => {
    const fixture = await seedMain(db, "first-fold-race");
    const repo = createCompactionRepository(db, exactObjectReader);
    const otherDb = createDb(scratch.url, { max: 4 });
    const { window, durable } = await conversation(db, fixture, "first-fold-race");
    const tail = durable[durable.length - 1]!;
    const input = foldInput(fixture, window.filter((message) =>
      !message.toolCalls?.length && message.role !== "tool",
    ));
    try {
      const [folded, truncated] = await Promise.allSettled([
        repo.foldCheckpoint(input),
        messages.truncateFrom(otherDb, fixture.sessionId, tail.id),
      ]);
      if (folded.status === "fulfilled" && truncated.status === "rejected") {
        expect(truncated.reason).toMatchObject({ code: "compacted_history_truncation" });
        expect(folded.value.compacted).toBe(true);
        expect(await repo.foldCheckpoint(input)).toEqual(folded.value);
        return;
      }
      if (folded.status === "rejected" && truncated.status === "fulfilled") {
        expect(folded.reason).toMatchObject({ code: "stale_compaction_input" });
        expect(await counts(scratch, fixture)).toMatchObject({ cursors: 0, checkpoints: 0, history: 0 });
        return;
      }
      throw new Error(`Invalid first-fold/truncation outcome: ${folded.status}/${truncated.status}`);
    } finally {
      await otherDb.$client.end({ timeout: 5 });
    }
  }, 15_000);

  it("UNEXECUTED: a concurrent canonical append cannot create a dangling reference after truncation", async () => {
    const fixture = await seedMain(db, "append-truncation-race");
    const otherDb = createDb(scratch.url, { max: 4 });
    const row = await messages.append(db, {
      sessionId: fixture.sessionId, role: "assistant", content: "append race exact",
    });
    const item = {
      stableId: row.id,
      kind: "message" as const,
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: null,
      attemptId: null,
      eventCursor: row.id,
      objectRef: `postgres:messages/${row.id}`,
      byteLength: Buffer.byteLength(row.content),
    };
    try {
      const [appended, truncated] = await Promise.allSettled([
        appendExactItem(db, item, exactObjectReader),
        messages.truncateFrom(otherDb, fixture.sessionId, row.id),
      ]);
      if (appended.status === "rejected") {
        expect(appended.reason).toMatchObject({ code: "history_reference_not_found" });
        expect(await counts(scratch, fixture)).toMatchObject({ cursors: 0, checkpoints: 0, history: 0 });
      } else {
        expect(truncated.status).toBe("rejected");
        if (truncated.status === "rejected") expect(truncated.reason).toMatchObject({ code: "compacted_history_truncation" });
        const page = await readHistory(db, {
          sessionId: fixture.sessionId,
          rootTaskRunId: fixture.rootTaskRunId,
          reference: { kind: "message", id: row.id },
        });
        expect(page.items[0]?.data).toMatchObject({ id: row.id, content: row.content });
      }
    } finally {
      await otherDb.$client.end({ timeout: 5 });
    }
  }, 15_000);

  it("UNEXECUTED: a target-session exclusive gate does not block unrelated writes or first folds", async () => {
    const target = await seedMain(db, "exclusive-target");
    const targetRepo = createCompactionRepository(db, exactObjectReader);
    const targetWindow = await conversation(db, target, "exclusive-target");
    expect((await fold(db, targetRepo, foldInput(target, targetWindow.window))).compacted).toBe(true);
    const other = await seedMain(db, "unrelated-progress");
    const otherWindow = await conversation(db, other, "unrelated-progress");
    const otherRepo = createCompactionRepository(db, exactObjectReader);
    const otherDb = createDb(scratch.url, { max: 4 });
    let locked!: () => void;
    const lockReady = new Promise<void>((resolve) => { locked = resolve; });
    let release!: () => void;
    const released = new Promise<void>((resolve) => { release = resolve; });
    const holder = otherDb.transaction(async (tx) => {
      await lockCompactionSession(tx, target.sessionId, { mode: "exclusive" });
      locked();
      await released;
    });
    try {
      await lockReady;
      await messages.append(db, {
        sessionId: other.sessionId, role: "assistant", content: "unrelated write",
      });
      await sessionState.patch(db, other.sessionId, { planMode: true });
      const outcome = await fold(db, otherRepo, foldInput(other, otherWindow.window));
      expect(outcome.compacted).toBe(true);
      expect((await sessionState.get(db, other.sessionId)).planMode).toBe(true);
    } finally {
      release();
      await holder;
      await otherDb.$client.end({ timeout: 5 });
    }
  }, 15_000);

  it("rolls back checkpoint, history and cursor writes on a crash, then replays the same fold", async () => {
    const fixture = await seedMain(db, "crash");
    const repo = createCompactionRepository(db, exactObjectReader);
    const { window } = await conversation(db, fixture, "crash");
    const input = foldInput(fixture, window);
    await seedFoldHistory(db, input);
    const baseline = await counts(scratch, fixture);
    await scratch.client.unsafe(`
      CREATE FUNCTION fail_0039_checkpoint() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'injected 0039 crash'; END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER fail_0039_checkpoint BEFORE INSERT ON compaction_checkpoints
      FOR EACH ROW EXECUTE FUNCTION fail_0039_checkpoint();
    `);
    await expect(repo.foldCheckpoint(input)).rejects.toMatchObject({
      cause: expect.objectContaining({ message: expect.stringContaining("injected 0039 crash") }),
    });
    expect(await counts(scratch, fixture)).toEqual(baseline);
    await scratch.client.unsafe(`
      DROP TRIGGER fail_0039_checkpoint ON compaction_checkpoints;
      DROP FUNCTION fail_0039_checkpoint();
    `);
    const recovered = await repo.foldCheckpoint(input);
    expect(recovered.compacted).toBe(true);
    expect(await counts(scratch, fixture)).toMatchObject({ cursors: 1, checkpoints: 1 });
    expect(await repo.foldCheckpoint(input)).toEqual(recovered);
  });

  it("refuses nonterminal tool calls and approvals without advancing durable state", async () => {
    const toolFixture = await seedMain(db, "pending-tool");
    const repo = createCompactionRepository(db, exactObjectReader);
    const { window, callId } = await conversation(db, toolFixture, "pending-tool");
    const pending = window.filter((message) => message.role !== "tool" || message.toolCallId !== callId);
    await expect(repo.foldCheckpoint(foldInput(toolFixture, pending)))
      .rejects.toMatchObject({ code: "tool_call_not_terminal" });
    expect(await counts(scratch, toolFixture)).toMatchObject({ cursors: 0, checkpoints: 0, history: 0 });

    const approvalFixture = await seedMain(db, "pending-approval");
    const approvalId = `pending-${newId()}`;
    await db.insert(systemRequests).values({
      requestId: approvalId,
      userId: approvalFixture.userId,
      sessionId: approvalFixture.sessionId,
      runId: approvalFixture.rootTaskRunId,
      kind: "approval",
      safePayload: { tool: "run_shell", summary: "pending" },
      sensitive: false,
      status: "pending",
      expiresAt: new Date("2026-10-26T23:00:00.000Z"),
      version: 1,
    });
    const ready = await conversation(db, approvalFixture, "pending-approval");
    await expect(repo.foldCheckpoint(foldInput(approvalFixture, ready.window)))
      .rejects.toMatchObject({ code: "approval_not_terminal" });
    expect((await counts(scratch, approvalFixture)).cursors).toBe(0);
  });

  it("stores recognizable, numeric and opaque secrets only in sealed objects while exact recall remains lossless", async () => {
    const fixture = await seedMain(db, "secret-sealed");
    const repo = createCompactionRepository(db, exactObjectReader);
    const { window, callId } = await conversation(db, fixture, "secret-sealed");
    const opaqueCanary = "opaque-result-credential-4a30e1b6c8db49ac-not-regex-detectable";
    const withSecret = window.map((message) => {
      if (message.role === "assistant" && message.toolCalls?.[0]?.id === callId) {
        return {
          ...message,
          toolCalls: [{
            ...message.toolCalls[0]!,
            args: { apiKey: SECRET_CANARY, password: 123456, opaque: opaqueCanary },
          }],
        };
      }
      return message.role === "tool" ? { ...message, content: opaqueCanary } : message;
    });
    const outcome = await fold(db, repo, foldInput(fixture, withSecret));
    expect(outcome.compacted).toBe(true);
    const recalled = await readHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "tool_call", id: callId },
    });
    expect(recalled.items[0]?.data).toMatchObject({
      args: { apiKey: SECRET_CANARY, password: 123456, opaque: opaqueCanary },
      result: opaqueCanary,
    });
    const rows = await scratch.client`
      SELECT inline_payload, object_ref FROM compaction_history_items
       WHERE session_id = ${fixture.sessionId}`;
    expect(rows.every((row) => row.inline_payload === null && typeof row.object_ref === "string" &&
      (row.object_ref.startsWith("sealed:") || row.object_ref.startsWith("postgres:")))).toBe(true);
    expect(JSON.stringify(rows)).not.toContain(SECRET_CANARY);
    expect(JSON.stringify(rows)).not.toContain(opaqueCanary);
    expect(JSON.stringify([...sealedObjects.values()])).not.toContain(SECRET_CANARY);
    expect(JSON.stringify([...sealedObjects.values()])).not.toContain(opaqueCanary);
  });

  it("rejects every raw inline payload, including opaque strings and numeric secrets", async () => {
    const fixture = await seedMain(db, "unsafe-inline");
    const base = {
      kind: "message" as const,
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: null,
      attemptId: null,
      byteLength: 32,
    };
    for (const [stableId, inlinePayload] of [
      ["numeric-secret", { password: 123456 }],
      ["opaque-secret", { credential: "opaque-not-regex-detectable" }],
      ["hyphenated-secret", { "x-custom-credential": 987654321 }],
    ] as const) {
      await expect(appendExactItem(db, { ...base, stableId, eventCursor: stableId, inlinePayload }))
        .rejects.toMatchObject({ code: "unsafe_inline_payload" });
    }
    expect(await counts(scratch, fixture)).toMatchObject({ cursors: 0, checkpoints: 0, history: 0 });
  });

  it("fails closed when noncanonical content has no matching sealed exact object", async () => {
    const fixture = await seedMain(db, "missing-sealed");
    const repo = createCompactionRepository(db, exactObjectReader);
    const { window } = await conversation(db, fixture, "missing-sealed");
    await expect(repo.foldCheckpoint(foldInput(fixture, window)))
      .rejects.toMatchObject({ code: "exact_object_required" });
    expect(await counts(scratch, fixture)).toMatchObject({ cursors: 0, checkpoints: 0 });
  });
});
