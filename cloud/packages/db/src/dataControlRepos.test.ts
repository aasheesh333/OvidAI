import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "./client.js";
import { dataControlRepo } from "./dataControlRepos.js";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";
import { messages, newId, runs, sessions, users } from "./repos.js";
import {
  expectSessionCleanupFixtureGone,
  seedSessionCleanupFixture,
} from "../test/sessionCleanupFixtures.js";

/**
 * The destructive SQL, pinned without a database.
 *
 * A fake postgres.js client records every statement the repository issues.
 * That is enough to assert the two properties that matter most in a bulk
 * delete and cannot be caught by a route test:
 *
 *   - no statement is table-wide: every one carries a `user_id =` predicate
 *     (or a sub-select that does), and the uid is bound, never interpolated;
 *   - session-owned rows are removed before the sessions themselves, so a
 *     real database can never reject the transaction on a foreign key.
 *
 * Behaviour against real Postgres is exercised by the isolated cases below;
 * this file also guards the shape of the SQL itself.
 */

type Statement = { text: string; values: unknown[] };

function fakeDb(): { db: Db; statements: Statement[] } {
  const statements: Statement[] = [];

  const respond = (text: string): unknown[] => {
    if (text.startsWith("SELECT email")) return [{ email: "owner@example.test" }];
    if (text.includes("SELECT r2_key")) {
      return [{ key: "users/u/a.bin" }, { key: "users/u/b.bin" }, { key: "users/u/a.bin" }, { key: "" }];
    }
    if (text.includes("DELETE FROM workspace_objects")) {
      return [{ kind: "artifact" }, { kind: "artifact" }, { kind: "workspace_archive" }];
    }
    if (text.includes("DELETE FROM sessions")) return [{ id: "s1" }, { id: "s2" }];
    if (text.includes("DELETE FROM attachments")) return [{ id: "a1" }];
    if (text.includes("DELETE FROM private_memory_files")) {
      return [{ name: "MEMORY.md" }, { name: "notes.md" }];
    }
    return [];
  };

  const sql = (strings: TemplateStringsArray, ...values: unknown[]) => {
    // "$" marks a bound parameter; collapse whitespace so assertions are
    // independent of the source's indentation.
    const text = strings.join("$").replace(/\s+/g, " ").trim();
    statements.push({ text, values });
    return Promise.resolve(respond(text));
  };
  // A transaction is the same recorder: order is what is under test.
  (sql as unknown as { begin: (fn: (tx: unknown) => Promise<unknown>) => Promise<unknown> }).begin =
    async (fn) => fn(sql);

  return { db: { $client: sql } as unknown as Db, statements };
}

