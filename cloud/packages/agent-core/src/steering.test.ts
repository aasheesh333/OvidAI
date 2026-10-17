// Steering queue (P3 Task 14) — TDD step 1.
//
// Cloud port of Dart's in-run queue drain (_drainQueueIntoMsgs,
// agent_service.dart AS:10399–10464) onto the run-row analog: the queue IS
// the `runs` table (status 'queued'). Ports the portable legs of
// test/queue_inject_run_test.dart (:140 delivery in order, :170 multiple
// messages together), test/queue_ids_test.dart (id analog: rows drain in
// (createdAt, id) order, each exactly once), test/queue_continuation_test.dart
// (:106 never fired into another session) — plus the cloud-only claim-race
// pin (Review Focus #5, no Dart analog: BullMQ did not exist there).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createDb,
  messages,
  migrate,
  runs,
  sessions,
  users,
  type Db,
  type RunRow,
} from "@ovid/db";
import type { SessionEventType } from "@ovid/shared";

import type { EventSink } from "./ports.js";
import { drainQueuedRuns } from "./steering.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

interface SinkEvent {
  type: SessionEventType;
  payload: Record<string, unknown>;
}

/**
 * Recording sink; `onEmit` runs inside the drain's await point, which lets a
 * test interleave a concurrent BullMQ claim at a REAL mid-drain moment.
 */
function recordingSink(
  onEmit?: (payload: Record<string, unknown>) => void | Promise<void>,
): { sink: EventSink; events: SinkEvent[] } {
  const events: SinkEvent[] = [];
  const sink: EventSink = {
    async emit(type, payload) {
      events.push({ type, payload });
      await onEmit?.(payload);
    },
  };
  return { sink, events };
}

