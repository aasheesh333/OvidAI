import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { eventMirror, messages, newId, runs, sessions, users, type Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import type { QueueServices } from "@ovid/queue";
import type { RunCancelResponse, SessionEvent } from "@ovid/shared";
import { runCancelResponseSchema } from "@ovid/shared";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  stubKeys,
  stubMint,
  stubTickets,
  stubVerifier,
  stubSystemBus,
} from "../test/stubs.js";

// Run-cancel routes (P8 Task 1). The harness mirrors messages.test.ts: real
// Postgres, Fastify inject, fresh gateway per test so stub behavior (failing
// remove) never leaks. The queue/event stubs here are LOCAL because they need
// surfaces test/stubs.ts does not provide: queues.agentRuns.remove (captured)
// and a recording EventLog.

const CANCELLED_PAYLOAD = { code: "cancelled", message: "Stopped by user." };

/**
 * QueueServices stub capturing add() AND remove() — remove is the cancel
 * endpoint's BullMQ best-effort. `failRemove` makes remove() reject (the
 * gateway must degrade to "cancelling", never 5xx).
 */
function stubQueuesWithRemove(behavior: { failRemove?: boolean } = {}): {
  queues: QueueServices;
  removes: string[];
} {
  const removes: string[] = [];
  const queues = {
    agentRuns: {
      add: async () => ({ id: "", name: "", data: undefined }),
      remove: async (jobId: string) => {
        if (behavior.failRemove) throw new Error("remove: job missing or locked");
        removes.push(jobId);
      },
      client: Promise.resolve({ ping: async () => "PONG" }),
    },
  } as unknown as QueueServices;
  return { queues, removes };
}

/**
 * Recording EventLog stand-in: append() hands back the SAME envelope shape the
 * real log produces (seq filled by the stub) so the route's append+mirror
 * pairing is assertable against eventMirror.readSince afterwards.
 */
function recordingEvents(): { events: EventLog; appended: SessionEvent[] } {
  const appended: SessionEvent[] = [];
  const events = {
    async append(sessionId: string, type: SessionEvent["type"], payload: Record<string, unknown>) {
      const event: SessionEvent = {
        sessionId,
        // Redis stream id shape "ms-sub" — readSince's ORDER BY splits on '-'
        // and casts both halves, so the stub must be shape-faithful here.
        seq: `${Date.now()}-${appended.length + 1}`,
        type,
        payload,
        ts: new Date().toISOString(),
      };
      appended.push(event);
      return event;
    },
    async readSince() {
      return appended;
    },
    async subscribe() {
      return async () => {};
    },
  } as unknown as EventLog;
  return { events, appended };
}

