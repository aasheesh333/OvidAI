import { afterEach, describe, expect, it } from "vitest";

import {
  createCompactionRepository,
  createDb,
  messages,
  migrate,
  newId,
  runs,
  sessionState,
  sessions,
  users,
  type CompactionActor,
  type Db,
  type FoldCheckpointInput,
} from "@ovid/db";

import {
  createMigrationScratch,
  type MigrationScratch,
} from "../../../packages/db/src/migrationTestKit.js";
import {
  createCompactionContinuation,
  recoverPendingCompactionContinuations,
} from "./compactionContinuation.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

const PROFILE = {
  model: "provider/continuation",
  contextLimit: 100_000,
  outputReserveTokens: 500,
  providerReserveTokens: 100,
};
const FOLDED_ROWS = 4;
const RETAINED_ROWS = 8;

/**
 * Next-run continuation is a projection of the committed checkpoint into the
 * legacy replay state (`session_agent_state.compaction`) that agent-core's loop
 * reads through `applyCheckpoint` / `foldBoundaryFor`. These cases pin the
 * crash window (fold committed, projection missing), idempotency, supersession,
 * and every fail-closed scope gate.
 *
 * Each case owns its scratch database: recovery is a global bounded scan, so a
 * shared database would let an earlier case's deliberately-unprojectable
 * cursor leak into a later case's report.
 */
