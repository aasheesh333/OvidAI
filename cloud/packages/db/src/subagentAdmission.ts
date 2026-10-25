import { and, asc, eq, gt, inArray, isNotNull, sql } from "drizzle-orm";
import type { StructuredSubagentReport } from "@ovid/shared";
import type { Db } from "./client.js";
import { readDurableSubagentReportSnapshotWithin } from "./subagentReportSnapshots.js";
import { newId } from "./repos.js";
import {
  messages,
  runs,
  sessionAgentState,
  sessions,
  subagentAttempts,
  subagentBatches,
  subagentControlAudit,
  subagentDispatches,
  subagentLogicalWorkers,
  subagentReports,
  subagentRootFinalizations,
  subagentRoots,
  subagentSessionAdmission,
  type SubagentAttemptRow,
  type SubagentDispatchRow,
  type SubagentRootRow,
} from "./schema.js";

export const SESSION_ACTIVE_SUBAGENT_LIMIT = 50;

const ACTIVE_RUN_STATUSES = ["queued", "running"] as const;

type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];
type TerminalOutcome = "completed" | "failed" | "cancelled" | "timeout";

export interface InheritedModelContext {
  requestedModel: string | null;
  byokKeyId: string | null;
  byokModel?: string;
  actorUserId: string;
}

export interface AdmissionRequest {
  requestId: string;
  index: number;
  sessionId: string;
  userId: string;
  rootTaskRunId: string;
  parentRunId: string;
  batchId: string;
  prompt: string;
  agentType?: string;
  tools?: readonly string[];
  disallowedTools?: readonly string[];
  provenance: "web" | "android" | "server";
  requestedAt: Date;
  userPriorityHint?: number;
  modelContext: InheritedModelContext;
}

export interface AdmissionOutcome {
  index: number;
  admission: "admitted" | "awaiting_next_user_task" | "refused";
  logicalWorkerId?: string;
  attemptId?: string;
  childSessionId?: string;
  childRunId?: string;
  deferredRequestId?: string;
  code?: string;
  message?: string;
}

export interface SubagentReportRecord {
  logicalWorkerId: string;
  attemptId: string;
  childSessionId: string;
  childRunId: string;
  agentType: string;
  status: TerminalOutcome;
  summary: string;
  task: string;
  at: number;
  structuredReport?: StructuredSubagentReport;
}

/** Atomic root/epoch/active/report input for the root-finalization adapter. */
export interface RootFinalizationSnapshotRecord {
  rootTaskRunId: string;
  sessionId: string;
  executionEpoch: number;
  activeAttemptIds: readonly string[];
  finalized: boolean;
  reports: readonly SubagentReportRecord[];
}

interface RootContext {
  runId: string;
  status: string;
  createdAt: Date;
  messageCreatedAt: Date;
}

class RootFinalizedError extends Error {}

function refusal(index: number, code: string, message: string): AdmissionOutcome {
  return { index, admission: "refused", code, message };
}

function validateRequest(request: AdmissionRequest): AdmissionOutcome | null {
  const ids = [
    request.requestId,
    request.sessionId,
    request.userId,
    request.rootTaskRunId,
    request.parentRunId,
    request.batchId,
  ];
  if (ids.some((id) => typeof id !== "string" || id.length === 0)) {
    return refusal(request.index, "invalid_request", "Request identity is invalid.");
  }
  if (!Number.isInteger(request.index) || request.index < 0) {
    return refusal(request.index, "invalid_request", "Request index is invalid.");
  }
  if (typeof request.prompt !== "string" || request.prompt.trim() === "") {
    return refusal(request.index, "invalid_prompt", "A non-empty prompt is required.");
  }
  if (!(request.requestedAt instanceof Date) || !Number.isFinite(request.requestedAt.getTime())) {
    return refusal(request.index, "invalid_request", "Request time is invalid.");
  }
  if (!["web", "android", "server"].includes(request.provenance)) {
    return refusal(request.index, "invalid_provenance", "Request provenance is invalid.");
  }
  if (
    request.userPriorityHint !== undefined &&
    !Number.isInteger(request.userPriorityHint)
  ) {
    return refusal(request.index, "invalid_request", "Priority hint is invalid.");
  }
  if (request.modelContext.actorUserId !== request.userId) {
    return refusal(request.index, "actor_mismatch", "Model billing identity does not match the dispatch user.");
  }
  return null;
}

async function lockSession(tx: Tx, sessionId: string): Promise<{ userId: string } | null> {
  const found = await tx
    .select({ userId: sessions.userId })
    .from(sessions)
    .where(eq(sessions.id, sessionId))
    .for("update")
    .limit(1);
  if (found.length === 0) return null;
  await tx
    .insert(subagentSessionAdmission)
    .values({ sessionId })
    .onConflictDoNothing({ target: subagentSessionAdmission.sessionId });
  await tx
    .select({ sessionId: subagentSessionAdmission.sessionId })
    .from(subagentSessionAdmission)
    .where(eq(subagentSessionAdmission.sessionId, sessionId))
    .for("update")
    .limit(1);
  return found[0]!;
}

