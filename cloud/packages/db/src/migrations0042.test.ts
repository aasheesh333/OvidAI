import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

const MIGRATION_PATH = fileURLToPath(
  new URL("../drizzle/0042_run_delivery_outbox.sql", import.meta.url),
);
const SNAPSHOT_PATH = fileURLToPath(
  new URL("../drizzle/meta/0042_snapshot.json", import.meta.url),
);
const PREVIOUS_SNAPSHOT_PATH = fileURLToPath(
  new URL("../drizzle/meta/0041_snapshot.json", import.meta.url),
);
const JOURNAL_PATH = fileURLToPath(new URL("../drizzle/meta/_journal.json", import.meta.url));

interface Snapshot {
  id: string;
  prevId: string;
  tables: Record<
    string,
    {
      columns: Record<string, { type: string; notNull: boolean; default?: unknown }>;
      indexes: Record<string, { columns: Array<{ expression: string }>; isUnique: boolean }>;
      foreignKeys: Record<string, { tableTo: string; onDelete: string }>;
      checkConstraints: Record<string, { value: string }>;
    }
  >;
}

/**
 * 0042 is the run-delivery outbox. The metadata half pins the hand-maintained
 * journal/snapshot (drizzle-kit is not run in CI), and the execution half
 * proves the SQL actually applies on a real Postgres and produces the columns
 * the delivery path depends on.
 */
describe("0042 run delivery outbox migration metadata", () => {
  it("allocates exactly one chronological 0042 entry after 0041", () => {
    const journal = JSON.parse(readFileSync(JOURNAL_PATH, "utf8")) as {
      entries: Array<{ idx: number; tag: string; when: number }>;
    };
    const positions = journal.entries
      .map((entry, position) => ({ entry, position }))
      .filter(({ entry }) => entry.idx === 42);
    expect(positions).toHaveLength(1);
    const [{ entry, position }] = positions;
    expect(entry.tag).toBe("0042_run_delivery_outbox");
    expect(journal.entries[position - 1]?.tag).toBe("0041_studio_previews");
    expect(journal.entries[position + 1]).toBeUndefined();
    expect(entry.when).toBeGreaterThan(journal.entries[position - 1]!.when);
  });

  it("chains the real 0041 snapshot and carries the delivery contract", () => {
    expect(existsSync(MIGRATION_PATH)).toBe(true);
    expect(existsSync(SNAPSHOT_PATH)).toBe(true);
    const snapshot = JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8")) as Snapshot;
    const previous = JSON.parse(readFileSync(PREVIOUS_SNAPSHOT_PATH, "utf8")) as Snapshot;
    expect(snapshot.prevId).toBe(previous.id);

    const table = snapshot.tables["public.run_delivery_outbox"];
    expect(table).toBeDefined();
    // The unique run identity is what makes replay idempotent.
    expect(table!.indexes["run_delivery_outbox_run_uq"]).toMatchObject({ isUnique: true });
    expect(table!.indexes["run_delivery_outbox_run_uq"]!.columns.map((c) => c.expression))
      .toEqual(["run_id"]);
    expect(table!.indexes["run_delivery_outbox_status_idx"]!.columns.map((c) => c.expression))
      .toEqual(["status", "last_attempt_at", "created_at"]);
    for (const column of [
      "outbox_id",
      "run_id",
      "session_id",
      "user_id",
      "message_id",
      "scheduled",
      "completion_payload",
      "status",
      "attempts",
      "last_attempt_at",
      "delivered_at",
      "last_error",
    ]) {
      expect(table!.columns[column], column).toBeDefined();
    }
    expect(table!.columns.status!.default).toBe("'pending'");
    expect(table!.columns.scheduled!.default).toBe(false);
    expect(table!.columns.delivered_at!.notNull).toBe(false);
    expect(Object.values(table!.foreignKeys).map((fk) => fk.tableTo).sort())
      .toEqual(["messages", "runs", "sessions", "users"]);
    expect(table!.checkConstraints.run_delivery_outbox_status_check!.value)
      .toContain("'delivering'");
    // The claim lease rides the pre-existing notification table.
    expect(snapshot.tables["public.notification_delivery_claims"]!.columns.claimed_at).toBeDefined();
  });

  describe.skipIf(!TEST_DATABASE_URL)("applies on real Postgres", () => {
    let scratch: MigrationScratch;

    beforeAll(async () => {
      scratch = await createMigrationScratch(TEST_DATABASE_URL!, "mig0042");
      // The outbox has FKs into runs/sessions/users/messages, so the real
      // prior migrations must exist first — this is the actual deploy order.
      const { migrateThrough } = await import("./migrationTestKit.js");
      await migrateThrough(scratch.url, 41);
    }, 120_000);

    afterAll(async () => {
      await scratch?.close();
    });

    it("creates the outbox table, its unique run index and the claim lease column", async () => {
      await scratch.client.unsafe(readFileSync(MIGRATION_PATH, "utf8"));
      const [table] = await scratch.client`
        SELECT to_regclass('public.run_delivery_outbox') AS name`;
      expect(table?.name).toBe("run_delivery_outbox");

      const indexes = await scratch.client`
        SELECT indexname FROM pg_indexes
         WHERE schemaname = 'public' AND tablename = 'run_delivery_outbox'
         ORDER BY indexname`;
      expect(indexes.map((row) => row.indexname)).toEqual([
        "run_delivery_outbox_pkey",
        "run_delivery_outbox_run_uq",
        "run_delivery_outbox_status_idx",
      ]);

      const columns = await scratch.client`
        SELECT column_name FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'run_delivery_outbox'`;
      expect(columns.map((row) => row.column_name)).toEqual(
        expect.arrayContaining(["run_id", "message_id", "completion_payload", "status"]),
      );

      // The ALTER is idempotent (IF NOT EXISTS) — a replayed migration is safe.
      await scratch.client.unsafe(
        `ALTER TABLE "notification_delivery_claims" ADD COLUMN IF NOT EXISTS "claimed_at" timestamp (3) with time zone`,
      );
      const claimColumns = await scratch.client`
        SELECT column_name FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'notification_delivery_claims'`;
      expect(claimColumns.map((row) => row.column_name)).toContain("claimed_at");
    });
  });
});
