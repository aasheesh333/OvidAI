import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "./client.js";
import { dataControlRepo } from "./dataControlRepos.js";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";
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
 * Behaviour against real Postgres is exercised by the gateway's integration
 * tests; this file guards the shape of the SQL itself.
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

describe.skipIf(!TEST_DATABASE_URL)("dataControlRepo 0033/0034 cleanup (isolated real Postgres)", () => {
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
});