describe.skipIf(!TEST_DATABASE_URL).sequential("compaction continuation on isolated real Postgres", () => {
  let scratch: MigrationScratch | undefined;
  let db: Db | undefined;

  async function fresh(label: string): Promise<{ scratch: MigrationScratch; db: Db }> {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, label);
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 6 });
    return { scratch, db };
  }

  afterEach(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
    db = undefined;
    scratch = undefined;
  }, 30_000);

  async function seed(
    target: Db,
    label: string,
    contextLimit = 100_000,
    prefixRows: Array<{ role: "user" | "assistant" | "system"; content: string; id?: string }> = [],
  ) {
    const userId = newId();
    await users.ensure(target, userId, null);
    const session = await sessions.create(target, userId, label);
    const prompt = await messages.append(target, { sessionId: session.id, role: "user", content: `${label}-root` });
    const root = await runs.create(target, { sessionId: session.id, promptMessageId: prompt.id });
    expect(await runs.claimNext(target, root.id)).toBe(true);
    const chars = Math.ceil(contextLimit * 0.08);
    const window: Array<{ id: string; role: "user" | "assistant"; content: string }> = [];
    for (let index = 0; index < FOLDED_ROWS + RETAINED_ROWS; index += 1) {
      const role = index % 2 === 0 ? "user" as const : "assistant" as const;
      const prefix = `${label}-${index}-`;
      const row = await messages.append(target, {
        sessionId: session.id,
        role,
        content: `${prefix}${"x".repeat(chars - prefix.length)}`,
      });
      window.push({ id: row.id, role, content: row.content });
    }
    const actor: CompactionActor = {
      sessionId: session.id,
      rootTaskRunId: root.id,
      logicalWorkerId: null,
      attemptId: null,
      kind: "main",
    };
    return { userId, session, root, window, actor, prefixRows, chars };
  }

  async function fold(
    target: Db,
    fixture: Awaited<ReturnType<typeof seed>>,
    opts: {
      messages?: FoldCheckpointInput["messages"];
      foldBoundary?: number;
      contextLimit?: number;
    } = {},
  ) {
    const contextLimit = opts.contextLimit ?? PROFILE.contextLimit;
    const outcome = await createCompactionRepository(target).foldCheckpoint({
      messages: opts.messages ?? fixture.window,
      foldBoundary: opts.foldBoundary ?? 0,
      profile: { ...PROFILE, contextLimit },
      usage: { beforeTokens: Math.floor(contextLimit * 0.8), usageSource: "measured" },
      actor: fixture.actor,
    });
    expect(outcome.compacted).toBe(true);
    return outcome;
  }

  it("recovers a fold committed without a projection, then never inflates on replay", async () => {
    const { db: target } = await fresh("continuation_crash");
    const fixture = await seed(target, "crash");
    const outcome = await fold(target, fixture);
    const continuation = createCompactionContinuation({ db: target });

    // The crash window: the checkpoint + cursor exist, the legacy state does not.
    expect((await sessionState.get(target, fixture.session.id)).compaction).toBeNull();

    const first = await continuation.sync({
      checkpointId: outcome.checkpointId!,
      actor: fixture.actor,
    });
    expect(first).toMatchObject({
      status: "applied",
      checkpointId: outcome.checkpointId,
      compactedAtCount: 1,
      cutoffMessageId: fixture.window[FOLDED_ROWS - 1]!.id,
    });
    // The durable summary is the DB checkpoint document (the runtime wraps it
    // in the <compacted-summary> block only when building request rows).
    expect(first.summary).toContain("# Lossless compaction checkpoint");
    expect(first.summary).toContain(`Checkpoint: ${outcome.checkpointId}`);

    const state = await sessionState.get(target, fixture.session.id);
    expect(state.compaction).toMatchObject({
      // A durable window is indexed by cutoffMessageId, never by the ledger.
      ledger: null,
      summary: first.summary,
      cutoffMessageId: first.cutoffMessageId,
      compactedAtCount: 1,
    });

    const replay = await continuation.sync({
      checkpointId: outcome.checkpointId!,
      actor: fixture.actor,
    });
    expect(replay.status).toBe("already_applied");
    expect(replay.compactedAtCount).toBe(1);
    expect((await sessionState.get(target, fixture.session.id)).compaction!.compactedAtCount).toBe(1);
  });

  it("keeps unrelated state keys and an existing compaction count intact", async () => {
    const { db: target } = await fresh("continuation_preserve");
    const fixture = await seed(target, "preserve");
    await sessionState.patch(target, fixture.session.id, {
      modelPin: "provider/pinned",
      compaction: {
        ledger: { v: 1, folded: 2 },
        summary: "older summary",
        cutoffMessageId: null,
        compactedAtCount: 3,
      },
    });
    const outcome = await fold(target, fixture);
    const applied = await createCompactionContinuation({ db: target }).sync({
      checkpointId: outcome.checkpointId!,
      actor: fixture.actor,
    });
    expect(applied.compactedAtCount).toBe(4);
    const state = await sessionState.get(target, fixture.session.id);
    expect(state.modelPin).toBe("provider/pinned");
    expect(state.compaction!.summary).toBe(applied.summary);
    expect(state.compaction!.cutoffMessageId).toBe(applied.cutoffMessageId);
  });

  it("reconciles from the cursor and reports the actor's current checkpoint", async () => {
    const { db: target } = await fresh("continuation_reconcile");
    const fixture = await seed(target, "reconcile");
    const outcome = await fold(target, fixture);
    const continuation = createCompactionContinuation({ db: target });
    const reconciled = await continuation.reconcile(fixture.actor);
    expect(reconciled).toMatchObject({ status: "applied", checkpointId: outcome.checkpointId });
    // No cursor for an unrelated root: nothing to reconcile, never a guess.
    const other = await seed(target, "reconcile-other");
    expect(await continuation.reconcile(other.actor)).toBeNull();
  });

  it("refuses a checkpoint from another actor scope or another session", async () => {
    const { db: target } = await fresh("continuation_scope");
    const fixture = await seed(target, "scope");
    const other = await seed(target, "scope-other");
    const outcome = await fold(target, fixture);
    const continuation = createCompactionContinuation({ db: target });

    await expect(continuation.sync({
      checkpointId: outcome.checkpointId!,
      actor: { ...other.actor },
    })).rejects.toMatchObject({ code: "checkpoint_scope_mismatch" });

    await expect(continuation.sync({
      checkpointId: outcome.checkpointId!,
      actor: { ...fixture.actor, sessionId: other.session.id },
    })).rejects.toMatchObject({ code: "checkpoint_scope_mismatch" });

    await expect(continuation.sync({
      checkpointId: newId(),
      actor: fixture.actor,
    })).rejects.toMatchObject({ code: "checkpoint_not_found" });

    expect((await sessionState.get(target, fixture.session.id)).compaction).toBeNull();
  });

  it("fails closed when the cutoff row no longer exists in the actor session", async () => {
    const { db: target, scratch: owner } = await fresh("continuation_cutoff");
    const fixture = await seed(target, "cutoff");
    const outcome = await fold(target, fixture);
    // Simulate a destructive truncation between the fold and the projection.
    await owner.client`DELETE FROM messages WHERE id = ${fixture.window[FOLDED_ROWS - 1]!.id}`;
    await expect(createCompactionContinuation({ db: target }).sync({
      checkpointId: outcome.checkpointId!,
      actor: fixture.actor,
    })).rejects.toMatchObject({ code: "continuation_cutoff_unprovable" });
    expect((await sessionState.get(target, fixture.session.id)).compaction).toBeNull();
  });

  it("never regresses the replay boundary to a superseded checkpoint", async () => {
    const { db: target } = await fresh("continuation_superseded");
    const fixture = await seed(target, "superseded");
    const first = await fold(target, fixture);
    const continuation = createCompactionContinuation({ db: target });
    await continuation.sync({ checkpointId: first.checkpointId!, actor: fixture.actor });

    // A second fold continues the first checkpoint. Its window is the exact
    // replayed projection (checkpoint row + retained tail) plus fresh rows, so
    // the repository's own stale-input and cutoff gates both apply.
    const state = await sessionState.get(target, fixture.session.id);
    const chars = fixture.chars;
    const extra: Array<{ id: string; role: "user" | "assistant"; content: string }> = [];
    for (let index = 0; index < RETAINED_ROWS; index += 1) {
      const role = index % 2 === 0 ? "user" as const : "assistant" as const;
      const prefix = `superseded-second-${index}-`;
      const row = await messages.append(target, {
        sessionId: fixture.session.id,
        role,
        content: `${prefix}${"y".repeat(chars - prefix.length)}`,
      });
      extra.push({ id: row.id, role, content: row.content });
    }
    const second = await fold(target, fixture, {
      messages: [...first.messages, ...extra] as FoldCheckpointInput["messages"],
      foldBoundary: 1,
    });
    expect(second.checkpointId).not.toBe(first.checkpointId);
    expect(state.compaction!.cutoffMessageId).toBe(fixture.window[FOLDED_ROWS - 1]!.id);

    const stale = await continuation.sync({
      checkpointId: first.checkpointId!,
      actor: fixture.actor,
    });
    expect(stale.status).toBe("superseded");
    // The newer projection still governs the next run.
    const current = await createCompactionContinuation({ db: target }).reconcile(fixture.actor);
    expect((await sessionState.get(target, fixture.session.id)).compaction!.summary)
      .toBe(current!.summary);
    expect(current!.checkpointId).toBe(second.checkpointId);
  });

  it("replays only unprojected cursors in one bounded idempotent pass", async () => {
    const { db: target } = await fresh("continuation_batch");
    const fixtures = await Promise.all([
      seed(target, "batch-a"),
      seed(target, "batch-b"),
    ]);
    const outcomes = [];
    for (const fixture of fixtures) outcomes.push(await fold(target, fixture));

    expect(await recoverPendingCompactionContinuations({ db: target })).toEqual({
      recovered: 2,
      failed: 0,
    });
    expect(await recoverPendingCompactionContinuations({ db: target })).toEqual({
      recovered: 0,
      failed: 0,
    });
    for (const [index, fixture] of fixtures.entries()) {
      const state = await sessionState.get(target, fixture.session.id);
      expect(state.compaction!.cutoffMessageId).toBe(fixture.window[FOLDED_ROWS - 1]!.id);
      expect(state.compaction!.summary).toContain(
        `Checkpoint: ${outcomes[index]!.checkpointId}`,
      );
    }
  });

  it("keeps a poisoned cursor pending without blocking the rest of the batch", async () => {
    const { db: target, scratch: owner } = await fresh("continuation_poison");
    const broken = await seed(target, "poison");
    const healthy = await seed(target, "poison-healthy");
    const brokenFold = await fold(target, broken);
    await fold(target, healthy);
    // Break only the first actor's cutoff reference.
    await owner.client`DELETE FROM messages WHERE id = ${broken.window[FOLDED_ROWS - 1]!.id}`;

    const report = await recoverPendingCompactionContinuations({ db: target });
    expect(report).toEqual({ recovered: 1, failed: 1 });
    expect((await sessionState.get(target, broken.session.id)).compaction).toBeNull();
    expect((await sessionState.get(target, healthy.session.id)).compaction).not.toBeNull();
    // The poisoned cursor is still discoverable for the next pass.
    const pending = await owner.client`
      SELECT count(*)::int AS "count" FROM compaction_cursors c
        LEFT JOIN session_agent_state s ON s.session_id = c.session_id
       WHERE c.checkpoint_id = ${brokenFold.checkpointId!}
         AND (s.state->'compaction' IS NULL)`;
    expect(pending[0]).toEqual({ count: 1 });
  });
});
