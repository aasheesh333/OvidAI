import type { Db } from "../src/client.js";
import { messages, newId, runs, sessions, users } from "../src/repos.js";
import {
  admitDispatches,
  markRootFinalized,
  settleAttemptAndMaybeWake,
  snapshotRootFinalization,
} from "../src/subagentAdmission.js";
import { fingerprintRootFinalizationReports } from "../src/subagentReportSnapshots.js";

export interface SessionCleanupFixture {
  userId: string;
  sessionId: string;
  runId: string;
  messageId: string;
  requestId: string;
  attemptId: string;
  childSessionId: string;
}

/** Real 0033 rows plus a complete admitted/settled 0034 descendant graph. */
export async function seedSessionCleanupFixture(
  db: Db,
  userId: string,
): Promise<SessionCleanupFixture> {
  await users.ensure(db, userId, null);
  const session = await sessions.create(db, userId, "0033 cleanup");
  const message = await messages.append(db, {
    sessionId: session.id,
    role: "user",
    content: "root cleanup prompt",
  });
  const run = await runs.create(db, { sessionId: session.id, promptMessageId: message.id });
  if (!(await runs.claimNext(db, run.id))) throw new Error("fixture root was not claimed");

  const requestId = newId();
  await db.$client`
    INSERT INTO system_requests
      (request_id, user_id, session_id, run_id, kind, safe_payload, sensitive, status, expires_at, version)
    VALUES
      (${requestId}, ${userId}, ${session.id}, ${run.id}, 'approval', '{}'::jsonb,
       false, 'resolved', now() + interval '1 hour', 2)`;
  await db.$client`
    INSERT INTO system_request_responses
      (response_id, request_id, user_id, request_version, client_response_id, response, response_digest)
    VALUES
      (${newId()}, ${requestId}, ${userId}, 1, ${`cleanup-response-${newId()}`},
       '{"approve":true}'::jsonb, ${"a".repeat(64)})`;
  await db.$client`
    INSERT INTO run_outbox
      (outbox_id, actor_user_id, session_id, run_id, user_message_id, idempotency_key,
       status, request_payload, body_payload, job_id)
    VALUES
      (${newId()}, ${userId}, ${session.id}, ${run.id}, ${message.id},
       ${`cleanup-turn-${newId()}`}, 'queued',
       ${JSON.stringify({ schemaVersion: 1, idempotencyKey: "cleanup", text: "root cleanup prompt" })}::jsonb,
       ${JSON.stringify({ ownerUserId: userId, requestedModel: null })}::jsonb,
       ${run.id})`;

  const [admission] = await admitDispatches(db, [{
    requestId: newId(),
    index: 0,
    sessionId: session.id,
    userId,
    rootTaskRunId: run.id,
    parentRunId: run.id,
    batchId: newId(),
    prompt: "real 0034 cleanup descendant",
    provenance: "server",
    requestedAt: new Date(),
    modelContext: {
      requestedModel: null,
      byokKeyId: null,
      actorUserId: userId,
    },
  }]);
  if (admission?.admission !== "admitted") {
    throw new Error(`0034 fixture was not admitted: ${JSON.stringify(admission)}`);
  }
  const attemptId = admission.attemptId!;
  const logicalWorkerId = admission.logicalWorkerId!;
  const childSessionId = admission.childSessionId!;
  await settleAttemptAndMaybeWake(db, { attemptId, outcome: "completed" });
  const snapshot = await snapshotRootFinalization(db, { rootTaskRunId: run.id });
  if (snapshot === null) throw new Error("0034 fixture root snapshot is missing");
  if ((await markRootFinalized(db, {
    rootTaskRunId: run.id,
    executionEpoch: snapshot.executionEpoch,
    activeAttemptIds: snapshot.activeAttemptIds,
    expectedReportAttemptIds: snapshot.reports.map((report) => report.attemptId),
    expectedReportFingerprint: fingerprintRootFinalizationReports(snapshot.reports),
  })) !== "committed") {
    throw new Error("0034 fixture root was not finalized");
  }
  const checkpointId = newId();
  await db.$client`
    INSERT INTO subagent_checkpoints
      (id, session_id, logical_worker_id, attempt_id, root_task_run_id, hash, verified_at)
    VALUES
      (${checkpointId}, ${session.id}, ${logicalWorkerId}, ${attemptId},
       ${run.id}, 'cleanup-checkpoint', now())`;
  await db.$client`
    INSERT INTO subagent_control_audit
      (id, session_id, actor_run_id, root_task_run_id, logical_worker_id,
       source_attempt_id, target_logical_worker_id, checkpoint_id, deferred_request_id,
       action, decision)
    VALUES
      (${newId()}, ${session.id}, ${run.id}, ${run.id}, ${logicalWorkerId},
       ${attemptId}, ${logicalWorkerId}, ${checkpointId}, ${admission.deferredRequestId ?? null},
       'cleanup_test', 'admitted')`;

  return {
    userId,
    sessionId: session.id,
    runId: run.id,
    messageId: message.id,
    requestId,
    attemptId,
    childSessionId,
  };
}

export const SESSION_CLEANUP_TABLES = [
  "system_request_responses",
  "system_requests",
  "run_outbox",
  "subagent_control_audit",
  "subagent_reports",
  "subagent_checkpoints",
  "subagent_root_finalizations",
  "subagent_attempts",
  "subagent_logical_workers",
  "subagent_dispatches",
  "subagent_batches",
  "subagent_roots",
  "subagent_session_admission",
] as const;

export async function expectSessionCleanupFixtureGone(
  db: Db,
  options: { preserveCanonicalRows?: boolean } = {},
): Promise<void> {
  for (const table of SESSION_CLEANUP_TABLES) {
    const rows = await db.$client.unsafe(`SELECT count(*)::int AS count FROM ${table}`);
    if (rows[0]?.count !== 0) {
      throw new Error(`${table} retained ${String(rows[0]?.count)} rows after cleanup`);
    }
  }
  if (options.preserveCanonicalRows === true) return;
  const remaining = await db.$client`
    SELECT
      (SELECT count(*)::int FROM messages) AS messages,
      (SELECT count(*)::int FROM runs) AS runs,
      (SELECT count(*)::int FROM sessions) AS sessions`;
  if (remaining[0]?.messages !== 0 || remaining[0]?.runs !== 0 || remaining[0]?.sessions !== 0) {
    throw new Error(`canonical rows remained: ${JSON.stringify(remaining[0])}`);
  }
}
