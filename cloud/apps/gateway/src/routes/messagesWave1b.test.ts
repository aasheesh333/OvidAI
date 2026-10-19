// Wave 1b — rich history page, truncate (delete / edit-and-resend),
// regenerate and branch routes (CH-002, CH-003, CH-006, CT-003, CT-004,
// CH-024). Real Postgres, stub queue/mint (the messages.test.ts harness).

import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { attachments, eventMirror, messages, newId, runs, sessionState, type Db } from "@ovid/db";
import type { MessagePage, SessionEvent } from "@ovid/shared";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
  type QueueAdd,
} from "../test/stubs.js";

interface TestApp {
  app: FastifyInstance;
  adds: QueueAdd[];
  mintCalls: string[];
}

describe.skipIf(!TEST_DATABASE_URL)("Wave 1b message routes (real postgres)", () => {
  let db: Db;
  const built: TestApp[] = [];

  beforeAll(async () => {
    db = await openTestDb();
  }, 60_000);

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.app.close();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  function makeApp(): TestApp {
    const { queues, adds } = stubQueues();
    const mint = stubMint();
    const mintCalls: string[] = [];
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: { async ensureKeyForUid(uid) { mintCalls.push(uid); return mint.ensureKeyForUid(uid); } },
      events: noopEvents,
    });
    const handle = { app, adds, mintCalls };
    built.push(handle);
    return handle;
  }

  async function createSession(h: TestApp, uid: string): Promise<string> {
    const res = await h.app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
      payload: { title: "Trip plan" },
    });
    expect(res.statusCode).toBe(201);
    return res.json().id as string;
  }

  function get(h: TestApp, uid: string, url: string) {
    return h.app.inject({ method: "GET", url, headers: authHeaders(uid) });
  }

  let seqCounter = 1_800_000_000_000;
  async function putEvent(
    sessionId: string,
    type: string,
    payload: Record<string, unknown>,
    ts: Date,
  ): Promise<string> {
    seqCounter += 1;
    const seq = `${seqCounter}-0`;
    const e: SessionEvent = { sessionId, seq, type: type as SessionEvent["type"], payload, ts: ts.toISOString() };
    await eventMirror.put(db, e);
    return seq;
  }

  const later = (d: Date, ms: number) => new Date(d.getTime() + ms);

  async function finishRuns(sessionId: string): Promise<void> {
    await db.$client.unsafe(
      "UPDATE runs SET status = 'completed' WHERE session_id = $1 AND status IN ('queued','running')",
      [sessionId],
    );
  }

  // ── GET rich page ──────────────────────────────────────────────────────

  it("GET answers lastEventSeq + activeRun, and attachments under the user row that sent them", async () => {
    const h = makeApp();
    const uid = testUid("w1b-get");
    const sid = await createSession(h, uid);
    const attId = newId();
    await attachments.create(db, { id: attId, sessionId: sid, userId: uid, name: "map.png", size: 1234, r2Key: "k" });
    const send = await h.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/messages`,
      headers: authHeaders(uid),
      payload: { content: "look at this", attachmentIds: [attId] },
    });
    expect(send.statusCode).toBe(202);
    const { runId, userMessageId } = send.json() as { runId: string; userMessageId: string };

    const empty = await get(h, uid, `/cloud/v1/sessions/${sid}/messages`);
    const page0 = empty.json() as MessagePage;
    expect(page0.lastEventSeq).toBeNull();
    expect(page0.activeRun).toEqual({ runId, status: "queued" });
    expect(page0.events).toBeUndefined();
    expect(page0.items[0]).toMatchObject({
      id: userMessageId,
      attachments: [{ id: attId, name: "map.png", sizeBytes: 1234 }],
    });

    const seq = await putEvent(sid, "run_started", { runId }, new Date());
    await finishRuns(sid);
    const after = (await get(h, uid, `/cloud/v1/sessions/${sid}/messages`)).json() as MessagePage;
    expect(after.lastEventSeq).toBe(seq);
    expect(after.activeRun).toBeNull();
  });

  it("GET ?events=1 returns the page window's settled events (no deltas) and coalesces the live run's text", async () => {
    const h = makeApp();
    const uid = testUid("w1b-ev");
    const sid = await createSession(h, uid);
    const u1 = await messages.append(db, { sessionId: sid, role: "user", content: "q1" });
    const r1 = await runs.create(db, { sessionId: sid, promptMessageId: u1.id });
    await putEvent(sid, "run_started", { runId: r1.id }, later(u1.createdAt, 1));
    await putEvent(sid, "message_delta", { runId: r1.id, text: "Let me" }, later(u1.createdAt, 2));
    await putEvent(sid, "message_segment", { runId: r1.id, content: "Let me look." }, later(u1.createdAt, 3));
    await putEvent(sid, "tool_started", { runId: r1.id, callId: "c1", name: "web_search" }, later(u1.createdAt, 4));
    await putEvent(sid, "tool_completed", { runId: r1.id, callId: "c1", name: "web_search", content: "ok" }, later(u1.createdAt, 5));
    const a1 = await messages.append(db, { sessionId: sid, role: "assistant", content: "Found it." });
    await putEvent(sid, "message_completed", { messageId: a1.id, content: "Found it." }, later(a1.createdAt, 1));
    await putEvent(sid, "run_completed", { runId: r1.id }, later(a1.createdAt, 2));
    await runs.finish(db, r1.id, "completed");

    // A second, still-running run with streamed text after a tool round.
    const u2 = await messages.append(db, { sessionId: sid, role: "user", content: "q2" });
    const r2 = await runs.create(db, { sessionId: sid, promptMessageId: u2.id });
    await runs.claimNext(db, r2.id);
    await putEvent(sid, "run_started", { runId: r2.id }, later(u2.createdAt, 1));
    await putEvent(sid, "message_delta", { runId: r2.id, text: "old " }, later(u2.createdAt, 2));
    await putEvent(sid, "tool_started", { runId: r2.id, callId: "c2", name: "fetch_url" }, later(u2.createdAt, 3));
    await putEvent(sid, "tool_completed", { runId: r2.id, callId: "c2", name: "fetch_url", content: "x" }, later(u2.createdAt, 4));
    await putEvent(sid, "message_delta", { runId: r2.id, text: "Hello " }, later(u2.createdAt, 5));
    const lastSeq = await putEvent(sid, "message_delta", { runId: r2.id, text: "world" }, later(u2.createdAt, 6));

    const res = await get(h, uid, `/cloud/v1/sessions/${sid}/messages?events=1`);
    expect(res.statusCode).toBe(200);
    const page = res.json() as MessagePage;
    expect(page.lastEventSeq).toBe(lastSeq);
    expect(page.activeRun).toEqual({ runId: r2.id, status: "running" });
    const evs = page.events!;
    expect(evs.map((e) => e.type)).toEqual([
      "run_started",
      "message_segment",
      "tool_started",
      "tool_completed",
      "message_completed",
      "run_completed",
      "run_started",
      "tool_started",
      "tool_completed",
      "message_delta",
    ]);
    const live = evs[evs.length - 1]!;
    expect(live.payload).toEqual({ runId: r2.id, text: "Hello world" });
    expect(live.seq).toBe(lastSeq);
  });

  it("GET ?events=1 on an older page scopes events to that page's time window", async () => {
    const h = makeApp();
    const uid = testUid("w1b-old");
    const sid = await createSession(h, uid);
    const u1 = await messages.append(db, { sessionId: sid, role: "user", content: "q1" });
    await putEvent(sid, "tool_started", { callId: "old" }, later(u1.createdAt, 1));
    await new Promise((r) => setTimeout(r, 10));
    const u2 = await messages.append(db, { sessionId: sid, role: "user", content: "q2" });
    await putEvent(sid, "tool_started", { callId: "new" }, later(u2.createdAt, 1));

    const newest = (await get(h, uid, `/cloud/v1/sessions/${sid}/messages?events=1&limit=1`)).json() as MessagePage;
    expect(newest.items.map((m) => m.id)).toEqual([u2.id]);
    expect(newest.events!.map((e) => e.payload.callId)).toEqual(["new"]);
    const older = (
      await get(h, uid, `/cloud/v1/sessions/${sid}/messages?events=1&limit=1&before=${newest.nextCursor}`)
    ).json() as MessagePage;
    expect(older.items.map((m) => m.id)).toEqual([u1.id]);
    expect(older.events!.map((e) => e.payload.callId)).toEqual(["old"]);
  });

  const gatedActions = [
    { method: "DELETE" as const, path: (sid: string, mid: string) => `/cloud/v1/sessions/${sid}/messages/${mid}` },
    { method: "POST" as const, path: (sid: string, mid: string) => `/cloud/v1/sessions/${sid}/messages/${mid}/regenerate` },
    { method: "POST" as const, path: (sid: string, _mid: string) => `/cloud/v1/sessions/${sid}/branch` },
  ];

  it.each(gatedActions)("R4 gate $method $path leaves all durable history and routing dependencies untouched", async ({ method, path }) => {
    const h = makeApp();
    const uid = testUid("w1b-gated");
    const sid = await createSession(h, uid);
    const prompt = await messages.append(db, { sessionId: sid, role: "user", content: "original prompt" });
    const answer = await messages.append(db, { sessionId: sid, role: "assistant", content: "original answer" });
    const attachmentId = newId();
    await attachments.create(db, { id: attachmentId, sessionId: sid, userId: uid, name: "keep.txt", size: 5, r2Key: "keep" });
    await attachments.linkToMessage(db, sid, [attachmentId], prompt.id);
    await putEvent(sid, "tool_started", { callId: "keep-tool" }, later(prompt.createdAt, 1));
    await sessionState.patch(db, sid, { compaction: { ledger: null, summary: "keep summary", cutoffMessageId: answer.id, compactedAtCount: 1 } });
    const snapshot = async () => JSON.stringify(await Promise.all([
      db.$client.unsafe("SELECT * FROM sessions WHERE user_id = $1 ORDER BY id", [uid]),
      ...["messages", "attachments", "session_event_mirror", "session_agent_state", "runs"].map((table) =>
        db.$client.unsafe(`SELECT * FROM ${table} WHERE session_id = $1`, [sid])),
    ]));
    const before = await snapshot();
    const res = await h.app.inject({ method, url: path(sid, answer.id), headers: authHeaders(uid),
      ...(method === "POST" ? { payload: { ...(path(sid, answer.id).endsWith("/branch") ? { messageId: answer.id } : {}) } } : {}) });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("history_actions_unavailable");
    expect(await snapshot()).toBe(before);
    expect(h.mintCalls).toEqual([]);
    expect(h.adds).toEqual([]);
  });

  // ── DELETE (truncate from a message) ───────────────────────────────────

  it("DELETE is ownership-scoped and release-gated while queued or idle", async () => {
    const h = makeApp();
    const uid = testUid("w1b-del");
    const sid = await createSession(h, uid);
    const u1 = await messages.append(db, { sessionId: sid, role: "user", content: "q1" });
    const a1 = await messages.append(db, { sessionId: sid, role: "assistant", content: "a1" });
    const u2 = await messages.append(db, { sessionId: sid, role: "user", content: "q2" });
    const a2 = await messages.append(db, { sessionId: sid, role: "assistant", content: "a2" });

    const stranger = testUid("w1b-stranger");
    const foreign = await h.app.inject({
      method: "DELETE",
      url: `/cloud/v1/sessions/${sid}/messages/${u2.id}`,
      headers: authHeaders(stranger),
    });
    expect(foreign.statusCode).toBe(404);

    const busyRun = await runs.create(db, { sessionId: sid, promptMessageId: u2.id });
    const busy = await h.app.inject({
      method: "DELETE",
      url: `/cloud/v1/sessions/${sid}/messages/${u2.id}`,
      headers: authHeaders(uid),
    });
    expect(busy.statusCode).toBe(409);
    expect(busy.json().error.code).toBe("history_actions_unavailable");
    await runs.finish(db, busyRun.id, "completed");

    const unknown = await h.app.inject({
      method: "DELETE",
      url: `/cloud/v1/sessions/${sid}/messages/${newId()}`,
      headers: authHeaders(uid),
    });
    expect(unknown.statusCode).toBe(404);

    const ok = await h.app.inject({
      method: "DELETE",
      url: `/cloud/v1/sessions/${sid}/messages/${u2.id}`,
      headers: authHeaders(uid),
    });
    expect(ok.statusCode).toBe(409);
    expect(ok.json().error.code).toBe("history_actions_unavailable");
    const left = await messages.page(db, sid, { limit: 10 });
    expect(left.rows.map((r) => r.id)).toEqual([a2.id, u2.id, a1.id, u1.id]);
    expect(h.mintCalls).toEqual([]);
    expect(h.adds).toEqual([]);
  });

  it("DELETE gate preserves an answer and its tool events", async () => {
    const h = makeApp();
    const uid = testUid("w1b-del-a");
    const sid = await createSession(h, uid);
    const u1 = await messages.append(db, { sessionId: sid, role: "user", content: "q1" });
    await putEvent(sid, "tool_started", { callId: "c" }, later(u1.createdAt, 1));
    const a1 = await messages.append(db, { sessionId: sid, role: "assistant", content: "a1" });
    const res = await h.app.inject({
      method: "DELETE",
      url: `/cloud/v1/sessions/${sid}/messages/${a1.id}`,
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("history_actions_unavailable");
    expect((await eventMirror.readSince(db, sid, null, 10)).map((e) => e.payload.callId)).toEqual(["c"]);
    expect((await messages.page(db, sid, { limit: 10 })).rows.map((r) => r.id)).toEqual([a1.id, u1.id]);
  });

  // ── regenerate ─────────────────────────────────────────────────────────

  it("regenerate gate keeps the prompt, answer and linked attachments without another mint or queue call", async () => {
    const h = makeApp();
    const uid = testUid("w1b-regen");
    const sid = await createSession(h, uid);
    const attId = newId();
    await attachments.create(db, { id: attId, sessionId: sid, userId: uid, name: "a.txt", size: 3, r2Key: "k" });
    const send = await h.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/messages`,
      headers: authHeaders(uid),
      payload: { content: "summarize", attachmentIds: [attId] },
    });
    const { userMessageId } = send.json() as { userMessageId: string };
    await finishRuns(sid);
    const answer = await messages.append(db, { sessionId: sid, role: "assistant", content: "old answer" });

    const mintCount = h.mintCalls.length;
    const queuedCount = h.adds.length;
    const res = await h.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/messages/${answer.id}/regenerate`,
      headers: authHeaders(uid),
      payload: { maxOutputTokens: 500 },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("history_actions_unavailable");
    const left = await messages.page(db, sid, { limit: 10 });
    expect(left.rows.map((r) => r.id)).toEqual([answer.id, userMessageId]);
    expect((await attachments.forMessages(db, sid, [userMessageId])).map((a) => a.id)).toEqual([attId]);
    expect(h.mintCalls).toHaveLength(mintCount);
    expect(h.adds).toHaveLength(queuedCount);
    expect(await runs.activeForSession(db, sid)).toBeNull();

    // A stranger can't regenerate; a busy session refuses.
    const stranger = await h.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/messages/${answer.id}/regenerate`,
      headers: authHeaders(testUid("w1b-x")),
      payload: {},
    });
    expect(stranger.statusCode).toBe(404);
  });

  it("regenerate gate keeps a failed attempt and its events without sending a duplicate", async () => {
    const h = makeApp();
    const uid = testUid("w1b-retry");
    const sid = await createSession(h, uid);
    const u1 = await messages.append(db, { sessionId: sid, role: "user", content: "try this" });
    await putEvent(sid, "run_failed", { code: "model_terminal" }, later(u1.createdAt, 5));
    const res = await h.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/messages/${u1.id}/regenerate`,
      headers: authHeaders(uid),
      payload: {},
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("history_actions_unavailable");
    expect((await messages.page(db, sid, { limit: 10 })).rows.map((r) => r.id)).toEqual([u1.id]);
    expect((await eventMirror.readSince(db, sid, null, 10)).map((e) => e.type)).toEqual(["run_failed"]);
    expect(h.mintCalls).toEqual([]);
    expect(h.adds).toEqual([]);
  });

  it("regenerate refuses while a run is active", async () => {
    const h = makeApp();
    const uid = testUid("w1b-regen-busy");
    const sid = await createSession(h, uid);
    const u1 = await messages.append(db, { sessionId: sid, role: "user", content: "q" });
    const a1 = await messages.append(db, { sessionId: sid, role: "assistant", content: "a" });
    await runs.create(db, { sessionId: sid, promptMessageId: u1.id });
    const res = await h.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/messages/${a1.id}/regenerate`,
      headers: authHeaders(uid),
      payload: {},
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("history_actions_unavailable");
    expect((await messages.page(db, sid, { limit: 10 })).rows).toHaveLength(2);
  });

  it("delete/edit and regenerate refuse while a running task awaits approval, preserving history and approval", async () => {
    const h = makeApp();
    const uid = testUid("w1b-approval-history");
    const sid = await createSession(h, uid);
    const prompt = await messages.append(db, { sessionId: sid, role: "user", content: "change a file" });
    const answer = await messages.append(db, { sessionId: sid, role: "assistant", content: "awaiting permission" });
    const run = await runs.create(db, { sessionId: sid, promptMessageId: prompt.id });
    await db.$client.unsafe("UPDATE runs SET status = 'running' WHERE id = $1", [run.id]);
    const approvalSeq = await putEvent(sid, "approval_requested", {
      approvalId: "approval-history-guard", kind: "tool", summary: "Edit a file", detail: "fs_edit",
    }, new Date());
    for (const method of ["DELETE", "POST"] as const) {
      const res = await h.app.inject({
        method,
        url: `/cloud/v1/sessions/${sid}/messages/${answer.id}${method === "POST" ? "/regenerate" : ""}`,
        headers: authHeaders(uid),
        ...(method === "POST" ? { payload: {} } : {}),
      });
      expect(res.statusCode).toBe(409);
      expect(res.json().error.code).toBe("history_actions_unavailable");
    }
    expect((await messages.page(db, sid, { limit: 10 })).rows.map((m) => m.id)).toEqual([answer.id, prompt.id]);
    expect((await eventMirror.readSince(db, sid, null, 10)).map((e) => e.seq)).toEqual([approvalSeq]);
    expect(h.adds).toHaveLength(0);
  });

  // ── branch ─────────────────────────────────────────────────────────────

  it("branch is ownership-scoped and gated rather than claiming a capped text copy is a rich fork", async () => {
    const h = makeApp();
    const uid = testUid("w1b-branch");
    const sid = await createSession(h, uid);
    const u1 = await messages.append(db, { sessionId: sid, role: "user", content: "q1" });
    const a1 = await messages.append(db, { sessionId: sid, role: "assistant", content: "a1" });
    await messages.append(db, { sessionId: sid, role: "user", content: "q2" });

    const res = await h.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/branch`,
      headers: authHeaders(uid),
      payload: { messageId: a1.id },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("history_actions_unavailable");
    const unchanged = (await get(h, uid, `/cloud/v1/sessions/${sid}/messages`)).json() as MessagePage;
    expect(unchanged.items.map((m) => m.content).reverse()).toEqual(["q1", "a1", "q2"]);
    expect(unchanged.items[2]!.createdAt).toBe(u1.createdAt.toISOString());
    expect(h.mintCalls).toEqual([]);
    expect(h.adds).toEqual([]);

    const foreign = await h.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/branch`,
      headers: authHeaders(testUid("w1b-y")),
      payload: { messageId: a1.id },
    });
    expect(foreign.statusCode).toBe(404);
    const bad = await h.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/branch`,
      headers: authHeaders(uid),
      payload: { messageId: newId() },
    });
    expect(bad.statusCode).toBe(404);
  });
});