async function canonicalRoot(
  tx: Tx,
  sessionId: string,
  rootTaskRunId: string,
): Promise<RootContext | null> {
  const rows = await tx
    .select({
      runId: runs.id,
      status: runs.status,
      createdAt: runs.createdAt,
      messageCreatedAt: messages.createdAt,
    })
    .from(runs)
    .innerJoin(messages, eq(runs.promptMessageId, messages.id))
    .where(and(
      eq(runs.id, rootTaskRunId),
      eq(runs.sessionId, sessionId),
      eq(messages.sessionId, sessionId),
      eq(messages.role, "user"),
    ))
    .for("update")
    .limit(1);
  return rows[0] ?? null;
}

async function runBelongsToSession(
  tx: Tx,
  sessionId: string,
  runId: string,
): Promise<boolean> {
  const rows = await tx
    .select({ id: runs.id })
    .from(runs)
    .where(and(eq(runs.id, runId), eq(runs.sessionId, sessionId)))
    .limit(1);
  return rows.length > 0;
}

async function activeAttemptCount(
  tx: Tx,
  sessionId: string,
  rootTaskRunId?: string,
  executionEpoch?: number,
): Promise<number> {
  const conditions = [eq(subagentAttempts.sessionId, sessionId), eq(subagentAttempts.status, "running")];
  if (rootTaskRunId !== undefined) conditions.push(eq(subagentAttempts.rootTaskRunId, rootTaskRunId));
  if (executionEpoch !== undefined) conditions.push(eq(subagentAttempts.executionEpoch, executionEpoch));
  const rows = await tx
    .select({ count: sql<number>`count(*)::int` })
    .from(subagentAttempts)
    .where(and(...conditions));
  return rows[0]?.count ?? 0;
}

async function lockRootForAdmission(
  tx: Tx,
  sessionId: string,
  rootTaskRunId: string,
): Promise<SubagentRootRow> {
  await tx
    .insert(subagentRoots)
    .values({ sessionId, rootTaskRunId })
    .onConflictDoNothing({ target: subagentRoots.rootTaskRunId });
  const rows = await tx
    .select()
    .from(subagentRoots)
    .where(and(
      eq(subagentRoots.rootTaskRunId, rootTaskRunId),
      eq(subagentRoots.sessionId, sessionId),
    ))
    .for("update")
    .limit(1);
  const root = rows[0];
  if (root === undefined) throw new Error("Subagent root could not be created");
  const finalized = await tx
    .select({ id: subagentRootFinalizations.id })
    .from(subagentRootFinalizations)
    .where(and(
      eq(subagentRootFinalizations.rootTaskRunId, rootTaskRunId),
      eq(subagentRootFinalizations.executionEpoch, root.executionEpoch),
      isNotNull(subagentRootFinalizations.finalizedAt),
    ))
    .limit(1);
  if (finalized.length > 0) throw new RootFinalizedError();
  return root;
}

function clipSummary(value: string, maximum: number): string {
  return value.length <= maximum ? value : value.slice(0, maximum);
}

async function materializeAdmission(
  tx: Tx,
  dispatch: SubagentDispatchRow,
  activeRootTaskRunId: string,
  decisionActorRunId: string,
  schedulingReason: string | null,
  includeDeferredId: boolean,
): Promise<AdmissionOutcome> {
  const root = await lockRootForAdmission(tx, dispatch.sessionId, activeRootTaskRunId);
  const admittedAt = new Date();
  // IDs are deliberately allocated only after capacity and finalization fences
  // have admitted this request. Deferred/refused work has no child identity.
  const logicalWorkerId = newId();
  const attemptId = newId();
  const childSessionId = newId();
  const childRunId = newId();
  const firstMessageId = newId();
  const prompt = dispatch.prompt;
  if (prompt === null) throw new Error("Deferred prompt is unavailable before canonical child creation");

  await tx.insert(sessions).values({
    id: childSessionId,
    userId: dispatch.userId,
    title: `subagent: ${prompt.replace(/\s+/g, " ").slice(0, 60)}`,
    createdAt: admittedAt,
    updatedAt: admittedAt,
  });
  // Keep the existing cold-resume lineage reader compatible. The lifecycle
  // tables add precise root/attempt lineage; they do not replace this reader.
  await tx.insert(sessionAgentState).values({
    sessionId: childSessionId,
    state: { subagentParentSessionId: dispatch.sessionId },
  });
  let startedAt = new Date();
  if (startedAt.getTime() === admittedAt.getTime()) {
    // timestamptz(3) is millisecond precision. Ensure the two real transitions
    // remain distinguishable without assigning a synthetic future timestamp.
    await tx.execute(sql`SELECT pg_sleep(0.001)`);
    startedAt = new Date();
  }
  await tx.insert(messages).values({
    id: firstMessageId,
    sessionId: childSessionId,
    role: "user",
    content: prompt,
    createdAt: startedAt,
  });
  await tx.insert(runs).values({
    id: childRunId,
    sessionId: childSessionId,
    status: "running",
    promptMessageId: firstMessageId,
    startedAt,
    createdAt: startedAt,
  });
  await tx.insert(subagentLogicalWorkers).values({
    id: logicalWorkerId,
    requestId: dispatch.id,
    sessionId: dispatch.sessionId,
    userId: dispatch.userId,
    currentRootTaskRunId: activeRootTaskRunId,
    childSessionId,
    agentType: dispatch.agentType,
    status: "running",
    createdAt: startedAt,
    updatedAt: startedAt,
  });
  await tx.insert(subagentAttempts).values({
    id: attemptId,
    logicalWorkerId,
    sessionId: dispatch.sessionId,
    rootTaskRunId: activeRootTaskRunId,
    executionEpoch: root.executionEpoch,
    attemptNumber: 1,
    childSessionId,
    childRunId,
    promptMessageId: firstMessageId,
    status: "running",
    admittedAt,
    startedAt,
    createdAt: startedAt,
  });
  await tx
    .update(subagentDispatches)
    .set({
      state: "admitted",
      prompt: null,
      firstMessageId,
      admittedRootTaskRunId: activeRootTaskRunId,
      decisionActorRunId,
      schedulingReason,
      deferredAt: null,
      admittedAt,
      updatedAt: startedAt,
    })
    .where(eq(subagentDispatches.id, dispatch.id));
  await tx
    .update(subagentRoots)
    .set({
      activeWorkerCount: sql`${subagentRoots.activeWorkerCount} + 1`,
      updatedAt: startedAt,
    })
    .where(eq(subagentRoots.rootTaskRunId, activeRootTaskRunId));
  return {
    index: dispatch.requestIndex,
    admission: "admitted",
    logicalWorkerId,
    attemptId,
    childSessionId,
    childRunId,
    ...(includeDeferredId ? { deferredRequestId: dispatch.id } : {}),
  };
}

