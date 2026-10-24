import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { eventMirror, messages, newId, runs, sessions, users, type Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import type { QueueServices } from "@ovid/queue";
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
  stubSystemBus,
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
      system: stubSystemBus(),
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
    // P8: every session route now carries mode; a fresh session is "auto"
    // (schema default) — spec D5: never "control".
    expect(dto.mode).toBe("auto");
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
    expect(sessionDtoSchema.parse(mine.json()).mode).toBe("auto");

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

  it("snapshot pagination does not skip an unfetched chat pinned between pages", async () => {
    const uid = testUid("sess-snapshot");
    const created: SessionDto[] = [];
    for (let i = 0; i < 3; i++) created.push(await createSession(uid, `s${i}`));
    const snapshot = String(Date.now());

    const first = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions?limit=1&snapshot=${encodeURIComponent(snapshot)}`,
      headers: authHeaders(uid),
    });
    expect(first.statusCode).toBe(200);
    const page = sessionPage.parse(first.json()) as Page<SessionDto>;
    expect(page.nextCursor).not.toBeNull();

    // Mutating activity order must not change this immutable snapshot walk.
    await app.inject({
      method: "PATCH",
      url: `/cloud/v1/sessions/${created[0]!.id}`,
      headers: authHeaders(uid),
      payload: { pinned: true, title: "renamed between pages" },
    });

    const seen = page.items.map((session) => session.id);
    let cursor = page.nextCursor;
    while (cursor !== null) {
      const next = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions?limit=1&snapshot=${encodeURIComponent(snapshot)}&cursor=${encodeURIComponent(cursor)}`,
        headers: authHeaders(uid),
      });
      expect(next.statusCode).toBe(200);
      const body = sessionPage.parse(next.json()) as Page<SessionDto>;
      seen.push(...body.items.map((session) => session.id));
      cursor = body.nextCursor;
    }
    expect(new Set(seen)).toEqual(new Set(created.map((session) => session.id)));
    expect(seen).toHaveLength(3);
  });

  it("snapshot enumeration includes a chat created during pagination but never repeats the boundary", async () => {
    const uid = testUid("sess-snapshot-create");
    const firstCreated = await createSession(uid, "first");
    const secondCreated = await createSession(uid, "second");
    const snapshot = String(Date.now());
    const first = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions?limit=1&snapshot=${snapshot}`,
      headers: authHeaders(uid),
    });
    const firstPage = sessionPage.parse(first.json()) as Page<SessionDto>;
    expect(firstPage.nextCursor).not.toBeNull();
    const newDuringWalk = await createSession(uid, "created during walk");

    const second = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions?limit=1&snapshot=${snapshot}&cursor=${encodeURIComponent(firstPage.nextCursor!)}`,
      headers: authHeaders(uid),
    });
    const secondPage = sessionPage.parse(second.json()) as Page<SessionDto>;
    expect(secondPage.nextCursor).toBeNull();
    const revalidated = await app.inject({
      method: "GET",
      url: "/cloud/v1/sessions?limit=100",
      headers: authHeaders(uid),
    });
    const boundary = (sessionPage.parse(revalidated.json()) as Page<SessionDto>).items;
    const ids = new Set([
      ...firstPage.items.map((item) => item.id),
      ...secondPage.items.map((item) => item.id),
      ...boundary
        .filter((item) => Date.parse(item.createdAt) > Number(snapshot))
        .map((item) => item.id),
    ]);
    expect(ids).toEqual(new Set([firstCreated.id, secondCreated.id, newDuringWalk.id]));
  });

  it("revalidation includes a session created exactly on the snapshot millisecond without duplicating it", async () => {
    const uid = testUid("sess-snapshot-same-ms");
    const existing = await createSession(uid, "existing");
    const snapshot = Date.now();
    const concurrent = await createSession(uid, "same millisecond");
    await db.$client.unsafe("UPDATE sessions SET created_at = $2 WHERE id IN ($1, $3)", [
      existing.id, new Date(snapshot).toISOString(), concurrent.id,
    ]);
    const snapshotRows = await app.inject({
      method: "GET", url: `/cloud/v1/sessions?limit=100&snapshot=${snapshot}`, headers: authHeaders(uid),
    });
    const latestRows = await app.inject({
      method: "GET", url: "/cloud/v1/sessions?limit=100", headers: authHeaders(uid),
    });
    const items = (sessionPage.parse(snapshotRows.json()) as Page<SessionDto>).items;
    const latest = (sessionPage.parse(latestRows.json()) as Page<SessionDto>).items;
    const merged = new Map(items.map((item) => [item.id, item]));
    for (const item of latest.filter((candidate) => Date.parse(candidate.createdAt) >= snapshot)) {
      merged.set(item.id, item);
    }
    expect(merged.has(concurrent.id)).toBe(true);
    expect(merged.size).toBe(2);
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

  it("PATCH /sessions/:id with a title-only body → 200, new title, mode unchanged", async () => {
    const owner = testUid("sess-patch-title");
    const created = await createSession(owner, "before");

    const res = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(owner),
      payload: { title: "after" },
    });
    expect(res.statusCode).toBe(200);
    const dto = sessionDtoSchema.parse(res.json());
    expect(dto.id).toBe(created.id);
    expect(dto.title).toBe("after");
    expect(dto.mode).toBe("auto"); // untouched by a title-only patch
    expect(Date.parse(dto.updatedAt)).toBeGreaterThanOrEqual(Date.parse(created.updatedAt));

    // Persisted, not just echoed: a fresh GET sees the new title.
    const again = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(owner),
    });
    expect(again.statusCode).toBe(200);
    expect(sessionDtoSchema.parse(again.json()).title).toBe("after");
  });

  it("PATCH /sessions/:id title null clears the title", async () => {
    const owner = testUid("sess-patch-null");
    const created = await createSession(owner, "clear me");
    const res = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(owner),
      payload: { title: null },
    });
    expect(res.statusCode).toBe(200);
    expect(sessionDtoSchema.parse(res.json()).title).toBeNull();
  });

  it("PATCH /sessions/:id mode 'studio' → 200, persisted and returned", async () => {
    const owner = testUid("sess-patch-mode");
    const created = await createSession(owner);

    const res = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(owner),
      payload: { mode: "studio" },
    });
    expect(res.statusCode).toBe(200);
    const dto = sessionDtoSchema.parse(res.json());
    expect(dto.mode).toBe("studio");
    expect(dto.title).toBeNull(); // mode-only patch leaves title alone

    // Persisted.
    const again = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(owner),
    });
    expect(sessionDtoSchema.parse(again.json()).mode).toBe("studio");
  });

  it("PATCH /sessions/:id with both fields → 200 applies both", async () => {
    const owner = testUid("sess-patch-both");
    const created = await createSession(owner, "old");
    const res = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(owner),
      payload: { title: "new", mode: "safe" },
    });
    expect(res.statusCode).toBe(200);
    const dto = sessionDtoSchema.parse(res.json());
    expect(dto.title).toBe("new");
    expect(dto.mode).toBe("safe");
  });

  it("PATCH /sessions/:id rejects {}, 'control', and unknown keys → 400 bad_request", async () => {
    const owner = testUid("sess-patch-bad");
    const created = await createSession(owner, "keep");
    const payloads = [
      {}, // at least one field required
      { mode: "control" }, // retired value (spec D5)
      { mode: "AUTO" }, // case-sensitive enum
      { title: "t", extra: "x" }, // strict: unknown key
      { title: 42 }, // non-string title
      { mode: 7 },
    ];
    for (const payload of payloads) {
      const res = await app.inject({
        method: "PATCH",
        url: `/cloud/v1/sessions/${created.id}`,
        headers: authHeaders(owner),
        payload,
      });
      expect(res.statusCode, JSON.stringify(payload)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
      expect(typeof res.json().error.message).toBe("string");
    }

    // Nothing was written by the rejected patches.
    const after = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(owner),
    });
    const dto = sessionDtoSchema.parse(after.json());
    expect(dto.title).toBe("keep");
    expect(dto.mode).toBe("auto");
  });

  it("PATCH /sessions/:id wrong owner, unknown id, and malformed id → 404 (never 403/500)", async () => {
    const owner = testUid("sess-patch-404");
    const stranger = testUid("sess-patch-stranger");
    const created = await createSession(owner, "mine");

    const theirs = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(stranger),
      payload: { title: "hijack" },
    });
    expect(theirs.statusCode).toBe(404); // existence leak rule: 404, NOT 403
    expect(theirs.json().error.code).toBe("not_found");

    const unknown = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/sessions/${newId()}`,
      headers: authHeaders(owner),
      payload: { title: "x" },
    });
    expect(unknown.statusCode).toBe(404);
    expect(unknown.json().error.code).toBe("not_found");

    for (const bad of ["not-a-uuid", "1234567"]) {
      const res = await app.inject({
        method: "PATCH",
        url: `/cloud/v1/sessions/${bad}`,
        headers: authHeaders(owner),
        payload: { title: "x" },
      });
      expect(res.statusCode, bad).toBe(404);
      expect(res.statusCode, `${bad} must never be a 500`).not.toBe(500);
      expect(res.json().error.code).toBe("not_found");
      // Route-level envelope, not Fastify's unmatched-route 404.
      expect(res.json().error.message).toBe("Session not found.");
    }

    // Owner's session untouched by all the 404s above.
    const after = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(owner),
    });
    expect(sessionDtoSchema.parse(after.json()).title).toBe("mine");
  });

  it("DELETE /sessions/:id → 204; GET 404s and the list hides the row (soft delete)", async () => {
    const owner = testUid("sess-del");
    const keep = await createSession(owner, "keep");
    const doomed = await createSession(owner, "doomed");

    const res = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/sessions/${doomed.id}`,
      headers: authHeaders(owner),
    });
    expect(res.statusCode).toBe(204);
    expect(res.body).toBe("");

    // Soft delete, not a drop: the row (and its history) stays, but every
    // read path filters deleted_at IS NULL.
    const rows = await db.$client.unsafe(
      "SELECT deleted_at FROM sessions WHERE id = $1",
      [doomed.id],
    );
    expect(rows.length).toBe(1);
    expect((rows[0] as unknown as { deleted_at: Date | null }).deleted_at).not.toBeNull();

    const get = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${doomed.id}`,
      headers: authHeaders(owner),
    });
    expect(get.statusCode).toBe(404);
    expect(get.json().error.code).toBe("not_found");

    // The list answers only the surviving session.
    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/sessions",
      headers: authHeaders(owner),
    });
    expect(sessionPage.parse(list.json()).items.map((s) => s.id)).toEqual([keep.id]);

    // PATCH on a deleted id is the same 404 (the update filters deleted_at).
    const patch = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/sessions/${doomed.id}`,
      headers: authHeaders(owner),
      payload: { title: "zombie" },
    });
    expect(patch.statusCode).toBe(404);

    // Idempotent delete discipline: deleting it AGAIN answers the same 404
    // the unknown-id path does — no existence leak, never a 500.
    const again = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/sessions/${doomed.id}`,
      headers: authHeaders(owner),
    });
    expect(again.statusCode).toBe(404);
    expect(again.json().error.code).toBe("not_found");
  });

  it("DELETE /sessions/:id wrong owner, unknown id, malformed id → the identical 404 (never 403/500)", async () => {
    const owner = testUid("sess-del-404");
    const stranger = testUid("sess-del-stranger");
    const created = await createSession(owner, "mine");

    const theirs = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(stranger),
    });
    expect(theirs.statusCode).toBe(404); // existence leak rule: 404, NOT 403

    const unknown = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/sessions/${newId()}`,
      headers: authHeaders(owner),
    });
    expect(unknown.statusCode).toBe(404);
    // Identical envelope — no existence leak between wrong-owner and unknown.
    expect(theirs.json()).toEqual(unknown.json());
    expect(theirs.json().error.code).toBe("not_found");

    for (const bad of ["not-a-uuid", "1234567"]) {
      const res = await app.inject({
        method: "DELETE",
        url: `/cloud/v1/sessions/${bad}`,
        headers: authHeaders(owner),
      });
      expect(res.statusCode, bad).toBe(404);
      expect(res.statusCode, `${bad} must never be a 500`).not.toBe(500);
      expect(res.json().error.code).toBe("not_found");
      expect(res.json().error.message).toBe("Session not found.");
    }

    // The 404 probes touched nothing.
    const after = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${created.id}`,
      headers: authHeaders(owner),
    });
    expect(after.statusCode).toBe(200);
    expect(sessionDtoSchema.parse(after.json()).title).toBe("mine");
  });

  it("DELETE /sessions/:id with an active run → 204 and the run is cancelled", async () => {
    // Local stubs (runs.test.ts pattern): the shared describe app's
    // stubQueues has no agentRuns.remove, which would degrade the cancel to
    // "cancelling"; this test pins the full queued-run terminalization.
    const removes: string[] = [];
    const appended: unknown[] = [];
    // Unique seq per append — the mirror's PK is (session_id, seq).
    let seq = 0;
    const queues = {
      agentRuns: {
        add: async () => ({ id: "", name: "", data: undefined }),
        remove: async (jobId: string) => {
          removes.push(jobId);
        },
        client: Promise.resolve({ ping: async () => "PONG" }),
      },
    } as unknown as QueueServices;
    const events = {
      async append(sessionId: string, type: string, payload: Record<string, unknown>) {
        const event = { sessionId, seq: `${++seq}-0`, type, payload, ts: new Date() };
        appended.push(event);
        return event;
      },
    } as unknown as EventLog;
    const runApp = buildGateway({
      system: stubSystemBus(),
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events,
    });
    try {
      // Seed exactly what POST /messages leaves: user + session + prompt + a
      // QUEUED run (plus a second still-active run — both must be cancelled).
      const uid = testUid("sess-del-run");
      await users.ensure(db, uid, `${uid}@stub.test`);
      const session = await sessions.create(db, uid, "busy");
      const prompt = await messages.append(db, {
        sessionId: session.id,
        role: "user",
        content: "cancel me",
      });
      const run = await runs.create(db, {
        sessionId: session.id,
        promptMessageId: prompt.id,
      });
      const prompt2 = await messages.append(db, {
        sessionId: session.id,
        role: "user",
        content: "and me",
      });
      const run2 = await runs.create(db, {
        sessionId: session.id,
        promptMessageId: prompt2.id,
      });

      const res = await runApp.inject({
        method: "DELETE",
        url: `/cloud/v1/sessions/${session.id}`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(204);

      // Both queued runs were terminalized with the cancelled verdict —
      // the same run_failed{cancelled} the POST cancel route emits.
      expect(removes.sort()).toEqual([run.id, run2.id].sort());
      const rows = await db.$client.unsafe(
        "SELECT status, last_error FROM runs WHERE session_id = $1 ORDER BY id",
        [session.id],
      );
      for (const row of rows as unknown as Array<{ status: string; last_error: string | null }>) {
        expect(row.status).toBe("cancelled");
        expect(row.last_error).toBe("Stopped by user.");
      }
      expect(appended).toHaveLength(2);

      // The run-failed events are mirrored exactly like the worker does.
      const mirrored = await eventMirror.readSince(db, session.id, null, 50);
      expect(mirrored.map((e) => e.type)).toEqual(["run_failed", "run_failed"]);

      // And the session itself is soft-deleted.
      const after = await runApp.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${session.id}`,
        headers: authHeaders(uid),
      });
      expect(after.statusCode).toBe(404);
    } finally {
      await runApp.close();
    }
  });

  it("all session routes answer 401 unauthenticated with the Task 6 envelope", async () => {
    const uid = testUid("sess-401");
    const created = await createSession(uid);
    const requests = [
      { method: "POST" as const, url: "/cloud/v1/sessions", payload: {} },
      { method: "GET" as const, url: "/cloud/v1/sessions" },
      { method: "GET" as const, url: `/cloud/v1/sessions/${created.id}` },
      { method: "PATCH" as const, url: `/cloud/v1/sessions/${created.id}`, payload: { title: "x" } },
      { method: "DELETE" as const, url: `/cloud/v1/sessions/${created.id}` },
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
      system: stubSystemBus(),
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
