import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  cancelSchedule,
  createDb,
  createSchedule,
  migrate,
  schedules,
  users,
  type Db,
} from "@ovid/db";
import type { SystemBus } from "@ovid/events";
import type { SystemEvent } from "@ovid/shared";
import {
  createScheduleTools,
  toCoreTools,
  type ScheduleTool,
  type ScheduleToolContext,
} from "./scheduleTools.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

// Fixed, injected clock — every expected ISO is computed, never wall-time.
const T0 = 1_600_000_000_000;
const iso = (ms: number): string => new Date(ms).toISOString();

/** Capturing SystemBus stub — records every published SystemEvent. */
function stubSystem(): { system: SystemBus; published: Array<{ uid: string; event: SystemEvent }> } {
  const published: Array<{ uid: string; event: SystemEvent }> = [];
  const system = {
    async publish(uid: string, event: SystemEvent) {
      published.push({ uid, event });
    },
    async subscribe() {
      return async () => {};
    },
  } as unknown as SystemBus;
  return { system, published };
}

function byName(tools: readonly ScheduleTool[]): Record<string, ScheduleTool> {
  return Object.fromEntries(tools.map((t) => [t.name, t]));
}

describe.skipIf(!TEST_DATABASE_URL)(
  "agent schedule tools (real Postgres, injected clock)",
  () => {
    let db: Db;
    const createdScheduleIds: string[] = [];
    let counter = 0;

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
    });

    afterEach(async () => {
      // Cancelled rows are invisible to the tools' list (default view), so
      // leftovers can never leak into another run's assertions.
      for (const scheduleId of createdScheduleIds.splice(0)) {
        await schedules.update(db, scheduleId, { status: "cancelled" }).catch(() => {});
      }
    });

    afterAll(async () => {
      await db?.$client.end({ timeout: 5 });
    });

    const uid = (prefix: string): string => {
      counter += 1;
      return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random()
        .toString(36)
        .slice(2, 10)}`;
    };

    const ctx = (userId: string): ScheduleToolContext => ({
      userId,
      // Deliberately bogus: a dedicated session must be materialized unless
      // the caller passes an explicit sessionId (case b).
      sessionId: "ctx-session-must-not-be-used",
    });

    function makeTools(clockMs = T0): {
      tools: ScheduleTool[];
      map: Record<string, ScheduleTool>;
      published: Array<{ uid: string; event: SystemEvent }>;
    } {
      const { system, published } = stubSystem();
      const tools = createScheduleTools({ db, system, clock: () => new Date(clockMs) });
      return { tools, map: byName(tools), published };
    }

    async function seedSchedule(
      userId: string,
      opts: {
        title?: string;
        trigger?: { kind: "every"; seconds: number } | { kind: "at"; at: string };
      } = {},
    ) {
      await users.ensure(db, userId, `${userId}@stub.test`);
      const row = await createSchedule(db, {
        userId,
        title: opts.title ?? "Morning",
        description: "check inbox",
        trigger: opts.trigger ?? { kind: "every", seconds: 300 },
        clock: () => new Date(T0),
      });
      createdScheduleIds.push(row.id);
      return row;
    }

    it("(a) create without confirmed persists NOTHING and echoes the parsed trigger", async () => {
      const userId = uid("t13a");
      const { map, published } = makeTools();

      const res = await map.schedule_create!.execute(
        {
          title: "Morning report",
          description: "check things",
          trigger: { kind: "every", seconds: 300 },
        },
        ctx(userId),
      );

      expect(res.isError).toBeFalsy();
      const structured = res.structured as {
        status: string;
        parsed: { title: string; nextRunAt: string; autonomy: string; maxRetries: number };
      };
      expect(structured.status).toBe("needs_confirmation");
      expect(structured.parsed.nextRunAt).toBe(iso(T0 + 300_000));
      expect(structured.parsed.autonomy).toBe("safe");
      expect(structured.parsed.maxRetries).toBe(0);
      expect(res.content).toContain("every 300 seconds");
      expect(res.content).toContain('Say "confirm"');

      // Nothing persisted — no schedule row, no bus event.
      const { rows } = await schedules.list(db, userId, { limit: 10 });
      expect(rows).toHaveLength(0);
      expect(published).toHaveLength(0);
    });

    it("(b) confirmed create persists, uses a dedicated session and publishes schedule_created", async () => {
      const userId = uid("t13b");
      await users.ensure(db, userId, `${userId}@stub.test`);
      const { map, published } = makeTools();

      const res = await map.schedule_create!.execute(
        {
          title: "Morning report",
          description: "check things",
          trigger: { kind: "every", seconds: 300 },
          confirmed: true,
        },
        ctx(userId),
      );

      expect(res.isError).toBeFalsy();
      expect(res.content).toContain("Schedule created:");
      const structured = res.structured as {
        status: string;
        schedule: { id: string; sessionId: string; title: string; status: string };
      };
      expect(structured.status).toBe("created");
      expect(structured.schedule.title).toBe("Morning report");
      expect(structured.schedule.status).toBe("pending");
      // Dedicated session — never the ctx session.
      expect(structured.schedule.sessionId).not.toBe("ctx-session-must-not-be-used");
      createdScheduleIds.push(structured.schedule.id);

      const row = await schedules.getById(db, structured.schedule.id);
      expect(row).not.toBeNull();

      expect(published).toHaveLength(1);
      expect(published[0]!.uid).toBe(userId);
      expect(published[0]!.event.type).toBe("schedule_created");
      expect(published[0]!.event.scheduleId).toBe(structured.schedule.id);
      expect(published[0]!.event.payload).toMatchObject({
        schedule: { id: structured.schedule.id },
      });
    });

    it("(c) free-tier cron is rejected in PREVIEW too (tier gate included)", async () => {
      const userId = uid("t13c");
      await users.ensure(db, userId, `${userId}@stub.test`);
      const { map, published } = makeTools();

      const res = await map.schedule_create!.execute(
        {
          title: "Cron job",
          description: "daily",
          trigger: { kind: "cron", expr: "0 9 * * *", tz: "UTC" },
        },
        ctx(userId),
      );

      expect(res.isError).toBe(true);
      expect(res.content).toBe("Cron schedules require Ovid Pro.");
      const { rows } = await schedules.list(db, userId, { limit: 10 });
      expect(rows).toHaveLength(0);
      expect(published).toHaveLength(0);
    });

    it("(d) list returns the caller's non-cancelled schedules", async () => {
      const userId = uid("t13d");
      const first = await seedSchedule(userId, { title: "First" });
      const second = await seedSchedule(userId, { title: "Second" });
      const cancelled = await seedSchedule(userId, { title: "Cancelled" });
      await cancelSchedule(db, { userId, scheduleId: cancelled.id });

      const { map } = makeTools();
      const res = await map.schedule_list!.execute({}, ctx(userId));

      expect(res.isError).toBeFalsy();
      const structured = res.structured as { schedules: Array<{ id: string; title: string }> };
      expect(structured.schedules).toHaveLength(2);
      expect(structured.schedules.map((s) => s.id).sort()).toEqual(
        [first.id, second.id].sort(),
      );
      expect(res.content).toContain("First");
      expect(res.content).toContain("Second");
      expect(res.content).not.toContain("Cancelled");
    });

    it("(e) update pauses the row and publishes schedule_updated", async () => {
      const userId = uid("t13e");
      const seeded = await seedSchedule(userId, { title: "Pausable" });
      const { map, published } = makeTools();

      const res = await map.schedule_update!.execute(
        { scheduleId: seeded.id, patch: { status: "paused" } },
        ctx(userId),
      );

      expect(res.isError).toBeFalsy();
      expect(res.content).toContain('Schedule updated: "Pausable".');
      const row = await schedules.getById(db, seeded.id);
      expect(row!.status).toBe("paused");
      expect(row!.pausedReason).toBe("user");

      expect(published).toHaveLength(1);
      expect(published[0]!.event.type).toBe("schedule_updated");
      expect(published[0]!.event.scheduleId).toBe(seeded.id);
      expect(published[0]!.event.payload).toMatchObject({ reason: "patched" });
    });

    it("(f) delete of someone else's id is not_found and leaves the row untouched", async () => {
      const ownerId = uid("t13f-owner");
      const otherId = uid("t13f-other");
      await users.ensure(db, otherId, `${otherId}@stub.test`);
      const seeded = await seedSchedule(ownerId, { title: "Owner's" });
      const { map, published } = makeTools();

      const res = await map.schedule_delete!.execute({ scheduleId: seeded.id }, ctx(otherId));

      expect(res.isError).toBe(true);
      expect(res.content).toBe("Schedule not found.");
      const row = await schedules.getById(db, seeded.id);
      expect(row!.status).toBe("pending");
      expect(published).toHaveLength(0);
    });

    it("(g) bad trigger JSON is rejected and persists nothing", async () => {
      const userId = uid("t13g");
      await users.ensure(db, userId, `${userId}@stub.test`);
      const { map, published } = makeTools();

      const res = await map.schedule_create!.execute(
        {
          title: "Too frequent",
          description: "nope",
          trigger: { kind: "every", seconds: 10 },
          confirmed: true,
        },
        ctx(userId),
      );

      expect(res.isError).toBe(true);
      expect(res.content).toMatch(/^Invalid arguments: /);
      const { rows } = await schedules.list(db, userId, { limit: 10 });
      expect(rows).toHaveLength(0);
      expect(published).toHaveLength(0);
    });

    it("(h) exposes exactly the four pinned tool names, in order", () => {
      const { tools } = makeTools();
      expect(tools.map((t) => t.name)).toEqual([
        "schedule_create",
        "schedule_list",
        "schedule_update",
        "schedule_delete",
      ]);
      for (const tool of tools) {
        expect(tool.description.length).toBeGreaterThan(0);
      }

      // P3 roster adaptation: canonical specs carry the same names and a
      // model-usable JSON Schema object.
      const core = toCoreTools(tools);
      expect(core.map((t) => t.spec.name)).toEqual(tools.map((t) => t.name));
      for (const tool of core) {
        expect(tool.spec.parameters).toMatchObject({ type: "object" });
        expect(tool.timeoutMs).toBe(120_000);
      }
    });
  },
);