function dispatchValues(request: AdmissionRequest, now: Date): typeof subagentDispatches.$inferInsert {
  return {
    id: request.requestId,
    batchId: request.batchId,
    requestIndex: request.index,
    sessionId: request.sessionId,
    userId: request.userId,
    rootTaskRunId: request.rootTaskRunId,
    parentRunId: request.parentRunId,
    prompt: request.prompt,
    agentType: request.agentType?.trim() || "general-purpose",
    ...(request.tools !== undefined ? { tools: [...request.tools] } : {}),
    ...(request.disallowedTools !== undefined ? { disallowedTools: [...request.disallowedTools] } : {}),
    provenance: request.provenance,
    requestedAt: request.requestedAt,
    userPriorityHint: request.userPriorityHint ?? null,
    requestedModel: request.modelContext.requestedModel,
    byokKeyId: request.modelContext.byokKeyId,
    byokModel: request.modelContext.byokModel ?? null,
    actorUserId: request.modelContext.actorUserId,
    state: "awaiting_next_user_task",
    deferReason: "capacity_exhausted",
    requestedSequence: request.requestedAt.getTime(),
    deferredAt: now,
    createdAt: now,
    updatedAt: now,
  };
}

export async function admitDispatches(
  db: Db,
  requests: readonly AdmissionRequest[],
): Promise<AdmissionOutcome[]> {
  if (requests.length === 0) return [];
  const sessionId = requests[0]!.sessionId;
  if (requests.some((request) => request.sessionId !== sessionId)) {
    return requests.map((request) =>
      refusal(request.index, "invalid_batch", "One admission transaction cannot span sessions."));
  }
  return db.transaction(async (tx) => {
    const session = await lockSession(tx, sessionId);
    if (session === null) {
      return requests.map((request) => refusal(request.index, "not_found", "Session not found."));
    }
    const outcomes = new Map<AdmissionRequest, AdmissionOutcome>();
    const valid: AdmissionRequest[] = [];
    const rootCache = new Map<string, Promise<RootContext | null>>();
    for (const request of requests) {
      const invalid = validateRequest(request);
      if (invalid !== null) {
        outcomes.set(request, invalid);
        continue;
      }
      if (request.userId !== session.userId) {
        outcomes.set(request, refusal(request.index, "actor_mismatch", "Dispatch user does not own this session."));
        continue;
      }
      let rootPromise = rootCache.get(request.rootTaskRunId);
      if (rootPromise === undefined) {
        rootPromise = canonicalRoot(tx, sessionId, request.rootTaskRunId);
        rootCache.set(request.rootTaskRunId, rootPromise);
      }
      const root = await rootPromise;
      if (root === null || !(await runBelongsToSession(tx, sessionId, request.parentRunId))) {
        outcomes.set(request, refusal(request.index, "invalid_lineage", "Root and parent runs must belong to a canonical user task in this session."));
        continue;
      }
      valid.push(request);
    }

    const groups = new Map<string, AdmissionRequest[]>();
    for (const request of valid) {
      const group = groups.get(request.batchId) ?? [];
      group.push(request);
      groups.set(request.batchId, group);
    }
    for (const [batchId, group] of groups) {
      const first = group[0]!;
      await tx.insert(subagentBatches).values({
        id: batchId,
        sessionId,
        userId: first.userId,
        rootTaskRunId: first.rootTaskRunId,
        parentRunId: first.parentRunId,
        requestedAt: new Date(Math.min(...group.map((request) => request.requestedAt.getTime()))),
        requestCount: group.length,
      });
    }

    let active = await activeAttemptCount(tx, sessionId);
    const batchCounts = new Map<string, { admitted: number; deferred: number }>();
    for (const request of valid) {
      try {
        // A root exists even when every request defers: deferred work consumes
        // no slot and must not block that root's zero-active final gate.
        await lockRootForAdmission(tx, sessionId, request.rootTaskRunId);
      } catch (error) {
        if (!(error instanceof RootFinalizedError)) throw error;
        outcomes.set(request, refusal(request.index, "root_finalized", "The root execution epoch is already finalized."));
        continue;
      }
      const now = new Date();
      await tx.insert(subagentDispatches).values(dispatchValues(request, now));
      const [dispatch] = await tx
        .select()
        .from(subagentDispatches)
        .where(eq(subagentDispatches.id, request.requestId))
        .limit(1);
      const counts = batchCounts.get(request.batchId) ?? { admitted: 0, deferred: 0 };
      batchCounts.set(request.batchId, counts);
      if (active >= SESSION_ACTIVE_SUBAGENT_LIMIT) {
        outcomes.set(request, {
          index: request.index,
          admission: "awaiting_next_user_task",
          deferredRequestId: request.requestId,
        });
        counts.deferred += 1;
        continue;
      }
      try {
        const outcome = await materializeAdmission(
          tx,
          dispatch!,
          request.rootTaskRunId,
          request.parentRunId,
          null,
          false,
        );
        outcomes.set(request, outcome);
        active += 1;
        counts.admitted += 1;
      } catch (error) {
        if (!(error instanceof RootFinalizedError)) throw error;
        outcomes.set(request, refusal(request.index, "root_finalized", "The root execution epoch is already finalized."));
      }
    }
    for (const [batchId, counts] of batchCounts) {
      await tx
        .update(subagentBatches)
        .set({ admittedCount: counts.admitted, deferredCount: counts.deferred })
        .where(eq(subagentBatches.id, batchId));
    }
    await tx
      .update(subagentSessionAdmission)
      .set({ updatedAt: new Date() })
      .where(eq(subagentSessionAdmission.sessionId, sessionId));
    return requests.map((request, position) =>
      outcomes.get(request) ?? refusal(request.index, "invalid_request", `No admission outcome at position ${position}.`));
  });
}

