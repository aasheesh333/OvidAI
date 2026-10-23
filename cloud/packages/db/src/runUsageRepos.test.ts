import { afterAll, beforeAll, describe, expect, it } from "vitest";
import postgres from "postgres";
import { createDb, migrate, type Db } from "./client.js";
import { messages, newId, runs, sessions, users as usersRepo } from "./repos.js";
import { runUsage } from "./runUsageRepos.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

/**
 * Wave 3: the per-model-call token ledger (run_usage) + the aggregates behind
 * GET /cloud/v1/usage/history. Real Postgres, same drop/recreate discipline
 * as repos.test.ts.
 */
describe.skipIf(!TEST_DATABASE_URL)("runUsage repo against real postgres", () => {
  let db: Db;

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    const admin = postgres(url, { max: 1, onnotice: () => {} });
    try {
      await admin.unsafe(`DROP SCHEMA IF EXISTS drizzle CASCADE`);
      await admin.unsafe(`DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE`);
      await admin.unsafe(
        `DROP TABLE IF EXISTS browser_credentials, studio_repos, private_memory_files, schedules, schedule_runs, devices, notifications, grants, file_manifests, workspace_objects, attachments, session_event_mirror, session_agent_state, runs, messages, sessions, users,` +
          ` plans, mint_settings, user_plan_overrides, mint_audit, billing_purchases, image_jobs,` +
          ` image_deleted_accounts, image_cards, image_card_history, image_probe_log, image_probe_state,` +
          ` shares, share_forks, reports, account_deletions, byok_keys,` +
          ` mcp_servers, mcp_oauth_tokens, mcp_oauth_flows, plugins, plugin_grants, run_usage,` +
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
    await usersRepo.ensure(db, uid, null);
    return uid;
  }

  async function seedRun(uid: string, title: string | null) {
    const session = await sessions.create(db, uid, title ?? undefined);
    const prompt = await messages.append(db, { sessionId: session.id, role: "user", content: "hi" });
    const run = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
    return { session, run };
  }

  const at = (iso: string) => new Date(iso);

  it("record stores one row with defaults for missing cache counts", async () => {
    const uid = await seedUser();
    const { session, run } = await seedRun(uid, "Rec");
    const row = await runUsage.record(db, {
      userId: uid,
      sessionId: session.id,
      runId: run.id,
      model: "auto",
      inputTokens: 120,
      outputTokens: 30,
    });
    expect(row.id).toMatch(/^[0-9a-f-]{36}$/);
    expect(row).toMatchObject({
      userId: uid,
      sessionId: session.id,
      runId: run.id,
      model: "auto",
      inputTokens: 120,
      outputTokens: 30,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
    });
    expect(row.createdAt).toBeInstanceOf(Date);
  });

  it("record clamps negative / fractional / non-finite counts to safe integers", async () => {
    const uid = await seedUser();
    const { session, run } = await seedRun(uid, null);
    const row = await runUsage.record(db, {
      userId: uid,
      sessionId: session.id,
      runId: run.id,
      model: "m",
      inputTokens: -5,
      outputTokens: 10.7,
      cacheReadTokens: Number.NaN,
      cacheWriteTokens: 3,
    });
    expect([row.inputTokens, row.outputTokens, row.cacheReadTokens, row.cacheWriteTokens]).toEqual([
      0, 10, 0, 3,
    ]);
  });

  describe("aggregates", () => {
    let uid: string;
    let other: string;
    let a: Awaited<ReturnType<typeof seedRun>>;
    let b: Awaited<ReturnType<typeof seedRun>>;
    let c: Awaited<ReturnType<typeof seedRun>>;
    const since = at("2026-10-10T00:00:00.000Z");
    const until = at("2026-10-20T00:00:00.000Z");

    beforeAll(async () => {
      uid = await seedUser();
      other = await seedUser();
      a = await seedRun(uid, "Alpha");
      b = await seedRun(uid, "Beta");
      c = await seedRun(uid, "Gone");
      await sessions.softDelete(db, c.session.id, uid);
      const rec = (
        run: Awaited<ReturnType<typeof seedRun>>,
        model: string,
        input: number,
        output: number,
        createdAt: string,
        cache: [number, number] = [0, 0],
        user = uid,
      ) =>
        runUsage.record(db, {
          userId: user,
          sessionId: run.session.id,
          runId: run.run.id,
          model,
          inputTokens: input,
          outputTokens: output,
          cacheReadTokens: cache[0],
          cacheWriteTokens: cache[1],
          createdAt: at(createdAt),
        });
      // Run A: two calls (auto, then glm) on 2026-10-18 UTC late evening —
      // which is 2026-10-19 in IST (+330).
      await rec(a, "auto", 1000, 100, "2026-10-18T20:00:00.000Z", [400, 50]);
      await rec(a, "glm-5.3-flash", 500, 50, "2026-10-18T20:01:00.000Z");
      // Run B: one call on 2026-10-17.
      await rec(b, "auto", 3000, 300, "2026-10-17T10:00:00.000Z");
      // Run C (deleted session): counted, title hidden.
      await rec(c, "minimax-m3", 10, 1, "2026-10-16T10:00:00.000Z");
      // Out of window, and another user's data: never counted.
      await rec(a, "auto", 99999, 9999, "2026-10-01T10:00:00.000Z");
      await rec(a, "auto", 77777, 7777, "2026-10-18T10:00:00.000Z", [0, 0], other);
    });

    it("totals: runs = distinct runs, model_calls = rows, token sums; only the caller, only the window", async () => {
      expect(await runUsage.totals(db, { userId: uid, since, until })).toEqual({
        runs: 3,
        modelCalls: 4,
        inputTokens: 4510,
        outputTokens: 451,
        cacheReadTokens: 400,
        cacheWriteTokens: 50,
      });
      expect(
        await runUsage.totals(db, { userId: uid, since: at("2030-01-01T00:00:00Z"), until: at("2030-01-02T00:00:00Z") }),
      ).toEqual({
        runs: 0,
        modelCalls: 0,
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
      });
    });

    it("byDay buckets by the client's UTC offset (newest first) and validates it", async () => {
      const utc = await runUsage.byDay(db, { userId: uid, since, until, utcOffsetMinutes: 0 });
      expect(utc.map((d) => [d.date, d.runs, d.modelCalls, d.inputTokens])).toEqual([
        ["2026-10-18", 1, 2, 1500],
        ["2026-10-17", 1, 1, 3000],
        ["2026-10-16", 1, 1, 10],
      ]);
      const ist = await runUsage.byDay(db, { userId: uid, since, until, utcOffsetMinutes: 330 });
      expect(ist.map((d) => d.date)).toEqual(["2026-10-19", "2026-10-17", "2026-10-16"]);
      expect(ist[0]).toMatchObject({ cacheReadTokens: 400, cacheWriteTokens: 50, outputTokens: 150 });
      await expect(
        runUsage.byDay(db, { userId: uid, since, until, utcOffsetMinutes: 841 }),
      ).rejects.toThrow(RangeError);
      await expect(
        runUsage.byDay(db, { userId: uid, since, until, utcOffsetMinutes: 1.5 }),
      ).rejects.toThrow(RangeError);
    });

    it("byModel sorts by total tokens desc", async () => {
      const models = await runUsage.byModel(db, { userId: uid, since, until });
      expect(models.map((m) => [m.model, m.runs, m.modelCalls, m.inputTokens, m.outputTokens])).toEqual([
        ["auto", 2, 2, 4000, 400],
        ["glm-5.3-flash", 1, 1, 500, 50],
        ["minimax-m3", 1, 1, 10, 1],
      ]);
    });

    it("bySession joins titles, hides deleted sessions' titles but still counts them", async () => {
      const rows = await runUsage.bySession(db, { userId: uid, since, until });
      expect(rows.map((s) => [s.sessionId, s.title, s.runs, s.modelCalls, s.inputTokens, s.outputTokens])).toEqual([
        [b.session.id, "Beta", 1, 1, 3000, 300],
        [a.session.id, "Alpha", 1, 2, 1500, 150],
        [c.session.id, null, 1, 1, 10, 1],
      ]);
      expect(rows[1]!.lastAt.toISOString()).toBe("2026-10-18T20:01:00.000Z");
      expect(await runUsage.bySession(db, { userId: uid, since, until, limit: 1 })).toHaveLength(1);
    });

    it("recentRuns: newest run first, run status/timestamps, distinct models, keyset cursor", async () => {
      await runs.claimNext(db, a.run.id);
      const page1 = await runUsage.recentRuns(db, { userId: uid, since, until, limit: 2 });
      expect(page1.rows.map((r) => r.runId)).toEqual([c.run.id, b.run.id]);
      expect(page1.next).not.toBeNull();
      const page2 = await runUsage.recentRuns(db, {
        userId: uid,
        since,
        until,
        limit: 2,
        before: page1.next!,
      });
      expect(page2.rows.map((r) => r.runId)).toEqual([a.run.id]);
      expect(page2.next).toBeNull();
      const runA = page2.rows[0]!;
      expect(runA).toMatchObject({
        sessionId: a.session.id,
        sessionTitle: "Alpha",
        status: "running",
        models: ["auto", "glm-5.3-flash"],
        modelCalls: 2,
        inputTokens: 1500,
        outputTokens: 150,
        cacheReadTokens: 400,
        cacheWriteTokens: 50,
      });
      expect(runA.startedAt).toBeInstanceOf(Date);
      expect(runA.finishedAt).toBeNull();
      expect(page1.rows[0]!.sessionTitle).toBeNull(); // deleted session
    });

    it("recentRuns limit defaults to 50 and is capped at 200", async () => {
      const all = await runUsage.recentRuns(db, { userId: uid, since, until });
      expect(all.rows).toHaveLength(3);
      const capped = await runUsage.recentRuns(db, { userId: uid, since, until, limit: 10_000 });
      expect(capped.rows).toHaveLength(3);
      expect(runUsage.clampLimit(undefined)).toBe(50);
      expect(runUsage.clampLimit(10_000)).toBe(200);
      expect(runUsage.clampLimit(0)).toBe(1);
    });
  });
});
