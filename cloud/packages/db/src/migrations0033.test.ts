import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { migrate } from "./client.js";
import {
  applyMigrationFile,
  createMigrationScratch,
  migrateThrough,
  type MigrationScratch,
} from "./migrationTestKit.js";
import { newId } from "./repos.js";

const MIGRATION_PATH = fileURLToPath(
  new URL("../drizzle/0033_system_requests_outbox.sql", import.meta.url),
);
const SNAPSHOT_PATH = fileURLToPath(
  new URL("../drizzle/meta/0033_snapshot.json", import.meta.url),
);
const JOURNAL_PATH = fileURLToPath(new URL("../drizzle/meta/_journal.json", import.meta.url));
const migrationSql = existsSync(MIGRATION_PATH) ? readFileSync(MIGRATION_PATH, "utf8") : "";

const newTables = [
  "system_requests",
  "system_request_responses",
  "run_outbox",
  "billing_entitlement_events",
] as const;

describe("0033 system requests/outbox migration metadata", () => {
  it("allocates exactly one chronological 0033 entry after 0031 and before 0034", () => {
    const journal = JSON.parse(readFileSync(JOURNAL_PATH, "utf8")) as {
      entries: Array<{ idx: number; tag: string; when: number }>;
    };
    const positions = journal.entries
      .map((entry, position) => ({ entry, position }))
      .filter(({ entry }) => entry.idx === 33);
    expect(positions).toHaveLength(1);
    const [{ entry, position }] = positions;
    const previous = journal.entries[position - 1];
    expect(entry.tag).toBe("0033_system_requests_outbox");
    expect(previous?.tag).toBe("0031_attachment_provider_connections");
    expect(journal.entries[position + 1]?.tag).toBe("0034_subagent_lifecycle");
    expect(entry.when).toBeGreaterThan(previous!.when);
    // migrateThrough() filters by numeric idx and Drizzle gates by newest
    // timestamp. Numeric/timestamp order must therefore stay identical.
    for (const next of journal.entries.slice(position + 1)) {
      expect(next.when).toBeGreaterThan(entry.when);
    }
  });

  it("uses the real 0031 snapshot and contains the durable contract and required indexes", () => {
    expect(existsSync(SNAPSHOT_PATH)).toBe(true);
    const snapshot = existsSync(SNAPSHOT_PATH)
      ? JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8"))
      : { tables: {}, id: "", prevId: "" };
    const previous = JSON.parse(readFileSync(
      fileURLToPath(new URL("../drizzle/meta/0031_snapshot.json", import.meta.url)),
      "utf8",
    )) as { id: string };
    expect(snapshot.prevId).toBe(previous.id);
    for (const table of newTables) {
      expect(snapshot.tables[`public.${table}`], table).toBeDefined();
    }
    // Parallel reserved snapshots converge additively; 0034/0035 history is
    // neither rewritten nor incorrectly included in this 0031-based snapshot.
    expect(snapshot.tables["public.mcp_servers"]?.columns.provider_id).toBeDefined();
    expect(snapshot.tables["public.subagent_roots"]).toBeUndefined();
    expect(snapshot.tables["public.attachments"]?.columns.content_type_declared).toBeUndefined();

    const requests = snapshot.tables["public.system_requests"];
    expect(Object.keys(requests?.columns ?? {})).toEqual(expect.arrayContaining([
      "request_id", "user_id", "session_id", "run_id", "kind", "safe_payload",
      "sensitive", "status", "expires_at", "version",
    ]));
    expect(Object.keys(requests?.indexes ?? {})).toEqual(expect.arrayContaining([
      "system_requests_user_status_idx",
      "system_requests_session_status_idx",
    ]));
    const responses = snapshot.tables["public.system_request_responses"];
    expect(Object.keys(responses?.indexes ?? {})).toEqual(expect.arrayContaining([
      "system_request_responses_request_version_uq",
      "system_request_responses_client_response_uq",
    ]));
    const outbox = snapshot.tables["public.run_outbox"];
    expect(Object.keys(outbox?.indexes ?? {})).toEqual(expect.arrayContaining([
      "run_outbox_actor_idempotency_uq",
      "run_outbox_job_uq",
      "run_outbox_status_idx",
      "run_outbox_status_attempt_idx",
    ]));
    expect(outbox?.indexes.run_outbox_actor_idempotency_uq?.columns.map((c: { expression: string }) => c.expression))
      .toEqual(["actor_user_id", "idempotency_key"]);
    expect(outbox?.indexes.run_outbox_job_uq?.isUnique).toBe(true);
  });

  it("keeps response-wait bounded and billing period nullable with no monthly fallback", () => {
    const snapshot = existsSync(SNAPSHOT_PATH)
      ? JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8"))
      : { tables: {} };
    const wait = snapshot.tables["public.users"]?.columns.response_wait_seconds;
    expect(wait).toMatchObject({ type: "integer", notNull: true, default: 45 });
    for (const table of ["public.billing_purchases", "public.billing_entitlement_events"]) {
      expect(snapshot.tables[table]?.columns.period).toMatchObject({
        name: "period",
        type: "text",
        notNull: false,
      });
      expect(snapshot.tables[table]?.columns.period).not.toHaveProperty("default");
    }
    expect(migrationSql).toContain("response_wait_seconds");
    expect(migrationSql).toMatch(/response_wait_seconds[^\n]*15[^\n]*600|15[^\n]*response_wait_seconds[^\n]*600/i);
    expect(migrationSql).not.toMatch(/period[^\n]*DEFAULT\s+'monthly'/i);
  });

  it("is additive, forward-only, replayable, and does not rewrite existing preferences/history", () => {
    expect(migrationSql).not.toBe("");
    expect(migrationSql).not.toMatch(/\bDROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT)\b/i);
    expect(migrationSql).not.toMatch(/\bRENAME\s+(TO|COLUMN)\b/i);
    expect(migrationSql).not.toMatch(/\bUPDATE\s+"?(?:users|billing_purchases|sessions|messages|runs)"?/i);
    expect(migrationSql).not.toMatch(/\bDELETE\s+FROM\b/i);
    expect(migrationSql).toContain("CREATE TABLE IF NOT EXISTS");
    expect(migrationSql).toContain("ADD COLUMN IF NOT EXISTS");
  });
});

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL).sequential("0033 against isolated real Postgres", () => {
  let fresh: MigrationScratch;
  let upgrade: MigrationScratch;
  const legacyUid = "legacy-0033-user";
  const legacySessionId = newId();
  const legacyMessageId = newId();
  const legacyRunId = newId();
  const legacyToken = "legacy-purchase-0033";
  const legacyPreferences = {
    memoryEnabled: false,
    shareSessionMemory: true,
    customPresets: [{ id: "existing", label: "Existing", model: null }],
  };

  beforeAll(async () => {
    [fresh, upgrade] = await Promise.all([
      createMigrationScratch(TEST_DATABASE_URL!, "migration_0033_fresh"),
      createMigrationScratch(TEST_DATABASE_URL!, "migration_0033_upgrade"),
    ]);
    await Promise.all([migrate(fresh.url), migrateThrough(upgrade.url, 30)]);

    await upgrade.client`INSERT INTO users (uid, email, preferences)
      VALUES (${legacyUid}, NULL, ${upgrade.client.json(legacyPreferences)}::jsonb)`;
    await upgrade.client`INSERT INTO sessions (id, user_id, title)
      VALUES (${legacySessionId}, ${legacyUid}, 'legacy 0030 session')`;
    await upgrade.client`INSERT INTO messages (id, session_id, role, content)
      VALUES (${legacyMessageId}, ${legacySessionId}, 'user', 'legacy body remains canonical')`;
    await upgrade.client`INSERT INTO runs (id, session_id, status, prompt_message_id, started_at)
      VALUES (${legacyRunId}, ${legacySessionId}, 'completed', ${legacyMessageId}, now())`;
    await upgrade.client`INSERT INTO billing_purchases
      (token, uid, product_id, tier, status, expires_at, auto_renewing, updated_at)
      VALUES (${legacyToken}, ${legacyUid}, 'legacy-yearly-product', 'plus', 'active', 1893456000, true, 1792800000)`;

    await migrate(upgrade.url);
  }, 180_000);

  afterAll(async () => {
    await Promise.all([fresh?.close(), upgrade?.close()]);
  }, 30_000);

  it("fresh install supports old-shaped users and defaults only response wait, never billing period", async () => {
    const tables = await fresh.client`
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name IN
        ('system_requests','system_request_responses','run_outbox','billing_entitlement_events')`;
    expect(tables.map((row) => row.table_name).sort()).toEqual([...newTables].sort());

    const uid = "fresh-old-reader-0033";
    await fresh.client`INSERT INTO users (uid, email) VALUES (${uid}, NULL)`;
    const rows = await fresh.client`
      SELECT preferences, response_wait_seconds FROM users WHERE uid = ${uid}`;
    expect(rows).toEqual([{ preferences: {}, response_wait_seconds: 45 }]);
    await expect(fresh.client`UPDATE users SET response_wait_seconds = 14 WHERE uid = ${uid}`)
      .rejects.toMatchObject({ code: "23514" });
    await expect(fresh.client`UPDATE users SET response_wait_seconds = 601 WHERE uid = ${uid}`)
      .rejects.toMatchObject({ code: "23514" });
  });

  it("upgrade from populated 0030 preserves legacy readers and invents no monthly entitlement", async () => {
    const userRows = await upgrade.client`
      SELECT uid, email, tier, preferences, response_wait_seconds FROM users WHERE uid = ${legacyUid}`;
    expect(userRows).toEqual([{
      uid: legacyUid,
      email: null,
      tier: "free",
      preferences: legacyPreferences,
      response_wait_seconds: 45,
    }]);
    const oldPurchaseReader = await upgrade.client`
      SELECT token, uid, product_id, tier, status, expires_at, auto_renewing,
        linked_token, account_hash, updated_at
      FROM billing_purchases WHERE token = ${legacyToken}`;
    expect(oldPurchaseReader).toEqual([{
      token: legacyToken,
      uid: legacyUid,
      product_id: "legacy-yearly-product",
      tier: "plus",
      status: "active",
      expires_at: "1893456000",
      auto_renewing: true,
      linked_token: null,
      account_hash: null,
      updated_at: "1792800000",
    }]);
    const period = await upgrade.client`
      SELECT period FROM billing_purchases WHERE token = ${legacyToken}`;
    expect(period).toEqual([{ period: null }]);
    const oldTranscriptReader = await upgrade.client`
      SELECT m.id, m.session_id, m.role, m.content, r.id AS run_id, r.status
      FROM messages m JOIN runs r ON r.prompt_message_id = m.id WHERE m.id = ${legacyMessageId}`;
    expect(oldTranscriptReader).toEqual([{
      id: legacyMessageId,
      session_id: legacySessionId,
      role: "user",
      content: "legacy body remains canonical",
      run_id: legacyRunId,
      status: "completed",
    }]);
  });

  it("entitlement events and purchases persist unknown period as NULL and reject invented periods", async () => {
    await upgrade.client`INSERT INTO billing_entitlement_events
      (event_id, user_id, product_id, tier, purchase_state, event_type)
      VALUES ('evt-0033-unknown-period', ${legacyUid}, 'unconfigured-yearly', NULL, 'active', 'INITIAL_PURCHASE')`;
    const rows = await upgrade.client`
      SELECT event_id, user_id, product_id, tier, period, purchase_state, expires_at, occurred_at
      FROM billing_entitlement_events WHERE event_id = 'evt-0033-unknown-period'`;
    expect(rows).toEqual([{
      event_id: "evt-0033-unknown-period",
      user_id: legacyUid,
      product_id: "unconfigured-yearly",
      tier: null,
      period: null,
      purchase_state: "active",
      expires_at: null,
      occurred_at: null,
    }]);
    await expect(upgrade.client`INSERT INTO billing_entitlement_events
      (event_id, purchase_state, event_type, period)
      VALUES ('evt-0033-duplicate', 'active', 'RENEWAL', 'monthly')`)
      .resolves.toBeDefined();
    await expect(upgrade.client`INSERT INTO billing_entitlement_events
      (event_id, purchase_state, event_type, period)
      VALUES ('evt-0033-duplicate', 'active', 'RENEWAL', 'yearly')`)
      .rejects.toMatchObject({ code: "23505" });
    await expect(upgrade.client`INSERT INTO billing_entitlement_events
      (event_id, purchase_state, event_type, period)
      VALUES ('evt-0033-invalid-period', 'active', 'RENEWAL', 'weekly')`)
      .rejects.toMatchObject({ code: "23514" });
  });

  it("journal idempotence and manual replay preserve tables, indexes, events, and constraints", async () => {
    await migrate(upgrade.url);
    await applyMigrationFile(upgrade.client, MIGRATION_PATH);
    const indexes = await upgrade.client`
      SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname IN
        ('system_requests_user_status_idx','system_request_responses_request_version_uq',
         'system_request_responses_client_response_uq','run_outbox_actor_idempotency_uq',
         'run_outbox_job_uq','run_outbox_status_idx','run_outbox_status_attempt_idx')`;
    expect(indexes).toHaveLength(7);
    const event = await upgrade.client`
      SELECT event_id, period FROM billing_entitlement_events WHERE event_id = 'evt-0033-unknown-period'`;
    expect(event).toEqual([{ event_id: "evt-0033-unknown-period", period: null }]);
    await expect(upgrade.client`UPDATE users SET response_wait_seconds = 0 WHERE uid = ${legacyUid}`)
      .rejects.toMatchObject({ code: "23514" });
    const legacy = await upgrade.client`
      SELECT preferences FROM users WHERE uid = ${legacyUid}`;
    expect(legacy).toEqual([{ preferences: legacyPreferences }]);
  });
});
