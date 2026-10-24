import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "./client.js";
import {
  applyMigrationFile,
  createMigrationScratch,
  migrateThrough,
  type MigrationScratch,
} from "./migrationTestKit.js";
import { attachments, newId, sessions, users } from "./repos.js";

const MIGRATION_PATH = fileURLToPath(
  new URL("../drizzle/0035_attachment_declaration_presence.sql", import.meta.url),
);
const SNAPSHOT_PATH = fileURLToPath(
  new URL("../drizzle/meta/0035_snapshot.json", import.meta.url),
);
const JOURNAL_PATH = fileURLToPath(new URL("../drizzle/meta/_journal.json", import.meta.url));
const migrationSql = existsSync(MIGRATION_PATH) ? readFileSync(MIGRATION_PATH, "utf8") : "";

describe("0035 attachment declaration presence migration metadata", () => {
  it("preserves the journal-wide 0031 to 0035 chain with increasing timestamps", () => {
    const journal = JSON.parse(readFileSync(JOURNAL_PATH, "utf8")) as {
      entries: Array<{ idx: number; tag: string; when: number }>;
    };
    const lineage = journal.entries.filter((candidate) => [31, 33, 34, 35].includes(candidate.idx));
    expect(lineage.map((candidate) => candidate.tag)).toEqual([
      "0031_attachment_provider_connections",
      "0033_system_requests_outbox",
      "0034_subagent_lifecycle",
      "0035_attachment_declaration_presence",
    ]);
    for (let index = 1; index < lineage.length; index += 1) {
      expect(lineage[index]!.when).toBeGreaterThan(lineage[index - 1]!.when);
    }
    expect(journal.entries.filter((candidate) => candidate.idx === 35)).toHaveLength(1);
  });

  it("uses the real 0034 snapshot and adds only the declaration-presence column", () => {
    expect(existsSync(SNAPSHOT_PATH)).toBe(true);
    const snapshot = existsSync(SNAPSHOT_PATH)
      ? JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8"))
      : { tables: {}, id: "", prevId: "" };
    const previous = JSON.parse(readFileSync(
      fileURLToPath(new URL("../drizzle/meta/0034_snapshot.json", import.meta.url)),
      "utf8",
    )) as { id: string; tables: Record<string, unknown> };
    expect(snapshot.prevId).toBe(previous.id);
    const columnCount = Object.values(snapshot.tables as Record<string, { columns: Record<string, unknown> }>)
      .reduce((sum, table) => sum + Object.keys(table.columns).length, 0);
    expect({ tables: Object.keys(snapshot.tables).length, columns: columnCount })
      .toEqual({ tables: 56, columns: 538 });
    expect(Object.keys(snapshot.tables).sort())
      .toEqual(expect.arrayContaining(Object.keys(previous.tables).sort()));
    for (const [table, definition] of Object.entries(previous.tables)) {
      if (table === "public.attachments") continue;
      expect(snapshot.tables[table], `preserve entire 0034 table ${table}`).toEqual(definition);
    }
    const actualAttachments = structuredClone(snapshot.tables["public.attachments"]);
    const expectedAttachments = structuredClone(previous.tables["public.attachments"]);
    delete actualAttachments.columns.content_type_declared;
    expect(actualAttachments).toEqual(expectedAttachments);
    expect(snapshot.tables["public.users"]?.columns.response_wait_seconds)
      .toMatchObject({ type: "integer", notNull: true, default: 45 });
    expect(snapshot.tables["public.billing_purchases"]?.columns.period)
      .toMatchObject({ type: "text", notNull: false });
    for (const table of [
      "system_requests",
      "system_request_responses",
      "run_outbox",
      "billing_entitlement_events",
      "subagent_roots",
    ]) {
      expect(snapshot.tables[`public.${table}`], `cumulative table ${table}`).toBeDefined();
    }
    expect(snapshot.tables["public.attachments"]?.columns.content_type_declared)
      .toMatchObject({
        name: "content_type_declared",
        type: "boolean",
        notNull: true,
        default: false,
      });
    expect(snapshot.tables["public.subagent_roots"]).toBeDefined();
  });

  it("is additive, replayable, and backfills only non-octet historical declarations", () => {
    expect(migrationSql).not.toBe("");
    expect(migrationSql).toContain("ADD COLUMN IF NOT EXISTS");
    expect(migrationSql).toContain("content_type_declared");
    expect(migrationSql).toMatch(/"?content_type"?\s*<>\s*'application\/octet-stream'/);
    expect(migrationSql).not.toMatch(/\bDROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT)\b/i);
    expect(migrationSql).not.toMatch(/\bRENAME\s+(TO|COLUMN)\b/i);
    expect(migrationSql).not.toMatch(/UPDATE\s+"?attachments"?\s+SET\s+"?content_type"?\s*=/i);
  });
});

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL).sequential("0035 against real Postgres", () => {
  let fresh: MigrationScratch;
  let upgrade: MigrationScratch;
  let freshDb: Db;
  let upgradeDb: Db;
  let upgradeSessionId: string;
  let historicalOctetId: string;
  let historicalTextId: string;
  let historicalDefaultId: string;

  beforeAll(async () => {
    [fresh, upgrade] = await Promise.all([
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0035_fresh"),
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0035_upgrade"),
    ]);
    await Promise.all([migrate(fresh.url), migrateThrough(upgrade.url, 34)]);

    upgradeSessionId = newId();
    historicalOctetId = newId();
    historicalTextId = newId();
    historicalDefaultId = newId();
    await upgrade.client`INSERT INTO users (uid, email) VALUES ('task3-0035-user', NULL)`;
    await upgrade.client`INSERT INTO sessions (id, user_id, title)
      VALUES (${upgradeSessionId}, 'task3-0035-user', 'declaration history')`;
    await upgrade.client`INSERT INTO attachments
      (id, session_id, user_id, name, size, r2_key, content_type)
      VALUES
      (${historicalOctetId}, ${upgradeSessionId}, 'task3-0035-user', 'ambiguous.bin', 4, 'history/octet', 'application/octet-stream'),
      (${historicalTextId}, ${upgradeSessionId}, 'task3-0035-user', 'declared.txt', 4, 'history/text', 'text/plain'),
      (${historicalDefaultId}, ${upgradeSessionId}, 'task3-0035-user', 'omitted.bin', 4, 'history/omitted', 'application/octet-stream')`;

    await migrate(upgrade.url);
    freshDb = createDb(fresh.url, { max: 4 });
    upgradeDb = createDb(upgrade.url, { max: 4 });
  }, 180_000);

  afterAll(async () => {
    await freshDb?.$client.end({ timeout: 5 });
    await upgradeDb?.$client.end({ timeout: 5 });
    await Promise.all([fresh?.close(), upgrade?.close()]);
  }, 30_000);

  it("fresh installs default old-shaped writes to unknown and persist supplied declarations", async () => {
    const columns = await fresh.client`
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_name = 'attachments' AND column_name = 'content_type_declared'`;
    expect(columns).toEqual([{
      column_name: "content_type_declared",
      data_type: "boolean",
      is_nullable: "NO",
      column_default: "false",
    }]);

    const uid = "task3-0035-fresh-user";
    await users.ensure(freshDb, uid, null);
    const session = await sessions.create(freshDb, uid);
    const oldShapedId = newId();
    await fresh.client`INSERT INTO attachments (id, session_id, user_id, name, size, r2_key)
      VALUES (${oldShapedId}, ${session.id}, ${uid}, 'old.bin', 4, 'fresh/old')`;
    const supplied = await attachments.create(freshDb, {
      id: newId(),
      sessionId: session.id,
      userId: uid,
      name: "supplied.bin",
      size: 4,
      r2Key: "fresh/supplied",
      contentType: "application/octet-stream",
    });
    const omitted = await attachments.create(freshDb, {
      id: newId(),
      sessionId: session.id,
      userId: uid,
      name: "omitted.bin",
      size: 4,
      r2Key: "fresh/omitted",
    });

    expect(supplied.contentTypeDeclared).toBe(true);
    expect(omitted.contentTypeDeclared).toBe(false);
    const oldRows = await fresh.client`
      SELECT content_type_declared FROM attachments WHERE id = ${oldShapedId}`;
    expect(oldRows).toEqual([{ content_type_declared: false }]);
  });

  it("upgrade from 0034 backfills non-octet as declared and ambiguous octet as unknown", async () => {
    const rows = await upgrade.client`
      SELECT id, content_type, content_type_declared
      FROM attachments WHERE session_id = ${upgradeSessionId}
      ORDER BY id`;
    const byId = new Map(rows.map((row) => [row.id as string, row]));
    expect(byId.get(historicalOctetId)).toMatchObject({
      content_type: "application/octet-stream",
      content_type_declared: false,
    });
    expect(byId.get(historicalDefaultId)).toMatchObject({
      content_type: "application/octet-stream",
      content_type_declared: false,
    });
    expect(byId.get(historicalTextId)).toMatchObject({
      content_type: "text/plain",
      content_type_declared: true,
    });
  });

  it("manual migration replay is idempotent and preserves an explicit octet declaration", async () => {
    const explicit = await attachments.create(upgradeDb, {
      id: newId(),
      sessionId: upgradeSessionId,
      userId: "task3-0035-user",
      name: "new-explicit.bin",
      size: 4,
      r2Key: "history/new-explicit",
      contentType: "application/octet-stream",
    });
    expect(explicit.contentTypeDeclared).toBe(true);

    await applyMigrationFile(upgrade.client, MIGRATION_PATH);
    const rows = await upgrade.client`
      SELECT content_type, content_type_declared FROM attachments WHERE id = ${explicit.id}`;
    expect(rows).toEqual([{
      content_type: "application/octet-stream",
      content_type_declared: true,
    }]);
  });
});
