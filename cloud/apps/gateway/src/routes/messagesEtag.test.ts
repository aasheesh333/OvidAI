import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { eventMirror, messages, newId, sessions, users, type Db } from "@ovid/db";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubTickets,
  stubVerifier,
  stubSystemBus,
} from "../test/stubs.js";

/**
 * W12 — conditional GET on the message page. This is NOT public caching:
 * transcripts are per-user and mutable, so the response is `private,
 * no-cache` and every repeat load revalidates. The ETag only lets an
 * unchanged snapshot answer 304 without a body.
 */
describe.skipIf(!TEST_DATABASE_URL)("message page ETag / conditional GET", () => {
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

  function app(): FastifyInstance {
    const a = buildGateway({
      db,
      system: stubSystemBus(),
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
    apps.push(a);
    return a;
  }

  async function seed(): Promise<{ uid: string; sid: string }> {
    const uid = testUid("etag");
    await users.ensure(db, uid, `${uid}@stub.test`);
    const session = await sessions.create(db, uid, "ETag chat");
    await messages.append(db, { sessionId: session.id, role: "user", content: "hello" });
    await messages.append(db, { sessionId: session.id, role: "assistant", content: "hi" });
    return { uid, sid: session.id };
  }

  async function get(
    a: FastifyInstance,
    uid: string,
    sid: string,
    headers: Record<string, string> = {},
    query = "",
  ) {
    return a.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/messages${query}`,
      headers: { ...authHeaders(uid), ...headers },
    });
  }

  it("sets a strong ETag with private, no-cache and Authorization Vary", async () => {
    const { uid, sid } = await seed();
    const res = await get(app(), uid, sid);
    expect(res.statusCode).toBe(200);
    expect(res.headers.etag).toMatch(/^"[A-Za-z0-9_-]+"$/);
    expect(res.headers["cache-control"]).toBe("private, no-cache");
    expect(res.headers["cache-control"]).not.toContain("public");
    expect(String(res.headers.vary)).toContain("Authorization");
    expect(res.headers.pragma).toBe("no-cache");
  });

  it("answers 304 for an unchanged snapshot (strong, weak and wildcard matches)", async () => {
    const a = app();
    const { uid, sid } = await seed();
    const first = await get(a, uid, sid);
    const etag = first.headers.etag as string;

    for (const candidate of [etag, `W/${etag}`, "*"]) {
      const res = await get(a, uid, sid, { "if-none-match": candidate });
      expect(res.statusCode).toBe(304);
      expect(res.body).toBe("");
      expect(res.headers.etag).toBe(etag);
      expect(res.headers["cache-control"]).toBe("private, no-cache");
    }

    const stale = await get(a, uid, sid, { "if-none-match": '"not-the-tag"' });
    expect(stale.statusCode).toBe(200);
    expect(stale.json().items).toHaveLength(2);
  });

  it("changes the ETag when history or the page window changes", async () => {
    const a = app();
    const { uid, sid } = await seed();
    const first = await get(a, uid, sid);
    const etag = first.headers.etag as string;

    await messages.append(db, { sessionId: sid, role: "user", content: "another" });
    const after = await get(a, uid, sid, { "if-none-match": etag });
    expect(after.statusCode).toBe(200);
    expect(after.headers.etag).not.toBe(etag);

    const limited = await get(a, uid, sid, {}, "?limit=1");
    expect(limited.headers.etag).not.toBe(after.headers.etag);
  });

  it("changes the ETag when settled events are requested and exist", async () => {
    const a = app();
    const { uid, sid } = await seed();
    const plain = await get(a, uid, sid);
    await eventMirror.put(db, {
      sessionId: sid,
      seq: "1700000000000-0",
      type: "tool_completed",
      payload: { runId: newId(), callId: "c1", name: "read_file", isError: false, content: "ok" },
      ts: new Date().toISOString(),
    });
    const withEvents = await get(a, uid, sid, {}, "?events=1");
    expect(withEvents.statusCode).toBe(200);
    expect(withEvents.headers.etag).not.toBe(plain.headers.etag);
    expect(withEvents.json().events).toHaveLength(1);
  });

  it("keeps ownership first: a foreign user with the owner's ETag gets 404, never 304", async () => {
    const a = app();
    const { uid, sid } = await seed();
    const owner = await get(a, uid, sid);
    const foreign = testUid("etag-foreign");
    await users.ensure(db, foreign, `${foreign}@stub.test`);
    const res = await get(a, foreign, sid, { "if-none-match": owner.headers.etag as string });
    expect(res.statusCode).toBe(404);
    expect(res.json().error.code).toBe("not_found");
  });
});