export async function capacityForSession(
  db: Db,
  sessionId: string,
): Promise<{ active: number; limit: 50; available: number; awaiting: number }> {
  const rows = (await db.execute(sql`
    SELECT
      (SELECT count(*)::int FROM subagent_attempts
        WHERE session_id = ${sessionId} AND status = 'running') AS active,
      (SELECT count(*)::int FROM subagent_dispatches
        WHERE session_id = ${sessionId} AND state = 'awaiting_next_user_task') AS awaiting
  `)) as unknown as Array<{ active: number; awaiting: number }>;
  const active = rows[0]?.active ?? 0;
  return {
    active,
    limit: SESSION_ACTIVE_SUBAGENT_LIMIT,
    available: Math.max(0, SESSION_ACTIVE_SUBAGENT_LIMIT - active),
    awaiting: rows[0]?.awaiting ?? 0,
  };
}

export async function reconsiderDeferred(
  db: Db,
  input: {
    sessionId: string;
    rootTaskRunId: string;
    requestIds: readonly string[];
    actorRunId: string;
    schedulingReason: string;
  },
): Promise<AdmissionOutcome[]> {
  if (input.requestIds.length === 0) return [];
  return db.transaction(async (tx) => {
    const session = await lockSession(tx, input.sessionId);
    if (session === null) {
      return input.requestIds.map((_, index) => refusal(index, "not_found", "Session not found."));
    }
    const root = await canonicalRoot(tx, input.sessionId, input.rootTaskRunId);
    // Reconsideration is a main-run action inside the exact active next-user
    // root transaction. Same-session lineage alone cannot authorize a late
    // wake, a stale actor, or another root to launch deferred work.
    const exactMainActor = input.actorRunId === input.rootTaskRunId;
    let active = await activeAttemptCount(tx, input.sessionId);
    const outcomes: AdmissionOutcome[] = [];
    for (const [index, requestId] of input.requestIds.entries()) {
      const [dispatch] = await tx
        .select()
        .from(subagentDispatches)
        .where(and(eq(subagentDispatches.id, requestId), eq(subagentDispatches.sessionId, input.sessionId)))
        .for("update")
        .limit(1);
      if (dispatch === undefined) {
        outcomes.push(refusal(index, "not_found", "Deferred request not found."));
        continue;
      }
      if (dispatch.state !== "awaiting_next_user_task") {
        outcomes.push(refusal(index, "not_deferred", "Request is not deferred."));
        continue;
      }
      if (
        root === null ||
        root.status !== "running" ||
        root.runId === dispatch.rootTaskRunId ||
        dispatch.deferredAt === null ||
        root.messageCreatedAt.getTime() <= dispatch.deferredAt.getTime()
      ) {
        outcomes.push(refusal(index, "next_user_task_required", "An active, genuine later user root is required to admit deferred work."));
        continue;
      }
      if (!exactMainActor) {
        outcomes.push(refusal(index, "invalid_actor_lineage", "The actor must be the exact main run of the active next-user root."));
        continue;
      }
      if (active >= SESSION_ACTIVE_SUBAGENT_LIMIT) {
        outcomes.push({
          index,
          admission: "awaiting_next_user_task",
          deferredRequestId: dispatch.id,
        });
        continue;
      }
      try {
        const outcome = await materializeAdmission(
          tx,
          { ...dispatch, requestIndex: index },
          input.rootTaskRunId,
          input.actorRunId,
          input.schedulingReason,
          true,
        );
        outcomes.push(outcome);
        active += 1;
      } catch (error) {
        if (!(error instanceof RootFinalizedError)) throw error;
        outcomes.push(refusal(index, "root_finalized", "The root execution epoch is already finalized."));
      }
    }
    return outcomes;
  });
}

