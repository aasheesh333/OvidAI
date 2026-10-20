import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import postgres from "postgres";
import { createDb, migrate, type Db } from "./client.js";
import { newId, runs, sessions, users as usersRepo } from "./repos.js";
import { scheduleRuns as scheduleRunsTable, schedules as schedulesTable } from "./schema.js";
import { scheduleRuns, schedules } from "./scheduleRepos.js";
import type { ScheduleRow, ScheduleRunRow, SessionRow } from "./schema.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

// Fixed instants (ms precision) so assertions never depend on the wall clock.
const NOW = new Date("2026-10-17T12:00:00.000Z");
const DUE = new Date("2026-10-17T11:59:00.000Z");
const LATER = new Date("2026-10-17T13:00:00.000Z");

describe.skipIf(!TEST_DATABASE_URL)("schedule repos against real postgres", () => {
  let db: Db;

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    // Same drop/recreate discipline as repos.test.ts / moneyRepos.test.ts
    // (P8-T3 rerunnability invariant).
    const admin = postgres(url, { max: 1, onnotice: () => {} });
    try {
      await admin.unsafe(`DROP SCHEMA IF EXISTS drizzle CASCADE`);
      await admin.unsafe(`DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE`);
      await admin.unsafe(
        `DROP TABLE IF EXISTS browser_credentials, private_memory_files, schedules, schedule_runs, devices, notifications, grants, file_manifests, workspace_objects, attachments, session_event_mirror, session_agent_state, runs, messages, sessions, users,` +
          ` plans, mint_settings, user_plan_overrides, mint_audit, billing_purchases, image_jobs,` +
          ` image_deleted_accounts, image_cards, image_card_history, image_probe_log, image_probe_state,` +
          ` shares, share_forks, reports, account_deletions, byok_keys,` +
          ` mcp_servers, mcp_oauth_tokens, mcp_oauth_flows, plugins, plugin_grants, run_usage CASCADE`,
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
    await usersRepo.ensure(db, uid, `u-${uid.slice(0, 8)}@test.local`);
    return uid;
  }

  async function seedSession(userId: string, title = "sched"): Promise<SessionRow> {
    return sessions.create(db, userId, title);
  }

  async function seedSchedule(
    userId: string,
    sessionId: string,
    opts: Partial<{ title: string; nextRunAt: Date | null; status: string }> = {},
  ): Promise<ScheduleRow> {
    return schedules.create(db, {
      userId,
      sessionId,
      title: opts.title ?? "Daily digest",
      description: "Summarize the day",
      trigger: { kind: "every", seconds: 300 },
      autonomy: "safe",
      maxRetries: 0,
      nextRunAt: opts.nextRunAt === undefined ? DUE : opts.nextRunAt,
    });
  }

  async function seedRun(sessionId: string, status?: "queued" | "running"): Promise<string> {
    const run = await runs.create(db, { sessionId, promptMessageId: newId() });
    if (status === "running") await runs.claimNext(db, run.id);
    return run.id;
  }

  /** Claim with the pinned routing context the production caller supplies. */
  const claim = (
    schedule: ScheduleRow,
    runId: string,
    opts: { scheduledFor?: Date; ranLate?: boolean } = {},
  ) =>
    scheduleRuns.claim(db, {
      scheduleId: schedule.id,
      scheduledFor: opts.scheduledFor ?? DUE,
      runId,
      ranLate: opts.ranLate ?? false,
      sessionId: schedule.sessionId,
      triggerKind: schedule.trigger.kind,
    });

  /** recordSkip with the same pinned routing context. */
  const skip = (schedule: ScheduleRow, scheduledFor: Date = DUE) =>
    scheduleRuns.recordSkip(db, {
      scheduleId: schedule.id,
      scheduledFor,
      sessionId: schedule.sessionId,
      triggerKind: schedule.trigger.kind,
    });

  // -------------------------------------------------------------------------

  it("claim is the ledger: first claim wins with status running, the duplicate returns null", async () => {
    const uid = await seedUser();
    const session = await seedSession(uid);
    const schedule = await seedSchedule(uid, session.id);
    const runId = await seedRun(session.id);

    const first = await claim(schedule, runId);
    expect(first).not.toBeNull();
    expect(first!.status).toBe("running");
    expect(first!.runId).toBe(runId);
    expect(first!.attempt).toBe(1);
    expect(first!.ranLate).toBe(false);
    expect(first!.startedAt).toBeInstanceOf(Date);
    expect(first!.finishedAt).toBeNull();
    expect(first!.sessionId).toBe(session.id);
    expect(first!.triggerKind).toBe("every");

    const second = await claim(schedule, await seedRun(session.id), { ranLate: true });
    expect(second).toBeNull();

    const rows = await db
      .select()
      .from(scheduleRunsTable)
      .where(eq(scheduleRunsTable.scheduleId, schedule.id));
    expect(rows).toHaveLength(1);
    expect(rows[0]!.id).toBe(first!.id);
  });

  it("true concurrency: two transactions claimDue+claim the same due schedule → exactly one occurrence", async () => {
    const uid = await seedUser();
    const session = await seedSession(uid);
    const schedule = await seedSchedule(uid, session.id);

    const runA = await seedRun(session.id);
    const runB = await seedRun(session.id);

    const attempt = (runId: string) =>
      db.transaction(async (tx) => {
        // FOR UPDATE SKIP LOCKED: the second transaction either sees zero due
        // rows (skips the locked schedule) or loses the INSERT conflict.
        const due = await schedules.claimDue(tx, NOW, 100);
        if (!due.some((r) => r.id === schedule.id)) return null;
        return scheduleRuns.claim(tx, {
          scheduleId: schedule.id,
          scheduledFor: DUE,
          runId,
          ranLate: false,
          sessionId: schedule.sessionId,
          triggerKind: schedule.trigger.kind,
        });
      });

    const results = await Promise.all([attempt(runA), attempt(runB)]);
    expect(results.filter((r) => r !== null)).toHaveLength(1);

    const rows = await db
      .select()
      .from(scheduleRunsTable)
      .where(eq(scheduleRunsTable.scheduleId, schedule.id));
    expect(rows).toHaveLength(1);
    expect(rows[0]!.status).toBe("running");
  });

  it("claimDue: pending + due (or retry due) only; ignores paused/future/null-nextRunAt", async () => {
    const uid = await seedUser();
    const session = await seedSession(uid);

    const due = await seedSchedule(uid, session.id, { nextRunAt: DUE });
    const paused = await seedSchedule(uid, session.id, { nextRunAt: DUE });
    await db
      .update(schedulesTable)
      .set({ status: "paused" })
      .where(eq(schedulesTable.id, paused.id));
    const future = await seedSchedule(uid, session.id, { nextRunAt: LATER });
    const retryDue = await seedSchedule(uid, session.id, { nextRunAt: null });
    const retryFuture = await seedSchedule(uid, session.id, { nextRunAt: null });

    const retryRun = await seedRun(session.id);
    const claimed = await claim(retryDue, retryRun);
    await scheduleRuns.scheduleRetry(db, claimed!.id, new Date(NOW.getTime() - 60_000));

    const retryRunFuture = await seedRun(session.id);
    const claimedFuture = await claim(retryFuture, retryRunFuture);
    await scheduleRuns.scheduleRetry(db, claimedFuture!.id, LATER);

    const found = await schedules.claimDue(db, NOW, 100);
    const ids = found.map((r) => r.id);
    expect(ids).toContain(due.id);
    expect(ids).toContain(retryDue.id);
    expect(ids).not.toContain(paused.id);
    expect(ids).not.toContain(future.id);
    expect(ids).not.toContain(retryFuture.id);
  });

  it("claimRetry is conditional; scheduleRetry bumps attempt and sets the retry slot", async () => {
    const uid = await seedUser();
    const session = await seedSession(uid);
    const schedule = await seedSchedule(uid, session.id);
    const runId = await seedRun(session.id);
    const row = await claim(schedule, runId);

    // A running row is not retryable.
    expect(await scheduleRuns.claimRetry(db, row!.id, await seedRun(session.id))).toBeNull();

    const retryAt = new Date(NOW.getTime() + 30_000);
    await scheduleRuns.scheduleRetry(db, row!.id, retryAt);
    let stored = await db
      .select()
      .from(scheduleRunsTable)
      .where(eq(scheduleRunsTable.id, row!.id));
    expect(stored[0]!.status).toBe("retry_scheduled");
    expect(stored[0]!.attempt).toBe(2);
    expect(stored[0]!.retryAt).toEqual(retryAt);

    const retryRunId = await seedRun(session.id);
    const retried = await scheduleRuns.claimRetry(db, row!.id, retryRunId);
    expect(retried).not.toBeNull();
    expect(retried!.status).toBe("running");
    expect(retried!.runId).toBe(retryRunId);
    expect(retried!.retryAt).toBeNull();
    expect(retried!.attempt).toBe(2);
    expect(retried!.startedAt).toBeInstanceOf(Date);

    // Lost race: already running again.
    expect(await scheduleRuns.claimRetry(db, row!.id, await seedRun(session.id))).toBeNull();
  });

  it("listSettleable joins schedule fields, includes terminal runs + stale orphans, skips live runs", async () => {
    const uid = await seedUser();
    const session = await seedSession(uid);
    const staleBefore = new Date(NOW.getTime() - 60_000);

    const sDone = await seedSchedule(uid, session.id, { title: "Done" });
    const runDone = await seedRun(session.id, "running");
    await runs.finish(db, runDone, "completed");
    const done = await claim(sDone, runDone, { ranLate: true });
    await db
      .update(scheduleRunsTable)
      .set({ startedAt: new Date(NOW.getTime() - 120_000) })
      .where(eq(scheduleRunsTable.id, done!.id));

    const sLive = await seedSchedule(uid, session.id, { title: "Live" });
    const runLive = await seedRun(session.id, "running");
    const live = await claim(sLive, runLive);
    await db
      .update(scheduleRunsTable)
      .set({ startedAt: new Date(NOW.getTime() - 120_000) })
      .where(eq(scheduleRunsTable.id, live!.id));

    // Orphans: the enqueue was lost, so run_id stays NULL (claim first with a
    // real run, then null it — the crash-remnant shape settle must recover).
    const sOrphan = await seedSchedule(uid, session.id, { title: "Orphan" });
    const orphan = await claim(sOrphan, await seedRun(session.id));
    await db
      .update(scheduleRunsTable)
      .set({ runId: null, startedAt: new Date(NOW.getTime() - 120_000) })
      .where(eq(scheduleRunsTable.id, orphan!.id));

    const sFreshOrphan = await seedSchedule(uid, session.id, { title: "Fresh orphan" });
    const fresh = await claim(sFreshOrphan, await seedRun(session.id));
    await db
      .update(scheduleRunsTable)
      .set({ runId: null, startedAt: new Date(NOW.getTime() - 1_000) })
      .where(eq(scheduleRunsTable.id, fresh!.id));

    const rows = await scheduleRuns.listSettleable(db, { staleBefore, limit: 100 });
    const ids = rows.map((r) => r.id);
    expect(ids).toContain(done!.id);
    expect(ids).toContain(orphan!.id);
    expect(ids).not.toContain(live!.id);
    expect(ids).not.toContain(fresh!.id);

    const settled = rows.find((r) => r.id === done!.id)!;
    expect(settled.status).toBe("running");
    expect(settled.runStatus).toBe("completed");
    expect(settled.runError).toBeNull();
    expect(settled.scheduleStatus).toBe("pending");
    expect(settled.scheduleTitle).toBe("Done");
    expect(settled.scheduleUserId).toBe(uid);
    // Pinned at claim time (final review M1) — not the joined schedule row.
    expect(settled.sessionId).toBe(session.id);
    expect(settled.triggerKind).toBe("every");
    expect(settled.scheduleMaxRetries).toBe(0);

    const orphanRow = rows.find((r) => r.id === orphan!.id)!;
    expect(orphanRow.runStatus).toBeNull();
    expect(orphanRow.runError).toBeNull();
  });

  it("list keyset-pages newest first and hides cancelled unless asked", async () => {
    const uid = await seedUser();
    const session = await seedSession(uid);
    const base = NOW.getTime();
    const all: ScheduleRow[] = [];
    for (let i = 0; i < 4; i++) {
      const row = await seedSchedule(uid, session.id, { title: `s${i}` });
      all.push(row);
      await db
        .update(schedulesTable)
        .set({ updatedAt: new Date(base + i * 1000) })
        .where(eq(schedulesTable.id, row.id));
    }
    await db
      .update(schedulesTable)
      .set({ status: "cancelled" })
      .where(eq(schedulesTable.id, all[0]!.id));

    const page1 = await schedules.list(db, uid, { limit: 2 });
    expect(page1.rows).toHaveLength(2);
    expect(page1.rows.map((r) => r.id)).toEqual([all[3]!.id, all[2]!.id]);
    expect(page1.nextCursor).not.toBeNull();

    const page2 = await schedules.list(db, uid, { limit: 2, cursor: page1.nextCursor });
    expect(page2.rows.map((r) => r.id)).toEqual([all[1]!.id]);
    expect(page2.nextCursor).toBeNull();

    // No overlap across pages.
    const seen = new Set([...page1.rows, ...page2.rows].map((r) => r.id));
    expect(seen.size).toBe(3);
    expect(seen.has(all[0]!.id)).toBe(false); // cancelled hidden

    const withCancelled = await schedules.list(db, uid, {
      limit: 10,
      includeCancelled: true,
    });
    expect(withCancelled.rows.map((r) => r.id)).toEqual([
      all[3]!.id,
      all[2]!.id,
      all[1]!.id,
      all[0]!.id,
    ]);
  });

  it("get is owner-scoped, getById is internal, update bumps updatedAt", async () => {
    const uid = await seedUser();
    const stranger = await seedUser();
    const session = await seedSession(uid);
    const schedule = await seedSchedule(uid, session.id);

    expect(await schedules.get(db, schedule.id, uid)).not.toBeNull();
    expect(await schedules.get(db, schedule.id, stranger)).toBeNull();
    expect((await schedules.getById(db, schedule.id))!.id).toBe(schedule.id);
    expect(await schedules.getById(db, newId())).toBeNull();

    const before = await schedules.getById(db, schedule.id);
    await new Promise((resolve) => setTimeout(resolve, 5));
    const updated = await schedules.update(db, schedule.id, {
      title: "Renamed",
      status: "paused",
      pausedReason: "user",
      lastResult: {
        status: "skipped",
        code: null,
        message: null,
        finishedAt: NOW.toISOString(),
        ranLate: false,
      },
    });
    expect(updated).not.toBeNull();
    expect(updated!.title).toBe("Renamed");
    expect(updated!.status).toBe("paused");
    expect(updated!.pausedReason).toBe("user");
    expect(updated!.lastResult!.status).toBe("skipped");
    expect(updated!.updatedAt.getTime()).toBeGreaterThan(before!.updatedAt.getTime());

    expect(await schedules.update(db, newId(), { title: "nope" })).toBeNull();
  });

  it("listPendingWithNextRun returns only pending rows with a next_run_at", async () => {
    const uid = await seedUser();
    const session = await seedSession(uid);
    const withNext = await seedSchedule(uid, session.id, { nextRunAt: DUE });
    const withoutNext = await seedSchedule(uid, session.id, { nextRunAt: null });
    const paused = await seedSchedule(uid, session.id, { nextRunAt: DUE });
    await db
      .update(schedulesTable)
      .set({ status: "paused" })
      .where(eq(schedulesTable.id, paused.id));

    const rows = await schedules.listPendingWithNextRun(db);
    const ids = rows.map((r) => r.id);
    expect(ids).toContain(withNext.id);
    expect(ids).not.toContain(withoutNext.id);
    expect(ids).not.toContain(paused.id);
  });

  it("finish and appendAutoDenied write the run ledger", async () => {
    const uid = await seedUser();
    const session = await seedSession(uid);
    const schedule = await seedSchedule(uid, session.id);
    const row = await claim(schedule, await seedRun(session.id));

    await scheduleRuns.appendAutoDenied(db, row!.id, {
      toolName: "shell",
      summary: "denied rm -rf",
      ts: NOW.toISOString(),
    });
    await scheduleRuns.appendAutoDenied(db, row!.id, {
      toolName: "http",
      summary: "denied example.com",
      ts: NOW.toISOString(),
    });
    await scheduleRuns.finish(db, row!.id, "failed", "model_terminal");

    const [stored] = await db
      .select()
      .from(scheduleRunsTable)
      .where(eq(scheduleRunsTable.id, row!.id));
    expect(stored!.status).toBe("failed");
    expect(stored!.error).toBe("model_terminal");
    expect(stored!.finishedAt).toBeInstanceOf(Date);
    expect(stored!.autoDenied).toHaveLength(2);
    expect(stored!.autoDenied[0]).toEqual({
      toolName: "shell",
      summary: "denied rm -rf",
      ts: NOW.toISOString(),
    });

    // finish is conditional on status='running': a second call is a no-op.
    await scheduleRuns.finish(db, row!.id, "succeeded");
    const [after] = await db
      .select()
      .from(scheduleRunsTable)
      .where(eq(scheduleRunsTable.id, row!.id));
    expect(after!.status).toBe("failed");
  });

  it("listForSchedule keyset-pages newest first by id", async () => {
    const uid = await seedUser();
    const session = await seedSession(uid);
    const schedule = await seedSchedule(uid, session.id);

    const ids: string[] = [];
    for (let i = 0; i < 3; i++) {
      const claimed: ScheduleRunRow | null = await claim(schedule, await seedRun(session.id), {
        scheduledFor: new Date(DUE.getTime() + i * 300_000),
      });
      ids.push(claimed!.id);
    }

    const page1 = await scheduleRuns.listForSchedule(db, schedule.id, { limit: 2 });
    expect(page1.rows.map((r) => r.id)).toEqual([ids[2]!, ids[1]!]);
    expect(page1.nextCursor).toBe(ids[1]);

    const page2 = await scheduleRuns.listForSchedule(db, schedule.id, {
      limit: 2,
      beforeId: page1.nextCursor,
    });
    expect(page2.rows.map((r) => r.id)).toEqual([ids[0]!]);
    expect(page2.nextCursor).toBeNull();
  });

  it("getByRunId resolves the occurrence for a run", async () => {
    const uid = await seedUser();
    const session = await seedSession(uid);
    const schedule = await seedSchedule(uid, session.id);
    const runId = await seedRun(session.id);
    const claimed = await claim(schedule, runId);

    expect((await scheduleRuns.getByRunId(db, runId))!.id).toBe(claimed!.id);
    expect(await scheduleRuns.getByRunId(db, newId())).toBeNull();
  });

  it("recordSkip claims the occurrence as skipped and loses the same ledger race", async () => {
    const uid = await seedUser();
    const session = await seedSession(uid);
    const schedule = await seedSchedule(uid, session.id);

    const first = await skip(schedule);
    expect(first).not.toBeNull();
    expect(first!.status).toBe("skipped");
    expect(first!.runId).toBeNull();
    expect(first!.sessionId).toBe(session.id);
    expect(first!.triggerKind).toBe("every");

    expect(await skip(schedule)).toBeNull();
  });
});
