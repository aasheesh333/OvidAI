import { afterAll, beforeAll, describe, expect, it } from "vitest";
import postgres from "postgres";
import { createDb, migrate, newId, sessions, type Db } from "./index.js";
import { messages, searchMessages, sessionState, users as usersRepo } from "./repos.js";
import { sessionAgentState, users } from "./schema.js";

/**
 * P3 Task 13 — messages FTS search (searchMessages) and the session_agent_state
 * repo (sessionState) against real Postgres. Ports session_search_test.dart's
 * literal/phrase/filter/limit cases onto the tsvector column, and pins the
 * Postgres get-vs-patch semantics (ruling in the task brief: get() on a missing
 * row returns the Task-1 zero state WITHOUT materializing a row; patch() is an
 * atomic jsonb upsert). Same drop/recreate discipline as repos.test.ts.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL)("searchMessages + sessionState against real postgres", () => {
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
      // users table, so DROP TABLE users leaves it behind — drop it too.
      await admin.unsafe(`DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE`);
      // Every table any migration creates (P8-T3 rerunnability invariant);
      // session_agent_state joins the list with this task's migration.
      await admin.unsafe(
        `DROP TABLE IF EXISTS browser_credentials, private_memory_files, schedules, schedule_runs, devices, notifications, grants, file_manifests, workspace_objects, attachments, session_event_mirror, runs, messages, sessions, users,` +
          ` plans, mint_settings, user_plan_overrides, mint_audit, billing_purchases, image_jobs,` +
          ` image_deleted_accounts, image_cards, image_card_history, image_probe_log, image_probe_state,` +
          ` shares, share_forks, reports, account_deletions, byok_keys,` +
          ` mcp_servers, mcp_oauth_tokens, mcp_oauth_flows, plugins, plugin_grants, session_agent_state, run_usage,` +
          ` private_memory_files, projects CASCADE`,
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

  async function seedSession(userId: string): Promise<string> {
    const row = await sessions.create(db, userId, null);
    return row.id;
  }

  async function seedMessage(sessionId: string, content: string, role: "user" | "assistant" = "user"): Promise<string> {
    const row = await messages.append(db, { sessionId, role, content });
    return row.id;
  }

  // Shared two-user seed: user A owns s1/s2, user B owns s3. Every session
  // holds one "needle" message; s1 additionally repeats the term so it must
  // outrank s2 under ts_rank_cd cover-density ordering. "aardvark" exists
  // ONLY in user A's s2 — the ownership probe term.
  async function seedTwoUsers(): Promise<{ a: string; b: string; s1: string; s2: string; s3: string }> {
    const a = await seedUser();
    const b = await seedUser();
    const s1 = await seedSession(a);
    const s2 = await seedSession(a);
    const s3 = await seedSession(b);
    await seedMessage(s1, "needle needle needle — the dense one");
    await seedMessage(s2, "a single needle here, plus aardvark", "assistant");
    await seedMessage(s3, "someone else's needle");
    return { a, b, s1, s2, s3 };
  }

  it("returns only the caller's rows, ranked by cover density, with snippets and total", async () => {
    const { a, s1, s2 } = await seedTwoUsers();
    const res = await searchMessages(db, a, "needle");
    expect(res.total).toBe(2);
    expect(res.rows).toHaveLength(2);
    expect(new Set(res.rows.map((r) => r.sessionId))).toEqual(new Set([s1, s2]));
    for (const row of res.rows) {
      expect(typeof row.messageId).toBe("string");
      expect(row.messageId).toMatch(/^[0-9a-f-]{36}$/);
      expect(["user", "assistant"]).toContain(row.role);
      expect(typeof row.rank).toBe("number");
      // ts_headline highlights the match with the Dart snippet markers.
      expect(row.snippet).toContain("→");
      expect(row.snippet).toContain("←");
    }
    // Dense repetitions rank first (ts_rank_cd DESC).
    expect(res.rows[0]!.sessionId).toBe(s1);
    expect(res.rows[0]!.rank).toBeGreaterThan(res.rows[1]!.rank);
    expect(res.rows[0]!.snippet).toContain("→needle←");
  });

  it("ownership: user B searching user A's text → zero rows, never an error", async () => {
    const { a, b, s2, s3 } = await seedTwoUsers();
    // "aardvark" lives only in user A's session — B must see nothing.
    const res = await searchMessages(db, b, "aardvark");
    expect(res).toEqual({ rows: [], total: 0 });
    // The mirror: A finds it; B's own "needle" stays B-visible only.
    const mine = await searchMessages(db, a, "aardvark");
    expect(mine.total).toBe(1);
    expect(mine.rows[0]!.sessionId).toBe(s2);
    const bNeedle = await searchMessages(db, b, "needle");
    expect(bNeedle.total).toBe(1);
    expect(bNeedle.rows[0]!.sessionId).toBe(s3);
  });

  it("bare terms AND (plainto), quoted phrases match the literal phrase (websearch)", async () => {
    const a = await seedUser();
    const s = await seedSession(a);
    await seedMessage(s, "the red fox jumps");
    await seedMessage(s, "the red quick fox");
    await seedMessage(s, "the blue fox");

    // Bare query: implicit AND — both words must appear.
    const both = await searchMessages(db, a, "red fox");
    expect(both.total).toBe(2);
    // Quoted phrase: literal adjacency, session_search.dart parity.
    const phrase = await searchMessages(db, a, '"red fox"');
    expect(phrase.total).toBe(1);
    expect(phrase.rows[0]!.sessionId).toBe(s);
    // A phrase that never occurs adjacently → zero rows.
    const none = await searchMessages(db, a, '"red blue"');
    expect(none).toEqual({ rows: [], total: 0 });
  });

  it("sessionId filter scopes the search to one session", async () => {
    const { a, s1, s2 } = await seedTwoUsers();
    const res = await searchMessages(db, a, "needle", { sessionId: s2 });
    expect(res.total).toBe(1);
    expect(res.rows).toHaveLength(1);
    expect(res.rows[0]!.sessionId).toBe(s2);
    // Unknown/foreign sessionId → zero rows, not an error.
    const empty = await searchMessages(db, a, "needle", { sessionId: newId() });
    expect(empty).toEqual({ rows: [], total: 0 });
    void s1;
  });

  it("limit clamps to 100; total stays the full count; offset pages", async () => {
    const a = await seedUser();
    const s = await seedSession(a);
    for (let i = 0; i < 105; i++) {
      await seedMessage(s, `needle occurrence number ${i}`);
    }
    const clamped = await searchMessages(db, a, "needle", { limit: 150 });
    expect(clamped.rows).toHaveLength(100); // maxLimit parity (Dart SessionSearch.maxLimit)
    expect(clamped.total).toBe(105);
    // Default limit 20 (Dart default).
    const def = await searchMessages(db, a, "needle");
    expect(def.rows).toHaveLength(20);
    // Offset skips the leading page.
    const page2 = await searchMessages(db, a, "needle", { limit: 100, offset: 100 });
    expect(page2.rows).toHaveLength(5);
    // offset beyond the end → empty, never an error.
    const past = await searchMessages(db, a, "needle", { offset: 10_000 });
    expect(past.rows).toHaveLength(0);
  });

  it("query is clamped to 4096 UTF-16 units and NUL bytes are stripped, never thrown", async () => {
    const a = await seedUser();
    const s = await seedSession(a);
    await seedMessage(s, "haystack needle inside word word word");
    // >4096 UTF-16 chars: the clamp keeps the head, which contains the term.
    const long = "needle " + "word ".repeat(2100);
    const res = await searchMessages(db, a, long);
    expect(res.total).toBe(1);
    expect(res.rows[0]!.sessionId).toBe(s);
    // NUL would break the driver binding — it is replaced, not an error.
    const withNul = await searchMessages(db, a, "needle\0");
    expect(withNul.total).toBe(1);
    // Empty / whitespace-only query → zero rows, no error.
    expect(await searchMessages(db, a, "")).toEqual({ rows: [], total: 0 });
    expect(await searchMessages(db, a, "   ")).toEqual({ rows: [], total: 0 });
  });

  // -- sessionState (Postgres get-vs-patch semantics) --------------------------

  it("get on a missing row returns the Task-1 zero state WITHOUT materializing a row", async () => {
    const uid = await seedUser();
    const s = await seedSession(uid);
    const state = await sessionState.get(db, s);
    expect(state).toEqual({
      todos: [],
      goal: null,
      presetId: null,
      planMode: false,
      planPreMode: null,
      pendingPlanMode: null,
      compaction: null,
      mode: "auto",
      modelPin: null,
      activeSkillScopes: [],
    });
    // THE documented divergence from T1's fake: get() is a pure read — no row
    // is written (the fake materializes-and-caches; Postgres never does).
    const rows = await db.select().from(sessionAgentState);
    expect(rows).toHaveLength(0);
  });

  it("patch is an atomic upsert; get round-trips; repeated patches merge shallowly", async () => {
    const uid = await seedUser();
    const s = await seedSession(uid);
    await sessionState.patch(db, s, { todos: [{ content: "first", status: "pending" }], mode: "drive" });
    let state = await sessionState.get(db, s);
    expect(state.todos).toEqual([{ content: "first", status: "pending" }]);
    expect(state.mode).toBe("drive");

    // Shallow merge: a second patch replaces the array field wholesale while
    // sibling fields survive (T1 fake parity — Object.assign semantics).
    await sessionState.patch(db, s, { todos: [{ content: "second", status: "in_progress" }] });
    state = await sessionState.get(db, s);
    expect(state.todos).toEqual([{ content: "second", status: "in_progress" }]);
    expect(state.mode).toBe("drive");

    // The whole SessionAgentState JSON is stored (goal + compaction shape).
    await sessionState.patch(db, s, {
      goal: { objective: "ship it", notes: "" },
      compaction: { ledger: { v: 1 }, summary: null, cutoffMessageId: null, compactedAtCount: 0 },
    });
    state = await sessionState.get(db, s);
    expect(state.goal).toEqual({ objective: "ship it", notes: "" });
    expect(state.compaction).toEqual({
      ledger: { v: 1 },
      summary: null,
      cutoffMessageId: null,
      compactedAtCount: 0,
    });

    // Per-session isolation.
    const s2 = await seedSession(uid);
    const other = await sessionState.get(db, s2);
    expect(other.todos).toEqual([]);
    expect(other.mode).toBe("auto");
  });

  it("patch on an unknown session raises the FK violation (loud, never silent)", async () => {
    const uid = await seedUser();
    void uid;
    await expect(sessionState.patch(db, newId(), { mode: "safe" })).rejects.toThrow();
  });

  it("users.ensure/tier sanity for the seed path used above", async () => {
    const uid = newId();
    const row = await usersRepo.ensure(db, uid, null);
    expect(row.uid).toBe(uid);
    expect(row.tier).toBe("free");
  });
});
