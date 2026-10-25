import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { SessionEvent } from "@ovid/shared";
import { createDb, migrate, type Db } from "./client.js";
import {
  appendExactItem,
  createCompactionRepository,
  readExactHistory,
  type CompactionActor,
  type CompactionMessage,
  type FoldCheckpointInput,
} from "./compactionRepos.js";
import {
  attachments,
  eventMirror,
  lockCompactionSession,
  messages,
  newId,
  runs,
  sessionState,
  sessions,
  users as usersRepo,
} from "./repos.js";
import { admitDispatches } from "./subagentAdmission.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

function ev(sessionId: string, seq: string, type: string, payload: Record<string, unknown>, ts: Date): SessionEvent {
  return { sessionId, seq, type: type as SessionEvent["type"], payload, ts: ts.toISOString() };
}

describe.skipIf(!TEST_DATABASE_URL)("Wave 1b repos (history window, truncate, branch, attachment links)", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function freshSession(): Promise<{ uid: string; sessionId: string }> {
    const uid = newId();
    await usersRepo.ensure(db, uid, null);
    const s = await sessions.create(db, uid, "t");
    return { uid, sessionId: s.id };
  }

  async function freshRoot(label: string) {
    const fixture = await freshSession();
    const prompt = await messages.append(db, {
      sessionId: fixture.sessionId,
      role: "user",
      content: `${label} root`,
    });
    const root = await runs.create(db, { sessionId: fixture.sessionId, promptMessageId: prompt.id });
    expect(await runs.claimNext(db, root.id)).toBe(true);
    return { ...fixture, prompt, rootTaskRunId: root.id };
  }

  async function prepareCompaction(actor: CompactionActor, label: string) {
    const durable: Array<CompactionMessage & { id: string }> = [];
    for (let index = 0; index < 10; index += 1) {
      const role = index % 2 === 0 ? "user" as const : "assistant" as const;
      const row = await messages.append(db, {
        sessionId: actor.sessionId,
        role,
        content: `${label}-${index}-${"x".repeat(400)}`,
      });
      durable.push({ id: row.id, role, content: row.content });
    }
    const input: FoldCheckpointInput = {
      actor,
      messages: durable,
      profile: {
        model: "truncation-fence-test",
        contextLimit: 1_000,
        outputReserveTokens: 100,
        providerReserveTokens: 10,
      },
      usage: { usageSource: "measured", beforeTokens: 800 },
    };
    return { actor, durable, input };
  }

  async function compactActor(actor: CompactionActor, label: string) {
    const prepared = await prepareCompaction(actor, label);
    const outcome = await createCompactionRepository(db).foldCheckpoint(prepared.input);
    expect(outcome.compacted).toBe(true);
    return { ...prepared, outcome };
  }

  async function compactMain(label: string) {
    const fixture = await freshRoot(label);
    const compacted = await compactActor(mainActor(fixture), label);
    return { ...fixture, ...compacted };
  }

  async function compactionSnapshot(sessionId: string) {
    const cursors = await db.$client`
      SELECT root_task_run_id, actor_kind, actor_id, checkpoint_id, compaction_id,
             cutoff_cursor, cutoff_message_id, ledger_version, pending_recall_cursor
        FROM compaction_cursors
       WHERE session_id = ${sessionId}
       ORDER BY root_task_run_id, actor_kind, actor_id`;
    const checkpoints = await db.$client`
      SELECT checkpoint_id, compaction_id, root_task_run_id, actor_kind, actor_id,
             previous_checkpoint_id, request_digest, cutoff_cursor, cutoff_message_id, ledger_version
        FROM compaction_checkpoints
       WHERE session_id = ${sessionId}
       ORDER BY checkpoint_id`;
    const history = await db.$client`
      SELECT position::text AS position, root_task_run_id, logical_worker_id, attempt_id,
             kind, stable_id, event_cursor, object_ref,
             inline_payload IS NOT NULL AS has_inline_payload
        FROM compaction_history_items
       WHERE session_id = ${sessionId}
       ORDER BY position`;
    return { cursors, checkpoints, history };
  }

  async function within<T>(promise: Promise<T>, label: string, timeoutMs = 5_000): Promise<T> {
    let timer: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        promise,
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), timeoutMs);
        }),
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  function mainActor(fixture: { sessionId: string; rootTaskRunId: string }): CompactionActor {
    return {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: null,
      attemptId: null,
      kind: "main",
    };
  }

  it("maxSeq / readWindow / deltasForRun order numerically and honour the bounds", async () => {
    const { sessionId } = await freshSession();
    expect(await eventMirror.maxSeq(db, sessionId)).toBeNull();
    const t0 = new Date("2026-01-01T00:00:00Z");
    const at = (s: number) => new Date(t0.getTime() + s * 1000);
    await eventMirror.put(db, ev(sessionId, "999-0", "run_started", { runId: "r1" }, at(1)));
    await eventMirror.put(db, ev(sessionId, "999-1", "message_delta", { runId: "r1", text: "a" }, at(2)));
    await eventMirror.put(db, ev(sessionId, "1000-0", "tool_started", { runId: "r1", callId: "c" }, at(3)));
    await eventMirror.put(db, ev(sessionId, "1000-1", "message_delta", { runId: "r1", text: "b" }, at(4)));
    await eventMirror.put(db, ev(sessionId, "1000-2", "message_delta", { runId: "r2", text: "x" }, at(4)));
    await eventMirror.put(db, ev(sessionId, "1001-0", "run_completed", { runId: "r1" }, at(5)));
    expect(await eventMirror.maxSeq(db, sessionId)).toBe("1001-0");

    const all = await eventMirror.readWindow(db, sessionId, { fromTs: null, toTs: null, maxSeq: null, limit: 100 });
    expect(all.map((e) => e.seq)).toEqual(["999-0", "1000-0", "1001-0"]);

    const windowed = await eventMirror.readWindow(db, sessionId, {
      fromTs: at(2),
      toTs: at(5),
      maxSeq: null,
      limit: 100,
    });
    expect(windowed.map((e) => e.seq)).toEqual(["1000-0"]);

    const capped = await eventMirror.readWindow(db, sessionId, { fromTs: null, toTs: null, maxSeq: "1000-0", limit: 100 });
    expect(capped.map((e) => e.seq)).toEqual(["999-0", "1000-0"]);

    const newest = await eventMirror.readWindow(db, sessionId, { fromTs: null, toTs: null, maxSeq: null, limit: 2 });
    expect(newest.map((e) => e.seq)).toEqual(["1000-0", "1001-0"]);

    const deltas = await eventMirror.deltasForRun(db, sessionId, "r1", { afterSeq: "1000-0", maxSeq: null, limit: 10 });
    expect(deltas.map((e) => e.payload.text)).toEqual(["b"]);
    const allDeltas = await eventMirror.deltasForRun(db, sessionId, "r1", { afterSeq: null, maxSeq: "999-1", limit: 10 });
    expect(allDeltas.map((e) => e.payload.text)).toEqual(["a"]);
  });

  // UNEXECUTED legacy compatibility extension under the heavy-command pause.
  it("legacy un-compacted truncateFrom removes later rows/events and stale state, then replays as a no-op", async () => {
    const { sessionId } = await freshSession();
    const m1 = await messages.append(db, { sessionId, role: "user", content: "one" });
    const m2 = await messages.append(db, { sessionId, role: "assistant", content: "two" });
    await new Promise((r) => setTimeout(r, 5));
    const m3 = await messages.append(db, { sessionId, role: "user", content: "three" });
    const m4 = await messages.append(db, { sessionId, role: "assistant", content: "four" });
    await eventMirror.put(db, ev(sessionId, "1-0", "message_completed", { messageId: m2.id }, m2.createdAt));
    await eventMirror.put(
      db,
      ev(sessionId, "2-0", "tool_started", { callId: "c" }, new Date(m3.createdAt.getTime() + 1)),
    );
    await sessionState.patch(db, sessionId, {
      compaction: { ledger: null, summary: "s", cutoffMessageId: m4.id, compactedAtCount: 1 },
    });

    // Not in the session → nothing happens.
    expect(await messages.truncateFrom(db, sessionId, newId())).toBe(0);

    expect(await messages.truncateFrom(db, sessionId, m3.id)).toBe(2);
    const left = await messages.page(db, sessionId, { limit: 10 });
    expect(left.rows.map((r) => r.id)).toEqual([m2.id, m1.id]);
    const evs = await eventMirror.readSince(db, sessionId, null, 10);
    expect(evs.map((e) => e.seq)).toEqual(["1-0"]);
    expect((await sessionState.get(db, sessionId)).compaction).toBeNull();
    expect(await messages.truncateFrom(db, sessionId, m3.id)).toBe(0);
  });

  it("truncateFrom keepAnchor removes only the rows after the anchor", async () => {
    const { sessionId } = await freshSession();
    const u1 = await messages.append(db, { sessionId, role: "user", content: "q" });
    await messages.append(db, { sessionId, role: "assistant", content: "a" });
    expect(await messages.truncateFrom(db, sessionId, u1.id, { keepAnchor: true })).toBe(1);
    const left = await messages.page(db, sessionId, { limit: 10 });
    expect(left.rows.map((r) => r.id)).toEqual([u1.id]);
  });

  it("truncateFrom keeps a compaction whose boundary is before the cut", async () => {
    const { sessionId } = await freshSession();
    const m1 = await messages.append(db, { sessionId, role: "user", content: "one" });
    const m2 = await messages.append(db, { sessionId, role: "assistant", content: "two" });
    await sessionState.patch(db, sessionId, {
      compaction: { ledger: null, summary: "s", cutoffMessageId: m1.id, compactedAtCount: 1 },
    });
    expect(await messages.truncateFrom(db, sessionId, m2.id)).toBe(1);
    expect((await sessionState.get(db, sessionId)).compaction?.cutoffMessageId).toBe(m1.id);
  });

  // UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
  // Static regressions for the 0039 truncation/recall fence; no RED/GREEN run is claimed.
  it("fences truncation for a compacted session and preserves exact recall and fold replay", async () => {
    const fixture = await compactMain("compacted-truncation");
    const before = await compactionSnapshot(fixture.sessionId);
    const compactedAnchor = fixture.durable[1]!;
    const tailAnchor = fixture.durable[9]!;

    await expect(messages.truncateFrom(db, fixture.sessionId, compactedAnchor.id))
      .rejects.toMatchObject({ code: "compacted_history_truncation" });
    // A tail-only cut is fenced too: replaying the old fold would otherwise
    // rebuild a projection containing the deleted tail.
    await expect(messages.truncateFrom(db, fixture.sessionId, tailAnchor.id))
      .rejects.toMatchObject({ code: "compacted_history_truncation" });

    expect(await compactionSnapshot(fixture.sessionId)).toEqual(before);
    expect((await messages.getInSession(db, fixture.sessionId, compactedAnchor.id))?.content)
      .toBe(compactedAnchor.content);
    const recalled = await readExactHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "message", id: compactedAnchor.id },
    });
    expect(recalled.items).toHaveLength(1);
    expect(recalled.items[0]?.data).toMatchObject({
      id: compactedAnchor.id,
      content: compactedAnchor.content,
    });
    expect(await createCompactionRepository(db).foldCheckpoint(fixture.input)).toEqual(fixture.outcome);
    expect(await compactionSnapshot(fixture.sessionId)).toEqual(before);
  });

  it("fences only the deletion span backed by an exact message reference", async () => {
    const fixture = await freshRoot("backfilled-message-truncation");
    const referenced = await messages.append(db, {
      sessionId: fixture.sessionId,
      role: "user",
      content: "canonical message retained for exact recall",
    });
    const tail = await messages.append(db, {
      sessionId: fixture.sessionId,
      role: "assistant",
      content: "unreferenced tail",
    });
    const item = {
      stableId: referenced.id,
      kind: "message" as const,
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: null,
      attemptId: null,
      eventCursor: referenced.id,
      objectRef: `postgres:messages/${referenced.id}`,
      byteLength: Buffer.byteLength(referenced.content, "utf8"),
    };
    await appendExactItem(db, item);

    expect(await messages.truncateFrom(db, fixture.sessionId, tail.id)).toBe(1);
    expect(await messages.truncateFrom(db, fixture.sessionId, tail.id)).toBe(0);
    await expect(messages.truncateFrom(db, fixture.sessionId, referenced.id))
      .rejects.toMatchObject({ code: "compacted_history_truncation" });
    await appendExactItem(db, item);
    const recalled = await readExactHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "message", id: referenced.id },
    });
    expect(recalled.items).toHaveLength(1);
    expect(recalled.items[0]?.data).toMatchObject({ id: referenced.id, content: referenced.content });
  });

  it("fences deletion of a mirrored event backed by exact recall", async () => {
    const fixture = await freshRoot("backfilled-event-truncation");
    const tail = await messages.append(db, {
      sessionId: fixture.sessionId,
      role: "assistant",
      content: "event anchor",
    });
    await eventMirror.put(db, ev(fixture.sessionId, "1-0", "tool_started", { callId: "exact-call" }, tail.createdAt));
    await appendExactItem(db, {
      stableId: "1-0",
      kind: "event",
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: null,
      attemptId: null,
      eventCursor: "1-0",
      objectRef: `postgres:session_event_mirror/${fixture.sessionId}/1-0`,
      byteLength: Buffer.byteLength(JSON.stringify({ callId: "exact-call" }), "utf8"),
    });

    await expect(messages.truncateFrom(db, fixture.sessionId, tail.id))
      .rejects.toMatchObject({ code: "compacted_history_truncation" });
    expect((await messages.getInSession(db, fixture.sessionId, tail.id))?.id).toBe(tail.id);
    expect((await eventMirror.readSince(db, fixture.sessionId, null, 10)).map((event) => event.seq))
      .toEqual(["1-0"]);
    const recalled = await readExactHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "event", id: "1-0" },
    });
    expect(recalled.items[0]?.data).toMatchObject({ seq: "1-0", type: "tool_started" });
  });

  it("fences a legacy compaction reset while exact history references that state", async () => {
    const fixture = await freshRoot("legacy-state-reference");
    const target = await messages.append(db, {
      sessionId: fixture.sessionId,
      role: "assistant",
      content: "legacy cutoff",
    });
    await sessionState.patch(db, fixture.sessionId, {
      compaction: { ledger: null, summary: "legacy exact summary", cutoffMessageId: target.id, compactedAtCount: 1 },
    });
    const referenceId = newId();
    await appendExactItem(db, {
      stableId: referenceId,
      kind: "checkpoint",
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: null,
      attemptId: null,
      eventCursor: referenceId,
      objectRef: `postgres:session_agent_state/${fixture.sessionId}#compaction`,
      byteLength: 1,
    });

    await expect(messages.truncateFrom(db, fixture.sessionId, target.id))
      .rejects.toMatchObject({ code: "compacted_history_truncation" });
    expect((await sessionState.get(db, fixture.sessionId)).compaction?.summary).toBe("legacy exact summary");
    const recalled = await readExactHistory(db, {
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      reference: { kind: "checkpoint", id: referenceId },
    });
    expect(recalled.items[0]?.data).toMatchObject({ summary: "legacy exact summary" });
  });

  it("keeps independent worker cursors and replay intact when truncation is fenced", async () => {
    const fixture = await freshRoot("independent-worker-truncation");
    const admitted = await admitDispatches(db, [0, 1].map((index) => ({
      requestId: newId(),
      index,
      sessionId: fixture.sessionId,
      userId: fixture.uid,
      rootTaskRunId: fixture.rootTaskRunId,
      parentRunId: fixture.rootTaskRunId,
      batchId: newId(),
      prompt: `independent truncation worker ${index}`,
      provenance: "server" as const,
      requestedAt: new Date(),
      modelContext: { requestedModel: null, byokKeyId: null, actorUserId: fixture.uid },
    })));
    expect(admitted.map((outcome) => outcome.admission)).toEqual(["admitted", "admitted"]);
    const workers: Array<Awaited<ReturnType<typeof compactActor>>> = [];
    for (const [index, admission] of admitted.entries()) {
      workers.push(await compactActor({
        sessionId: admission.childSessionId!,
        rootTaskRunId: fixture.rootTaskRunId,
        logicalWorkerId: admission.logicalWorkerId!,
        attemptId: admission.attemptId!,
        kind: "worker",
      }, `independent-worker-${index}`));
    }
    const before = await Promise.all(workers.map((worker) => compactionSnapshot(worker.actor.sessionId)));

    await expect(messages.truncateFrom(db, workers[0]!.actor.sessionId, workers[0]!.durable[1]!.id))
      .rejects.toMatchObject({ code: "compacted_history_truncation" });
    expect(await Promise.all(workers.map((worker) => compactionSnapshot(worker.actor.sessionId))))
      .toEqual(before);
    for (const worker of workers) {
      expect(await createCompactionRepository(db).foldCheckpoint(worker.input)).toEqual(worker.outcome);
      const recalled = await readExactHistory(db, {
        sessionId: worker.actor.sessionId,
        rootTaskRunId: fixture.rootTaskRunId,
        logicalWorkerId: worker.actor.logicalWorkerId,
        reference: { kind: "message", id: worker.durable[0]!.id },
      });
      expect(recalled.items[0]?.data).toMatchObject({ id: worker.durable[0]!.id });
    }
    expect(await Promise.all(workers.map((worker) => compactionSnapshot(worker.actor.sessionId))))
      .toEqual(before);
  });

  // FIX ROUND 1 — UNEXECUTED under the heavy-command pause. The required
  // fold/append handoff is now present; parent/child worker-event coverage
  // lives in compactionRepos.test.ts. These remain dynamic verification gates.
  it("rejects a first fold whose unreferenced retained tail was truncated before any cursor existed", async () => {
    const fixture = await freshRoot("sequential-first-fold-stale-tail");
    const prepared = await prepareCompaction(mainActor(fixture), "sequential-first-fold-stale-tail");
    const retainedTail = prepared.durable[prepared.durable.length - 1]!;

    // No cursor/history exists yet, so this legacy tail-only cut is allowed.
    expect(await messages.truncateFrom(db, fixture.sessionId, retainedTail.id)).toBe(1);
    await expect(createCompactionRepository(db).foldCheckpoint(prepared.input))
      .rejects.toMatchObject({ code: "stale_compaction_input" });
    expect(await compactionSnapshot(fixture.sessionId)).toEqual({
      cursors: [],
      checkpoints: [],
      history: [],
    });
    expect(await messages.getInSession(db, fixture.sessionId, retainedTail.id)).toBeNull();
  });

  it("serializes a two-connection first fold and retained-tail truncation without stale replay", async () => {
    const fixture = await freshRoot("concurrent-first-fold-stale-tail");
    const prepared = await prepareCompaction(mainActor(fixture), "concurrent-first-fold-stale-tail");
    const retainedTail = prepared.durable[prepared.durable.length - 1]!;
    const secondDb = createDb(TEST_DATABASE_URL!, { max: 4 });
    try {
      const [fold, truncation] = await within(Promise.allSettled([
        createCompactionRepository(db).foldCheckpoint(prepared.input),
        messages.truncateFrom(secondDb, fixture.sessionId, retainedTail.id),
      ]), "first fold versus retained-tail truncation", 10_000);

      if (fold.status === "fulfilled" && truncation.status === "rejected") {
        // Fold won the shared gate first. Truncation must then observe the new
        // runtime cursor and fence rather than deleting the replayed tail.
        expect(fold.value.compacted).toBe(true);
        expect(truncation.reason).toMatchObject({ code: "compacted_history_truncation" });
        expect(await messages.getInSession(db, fixture.sessionId, retainedTail.id)).not.toBeNull();
        const beforeReplay = await compactionSnapshot(fixture.sessionId);
        expect(await createCompactionRepository(db).foldCheckpoint(prepared.input)).toEqual(fold.value);
        expect(await compactionSnapshot(fixture.sessionId)).toEqual(beforeReplay);
        return;
      }
      if (fold.status === "rejected" && truncation.status === "fulfilled") {
        // Truncation won the exclusive gate first. The later fold must
        // revalidate every prefix/tail row and roll back before replay state.
        expect(truncation.value).toBe(1);
        expect(fold.reason).toMatchObject({ code: "stale_compaction_input" });
        expect(await messages.getInSession(db, fixture.sessionId, retainedTail.id)).toBeNull();
        expect(await compactionSnapshot(fixture.sessionId)).toEqual({
          cursors: [],
          checkpoints: [],
          history: [],
        });
        return;
      }
      throw new Error(`Invalid fold/truncation outcome: ${fold.status}/${truncation.status}`);
    } finally {
      await secondDb.$client.end({ timeout: 5 });
    }
  });

  it("terminates two concurrent truncations without a retained-lock upgrade deadlock", async () => {
    const { sessionId } = await freshSession();
    await messages.append(db, { sessionId, role: "user", content: "before" });
    const anchor = await messages.append(db, { sessionId, role: "user", content: "anchor" });
    await messages.append(db, { sessionId, role: "assistant", content: "tail" });
    const secondDb = createDb(TEST_DATABASE_URL!, { max: 4 });
    try {
      const results = await within(Promise.allSettled([
        messages.truncateFrom(db, sessionId, anchor.id),
        messages.truncateFrom(secondDb, sessionId, anchor.id),
      ]), "two truncations of one session");
      expect(results.every((result) => result.status === "fulfilled")).toBe(true);
      const counts = results.map((result) => {
        if (result.status !== "fulfilled") throw result.reason;
        return result.value;
      });
      expect(counts.sort((left, right) => left - right)).toEqual([0, 2]);
      expect((await messages.page(db, sessionId, { limit: 10 })).rows.map((row) => row.content))
        .toEqual(["before"]);
    } finally {
      await secondDb.$client.end({ timeout: 5 });
    }
  });

  it("does not block unrelated account messages, events, state, or a first fold behind a target-session fence", async () => {
    const target = await compactMain("exclusive-target-session");
    const other = await freshRoot("unrelated-account-progress");
    const preparedOther = await prepareCompaction(mainActor(other), "unrelated-account-progress");
    const secondDb = createDb(TEST_DATABASE_URL!, { max: 4 });
    let signalLocked!: () => void;
    const locked = new Promise<void>((resolve) => { signalLocked = resolve; });
    let release!: () => void;
    const released = new Promise<void>((resolve) => { release = resolve; });
    const holder = secondDb.transaction(async (tx) => {
      await lockCompactionSession(tx, target.sessionId, { mode: "exclusive" });
      signalLocked();
      await released;
    });
    try {
      await locked;
      const unrelatedWork = (async () => {
        await messages.page(db, other.sessionId, { limit: 10 });
        await messages.append(db, { sessionId: other.sessionId, role: "assistant", content: "unrelated write" });
        await eventMirror.put(db, ev(other.sessionId, "1-0", "run_started", {
          runId: other.rootTaskRunId,
        }, new Date()));
        await sessionState.patch(db, other.sessionId, { planMode: true });
        const outcome = await createCompactionRepository(db).foldCheckpoint(preparedOther.input);
        expect(outcome.compacted).toBe(true);
      })();
      await within(unrelatedWork, "unrelated account progress during a target-session fence", 10_000);
      expect((await sessionState.get(db, other.sessionId)).planMode).toBe(true);
    } finally {
      release();
      await holder;
      await secondDb.$client.end({ timeout: 5 });
    }
  });

  it("latestUserBefore, upTo and copyInto support regenerate and branch", async () => {
    const { uid, sessionId } = await freshSession();
    const u1 = await messages.append(db, { sessionId, role: "user", content: "q1" });
    const a1 = await messages.append(db, { sessionId, role: "assistant", content: "a1" });
    const u2 = await messages.append(db, { sessionId, role: "user", content: "q2" });
    const a2 = await messages.append(db, { sessionId, role: "assistant", content: "a2" });
    expect((await messages.latestUserBefore(db, sessionId, a2.id))?.id).toBe(u2.id);
    expect((await messages.latestUserBefore(db, sessionId, a1.id))?.id).toBe(u1.id);
    expect(await messages.latestUserBefore(db, sessionId, u1.id)).toBeNull();
    expect((await messages.getInSession(db, sessionId, a1.id))?.content).toBe("a1");
    const other = await sessions.create(db, uid, "other");
    expect(await messages.getInSession(db, other.id, a1.id)).toBeNull();

    const head = await messages.upTo(db, sessionId, a1.id, 100);
    expect(head.map((r) => r.content)).toEqual(["q1", "a1"]);
    expect(await messages.copyInto(db, other.id, head)).toBe(2);
    const copied = await messages.page(db, other.id, { limit: 10 });
    expect(copied.rows.map((r) => r.content).reverse()).toEqual(["q1", "a1"]);
    expect(copied.rows[1]!.createdAt.getTime()).toBe(u1.createdAt.getTime());
  });

  it("linkToMessage / forMessages are session-scoped", async () => {
    const { uid, sessionId } = await freshSession();
    const other = await sessions.create(db, uid, "other");
    const m = await messages.append(db, { sessionId, role: "user", content: "see file" });
    const a = newId();
    const b = newId();
    await attachments.create(db, { id: a, sessionId, userId: uid, name: "a.png", size: 10, r2Key: "k/a" });
    await attachments.create(db, { id: b, sessionId: other.id, userId: uid, name: "b.png", size: 10, r2Key: "k/b" });
    await attachments.linkToMessage(db, sessionId, [a, b], m.id);
    const rows = await attachments.forMessages(db, sessionId, [m.id]);
    expect(rows.map((r) => r.id)).toEqual([a]);
    expect(await attachments.forMessages(db, other.id, [m.id])).toEqual([]);
    expect(await attachments.forMessages(db, sessionId, [])).toEqual([]);
  });
});
