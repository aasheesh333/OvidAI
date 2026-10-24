import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { attachments, newId, sessions, users } from "./repos.js";
import { createDb, migrate, type Db } from "./client.js";
import {
  applyMigrationFile,
  createMigrationScratch,
  migrateThrough,
  type MigrationScratch,
} from "./migrationTestKit.js";

const MIGRATION_PATH = fileURLToPath(
  new URL("../drizzle/0031_attachment_provider_connections.sql", import.meta.url),
);
const SNAPSHOT_PATH = fileURLToPath(
  new URL("../drizzle/meta/0031_snapshot.json", import.meta.url),
);
const JOURNAL_PATH = fileURLToPath(new URL("../drizzle/meta/_journal.json", import.meta.url));
const migrationSql = existsSync(MIGRATION_PATH) ? readFileSync(MIGRATION_PATH, "utf8") : "";

describe("0031 attachment/provider-connection migration metadata", () => {
  it("allocates only journal entry 31, immediately after 0030", () => {
    const journal = JSON.parse(readFileSync(JOURNAL_PATH, "utf8")) as {
      entries: Array<{ idx: number; tag: string; when: number }>;
    };
    const entry = journal.entries.find((candidate) => candidate.idx === 31);
    const previous = journal.entries.find((candidate) => candidate.idx === 30);
    expect(entry?.tag).toBe("0031_attachment_provider_connections");
    expect(previous?.tag).toBe("0030_notification_claim_lease");
    expect(entry!.when).toBeGreaterThan(previous!.when);
    expect(journal.entries.filter((candidate) => candidate.idx === 31)).toHaveLength(1);
  });

  it("has a current snapshot containing the additive attachment and connection fields", () => {
    expect(existsSync(SNAPSHOT_PATH)).toBe(true);
    const snapshot = existsSync(SNAPSHOT_PATH)
      ? JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8"))
      : { tables: {} };
    const attachmentColumns = snapshot.tables["public.attachments"]?.columns ?? {};
    const connectionColumns = snapshot.tables["public.mcp_servers"]?.columns ?? {};
    expect(Object.keys(attachmentColumns)).toEqual(expect.arrayContaining([
      "content_type",
      "upload_status",
      "actual_bytes",
      "actual_content_type",
      "finalized_at",
    ]));
    expect(Object.keys(connectionColumns)).toEqual(expect.arrayContaining([
      "provider_id",
      "agent_enabled",
      "auth_state",
      "health_state",
      "last_checked_at",
      "last_success_at",
      "config_version",
      "disconnect_generation",
      "approved_source_id",
      "approved_digest",
      "normalized_connection_name",
    ]));
  });

  it("is additive and contains no down-migration cleanup", () => {
    expect(migrationSql).not.toBe("");
    expect(migrationSql).not.toMatch(/\bDROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT)\b/i);
    expect(migrationSql).not.toMatch(/\bRENAME\s+(TO|COLUMN)\b/i);
  });
});

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL)("0031 against real Postgres", () => {
  let fresh: MigrationScratch;
  let upgrade: MigrationScratch;
  let db: Db;
  let freshSessionId: string;
  let upgradeSessionId: string;
  let legacyAttachmentId: string;
  let curatedConnectionId: string;
  let customConnectionId: string;

  beforeAll(async () => {
    [fresh, upgrade] = await Promise.all([
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0031_fresh"),
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0031_upgrade"),
    ]);
    await Promise.all([migrate(fresh.url), migrateThrough(upgrade.url, 30)]);

    freshSessionId = newId();
    await fresh.client`INSERT INTO users (uid, email) VALUES ('task2-fresh-user', 'fresh@test.local')`;
    await fresh.client`INSERT INTO sessions (id, user_id, title)
      VALUES (${freshSessionId}, 'task2-fresh-user', 'fresh')`;

    upgradeSessionId = newId();
    legacyAttachmentId = newId();
    curatedConnectionId = newId();
    customConnectionId = newId();
    await upgrade.client`INSERT INTO users (uid, email) VALUES
      ('task2-upgrade-user', 'upgrade@test.local'),
      ('task2-other-user', 'other@test.local')`;
    await upgrade.client`INSERT INTO sessions (id, user_id, title)
      VALUES (${upgradeSessionId}, 'task2-upgrade-user', 'legacy')`;
    await upgrade.client`INSERT INTO attachments (id, session_id, user_id, name, size, r2_key)
      VALUES (${legacyAttachmentId}, ${upgradeSessionId}, 'task2-upgrade-user', 'legacy.png', 1234, 'legacy/object')`;
    await upgrade.client`INSERT INTO mcp_servers
      (id, user_id, name, transport, curated_id, config, enabled)
      VALUES (${curatedConnectionId}, 'task2-upgrade-user', 'GitHub', 'http', 'github',
        '{"url":"https://example.invalid"}'::jsonb, true)`;
    await upgrade.client`INSERT INTO mcp_servers (id, user_id, name, transport, enabled)
      VALUES (${customConnectionId}, 'task2-upgrade-user', '  Mixed   Name  ', 'http', false)`;

    // Upgrade the populated 0030 install through the real drizzle migrator.
    await migrate(upgrade.url);
    db = createDb(fresh.url, { max: 4 });
  }, 180_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await Promise.all([fresh?.close(), upgrade?.close()]);
  }, 30_000);

  it("fresh install and old-shaped writes get truthful attachment/connection defaults", async () => {
    const attachmentId = newId();
    await fresh.client`INSERT INTO attachments (id, session_id, user_id, name, size, r2_key)
      VALUES (${attachmentId}, ${freshSessionId}, 'task2-fresh-user', 'old-client.bin', 12, 'fresh/old-client')`;
    const attachmentRows = await fresh.client`
      SELECT content_type, upload_status, actual_bytes, actual_content_type, finalized_at
      FROM attachments WHERE id = ${attachmentId}`;
    expect(attachmentRows).toEqual([{
      content_type: "application/octet-stream",
      upload_status: "pending",
      actual_bytes: null,
      actual_content_type: null,
      finalized_at: null,
    }]);

    const connectionId = newId();
    await fresh.client`INSERT INTO mcp_servers (id, user_id, name, transport, curated_id)
      VALUES (${connectionId}, 'task2-fresh-user', 'Legacy writer', 'http', 'legacy-provider')`;
    const connectionRows = await fresh.client`
      SELECT provider_id, agent_enabled, auth_state, health_state,
        last_checked_at, last_success_at, config_version, disconnect_generation,
        approved_source_id, approved_digest, normalized_connection_name
      FROM mcp_servers WHERE id = ${connectionId}`;
    expect(connectionRows).toEqual([{
      provider_id: null,
      agent_enabled: false,
      auth_state: "unknown",
      health_state: "never_checked",
      last_checked_at: null,
      last_success_at: null,
      config_version: 1,
      disconnect_generation: 0,
      approved_source_id: null,
      approved_digest: null,
      normalized_connection_name: null,
    }]);
  });

  it("upgrade preserves old rows without inventing activation, health, or actual upload history", async () => {
    const attachmentRows = await upgrade.client`
      SELECT name, size, content_type, upload_status, actual_bytes, actual_content_type, finalized_at
      FROM attachments WHERE id = ${legacyAttachmentId}`;
    expect(attachmentRows).toEqual([{
      name: "legacy.png",
      size: 1234,
      content_type: "application/octet-stream",
      upload_status: "pending",
      actual_bytes: null,
      actual_content_type: null,
      finalized_at: null,
    }]);

    const rows = await upgrade.client`
      SELECT id, provider_id, agent_enabled, auth_state, health_state,
        last_checked_at, last_success_at, config_version, disconnect_generation,
        approved_source_id, approved_digest, normalized_connection_name
      FROM mcp_servers WHERE id IN (${curatedConnectionId}, ${customConnectionId}) ORDER BY id`;
    expect(rows).toHaveLength(2);
    const curated = rows.find((row) => row.id === curatedConnectionId)!;
    expect(curated).toEqual({
      id: curatedConnectionId,
      provider_id: "github",
      agent_enabled: false,
      auth_state: "unknown",
      health_state: "never_checked",
      last_checked_at: null,
      last_success_at: null,
      config_version: 1,
      disconnect_generation: 0,
      approved_source_id: null,
      approved_digest: null,
      normalized_connection_name: "github",
    });
    const custom = rows.find((row) => row.id === customConnectionId)!;
    expect(custom).toMatchObject({
      provider_id: null,
      agent_enabled: false,
      auth_state: "unknown",
      health_state: "never_checked",
      last_checked_at: null,
      last_success_at: null,
      config_version: 1,
      disconnect_generation: 0,
      approved_source_id: null,
      approved_digest: null,
      normalized_connection_name: "mixed   name",
    });
  });

  it("keeps legacy attachment and connection readers on their original columns", async () => {
    const oldAttachments = await upgrade.client`
      SELECT id, session_id, user_id, name, size, r2_key, message_id, created_at
      FROM attachments WHERE id = ${legacyAttachmentId}`;
    expect(oldAttachments).toHaveLength(1);
    expect(oldAttachments[0]).toMatchObject({
      id: legacyAttachmentId,
      session_id: upgradeSessionId,
      user_id: "task2-upgrade-user",
      name: "legacy.png",
      size: 1234,
      r2_key: "legacy/object",
      message_id: null,
    });
    const oldConnections = await upgrade.client`
      SELECT id, user_id, name, transport, curated_id, config, secrets_sealed, enabled
      FROM mcp_servers WHERE id = ${curatedConnectionId}`;
    expect(oldConnections).toEqual([{
      id: curatedConnectionId,
      user_id: "task2-upgrade-user",
      name: "GitHub",
      transport: "http",
      curated_id: "github",
      config: { url: "https://example.invalid" },
      secrets_sealed: null,
      enabled: true,
    }]);
  });

  it("enforces curated and custom identity across legacy NULL fields", async () => {
    // A pre-0031 writer can still leave provider_id NULL; curated_id is the
    // evidenced fallback and must not become a uniqueness bypass.
    await expect(upgrade.client`INSERT INTO mcp_servers
      (id, user_id, name, transport, curated_id, provider_id)
      VALUES (${newId()}, 'task2-upgrade-user', 'Another GitHub', 'http', 'github', NULL)`)
      .rejects.toMatchObject({ code: "23505" });
    await expect(upgrade.client`INSERT INTO mcp_servers
      (id, user_id, name, transport, curated_id, provider_id)
      VALUES (${newId()}, 'task2-other-user', 'Other GitHub', 'http', 'github', NULL)`)
      .resolves.toBeDefined();

    // A NULL normalized name/source uses the legacy name and the same empty
    // source identity; it cannot bypass custom uniqueness by case or NULL.
    await expect(upgrade.client`INSERT INTO mcp_servers
      (id, user_id, name, transport, normalized_connection_name, approved_source_id)
      VALUES (${newId()}, 'task2-upgrade-user', 'MIXED   NAME', 'http', NULL, NULL)`)
      .rejects.toMatchObject({ code: "23505" });

    const approvedId = newId();
    await upgrade.client`INSERT INTO mcp_servers
      (id, user_id, name, transport, normalized_connection_name, approved_source_id)
      VALUES (${approvedId}, 'task2-upgrade-user', 'Mixed   Name', 'http', NULL, 'source-one')`;
    await expect(upgrade.client`INSERT INTO mcp_servers
      (id, user_id, name, transport, normalized_connection_name, approved_source_id)
      VALUES (${newId()}, 'task2-upgrade-user', 'mixed   name', 'http', NULL, 'source-one')`)
      .rejects.toMatchObject({ code: "23505" });
  });

  it("repository create/get round-trips canonical type and finalization fields", async () => {
    const typed = await attachments.create(db, {
      id: newId(),
      sessionId: freshSessionId,
      userId: "task2-fresh-user",
      name: "typed.bin",
      size: 42,
      r2Key: "fresh/typed",
      contentType: "application/x-ovid-unknown",
    });
    expect(typed).toMatchObject({
      contentType: "application/x-ovid-unknown",
      uploadStatus: "pending",
      actualBytes: null,
      actualContentType: null,
      finalizedAt: null,
    });

    const legacy = await attachments.create(db, {
      id: newId(),
      sessionId: freshSessionId,
      userId: "task2-fresh-user",
      name: "legacy.bin",
      size: 1,
      r2Key: "fresh/repository-legacy",
    });
    expect(legacy.contentType).toBe("application/octet-stream");
    const rows = await attachments.getForSession(db, freshSessionId);
    expect(rows.find((row) => row.id === typed.id)?.contentType).toBe("application/x-ovid-unknown");
    expect(rows.find((row) => row.id === legacy.id)?.contentType).toBe("application/octet-stream");
  });

  it("journal idempotence and manual replay leave the schema and legacy rows intact", async () => {
    await migrate(fresh.url);
    await applyMigrationFile(fresh.client, MIGRATION_PATH);
    const columns = await fresh.client`
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'attachments'
        AND column_name IN ('content_type', 'upload_status', 'actual_bytes', 'actual_content_type', 'finalized_at')`;
    expect(columns).toHaveLength(5);
    const legacy = await upgrade.client`
      SELECT content_type, upload_status, actual_content_type FROM attachments WHERE id = ${legacyAttachmentId}`;
    expect(legacy).toEqual([{
      content_type: "application/octet-stream",
      upload_status: "pending",
      actual_content_type: null,
    }]);
  });
});
