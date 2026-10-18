import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { eventMirror, newId, type Db } from "@ovid/db";
import type { SessionEvent } from "@ovid/shared";
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
} from "../test/stubs.js";

const BASE = 1_700_000_000_000;

describe.skipIf(!TEST_DATABASE_URL)("gateway session-event routes (real postgres)", () => {
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

  /** Fresh gateway per test (no state leaks between cases). */
  function makeApp(): FastifyInstance {
    const { queues } = stubQueues();
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
    built.push(app);
    return app;
  }

  async function createSession(app: FastifyInstance, uid: string): Promise<string> {
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
      payload: {},
    });
    expect(res.statusCode).toBe(201);
    return res.json().id as string;
  }

  /** Seed events in the given order and return the exact stored envelopes. */
  async function seedEvents(sessionId: string, seqs: readonly string[]): Promise<SessionEvent[]> {
    const events: SessionEvent[] = seqs.map((seq, i) => ({
      sessionId,
      seq,
      type: "message_delta",
      payload: { n: i + 1 },
      ts: new Date(BASE + i + 1).toISOString(),
    }));
    for (const e of events) await eventMirror.put(db, e);
    return events;
  }

  function getEvents(
    app: FastifyInstance,
    uid: string,
    sessionId: string,
    query = "",
  ) {
    return app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sessionId}/events${query}`,
      headers: authHeaders(uid),
    });
  }

  const SEQ = ["1000-0", "1000-5", "1000-10", "1001-0", "1002-0"];

  it("owner gets their events, ascending, in the exact shared wire shape", async () => {
    const app = makeApp();
    const uid = testUid("evt-shape");
    const sid = await createSession(app, uid);
    const seeded = await seedEvents(sid, SEQ);

    const res = await getEvents(app, uid, sid);
    expect(res.statusCode).toBe(200);
    const body = res.json() as { events: SessionEvent[] };
    expect(body).toEqual({ events: seeded });
    // Exact keys — no extra/missing fields on the wire.
    for (const e of body.events) {
      expect(Object.keys(e).sort()).toEqual(["payload", "seq", "sessionId", "ts", "type"]);
      expect(typeof e.ts).toBe("string");
    }
    expect(body.events.map((e) => e.seq)).toEqual(SEQ);
  });

  it("another user's session → 404; unknown id → 404; malformed id → 404", async () => {
    const app = makeApp();
    const owner = testUid("evt-owner");
    const other = testUid("evt-other");
    const sid = await createSession(app, owner);
    await seedEvents(sid, ["1000-0"]);

    const foreign = await getEvents(app, other, sid);
    expect(foreign.statusCode).toBe(404);
    expect(foreign.json()).toEqual({
      error: { code: "not_found", message: "Session not found." },
    });

    const unknown = await getEvents(app, owner, newId());
    expect(unknown.statusCode).toBe(404);
    expect(unknown.json()).toEqual({
      error: { code: "not_found", message: "Session not found." },
    });

    const malformed = await app.inject({
      method: "GET",
      url: "/cloud/v1/sessions/not-a-uuid/events",
      headers: authHeaders(owner),
    });
    expect(malformed.statusCode).toBe(404);
    expect(malformed.json()).toEqual({
      error: { code: "not_found", message: "Session not found." },
    });
  });

  it("after is exclusive and pages forward", async () => {
    const app = makeApp();
    const uid = testUid("evt-after");
    const sid = await createSession(app, uid);
    const seeded = await seedEvents(sid, SEQ);

    const res = await getEvents(app, uid, sid, `?after=${seeded[1]!.seq}`);
    expect(res.statusCode).toBe(200);
    expect((res.json() as { events: SessionEvent[] }).events.map((e) => e.seq)).toEqual([
      "1000-10",
      "1001-0",
      "1002-0",
    ]);

    // Exclusivity at the tail: the last seq yields nothing.
    const tail = await getEvents(app, uid, sid, `?after=${seeded[4]!.seq}`);
    expect(tail.statusCode).toBe(200);
    expect((tail.json() as { events: SessionEvent[] }).events).toEqual([]);

    // Forward paging honours the limit.
    const limited = await getEvents(app, uid, sid, `?after=${seeded[0]!.seq}&limit=2`);
    expect((limited.json() as { events: SessionEvent[] }).events.map((e) => e.seq)).toEqual([
      "1000-5",
      "1000-10",
    ]);
  });

  it("before is exclusive, pages backward, and stays ascending", async () => {
    const app = makeApp();
    const uid = testUid("evt-before");
    const sid = await createSession(app, uid);
    const seeded = await seedEvents(sid, SEQ);

    // Strictly before the boundary (which itself is excluded).
    const res = await getEvents(app, uid, sid, `?before=${seeded[2]!.seq}`);
    expect(res.statusCode).toBe(200);
    expect((res.json() as { events: SessionEvent[] }).events.map((e) => e.seq)).toEqual([
      "1000-0",
      "1000-5",
    ]);

    // Backward paging takes the page NEAREST the boundary, still ascending.
    const limited = await getEvents(app, uid, sid, `?before=${seeded[4]!.seq}&limit=2`);
    expect((limited.json() as { events: SessionEvent[] }).events.map((e) => e.seq)).toEqual([
      "1000-10",
      "1001-0",
    ]);

    // Before the first event → empty.
    const first = await getEvents(app, uid, sid, `?before=${seeded[0]!.seq}`);
    expect((first.json() as { events: SessionEvent[] }).events).toEqual([]);
  });

  it("before with no value returns the NEWEST page in ascending order", async () => {
    const app = makeApp();
    const uid = testUid("evt-newest");
    const sid = await createSession(app, uid);
    const seeded = await seedEvents(sid, SEQ);

    const res = await getEvents(app, uid, sid, "?before=");
    expect(res.statusCode).toBe(200);
    expect((res.json() as { events: SessionEvent[] }).events.map((e) => e.seq)).toEqual(SEQ);

    const limited = await getEvents(app, uid, sid, "?limit=2");
    expect((limited.json() as { events: SessionEvent[] }).events).toEqual(
      seeded.slice(-2),
    );
  });

  it("after wins when both after and before are present", async () => {
    const app = makeApp();
    const uid = testUid("evt-both");
    const sid = await createSession(app, uid);
    const seeded = await seedEvents(sid, SEQ);

    const res = await getEvents(
      app,
      uid,
      sid,
      `?after=${seeded[0]!.seq}&before=${seeded[4]!.seq}`,
    );
    expect(res.statusCode).toBe(200);
    expect((res.json() as { events: SessionEvent[] }).events.map((e) => e.seq)).toEqual([
      "1000-5",
      "1000-10",
      "1001-0",
      "1002-0",
    ]);
  });

  it("malformed after/before are ignored (default page, never 400)", async () => {
    const app = makeApp();
    const uid = testUid("evt-malformed");
    const sid = await createSession(app, uid);
    await seedEvents(sid, SEQ);

    for (const query of ["?after=garbage", "?before=not-a-seq", "?after=-1", "?before=1-2-3"]) {
      const res = await getEvents(app, uid, sid, query);
      expect(res.statusCode, query).toBe(200);
      // No usable cursor → the newest page (all five here), ascending.
      expect((res.json() as { events: SessionEvent[] }).events.map((e) => e.seq), query).toEqual(SEQ);
    }
  });

  it("limit clamps: 0/negative/garbage → default 200; >1000 → 1000", async () => {
    const app = makeApp();
    const uid = testUid("evt-limit");
    const sid = await createSession(app, uid);
    const total = 1001;
    const seqs = Array.from({ length: total }, (_, i) => `1700000000000-${i}`);
    await seedEvents(sid, seqs);

    for (const query of ["", "?limit=0", "?limit=-5", "?limit=abc"]) {
      const res = await getEvents(app, uid, sid, query);
      expect(res.statusCode, query).toBe(200);
      const events = (res.json() as { events: SessionEvent[] }).events;
      // Newest 200, ascending: i = 801 … 1000.
      expect(events, query).toHaveLength(200);
      expect(events[0]!.seq, query).toBe(`1700000000000-${total - 200}`);
      expect(events[events.length - 1]!.seq, query).toBe(`1700000000000-${total - 1}`);
    }

    const capped = await getEvents(app, uid, sid, "?limit=5000");
    expect(capped.statusCode).toBe(200);
    const events = (capped.json() as { events: SessionEvent[] }).events;
    expect(events).toHaveLength(1000);
    expect(events[0]!.seq).toBe("1700000000000-1");
    expect(events[events.length - 1]!.seq).toBe(`1700000000000-${total - 1}`);
  }, 60_000);

  it("an empty session answers {events: []}", async () => {
    const app = makeApp();
    const uid = testUid("evt-empty");
    const sid = await createSession(app, uid);

    const res = await getEvents(app, uid, sid);
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ events: [] });
  });
});