export async function updateDeferred(
  db: Db,
  input: {
    sessionId: string;
    deferredRequestId: string;
    actorRunId: string;
    cancel?: boolean;
    userPriorityHint?: number;
  },
): Promise<"updated" | "not_found" | "not_deferred"> {
  if (input.userPriorityHint !== undefined && !Number.isInteger(input.userPriorityHint)) {
    throw new RangeError("userPriorityHint must be an integer");
  }
  return db.transaction(async (tx) => {
    const session = await lockSession(tx, input.sessionId);
    if (session === null || !(await runBelongsToSession(tx, input.sessionId, input.actorRunId))) {
      return "not_found";
    }
    const [dispatch] = await tx
      .select()
      .from(subagentDispatches)
      .where(and(
        eq(subagentDispatches.id, input.deferredRequestId),
        eq(subagentDispatches.sessionId, input.sessionId),
      ))
      .for("update")
      .limit(1);
    if (dispatch === undefined) return "not_found";
    if (dispatch.state !== "awaiting_next_user_task") return "not_deferred";
    const now = new Date();
    await tx
      .update(subagentDispatches)
      .set({
        ...(input.cancel === true ? { state: "cancelled" as const, cancelledAt: now } : {}),
        ...(input.userPriorityHint !== undefined ? { userPriorityHint: input.userPriorityHint } : {}),
        updatedAt: now,
      })
      .where(eq(subagentDispatches.id, dispatch.id));
    await tx.insert(subagentControlAudit).values({
      id: newId(),
      sessionId: input.sessionId,
      actorRunId: input.actorRunId,
      rootTaskRunId: dispatch.rootTaskRunId,
      deferredRequestId: dispatch.id,
      action: input.cancel === true ? "deferred_cancel" : "deferred_reprioritize",
      decision: "performed",
      requestedTransition: input.cancel === true ? "cancelled" : "awaiting_next_user_task",
      performedTransition: input.cancel === true ? "cancelled" : "awaiting_next_user_task",
      outcome: "updated",
      metadata: {
        previousPriorityHint: dispatch.userPriorityHint,
        userPriorityHint: input.userPriorityHint ?? dispatch.userPriorityHint,
      },
      createdAt: now,
    });
    return "updated";
  });
}

export async function beforeRootFinalResponse(
  db: Db,
  input: { rootTaskRunId: string; executionEpoch: number },
): Promise<"allow" | "wait"> {
  return db.transaction(async (tx) => {
    const [root] = await tx
      .select()
      .from(subagentRoots)
      .where(eq(subagentRoots.rootTaskRunId, input.rootTaskRunId))
      .for("update")
      .limit(1);
    if (root === undefined || root.executionEpoch !== input.executionEpoch) return "wait";
    const finalized = await tx
      .select({ id: subagentRootFinalizations.id })
      .from(subagentRootFinalizations)
      .where(and(
        eq(subagentRootFinalizations.rootTaskRunId, input.rootTaskRunId),
        eq(subagentRootFinalizations.executionEpoch, input.executionEpoch),
        isNotNull(subagentRootFinalizations.finalizedAt),
      ))
      .limit(1);
    if (finalized.length > 0) return "wait";
    const active = await activeAttemptCount(
      tx,
      root.sessionId,
      input.rootTaskRunId,
      input.executionEpoch,
    );
    return active === 0 ? "allow" : "wait";
  });
}

function canonicalTerminalOutcome(status: string): "completed" | "failed" | "cancelled" | null {
  return status === "completed" || status === "failed" || status === "cancelled"
    ? status
    : null;
}

async function settlementSummary(
  tx: Tx,
  attempt: SubagentAttemptRow,
  outcome: TerminalOutcome,
  runError: string | null,
): Promise<string> {
  const latest = await tx
    .select({ content: messages.content })
    .from(messages)
    .where(and(eq(messages.sessionId, attempt.childSessionId), eq(messages.role, "assistant")))
    .orderBy(sql`${messages.id} DESC`)
    .limit(1);
  const partial = latest[0]?.content.trim() ?? "";
  if (outcome === "completed") {
    return clipSummary(partial || "Completed without a final response.", 1200);
  }
  const lead = outcome === "failed"
    ? `Failed: ${runError?.trim() || "No error detail was recorded."}`
    : outcome === "cancelled"
      ? "Cancelled before finishing."
      : "Timed out before finishing.";
  const withPartial = partial === "" ? lead : `${lead}\n\nUnverified partial work:\n${partial}`;
  return clipSummary(withPartial, 4000);
}

