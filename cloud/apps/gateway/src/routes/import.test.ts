import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { messages, sessions, type Db } from "@ovid/db";
import { importReportSchema, type ImportReport } from "@ovid/shared";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import { stubSystemBus, authHeaders, noopEvents, stubKeys, stubMint, stubQueues, stubTickets, stubVerifier } from "../test/stubs.js";

const UUIDV7_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/**
 * P8 Task 4: POST /cloud/v1/import/sessions — bulk history import (Android
 * thin-client transcripts+sessions). clientMsgId is the per-session
 * idempotency key: re-sent ids are skipped, never duplicated; stored
 * createdAt values are the CLIENT's (timestamp fidelity, spec §13.3).
 */
describe.skipIf(!TEST_DATABASE_URL)("gateway import route (real postgres)", () => {
  let db: Db;
  const built: FastifyInstance[] = [];

  beforeAll(async () => {
    db = await openTestDb();
  }, 60_000);

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  /** Fresh gateway per test. The import path enqueues nothing, so the queue stub is inert. */
  function makeApp(): FastifyInstance {
    const { queues } = stubQueues({});
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint({}),
      events: noopEvents,
    });
    built.push(app);
    return app;
  }

  function postImport(app: FastifyInstance, uid: string, payload: unknown) {
    return app.inject({
      method: "POST",
      url: "/cloud/v1/import/sessions",
      headers: authHeaders(uid),
      payload: payload as object,
    });
  }

  /** A 3-message transcript slice (client-generated ids + client timestamps). */
  function batch(prefix: string): Array<{
    clientMsgId: string;
    role: "user" | "assistant";
    content: string;
    createdAt: string;
  }> {
    return [
      {
        clientMsgId: `${prefix}-1`,
        role: "user",
        content: "what is the capital of France?",
        createdAt: "2025-01-02T03:04:05.678Z",
      },
      {
        clientMsgId: `${prefix}-2`,
        role: "assistant",
        content: "Paris",
        createdAt: "2025-01-02T03:04:09.000Z",
      },
      {
        clientMsgId: `${prefix}-3`,
        role: "user",
        content: "thanks",
        createdAt: "2025-01-02T03:05:00.123Z",
      },
    ];
  }

  it("fresh import → 201 {sessionId, imported, skipped}; rows carry the CLIENT createdAt values; session carries client title/createdAt", async () => {
    const app = makeApp();
    const uid = testUid("imp-ok");
    const msgs = batch("ok");

    const res = await postImport(app, uid, {
      title: "old phone chat",
      createdAt: "2024-05-06T07:08:09.000Z",
      messages: msgs,
    });
    expect(res.statusCode).toBe(201);
    const report = importReportSchema.parse(res.json()) as ImportReport;
    expect(report).toEqual({
      sessionId: expect.stringMatching(UUIDV7_RE),
      imported: 3,
      skipped: 0,
    });

    // Timestamp fidelity (spec §13.3): every row stores the client's value.
    const page = await messages.page(db, report.sessionId, { limit: 10 });
    expect(page.rows).toHaveLength(3);
    const byContent = new Map(page.rows.map((m) => [m.content, m]));
    expect(byContent.get("what is the capital of France?")!.createdAt.toISOString()).toBe(
      "2025-01-02T03:04:05.678Z",
    );
    expect(byContent.get("Paris")!.role).toBe("assistant");
    expect(byContent.get("Paris")!.createdAt.toISOString()).toBe("2025-01-02T03:04:09.000Z");
    expect(byContent.get("thanks")!.createdAt.toISOString()).toBe("2025-01-02T03:05:00.123Z");

    // The session itself: client title + client createdAt, owned by the caller.
    const session = await sessions.get(db, report.sessionId, uid);
    expect(session).not.toBeNull();
    expect(session!.title).toBe("old phone chat");
    expect(session!.createdAt.toISOString()).toBe("2024-05-06T07:08:09.000Z");
    // Ownership scoping: a stranger sees nothing.
    expect(await sessions.get(db, report.sessionId, testUid("imp-ok-stranger"))).toBeNull();
  });

  it("continuation: re-sending the SAME body WITH the returned sessionId → 201 {imported:0, skipped:3}, never a duplicate row; a mixed batch imports only the new ids", async () => {
    const app = makeApp();
    const uid = testUid("imp-cont");
    const msgs = batch("cont");

    const first = await postImport(app, uid, { messages: msgs });
    expect(first.statusCode).toBe(201);
    const firstReport = importReportSchema.parse(first.json()) as ImportReport;
    expect(firstReport.imported).toBe(3);

    // Exact re-send (the binding pin): duplicates skip, the SAME sessionId
    // comes back — this is the only path where per-session duplicate-skip is
    // observable.
    const again = await postImport(app, uid, {
      sessionId: firstReport.sessionId,
      messages: msgs,
    });
    expect(again.statusCode).toBe(201);
    expect(again.json()).toEqual({
      sessionId: firstReport.sessionId,
      imported: 0,
      skipped: 3,
    });
    expect((await messages.page(db, firstReport.sessionId, { limit: 10 })).rows).toHaveLength(3);

    // Mixed batch: two duplicates + one new id → imports exactly the new one.
    const mixed = await postImport(app, uid, {
      sessionId: firstReport.sessionId,
      messages: [msgs[0]!, { ...msgs[2]!, clientMsgId: "cont-4", content: "one more" }, msgs[1]!],
    });
    expect(mixed.statusCode).toBe(201);
    expect(mixed.json()).toEqual({ sessionId: firstReport.sessionId, imported: 1, skipped: 2 });
    expect((await messages.page(db, firstReport.sessionId, { limit: 10 })).rows).toHaveLength(4);
  });

  it("a fresh call WITHOUT sessionId creates a FRESH session (idempotency is per-session, so nothing is skipped)", async () => {
    const app = makeApp();
    const uid = testUid("imp-fresh");
    const msgs = batch("fresh");

    const a = await postImport(app, uid, { messages: msgs });
    const b = await postImport(app, uid, { messages: msgs });
    expect(a.statusCode).toBe(201);
    expect(b.statusCode).toBe(201);
    const ra = importReportSchema.parse(a.json()) as ImportReport;
    const rb = importReportSchema.parse(b.json()) as ImportReport;
    expect(rb.sessionId).not.toBe(ra.sessionId);
    expect(rb.imported).toBe(3); // per-session key → no skips in the new session
    expect(rb.skipped).toBe(0);
  });

  it("boundary: exactly 500 messages import fine, 501 → 400 import_too_large", async () => {
    const app = makeApp();
    const uid = testUid("imp-size");
    const makeMessages = (n: number) =>
      Array.from({ length: n }, (_, i) => ({
        clientMsgId: `size-${i}`,
        role: "user" as const,
        content: `m${i}`,
        createdAt: "2025-01-01T00:00:00.000Z",
      }));

    const atLimit = await postImport(app, uid, { messages: makeMessages(500) });
    expect(atLimit.statusCode).toBe(201);
    expect(importReportSchema.parse(atLimit.json()).imported).toBe(500);

    const over = await postImport(app, uid, { messages: makeMessages(501) });
    expect(over.statusCode).toBe(400);
    expect(over.json().error.code).toBe("import_too_large");
  });

  it("continuation against a session owned by someone else, or an unknown session → 404 not_found, nothing imported", async () => {
    const app = makeApp();
    const owner = testUid("imp-owner");
    const stranger = testUid("imp-stranger");
    const owned = await postImport(app, owner, { messages: batch("own") });
    const ownedId = (importReportSchema.parse(owned.json()) as ImportReport).sessionId;

    // Wrong owner and unknown id are indistinguishable — never 403.
    const foreign = await postImport(app, stranger, { sessionId: ownedId, messages: batch("hijack") });
    expect(foreign.statusCode).toBe(404);
    expect(foreign.json().error.code).toBe("not_found");

    const unknown = await postImport(app, owner, {
      sessionId: "018f3e11-0000-7000-8000-000000000000",
      messages: batch("ghost"),
    });
    expect(unknown.statusCode).toBe(404);
    expect(unknown.json().error.code).toBe("not_found");

    // Neither call wrote anything into the owner's session.
    expect((await messages.page(db, ownedId, { limit: 10 })).rows).toHaveLength(3);
  });

  it("validation → 400 bad_request: empty messages, unknown body/message keys, missing clientMsgId, bad role, non-ISO createdAt, non-uuid sessionId, oversized clientMsgId", async () => {
    const app = makeApp();
    const uid = testUid("imp-bad");

    const bad: unknown[] = [
      { messages: [] },
      { messages: batch("v"), extra: 1 },
      { messages: [{ role: "user", content: "x", createdAt: "2025-01-01T00:00:00.000Z" }] }, // missing clientMsgId
      {
        messages: [
          { clientMsgId: "v-1", role: "narrator", content: "x", createdAt: "2025-01-01T00:00:00.000Z" },
        ],
      },
      {
        messages: [
          { clientMsgId: "v-1", role: "user", content: "x", createdAt: "not-a-timestamp" },
        ],
      },
      { sessionId: "not-a-uuid", messages: batch("v") },
      { messages: [{ ...batch("v")[0]!, clientMsgId: "x".repeat(65) }] },
    ];
    for (const payload of bad) {
      const res = await postImport(app, uid, payload);
      expect(res.statusCode, JSON.stringify(payload)).toBe(400);
      expect(res.json().error.code, JSON.stringify(payload)).toBe("bad_request");
    }
  });

  it("import route answers 401 unauthenticated with the shared envelope", async () => {
    const app = makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/import/sessions",
      headers: {},
      payload: { messages: batch("noauth") },
    });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
  });
});
