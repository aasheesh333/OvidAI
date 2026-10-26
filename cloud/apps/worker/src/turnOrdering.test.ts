import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { sql } from "drizzle-orm";
import {
  admitTurn,
  claimSteerTurn,
  claimTurn,
  createDb,
  listTurns,
  messages,
  migrate,
  newId,
  recoverInFlightTurn,
  resumeTurn,
  runs,
  sessions,
  stopTurn,
  TurnOrderingError,
  users,
  type Db,
} from "@ovid/db";
import {
  createMigrationScratch,
  type MigrationScratch,
} from "../../../packages/db/src/migrationTestKit.js";

// A1/A2 current-turn primitives — REAL Postgres. Every case runs against an
// isolated migrated database (createMigrationScratch), not a fake: the
// monotonic sequence, the Stop fence and crash recovery are all claims about
// durable state, so only a real server can prove them.

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

interface RunStateRow {
  status: string;
  cancel_requested: boolean;
  started_at: Date | null;
  last_active_at: Date | null;
}

describe.skipIf(!TEST_DATABASE_URL)("current-turn ordering (real postgres)", () => {
  let scratch: MigrationScratch;
  let db: Db;
  let counter = 0;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "a12_turn_ordering");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 12 });
  }, 120_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  async function seedSession(): Promise<{ userId: string; sessionId: string }> {
    const uid = `a12-${Date.now().toString(36)}-${(counter += 1).toString(36)}`;
    await users.ensure(db, uid, null);
    const session = await sessions.create(db, uid, null);
    return { userId: uid, sessionId: session.id };
  }

  async function prompt(sessionId: string, content: string): Promise<string> {
    const row = await messages.append(db, { sessionId, role: "user", content });
    return row.id;
  }

  async function admit(
    sessionId: string,
    content: string,
  ): Promise<Awaited<ReturnType<typeof admitTurn>>> {
    const promptMessageId = await prompt(sessionId, content);
    return admitTurn(db, { sessionId, promptMessageId });
  }

  async function state(runId: string): Promise<RunStateRow> {
    const rows = (await db.execute(sql`
      SELECT status, cancel_requested, started_at, last_active_at
        FROM runs WHERE id = ${runId}
    `)) as unknown as RunStateRow[];
    return rows[0]!;
  }

  it("admits gap-free per-session sequences and replays the same prompt without a second turn", async () => {
    const a = await seedSession();
    const b = await seedSession();

    const t1 = await admit(a.sessionId, "one");
    const t2 = await admit(a.sessionId, "two");
    const t3 = await admit(a.sessionId, "three");
    expect([t1.seq, t2.seq, t3.seq]).toEqual([1, 2, 3]);
    expect([t1.status, t2.status, t3.status]).toEqual(["queued", "queued", "queued"]);
    expect(t2.createdAt.getTime()).toBeGreaterThan(t1.createdAt.getTime());
    expect(t3.createdAt.getTime()).toBeGreaterThan(t2.createdAt.getTime());

    // Replay: the same prompt maps to the same turn, never a duplicate row.
    const replay = await admitTurn(db, {
      sessionId: a.sessionId,
      promptMessageId: t2.promptMessageId!,
    });
    expect(replay.runId).toBe(t2.runId);
    expect(replay.seq).toBe(2);
    expect((await listTurns(db, a.sessionId)).map((t) => t.runId)).toEqual([
      t1.runId,
      t2.runId,
      t3.runId,
    ]);

    // Sequences are per session, not global.
    expect((await admit(b.sessionId, "other")).seq).toBe(1);
  });

  it("fails closed when the prompt row is missing or belongs to another session", async () => {
    const a = await seedSession();
    const b = await seedSession();

    await expect(
      admitTurn(db, { sessionId: a.sessionId, promptMessageId: newId() }),
    ).rejects.toBeInstanceOf(TurnOrderingError);

    const foreign = await prompt(b.sessionId, "foreign prompt");
    await expect(
      admitTurn(db, { sessionId: a.sessionId, promptMessageId: foreign }),
    ).rejects.toMatchObject({ code: "prompt_missing" });

    // No turn was admitted for the failed attempts.
    expect(await listTurns(db, a.sessionId)).toEqual([]);
  });

  it("survives a process restart: the sequence is re-derived and keeps increasing", async () => {
    const a = await seedSession();
    const t1 = await admit(a.sessionId, "before restart 1");
    const t2 = await admit(a.sessionId, "before restart 2");

    const restarted = createDb(scratch.url, { max: 4 });
    try {
      expect(
        (await listTurns(restarted, a.sessionId)).map((t) => [t.runId, t.seq]),
      ).toEqual([
        [t1.runId, 1],
        [t2.runId, 2],
      ]);

      const promptMessageId = await prompt(a.sessionId, "after restart");
      const t3 = await admitTurn(restarted, { sessionId: a.sessionId, promptMessageId });
      expect(t3.seq).toBe(3);
      expect(t3.createdAt.getTime()).toBeGreaterThan(t2.createdAt.getTime());
    } finally {
      await restarted.$client.end({ timeout: 5 });
    }
  });

  it("claims turns strictly in accepted order and refuses to skip ahead", async () => {
    const a = await seedSession();
    const t1 = await admit(a.sessionId, "first");
    const t2 = await admit(a.sessionId, "second");

    const skipped = await claimTurn(db, { sessionId: a.sessionId, runId: t2.runId });
    expect(skipped.kind).toBe("not_oldest");
    if (skipped.kind === "not_oldest") expect(skipped.blocking.runId).toBe(t1.runId);
    expect((await state(t2.runId)).status).toBe("queued");

    const first = await claimTurn(db, { sessionId: a.sessionId, runId: t1.runId });
    expect(first.kind).toBe("claimed");
    expect((await state(t1.runId)).status).toBe("running");
    expect((await state(t1.runId)).started_at).not.toBeNull();

    // Duplicate delivery of the executing turn is not a second claim.
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: t1.runId })).kind).toBe(
      "already_running",
    );
    // The successor still waits for the active turn.
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: t2.runId })).kind).toBe(
      "not_oldest",
    );

    await runs.finish(db, t1.runId, "completed");
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: t2.runId })).kind).toBe(
      "claimed",
    );
  });

  it("never executes a turn carrying a durable Stop flag", async () => {
    const a = await seedSession();
    const t = await admit(a.sessionId, "stop me");

    expect((await stopTurn(db, { sessionId: a.sessionId, expectedRunId: t.runId })).kind).toBe(
      "stopped",
    );
    expect((await state(t.runId)).cancel_requested).toBe(true);

    expect((await claimTurn(db, { sessionId: a.sessionId, runId: t.runId })).kind).toBe(
      "cancelled",
    );
    // The claim wrote nothing: the waiter still owns the event-first terminal flip.
    expect((await state(t.runId)).status).toBe("queued");
    expect((await state(t.runId)).started_at).toBeNull();
  });

  it("fails closed instead of guessing when durable turn state is ambiguous", async () => {
    const a = await seedSession();
    const t1 = await admit(a.sessionId, "one");
    const t2 = await admit(a.sessionId, "two");
    await db.$client.unsafe("UPDATE runs SET status = 'running' WHERE id = $1", [t1.runId]);
    await db.$client.unsafe("UPDATE runs SET status = 'running' WHERE id = $1", [t2.runId]);
    expect(await claimTurn(db, { sessionId: a.sessionId, runId: t1.runId })).toMatchObject({
      kind: "ambiguous",
      reason: "multiple_running",
    });
    expect((await state(t1.runId)).status).toBe("running");
    expect((await state(t2.runId)).status).toBe("running");

    const b = await seedSession();
    const queued = await admit(b.sessionId, "queued first");
    const newer = await admit(b.sessionId, "running later");
    await db.$client.unsafe("UPDATE runs SET status = 'running' WHERE id = $1", [newer.runId]);
    expect(await claimTurn(db, { sessionId: b.sessionId, runId: queued.runId })).toMatchObject({
      kind: "ambiguous",
      reason: "newer_turn_running",
    });
    expect((await state(queued.runId)).status).toBe("queued");
  });

  it("Stop is idempotent and, by default, flags only the turn it names", async () => {
    const a = await seedSession();
    const t1 = await admit(a.sessionId, "one");
    const t2 = await admit(a.sessionId, "two");

    expect((await stopTurn(db, { sessionId: a.sessionId, expectedRunId: t1.runId })).kind).toBe(
      "stopped",
    );
    expect((await state(t1.runId)).cancel_requested).toBe(true);
    expect((await state(t2.runId)).cancel_requested).toBe(false);

    expect(
      (await stopTurn(db, { sessionId: a.sessionId, expectedRunId: t1.runId })).kind,
    ).toBe("already_requested");

    await runs.finish(db, t1.runId, "cancelled", "Stopped by user.");
    expect(
      (await stopTurn(db, { sessionId: a.sessionId, expectedRunId: t1.runId })).kind,
    ).toBe("already_stopped");
  });

  it("cannot let a stale Stop kill a newer turn", async () => {
    const a = await seedSession();
    const old = await admit(a.sessionId, "old");
    expect((await stopTurn(db, { sessionId: a.sessionId, expectedRunId: old.runId })).kind).toBe(
      "stopped",
    );
    await runs.finish(db, old.runId, "cancelled", "Stopped by user.");

    const newer = await admit(a.sessionId, "newer");
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: newer.runId })).kind).toBe(
      "claimed",
    );
    const before = await state(newer.runId);

    // A delayed/retried Stop for the finished turn mutates nothing.
    expect((await stopTurn(db, { sessionId: a.sessionId, expectedRunId: old.runId })).kind).toBe(
      "already_stopped",
    );
    // A Stop whose sequence view is stale is refused without a write.
    expect(
      await stopTurn(db, {
        sessionId: a.sessionId,
        expectedRunId: newer.runId,
        expectedSeq: 1,
      }),
    ).toMatchObject({ kind: "stale", reason: "sequence_mismatch" });
    // An unknown turn is refused, not guessed.
    expect(
      (await stopTurn(db, { sessionId: a.sessionId, expectedRunId: newId() })).kind,
    ).toBe("unknown");

    const after = await state(newer.runId);
    expect(after.status).toBe("running");
    expect(after.cancel_requested).toBe(false);
    expect(after.started_at).toEqual(before.started_at);
  });

  it("refuses a completed turn and leaves its live successor alone", async () => {
    const a = await seedSession();
    const done = await admit(a.sessionId, "done");
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: done.runId })).kind).toBe(
      "claimed",
    );
    await runs.finish(db, done.runId, "completed");

    const live = await admit(a.sessionId, "live");
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: live.runId })).kind).toBe(
      "claimed",
    );

    expect((await stopTurn(db, { sessionId: a.sessionId, expectedRunId: done.runId })).kind).toBe(
      "not_active",
    );
    expect(await state(live.runId)).toMatchObject({
      status: "running",
      cancel_requested: false,
    });
  });

  it("can fence already-accepted queued successors without stealing their terminal transition", async () => {
    const a = await seedSession();
    const t1 = await admit(a.sessionId, "active");
    const t2 = await admit(a.sessionId, "queued");
    const t3 = await admit(a.sessionId, "queued later");
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: t1.runId })).kind).toBe(
      "claimed",
    );

    const result = await stopTurn(db, {
      sessionId: a.sessionId,
      expectedRunId: t1.runId,
      cancelQueuedSuccessors: true,
    });
    expect(result.kind).toBe("stopped");
    for (const turn of [t1, t2, t3]) {
      expect((await state(turn.runId)).cancel_requested).toBe(true);
    }
    // Still queued: the flag is the fence, the waiter owns the terminal flip.
    expect((await state(t2.runId)).status).toBe("queued");
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: t2.runId })).kind).toBe(
      "cancelled",
    );
  });

  it("re-derives the in-flight turn after a crash and resumes it without duplicating", async () => {
    const a = await seedSession();
    const t1 = await admit(a.sessionId, "crashed");
    const t2 = await admit(a.sessionId, "queued behind");
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: t1.runId })).kind).toBe(
      "claimed",
    );

    // Simulate the claiming process dying without terminalizing: two fresh
    // connections see only durable rows.
    const crashed = createDb(scratch.url, { max: 4 });
    const restarted = createDb(scratch.url, { max: 4 });
    try {
      const recovered = await recoverInFlightTurn(crashed, a.sessionId);
      expect(recovered.kind).toBe("in_flight");
      if (recovered.kind === "in_flight") {
        expect(recovered.turn.runId).toBe(t1.runId);
        expect(recovered.turn.seq).toBe(1);
        expect(recovered.queued.map((t) => [t.runId, t.seq])).toEqual([[t2.runId, 2]]);
      }

      const first = await resumeTurn(crashed, {
        sessionId: a.sessionId,
        expectedRunId: t1.runId,
        expectedSeq: 1,
      });
      expect(first.kind).toBe("resumed");
      expect((await state(t1.runId)).last_active_at).not.toBeNull();
      // Idempotent replay on a second connection.
      expect(
        (await resumeTurn(restarted, { sessionId: a.sessionId, expectedRunId: t1.runId })).kind,
      ).toBe("resumed");

      // Exactly one run row per prompt: recovery never creates a second turn.
      const counted = (await crashed.execute(sql`
        SELECT count(*)::int AS n FROM runs WHERE prompt_message_id = ${t1.promptMessageId}
      `)) as unknown as Array<{ n: number }>;
      expect(counted[0]!.n).toBe(1);
      expect(await recoverInFlightTurn(restarted, a.sessionId)).toMatchObject({
        kind: "in_flight",
        turn: { runId: t1.runId },
      });

      await runs.finish(db, t1.runId, "completed");
      expect(await recoverInFlightTurn(db, a.sessionId)).toMatchObject({
        kind: "pending",
        turn: { runId: t2.runId, seq: 2 },
      });
      await runs.finish(db, t2.runId, "completed");
      expect((await recoverInFlightTurn(db, a.sessionId)).kind).toBe("none");
    } finally {
      await crashed.$client.end({ timeout: 5 });
      await restarted.$client.end({ timeout: 5 });
    }
  });

  it("fails closed when recovery cannot prove which turn was in flight", async () => {
    const a = await seedSession();
    const t1 = await admit(a.sessionId, "one");
    const t2 = await admit(a.sessionId, "two");

    // A running successor with a queued predecessor: the queue inverted.
    await db.$client.unsafe("UPDATE runs SET status = 'running' WHERE id = $1", [t2.runId]);
    expect(await recoverInFlightTurn(db, a.sessionId)).toMatchObject({
      kind: "ambiguous",
      reason: "running_behind_queued",
    });

    // Two running turns: no way to pick the owner of the turn.
    await db.$client.unsafe("UPDATE runs SET status = 'running' WHERE id = $1", [t1.runId]);
    expect(await recoverInFlightTurn(db, a.sessionId)).toMatchObject({
      kind: "ambiguous",
      reason: "multiple_running",
    });

    // A running turn whose prompt row vanished is not recoverable.
    const b = await seedSession();
    const orphan = await admit(b.sessionId, "orphan");
    await db.$client.unsafe("UPDATE runs SET status = 'running' WHERE id = $1", [orphan.runId]);
    await db.$client.unsafe("DELETE FROM messages WHERE id = $1", [orphan.promptMessageId]);
    expect(await recoverInFlightTurn(db, b.sessionId)).toMatchObject({
      kind: "ambiguous",
      reason: "missing_prompt",
    });
    expect(
      (await resumeTurn(db, { sessionId: b.sessionId, expectedRunId: orphan.runId })).kind,
    ).toBe("ambiguous");

    // Ambiguity never mutated the rows.
    expect((await state(t1.runId)).status).toBe("running");
    expect((await state(t2.runId)).status).toBe("running");
  });

  it("steers queued turns strictly in accepted order and closes after Stop", async () => {
    const a = await seedSession();
    const active = await admit(a.sessionId, "active");
    const q1 = await admit(a.sessionId, "q1");
    const q2 = await admit(a.sessionId, "q2");
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: active.runId })).kind).toBe(
      "claimed",
    );

    expect(
      await claimSteerTurn(db, {
        sessionId: a.sessionId,
        activeRunId: active.runId,
        runId: q2.runId,
      }),
    ).toMatchObject({ kind: "not_next", next: { runId: q1.runId } });

    expect(
      (await claimSteerTurn(db, {
        sessionId: a.sessionId,
        activeRunId: active.runId,
        runId: q1.runId,
      })).kind,
    ).toBe("claimed");
    await runs.finish(db, q1.runId, "completed");
    expect(
      (await claimSteerTurn(db, {
        sessionId: a.sessionId,
        activeRunId: active.runId,
        runId: q2.runId,
      })).kind,
    ).toBe("claimed");
    await runs.finish(db, q2.runId, "completed");

    // Stop on the absorber closes steering immediately.
    const b = await seedSession();
    const activeB = await admit(b.sessionId, "active");
    const queuedB = await admit(b.sessionId, "queued");
    expect((await claimTurn(db, { sessionId: b.sessionId, runId: activeB.runId })).kind).toBe(
      "claimed",
    );
    await stopTurn(db, { sessionId: b.sessionId, expectedRunId: activeB.runId });
    expect(
      (await claimSteerTurn(db, {
        sessionId: b.sessionId,
        activeRunId: activeB.runId,
        runId: queuedB.runId,
      })).kind,
    ).toBe("stopped");
    expect((await state(queuedB.runId)).status).toBe("queued");

    // A stopped queued candidate is never merged, and steering does not skip it.
    const c = await seedSession();
    const activeC = await admit(c.sessionId, "active");
    const stopped = await admit(c.sessionId, "stopped");
    const later = await admit(c.sessionId, "later");
    expect((await claimTurn(db, { sessionId: c.sessionId, runId: activeC.runId })).kind).toBe(
      "claimed",
    );
    await stopTurn(db, { sessionId: c.sessionId, expectedRunId: stopped.runId });
    expect(
      (await claimSteerTurn(db, {
        sessionId: c.sessionId,
        activeRunId: activeC.runId,
        runId: stopped.runId,
      })).kind,
    ).toBe("cancelled");
    expect(
      await claimSteerTurn(db, {
        sessionId: c.sessionId,
        activeRunId: activeC.runId,
        runId: later.runId,
      }),
    ).toMatchObject({ kind: "not_next", next: { runId: stopped.runId } });
    expect((await state(later.runId)).status).toBe("queued");
  });

  it("scheduled run admitted while an earlier turn is active is ordered after it", async () => {
    const a = await seedSession();
    const first = await admit(a.sessionId, "first");

    // Claim the first turn so it is active when the scheduled run is admitted.
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: first.runId })).kind).toBe(
      "claimed",
    );

    // Simulate the fixed scheduler path: a run created inside a multi-statement
    // transaction must still admit through the ordering primitive. Before the fix
    // the scheduler used runs.create with defaultNow() (transaction-start time),
    // which could order a scheduled run before a turn admitted while the tx was
    // open and then drop it as newer_turn_running.
    const scheduledPrompt = await prompt(a.sessionId, "scheduled");
    const scheduled = await db.transaction(async (tx) => {
      return admitTurn(tx as unknown as Db, {
        sessionId: a.sessionId,
        promptMessageId: scheduledPrompt,
      });
    });
    expect(scheduled.seq).toBe(first.seq + 1);
    expect(scheduled.createdAt.getTime()).toBeGreaterThan(first.createdAt.getTime());

    // The scheduled turn is the next in line; no newer_turn_running ambiguity.
    await runs.finish(db, first.runId, "completed");
    expect((await claimTurn(db, { sessionId: a.sessionId, runId: scheduled.runId })).kind).toBe(
      "claimed",
    );
  });
});