export async function settleAttemptAndMaybeWake(
  db: Db,
  input: { attemptId: string; outcome: TerminalOutcome },
): Promise<{ rootTaskRunId: string; shouldWake: boolean }> {
  return db.transaction(async (tx) => {
    const [attempt] = await tx
      .select()
      .from(subagentAttempts)
      .where(eq(subagentAttempts.id, input.attemptId))
      .for("update")
      .limit(1);
    if (attempt === undefined) throw new Error("Unknown subagent attempt");
    if (attempt.status !== "running") {
      return { rootTaskRunId: attempt.rootTaskRunId, shouldWake: false };
    }
    const [root] = await tx
      .select()
      .from(subagentRoots)
      .where(and(
        eq(subagentRoots.rootTaskRunId, attempt.rootTaskRunId),
        eq(subagentRoots.sessionId, attempt.sessionId),
      ))
      .for("update")
      .limit(1);
    if (root === undefined) throw new Error("Subagent attempt has no durable root");
    const [childRun] = await tx
      .select()
      .from(runs)
      .where(eq(runs.id, attempt.childRunId))
      .for("update")
      .limit(1);
    if (childRun === undefined) throw new Error("Subagent attempt has no canonical child run");
    const settledAt = new Date();
    let authoritativeRun = childRun;
    let authoritativeOutcome: TerminalOutcome | null = canonicalTerminalOutcome(childRun.status);
    let endedAt = settledAt;
    if (authoritativeOutcome !== null) {
      // A processor, cancellation, or stale-run sweep may have terminalized
      // the canonical run first. Its outcome and timestamps win; settlement
      // still releases the attempt and records a consistent report.
      endedAt = childRun.finishedAt ?? settledAt;
    } else {
      if (childRun.status !== "queued" && childRun.status !== "running") {
        throw new Error(`Unknown canonical child run status: ${childRun.status}`);
      }
      const requestedRunStatus = input.outcome === "completed"
        ? "completed"
        : input.outcome === "cancelled"
          ? "cancelled"
          : "failed";
      const transitioned = await tx
        .update(runs)
        .set({
          status: requestedRunStatus,
          finishedAt: settledAt,
          ...(input.outcome === "timeout" && childRun.lastError == null
            ? { lastError: "Subagent timed out." }
            : input.outcome === "failed" && childRun.lastError == null
              ? { lastError: "Subagent failed." }
              : {}),
        })
        .where(and(
          eq(runs.id, attempt.childRunId),
          inArray(runs.status, [...ACTIVE_RUN_STATUSES]),
        ))
        .returning();
      if (transitioned[0] !== undefined) {
        authoritativeRun = transitioned[0];
        authoritativeOutcome = input.outcome;
        endedAt = authoritativeRun.finishedAt ?? settledAt;
      } else {
        // Preserve runs.finish's conditional terminal semantics even if a
        // writer does not participate in our row-lock protocol.
        const [currentRun] = await tx
          .select()
          .from(runs)
          .where(eq(runs.id, attempt.childRunId))
          .for("update")
          .limit(1);
        if (currentRun === undefined) throw new Error("Canonical child run disappeared during settlement");
        const currentOutcome = canonicalTerminalOutcome(currentRun.status);
        if (currentOutcome === null) {
          throw new Error(`Canonical child run is not terminal after a lost transition: ${currentRun.status}`);
        }
        authoritativeRun = currentRun;
        authoritativeOutcome = currentOutcome;
        endedAt = currentRun.finishedAt ?? settledAt;
      }
    }
    if (authoritativeOutcome === null) throw new Error("Settlement has no authoritative outcome");
    const summary = await settlementSummary(
      tx,
      attempt,
      authoritativeOutcome,
      authoritativeRun.lastError,
    );
    await tx
      .update(subagentAttempts)
      .set({ status: authoritativeOutcome, endedAt })
      .where(eq(subagentAttempts.id, attempt.id));
    await tx
      .update(subagentLogicalWorkers)
      .set({ status: authoritativeOutcome, currentRootTaskRunId: attempt.rootTaskRunId, updatedAt: settledAt })
      .where(eq(subagentLogicalWorkers.id, attempt.logicalWorkerId));
    await tx
      .insert(subagentReports)
      .values({
        id: newId(),
        sessionId: attempt.sessionId,
        logicalWorkerId: attempt.logicalWorkerId,
        attemptId: attempt.id,
        childSessionId: attempt.childSessionId,
        childRunId: attempt.childRunId,
        agentType: (await tx
          .select({ agentType: subagentLogicalWorkers.agentType })
          .from(subagentLogicalWorkers)
          .where(eq(subagentLogicalWorkers.id, attempt.logicalWorkerId))
          .limit(1))[0]?.agentType ?? "general-purpose",
        status: authoritativeOutcome,
        summary,
        createdAt: settledAt,
      })
      .onConflictDoNothing({ target: subagentReports.attemptId });
    await tx
      .update(subagentRoots)
      .set({
        activeWorkerCount: sql`GREATEST(${subagentRoots.activeWorkerCount} - 1, 0)`,
        updatedAt: settledAt,
      })
      .where(eq(subagentRoots.rootTaskRunId, root.rootTaskRunId));
    const remaining = await activeAttemptCount(
      tx,
      attempt.sessionId,
      attempt.rootTaskRunId,
      attempt.executionEpoch,
    );
    let shouldWake = false;
    if (remaining === 0) {
      const [parentRun] = await tx
        .select({ status: runs.status })
        .from(runs)
        .where(eq(runs.id, attempt.rootTaskRunId))
        .limit(1);
      const parentActive = parentRun?.status === "queued" || parentRun?.status === "running";
      if (!parentActive) {
        const wake = await tx
          .insert(subagentRootFinalizations)
          .values({
            id: newId(),
            rootTaskRunId: attempt.rootTaskRunId,
            sessionId: attempt.sessionId,
            executionEpoch: attempt.executionEpoch,
            activeAttemptIds: [],
            wakeRequestedAt: settledAt,
            createdAt: settledAt,
          })
          .onConflictDoNothing({
            target: [subagentRootFinalizations.rootTaskRunId, subagentRootFinalizations.executionEpoch],
          })
          .returning({ id: subagentRootFinalizations.id });
        shouldWake = wake.length > 0;
      }
    }
    return { rootTaskRunId: attempt.rootTaskRunId, shouldWake };
  });
}

