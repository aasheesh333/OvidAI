import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import postgres from "postgres";
import { createDb, migrate, type Db } from "./client.js";
import { newId, sessions, users as usersRepo } from "./repos.js";
import { schedules as schedulesTable, sessions as sessionsTable, users as usersTable } from "./schema.js";
import type { ScheduleRow } from "./schema.js";
import { schedules } from "./scheduleRepos.js";
import {
  cancelSchedule,
  createSchedule,
  runScheduleNow,
  ScheduleError,
  updateSchedule,
} from "./scheduleService.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

// Fixed instants so nothing depends on the wall clock. The service takes an
// injected clock; every assertion below is exact.
const NOW = new Date("2026-10-17T12:00:00.000Z");
const clock = () => NOW;
const clockAt = (iso: string) => () => new Date(iso);

describe.skipIf(!TEST_DATABASE_URL)("scheduleService against real postgres", () => {
  let db: Db;

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    // Same drop/recreate discipline as repos.test.ts / scheduleRepos.test.ts.
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
          ` notification_delivery_claims, push_subscriptions, private_memory_files, projects CASCADE`,
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

  async function seedUser(tier = "free"): Promise<string> {
    const uid = newId();
    await usersRepo.ensure(db, uid, `u-${uid.slice(0, 8)}@test.local`);
    if (tier !== "free") {
      await db.update(usersTable).set({ tier }).where(eq(usersTable.uid, uid));
    }
    return uid;
  }

  async function countSessions(userId: string): Promise<number> {
    const rows = await db
      .select({ id: sessionsTable.id })
      .from(sessionsTable)
      .where(eq(sessionsTable.userId, userId));
    return rows.length;
  }

  async function expectScheduleError(
    promise: Promise<unknown>,
    code: ScheduleError["code"],
  ): Promise<ScheduleError> {
    let caught: unknown;
    try {
      await promise;
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(ScheduleError);
    const err = caught as ScheduleError;
    expect(err.code).toBe(code);
    return err;
  }

  const baseCreate = (userId: string, overrides: Partial<Parameters<typeof createSchedule>[1]> = {}) => ({
    userId,
    title: "Daily digest",
    description: "Summarize the day",
    trigger: { kind: "every" as const, seconds: 300 },
    clock,
    ...overrides,
  });

  // -------------------------------------------------------------------------

  it("gates cron on the free tier and allows it once the user is pro", async () => {
    const uid = await seedUser("free");

    const err = await expectScheduleError(
      createSchedule(db, baseCreate(uid, { trigger: { kind: "cron", expr: "0 9 * * *", tz: "UTC" } })),
      "tier_required",
    );
    expect(err.message).toBe("Cron schedules require Ovid Pro.");

    // users.ensure is idempotent and never clobbers the stored email.
    await db.update(usersTable).set({ tier: "pro" }).where(eq(usersTable.uid, uid));
    const created = await createSchedule(
      db,
      baseCreate(uid, { trigger: { kind: "cron", expr: "0 9 * * *", tz: "UTC" } }),
    );
    expect(created.trigger).toEqual({ kind: "cron", expr: "0 9 * * *", tz: "UTC" });
    expect(created.status).toBe("pending");
    expect(created.nextRunAt).toEqual(new Date("2026-10-18T09:00:00.000Z"));

    const [stored] = await db.select().from(usersTable).where(eq(usersTable.uid, uid));
    expect(stored!.tier).toBe("pro");
    expect(stored!.email).toBe(`u-${uid.slice(0, 8)}@test.local`);
  });

  it("creates a dedicated session titled after the schedule when none is bound", async () => {
    const uid = await seedUser();
    const before = await countSessions(uid);

    const created = await createSchedule(db, baseCreate(uid, { title: "Morning brief" }));

    expect(await countSessions(uid)).toBe(before + 1);
    const session = await sessions.get(db, created.sessionId, uid);
    expect(session).not.toBeNull();
    expect(session!.title).toBe("Morning brief");
  });

  it("binds an owned session and rejects someone else's with not_found", async () => {
    const uid = await seedUser();
    const stranger = await seedUser();
    const own = await sessions.create(db, uid, "bound");

    const created = await createSchedule(db, baseCreate(uid, { sessionId: own.id }));
    expect(created.sessionId).toBe(own.id);
    expect(await countSessions(uid)).toBe(1); // no dedicated session materialized

    const strangerSession = await sessions.create(db, stranger, "theirs");
    const err = await expectScheduleError(
      createSchedule(db, baseCreate(uid, { sessionId: strangerSession.id })),
      "not_found",
    );
    expect(err.message).toBe("Session not found.");
  });

  it("rejects a one-off more than 24 h in the past but keeps one within grace", async () => {
    const uid = await seedUser();

    await expectScheduleError(
      createSchedule(db, baseCreate(uid, { trigger: { kind: "at", at: "2026-10-16T11:00:00.000Z" } })),
      "invalid_trigger",
    ); // exactly 25 h before NOW

    const threeHoursAgo = "2026-10-17T09:00:00.000Z";
    const created = await createSchedule(
      db,
      baseCreate(uid, { trigger: { kind: "at", at: threeHoursAgo } }),
    );
    expect(created.nextRunAt).toEqual(new Date(threeHoursAgo));
  });

  it("computes nextRunAt exactly for every/interval triggers", async () => {
    const uid = await seedUser();
    const created = await createSchedule(
      db,
      baseCreate(uid, { trigger: { kind: "every", seconds: 300 } }),
    );
    expect(created.nextRunAt).toEqual(new Date(NOW.getTime() + 300_000));
    expect(created.autonomy).toBe("safe");
    expect(created.maxRetries).toBe(0);
    expect(created.status).toBe("pending");
    expect(created.pausedReason).toBeNull();
  });

  it("rejects out-of-range maxRetries with bad_request", async () => {
    const uid = await seedUser();
    await expectScheduleError(createSchedule(db, baseCreate(uid, { maxRetries: 4 })), "bad_request");
    await expectScheduleError(createSchedule(db, baseCreate(uid, { maxRetries: -1 })), "bad_request");
    await expectScheduleError(createSchedule(db, baseCreate(uid, { maxRetries: 1.5 })), "bad_request");

    const created = await createSchedule(db, baseCreate(uid, { maxRetries: 3, autonomy: "auto" }));
    expect(created.maxRetries).toBe(3);
    expect(created.autonomy).toBe("auto");
  });

  it("pauses keeping nextRunAt, then resumes a daily_at schedule at its next slot", async () => {
    const uid = await seedUser();
    const created = await createSchedule(
      db,
      baseCreate(uid, {
        trigger: { kind: "daily_at", time: "09:00", tz: "UTC" },
        clock: clockAt("2026-10-17T08:00:00.000Z"),
      }),
    );
    expect(created.nextRunAt).toEqual(new Date("2026-10-17T09:00:00.000Z"));

    const paused = await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      patch: { status: "paused" },
      clock,
    });
    expect(paused.status).toBe("paused");
    expect(paused.pausedReason).toBe("user");
    // Informational only; claimDue filters on status='pending'.
    expect(paused.nextRunAt).toEqual(new Date("2026-10-17T09:00:00.000Z"));

    const resumed = await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      patch: { status: "pending" },
      clock,
    });
    expect(resumed.status).toBe("pending");
    expect(resumed.pausedReason).toBeNull();
    expect(resumed.nextRunAt).toEqual(new Date("2026-10-18T09:00:00.000Z"));
  });

  it("resumes a past one-off at now (Dart 'missed one runs on the next tick')", async () => {
    const uid = await seedUser();
    const created = await createSchedule(
      db,
      baseCreate(uid, {
        trigger: { kind: "at", at: "2026-10-17T13:00:00.000Z" },
        clock,
      }),
    );
    expect(created.nextRunAt).toEqual(new Date("2026-10-17T13:00:00.000Z"));

    await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      patch: { status: "paused" },
      clock,
    });

    const resumed = await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      patch: { status: "pending" },
      clock: clockAt("2026-10-17T15:00:00.000Z"),
    });
    expect(resumed.nextRunAt).toEqual(new Date("2026-10-17T15:00:00.000Z"));
  });

  it("recomputes nextRunAt when the trigger changes while pending", async () => {
    const uid = await seedUser();
    const created = await createSchedule(db, baseCreate(uid));

    const updated = await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      patch: { trigger: { kind: "every", seconds: 600 }, title: "Renamed" },
      clock,
    });
    expect(updated.title).toBe("Renamed");
    expect(updated.nextRunAt).toEqual(new Date(NOW.getTime() + 600_000));
  });

  it("re-checks the cron tier on update", async () => {
    const uid = await seedUser("free");
    const created = await createSchedule(db, baseCreate(uid));

    await expectScheduleError(
      updateSchedule(db, {
        userId: uid,
        scheduleId: created.id,
        patch: { trigger: { kind: "cron", expr: "0 9 * * *", tz: "UTC" } },
        clock,
      }),
      "tier_required",
    );

    await db.update(usersTable).set({ tier: "pro" }).where(eq(usersTable.uid, uid));
    const updated = await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      patch: { trigger: { kind: "cron", expr: "0 9 * * *", tz: "UTC" } },
      clock,
    });
    expect(updated.nextRunAt).toEqual(new Date("2026-10-18T09:00:00.000Z"));
  });

  it("rejects empty patches, terminal schedules, and non-paused resumes", async () => {
    const uid = await seedUser();
    const created = await createSchedule(db, baseCreate(uid));

    await expectScheduleError(
      updateSchedule(db, { userId: uid, scheduleId: created.id, patch: {}, clock }),
      "bad_request",
    );
    await expectScheduleError(
      updateSchedule(db, {
        userId: uid,
        scheduleId: created.id,
        patch: { status: "pending" },
        clock,
      }),
      "bad_request",
    );

    await cancelSchedule(db, { userId: uid, scheduleId: created.id });
    await expectScheduleError(
      updateSchedule(db, {
        userId: uid,
        scheduleId: created.id,
        patch: { title: "nope" },
        clock,
      }),
      "bad_request",
    );
  });

  it("rebinds sessions with the same ownership check as create", async () => {
    const uid = await seedUser();
    const stranger = await seedUser();
    const created = await createSchedule(db, baseCreate(uid));
    const own = await sessions.create(db, uid, "rebind");
    const theirs = await sessions.create(db, stranger, "theirs");

    const rebound = await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      patch: { sessionId: own.id },
      clock,
    });
    expect(rebound.sessionId).toBe(own.id);

    await expectScheduleError(
      updateSchedule(db, {
        userId: uid,
        scheduleId: created.id,
        patch: { sessionId: theirs.id },
        clock,
      }),
      "not_found",
    );
  });

  it("is owner-scoped: wrong-owner update and cancel are not_found", async () => {
    const uid = await seedUser();
    const stranger = await seedUser();
    const created = await createSchedule(db, baseCreate(uid));

    await expectScheduleError(
      updateSchedule(db, {
        userId: stranger,
        scheduleId: created.id,
        patch: { title: "hijack" },
        clock,
      }),
      "not_found",
    );
    await expectScheduleError(
      cancelSchedule(db, { userId: stranger, scheduleId: created.id }),
      "not_found",
    );

    const [stored] = await db
      .select()
      .from(schedulesTable)
      .where(eq(schedulesTable.id, created.id));
    expect(stored!.status).toBe("pending");
    expect(stored!.title).toBe(created.title);
  });

  it("cancels idempotently and clears pausedReason", async () => {
    const uid = await seedUser();
    const created = await createSchedule(db, baseCreate(uid));
    await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      patch: { status: "paused" },
      clock,
    });

    await cancelSchedule(db, { userId: uid, scheduleId: created.id });
    await cancelSchedule(db, { userId: uid, scheduleId: created.id }); // no throw

    const [stored] = await db
      .select()
      .from(schedulesTable)
      .where(eq(schedulesTable.id, created.id));
    expect(stored!.status).toBe("cancelled");
    expect(stored!.pausedReason).toBeNull();
  });

  // ---- Wave 5: FE-013 / FE-017 / run now -----------------------------------

  async function markFailed(id: string): Promise<void> {
    await db.update(schedulesTable).set({ status: "failed" }).where(eq(schedulesTable.id, id));
  }

  it("FE-017: a patch that carries the UNCHANGED trigger never reschedules", async () => {
    const uid = await seedUser();
    const created = await createSchedule(db, baseCreate(uid));
    const later = clockAt("2026-10-17T12:04:00.000Z");

    const renamed = await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      // Same trigger, keys in another order — still the same trigger.
      patch: { title: "Renamed", trigger: { seconds: 300, kind: "every" } as never },
      clock: later,
    });
    expect(renamed.title).toBe("Renamed");
    expect(renamed.nextRunAt).toEqual(created.nextRunAt);
  });

  it("FE-013: a failed schedule can be edited after review and resumed", async () => {
    const uid = await seedUser();
    const created = await createSchedule(db, baseCreate(uid));
    await markFailed(created.id);

    const edited = await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      patch: { description: "Summarize the day, but shorter" },
      clock,
    });
    expect(edited.status).toBe("failed");
    expect(edited.description).toBe("Summarize the day, but shorter");

    const resumed = await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      patch: { status: "pending" },
      clock,
    });
    expect(resumed.status).toBe("pending");
    expect(resumed.pausedReason).toBeNull();
    expect(resumed.nextRunAt).toEqual(new Date(NOW.getTime() + 300_000));
  });

  it("FE-013: a failed one-off resumed with a new time keeps that time", async () => {
    const uid = await seedUser();
    const created = await createSchedule(
      db,
      baseCreate(uid, { trigger: { kind: "at", at: "2026-10-17T13:00:00.000Z" } }),
    );
    await markFailed(created.id);
    const resumed = await updateSchedule(db, {
      userId: uid,
      scheduleId: created.id,
      patch: { status: "pending", trigger: { kind: "at", at: "2026-10-18T08:00:00.000Z" } },
      clock,
    });
    expect(resumed.status).toBe("pending");
    expect(resumed.nextRunAt).toEqual(new Date("2026-10-18T08:00:00.000Z"));
  });

  it("completed and cancelled schedules stay read-only", async () => {
    const uid = await seedUser();
    const created = await createSchedule(db, baseCreate(uid));
    await db.update(schedulesTable).set({ status: "completed" }).where(eq(schedulesTable.id, created.id));
    await expectScheduleError(
      updateSchedule(db, { userId: uid, scheduleId: created.id, patch: { status: "pending" }, clock }),
      "bad_request",
    );
  });

  it("run now: claims an immediate occurrence (message + run + ledger) without touching nextRunAt", async () => {
    const uid = await seedUser();
    const created = await createSchedule(db, baseCreate(uid));

    const fired = await runScheduleNow(db, { userId: uid, scheduleId: created.id, clock });
    expect(fired.schedule.id).toBe(created.id);
    expect(fired.scheduleRun.scheduleId).toBe(created.id);
    expect(fired.scheduleRun.status).toBe("running");
    expect(fired.scheduleRun.runId).toBe(fired.runId);
    expect(fired.scheduleRun.scheduledFor).toEqual(NOW);
    expect(fired.prompt).toBe("[schedule: Daily digest] Summarize the day");

    const after = await schedules.get(db, created.id, uid);
    expect(after!.nextRunAt).toEqual(created.nextRunAt);
    expect(after!.status).toBe("pending");
  });

  it("run now refuses a busy chat, a cancelled schedule, and a stranger", async () => {
    const uid = await seedUser();
    const created = await createSchedule(db, baseCreate(uid));
    await runScheduleNow(db, { userId: uid, scheduleId: created.id, clock });
    // The first run is still queued: the chat is busy.
    await expectScheduleError(
      runScheduleNow(db, { userId: uid, scheduleId: created.id, clock: clockAt("2026-10-17T12:00:01.000Z") }),
      "busy",
    );

    const other = await seedUser();
    await expectScheduleError(runScheduleNow(db, { userId: other, scheduleId: created.id, clock }), "not_found");

    const second = await createSchedule(db, baseCreate(uid));
    await cancelSchedule(db, { userId: uid, scheduleId: second.id });
    await expectScheduleError(runScheduleNow(db, { userId: uid, scheduleId: second.id, clock }), "bad_request");
  });

  it("run now works on a paused or failed schedule (a test run during review)", async () => {
    const uid = await seedUser();
    const created = await createSchedule(db, baseCreate(uid));
    await markFailed(created.id);
    const fired = await runScheduleNow(db, { userId: uid, scheduleId: created.id, clock });
    expect(fired.scheduleRun.status).toBe("running");
    const after = await schedules.get(db, created.id, uid);
    expect(after!.status).toBe("failed");
  });

  it("throws not_found for an unknown schedule id", async () => {
    const uid = await seedUser();
    await expectScheduleError(
      updateSchedule(db, { userId: uid, scheduleId: newId(), patch: { title: "x" }, clock }),
      "not_found",
    );
    await expectScheduleError(
      cancelSchedule(db, { userId: uid, scheduleId: newId() }),
      "not_found",
    );
  });
});
