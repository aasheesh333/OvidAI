import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { accountSettings, attachments, byokKeysRepo, messages, newId, runs, runUsage, type Db } from "@ovid/db";
import { AGENT_RUN_JOB_NAME } from "@ovid/queue";
import {
  messageDtoSchema,
  pageSchema,
  MintInternalError,
  type InternalMintProvisioner,
  type Page,
  type MessageDto,
  type SendMessageResponse,
} from "@ovid/shared";
import { buildGateway } from "../app.js";
import { createInternalMintProvisioner } from "../internalMint.js";
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
  stubSystemBus,
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
    behavior: {
      failAdd?: boolean;
      mintThrows?: unknown;
      presigner?: AttachmentPresigner;
      /** P10 Task 2: override the provisioner (e.g. a hung HTTP fetch seam). */
      mint?: InternalMintProvisioner;
      /** P10 Task 2: bounded mint deadline (default 10000). */
      mintTimeoutMs?: number;
      /** Fixed clock for the token-cap windows and their reset header. */
      clock?: () => Date;
    } = {},
  ): TestApp {
    const { queues, adds } = stubQueues({ failAdd: behavior.failAdd });
    const mint = stubMint(behavior.mintThrows === undefined ? {} : { throws: behavior.mintThrows });
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: behavior.mint ?? mint,
      events: noopEvents,
      ...(behavior.mintTimeoutMs !== undefined
        ? { mintTimeoutMs: behavior.mintTimeoutMs }
        : {}),
      ...(behavior.presigner !== undefined ? { presigner: behavior.presigner } : {}),
      ...(behavior.clock !== undefined ? { clock: behavior.clock } : {}),
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

  async function createProject(handle: TestApp, uid: string, name: string): Promise<string> {
    const res = await handle.app.inject({
      method: "POST",
      url: "/cloud/v1/projects",
      headers: authHeaders(uid),
      payload: { name },
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

  it("BYOK sends bypass an exhausted Ovid allowance and pin the user's key and provider model in the job", async () => {
    const handle = makeApp({ mintThrows: new MintInternalError(402, { detail: "Daily Ovid allowance reached" }, {}) });
    const uid = testUid("msg-byok");
    const sid = await createSession(handle, uid);
    const key = await byokKeysRepo.create(db, {
      userId: uid, providerId: "openai", endpoint: "https://api.openai.com/v1", label: null,
      wrappedDek: Buffer.from("d").toString("base64"), iv: Buffer.from("i").toString("base64"),
      ciphertext: Buffer.from("c").toString("base64"), tag: Buffer.from("t").toString("base64"),
    });
    await accountSettings.patch(db, uid, { byokDefault: { keyId: key.id, model: "gpt-4.1-mini" } });

    const res = await sendMessage(handle, uid, sid, { content: "Use my provider" });
    expect(res.statusCode).toBe(202);
    expect(handle.mint.calls).toEqual([]);
    expect(handle.adds[0]!.data).toMatchObject({ byokKeyId: key.id, byokModel: "gpt-4.1-mini" });
    expect(await tableCounts(sid)).toEqual({ messages: 1, runs: 1 });
  });

  it("a missing or foreign configured BYOK key fails before mint, message writes or enqueue", async () => {
    const handle = makeApp();
    const uid = testUid("msg-byok-missing");
    const sid = await createSession(handle, uid);
    await accountSettings.patch(db, uid, { byokDefault: { keyId: newId(), model: "gpt-4.1-mini" } });
    const res = await sendMessage(handle, uid, sid, { content: "Never silently bill Ovid" });
    expect(res.statusCode).toBe(409);
    expect(handle.mint.calls).toEqual([]);
    expect(handle.adds).toEqual([]);
    expect(await tableCounts(sid)).toEqual({ messages: 0, runs: 0 });
  });

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
      model: "auto",
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

    // P9 Task 9: mint receives the gateway's verified uid only — no client
    // Firebase token or App Check header crosses this boundary.
    expect(handle.mint.calls).toEqual([{ uid }]);

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

  it("missing App Check header → mint still receives the verified uid", async () => {
    const handle = makeApp();
    const uid = testUid("msg-noac");
    const sid = await createSession(handle, uid);
    const res = await sendMessage(handle, uid, sid, { content: "hi" }, {
      authorization: `Bearer test:${uid}`,
    });
    expect(res.statusCode).toBe(202);
    expect(handle.mint.calls).toEqual([{ uid }]);
  });

  it("ensureKey failure BEFORE any write: 402/429 re-enveloped {error:{code,message}} + x-ovid-resets-at forwarded, everything else → 409 key_not_minted; zero adds, zero rows", async () => {
    const handle = makeApp(); // mint behavior re-stubbed per case below
    const uid = testUid("msg-mintfail");
    const sid = await createSession(handle, uid);

    // The mint answers FastAPI-parity {"detail": …}; the thin client parses
    // only the gateway's ApiError envelope (cloud_rest.dart _toError) and
    // keys its 402 UX off `daily_limit_reached` + the epoch-ms
    // x-ovid-resets-at header (cloud_session_store.dart, chat_screen.dart).
    const resetsIso = "2026-11-01T00:00:00Z";
    const resetsMs = String(Date.parse(resetsIso));
    const cases: Array<{
      thrown: unknown;
      status: number;
      body?: { error: { code: string; message: string } };
      resetsAt?: string;
    }> = [
      {
        thrown: new MintInternalError(
          402,
          { detail: "monthly free limit reached" },
          { "x-ovid-resets-at": resetsIso },
        ),
        status: 402,
        body: { error: { code: "daily_limit_reached", message: "monthly free limit reached" } },
        resetsAt: resetsMs, // ISO from the mint → epoch ms on the wire
      },
      {
        thrown: new MintInternalError(
          429,
          { detail: "too many requests from this network — retry later" },
          { "x-ovid-resets-at": resetsMs },
        ),
        status: 429,
        body: {
          error: {
            code: "rate_limited",
            message: "too many requests from this network — retry later",
          },
        },
        resetsAt: resetsMs, // already epoch ms → passed through untouched
      },
      {
        // No resets-at from the mint → no header (the client renders no
        // countdown); the envelope still carries the verdict.
        thrown: new MintInternalError(402, { detail: "monthly free limit reached" }),
        status: 402,
        body: { error: { code: "daily_limit_reached", message: "monthly free limit reached" } },
      },
      // Non-relayable mint statuses and plain failures → generic 409.
      { thrown: new MintInternalError(500, { error: { code: "internal" } }), status: 409 },
      { thrown: new Error("mint connection refused"), status: 409 },
    ];

    for (const c of cases) {
      const failing = makeApp({ mintThrows: c.thrown });
      const res = await sendMessage(failing, uid, sid, { content: "will not land" });
      expect(res.statusCode, String(c.status)).toBe(c.status);
      if (c.body !== undefined) {
        expect(res.json()).toEqual(c.body); // client-shaped envelope
        expect(res.headers["x-ovid-resets-at"]).toBe(c.resetsAt ?? undefined);
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

  it("mint call gets a deadline: a hung internal-mint fetch → bounded 503 unavailable, no writes", async () => {
    // P10 Task 2. The real internal-mint HTTP provisioner with a fetch that
    // never settles. Without GatewayDeps.mintTimeoutMs the route would hang
    // forever; with it the request must answer 503 `unavailable` well under
    // 1 s.
    const neverFetch = (() => new Promise<Response>(() => {})) as typeof fetch;
    const mint = createInternalMintProvisioner(
      "http://mint.invalid",
      "test-internal-secret-0123456789abcdef",
      neverFetch,
    );
    const handle = makeApp({ mint, mintTimeoutMs: 50 });
    const uid = testUid("msg-mintdeadline");
    const sid = await createSession(handle, uid);

    const started = Date.now();
    const res = await sendMessage(handle, uid, sid, { content: "bounded" });
    const elapsed = Date.now() - started;

    expect(elapsed).toBeLessThan(1_000);
    expect(res.statusCode).toBe(503);
    expect(res.json().error.code).toBe("unavailable");
    expect(handle.adds).toHaveLength(0);
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
          // Only the assistant turn captured provider thinking; every other
          // row must come back without the field at all.
          ...(i === 3 ? { reasoning: "considered the alternatives" } : {}),
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
    // Reasoning rides the DTO when the row captured it, and is omitted (not
    // null) for every row that did not — older clients see no change.
    expect(allBody.items[0]!.reasoning).toBeUndefined();
    expect(allBody.items[1]).toMatchObject({
      role: "assistant",
      content: "m3",
      reasoning: "considered the alternatives",
    });

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

  // -------------------------------------------------------------------------
  // maxOutputTokens (Settings "Max output tokens"): gateway-validated on the
  // send wire, forwarded on the job payload exactly like attachmentIds —
  // the key is present only when the request sent one (additive wire).
  // -------------------------------------------------------------------------

  it("send with maxOutputTokens → 202 and the enqueued job payload carries the cap", async () => {
    const handle = makeApp();
    const uid = testUid("msg-maxtok");
    const sid = await createSession(handle, uid);

    const res = await sendMessage(handle, uid, sid, {
      content: "keep it short",
      maxOutputTokens: 2048,
    });
    expect(res.statusCode).toBe(202);
    expect(handle.adds).toHaveLength(1);
    expect(handle.adds[0]!.data).toEqual({
      runId: expect.any(String) as string,
      sessionId: sid,
      userId: uid,
      prompt: "keep it short",
      tier: "free",
      maxOutputTokens: 2048,
    });
  });

  it("absent maxOutputTokens → 202 and the job payload carries NO maxOutputTokens key", async () => {
    const handle = makeApp();
    const uid = testUid("msg-maxtok-none");
    const sid = await createSession(handle, uid);

    const res = await sendMessage(handle, uid, sid, { content: "auto is fine" });
    expect(res.statusCode).toBe(202);
    const add = handle.adds.at(-1)!;
    expect(add.data).toEqual({
      runId: expect.any(String) as string,
      sessionId: sid,
      userId: uid,
      prompt: "auto is fine",
      tier: "free",
    });
    expect("maxOutputTokens" in add.data).toBe(false);
  });

  it("maxOutputTokens above the cap, non-integer, or non-positive → 400 bad_request, nothing written or enqueued", async () => {
    const handle = makeApp();
    const uid = testUid("msg-maxtok-bad");
    const sid = await createSession(handle, uid);

    for (const maxOutputTokens of [8193, 0, -1, 2048.5, "2048"]) {
      const res = await sendMessage(handle, uid, sid, { content: "x", maxOutputTokens });
      expect(res.statusCode, JSON.stringify(maxOutputTokens)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
    expect(handle.adds).toHaveLength(0);
    expect(await tableCounts(sid)).toEqual({ messages: 0, runs: 0 });
  });

  // -------------------------------------------------------------------------
  // P8 Task 4: clientMsgId idempotency — a retried send with the same
  // (sessionId, clientMsgId) replays the ORIGINAL answer instead of inserting
  // a second message/run; a clientMsgId owned by a run-less message is a 409.
  // -------------------------------------------------------------------------

  it("send with clientMsgId twice → second is a REPLAY: 202 with the identical runId/userMessageId, exactly one message row, one run row, one queue add", async () => {
    const handle = makeApp();
    const uid = testUid("msg-cmid");
    const sid = await createSession(handle, uid);

    const first = await sendMessage(handle, uid, sid, { content: "once", clientMsgId: "c-retry-1" });
    expect(first.statusCode).toBe(202);
    const firstBody = first.json() as SendMessageResponse;

    // The retry may carry different content — the replay answers with the
    // ORIGINAL run/message ids either way (the original send already landed).
    const second = await sendMessage(handle, uid, sid, { content: "once (retry)", clientMsgId: "c-retry-1" });
    expect(second.statusCode).toBe(202);
    expect(second.json()).toEqual(firstBody);
    expect(second.json()).toEqual({
      runId: firstBody.runId,
      userMessageId: firstBody.userMessageId,
      status: "queued",
      model: "auto",
    });

    // No second message, no second run, no second enqueue.
    expect(handle.adds).toHaveLength(1);
    expect(handle.adds[0]!.data).toMatchObject({ runId: firstBody.runId });
    expect(await tableCounts(sid)).toEqual({ messages: 1, runs: 1 });

    // The replay wins even when the retry's attachmentIds are garbage: the
    // conflict check runs BEFORE attachment validation (a retry whose
    // attachments went stale must still replay, not 400).
    const third = await sendMessage(handle, uid, sid, {
      content: "once (retry 2)",
      clientMsgId: "c-retry-1",
      attachmentIds: [newId()],
    });
    expect(third.statusCode).toBe(202);
    expect(third.json()).toEqual(firstBody);
    expect(handle.adds).toHaveLength(1);
    expect(await tableCounts(sid)).toEqual({ messages: 1, runs: 1 });
  });

  it("clientMsgId already used by a message with NO run → 409 run_conflict, nothing written or enqueued", async () => {
    const handle = makeApp();
    const uid = testUid("msg-cmconf");
    const sid = await createSession(handle, uid);
    // A run-less message holding the clientMsgId (e.g. seeded by the import
    // route): a new send must NOT silently create a second message/run for it.
    await messages.append(db, {
      sessionId: sid,
      role: "user",
      content: "seeded by import",
      clientMsgId: "c-imported",
    });

    const res = await sendMessage(handle, uid, sid, { content: "conflicting", clientMsgId: "c-imported" });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("run_conflict");

    expect(handle.adds).toHaveLength(0);
    expect(await tableCounts(sid)).toEqual({ messages: 1, runs: 0 });
  });

  // -------------------------------------------------------------------------
  // Review round 1 (IMPORTANT): the 409 window. Between the winner's
  // message-commit and its runs.create, a same-key concurrent send observes
  // "message exists, no run" — the conflict state — and must NOT conclude
  // 409: the run is about to appear. The route re-checks (bounded: 3 tries,
  // 25ms apart) before answering 409; if the run appears, it replays 202.
  // -------------------------------------------------------------------------

  it("409-window healing: a same-key send landing between the winner's message-commit and its runs.create → 202 replay once the run appears", async () => {
    const handle = makeApp();
    const uid = testUid("msg-heal");
    const sid = await createSession(handle, uid);

    // The race window state, exactly: the winner's message row is committed
    // but its run row is not yet created (simulated with direct repo writes —
    // the route has no timing seam of its own).
    const seeded = await messages.append(db, {
      sessionId: sid,
      role: "user",
      content: "winner's message",
      clientMsgId: "c-heal",
    });
    // The winner's runs.create lands ~30ms in — inside the healing window
    // (re-checks at ~25/50/75ms), comfortably between the first and second.
    const winnerRun = (async () => {
      await new Promise((resolve) => setTimeout(resolve, 30));
      return runs.create(db, { sessionId: sid, promptMessageId: seeded.id });
    })();

    const res = await sendMessage(handle, uid, sid, { content: "retry", clientMsgId: "c-heal" });
    const run = await winnerRun;
    expect(res.statusCode).toBe(202);
    expect(res.json()).toEqual({
      runId: run.id,
      userMessageId: seeded.id,
      status: "queued",
      model: "auto",
    });

    // The healing path inserted and enqueued NOTHING of its own.
    expect(handle.adds).toHaveLength(0);
    expect(await tableCounts(sid)).toEqual({ messages: 1, runs: 1 });
  });

  it("concurrent same-key sends (real 23505 race): both 202 with identical ids, exactly one message row and one run row", async () => {
    const handle = makeApp();
    const uid = testUid("msg-race");
    const sid = await createSession(handle, uid);

    // Two sends racing on the same key: both pass the pre-check (no message
    // yet), both append — one insert wins, the loser takes the 23505 catch,
    // re-resolves, and heals into the winner's replay answer.
    const [a, b] = await Promise.all([
      sendMessage(handle, uid, sid, { content: "race", clientMsgId: "c-race" }),
      sendMessage(handle, uid, sid, { content: "race (twin)", clientMsgId: "c-race" }),
    ]);
    expect(a.statusCode).toBe(202);
    expect(b.statusCode).toBe(202);
    expect(b.json()).toEqual(a.json());

    // Exactly one message, one run, one enqueue — the loser created nothing.
    expect(handle.adds).toHaveLength(1);
    expect(await tableCounts(sid)).toEqual({ messages: 1, runs: 1 });
  });

  it("clientMsgId bounds and per-session scope: empty → 400, > 64 chars → 400, same id under ANOTHER session → 202 fresh run", async () => {
    const handle = makeApp();
    const uid = testUid("msg-cmbounds");
    const sidA = await createSession(handle, uid);
    const sidB = await createSession(handle, uid);

    for (const clientMsgId of ["", "x".repeat(65)]) {
      const res = await sendMessage(handle, uid, sidA, { content: "x", clientMsgId });
      expect(res.statusCode, JSON.stringify(clientMsgId)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }

    // 64 chars exactly is fine.
    const ok = await sendMessage(handle, uid, sidA, { content: "max len", clientMsgId: "y".repeat(64) });
    expect(ok.statusCode).toBe(202);

    // Idempotency is PER SESSION: the same clientMsgId under session B is a
    // brand-new message/run, not a conflict.
    const other = await sendMessage(handle, uid, sidB, { content: "elsewhere", clientMsgId: "y".repeat(64) });
    expect(other.statusCode).toBe(202);
    expect((other.json() as SendMessageResponse).runId).not.toBe((ok.json() as SendMessageResponse).runId);
    expect(await tableCounts(sidB)).toEqual({ messages: 1, runs: 1 });
  });

  // ── W1 follow-up: @project turn refs (fail-safe) ────────────────────────

  it("projectRefs ride the job for that turn only and never persist into the next send", async () => {
    const handle = makeApp();
    const uid = testUid("msg-projrefs-ok");
    const sid = await createSession(handle, uid);
    const projectId = await createProject(handle, uid, "Tagged");

    const first = await sendMessage(handle, uid, sid, {
      content: `use @project:${projectId} context`,
      projectRefs: [projectId],
    });
    expect(first.statusCode).toBe(202);
    expect(handle.adds).toHaveLength(1);
    expect(handle.adds[0]!.data.projectRefs).toEqual([projectId]);

    // The next turn carries no refs unless the user tags again: project
    // context is per-turn, never persisted onto the session.
    const second = await sendMessage(handle, uid, sid, { content: "plain follow-up" });
    expect(second.statusCode).toBe(202);
    expect(handle.adds).toHaveLength(2);
    expect(handle.adds[1]!.data.projectRefs).toBeUndefined();
    expect(await tableCounts(sid)).toEqual({ messages: 2, runs: 2 });
  });

  it("foreign/unknown project refs fail the WHOLE send with a typed 400 and enqueue nothing", async () => {
    const handle = makeApp();
    const uid = testUid("msg-projrefs-foreign");
    const other = testUid("msg-projrefs-other");
    const sid = await createSession(handle, uid);
    const foreign = await createProject(handle, other, "Not yours");

    for (const projectId of [foreign, newId()]) {
      const res = await sendMessage(handle, uid, sid, {
        content: "should not send",
        projectRefs: [projectId],
      });
      expect(res.statusCode).toBe(400);
      expect(res.json().error.code).toBe("unknown_project_ref");
    }
    // No message row, no run row, no job, no mint: validation precedes every
    // side effect.
    expect(await tableCounts(sid)).toEqual({ messages: 0, runs: 0 });
    expect(handle.adds).toHaveLength(0);
    expect(handle.mint.calls).toEqual([]);
  });

  it("duplicate, over-limit and malformed project refs are refused with 400 and no side effects", async () => {
    const handle = makeApp();
    const uid = testUid("msg-projrefs-bad");
    const sid = await createSession(handle, uid);
    const projectId = await createProject(handle, uid, "One");

    const duplicate = await sendMessage(handle, uid, sid, {
      content: "dup",
      projectRefs: [projectId, projectId],
    });
    expect(duplicate.statusCode).toBe(400);
    expect(duplicate.json().error.code).toBe("duplicate_project_ref");

    const overLimit = await sendMessage(handle, uid, sid, {
      content: "too many",
      projectRefs: Array.from({ length: 6 }, () => projectId),
    });
    expect(overLimit.statusCode).toBe(400);
    expect(overLimit.json().error.code).toBe("bad_request");

    const malformed = await sendMessage(handle, uid, sid, {
      content: "malformed",
      projectRefs: ["not-a-uuid"],
    });
    expect(malformed.statusCode).toBe(400);
    expect(malformed.json().error.code).toBe("bad_request");

    expect(await tableCounts(sid)).toEqual({ messages: 0, runs: 0 });
    expect(handle.adds).toHaveLength(0);
    expect(handle.mint.calls).toEqual([]);
  });

  it("standalone sends are unaffected by project refs support", async () => {
    const handle = makeApp();
    const uid = testUid("msg-projrefs-standalone");
    const sid = await createSession(handle, uid);
    const res = await sendMessage(handle, uid, sid, { content: "no project" });
    expect(res.statusCode).toBe(202);
    expect(handle.adds[0]!.data.projectRefs).toBeUndefined();
  });

  // --- Token caps -----------------------------------------------------------
  //
  // Free is 50M tokens a day and 1.5B a month (paid tiers scale by their
  // auto multiplier). The counter is the `run_usage` ledger the worker already
  // writes. A send is refused only when the window is ALREADY spent — the
  // gateway cannot know a future run's size, so it stops at the ceiling, not
  // at an estimate.

  const CAP_NOW = new Date("2026-10-23T15:04:05.000Z");

  async function seedUsage(
    uid: string,
    sessionId: string,
    inputTokens: number,
    outputTokens: number,
    createdAt: Date,
  ): Promise<void> {
    await runUsage.record(db, {
      userId: uid,
      sessionId,
      runId: newId(),
      model: "deepseek-v4.1-flash",
      inputTokens,
      outputTokens,
      createdAt,
    });
  }

  it("refuses a send at the Free daily token ceiling: 402 daily_limit_reached + resets-at, no mint, no writes, no job", async () => {
    const handle = makeApp({ clock: () => CAP_NOW });
    const uid = testUid("msg-tokenday");
    const sid = await createSession(handle, uid);
    await seedUsage(uid, sid, 49_000_000, 1_000_000, new Date("2026-10-23T10:00:00.000Z"));

    const res = await sendMessage(handle, uid, sid, { content: "one more" });

    expect(res.statusCode).toBe(402);
    expect(res.json().error.code).toBe("daily_limit_reached");
    expect(res.json().error.message).toContain("daily");
    expect(res.json().error.message).toContain("50,000,000");
    // The client's whole 402 UX is the epoch-ms x-ovid-resets-at countdown.
    expect(res.headers["x-ovid-resets-at"]).toBe(
      String(Date.UTC(2026, 9, 24, 0, 0, 0)),
    );

    // Before mint and before every write: no key provisioning, no rows, no job.
    expect(handle.mint.calls).toEqual([]);
    expect(handle.adds).toHaveLength(0);
    expect(await tableCounts(sid)).toEqual({ messages: 0, runs: 0 });
  });

  it("refuses at the Free monthly ceiling when today is quiet, naming the month reset", async () => {
    const handle = makeApp({ clock: () => CAP_NOW });
    const uid = testUid("msg-tokenmonth");
    const sid = await createSession(handle, uid);
    // Spread over the month so the daily window is well under its cap.
    await seedUsage(uid, sid, 700_000_000, 0, new Date("2026-10-02T10:00:00.000Z"));
    await seedUsage(uid, sid, 800_000_000, 0, new Date("2026-10-12T10:00:00.000Z"));

    const res = await sendMessage(handle, uid, sid, { content: "one more" });

    expect(res.statusCode).toBe(402);
    expect(res.json().error.code).toBe("daily_limit_reached");
    expect(res.json().error.message).toContain("monthly");
    expect(res.json().error.message).toContain("1,500,000,000");
    expect(res.headers["x-ovid-resets-at"]).toBe(
      String(Date.UTC(2026, 10, 1, 0, 0, 0)),
    );
    expect(handle.mint.calls).toEqual([]);
    expect(handle.adds).toHaveLength(0);
    expect(await tableCounts(sid)).toEqual({ messages: 0, runs: 0 });
  });

  it("allows the send with headroom under the cap", async () => {
    const handle = makeApp({ clock: () => CAP_NOW });
    const uid = testUid("msg-tokenok");
    const sid = await createSession(handle, uid);
    await seedUsage(uid, sid, 49_999_999, 0, new Date("2026-10-23T10:00:00.000Z"));

    const res = await sendMessage(handle, uid, sid, { content: "still fine" });

    expect(res.statusCode).toBe(202);
    expect(handle.adds).toHaveLength(1);
    expect(handle.mint.calls).toEqual([{ uid }]);
  });

  it("gives a paid tier its multiplier: Go may pass Free's 50M daily ceiling", async () => {
    const handle = makeApp({ clock: () => CAP_NOW });
    const uid = testUid("msg-tokengo");
    const sid = await createSession(handle, uid);
    await db.$client.unsafe("UPDATE users SET tier = 'go' WHERE uid = $1", [uid]);
    await seedUsage(uid, sid, 60_000_000, 0, new Date("2026-10-23T10:00:00.000Z"));

    const res = await sendMessage(handle, uid, sid, { content: "go allows this" });

    expect(res.statusCode).toBe(202); // Go = 75M/day, not Free's 50M
    expect(handle.adds).toHaveLength(1);
  });

  it("BYOK sends are not held to the Ovid token allowance", async () => {
    // The cap measures what Ovid's own key spends. A BYOK send costs Ovid
    // nothing, so an exhausted plan allowance must not block it (the same
    // rule the mint-relayed 402 already follows).
    const handle = makeApp({ clock: () => CAP_NOW });
    const uid = testUid("msg-tokenbyok");
    const sid = await createSession(handle, uid);
    await seedUsage(uid, sid, 60_000_000, 0, new Date("2026-10-23T10:00:00.000Z"));
    const key = await byokKeysRepo.create(db, {
      userId: uid, providerId: "openai", endpoint: "https://api.openai.com/v1", label: null,
      wrappedDek: Buffer.from("d").toString("base64"), iv: Buffer.from("i").toString("base64"),
      ciphertext: Buffer.from("c").toString("base64"), tag: Buffer.from("t").toString("base64"),
    });
    await accountSettings.patch(db, uid, { byokDefault: { keyId: key.id, model: "gpt-4.1-mini" } });

    const res = await sendMessage(handle, uid, sid, { content: "my own key" });

    expect(res.statusCode).toBe(202);
    expect(handle.mint.calls).toEqual([]);
    expect(handle.adds[0]!.data).toMatchObject({ byokKeyId: key.id });
  });
});
