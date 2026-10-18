import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { eq, inArray, sql } from "drizzle-orm";
import postgres from "postgres";
import type { SessionEvent } from "@ovid/shared";
import { createDb, migrate, type Db } from "./client.js";
import { eventMirror, messages, newId, runs, sessions, users as usersRepo } from "./repos.js";
import {
  runs as runsTable,
  sessions as sessionsTable,
  users,
} from "./schema.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

// Fixed base (2023-11-14T22:13:20Z) for pinned updatedAt values so list-order
// assertions never depend on wall-clock ties.
const BASE = 1_700_000_000_000;

const UUIDV7_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

describe.skipIf(!TEST_DATABASE_URL)("repos against real postgres", () => {
  let db: Db;

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    // onnotice: swallow server NOTICEs ("table … does not exist, skipping") on fresh DBs
    const admin = postgres(url, { max: 1, onnotice: () => {} });
    try {
      // Drop the drizzle journal schema too, so migrate() re-applies the
      // generated SQL from scratch on every run (idempotent across runs).
      await admin.unsafe(`DROP SCHEMA IF EXISTS drizzle CASCADE`);
      // The sandbox-uid pool sequence (migration 0001) is NOT owned by the
      // users table, so DROP TABLE users leaves it behind — drop it too, or
      // the re-applied migration's CREATE SEQUENCE would collide with it.
      await admin.unsafe(`DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE`);
      // Every table any migration creates (P8-T3 rerunnability invariant) —
      // includes the P9 Task 2 money & accounts tables.
      await admin.unsafe(
        `DROP TABLE IF EXISTS schedules, schedule_runs, devices, notifications, grants, file_manifests, workspace_objects, attachments, session_event_mirror, session_agent_state, runs, messages, sessions, users,` +
          ` plans, mint_settings, user_plan_overrides, mint_audit, billing_purchases, image_jobs,` +
          ` image_deleted_accounts, image_cards, image_card_history, image_probe_log, image_probe_state,` +
          ` shares, share_forks, reports, account_deletions, byok_keys,` +
          ` mcp_servers, mcp_oauth_tokens, mcp_oauth_flows, plugins, plugin_grants CASCADE`,
      );
    } finally {
      await admin.end({ timeout: 5 });
    }
    await migrate(url);
    db = createDb(url);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function seedUser(): Promise<string> {
    const uid = newId();
    await db.insert(users).values({ uid, email: `u-${uid.slice(0, 8)}@test.local` });
    return uid;
  }

  it("sessions.create/get roundtrip; wrong owner → null (404 rule)", async () => {
    const uid = await seedUser();
    const [userRow] = await db.select().from(users).where(eq(users.uid, uid));
    expect(userRow!.tier).toBe("free"); // column default
    expect(userRow!.bannedAt).toBeNull();

    const s = await sessions.create(db, uid, "hello");
    expect(s.id).toMatch(UUIDV7_RE);
    expect(s.userId).toBe(uid);
    expect(s.title).toBe("hello");
    expect(s.mode).toBe("auto"); // column default
    expect(s.archivedAt).toBeNull();
    expect(s.createdAt).toBeInstanceOf(Date);
    expect(s.updatedAt).toBeInstanceOf(Date);

    const got = await sessions.get(db, s.id, uid);
    expect(got).toEqual(s);

    const stranger = await seedUser();
    expect(await sessions.get(db, s.id, stranger)).toBeNull();
    expect(await sessions.get(db, newId(), uid)).toBeNull();

    const untitled = await sessions.create(db, uid);
    expect(untitled.title).toBeNull();
    const explicitNull = await sessions.create(db, uid, null);
    expect(explicitNull.title).toBeNull();
  });

  it("sessions.list walks 3 pages of 2 via cursor, most recent activity first", async () => {
    const uid = await seedUser();
    const other = await seedUser();
    await sessions.create(db, other, "not mine"); // must never leak into uid's pages

    const created = [];
    for (let i = 0; i < 5; i++) {
      created.push(await sessions.create(db, uid, `s${i}`));
    }
    // Pin activity order s0 (oldest) … s4 (newest) so the expected page order
    // is exact regardless of insert timing.
    for (let i = 0; i < created.length; i++) {
      await db
        .update(sessionsTable)
        .set({ updatedAt: new Date(BASE + i * 1000) })
        .where(eq(sessionsTable.id, created[i]!.id));
    }

    const seen: string[] = [];
    const pageSizes: number[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < 10; page++) {
      const res = await sessions.list(db, uid, 2, cursor);
      pageSizes.push(res.rows.length);
      seen.push(...res.rows.map((r) => r.id));
      cursor = res.nextCursor;
      if (!cursor) break;
    }
    expect(pageSizes).toEqual([2, 2, 1]);
    expect(seen).toEqual([...created].reverse().map((s) => s!.id));

    // Omitted cursor behaves like null (first page).
    const first = await sessions.list(db, uid, 2);
    expect(first.rows.map((r) => r.id)).toEqual([created[4]!.id, created[3]!.id]);
    expect(first.nextCursor).toBeTruthy();

    // Crafted/garbage cursors degrade leniently to the first page — never throw.
    // Covers integer-but-Invalid-Date ms (1e20, Date-max±1) AND valid JS Dates
    // that Postgres cannot bind (years outside 0001–9999 → PG parser error).
    for (const bad of [
      "99999999999999999999~x", // Number.isInteger(1e20) === true, Date → Invalid
      "8640000000000001~x", // Date max + 1 → Invalid Date
      "-8640000000000001~x", // Date min - 1 → Invalid Date
      "8640000000000000~x", // Date max, valid JS Date but year 275760 → PG rejects
      "253402300800000~x", // year 10000 → PG rejects expanded-year format
      "-62167219200000~x", // year 0 → PG rejects
      "NaN~x",
      "1.5~x",
      "garbage",
      "~x",
      `${BASE}~`, // empty id part
    ]) {
      const res = await sessions.list(db, uid, 2, bad);
      expect(res.rows.map((r) => r.id), `cursor ${JSON.stringify(bad)}`).toEqual([
        created[4]!.id,
        created[3]!.id,
      ]);
    }
    // Well-formed cursors at the accepted bounds bind without throwing.
    const upperEdge = await sessions.list(db, uid, 2, "253402300799999~ffffffff-ffff-7fff-bfff-ffffffffffff");
    expect(upperEdge.rows.map((r) => r.id)).toEqual([created[4]!.id, created[3]!.id]); // all 2023 sessions sort before year 9999
    const lowerEdge = await sessions.list(db, uid, 2, "-62135596800000~00000000-0000-7000-8000-000000000000");
    expect(lowerEdge).toEqual({ rows: [], nextCursor: null }); // nothing sorts before year 1
  });

  it("sessions.touch bumps updatedAt and moves the session to the front", async () => {
    const uid = await seedUser();
    const a = await sessions.create(db, uid, "a");
    const b = await sessions.create(db, uid, "b");
    await db.update(sessionsTable).set({ updatedAt: new Date(BASE) }).where(eq(sessionsTable.id, a.id));
    await db.update(sessionsTable).set({ updatedAt: new Date(BASE + 1000) }).where(eq(sessionsTable.id, b.id));

    expect((await sessions.list(db, uid, 10)).rows.map((r) => r.id)).toEqual([b.id, a.id]);

    await sessions.touch(db, a.id);

    expect((await sessions.list(db, uid, 10)).rows.map((r) => r.id)).toEqual([a.id, b.id]);
    const touched = await sessions.get(db, a.id, uid);
    expect(touched!.updatedAt.getTime()).toBeGreaterThan(BASE + 1000);
  });

  it("messages.append + page newest-first with beforeId keyset", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "msgs");
    const other = await sessions.create(db, uid, "other session");
    await messages.append(db, { sessionId: other.id, role: "user", content: "elsewhere" });

    const ms = [];
    for (let i = 0; i < 5; i++) {
      ms.push(
        await messages.append(db, {
          sessionId: s.id,
          role: i % 2 === 0 ? "user" : "assistant",
          content: `m${i}`,
        }),
      );
    }
    expect(ms[0]!.id).toMatch(UUIDV7_RE);
    expect(ms[0]!.sessionId).toBe(s.id);
    expect(ms[0]!.role).toBe("user");
    expect(ms[1]!.role).toBe("assistant");
    expect(ms[0]!.content).toBe("m0");
    expect(ms[0]!.createdAt).toBeInstanceOf(Date);

    const p1 = await messages.page(db, s.id, { limit: 2 });
    expect(p1.rows.map((m) => m.id)).toEqual([ms[4]!.id, ms[3]!.id]); // newest-first
    expect(p1.nextCursor).toBe(ms[3]!.id);

    const p2 = await messages.page(db, s.id, { limit: 2, beforeId: p1.nextCursor });
    expect(p2.rows.map((m) => m.id)).toEqual([ms[2]!.id, ms[1]!.id]);
    expect(p2.nextCursor).toBe(ms[1]!.id);

    const p3 = await messages.page(db, s.id, { limit: 2, beforeId: p2.nextCursor });
    expect(p3.rows.map((m) => m.id)).toEqual([ms[0]!.id]); // "elsewhere" never appears
    expect(p3.nextCursor).toBeNull(); // last page

    const empty = await sessions.create(db, uid, "empty");
    expect(await messages.page(db, empty.id, { limit: 10 })).toEqual({ rows: [], nextCursor: null });
  });

  it("messages.append with clientMsgId + findByClientMsgId: per-session key, run-less conflict rows, unique index enforces it", async () => {
    const uid = await seedUser();
    const a = await sessions.create(db, uid, "a");
    const b = await sessions.create(db, uid, "b");

    const m = await messages.append(db, {
      sessionId: a.id,
      role: "user",
      content: "hello",
      clientMsgId: "c-1",
    });
    expect(m.clientMsgId).toBe("c-1");

    // Found by (sessionId, clientMsgId)…
    expect(await messages.findByClientMsgId(db, a.id, "c-1")).toMatchObject({ id: m.id });
    // …but NOT from another session, and unknown ids → null (per-session key).
    expect(await messages.findByClientMsgId(db, b.id, "c-1")).toBeNull();
    expect(await messages.findByClientMsgId(db, a.id, "c-missing")).toBeNull();

    // Messages WITHOUT clientMsgId never collide (partial index).
    await messages.append(db, { sessionId: a.id, role: "user", content: "no key 1" });
    await messages.append(db, { sessionId: a.id, role: "user", content: "no key 2" });
    expect((await messages.page(db, a.id, { limit: 10 })).rows).toHaveLength(3);

    // The partial unique index is the real guard: a same-(session, id) append
    // raises 23505 (drizzle wraps the driver error; walk .cause).
    let violated: unknown = null;
    try {
      await messages.append(db, { sessionId: a.id, role: "user", content: "dupe", clientMsgId: "c-1" });
    } catch (err) {
      violated = err;
    }
    expect(violated).not.toBeNull();
    let e: unknown = violated;
    let code: unknown = null;
    for (let depth = 0; e instanceof Error && depth < 5; depth++) {
      code = (e as { code?: unknown }).code ?? code;
      e = (e as { cause?: unknown }).cause;
    }
    expect(code).toBe("23505");
  });

  it("messages.importBulk: single-statement insert, ON CONFLICT skips duplicates (imported vs skipped counts), client createdAt fidelity", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "import");
    const rows = [
      { clientMsgId: "i-1", role: "user" as const, content: "q", createdAt: new Date("2025-01-02T03:04:05.678Z") },
      { clientMsgId: "i-2", role: "assistant" as const, content: "a", createdAt: new Date("2025-01-02T03:04:09.000Z") },
      { clientMsgId: "i-3", role: "user" as const, content: "t", createdAt: new Date("2025-01-02T03:05:00.123Z") },
    ];

    const first = await messages.importBulk(db, s.id, rows);
    expect(first).toEqual({ imported: 3, skipped: 0 });

    // Timestamp fidelity: stored createdAt values are the client's, verbatim.
    const page = await messages.page(db, s.id, { limit: 10 });
    const byContent = new Map(page.rows.map((m) => [m.content, m]));
    expect(byContent.get("q")!.createdAt.toISOString()).toBe("2025-01-02T03:04:05.678Z");
    expect(byContent.get("a")!.createdAt.toISOString()).toBe("2025-01-02T03:04:09.000Z");
    expect(byContent.get("t")!.clientMsgId).toBe("i-3");

    // Exact re-send: everything conflicts → skipped, nothing duplicated.
    const again = await messages.importBulk(db, s.id, rows);
    expect(again).toEqual({ imported: 0, skipped: 3 });
    expect((await messages.page(db, s.id, { limit: 10 })).rows).toHaveLength(3);

    // Mixed batch: only the new ids import.
    const mixed = await messages.importBulk(db, s.id, [
      rows[0]!,
      { clientMsgId: "i-4", role: "user" as const, content: "new", createdAt: new Date("2025-01-02T03:06:00.000Z") },
      rows[1]!,
    ]);
    expect(mixed).toEqual({ imported: 1, skipped: 2 });
    expect((await messages.page(db, s.id, { limit: 10 })).rows).toHaveLength(4);

    // The same clientMsgIds under a DIFFERENT session import cleanly (per-session key).
    const other = await sessions.create(db, uid, "import 2");
    expect(await messages.importBulk(db, other.id, rows)).toEqual({ imported: 3, skipped: 0 });
  });

  it("runs: create → activeForSession → claimNext race → finish clears active", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "run session");
    const m = await messages.append(db, { sessionId: s.id, role: "user", content: "go" });

    const run = await runs.create(db, { sessionId: s.id, promptMessageId: m.id });
    expect(run.id).toMatch(UUIDV7_RE);
    expect(run.status).toBe("queued");
    expect(run.attempts).toBe(0);
    expect(run.promptMessageId).toBe(m.id);
    expect(run.startedAt).toBeNull();
    expect(run.finishedAt).toBeNull();

    const active = await runs.activeForSession(db, s.id);
    expect(active?.id).toBe(run.id);

    expect(await runs.bumpAttempt(db, run.id)).toBe(1);
    expect(await runs.bumpAttempt(db, run.id)).toBe(2);
    expect((await runs.activeForSession(db, s.id))?.attempts).toBe(2);

    // Sequential double-claim: first wins, second loses.
    expect(await runs.claimNext(db, run.id)).toBe(true);
    expect(await runs.claimNext(db, run.id)).toBe(false);
    const claimed = await runs.activeForSession(db, s.id);
    expect(claimed?.status).toBe("running");
    expect(claimed?.startedAt).toBeInstanceOf(Date);

    // Concurrent claimants: exactly one wins.
    const run2 = await runs.create(db, { sessionId: s.id, promptMessageId: m.id });
    const outcomes = await Promise.all([
      runs.claimNext(db, run2.id),
      runs.claimNext(db, run2.id),
      runs.claimNext(db, run2.id),
    ]);
    expect(outcomes.filter((won) => won).length).toBe(1);

    expect(await runs.claimNext(db, newId())).toBe(false); // unknown id

    await runs.finish(db, run.id, "failed", "boom");
    await runs.finish(db, run2.id, "completed");
    expect(await runs.activeForSession(db, s.id)).toBeNull(); // finish clears active

    const [r1] = await db.select().from(runsTable).where(eq(runsTable.id, run.id));
    expect(r1!.status).toBe("failed");
    expect(r1!.lastError).toBe("boom");
    expect(r1!.finishedAt).toBeInstanceOf(Date);
    const [r2] = await db.select().from(runsTable).where(eq(runsTable.id, run2.id));
    expect(r2!.status).toBe("completed");
    expect(r2!.lastError).toBeNull();
  });

  it("runs.finish is conditional: a late finish on an already-terminal run is a no-op (returns false, keeps the first terminal state)", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "terminal guard");
    const m = await messages.append(db, { sessionId: s.id, role: "user", content: "go" });
    const run = await runs.create(db, { sessionId: s.id, promptMessageId: m.id });
    expect(await runs.claimNext(db, run.id)).toBe(true);

    // The processor's terminal transition wins first.
    expect(await runs.finish(db, run.id, "completed")).toBe(true);
    const [after] = await db.select().from(runsTable).where(eq(runsTable.id, run.id));
    expect(after!.status).toBe("completed");
    expect(after!.finishedAt).toBeInstanceOf(Date);

    // The stale-run sweeper racing in late must NOT overwrite the verdict:
    // false, and status/lastError/finishedAt all keep the processor's values.
    expect(await runs.finish(db, run.id, "failed", "run_lost: stale sweep")).toBe(false);
    const [kept] = await db.select().from(runsTable).where(eq(runsTable.id, run.id));
    expect(kept!.status).toBe("completed");
    expect(kept!.lastError).toBeNull();
    expect(kept!.finishedAt).toEqual(after!.finishedAt);

    // Also from 'queued': the queue-wait timeout path terminalizes a queued
    // run (I4b + C1), but a run already terminalized by someone else refuses.
    const queued = await runs.create(db, { sessionId: s.id, promptMessageId: m.id });
    expect(await runs.finish(db, queued.id, "failed", "run_queue_wait_timeout")).toBe(true);
    expect(await runs.finish(db, queued.id, "cancelled")).toBe(false);
    const [q] = await db.select().from(runsTable).where(eq(runsTable.id, queued.id));
    expect(q!.status).toBe("failed");
    expect(q!.lastError).toBe("run_queue_wait_timeout");

    expect(await runs.finish(db, newId(), "failed", "unknown")).toBe(false); // unknown id
  });

  it("runs.listStaleRunning: only 'running' rows with startedAt older than the cutoff, oldest first", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "stale sweep");
    const m = await messages.append(db, { sessionId: s.id, role: "user", content: "go" });

    const stale = await runs.create(db, { sessionId: s.id, promptMessageId: m.id });
    const fresh = await runs.create(db, { sessionId: s.id, promptMessageId: m.id });
    const queued = await runs.create(db, { sessionId: s.id, promptMessageId: m.id });
    const finished = await runs.create(db, { sessionId: s.id, promptMessageId: m.id });
    expect(await runs.claimNext(db, stale.id)).toBe(true);
    expect(await runs.claimNext(db, fresh.id)).toBe(true);
    expect(await runs.claimNext(db, finished.id)).toBe(true);
    await runs.finish(db, finished.id, "completed");

    // Age the stale runner's started_at; make the QUEUED row ancient too
    // (createdAt must never matter — only status + startedAt do).
    await db.update(runsTable).set({ startedAt: new Date(BASE) }).where(eq(runsTable.id, stale.id));
    await db.update(runsTable).set({ createdAt: new Date(BASE) }).where(eq(runsTable.id, queued.id));

    // Cutoff an hour after the aged start but far before fresh's (now).
    const found = await runs.listStaleRunning(db, new Date(BASE + 3_600_000));
    expect(found.map((r) => r.id)).toEqual([stale.id]);

    // Cutoff = now → both running rows, oldest startedAt first.
    const both = await runs.listStaleRunning(db, new Date());
    expect(both.map((r) => r.id)).toEqual([stale.id, fresh.id]);

    // Cutoff before every startedAt → empty.
    expect(await runs.listStaleRunning(db, new Date(BASE - 1))).toEqual([]);

    // Leave NO running rows behind: the worker's staleRuns suite reads this
    // same dev Postgres later in the monorepo run, and a leftover 'running'
    // row with an aged started_at would be counted by its sweep.
    await runs.finish(db, stale.id, "failed", "test cleanup");
    await runs.finish(db, fresh.id, "failed", "test cleanup");
    expect(await runs.listStaleRunning(db, new Date())).toEqual([]);
  });

  it("eventMirror: put idempotent on (sessionId, seq); readSince numeric-seq order + exclusivity", async () => {
    const sessionId = newId();
    const ev = (seq: string, n: number): SessionEvent => ({
      sessionId,
      seq,
      type: "message_delta",
      payload: { n },
      ts: new Date(BASE + n).toISOString(),
    });
    // Redis-stream-id-shaped seqs. "999999999999-0" has fewer digits than the
    // others: numeric ordering puts it first, lexicographic would put it last.
    // "-5" vs "-10" pins numeric comparison of the sub-sequence too.
    const e1 = ev("999999999999-0", 1);
    const e2 = ev("1700000000000-0", 2);
    const e3 = ev("1700000000000-5", 3);
    const e4 = ev("1700000000000-10", 4);
    const e5 = ev("1700000000001-0", 5);
    for (const e of [e5, e1, e4, e2, e3]) {
      await eventMirror.put(db, e); // inserted out of order
    }

    // Idempotency: re-put with same (sessionId, seq) but different body keeps the first.
    await eventMirror.put(db, { ...e3, type: "run_failed", payload: { n: 999 } });

    const all = await eventMirror.readSince(db, sessionId, null, 100);
    expect(all.map((e) => e.seq)).toEqual([
      "999999999999-0",
      "1700000000000-0",
      "1700000000000-5",
      "1700000000000-10",
      "1700000000001-0",
    ]);
    expect(all).toEqual([e1, e2, e3, e4, e5]); // full envelope round-trip, incl. ts

    const after = await eventMirror.readSince(db, sessionId, "1700000000000-5", 100);
    expect(after.map((e) => e.seq)).toEqual(["1700000000000-10", "1700000000001-0"]);

    const afterLast = await eventMirror.readSince(db, sessionId, "1700000000001-0", 100);
    expect(afterLast).toEqual([]);

    const limited = await eventMirror.readSince(db, sessionId, null, 2);
    expect(limited.map((e) => e.seq)).toEqual(["999999999999-0", "1700000000000-0"]);

    // readBefore: STRICTLY before the boundary, ascending (prependable).
    const beforeSub = await eventMirror.readBefore(db, sessionId, "1700000000000-5", 100);
    expect(beforeSub.map((e) => e.seq)).toEqual(["999999999999-0", "1700000000000-0"]);

    // Boundary exclusivity + numeric sub-sequence comparison: -10 is AFTER -5,
    // so it must not appear in a page before -5.
    const beforeTen = await eventMirror.readBefore(db, sessionId, "1700000000000-10", 100);
    expect(beforeTen.map((e) => e.seq)).toEqual([
      "999999999999-0",
      "1700000000000-0",
      "1700000000000-5",
    ]);

    // A bound before the first event → empty; the first event itself excluded.
    expect(await eventMirror.readBefore(db, sessionId, "999999999999-0", 100)).toEqual([]);

    // Null bound → the NEWEST page, still ascending (DESC select then reverse).
    const newest = await eventMirror.readBefore(db, sessionId, null, 2);
    expect(newest.map((e) => e.seq)).toEqual(["1700000000000-10", "1700000000001-0"]);
    expect(newest).toEqual([e4, e5]);

    // A bounded page takes the rows NEAREST the boundary (not the oldest).
    const bounded = await eventMirror.readBefore(db, sessionId, "1700000000001-0", 2);
    expect(bounded.map((e) => e.seq)).toEqual(["1700000000000-5", "1700000000000-10"]);

    // Session isolation.
    expect(await eventMirror.readSince(db, newId(), null, 100)).toEqual([]);
    expect(await eventMirror.readBefore(db, newId(), null, 100)).toEqual([]);
    expect(await eventMirror.readBefore(db, newId(), "1700000000000-5", 100)).toEqual([]);
  });

  it("users.ensure: insert-new, idempotent re-ensure, null email never clobbers, tier never overwritten", async () => {
    const uid = newId();

    // Insert-new: row created with the given email and the column-default tier.
    const first = await usersRepo.ensure(db, uid, "first@test.local");
    expect(first.uid).toBe(uid);
    expect(first.email).toBe("first@test.local");
    expect(first.tier).toBe("free");
    expect(first.bannedAt).toBeNull();
    expect(first.createdAt).toBeInstanceOf(Date);

    // Re-ensure is idempotent: still exactly ONE row.
    const again = await usersRepo.ensure(db, uid, "first@test.local");
    expect(again.uid).toBe(uid);
    const counted = await db
      .select({ n: sql<number>`count(*)::int` })
      .from(users)
      .where(eq(users.uid, uid));
    expect(counted[0]!.n).toBe(1);

    // A new non-null email updates the stored one.
    const updated = await usersRepo.ensure(db, uid, "second@test.local");
    expect(updated.email).toBe("second@test.local");

    // email = null must NOT clobber the stored email (COALESCE ruling).
    const kept = await usersRepo.ensure(db, uid, null);
    expect(kept.email).toBe("second@test.local");

    // ensure never touches tier — an operator-set tier survives re-ensure.
    await db.update(users).set({ tier: "pro" }).where(eq(users.uid, uid));
    const afterTier = await usersRepo.ensure(db, uid, "third@test.local");
    expect(afterTier.tier).toBe("pro");
    expect(afterTier.email).toBe("third@test.local");
  });

  describe("users.allocateSandboxUid (sandbox uid pool)", () => {
    // This suite owns exactly these rows and this sequence state; afterAll
    // removes/resets them — never a shared truncate of other suites' data.
    const createdUids: string[] = [];
    const allocated: number[] = [];

    afterAll(async () => {
      if (!db) return;
      if (createdUids.length > 0) {
        await db.delete(users).where(inArray(users.uid, createdUids));
      }
      // Hand the pool back exactly as the migration created it:
      // is_called=false → the next nextval returns 200000 again.
      await db.execute(sql`SELECT setval('users_sandbox_uid_seq', 200000, false)`);
    });

    async function seedSandboxUser(): Promise<string> {
      const uid = newId();
      await usersRepo.ensure(db, uid, `sbx-${uid.slice(0, 8)}@test.local`);
      createdUids.push(uid);
      return uid;
    }

    it("idempotent: allocating twice for the same user returns the identical uid", async () => {
      const uid = await seedSandboxUser();
      const first = await usersRepo.allocateSandboxUid(db, uid);
      const second = await usersRepo.allocateSandboxUid(db, uid);
      expect(Number.isInteger(first)).toBe(true);
      expect(second).toBe(first);
      allocated.push(first);
    });

    it("two users → distinct uids; every allocated uid stays in the production pool [200000, 209999]", async () => {
      const a = await seedSandboxUser();
      const b = await seedSandboxUser();
      const ua = await usersRepo.allocateSandboxUid(db, a);
      const ub = await usersRepo.allocateSandboxUid(db, b);
      expect(ua).not.toBe(ub);
      allocated.push(ua, ub);
      for (const v of allocated) {
        expect(v, `allocated uid ${v}`).toBeGreaterThanOrEqual(200_000);
        expect(v, `allocated uid ${v}`).toBeLessThanOrEqual(209_999);
      }
    });

    it("pool exhaustion: setval to maxvalue → next allocation for a fresh user throws /pool exhausted/", async () => {
      // last_value=209999, is_called=true → the next nextval cannot advance.
      await db.execute(sql`SELECT setval('users_sandbox_uid_seq', 209999, true)`);
      const uid = await seedSandboxUser();
      await expect(usersRepo.allocateSandboxUid(db, uid)).rejects.toThrow(/pool exhausted/);
    });
  });
});