export async function snapshotRootFinalization(
  db: Db,
  input: { rootTaskRunId: string },
): Promise<RootFinalizationSnapshotRecord | null> {
  return db.transaction(async (tx) => {
    const [root] = await tx
      .select()
      .from(subagentRoots)
      .where(eq(subagentRoots.rootTaskRunId, input.rootTaskRunId))
      .for("update")
      .limit(1);
    if (root === undefined) return null;
    const active = await tx
      .select({ id: subagentAttempts.id })
      .from(subagentAttempts)
      .where(and(
        eq(subagentAttempts.rootTaskRunId, input.rootTaskRunId),
        eq(subagentAttempts.executionEpoch, root.executionEpoch),
        eq(subagentAttempts.status, "running"),
      ))
      .orderBy(asc(subagentAttempts.id));
    const [finalized] = await tx
      .select({ id: subagentRootFinalizations.id })
      .from(subagentRootFinalizations)
      .where(and(
        eq(subagentRootFinalizations.rootTaskRunId, input.rootTaskRunId),
        eq(subagentRootFinalizations.executionEpoch, root.executionEpoch),
        isNotNull(subagentRootFinalizations.finalizedAt),
      ))
      .limit(1);
    const reports = await readDurableSubagentReportSnapshotWithin(tx, {
      sessionId: root.sessionId,
      rootTaskRunId: input.rootTaskRunId,
      pageSize: 50,
    }, drainReports);
    return {
      rootTaskRunId: root.rootTaskRunId,
      sessionId: root.sessionId,
      executionEpoch: root.executionEpoch,
      activeAttemptIds: active.map((attempt) => attempt.id),
      finalized: finalized !== undefined,
      reports,
    };
  });
}

export async function markRootFinalized(
  db: Db,
  input: {
    rootTaskRunId: string;
    executionEpoch: number;
    activeAttemptIds: readonly string[];
    /** Optional for legacy callers; the root-finalization adapter always supplies it. */
    expectedReportAttemptIds?: readonly string[];
  },
): Promise<"committed" | "fenced"> {
  return db.transaction(async (tx) => {
    const [root] = await tx
      .select()
      .from(subagentRoots)
      .where(eq(subagentRoots.rootTaskRunId, input.rootTaskRunId))
      .for("update")
      .limit(1);
    if (root === undefined || root.executionEpoch !== input.executionEpoch) return "fenced";
    const current = await tx
      .select({ id: subagentAttempts.id })
      .from(subagentAttempts)
      .where(and(
        eq(subagentAttempts.rootTaskRunId, input.rootTaskRunId),
        eq(subagentAttempts.executionEpoch, input.executionEpoch),
        eq(subagentAttempts.status, "running"),
      ))
      .orderBy(asc(subagentAttempts.id));
    const currentIds = current.map((row) => row.id);
    const suppliedIds = [...input.activeAttemptIds].sort();
    if (
      currentIds.length !== 0 ||
      currentIds.length !== suppliedIds.length ||
      currentIds.some((id, index) => id !== suppliedIds[index])
    ) {
      return "fenced";
    }
    if (input.expectedReportAttemptIds !== undefined) {
      // Reports are append-only and unique per attempt. Comparing this set
      // under the root lock closes admit -> settle -> empty-running-set ABA
      // without requiring executionEpoch to change on every admission.
      const reportRows = await tx
        .select({ attemptId: subagentReports.attemptId })
        .from(subagentReports)
        .innerJoin(subagentAttempts, eq(subagentReports.attemptId, subagentAttempts.id))
        .where(eq(subagentAttempts.rootTaskRunId, input.rootTaskRunId))
        .orderBy(asc(subagentReports.attemptId));
      const currentReportIds = reportRows.map((report) => report.attemptId);
      const expectedReportIds = [...input.expectedReportAttemptIds].sort();
      if (
        currentReportIds.length !== expectedReportIds.length ||
        currentReportIds.some((id, index) => id !== expectedReportIds[index])
      ) {
        return "fenced";
      }
    }
    const [existing] = await tx
      .select()
      .from(subagentRootFinalizations)
      .where(and(
        eq(subagentRootFinalizations.rootTaskRunId, input.rootTaskRunId),
        eq(subagentRootFinalizations.executionEpoch, input.executionEpoch),
      ))
      .for("update")
      .limit(1);
    if (existing?.finalizedAt != null) return "fenced";
    const now = new Date();
    if (existing !== undefined) {
      await tx
        .update(subagentRootFinalizations)
        .set({ finalizedAt: now, activeAttemptIds: suppliedIds })
        .where(eq(subagentRootFinalizations.id, existing.id));
      return "committed";
    }
    const inserted = await tx
      .insert(subagentRootFinalizations)
      .values({
        id: newId(),
        rootTaskRunId: input.rootTaskRunId,
        sessionId: root.sessionId,
        executionEpoch: input.executionEpoch,
        activeAttemptIds: suppliedIds,
        finalizedAt: now,
        createdAt: now,
      })
      .onConflictDoNothing({
        target: [subagentRootFinalizations.rootTaskRunId, subagentRootFinalizations.executionEpoch],
      })
      .returning({ id: subagentRootFinalizations.id });
    return inserted.length === 1 ? "committed" : "fenced";
  });
}