describe.skipIf(!TEST_DATABASE_URL)("gateway run-cancel routes (real postgres)", () => {
  let db: Db;
  const built: Array<{ app: FastifyInstance }> = [];

  beforeAll(async () => {
    db = await openTestDb();
  }, 60_000);

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.app.close();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  /** Fresh gateway per test (fresh stubs) so remove-failure behavior never leaks. */
  function makeApp(behavior: { failRemove?: boolean } = {}): {
    app: FastifyInstance;
    removes: string[];
    appended: SessionEvent[];
  } {
    const { queues, removes } = stubQueuesWithRemove(behavior);
    const { events, appended } = recordingEvents();
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events,
    });
    built.push({ app });
    return { app, removes, appended };
  }

  /** Queued run + owning session/user, the exact state POST /messages leaves. */
  async function seedQueuedRun(): Promise<{ uid: string; sessionId: string; runId: string }> {
    const uid = testUid("run-cancel");
    await users.ensure(db, uid, `${uid}@stub.test`);
    const session = await sessions.create(db, uid);
    const prompt = await messages.append(db, {
      sessionId: session.id,
      role: "user",
      content: "cancel me",
    });
    const run = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
    return { uid, sessionId: session.id, runId: run.id };
  }

  async function runRow(runId: string): Promise<{
    status: string;
    cancelRequested: boolean;
    lastError: string | null;
    finishedAt: Date | null;
  }> {
    const rows = await db.$client.unsafe(
      "SELECT status, cancel_requested, last_error, finished_at FROM runs WHERE id = $1",
      [runId],
    );
    // postgres.js rows are `Row & Iterable<Row>`; the SELECT projection above
    // is known, so cast through `unknown` to name it.
    const row = rows[0] as unknown as {
      status: string;
      cancel_requested: boolean;
      last_error: string | null;
      finished_at: Date | null;
    };
    return {
      status: row.status,
      cancelRequested: row.cancel_requested,
      lastError: row.last_error,
      finishedAt: row.finished_at,
    };
  }

  function cancel(app: FastifyInstance, uid: string, runId: string) {
    return app.inject({
      method: "POST",
      url: `/cloud/v1/runs/${runId}/cancel`,
      headers: authHeaders(uid),
    });
  }

  it("cancel a queued run → 202 cancelled; BullMQ job removed; run_failed{cancelled} appended AND mirrored; row terminal", async () => {
    const { app, removes, appended } = makeApp();
    const seeded = await seedQueuedRun();

    const res = await cancel(app, seeded.uid, seeded.runId);
    expect(res.statusCode).toBe(202);
    const body = runCancelResponseSchema.parse(res.json()) as RunCancelResponse;
    expect(body).toEqual({ runId: seeded.runId, status: "cancelled" });

    // The BullMQ job (jobId = runId) was removed.
    expect(removes).toEqual([seeded.runId]);

    // The run row is terminal with the cancelled verdict.
    expect(await runRow(seeded.runId)).toMatchObject({
      status: "cancelled",
      cancelRequested: true,
      lastError: "Stopped by user.",
      // $client.unsafe hands timestamps back as strings — non-null is the pin.
      finishedAt: expect.anything(),
    });
    expect((await runRow(seeded.runId)).finishedAt).not.toBeNull();

    // The EXISTING run_failed event type carries the cancelled payload, and
    // the append is mirrored to Postgres exactly like the worker does.
    expect(appended.map((e) => e.type)).toEqual(["run_failed"]);
    expect(appended[0]!.payload).toEqual(CANCELLED_PAYLOAD);
    expect(appended[0]!.sessionId).toBe(seeded.sessionId);
    expect(await eventMirror.readSince(db, seeded.sessionId, null, 50)).toEqual(appended);
  });

  it("cancel a running run (claim race) → 202 cancelling, flag set, row left for the worker; no run_failed event", async () => {
    const { app, removes, appended } = makeApp();
    const seeded = await seedQueuedRun();
    expect(await runs.claimNext(db, seeded.runId)).toBe(true); // a worker owns it

    const res = await cancel(app, seeded.uid, seeded.runId);
    expect(res.statusCode).toBe(202);
    expect(runCancelResponseSchema.parse(res.json())).toEqual({
      runId: seeded.runId,
      status: "cancelling",
    });

    // The row stays running — the worker's cancel check terminalizes it.
    expect(await runRow(seeded.runId)).toMatchObject({
      status: "running",
      cancelRequested: true,
      finishedAt: null,
    });
    // remove was attempted (best-effort); no terminal event was emitted here.
    expect(removes).toEqual([seeded.runId]);
    expect(appended).toEqual([]);
  });

  it("queued run but BullMQ remove fails → 202 cancelling (best-effort degrade), flag set, row still queued", async () => {
    const { app, removes, appended } = makeApp({ failRemove: true });
    const seeded = await seedQueuedRun();

    const res = await cancel(app, seeded.uid, seeded.runId);
    expect(res.statusCode).toBe(202);
    expect(runCancelResponseSchema.parse(res.json())).toEqual({
      runId: seeded.runId,
      status: "cancelling",
    });

    expect(await runRow(seeded.runId)).toMatchObject({
      status: "queued",
      cancelRequested: true,
      finishedAt: null,
    });
    expect(removes).toEqual([]);
    expect(appended).toEqual([]);
  });

  it("cancel a terminal run → 409 run_not_cancellable, flag never set, no remove, no event", async () => {
    const { app, removes, appended } = makeApp();
    const completed = await seedQueuedRun();
    expect(await runs.claimNext(db, completed.runId)).toBe(true);
    expect(await runs.finish(db, completed.runId, "completed")).toBe(true);

    const res = await cancel(app, completed.uid, completed.runId);
    expect(res.statusCode).toBe(409);
    expect(res.json()).toMatchObject({ error: { code: "run_not_cancellable" } });
    expect(typeof res.json().error.message).toBe("string");

    // The cancelled status is terminal too — same refusal.
    const cancelled = await seedQueuedRun();
    expect(await runs.claimNext(db, cancelled.runId)).toBe(true);
    expect(await runs.finish(db, cancelled.runId, "cancelled")).toBe(true);
    const again = await cancel(app, cancelled.uid, cancelled.runId);
    expect(again.statusCode).toBe(409);
    expect(again.json().error.code).toBe("run_not_cancellable");

    expect(await runRow(completed.runId)).toMatchObject({
      status: "completed",
      cancelRequested: false,
    });
    expect(removes).toEqual([]);
    expect(appended).toEqual([]);
  });

  it("wrong owner and unknown id → 404 not_found with the identical envelope (never 403)", async () => {
    const { app } = makeApp();
    const seeded = await seedQueuedRun();
    const stranger = testUid("run-stranger");

    const theirs = await cancel(app, stranger, seeded.runId);
    expect(theirs.statusCode).toBe(404);
    const unknown = await cancel(app, seeded.uid, newId());
    expect(unknown.statusCode).toBe(404);
    // Identical envelope — no existence leak between wrong-owner and unknown.
    expect(theirs.json()).toEqual(unknown.json());
    expect(theirs.json().error.code).toBe("not_found");

    // The wrong-owner probe touched nothing.
    expect(await runRow(seeded.runId)).toMatchObject({ status: "queued", cancelRequested: false });
  });
});

