import { Redis } from "ioredis";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createDb,
  eventMirror,
  messages,
  migrate,
  runs,
  sessions,
  users,
  type Db,
} from "@ovid/db";
import { createRedisEventLog, type EventLog } from "@ovid/events";
import type { SessionEvent } from "@ovid/shared";
import { sweepStaleRuns } from "./staleRuns.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

// Pinned PAST base (2023-11-14T22:13:20Z — the same fixed base @ovid/db's
// suite uses). Every seeded timestamp AND every injected clock lives in 2023,
// so all cutoffs this file computes are years before any real-clock row other
// suites leave behind (startedAt = actual now): count assertions stay exact on
// the shared dev DB regardless of leftovers, with no real waiting anywhere.
const BASE = 1_700_000_000_000;
const STALE_AFTER_MS = 600_000; // 10 min
const CLOCK = BASE + 30 * 60_000; // injected "now": 30 min after BASE
const CUTOFF = CLOCK - STALE_AFTER_MS; // BASE + 20 min (started_at < cutoff is STRICT)

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "sweepStaleRuns (real Postgres + real Redis event log)",
  () => {
    let db: Db;
    let redisQ: Redis;
    let events: EventLog;
    const createdSessions: string[] = [];
    const seededRuns: string[] = [];

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      redisQ = new Redis(TEST_REDIS_URL!);
      events = createRedisEventLog(redisQ);
    });

    afterAll(async () => {
      // Terminalize any row this file leaves in 'running' (ours only) — a
      // suite that tests stranded-run recovery must not strand rows itself,
      // or re-runs and real-clock sweeps would see its leftovers.
      for (const runId of seededRuns) {
        const row = await runRow(runId).catch(() => null);
        if (row?.status === "running") {
          await runs.finish(db, runId, "failed", "staleRuns.test cleanup").catch(() => {});
        }
      }
      // Only keys THIS file created (one event stream per seeded session).
      if (createdSessions.length > 0) {
        await redisQ
          .del(...createdSessions.map((id) => `sess:${id}:events`))
          .catch(() => {});
      }
      redisQ?.disconnect();
      await db?.$client.end({ timeout: 5 });
    });

    let counter = 0;
    function uid(prefix: string): string {
      counter += 1;
      return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random()
        .toString(36)
        .slice(2, 10)}`;
    }

    /** Run on a fresh user/session, moved to `state` with pinned timestamps. */
    async function seedRun(
      state: "queued" | "running" | "completed",
      opts: { startedAt?: Date; createdAt?: Date } = {},
    ): Promise<{ runId: string; sessionId: string }> {
      const userUid = uid("w9s");
      await users.ensure(db, userUid, `${userUid}@stub.test`);
      const session = await sessions.create(db, userUid);
      createdSessions.push(session.id);
      const prompt = await messages.append(db, {
        sessionId: session.id,
        role: "user",
        content: "go",
      });
      const run = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
      seededRuns.push(run.id);
      if (opts.createdAt !== undefined) {
        // postgres.js unsafe() binds raw values — pass the ISO string, not a Date.
        await db.$client.unsafe("UPDATE runs SET created_at = $1 WHERE id = $2", [
          opts.createdAt.toISOString(),
          run.id,
        ]);
      }
      if (state !== "queued") {
        expect(await runs.claimNext(db, run.id)).toBe(true); // sets startedAt = now
        if (opts.startedAt !== undefined) {
          await db.$client.unsafe("UPDATE runs SET started_at = $1 WHERE id = $2", [
            opts.startedAt.toISOString(),
            run.id,
          ]);
        }
      }
      if (state === "completed") await runs.finish(db, run.id, "completed");
      return { runId: run.id, sessionId: session.id };
    }

    async function runRow(
      runId: string,
    ): Promise<{ status: string; lastError: string | null }> {
      const rows = await db.$client.unsafe("SELECT status, last_error FROM runs WHERE id = $1", [
        runId,
      ]);
      const row = rows[0] as { status: string; last_error: string | null };
      return { status: row.status, lastError: row.last_error };
    }

    const sweep = (clockMs: number = CLOCK): Promise<number> =>
      sweepStaleRuns(
        { db, events, clock: () => new Date(clockMs) },
        { staleAfterMs: STALE_AFTER_MS },
      );

    const readEvents = (sessionId: string): Promise<SessionEvent[]> =>
      events.readSince(sessionId, null, 100);
    const readMirror = (sessionId: string): Promise<SessionEvent[]> =>
      eventMirror.readSince(db, sessionId, null, 100);

    it("stale running run → run_failed {runId, code:'run_lost'} in stream AND mirror, run failed with lastError, count 1", async () => {
      // startedAt 30 min before the injected clock (> 10 min threshold → stale).
      const stale = await seedRun("running", { startedAt: new Date(BASE) });

      expect(await sweep()).toBe(1);

      const evts = await readEvents(stale.sessionId);
      expect(evts.map((e) => e.type)).toEqual(["run_failed"]);
      expect(evts[0]!.sessionId).toBe(stale.sessionId);
      expect(evts[0]!.payload).toEqual({ runId: stale.runId, code: "run_lost" });
      // append+mirror, same emit pattern as the processor: rows match exactly
      expect(await readMirror(stale.sessionId)).toEqual(evts);
      expect(await runRow(stale.runId)).toEqual({
        status: "failed",
        lastError: "run_lost: stale sweep",
      });

      // Idempotent: the next sweep finds nothing (the row is terminal now).
      expect(await sweep()).toBe(0);
    });

    it("fresh running runs (including startedAt exactly AT the cutoff) → untouched, count 0, zero events", async () => {
      const fresh = await seedRun("running", { startedAt: new Date(CLOCK - 60_000) });
      // started_at < cutoff is STRICT: exactly at the cutoff is not stale.
      const boundary = await seedRun("running", { startedAt: new Date(CUTOFF) });

      expect(await sweep()).toBe(0);

      for (const seeded of [fresh, boundary]) {
        expect(await readEvents(seeded.sessionId)).toEqual([]);
        expect(await readMirror(seeded.sessionId)).toEqual([]);
        expect((await runRow(seeded.runId)).status).toBe("running");
      }
    });

    it("queued runs (even ancient) and finished runs are never swept", async () => {
      // Queued rows have startedAt NULL — age of createdAt must not matter.
      const queued = await seedRun("queued", { createdAt: new Date(BASE - 86_400_000) });
      const completed = await seedRun("completed", { startedAt: new Date(BASE - 86_400_000) });

      expect(await sweep()).toBe(0);

      expect((await runRow(queued.runId)).status).toBe("queued");
      expect((await runRow(completed.runId)).status).toBe("completed");
      expect(await readEvents(queued.sessionId)).toEqual([]);
      expect(await readEvents(completed.sessionId)).toEqual([]);
    });

    it("two stale running runs → both swept in one pass, count 2, each with its own run_failed", async () => {
      const a = await seedRun("running", { startedAt: new Date(BASE) });
      const b = await seedRun("running", { startedAt: new Date(BASE + 60_000) });

      expect(await sweep()).toBe(2);

      for (const seeded of [a, b]) {
        const evts = await readEvents(seeded.sessionId);
        expect(evts.map((e) => e.type)).toEqual(["run_failed"]);
        expect(evts[0]!.payload).toEqual({ runId: seeded.runId, code: "run_lost" });
        expect(await readMirror(seeded.sessionId)).toEqual(evts);
        expect((await runRow(seeded.runId)).status).toBe("failed");
      }
    });

    it("injected clock is authoritative: a run the REAL clock would call stale is fresh under the 2023 clock", async () => {
      // startedAt = BASE (Nov 2023): ~3 years stale under the real wall clock.
      const seeded = await seedRun("running", { startedAt: new Date(BASE) });
      // Injected now = BASE + 1 min with the 10 min threshold → cutoff is
      // 9 min BEFORE BASE → fresh. An implementation ignoring `clock` and
      // reading the wall clock would sweep this row (count ≥ 1).
      expect(await sweep(BASE + 60_000)).toBe(0);
      expect((await runRow(seeded.runId)).status).toBe("running");
      expect(await readEvents(seeded.sessionId)).toEqual([]);
    });
  },
);