describe("dataControlRepo", () => {
  it("reads the registered email from the users row, never from a caller value", async () => {
    const { db, statements } = fakeDb();
    await expect(dataControlRepo.registeredEmail(db, "u1")).resolves.toBe("owner@example.test");
    expect(statements).toHaveLength(1);
    expect(statements[0]!.text).toContain("WHERE uid = $");
    expect(statements[0]!.values).toEqual(["u1"]);
  });

  it("enumerates and deduplicates only the caller's referenced storage keys", async () => {
    const { db, statements } = fakeDb();
    await expect(dataControlRepo.ownedStorageKeys(db, "u1")).resolves.toEqual([
      "users/u/a.bin",
      "users/u/b.bin",
    ]);
    expect(statements[0]!.text).toContain("attachments WHERE user_id = $");
    expect(statements[0]!.text).toContain("workspace_objects WHERE user_id = $");
    expect(statements[0]!.values).toEqual(["u1", "u1"]);
  });

  it("deletes only uid-scoped rows, and every session-owned table before sessions", async () => {
    const { db, statements } = fakeDb();
    const counts = await dataControlRepo.deleteAllData(db, "u1");

    expect(counts).toEqual({ sessions: 2, attachments: 1, artifacts: 2, workspaceFiles: 1 });

    for (const statement of statements) {
      // THE invariant: a signed-in account's request must never widen to the
      // whole table. Every statement names the owner.
      expect(statement.text).toContain("user_id =");
      expect(statement.values).toContain("u1");
    }

    const indexOf = (needle: string) =>
      statements.findIndex((statement) => statement.text.includes(needle));
    const sessionsAt = indexOf("DELETE FROM sessions");
    expect(sessionsAt).toBeGreaterThanOrEqual(0);
    const messagesAt = indexOf("DELETE FROM messages");
    const runsAt = indexOf("DELETE FROM runs");
    for (const dependent of [
      "DELETE FROM system_request_responses",
      "DELETE FROM system_requests",
      "DELETE FROM run_outbox",
      "DELETE FROM compaction_cursors",
      "DELETE FROM compaction_history_items",
      "DELETE FROM compaction_checkpoints",
      "DELETE FROM subagent_control_audit",
      "DELETE FROM subagent_reports",
      "DELETE FROM subagent_checkpoints",
      "DELETE FROM subagent_root_finalizations",
      "DELETE FROM subagent_attempts",
      "DELETE FROM subagent_logical_workers",
      "DELETE FROM subagent_dispatches",
      "DELETE FROM subagent_batches",
      "DELETE FROM subagent_roots",
    ]) {
      expect(indexOf(dependent), `${dependent} precedes messages`).toBeLessThan(messagesAt);
      expect(indexOf(dependent), `${dependent} precedes runs`).toBeLessThan(runsAt);
    }
    expect(indexOf("DELETE FROM system_request_responses"))
      .toBeLessThan(indexOf("DELETE FROM system_requests"));
    // 0039: cursor -> checkpoint is NO ACTION, as is each compaction row's
    // run/worker/attempt reference. Session cascades do not make those safe.
    expect(indexOf("DELETE FROM compaction_cursors"))
      .toBeLessThan(indexOf("DELETE FROM compaction_checkpoints"));
    for (const dependent of [
      "DELETE FROM compaction_cursors",
      "DELETE FROM compaction_history_items",
      "DELETE FROM compaction_checkpoints",
    ]) {
      for (const authority of [
        "DELETE FROM subagent_attempts",
        "DELETE FROM subagent_logical_workers",
      ]) {
        expect(indexOf(dependent), `${dependent} precedes ${authority}`)
          .toBeLessThan(indexOf(authority));
      }
    }

    for (const child of [
      "DELETE FROM schedule_runs",
      "DELETE FROM schedules",
      "DELETE FROM grants",
      "DELETE FROM attachments",
      "DELETE FROM session_event_mirror",
      "DELETE FROM session_agent_state",
      "DELETE FROM system_request_responses",
      "DELETE FROM system_requests",
      "DELETE FROM run_outbox",
      "DELETE FROM compaction_cursors",
      "DELETE FROM compaction_history_items",
      "DELETE FROM compaction_checkpoints",
      "DELETE FROM subagent_control_audit",
      "DELETE FROM subagent_reports",
      "DELETE FROM subagent_checkpoints",
      "DELETE FROM subagent_root_finalizations",
      "DELETE FROM subagent_attempts",
      "DELETE FROM subagent_logical_workers",
      "DELETE FROM subagent_dispatches",
      "DELETE FROM subagent_batches",
      "DELETE FROM subagent_roots",
      "DELETE FROM subagent_session_admission",
      "DELETE FROM messages",
      "DELETE FROM runs",
      "DELETE FROM file_manifests",
      "DELETE FROM workspace_objects",
    ]) {
      const at = indexOf(child);
      expect(at, `${child} must run`).toBeGreaterThanOrEqual(0);
      expect(at, `${child} must run before sessions`).toBeLessThan(sessionsAt);
    }
  });

  it("leaves project and shared memory alone when deleting chats", async () => {
    const { db, statements } = fakeDb();
    await dataControlRepo.deleteAllData(db, "u1");
    const memory = statements.find((statement) =>
      statement.text.includes("DELETE FROM private_memory_files"),
    );
    expect(memory).toBeDefined();
    // Session-scoped rows only; `project:<uuid>` and `shared` survive.
    expect(memory!.text).toContain("session_id IS NOT NULL");
  });

  it("resets memory with one uid-scoped statement and reports what it removed", async () => {
    const { db, statements } = fakeDb();
    await expect(dataControlRepo.resetAllMemory(db, "u1")).resolves.toBe(2);
    expect(statements).toHaveLength(1);
    expect(statements[0]!.text).toBe(
      "DELETE FROM private_memory_files WHERE user_id = $ RETURNING name",
    );
    expect(statements[0]!.values).toEqual(["u1"]);
  });
});

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

