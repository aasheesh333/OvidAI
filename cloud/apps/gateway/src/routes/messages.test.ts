import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { attachments, messages, newId, runs, type Db } from "@ovid/db";
import { AGENT_RUN_JOB_NAME } from "@ovid/queue";
import {
  messageDtoSchema,
  pageSchema,
  type Page,
  type MessageDto,
  type SendMessageResponse,
} from "@ovid/shared";
import { buildGateway } from "../app.js";
import { MintHttpError } from "../keys.js";
import type { AttachmentPresigner } from "./attachments.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubTickets,
  stubVerifier,
  type MintStub,
  type QueueAdd,
} from "../test/stubs.js";

const UUIDV7_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

const messagePage = pageSchema(messageDtoSchema);

interface TestApp {
  app: FastifyInstance;
  adds: QueueAdd[];
  mint: MintStub;
}

describe.skipIf(!TEST_DATABASE_URL)("gateway message routes (real postgres)", () => {
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

  /** Fresh gateway per test so stub behavior (failing add/mint) never leaks. */
  function makeApp(
    behavior: { failAdd?: boolean; mintThrows?: unknown; presigner?: AttachmentPresigner } = {},
  ): TestApp {
    const { queues, adds } = stubQueues({ failAdd: behavior.failAdd });
    const mint = stubMint(behavior.mintThrows === undefined ? {} : { throws: behavior.mintThrows });
    const app = buildGateway({
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint,
      events: noopEvents,
      ...(behavior.presigner !== undefined ? { presigner: behavior.presigner } : {}),
    });
    const handle = { app, adds, mint };
    built.push(handle);
    return handle;
  }

  async function createSession(handle: TestApp, uid: string): Promise<string> {
    const res = await handle.app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
      payload: {},
    });
    expect(res.statusCode).toBe(201);
    return res.json().id as string;
  }

  function sendMessage(
    handle: TestApp,
    uid: string,
    sessionId: string,
    content: unknown,
    headers: Record<string, string> | null = null,
  ) {
    return handle.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sessionId}/messages`,
      headers: headers ?? authHeaders(uid),
      payload: content as object,
    });
  }

  async function tableCounts(sessionId: string): Promise<{ messages: number; runs: number }> {
    const m = await db.$client.unsafe(
      "SELECT count(*)::int AS n FROM messages WHERE session_id = $1",
      [sessionId],
    );
    const r = await db.$client.unsafe("SELECT count(*)::int AS n FROM runs WHERE session_id = $1", [
      sessionId,
    ]);
    return { messages: m[0]!.n as number, runs: r[0]!.n as number };
  }

  it("send → 202 queued with runId, exactly one queue add (jobId=runId, free-tier priority 2), persisted user message, touched session", async () => {
    const handle = makeApp();
    const uid = testUid("msg-ok");
    const sid = await createSession(handle, uid);
    // Pin updatedAt in the past so sessions.touch is provable (unsafe params
    // must be primitives — postgres.js does not serialize Date there).
    await db.$client.unsafe("UPDATE sessions SET updated_at = $2 WHERE id = $1", [
      sid,
      new Date(1_700_000_000_000).toISOString(),
    ]);

    const content = "olá 🌍 — write me a poem";
    const res = await sendMessage(handle, uid, sid, { content });
    expect(res.statusCode).toBe(202);
    const body = res.json() as SendMessageResponse;
    expect(body).toEqual({
      runId: expect.stringMatching(UUIDV7_RE),
      userMessageId: expect.stringMatching(UUIDV7_RE),
      status: "queued",
    });

    // Exactly one add, exact name/data/opts.
    expect(handle.adds).toHaveLength(1);
    const add = handle.adds[0]!;
    expect(add.name).toBe(AGENT_RUN_JOB_NAME);
    // P2 Task 12: the payload now carries the caller's tier (the worker's
    // sandbox attach is tier-aware).
    expect(add.data).toEqual({
      runId: body.runId,
      sessionId: sid,
      userId: uid,
      prompt: content,
      tier: "free",
    });
    expect(add.opts.jobId).toBe(body.runId);
    expect(add.opts.priority).toBe(2); // users.tier default "free" → priority 2

    // Mint received the caller's raw tokens (Authorization stripped of Bearer,
    // X-Firebase-AppCheck verbatim).
    expect(handle.mint.calls).toEqual([
      { idToken: `test:${uid}`, appCheck: "app-check-stub" },
    ]);

    // User message row persisted verbatim; run row queued.
    const page = await messages.page(db, sid, { limit: 10 });
    expect(page.rows).toHaveLength(1);
    expect(page.rows[0]).toMatchObject({
      id: body.userMessageId,
      sessionId: sid,
      role: "user",
      content,
    });
    const active = await runs.activeForSession(db, sid);
    expect(active).toMatchObject({ id: body.runId, status: "queued", promptMessageId: body.userMessageId });

    // sessions.touch ran: updatedAt moved off the pinned past value.
    const rows = await db.$client.unsafe(
      "SELECT (extract(epoch FROM updated_at) * 1000)::bigint AS ms FROM sessions WHERE id = $1",
      [sid],
    );
    expect(Number(rows[0]!.ms)).toBeGreaterThan(1_700_000_000_000);
  });

  it("non-free tier → queue priority 1 (tier seeded via direct db update)", async () => {
    const handle = makeApp();
    const uid = testUid("msg-pro");
    const sid = await createSession(handle, uid); // ensures the users row
    await db.$client.unsafe("UPDATE users SET tier = 'pro' WHERE uid = $1", [uid]);

    const res = await sendMessage(handle, uid, sid, { content: "pro prompt" });
    expect(res.statusCode).toBe(202);
    expect(handle.adds).toHaveLength(1);
    expect(handle.adds[0]!.opts.priority).toBe(1);
    expect(handle.adds[0]!.data).toMatchObject({ prompt: "pro prompt", tier: "pro" });
  });

  it("missing App Check header → mint gets appCheck null", async () => {
    const handle = makeApp();
    const uid = testUid("msg-noac");
    const sid = await createSession(handle, uid);
    const res = await sendMessage(handle, uid, sid, { content: "hi" }, {
      authorization: `Bearer test:${uid}`,
    });
    expect(res.statusCode).toBe(202);
    expect(handle.mint.calls).toEqual([{ idToken: `test:${uid}`, appCheck: null }]);
  });

  it("ensureKey failure BEFORE any write: 402/429 relayed verbatim, everything else → 409 key_not_minted; zero adds, zero rows", async () => {
    const handle = makeApp(); // mint behavior re-stubbed per case below
    const uid = testUid("msg-mintfail");
    const sid = await createSession(handle, uid);

    const paymentBody = { error: { code: "payment_required", message: "buy credits" } };
    const rateBody = { error: { code: "rate_limited", message: "slow down" } };
    const cases: Array<{ thrown: unknown; status: number; body?: unknown }> = [
      { thrown: new MintHttpError(402, paymentBody), status: 402, body: paymentBody },
      { thrown: new MintHttpError(429, rateBody), status: 429, body: rateBody },
      // Non-relayable mint statuses and plain failures → generic 409.
      { thrown: new MintHttpError(500, { error: { code: "internal" } }), status: 409 },
      { thrown: new Error("mint connection refused"), status: 409 },
    ];

    for (const c of cases) {
      const failing = makeApp({ mintThrows: c.thrown });
      const res = await sendMessage(failing, uid, sid, { content: "will not land" });
      expect(res.statusCode, String(c.status)).toBe(c.status);
      if (c.status === 402 || c.status === 429) {
        expect(res.json()).toEqual(c.body); // mint envelope preserved exactly
      } else {
        expect(res.json().error.code).toBe("key_not_minted");
        expect(typeof res.json().error.message).toBe("string");
      }
      expect(failing.adds).toHaveLength(0); // never enqueued
    }

    // Ordering pin: ensureKey runs BEFORE messages.append/runs.create — after
    // all four failures the session has NO message rows and NO run rows.
    expect(await tableCounts(sid)).toEqual({ messages: 0, runs: 0 });
  });

  it("queue add rejection → 503 unavailable; user message row stays, run row left 'queued' (documented ruling)", async () => {
    const handle = makeApp({ failAdd: true });
    const uid = testUid("msg-qfail");
    const sid = await createSession(handle, uid);

    const res = await sendMessage(handle, uid, sid, { content: "stuck prompt" });
    expect(res.statusCode).toBe(503);
    expect(res.json().error.code).toBe("unavailable");
    expect(handle.adds).toHaveLength(0); // the failed add was not captured

    // Message row stays; run row survives as 'queued' for reconciliation.
    const page = await messages.page(db, sid, { limit: 10 });
    expect(page.rows).toHaveLength(1);
    expect(page.rows[0]).toMatchObject({ role: "user", content: "stuck prompt" });
    const active = await runs.activeForSession(db, sid);
    expect(active).toMatchObject({ status: "queued", promptMessageId: page.rows[0]!.id });
  });

  it("second send while the first run is still active → 202 with a NEW runId queued behind (FIFO)", async () => {
    const handle = makeApp(); // stub queue never drains → first run stays queued
    const uid = testUid("msg-second");
    const sid = await createSession(handle, uid);

    const first = await sendMessage(handle, uid, sid, { content: "one" });
    expect(first.statusCode).toBe(202);
    const second = await sendMessage(handle, uid, sid, { content: "two" });
    expect(second.statusCode).toBe(202);

    const runId1 = (first.json() as SendMessageResponse).runId;
    const runId2 = (second.json() as SendMessageResponse).runId;
    expect(runId2).not.toBe(runId1);
    expect(handle.adds).toHaveLength(2);
    expect(handle.adds.map((a) => a.opts.jobId)).toEqual([runId1, runId2]);
    expect(handle.adds.map((a) => a.data.prompt)).toEqual(["one", "two"]);

    // Oldest active run wins claim order (worker processes FIFO by createdAt).
    const active = await runs.activeForSession(db, sid);
    expect(active!.id).toBe(runId1);
    expect(await tableCounts(sid)).toEqual({ messages: 2, runs: 2 });
  });

  it("empty/missing/whitespace content or unknown keys → 400 bad_request, nothing written", async () => {
    const handle = makeApp();
    const uid = testUid("msg-bad");
    const sid = await createSession(handle, uid);

    for (const payload of [
      { content: "" },
      {},
      { content: "   " },
      { content: 42 },
      { content: "ok", extra: 1 },
    ]) {
      const res = await sendMessage(handle, uid, sid, payload);
      expect(res.statusCode, JSON.stringify(payload)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
    expect(handle.adds).toHaveLength(0);
    expect(await tableCounts(sid)).toEqual({ messages: 0, runs: 0 });
  });

  it("POST messages: wrong owner or unknown session → 404 (checked BEFORE body validation), nothing enqueued", async () => {
    const handle = makeApp();
    const owner = testUid("msg-owner");
    const stranger = testUid("msg-stranger");
    const sid = await createSession(handle, owner);

    // Even a VALID body gets 404 for a stranger; an INVALID body too — the
    // ownership check runs first, so validation never leaks session existence.
    for (const content of [{ content: "sneaky" }, { content: "" }]) {
      const res = await sendMessage(handle, stranger, sid, content);
      expect(res.statusCode, JSON.stringify(content)).toBe(404);
      expect(res.json().error.code).toBe("not_found");
    }
    const unknown = await sendMessage(handle, owner, newId(), { content: "ghost" });
    expect(unknown.statusCode).toBe(404);
    expect(unknown.json().error.code).toBe("not_found");

    expect(handle.adds).toHaveLength(0);
    expect(await tableCounts(sid)).toEqual({ messages: 0, runs: 0 });
  });

  it("GET messages: newest-first, before-keyset paging, ownership 404, limit clamp", async () => {
    const handle = makeApp();
    const uid = testUid("msg-page");
    const stranger = testUid("msg-page-stranger");
    const sid = await createSession(handle, uid);

    const seeded = [];
    for (let i = 0; i < 5; i++) {
      seeded.push(
        await messages.append(db, {
          sessionId: sid,
          role: i % 2 === 0 ? "user" : "assistant",
          content: `m${i}`,
        }),
      );
    }
    const newestFirst = [...seeded].reverse().map((m) => m.id);

    // Default page: all five, newest first, DTO-shaped.
    const all = await handle.app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/messages`,
      headers: authHeaders(uid),
    });
    expect(all.statusCode).toBe(200);
    const allBody = messagePage.parse(all.json()) as Page<MessageDto>;
    expect(allBody.items.map((m) => m.id)).toEqual(newestFirst);
    expect(allBody.nextCursor).toBeNull();
    expect(allBody.items[0]).toMatchObject({ sessionId: sid, role: "user", content: "m4" });
    expect(Date.parse(allBody.items[0]!.createdAt)).not.toBeNaN();

    // Walk pages of 2 with before=nextCursor.
    const p1 = await handle.app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/messages?limit=2`,
      headers: authHeaders(uid),
    });
    const page1 = messagePage.parse(p1.json()) as Page<MessageDto>;
    expect(page1.items.map((m) => m.id)).toEqual([newestFirst[0], newestFirst[1]]);
    expect(page1.nextCursor).toBe(newestFirst[1]);

    const p2 = await handle.app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/messages?limit=2&before=${page1.nextCursor}`,
      headers: authHeaders(uid),
    });
    const page2 = messagePage.parse(p2.json()) as Page<MessageDto>;
    expect(page2.items.map((m) => m.id)).toEqual([newestFirst[2], newestFirst[3]]);

    const p3 = await handle.app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/messages?limit=2&before=${page2.nextCursor}`,
      headers: authHeaders(uid),
    });
    const page3 = messagePage.parse(p3.json()) as Page<MessageDto>;
    expect(page3.items.map((m) => m.id)).toEqual([newestFirst[4]]);
    expect(page3.nextCursor).toBeNull();

    // Ownership 404 for GET as well (wrong owner AND unknown session).
    const theirs = await handle.app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/messages`,
      headers: authHeaders(stranger),
    });
    expect(theirs.statusCode).toBe(404);
    expect(theirs.json().error.code).toBe("not_found");
    const ghost = await handle.app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${newId()}/messages`,
      headers: authHeaders(uid),
    });
    expect(ghost.statusCode).toBe(404);

    // Clamp rules shared with the sessions list route.
    const clamped = await handle.app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/messages?limit=1000`,
      headers: authHeaders(uid),
    });
    expect(clamped.statusCode).toBe(200);
    expect(messagePage.parse(clamped.json()).items).toHaveLength(5);
    const garbage = await handle.app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/messages?limit=abc`,
      headers: authHeaders(uid),
    });
    expect(garbage.statusCode).toBe(200);
    expect(messagePage.parse(garbage.json()).items).toHaveLength(5);
  });

  it("malformed session :id on POST and GET messages → 404 not_found (never 500 via Postgres 22P02), nothing enqueued", async () => {
    const handle = makeApp();
    const uid = testUid("msg-badid");
    // Same three client-typo shapes as sessions.test.ts: a non-UUID word, a
    // long random string, a numeric string.
    const malformed = [
      "not-a-uuid",
      "9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a",
      "1234567",
    ];
    for (const bad of malformed) {
      const post = await sendMessage(handle, uid, bad, { content: "valid body" });
      expect(post.statusCode, `POST ${bad}`).toBe(404);
      expect(post.statusCode, `POST ${bad} must never be a 500`).not.toBe(500);
      expect(post.json().error.code).toBe("not_found");
      expect(post.json().error.message).toBe("Session not found.");

      const get = await handle.app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${bad}/messages`,
        headers: authHeaders(uid),
      });
      expect(get.statusCode, `GET ${bad}`).toBe(404);
      expect(get.statusCode, `GET ${bad} must never be a 500`).not.toBe(500);
      expect(get.json().error.code).toBe("not_found");
      expect(get.json().error.message).toBe("Session not found.");
    }
    // Rejected at the shape guard — no dependency was touched on the way.
    expect(handle.adds).toHaveLength(0);
    expect(handle.mint.calls).toHaveLength(0);
  });

  it("GET messages with a malformed before degrades to the first page (documented choice: ignore it, lenient like the sessions cursor)", async () => {
    const handle = makeApp();
    const uid = testUid("msg-badbefore");
    const sid = await createSession(handle, uid);
    const seeded = [];
    for (let i = 0; i < 3; i++) {
      seeded.push(
        await messages.append(db, { sessionId: sid, role: "user", content: `m${i}` }),
      );
    }
    const newestFirst = [...seeded].reverse().map((m) => m.id);

    // Ruling pinned here: a malformed `before` is IGNORED (first page served),
    // consistent with the sessions-list garbage-cursor contract — never a 500,
    // never a 400. "0" is the discriminating case: an unguarded bpchar keyset
    // comparison would filter EVERY UUIDv7 id out (all start "01…" > "0") and
    // serve an empty page; only the gateway-side guard guarantees the full
    // first page for every malformed value.
    for (const bad of ["garbage", "1234567", "not-a-uuid", "0"]) {
      const res = await handle.app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/messages?before=${encodeURIComponent(bad)}`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode, bad).toBe(200);
      expect(messagePage.parse(res.json()).items.map((m) => m.id)).toEqual(newestFirst);
    }
  });

  it("message routes answer 401 unauthenticated with the Task 6 envelope", async () => {
    const handle = makeApp();
    const uid = testUid("msg-401");
    const sid = await createSession(handle, uid);
    for (const req of [
      { method: "POST" as const, url: `/cloud/v1/sessions/${sid}/messages`, payload: { content: "x" } },
      { method: "GET" as const, url: `/cloud/v1/sessions/${sid}/messages` },
    ]) {
      const res = await handle.app.inject({ ...req, headers: {} });
      expect(res.statusCode, req.url).toBe(401);
      expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
    }
  });

  // -------------------------------------------------------------------------
  // P8 Task 3: message attachmentIds — validated against the attachments of
  // the SAME session, then carried on the enqueued job payload (additive: the
  // key is present only when the request sent one).
  // -------------------------------------------------------------------------

  /** Fake presigner (the P8-Q3 seam) so the attachments route can create rows. */
  const fakePresigner: AttachmentPresigner = {
    async presignPut(key) {
      return `https://r2.test/bucket/${encodeURIComponent(key)}`;
    },
  };

  it("send with attachmentIds → 202 and the enqueued job payload carries the ids", async () => {
    const handle = makeApp({ presigner: fakePresigner });
    const uid = testUid("msg-atts");
    const sid = await createSession(handle, uid);

    // Create two attachments through the route (exactly the client flow).
    const ids: string[] = [];
    for (const name of ["a.txt", "b.png"]) {
      const res = await handle.app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sid}/attachments`,
        headers: authHeaders(uid),
        payload: { name, size: 4 },
      });
      expect(res.statusCode).toBe(201);
      ids.push((res.json() as { attachmentId: string }).attachmentId);
    }

    const res = await sendMessage(handle, uid, sid, {
      content: "here are the files",
      attachmentIds: ids,
    });
    expect(res.statusCode).toBe(202);
    expect(handle.adds).toHaveLength(1);
    // Exact payload pin: the pre-existing fields PLUS attachmentIds.
    expect(handle.adds[0]!.data).toEqual({
      runId: expect.any(String) as string,
      sessionId: sid,
      userId: uid,
      prompt: "here are the files",
      tier: "free",
      attachmentIds: ids,
    });
  });

  it("unknown attachment id, or an id belonging to ANOTHER session → 400 bad_request, nothing written or enqueued", async () => {
    const handle = makeApp({ presigner: fakePresigner });
    const uid = testUid("msg-attbad");
    const other = testUid("msg-attbad-other");
    const sid = await createSession(handle, uid);
    const otherSid = await createSession(handle, other);

    // A real attachment — but for a DIFFERENT session (cross-session id reuse
    // must not pass: getForSession is session-scoped).
    const foreign = await handle.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${otherSid}/attachments`,
      headers: authHeaders(other),
      payload: { name: "foreign.txt", size: 4 },
    });
    const foreignId = (foreign.json() as { attachmentId: string }).attachmentId;

    for (const attachmentIds of [[newId()], [foreignId]]) {
      const res = await sendMessage(handle, uid, sid, { content: "x", attachmentIds });
      expect(res.statusCode, JSON.stringify(attachmentIds)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
    expect(handle.adds).toHaveLength(0);
    expect(await tableCounts(sid)).toEqual({ messages: 0, runs: 0 });

    // Malformed ids never reach the db: z.array(z.string().uuid()) rejects them.
    const malformed = await sendMessage(handle, uid, sid, {
      content: "x",
      attachmentIds: ["not-a-uuid"],
    });
    expect(malformed.statusCode).toBe(400);
    expect(malformed.json().error.code).toBe("bad_request");
    expect(handle.adds).toHaveLength(0);
  });

  it("absent or empty attachmentIds → 202 and the job payload carries NO attachmentIds key (wire stays additive)", async () => {
    const handle = makeApp({ presigner: fakePresigner });
    const uid = testUid("msg-attnone");
    const sid = await createSession(handle, uid);

    for (const payload of [{ content: "no key at all" }, { content: "empty list", attachmentIds: [] }]) {
      const res = await sendMessage(handle, uid, sid, payload);
      expect(res.statusCode, JSON.stringify(payload)).toBe(202);
      const add = handle.adds.at(-1)!;
      expect(add.data).toEqual({
        runId: expect.any(String) as string,
        sessionId: sid,
        userId: uid,
        prompt: payload.content,
        tier: "free",
      });
      expect("attachmentIds" in add.data).toBe(false);
    }
  });
});