describe("gateway run-cancel routes without a database", () => {
  it("malformed :id → 404 not_found and the db is never touched (no Postgres 22P02)", async () => {
    // A db whose every property access throws: the shape guard must answer
    // before any repo call, or this test fails with the thrown error.
    const neverDb = new Proxy(
      {},
      {
        get() {
          throw new Error("deps.db must not be touched for a malformed :id");
        },
      },
    ) as unknown as Db;
    const { queues } = stubQueuesWithRemove();
    const { events } = recordingEvents();
    const app = buildGateway({
      system: stubSystemBus(),
      db: neverDb,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events,
    });
    try {
      for (const bad of ["not-a-uuid", "1234567", "9f8a7b6c5d4e3f2a1b0c9d8e"]) {
        const res = await app.inject({
          method: "POST",
          url: `/cloud/v1/runs/${bad}/cancel`,
          headers: authHeaders(testUid("run-badid")),
        });
        expect(res.statusCode, bad).toBe(404);
        expect(res.statusCode, `${bad} must never be a 500`).not.toBe(500);
        expect(res.json().error.code).toBe("not_found");
        // Route-level envelope (message proves the run route answered, not
        // Fastify's unmatched-route 404).
        expect(res.json().error.message).toBe("Run not found.");
      }
    } finally {
      await app.close();
    }
  });

  it("POST /runs/:id/cancel answers 401 unauthenticated with the shared envelope", async () => {
    const { queues } = stubQueuesWithRemove();
    const { events } = recordingEvents();
    const app = buildGateway({
      system: stubSystemBus(),
      db: {} as unknown as Db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events,
    });
    try {
      const res = await app.inject({
        method: "POST",
        url: `/cloud/v1/runs/${newId()}/cancel`,
        headers: {},
      });
      expect(res.statusCode).toBe(401);
      expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
    } finally {
      await app.close();
    }
  });
});
