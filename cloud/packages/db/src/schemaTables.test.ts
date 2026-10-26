import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { eq, sql } from "drizzle-orm";
import { createDb, migrate, type Db } from "./client.js";
import { resetPublicSchema } from "./migrationTestKit.js";
import { newId, sessions, users as usersRepo } from "./repos.js";
import { devices, notifications, scheduleRuns, schedules } from "./schema.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

const UUIDV7_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

// Fixed instants (ms precision) so timestamp round-trip assertions never
// depend on the wall clock.
const NEXT_RUN = new Date("2026-10-18T09:00:00.000Z");
const SCHEDULED_FOR = new Date("2026-10-18T09:00:00.000Z");

describe.skipIf(!TEST_DATABASE_URL)("scheduler schema against real postgres", () => {
  let db: Db;

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    // Same drop/recreate discipline as repos.test.ts (P8-T3 rerunnability
    // invariant): journal schema, sandbox sequence and every migrated table
    // are dropped so migrate() re-applies from scratch on every run.
    await resetPublicSchema(url);
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

  /** Minimal schedules row: only the NOT NULL columns without defaults. */
  async function seedSchedule(userId: string): Promise<typeof schedules.$inferSelect> {
    const session = await sessions.create(db, userId, "scheduler");
    const [row] = await db
      .insert(schedules)
      .values({
        id: newId(),
        userId,
        sessionId: session.id,
        title: "Daily digest",
        description: "Summarize the day",
        trigger: { kind: "every", seconds: 300 },
        nextRunAt: NEXT_RUN,
      })
      .returning();
    return row!;
  }

  it("schedules: trigger jsonb round-trips and column defaults apply", async () => {
    const uid = await seedUser();
    const row = await seedSchedule(uid);

    expect(row.id).toMatch(UUIDV7_RE);
    expect(row.userId).toBe(uid);
    expect(row.trigger).toEqual({ kind: "every", seconds: 300 });
    expect(row.status).toBe("pending");
    expect(row.autonomy).toBe("safe");
    expect(row.maxRetries).toBe(0);
    expect(row.pausedReason).toBeNull();
    expect(row.lastResult).toBeNull();
    // timestamptz(3) round-trip: no sub-ms drift between JS Date and DB value.
    expect(row.nextRunAt).toEqual(NEXT_RUN);
    expect(row.createdAt).toBeInstanceOf(Date);
    expect(row.updatedAt).toBeInstanceOf(Date);

    const [readBack] = await db.select().from(schedules).where(eq(schedules.id, row.id));
    expect(readBack).toEqual(row);
  });

  it("schedule_runs: the (schedule_id, scheduled_for) claim ledger rejects a duplicate with 23505", async () => {
    const uid = await seedUser();
    const schedule = await seedSchedule(uid);

    const [first] = await db
      .insert(scheduleRuns)
      .values({
        id: newId(),
        scheduleId: schedule.id,
        scheduledFor: SCHEDULED_FOR,
        sessionId: schedule.sessionId,
        triggerKind: "every",
        status: "running",
        startedAt: SCHEDULED_FOR,
      })
      .returning();
    expect(first!.attempt).toBe(1);
    expect(first!.ranLate).toBe(false);
    expect(first!.retryAt).toBeNull();
    expect(first!.error).toBeNull();
    expect(first!.autoDenied).toEqual([]); // '[]'::jsonb default
    expect(first!.runId).toBeNull();
    expect(first!.scheduledFor).toEqual(SCHEDULED_FOR);
    expect(first!.createdAt).toBeInstanceOf(Date);

    // Same occurrence → unique violation on the claim index (drizzle wraps the
    // driver error; walk .cause).
    let violated: unknown = null;
    try {
      await db.insert(scheduleRuns).values({
        id: newId(),
        scheduleId: schedule.id,
        scheduledFor: SCHEDULED_FOR,
        sessionId: schedule.sessionId,
        triggerKind: "every",
        status: "running",
      });
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

  it("devices: upsert by token and notifications round-trip", async () => {
    const uid = await seedUser();
    const token = `fcm-${newId()}`;

    await db.insert(devices).values({ token, userId: uid });
    // Re-register (upsert-style raw insert) must not throw and must not
    // duplicate the row.
    await db
      .insert(devices)
      .values({ token, userId: uid })
      .onConflictDoUpdate({
        target: devices.token,
        set: { userId: uid, updatedAt: new Date() },
      });

    const deviceRows = await db.select().from(devices).where(eq(devices.token, token));
    expect(deviceRows).toHaveLength(1);
    expect(deviceRows[0]!.platform).toBe("android");
    expect(deviceRows[0]!.createdAt).toBeInstanceOf(Date);
    expect(deviceRows[0]!.updatedAt).toBeInstanceOf(Date);

    const notifId = newId();
    const [sent] = await db
      .insert(notifications)
      .values({
        id: notifId,
        userId: uid,
        deviceToken: token,
        kind: "schedule_run_succeeded",
        channel: "push",
        title: "Schedule finished",
        body: "Daily digest succeeded",
        route: `/schedules/${notifId}`,
        data: { scheduleId: notifId, status: "succeeded" },
      })
      .returning();
    expect(sent!.status).toBe("sent"); // column default
    expect(sent!.error).toBeNull();
    expect(sent!.deviceToken).toBe(token);
    expect(sent!.data).toEqual({ scheduleId: notifId, status: "succeeded" });
    expect(sent!.createdAt).toBeInstanceOf(Date);

    // device_token is nullable — a no-device record stores NULL.
    const [noDevice] = await db
      .insert(notifications)
      .values({
        id: newId(),
        userId: uid,
        deviceToken: null,
        kind: "schedule_run_failed",
        channel: "inbox",
        title: "Schedule failed",
        body: "No devices registered",
        route: "/schedules",
        data: {},
        status: "skipped_no_devices",
      })
      .returning();
    expect(noDevice!.deviceToken).toBeNull();
    expect(noDevice!.status).toBe("skipped_no_devices");

    const [readBack] = await db.select().from(notifications).where(eq(notifications.id, notifId));
    expect(readBack).toEqual(sent);
  });

  it("deleting a schedule cascades its schedule_runs rows", async () => {
    const uid = await seedUser();
    const schedule = await seedSchedule(uid);

    await db.insert(scheduleRuns).values([
      {
        id: newId(),
        scheduleId: schedule.id,
        scheduledFor: SCHEDULED_FOR,
        sessionId: schedule.sessionId,
        triggerKind: "every",
        status: "succeeded",
      },
      {
        id: newId(),
        scheduleId: schedule.id,
        scheduledFor: new Date(SCHEDULED_FOR.getTime() + 300_000),
        sessionId: schedule.sessionId,
        triggerKind: "every",
        status: "succeeded",
      },
    ]);

    await db.delete(schedules).where(eq(schedules.id, schedule.id));

    const [{ count }] = (await db.execute(
      sql`SELECT count(*)::int AS count FROM schedule_runs WHERE schedule_id = ${schedule.id}`,
    )) as unknown as { count: number }[];
    expect(count).toBe(0);
  });
});