async function compactionRows(db: Db, sessionId: string) {
  return {
    cursors: await db.$client`
      SELECT * FROM compaction_cursors WHERE session_id = ${sessionId}
      ORDER BY root_task_run_id, actor_kind, actor_id`,
    checkpoints: await db.$client`
      SELECT * FROM compaction_checkpoints WHERE session_id = ${sessionId}
      ORDER BY checkpoint_id`,
    history: await db.$client`
      SELECT * FROM compaction_history_items WHERE session_id = ${sessionId}
      ORDER BY position`,
  };
}

async function canonicalRows(db: Db, userId: string) {
  return {
    sessions: await db.$client`
      SELECT * FROM sessions WHERE user_id = ${userId} ORDER BY id`,
    runs: await db.$client`
      SELECT * FROM runs WHERE session_id IN
        (SELECT id FROM sessions WHERE user_id = ${userId}) ORDER BY id`,
    messages: await db.$client`
      SELECT * FROM messages WHERE session_id IN
        (SELECT id FROM sessions WHERE user_id = ${userId}) ORDER BY id`,
  };
}

/** Populate every 0039 FK direction, including worker lineage and cursor -> checkpoint. */
async function seedCompactionCleanupFixture(db: Db, userId: string) {
  const fixture = await seedSessionCleanupFixture(db, userId);
  const [attempt] = await db.$client`
    SELECT logical_worker_id FROM subagent_attempts WHERE id = ${fixture.attemptId}`;
  const logicalWorkerId = attempt?.logical_worker_id;
  if (typeof logicalWorkerId !== "string") {
    throw new Error("cleanup fixture has no logical worker lineage");
  }
  const checkpointId = newId();
  const compactionId = newId();
  await db.$client`
    INSERT INTO compaction_checkpoints
      (checkpoint_id, compaction_id, session_id, root_task_run_id,
       logical_worker_id, attempt_id, actor_id, actor_kind, request_digest,
       model, context_limit, output_reserve_tokens, provider_reserve_tokens,
       before_tokens, after_tokens, usage_source, cutoff_cursor,
       cutoff_message_id, ledger_version, ledger, summary, active_state,
       continuation, created_at)
    VALUES
      (${checkpointId}, ${compactionId}, ${fixture.sessionId}, ${fixture.runId},
       ${logicalWorkerId}, ${fixture.attemptId}, ${logicalWorkerId}, 'worker',
       ${"d".repeat(64)}, 'cleanup-model', 1000, 100, 10, 800, 200, 'measured',
       ${fixture.messageId}, ${fixture.messageId}, 1, '{"v":1,"version":1}'::jsonb,
       'cleanup checkpoint', '{}'::jsonb, 'continuing_existing_task', now())`;
  await db.$client`
    INSERT INTO compaction_history_items
      (session_id, root_task_run_id, logical_worker_id, attempt_id,
       kind, stable_id, event_cursor, object_ref, byte_length)
    VALUES
      (${fixture.sessionId}, ${fixture.runId}, ${logicalWorkerId}, ${fixture.attemptId},
       'message', ${fixture.messageId}, ${fixture.messageId},
       ${`postgres:messages/${fixture.messageId}`}, ${Buffer.byteLength("root cleanup prompt")})`;
  await db.$client`
    INSERT INTO compaction_cursors
      (session_id, root_task_run_id, actor_kind, actor_id, logical_worker_id,
       attempt_id, checkpoint_id, compaction_id, cutoff_cursor,
       cutoff_message_id, ledger_version)
    VALUES
      (${fixture.sessionId}, ${fixture.runId}, 'worker', ${logicalWorkerId},
       ${logicalWorkerId}, ${fixture.attemptId}, ${checkpointId}, ${compactionId},
       ${fixture.messageId}, ${fixture.messageId}, 1)`;
  return fixture;
}

