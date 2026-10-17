import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { newId, type Db } from "@ovid/db";
import {
  pageSchema,
  scheduleDtoSchema,
  scheduleRunDtoSchema,
  type Page,
  type ScheduleDto,
  type ScheduleRunDto,
} from "@ovid/shared";
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
  type SystemBusStub,
} from "../test/stubs.js";

const schedulePage = pageSchema(scheduleDtoSchema);
const runPage = pageSchema(scheduleRunDtoSchema);

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

const EVERY_300 = { kind: "every", seconds: 300 } as const;

describe.skipIf(!TEST_DATABASE_URL)("gateway schedule routes (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;
  let bus: SystemBusStub;

  beforeAll(async () => {
    db = await openTestDb();
    bus = stubSystemBus();
    const { queues } = stubQueues();
    app = buildGateway({
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      system: bus,
    });
  }, 60_000);

  afterAll(async () => {
    await app?.close();
    await closeDb(db);
  });

  function createBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
    return {
      title: "Morning report",
      description: "check things",
      trigger: EVERY_300,
      ...overrides,
    };
  }

  async function createSchedule(
    uid: string,
    overrides: Record<string, unknown> = {},
  ): Promise<ScheduleDto> {
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/schedules",
      headers: authHeaders(uid),
      payload: createBody(overrides),
    });
    expect(res.statusCode, res.body).toBe(201);
    return scheduleDtoSchema.parse(res.json());
  }

  async function setTier(uid: string, tier: string): Promise<void> {
    await db.$client.unsafe("UPDATE users SET tier = $2 WHERE uid = $1", [uid, tier]);
  }

  async function setNextRunAt(scheduleId: string, iso: string): Promise<void> {
    await db.$client.unsafe("UPDATE schedules SET next_run_at = $2 WHERE id = $1", [
      scheduleId,
      iso,
    ]);
  }

  it("POST /schedules → 201 pending/safe, nextRunAt ≈ now+300 s, dedicated session exists", async () => {
    const uid = testUid("sched-create");
    const before = Date.now();
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/schedules",
      headers: authHeaders(uid),
      payload: createBody(),
    });
    const after = Date.now();
    expect(res.statusCode).toBe(201);
    const dto = scheduleDtoSchema.parse(res.json());
    expect(dto.status).toBe("pending");
    expect(dto.autonomy).toBe("safe");
    expect(dto.pausedReason).toBeNull();
    expect(dto.maxRetries).toBe(0);
    expect(dto.trigger).toEqual(EVERY_300);
    expect(dto.nextRunAt).not.toBeNull();
    const next = Date.parse(dto.nextRunAt!);
    expect(next).toBeGreaterThanOrEqual(before + 300_000);
    expect(next).toBeLessThanOrEqual(after + 300_000 + 2_000);

    // Dedicated session materialized and owned by the caller.
    const session = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${dto.sessionId}`,
      headers: authHeaders(uid),
    });
    expect(session.statusCode).toBe(200);

    // users.ensure ran before the create (FK target).
    const rows = await db.$client.unsafe("SELECT uid, tier FROM users WHERE uid = $1", [uid]);
    expect(rows.length).toBe(1);
  });

  it("POST /schedules cron is Pro-only: free → 403 tier_required; after tier='pro' → 201", async () => {
    const uid = testUid("sched-cron");
    const cron = { kind: "cron", expr: "*/5 * * * *", tz: "UTC" };

    const denied = await app.inject({
      method: "POST",
      url: "/cloud/v1/schedules",
      headers: authHeaders(uid),
      payload: createBody({ trigger: cron }),
    });
    expect(denied.statusCode).toBe(403);
    expect(denied.json()).toEqual({
      error: { code: "tier_required", message: "Cron schedules require Ovid Pro." },
    });

    await setTier(uid, "pro");
    const allowed = await app.inject({
      method: "POST",
      url: "/cloud/v1/schedules",
      headers: authHeaders(uid),
      payload: createBody({ trigger: cron }),
    });
    expect(allowed.statusCode).toBe(201);
    expect(scheduleDtoSchema.parse(allowed.json()).trigger).toEqual(cron);
  });

  it("POST /schedules with an unknown sessionId → 404 not_found", async () => {
    const uid = testUid("sched-badsession");
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/schedules",
      headers: authHeaders(uid),
      payload: createBody({ sessionId: newId() }),
    });
    expect(res.statusCode).toBe(404);
    expect(res.json().error.code).toBe("not_found");
  });

  it("POST /schedules rejects malformed bodies → 400 bad_request", async () => {
    const uid = testUid("sched-badbody");
    const payloads: unknown[] = [
      {},
      { title: "" },
      createBody({ unknown: true }),
      createBody({ maxRetries: 9 }),
      createBody({ trigger: { kind: "every", seconds: 10 } }),
      createBody({ autonomy: "unsafe" }),
    ];
    for (const payload of payloads) {
      const res = await app.inject({
        method: "POST",
        url: "/cloud/v1/schedules",
        headers: authHeaders(uid),
        payload: payload as Record<string, unknown>,
      });
      expect(res.statusCode, JSON.stringify(payload)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
  });

  it("GET /schedules is owner-scoped, cursor-paginated, and hides cancelled unless asked", async () => {
    const uid = testUid("sched-list");
    const other = testUid("sched-list-other");
    const mine: ScheduleDto[] = [];
    for (let i = 0; i < 3; i++) {
      mine.push(await createSchedule(uid, { title: `s${i}` }));
    }
    await createSchedule(other, { title: "not mine" });

    // Empty for another user.
    const theirs = await app.inject({
      method: "GET",
      url: "/cloud/v1/schedules",
      headers: authHeaders(other),
    });
    expect(theirs.statusCode).toBe(200);
    const otherPage = schedulePage.parse(theirs.json()) as Page<ScheduleDto>;
    expect(otherPage.items.map((s) => s.title)).toEqual(["not mine"]);

    // Pages of 2 via nextCursor.
    const seen: string[] = [];
    const sizes: number[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < 10; page++) {
      const url = cursor
        ? `/cloud/v1/schedules?limit=2&cursor=${encodeURIComponent(cursor)}`
        : "/cloud/v1/schedules?limit=2";
      const res = await app.inject({ method: "GET", url, headers: authHeaders(uid) });
      expect(res.statusCode).toBe(200);
      const body = schedulePage.parse(res.json()) as Page<ScheduleDto>;
      sizes.push(body.items.length);
      seen.push(...body.items.map((s) => s.id));
      cursor = body.nextCursor;
      if (cursor === null) break;
    }
    expect(sizes).toEqual([2, 1]);
    expect(seen.sort()).toEqual(mine.map((s) => s.id).sort());

    // Cancelled hidden by default, shown with includeCancelled=true.
    const cancelled = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/schedules/${mine[0]!.id}`,
      headers: authHeaders(uid),
    });
    expect(cancelled.statusCode).toBe(204);

    const hidden = await app.inject({
      method: "GET",
      url: "/cloud/v1/schedules",
      headers: authHeaders(uid),
    });
    expect(schedulePage.parse(hidden.json()).items.map((s) => s.id)).not.toContain(mine[0]!.id);

    const shown = await app.inject({
      method: "GET",
      url: "/cloud/v1/schedules?includeCancelled=true",
      headers: authHeaders(uid),
    });
    expect(schedulePage.parse(shown.json()).items.map((s) => s.id)).toContain(mine[0]!.id);

    // Anything other than the literal "true" is false.
    const notTrue = await app.inject({
      method: "GET",
      url: "/cloud/v1/schedules?includeCancelled=1",
      headers: authHeaders(uid),
    });
    expect(schedulePage.parse(notTrue.json()).items.map((s) => s.id)).not.toContain(
      mine[0]!.id,
    );
  });

  it("GET/PATCH/DELETE as another user or with a malformed id → 404 not_found (never 403/500)", async () => {
    const owner = testUid("sched-404");
    const stranger = testUid("sched-404-stranger");
    const created = await createSchedule(owner, { title: "mine" });

    for (const method of ["GET", "PATCH", "DELETE"] as const) {
      const theirs = await app.inject({
        method,
        url: `/cloud/v1/schedules/${created.id}`,
        headers: authHeaders(stranger),
        ...(method === "PATCH" ? { payload: { title: "hijack" } } : {}),
      });
      expect(theirs.statusCode, method).toBe(404);
      expect(theirs.json().error.code, method).toBe("not_found");
      expect(theirs.json().error.message, method).toBe("Schedule not found.");

      const malformed = await app.inject({
        method,
        url: "/cloud/v1/schedules/nope",
        headers: authHeaders(owner),
        ...(method === "PATCH" ? { payload: { title: "x" } } : {}),
      });
      expect(malformed.statusCode, `${method} malformed`).toBe(404);
      expect(malformed.json().error.code).toBe("not_found");
      expect(malformed.json().error.message).toBe("Schedule not found.");
    }

    // Owner's row untouched.
    const after = await app.inject({
      method: "GET",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(owner),
    });
    expect(after.statusCode).toBe(200);
    expect(scheduleDtoSchema.parse(after.json()).title).toBe("mine");
  });

  it("PATCH pauses with pausedReason 'user'; PATCH pending recomputes nextRunAt", async () => {
    const uid = testUid("sched-patch");
    const created = await createSchedule(uid);

    const paused = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(uid),
      payload: { status: "paused" },
    });
    expect(paused.statusCode).toBe(200);
    const pausedDto = scheduleDtoSchema.parse(paused.json());
    expect(pausedDto.status).toBe("paused");
    expect(pausedDto.pausedReason).toBe("user");

    // Force a stale nextRunAt: resume must recompute it from now.
    await setNextRunAt(created.id, "2000-01-01T00:00:00.000Z");
    const before = Date.now();
    const resumed = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(uid),
      payload: { status: "pending" },
    });
    expect(resumed.statusCode).toBe(200);
    const resumedDto = scheduleDtoSchema.parse(resumed.json());
    expect(resumedDto.status).toBe("pending");
    expect(resumedDto.pausedReason).toBeNull();
    expect(Date.parse(resumedDto.nextRunAt!)).toBeGreaterThanOrEqual(before + 299_000);

    const empty = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(uid),
      payload: {},
    });
    expect(empty.statusCode).toBe(400);
    expect(empty.json().error.code).toBe("bad_request");

    const unknownKey = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(uid),
      payload: { nope: 1 },
    });
    expect(unknownKey.statusCode).toBe(400);
  });

  it("DELETE → 204, list excludes it, second DELETE → 204 idempotent", async () => {
    const uid = testUid("sched-delete");
    const created = await createSchedule(uid);

    const first = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(uid),
    });
    expect(first.statusCode).toBe(204);
    expect(first.body).toBe("");

    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/schedules",
      headers: authHeaders(uid),
    });
    expect(schedulePage.parse(list.json()).items).toEqual([]);

    const second = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(uid),
    });
    expect(second.statusCode).toBe(204);

    const gone = await app.inject({
      method: "GET",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(uid),
    });
    // Soft delete keeps the row: detail is still readable, status cancelled.
    expect(gone.statusCode).toBe(200);
    expect(scheduleDtoSchema.parse(gone.json()).status).toBe("cancelled");
  });

  it("GET /:id/runs pages newest-first and splits on the before cursor", async () => {
    const uid = testUid("sched-runs");
    const schedule = await createSchedule(uid);

    const older = newId();
    await sleep(5);
    const newer = newId();
    for (const [id, scheduledFor] of [
      [older, "2026-01-01T00:00:00.000Z"],
      [newer, "2026-01-02T00:00:00.000Z"],
    ] as const) {
      await db.$client.unsafe(
        `INSERT INTO schedule_runs (id, schedule_id, scheduled_for, session_id, trigger_kind, status)
         VALUES ($1, $2, $3, $4, 'cron', 'succeeded')`,
        [id, schedule.id, scheduledFor, schedule.sessionId],
      );
    }

    const first = await app.inject({
      method: "GET",
      url: `/cloud/v1/schedules/${schedule.id}/runs?limit=1`,
      headers: authHeaders(uid),
    });
    expect(first.statusCode).toBe(200);
    const firstPage = runPage.parse(first.json()) as Page<ScheduleRunDto>;
    expect(firstPage.items.map((r) => r.id)).toEqual([newer]);
    expect(firstPage.nextCursor).toBe(newer);

    const second = await app.inject({
      method: "GET",
      url: `/cloud/v1/schedules/${schedule.id}/runs?limit=1&before=${firstPage.nextCursor}`,
      headers: authHeaders(uid),
    });
    expect(second.statusCode).toBe(200);
    const secondPage = runPage.parse(second.json()) as Page<ScheduleRunDto>;
    expect(secondPage.items.map((r) => r.id)).toEqual([older]);
    expect(secondPage.nextCursor).toBeNull();

    // A garbage `before` is ignored (first page again), never a 400/500.
    const garbage = await app.inject({
      method: "GET",
      url: `/cloud/v1/schedules/${schedule.id}/runs?limit=1&before=garbage`,
      headers: authHeaders(uid),
    });
    expect(garbage.statusCode).toBe(200);
    expect(runPage.parse(garbage.json()).items.map((r) => r.id)).toEqual([newer]);

    // Ownership check precedes the feed: a stranger gets 404, not an empty page.
    const stranger = await app.inject({
      method: "GET",
      url: `/cloud/v1/schedules/${schedule.id}/runs`,
      headers: authHeaders(testUid("sched-runs-stranger")),
    });
    expect(stranger.statusCode).toBe(404);
    expect(stranger.json().error.code).toBe("not_found");
  });

  it("publishes schedule_created / schedule_updated / schedule_deleted on the uid's channel", async () => {
    const uid = testUid("sched-bus");
    bus.published.length = 0;

    const created = await createSchedule(uid, { title: "bus pin" });
    const createdEvent = bus.published.find((p) => p.event.type === "schedule_created");
    expect(createdEvent).toBeDefined();
    expect(createdEvent!.uid).toBe(uid);
    expect(createdEvent!.event.scheduleId).toBe(created.id);
    expect(createdEvent!.event.payload.schedule).toMatchObject({
      id: created.id,
      title: "bus pin",
    });

    const patched = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(uid),
      payload: { title: "patched" },
    });
    expect(patched.statusCode).toBe(200);
    const updatedEvent = bus.published.find((p) => p.event.type === "schedule_updated");
    expect(updatedEvent).toBeDefined();
    expect(updatedEvent!.uid).toBe(uid);
    expect(updatedEvent!.event.scheduleId).toBe(created.id);
    expect(updatedEvent!.event.payload).toMatchObject({
      reason: "patched",
      schedule: { id: created.id, title: "patched" },
    });

    // Resume publishes reason "resumed".
    await app.inject({
      method: "PATCH",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(uid),
      payload: { status: "paused" },
    });
    bus.published.length = 0;
    await app.inject({
      method: "PATCH",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(uid),
      payload: { status: "pending" },
    });
    expect(bus.published.find((p) => p.event.type === "schedule_updated")!.event.payload).toMatchObject(
      { reason: "resumed" },
    );

    const deleted = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/schedules/${created.id}`,
      headers: authHeaders(uid),
    });
    expect(deleted.statusCode).toBe(204);
    const deletedEvent = bus.published.find((p) => p.event.type === "schedule_deleted");
    expect(deletedEvent).toBeDefined();
    expect(deletedEvent!.uid).toBe(uid);
    expect(deletedEvent!.event.scheduleId).toBe(created.id);
    expect(deletedEvent!.event.payload).toMatchObject({ scheduleId: created.id });
  });

  it("all schedule routes answer 401 unauthenticated", async () => {
    const created = await createSchedule(testUid("sched-401"));
    const requests = [
      { method: "POST" as const, url: "/cloud/v1/schedules", payload: createBody() },
      { method: "GET" as const, url: "/cloud/v1/schedules" },
      { method: "GET" as const, url: `/cloud/v1/schedules/${created.id}` },
      { method: "GET" as const, url: `/cloud/v1/schedules/${created.id}/runs` },
      { method: "PATCH" as const, url: `/cloud/v1/schedules/${created.id}`, payload: { title: "x" } },
      { method: "DELETE" as const, url: `/cloud/v1/schedules/${created.id}` },
    ];
    for (const req of requests) {
      const res = await app.inject({ ...req, headers: {} });
      expect(res.statusCode, req.url).toBe(401);
      expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
    }
  });
});
