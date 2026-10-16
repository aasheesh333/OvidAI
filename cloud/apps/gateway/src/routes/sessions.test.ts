import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { newId, type Db } from "@ovid/db";
import { pageSchema, sessionDtoSchema, type Page, type SessionDto } from "@ovid/shared";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopDb,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";

const UUIDV7_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

// Fixed base (2023-11-14T22:13:20Z) for pinned updatedAt values, same trick as
// @ovid/db's repos.test.ts — list order never depends on wall-clock ties.
const BASE = 1_700_000_000_000;

const sessionPage = pageSchema(sessionDtoSchema);

describe.skipIf(!TEST_DATABASE_URL)("gateway session routes (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;

  beforeAll(async () => {
    db = await openTestDb();
    const { queues } = stubQueues();
    app = buildGateway({
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
  }, 60_000);

  afterAll(async () => {
    await app?.close();
    await closeDb(db);
  });

  async function createSession(uid: string, title?: string): Promise<SessionDto> {
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
      payload: title === undefined ? {} : { title },
    });
    expect(res.statusCode).toBe(201);
    return sessionDtoSchema.parse(res.json());
  }

  async function countUsers(uid: string): Promise<number> {
    const rows = await db.$client.unsafe(
      "SELECT count(*)::int AS n FROM users WHERE uid = $1",
      [uid],
    );
    return rows[0]!.n as number;
  }

  it("POST /sessions → 201 with UUIDv7-shaped id and ensures the users row", async () => {
    const uid = testUid("sess-create");
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
      payload: { title: "first" },
    });
    expect(res.statusCode).toBe(201);
    const dto = sessionDtoSchema.parse(res.json());
    expect(dto.id).toMatch(UUIDV7_RE);
    expect(dto.title).toBe("first");
    expect(Date.parse(dto.createdAt)).not.toBeNaN();
    expect(Date.parse(dto.updatedAt)).not.toBeNaN();

    // users.ensure ran BEFORE the session insert (FK satisfied), with the
    // principal's email and the column-default tier.
    const rows = await db.$client.unsafe(
      "SELECT uid, email, tier FROM users WHERE uid = $1",
      [uid],
    );
    expect(rows.length).toBe(1);
    expect(rows[0]!.email).toBe(`${uid}@stub.test`);
    expect(rows[0]!.tier).toBe("free");
  });

  it("POST /sessions without a body or with {} → 201, title null; ensure is idempotent", async () => {
    const uid = testUid("sess-empty");
    const noBody = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
    });
    expect(noBody.statusCode).toBe(201);
    expect(sessionDtoSchema.parse(noBody.json()).title).toBeNull();

    // Second + third create for the same uid: still exactly ONE users row.
    await createSession(uid);
    await createSession(uid, "t");
    expect(await countUsers(uid)).toBe(1);
  });

  it("POST /sessions rejects unknown keys and non-string titles → 400 bad_request", async () => {
    const uid = testUid("sess-bad");
    for (const payload of [{ nope: 1 }, { title: 42 }, { title: "ok", extra: "x" }]) {
      const res = await app.inject({
        method: "POST",
        url: "/cloud/v1/sessions",
        headers: authHeaders(uid),
        payload,
      });
      expect(res.statusCode, JSON.stringify(payload)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
      expect(typeof res.json().error.message).toBe("string");
    }
  });

  it("GET /sessions/:id → 200 for the owner; wrong owner and unknown id → 404 (never 403)", async () => {
    const owner = testUid("sess-get");
    const stranger = testUid("sess-stranger");
    const created = await createSession(owner, "mine");

    const mine = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(owner),
    });
    expect(mine.statusCode).toBe(200);
    expect(sessionDtoSchema.parse(mine.json())).toEqual(created);

    const theirs = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(stranger),
    });
    expect(theirs.statusCode).toBe(404); // existence leak rule: 404, NOT 403
    expect(theirs.json().error.code).toBe("not_found");

    const unknown = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${newId()}`,
      headers: authHeaders(owner),
    });
    expect(unknown.statusCode).toBe(404);
    expect(unknown.json().error.code).toBe("not_found");
  });

  it("GET /sessions/:id with a malformed id → 404 not_found (never 500 via Postgres 22P02)", async () => {
    const uid = testUid("sess-badid");
    // Client-typo shapes that would raise Postgres 22P02 (invalid uuid syntax)
    // if bound raw to the uuid column; the route contract says 404 not_found.
    const malformed = [
      "not-a-uuid", // a non-UUID word
      "9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a", // long random string
      "1234567", // numeric string
    ];
    for (const bad of malformed) {
      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${bad}`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode, bad).toBe(404);
      expect(res.statusCode, `${bad} must never be a 500`).not.toBe(500);
      expect(res.json().error.code).toBe("not_found");
      // Route-level envelope, not Fastify's unmatched-route 404 (both use
      // code not_found — the message proves the session route answered).
      expect(res.json().error.message).toBe("Session not found.");
    }
  });

  it("GET /sessions pages via cursor, most recent activity first, and never leaks other users", async () => {
    const uid = testUid("sess-list");
    const other = testUid("sess-list-other");
    await createSession(other, "not mine"); // must never appear in uid's pages

    const created: SessionDto[] = [];
    for (let i = 0; i < 5; i++) created.push(await createSession(uid, `s${i}`));
    // Pin activity order s0 (oldest) … s4 (newest). ($client.unsafe params
    // must be primitives — postgres.js does not serialize Date there.)
    for (let i = 0; i < created.length; i++) {
      await db.$client.unsafe(
        "UPDATE sessions SET updated_at = $2 WHERE id = $1",
        [created[i]!.id, new Date(BASE + i * 1000).toISOString()],
      );
    }
    const newestFirst = [...created].reverse().map((s) => s.id);

    // Walk pages of 2 via nextCursor: [2, 2, 1], last page cursor null.
    const seen: string[] = [];
    const pageSizes: number[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < 10; page++) {
      const url = cursor
        ? `/cloud/v1/sessions?limit=2&cursor=${encodeURIComponent(cursor)}`
        : "/cloud/v1/sessions?limit=2";
      const res = await app.inject({ method: "GET", url, headers: authHeaders(uid) });
      expect(res.statusCode).toBe(200);
      const body = sessionPage.parse(res.json()) as Page<SessionDto>;
      pageSizes.push(body.items.length);
      seen.push(...body.items.map((s) => s.id));
      cursor = body.nextCursor;
      if (cursor === null) break;
    }
    expect(pageSizes).toEqual([2, 2, 1]);
    expect(seen).toEqual(newestFirst);

    // Default limit (30) returns everything this user has, newest first.
    const all = await app.inject({
      method: "GET",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
    });
    expect(sessionPage.parse(all.json()).items.map((s) => s.id)).toEqual(newestFirst);

    // Empty user → empty page.
    const fresh = await app.inject({
      method: "GET",
      url: "/cloud/v1/sessions",
      headers: authHeaders(testUid("sess-none")),
    });
    expect(sessionPage.parse(fresh.json())).toEqual({ items: [], nextCursor: null });
  });

  it("GET /sessions clamps limit (ruling: clamp, never 400)", async () => {
    const uid = testUid("sess-clamp");
    for (let i = 0; i < 5; i++) await createSession(uid, `c${i}`);

    // Over-max clamps to 100 (all 5 fit), garbage/negative/zero clamp to the
    // default 30 (all 5 fit), fractional floors — none of these are errors.
    for (const limit of ["1000", "-1", "abc", "0", ""]) {
      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions?limit=${limit}`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode, `limit=${limit}`).toBe(200);
      expect(sessionPage.parse(res.json()).items).toHaveLength(5);
    }
    const fractional = await app.inject({
      method: "GET",
      url: "/cloud/v1/sessions?limit=2.7",
      headers: authHeaders(uid),
    });
    expect(fractional.statusCode).toBe(200);
    expect(sessionPage.parse(fractional.json()).items).toHaveLength(2);
  });

  it("GET /sessions with a garbage cursor degrades to the first page (lenient repo contract)", async () => {
    const uid = testUid("sess-cursor");
    const a = await createSession(uid, "a");
    const res = await app.inject({
      method: "GET",
      url: "/cloud/v1/sessions?limit=10&cursor=garbage",
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(200);
    expect(sessionPage.parse(res.json()).items.map((s) => s.id)).toEqual([a.id]);
  });

  it("all session routes answer 401 unauthenticated with the Task 6 envelope", async () => {
    const uid = testUid("sess-401");
    const created = await createSession(uid);
    const requests = [
      { method: "POST" as const, url: "/cloud/v1/sessions", payload: {} },
      { method: "GET" as const, url: "/cloud/v1/sessions" },
      { method: "GET" as const, url: `/cloud/v1/sessions/${created.id}` },
    ];
    for (const req of requests) {
      const res = await app.inject({ ...req, headers: {} });
      expect(res.statusCode, req.url).toBe(401);
      expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
    }
  });
});

describe("gateway session routes without a database", () => {
  it("POST /sessions with a malformed JSON body → 400 bad_request envelope (never reaches db)", async () => {
    const { queues } = stubQueues();
    const app = buildGateway({
      db: noopDb,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
    try {
      const res = await app.inject({
        method: "POST",
        url: "/cloud/v1/sessions",
        headers: { ...authHeaders(testUid("sess-json")), "content-type": "application/json" },
        payload: "{not-json",
      });
      expect(res.statusCode).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    } finally {
      await app.close();
    }
  });
});
