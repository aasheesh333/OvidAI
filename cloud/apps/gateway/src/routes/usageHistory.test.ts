import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { messages, runs, runUsage, sessions, users, type Db } from "@ovid/db";
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

// Fixed "now": 2026-10-19T12:00:00Z (17:30 IST).
const NOW = new Date("2026-10-19T12:00:00.000Z");

describe.skipIf(!TEST_DATABASE_URL)("GET /cloud/v1/usage/history (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;
  let uid: string;
  let other: string;
  const ids: { sessions: string[]; runs: string[] } = { sessions: [], runs: [] };

  async function seedRun(owner: string, title: string) {
    const session = await sessions.create(db, owner, title);
    const prompt = await messages.append(db, { sessionId: session.id, role: "user", content: "q" });
    const run = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
    return { sessionId: session.id, runId: run.id };
  }

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
      system: stubSystemBus(),
      clock: () => NOW,
    });
    uid = testUid("usage-hist");
    other = testUid("usage-other");
    await users.ensure(db, uid, null);
    await users.ensure(db, other, null);
    const a = await seedRun(uid, "Alpha");
    const b = await seedRun(uid, "Beta");
    const o = await seedRun(other, "Theirs");
    ids.sessions.push(a.sessionId, b.sessionId);
    ids.runs.push(a.runId, b.runId);
    const rec = (
      r: { sessionId: string; runId: string },
      owner: string,
      model: string,
      input: number,
      output: number,
      at: string,
    ) =>
      runUsage.record(db, {
        userId: owner,
        sessionId: r.sessionId,
        runId: r.runId,
        model,
        inputTokens: input,
        outputTokens: output,
        cacheReadTokens: 10,
        cacheWriteTokens: 1,
        createdAt: new Date(at),
      });
    // Run A: 2026-10-18 20:00Z (= 10-19 01:30 IST) and 20:05Z.
    await rec(a, uid, "auto", 1000, 100, "2026-10-18T20:00:00.000Z");
    await rec(a, uid, "glm-5.3-flash", 400, 40, "2026-10-18T20:05:00.000Z");
    // Run B: 2026-10-15 09:00Z.
    await rec(b, uid, "auto", 50, 5, "2026-10-15T09:00:00.000Z");
    // 40 days ago: outside the default 30-day window.
    await rec(b, uid, "auto", 7777, 777, "2026-09-09T09:00:00.000Z");
    // Another user's usage in range: never visible.
    await rec(o, other, "auto", 99999, 9999, "2026-10-18T20:00:00.000Z");
  }, 60_000);

  afterAll(async () => {
    await app?.close();
    await closeDb(db);
  });

  async function get(query: string, who = uid) {
    return app.inject({
      method: "GET",
      url: `/cloud/v1/usage/history${query}`,
      headers: authHeaders(who),
    });
  }

  it("requires authentication", async () => {
    const res = await app.inject({ method: "GET", url: "/cloud/v1/usage/history" });
    expect(res.statusCode).toBe(401);
  });

  it("defaults: 30 UTC days, zero-filled newest first, totals/models/sessions/runs for the caller only", async () => {
    const res = await get("");
    expect(res.statusCode).toBe(200);
    expect(res.headers["cache-control"]).toBe("no-store");
    const body = res.json();
    expect(body.utcOffsetMinutes).toBe(0);
    expect(body.until).toBe(NOW.toISOString());
    expect(body.since).toBe("2026-09-20T00:00:00.000Z");
    expect(body.totals).toEqual({
      runs: 2,
      modelCalls: 3,
      inputTokens: 1450,
      outputTokens: 145,
      cacheReadTokens: 30,
      cacheWriteTokens: 3,
    });
    expect(body.days).toHaveLength(30);
    expect(body.days[0].date).toBe("2026-10-19");
    expect(body.days[29].date).toBe("2026-09-20");
    expect(body.days[0]).toEqual({
      date: "2026-10-19",
      runs: 0,
      modelCalls: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
    });
    expect(body.days[1]).toMatchObject({ date: "2026-10-18", runs: 1, modelCalls: 2, inputTokens: 1400 });
    expect(body.days[4]).toMatchObject({ date: "2026-10-15", runs: 1, modelCalls: 1, inputTokens: 50 });
    expect(body.models.map((m: { model: string }) => m.model)).toEqual(["auto", "glm-5.3-flash"]);
    expect(body.models[0]).toEqual({
      model: "auto",
      runs: 2,
      modelCalls: 2,
      inputTokens: 1050,
      outputTokens: 105,
      cacheReadTokens: 20,
      cacheWriteTokens: 2,
    });
    expect(body.sessions).toEqual([
      {
        sessionId: ids.sessions[0],
        title: "Alpha",
        runs: 1,
        modelCalls: 2,
        inputTokens: 1400,
        outputTokens: 140,
        cacheReadTokens: 20,
        cacheWriteTokens: 2,
        lastAt: "2026-10-18T20:05:00.000Z",
      },
      {
        sessionId: ids.sessions[1],
        title: "Beta",
        runs: 1,
        modelCalls: 1,
        inputTokens: 50,
        outputTokens: 5,
        cacheReadTokens: 10,
        cacheWriteTokens: 1,
        lastAt: "2026-10-15T09:00:00.000Z",
      },
    ]);
    expect(body.runs).toHaveLength(2);
    expect(body.runs[0]).toEqual({
      runId: ids.runs[1],
      sessionId: ids.sessions[1],
      sessionTitle: "Beta",
      status: "queued",
      startedAt: null,
      finishedAt: null,
      models: ["auto"],
      modelCalls: 1,
      inputTokens: 50,
      outputTokens: 5,
      cacheReadTokens: 10,
      cacheWriteTokens: 1,
    });
    expect(body.runs[1]).toMatchObject({ runId: ids.runs[0], models: ["auto", "glm-5.3-flash"] });
    expect(body.nextBefore).toBeNull();
    expect(JSON.stringify(body)).not.toContain("Theirs");
  });

  it("utcOffsetMinutes shifts the day buckets and the window start (IST +330)", async () => {
    const res = await get("?days=7&utcOffsetMinutes=330");
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.utcOffsetMinutes).toBe(330);
    // Local today is 2026-10-19; 7 local days start 2026-10-13 00:00 IST.
    expect(body.since).toBe("2026-10-12T18:30:00.000Z");
    expect(body.days.map((d: { date: string }) => d.date)).toEqual([
      "2026-10-19", "2026-10-18", "2026-10-17", "2026-10-16", "2026-10-15", "2026-10-14", "2026-10-13",
    ]);
    // Run A's calls (20:00Z/20:05Z on the 18th) are on the 19th in IST.
    expect(body.days[0]).toMatchObject({ runs: 1, modelCalls: 2, inputTokens: 1400 });
    expect(body.days[1]).toMatchObject({ runs: 0, modelCalls: 0 });
  });

  it("days is clamped to 1..90; the 90-day window includes older usage", async () => {
    const wide = (await get("?days=500")).json();
    expect(wide.days).toHaveLength(90);
    expect(wide.totals.inputTokens).toBe(1450 + 7777);
    const one = (await get("?days=1")).json();
    expect(one.days).toHaveLength(1);
    expect(one.since).toBe("2026-10-19T00:00:00.000Z");
  });

  it("runs pagination: limit + opaque nextBefore cursor", async () => {
    const page1 = (await get("?limit=1")).json();
    expect(page1.runs.map((r: { runId: string }) => r.runId)).toEqual([ids.runs[1]]);
    expect(typeof page1.nextBefore).toBe("string");
    const page2 = (await get(`?limit=1&before=${encodeURIComponent(page1.nextBefore)}`)).json();
    expect(page2.runs.map((r: { runId: string }) => r.runId)).toEqual([ids.runs[0]]);
    expect(page2.nextBefore).toBeNull();
    // Aggregates are unaffected by the runs cursor.
    expect(page2.totals.runs).toBe(2);
  });

  it("rejects a bad utcOffsetMinutes or cursor with the 400 envelope", async () => {
    for (const q of ["?utcOffsetMinutes=900", "?utcOffsetMinutes=abc", "?utcOffsetMinutes=1.5", "?before=garbage"]) {
      const res = await get(q);
      expect(res.statusCode, q).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
  });

  it("another user sees only their own usage", async () => {
    const body = (await get("", other)).json();
    expect(body.totals).toMatchObject({ runs: 1, inputTokens: 99999 });
    expect(body.sessions.map((s: { title: string }) => s.title)).toEqual(["Theirs"]);
  });
});