export async function drainReports(
  db: Db,
  input: {
    rootTaskRunId: string;
    executionEpoch: number;
    activeAttemptIds: readonly string[];
  },
): Promise<"committed" | "fenced"> {
  return db.transaction(async (tx) => {
    const [root] = await tx
      .select()
      .from(subagentRoots)
      .where(eq(subagentRoots.rootTaskRunId, input.rootTaskRunId))
      .for("update")
      .limit(1);
    if (root === undefined || root.executionEpoch !== input.executionEpoch) return "fenced";
    const current = await tx
      .select({ id: subagentAttempts.id })
      .from(subagentAttempts)
      .where(and(
        eq(subagentAttempts.rootTaskRunId, input.rootTaskRunId),
        eq(subagentAttempts.executionEpoch, input.executionEpoch),
        eq(subagentAttempts.status, "running"),
      ))
      .orderBy(asc(subagentAttempts.id));
    const currentIds = current.map((row) => row.id);
    const suppliedIds = [...input.activeAttemptIds].sort();
    if (
      currentIds.length !== 0 ||
      currentIds.length !== suppliedIds.length ||
      currentIds.some((id, index) => id !== suppliedIds[index])
    ) {
      return "fenced";
    }
    const [existing] = await tx
      .select()
      .from(subagentRootFinalizations)
      .where(and(
        eq(subagentRootFinalizations.rootTaskRunId, input.rootTaskRunId),
        eq(subagentRootFinalizations.executionEpoch, input.executionEpoch),
      ))
      .for("update")
      .limit(1);
    if (existing?.finalizedAt != null) return "fenced";
    const now = new Date();
    if (existing !== undefined) {
      await tx
        .update(subagentRootFinalizations)
        .set({ finalizedAt: now, activeAttemptIds: suppliedIds })
        .where(eq(subagentRootFinalizations.id, existing.id));
      return "committed";
    }
    const inserted = await tx
      .insert(subagentRootFinalizations)
      .values({
        id: newId(),
        rootTaskRunId: input.rootTaskRunId,
        sessionId: root.sessionId,
        executionEpoch: input.executionEpoch,
        activeAttemptIds: suppliedIds,
        finalizedAt: now,
        createdAt: now,
      })
      .onConflictDoNothing({
        target: [subagentRootFinalizations.rootTaskRunId, subagentRootFinalizations.executionEpoch],
      })
      .returning({ id: subagentRootFinalizations.id });
    return inserted.length === 1 ? "committed" : "fenced";
  });
}

export async function drainReports(
  db: Db,
  input: { sessionId: string; afterId?: string; limit: number },
): Promise<{ items: SubagentReportRecord[]; nextCursor: string | null }> {
  if (!Number.isInteger(input.limit) || input.limit < 1 || input.limit > 50) {
    throw new RangeError("Report page limit must be an integer from 1 to 50");
  }
  const conditions = [eq(subagentReports.sessionId, input.sessionId)];
  if (input.afterId !== undefined) conditions.push(gt(subagentReports.id, input.afterId));
  const rows = await db
    .select({
      report: subagentReports,
      task: messages.content,
    })
    .from(subagentReports)
    .innerJoin(subagentAttempts, eq(subagentReports.attemptId, subagentAttempts.id))
    .innerJoin(messages, eq(subagentAttempts.promptMessageId, messages.id))
    .where(and(...conditions))
    .orderBy(asc(subagentReports.id))
    .limit(input.limit + 1);
  const hasMore = rows.length > input.limit;
  const page = hasMore ? rows.slice(0, input.limit) : rows;
  return {
    items: page.map(({ report, task }) => ({
      logicalWorkerId: report.logicalWorkerId,
      attemptId: report.attemptId,
      childSessionId: report.childSessionId,
      childRunId: report.childRunId,
      agentType: report.agentType,
      status: report.status,
      summary: report.summary,
      task,
      at: report.createdAt.getTime(),
      ...(report.structuredReport !== null ? { structuredReport: report.structuredReport } : {}),
    })),
    nextCursor: hasMore && page.length > 0 ? page[page.length - 1]!.report.id : null,
  };
}
