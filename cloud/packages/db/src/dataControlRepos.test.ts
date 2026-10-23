import { describe, expect, it } from "vitest";
import type { Db } from "./client.js";
import { dataControlRepo } from "./dataControlRepos.js";

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
    for (const child of [
      "DELETE FROM schedule_runs",
      "DELETE FROM schedules",
      "DELETE FROM grants",
      "DELETE FROM attachments",
      "DELETE FROM session_event_mirror",
      "DELETE FROM session_agent_state",
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
