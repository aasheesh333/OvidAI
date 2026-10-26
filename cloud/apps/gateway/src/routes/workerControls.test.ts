import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { EventLog } from "@ovid/events";

import {
  admitDispatches,
  messages,
  newId,
  runs,
  sessions,
  users,
  type AdmissionOutcome,
  type Db,
} from "@ovid/db";
import type { QueueServices } from "@ovid/queue";
import type { ActivityTracker } from "@ovid/storage";

import { buildGateway } from "../app.js";
import { cancelActiveRun } from "./runs.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
  type QueueAdd,
} from "../test/stubs.js";

/**
 * UNEXECUTED under the heavy-command pause. These are real authenticated-route
 * regressions, not ToolContext stand-ins or source-text assertions. The expected
 * refusals are a regression specification, not an observed RED/GREEN result.
 */
describe.skipIf(!TEST_DATABASE_URL)("authenticated worker-control route fencing (real postgres)", () => {
  let db: Db;
  const apps: FastifyInstance[] = [];

  beforeAll(async () => {
    db = await openTestDb();
  }, 60_000);

  afterEach(async () => {
    while (apps.length > 0) await apps.pop()!.close();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  function makeApp() {
    const base = stubQueues();
    const removes: string[] = [];
    const appended: unknown[] = [];
    const activityBumps: string[] = [];
    const activityReads: string[] = [];
    const activityReadMany: string[][] = [];
    let eventSeq = 0;
    const activity: ActivityTracker = {
      async bump(sessionId) { activityBumps.push(sessionId); },
      async read(sessionId) {
        activityReads.push(sessionId);
        return null;
      },
      async readMany(sessionIds) {
        activityReadMany.push([...sessionIds]);
        return new Map<string, number>();
      },
    };
    const queues = {
      ...base.queues,
      agentRuns: {
        add: base.queues.agentRuns.add,
        remove: async (jobId: string) => { removes.push(jobId); },
        client: Promise.resolve({ ping: async () => "PONG" }),
      },
    } as unknown as QueueServices;
    const events = {
      async append(sessionId: string, type: string, payload: Record<string, unknown>) {
        const event = { sessionId, seq: `${++eventSeq}-0`, type, payload, ts: new Date() };
        appended.push(event);
        return event;
      },
    } as unknown as EventLog;
    const deps = {
      system: stubSystemBus(),
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events,
      activity,
    };
    const app = buildGateway(deps);
    apps.push(app);
    return {
      app,
      deps,
      adds: base.adds as QueueAdd[],
      removes,
      appended,
      activityBumps,
      activityReads,
      activityReadMany,
    };
  }

  async function seedWorker(): Promise<{
    uid: string;
    parentSessionId: string;
    rootRunId: string;
    admitted: AdmissionOutcome;
  }> {
    const uid = testUid("worker-control-route");
    await users.ensure(db, uid, `${uid}@stub.test`);
    const parent = await sessions.create(db, uid, "parent root");
    const prompt = await messages.append(db, {
      sessionId: parent.id,
      role: "user",
      content: "dispatch one child",
    });
    const root = await runs.create(db, {
      sessionId: parent.id,
      promptMessageId: prompt.id,
    });
    expect(await runs.claimNext(db, root.id)).toBe(true);
    const [admitted] = await admitDispatches(db, [{
      requestId: newId(),
      index: 0,
      sessionId: parent.id,
      userId: uid,
      rootTaskRunId: root.id,
      parentRunId: root.id,
      batchId: newId(),
      prompt: "child work that public clients must not mutate",
      provenance: "web",
      requestedAt: new Date(),
      modelContext: {
        requestedModel: null,
        byokKeyId: null,
        actorUserId: uid,
      },
    }]);
    expect(admitted).toMatchObject({ admission: "admitted" });
    return {
      uid,
      parentSessionId: parent.id,
      rootRunId: root.id,
      admitted: admitted!,
    };
  }

  async function childLifecycleSnapshot(ids: {
    sessionId: string;
    attemptId: string;
    workerId: string;
  }) {
    const session = await db.$client`
      SELECT title, mode, pinned_at, updated_at, deleted_at
        FROM sessions WHERE id = ${ids.sessionId}`;
    const sessionAgentState = await db.$client`
      SELECT state FROM session_agent_state WHERE session_id = ${ids.sessionId}`;
    const childRuns = await db.$client`
      SELECT id, status, cancel_requested, last_error, finished_at
        FROM runs WHERE session_id = ${ids.sessionId} ORDER BY id`;
    const childMessages = await db.$client`
      SELECT id, role, content, client_msg_id, created_at
        FROM messages WHERE session_id = ${ids.sessionId} ORDER BY id`;
    const attempt = await db.$client`
      SELECT status, ended_at FROM subagent_attempts WHERE id = ${ids.attemptId}`;
    const worker = await db.$client`
      SELECT status, updated_at FROM subagent_logical_workers WHERE id = ${ids.workerId}`;
    const mirroredEvents = await db.$client`
      SELECT seq, type, payload, ts FROM session_event_mirror
       WHERE session_id = ${ids.sessionId} ORDER BY seq`;
    return {
      session,
      sessionAgentState,
      runs: childRuns,
      messages: childMessages,
      attempt,
      worker,
      mirroredEvents,
    };
  }

  it("denies an authenticated owner's generic cancel against a child run without mutation", async () => {
    const { app, removes, appended } = makeApp();
    const seeded = await seedWorker();
    const childRunId = seeded.admitted.childRunId!;
    const response = await app.inject({
      method: "POST",
      url: `/cloud/v1/runs/${childRunId}/cancel`,
      headers: authHeaders(seeded.uid),
    });
    expect(response.statusCode).toBe(403);
    expect(response.json()).toMatchObject({ error: { code: "worker_control_main_only" } });
    expect(removes).toEqual([]);
    expect(appended).toEqual([]);
    const stored = await db.$client`
      SELECT status, cancel_requested FROM runs WHERE id = ${childRunId}`;
    expect(stored[0]).toMatchObject({ status: "running", cancel_requested: false });
    const attempt = await db.$client`
      SELECT status FROM subagent_attempts WHERE id = ${seeded.admitted.attemptId!}`;
    expect(attempt[0]!.status).toBe("running");
  });

  it("fences the shared cancelActiveRun helper before its first child mutation", async () => {
    const { app, deps, removes, appended } = makeApp();
    const seeded = await seedWorker();
    const childRunId = seeded.admitted.childRunId!;
    const result = await cancelActiveRun(deps, app.log, seeded.uid, childRunId);
    expect(result).toBe("refused");
    expect(removes).toEqual([]);
    expect(appended).toEqual([]);
    const stored = await db.$client`
      SELECT status, cancel_requested FROM runs WHERE id = ${childRunId}`;
    expect(stored[0]).toMatchObject({ status: "running", cancel_requested: false });
  });

  it("denies generic cancel for a current follow-up run, not only the immutable initial run", async () => {
    const { app, deps, removes, appended } = makeApp();
    const seeded = await seedWorker();
    const followUpMessage = await messages.append(db, {
      sessionId: seeded.admitted.childSessionId!,
      role: "user",
      content: "main-mediated current follow-up",
    });
    const followUp = await runs.create(db, {
      sessionId: seeded.admitted.childSessionId!,
      promptMessageId: followUpMessage.id,
    });
    expect(followUp.id).not.toBe(seeded.admitted.childRunId);

    const direct = await app.inject({
      method: "POST",
      url: `/cloud/v1/runs/${followUp.id}/cancel`,
      headers: authHeaders(seeded.uid),
    });
    expect(direct.statusCode).toBe(403);
    expect(direct.json()).toMatchObject({ error: { code: "worker_control_main_only" } });
    expect(await cancelActiveRun(deps, app.log, seeded.uid, followUp.id)).toBe("refused");
    expect(removes).toEqual([]);
    expect(appended).toEqual([]);
    const stored = await runs.get(db, followUp.id, seeded.uid);
    expect(stored).toMatchObject({ status: "queued", cancelRequested: false });
    const initial = await runs.get(db, seeded.admitted.childRunId!, seeded.uid);
    expect(initial).toMatchObject({ status: "running", cancelRequested: false });
  });

  it("denies a child send even when clientMsgId would replay an accepted run", async () => {
    const { app, deps, adds, removes, appended, activityBumps } = makeApp();
    const seeded = await seedWorker();
    const ids = {
      sessionId: seeded.admitted.childSessionId!,
      attemptId: seeded.admitted.attemptId!,
      workerId: seeded.admitted.logicalWorkerId!,
    };
    const clientMsgId = `child-replay-${newId()}`;
    await db.$client`
      UPDATE messages SET client_msg_id = ${clientMsgId}
       WHERE id = (SELECT prompt_message_id FROM runs WHERE id = ${seeded.admitted.childRunId!})`;
    const before = await childLifecycleSnapshot(ids);
    const response = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${ids.sessionId}/messages`,
      headers: authHeaders(seeded.uid),
      payload: { content: "direct client follow-up bypass", clientMsgId },
    });
    expect(response.statusCode).toBe(403);
    expect(response.json()).toMatchObject({ error: { code: "worker_control_main_only" } });
    expect(deps.mint.calls).toEqual([]);
    expect(activityBumps).toEqual([]);
    expect(adds).toEqual([]);
    expect(removes).toEqual([]);
    expect(appended).toEqual([]);
    expect(await childLifecycleSnapshot(ids)).toEqual(before);
  });

  it("refuses a valid title/mode/pinned PATCH of a live child without lifecycle mutation", async () => {
    const { app, adds, removes, appended } = makeApp();
    const seeded = await seedWorker();
    const ids = {
      sessionId: seeded.admitted.childSessionId!,
      attemptId: seeded.admitted.attemptId!,
      workerId: seeded.admitted.logicalWorkerId!,
    };
    const before = await childLifecycleSnapshot(ids);
    expect(before.session).toHaveLength(1);
    expect(before.session[0]).toMatchObject({
      title: "subagent: child work that public clients must not mutate",
      mode: "auto",
      pinned_at: null,
      deleted_at: null,
    });
    // Raw postgres.js reads return timestamptz as text (drizzle installs
    // transparent parsers), so assert a parseable timestamp, not a Date.
    expect(Number.isNaN(new Date(String(before.session[0]!.updated_at)).getTime())).toBe(false);
    expect(before.sessionAgentState).toEqual([
      { state: { subagentParentSessionId: seeded.parentSessionId } },
    ]);
    expect(before.runs[0]).toMatchObject({ status: "running", cancel_requested: false });
    expect(before.messages).toHaveLength(1);
    expect(before.attempt[0]).toMatchObject({ status: "running", ended_at: null });
    expect(before.worker[0]).toMatchObject({ status: "running" });

    const response = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/sessions/${ids.sessionId}`,
      headers: authHeaders(seeded.uid),
      payload: {
        title: "public child PATCH must not apply",
        mode: "safe",
        pinned: true,
      },
    });
    expect(response.statusCode).toBe(403);
    expect(response.json()).toMatchObject({ error: { code: "worker_control_main_only" } });
    expect(adds).toEqual([]);
    expect(removes).toEqual([]);
    expect(appended).toEqual([]);
    expect(await childLifecycleSnapshot(ids)).toEqual(before);
  });

  it("refuses direct DELETE of a live child session with zero lifecycle mutation", async () => {
    const { app, adds, removes, appended } = makeApp();
    const seeded = await seedWorker();
    const ids = {
      sessionId: seeded.admitted.childSessionId!,
      attemptId: seeded.admitted.attemptId!,
      workerId: seeded.admitted.logicalWorkerId!,
    };
    const before = await childLifecycleSnapshot(ids);
    expect(before.session[0]).toMatchObject({ deleted_at: null });
    expect(before.runs[0]).toMatchObject({ status: "running", cancel_requested: false });
    expect(before.attempt[0]).toMatchObject({ status: "running", ended_at: null });
    expect(before.worker[0]).toMatchObject({ status: "running" });

    const response = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/sessions/${ids.sessionId}`,
      headers: authHeaders(seeded.uid),
    });
    expect(response.statusCode).toBe(403);
    expect(response.json()).toMatchObject({ error: { code: "worker_control_main_only" } });
    expect(adds).toEqual([]);
    expect(removes).toEqual([]);
    expect(appended).toEqual([]);
    expect(await childLifecycleSnapshot(ids)).toEqual(before);
  });

  it("keeps ordinary root-run Stop distinct and functional", async () => {
    const { app, removes, appended } = makeApp();
    const seeded = await seedWorker();
    const response = await app.inject({
      method: "POST",
      url: `/cloud/v1/runs/${seeded.rootRunId}/cancel`,
      headers: authHeaders(seeded.uid),
    });
    expect(response.statusCode).toBe(202);
    expect(response.json()).toMatchObject({ runId: seeded.rootRunId, status: "cancelling" });
    expect(removes).toEqual([seeded.rootRunId]);
    expect(appended).toEqual([]);
    const root = await runs.get(db, seeded.rootRunId, seeded.uid);
    expect(root).toMatchObject({ status: "running", cancelRequested: true });
    const child = await runs.get(db, seeded.admitted.childRunId!, seeded.uid);
    expect(child).toMatchObject({ status: "running", cancelRequested: false });
  });

  it("keeps normal parent-session messages admitted", async () => {
    const { app, adds, activityBumps } = makeApp();
    const seeded = await seedWorker();
    const response = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${seeded.parentSessionId}/messages`,
      headers: authHeaders(seeded.uid),
      payload: { content: "ordinary next user task" },
    });
    expect(response.statusCode).toBe(202);
    expect(adds).toHaveLength(1);
    expect(adds[0]!.data).toMatchObject({
      sessionId: seeded.parentSessionId,
      userId: seeded.uid,
      prompt: "ordinary next user task",
    });
    expect(activityBumps).toEqual([seeded.parentSessionId]);
  });

  it("keeps ordinary parent-session DELETE and root cancellation functional", async () => {
    const { app, adds, removes, appended } = makeApp();
    const seeded = await seedWorker();
    const response = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/sessions/${seeded.parentSessionId}`,
      headers: authHeaders(seeded.uid),
    });
    expect(response.statusCode).toBe(204);
    expect(response.body).toBe("");
    expect(adds).toEqual([]);
    expect(removes).toEqual([seeded.rootRunId]);
    expect(appended).toEqual([]);

    const parent = await db.$client`
      SELECT deleted_at FROM sessions WHERE id = ${seeded.parentSessionId}`;
    expect(parent[0]!.deleted_at).not.toBeNull();
    const root = await db.$client`
      SELECT status, cancel_requested FROM runs WHERE id = ${seeded.rootRunId}`;
    expect(root[0]).toMatchObject({ status: "running", cancel_requested: true });
    const child = await runs.get(db, seeded.admitted.childRunId!, seeded.uid);
    expect(child).toMatchObject({ status: "running", cancelRequested: false });
    const childSession = await db.$client`
      SELECT deleted_at FROM sessions WHERE id = ${seeded.admitted.childSessionId!}`;
    expect(childSession[0]).toMatchObject({ deleted_at: null });
  });
});