describe.skipIf(!TEST_DATABASE_URL)("drainQueuedRuns (real postgres)", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  /** Fresh user + session per test (data isolation, approvals.test.ts convention). */
  async function seedSession(): Promise<{ userId: string; sessionId: string }> {
    const uid = `st-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    await users.ensure(db, uid, null);
    const row = await sessions.create(db, uid, null);
    return { userId: uid, sessionId: row.id };
  }

  /** Gateway shape: persist the prompt row, THEN create the queued run referencing it. */
  async function seedRun(sessionId: string, prompt: string): Promise<RunRow> {
    const msg = await messages.append(db, { sessionId, role: "user", content: prompt });
    return runs.create(db, { sessionId, promptMessageId: msg.id });
  }

  async function statusOf(runId: string, userId: string): Promise<string> {
    const row = await runs.get(db, runId, userId);
    return row!.status;
  }

  it("drains two queued runs in queue order: prompts injected as user rows, rows completed, one run_merged note each (queue_inject :140/:170, queue_ids order)", async () => {
    const { userId, sessionId } = await seedSession();
    const active = await seedRun(sessionId, "active prompt");
    expect(await runs.claimNext(db, active.id)).toBe(true); // the engine's claim
    const q1 = await seedRun(sessionId, "first queued");
    const q2 = await seedRun(sessionId, "second queued");
    const { sink, events } = recordingSink();

    const injected = await drainQueuedRuns({ db, sink }, { sessionId, activeRunId: active.id });

    expect(injected).toEqual([
      { role: "user", content: "first queued" },
      { role: "user", content: "second queued" },
    ]);
    expect(events.map((e) => e.type)).toEqual(["system_note", "system_note"]);
    expect(events[0]!.payload).toEqual({
      code: "run_merged",
      mergedRunId: q1.id,
      runId: active.id,
    });
    expect(events[1]!.payload).toEqual({
      code: "run_merged",
      mergedRunId: q2.id,
      runId: active.id,
    });
    expect(await statusOf(q1.id, userId)).toBe("completed");
    expect(await statusOf(q2.id, userId)).toBe("completed");
    expect(await statusOf(active.id, userId)).toBe("running"); // the absorbing run is untouched

    // Each queued run merges EXACTLY once (queue_ids stable-id analog):
    // everything is terminal now, so a second drain is a no-op.
    const again = await drainQueuedRuns({ db, sink }, { sessionId, activeRunId: active.id });
    expect(again).toEqual([]);
    expect(events).toHaveLength(2);
  });

  it("claim race: a queued run pre-claimed by a concurrent BullMQ delivery is skipped — no message, no merge note (Review Focus #5)", async () => {
    const { userId, sessionId } = await seedSession();
    const active = await seedRun(sessionId, "active prompt");
    await runs.claimNext(db, active.id);
    const q1 = await seedRun(sessionId, "first queued");
    const q2 = await seedRun(sessionId, "second queued");
    // The delivery for q2 wins the claim BEFORE the drain lists the queue.
    expect(await runs.claimNext(db, q2.id)).toBe(true);

    const { sink, events } = recordingSink();
    const injected = await drainQueuedRuns({ db, sink }, { sessionId, activeRunId: active.id });

    expect(injected).toEqual([{ role: "user", content: "first queued" }]);
    expect(events.map((e) => e.payload.mergedRunId)).toEqual([q1.id]); // no note for q2
    // q2 belongs to the winning delivery — the drain never terminalizes it.
    expect(await statusOf(q2.id, userId)).toBe("running");
    expect(await statusOf(q1.id, userId)).toBe("completed");
  });

  it("claim race mid-drain: a delivery claiming BETWEEN the list and the claim loses nothing — the drain skips it silently", async () => {
    const { userId, sessionId } = await seedSession();
    const active = await seedRun(sessionId, "active prompt");
    await runs.claimNext(db, active.id);
    const q1 = await seedRun(sessionId, "first queued");
    const q2 = await seedRun(sessionId, "second queued");
    // Interleave at a real await point INSIDE the drain: while q1's merge
    // note is being emitted, a concurrent BullMQ delivery claims q2.
    const { sink, events } = recordingSink(async (payload) => {
      if (payload.code === "run_merged" && payload.mergedRunId === q1.id) {
        await runs.claimNext(db, q2.id);
      }
    });

    const injected = await drainQueuedRuns({ db, sink }, { sessionId, activeRunId: active.id });

    expect(injected).toEqual([{ role: "user", content: "first queued" }]);
    expect(events).toHaveLength(1); // exactly one merge note — none for q2
    expect(await statusOf(q2.id, userId)).toBe("running"); // untouched by the drain
    expect(await statusOf(q1.id, userId)).toBe("completed");
  });

  it("empty queue: [] and zero writes — no claims, no events, no status flips", async () => {
    const { userId, sessionId } = await seedSession();
    const active = await seedRun(sessionId, "active prompt");
    await runs.claimNext(db, active.id);
    const { sink, events } = recordingSink();

    const injected = await drainQueuedRuns({ db, sink }, { sessionId, activeRunId: active.id });

    expect(injected).toEqual([]);
    expect(events).toEqual([]);
    expect(await statusOf(active.id, userId)).toBe("running");
  });

  it("the active run itself is never drained, even if it were still 'queued' (the id != activeRunId exclusion)", async () => {
    const { userId, sessionId } = await seedSession();
    // Left 'queued' on purpose: the engine claims before the loop starts, but
    // the exclusion must hold structurally, not by status luck.
    const active = await seedRun(sessionId, "active prompt");
    const other = await seedRun(sessionId, "other queued");
    const { sink, events } = recordingSink();

    const injected = await drainQueuedRuns({ db, sink }, { sessionId, activeRunId: active.id });

    expect(injected).toEqual([{ role: "user", content: "other queued" }]);
    expect(events.map((e) => e.payload.mergedRunId)).toEqual([other.id]);
    expect(await statusOf(active.id, userId)).toBe("queued"); // never claimed, never merged
    expect(await statusOf(other.id, userId)).toBe("completed");
  });

  it("queued runs of OTHER sessions are never drained into this one (queue_continuation :106 isolation)", async () => {
    const a = await seedSession();
    const b = await seedSession();
    const active = await seedRun(a.sessionId, "active prompt");
    await runs.claimNext(db, active.id);
    const foreign = await seedRun(b.sessionId, "foreign queued");
    const { sink, events } = recordingSink();

    const injected = await drainQueuedRuns({ db, sink }, { sessionId: a.sessionId, activeRunId: active.id });

    expect(injected).toEqual([]);
    expect(events).toEqual([]);
    expect(await statusOf(foreign.id, b.userId)).toBe("queued"); // untouched
  });
});