describe.skipIf(!TEST_DATABASE_URL).sequential("dataControlRepo 0033/0034/0039 cleanup (isolated real Postgres)", () => {
  let scratch: MigrationScratch;
  let db: Db;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "cleanup_0033_data");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 8 });
  }, 180_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  it("deletes real 0033 rows and every 0034 descendant before messages/runs, then replays", async () => {
    await seedSessionCleanupFixture(db, "data-control-0033-user");
    const first = await dataControlRepo.deleteAllData(db, "data-control-0033-user");
    expect(first.sessions).toBe(2);
    await expectSessionCleanupFixtureGone(db);
    await expect(dataControlRepo.deleteAllData(db, "data-control-0033-user"))
      .resolves.toEqual({ sessions: 0, attachments: 0, artifacts: 0, workspaceFiles: 0 });
  }, 60_000);

  it("preserves legacy-empty deletion and zero-count replay when no 0039 rows exist", async () => {
    const userId = newId();
    await users.ensure(db, userId, null);
    const session = await sessions.create(db, userId, "legacy compaction-empty cleanup");
    const prompt = await messages.append(db, {
      sessionId: session.id,
      role: "user",
      content: "legacy canonical prompt",
    });
    await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
    expect(await compactionRows(db, session.id)).toEqual({
      cursors: [], checkpoints: [], history: [],
    });

    await expect(dataControlRepo.deleteAllData(db, userId)).resolves.toEqual({
      sessions: 1, attachments: 0, artifacts: 0, workspaceFiles: 0,
    });
    expect(await canonicalRows(db, userId)).toEqual({ sessions: [], runs: [], messages: [] });
    await expect(dataControlRepo.deleteAllData(db, userId)).resolves.toEqual({
      sessions: 0, attachments: 0, artifacts: 0, workspaceFiles: 0,
    });
  }, 60_000);

  it("deletes populated 0039 rows before their authorities without cross-account collateral", async () => {
    const target = await seedCompactionCleanupFixture(db, newId());
    const survivor = await seedCompactionCleanupFixture(db, newId());
    const targetBefore = await compactionRows(db, target.sessionId);
    expect(targetBefore.cursors).toHaveLength(1);
    expect(targetBefore.checkpoints).toHaveLength(1);
    expect(targetBefore.history).toHaveLength(1);
    const survivorCompactionBefore = await compactionRows(db, survivor.sessionId);
    const survivorCanonicalBefore = await canonicalRows(db, survivor.userId);

    const first = await dataControlRepo.deleteAllData(db, target.userId);
    expect(first).toEqual({ sessions: 2, attachments: 0, artifacts: 0, workspaceFiles: 0 });
    expect(await compactionRows(db, target.sessionId)).toEqual({
      cursors: [], checkpoints: [], history: [],
    });
    expect(await canonicalRows(db, target.userId)).toEqual({
      sessions: [], runs: [], messages: [],
    });
    await expect(dataControlRepo.deleteAllData(db, target.userId)).resolves.toEqual({
      sessions: 0, attachments: 0, artifacts: 0, workspaceFiles: 0,
    });

    // Exact history, checkpoints/cursors and canonical rows for another uid
    // must survive both the initial delete and its idempotent replay verbatim.
    expect(await compactionRows(db, survivor.sessionId)).toEqual(survivorCompactionBefore);
    expect(await canonicalRows(db, survivor.userId)).toEqual(survivorCanonicalBefore);

    // Leave the shared scratch database clean for subsequent cases.
    await dataControlRepo.deleteAllData(db, survivor.userId);
    expect(await compactionRows(db, survivor.sessionId)).toEqual({
      cursors: [], checkpoints: [], history: [],
    });
  }, 60_000);
});
