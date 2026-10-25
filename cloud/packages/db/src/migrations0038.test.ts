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
import { messages, newId, runs, sessions, users } from "./repos.js";
import { RunQuotaService } from "./quotaService.js";

const MIGRATION_PATH = fileURLToPath(
  new URL("../drizzle/0038_usage_billing_windows.sql", import.meta.url),
);
const SNAPSHOT_PATH = fileURLToPath(
  new URL("../drizzle/meta/0038_snapshot.json", import.meta.url),
);
const JOURNAL_PATH = fileURLToPath(new URL("../drizzle/meta/_journal.json", import.meta.url));
const migrationSql = existsSync(MIGRATION_PATH) ? readFileSync(MIGRATION_PATH, "utf8") : "";
const QUOTA_TABLES = [
  "usage_quota_counters",
  "usage_run_admissions",
  "usage_quota_reservations",
  "upload_window_counters",
  "storage_usage_counters",
  "storage_reservations",
  "image_usage_facts",
] as const;

describe("0038 usage billing windows migration metadata", () => {
  it("preserves the journal-wide 0031 to 0038 chain with increasing timestamps", () => {
    const journal = JSON.parse(readFileSync(JOURNAL_PATH, "utf8")) as {
      entries: Array<{ idx: number; tag: string; when: number }>;
    };
    const lineage = journal.entries.filter((candidate) => [31, 33, 34, 35, 38].includes(candidate.idx));
    expect(lineage.map((candidate) => candidate.tag)).toEqual([
      "0031_attachment_provider_connections",
      "0033_system_requests_outbox",
      "0034_subagent_lifecycle",
      "0035_attachment_declaration_presence",
      "0038_usage_billing_windows",
    ]);
    for (let index = 1; index < lineage.length; index += 1) {
      expect(lineage[index]!.when).toBeGreaterThan(lineage[index - 1]!.when);
    }
    expect(journal.entries.filter((candidate) => candidate.idx === 38)).toHaveLength(1);
  });

  it("uses the real 0035 snapshot and contains every quota/upload/usage/image contract field", () => {
    expect(existsSync(SNAPSHOT_PATH)).toBe(true);
    const snapshot = existsSync(SNAPSHOT_PATH)
      ? JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8"))
      : { tables: {}, id: "", prevId: "" };
    const previous = JSON.parse(readFileSync(
      fileURLToPath(new URL("../drizzle/meta/0035_snapshot.json", import.meta.url)),
      "utf8",
    )) as { id: string; tables: Record<string, unknown> };
    expect(snapshot.prevId).toBe(previous.id);
    const columnCount = Object.values(snapshot.tables as Record<string, { columns: Record<string, unknown> }>)
      .reduce((sum, table) => sum + Object.keys(table.columns).length, 0);
    // 624 = the 620-column lineage baseline plus 0034 subagent_dispatches.temperature
    // and 0038 billing_class on run_usage, usage_run_admissions, usage_quota_reservations.
    expect({ tables: Object.keys(snapshot.tables).length, columns: columnCount })
      .toEqual({ tables: 63, columns: 624 });
    expect(Object.keys(snapshot.tables).sort())
      .toEqual(expect.arrayContaining(Object.keys(previous.tables).sort()));
    for (const [table, definition] of Object.entries(previous.tables)) {
      if (table === "public.run_usage") continue;
      expect(snapshot.tables[table], `preserve entire 0035 table ${table}`).toEqual(definition);
    }
    const actualRunUsage = structuredClone(snapshot.tables["public.run_usage"]);
    const expectedRunUsage = structuredClone(previous.tables["public.run_usage"]);
    for (const column of [
      "quota_reservation_id", "quota_call_id", "attempt_id", "requested_model",
      "provider_model", "cost_usd", "cost_source", "billing_class",
    ]) {
      delete actualRunUsage.columns[column];
    }
    for (const index of [
      "run_usage_session_created_idx",
      "run_usage_quota_reservation_uq",
      "run_usage_run_quota_call_uq",
    ]) {
      delete actualRunUsage.indexes[index];
    }
    expect(actualRunUsage).toEqual(expectedRunUsage);
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
      .toMatchObject({ type: "boolean", notNull: true, default: false });
    for (const table of QUOTA_TABLES) {
      expect(snapshot.tables[`public.${table}`], table).toBeDefined();
    }

    const reservations = snapshot.tables["public.usage_quota_reservations"];
    for (const column of [
      "actor_user_id",
      "run_id",
      "attempt_id",
      "reservation_key",
      "state",
      "input_tokens",
      "max_output_tokens",
      "reserved_cost_usd",
      "requested_model",
      "provider_model",
      "cost_usd",
    ]) {
      expect(reservations?.columns[column], `reservation ${column}`).toBeDefined();
    }
    expect(reservations?.columns.requested_model.notNull).toBe(false);
    expect(reservations?.columns.provider_model.notNull).toBe(false);
    expect(reservations?.columns.cost_usd.notNull).toBe(false);
    expect(reservations?.columns.cost_usd.type).toMatch(/^numeric\(38,\s*10\)$/);
    expect(Object.keys(reservations?.indexes ?? {})).toEqual(expect.arrayContaining([
      "usage_quota_reservations_actor_key_uq",
      "usage_quota_reservations_actor_window_idx",
      "usage_quota_reservations_run_attempt_idx",
    ]));

    const runUsage = snapshot.tables["public.run_usage"];
    for (const column of [
      "quota_reservation_id",
      "quota_call_id",
      "attempt_id",
      "requested_model",
      "provider_model",
      "cost_usd",
      "cost_source",
      "billing_class",
    ]) {
      expect(runUsage?.columns[column], `run_usage ${column}`).toMatchObject({ notNull: column === "billing_class" });
    }
    expect(runUsage?.columns.billing_class.default).toBe("'ovid_allowance'");
    expect(runUsage?.columns.cost_usd.type).toMatch(/^numeric\(38,\s*10\)$/);

    const legacyImages = snapshot.tables["public.image_jobs"];
    const imageFacts = snapshot.tables["public.image_usage_facts"];
    for (const column of ["session_id", "run_id", "generate_count", "edit_count", "cost_usd"]) {
      expect(legacyImages?.columns[column], `legacy image_jobs ${column}`).toBeUndefined();
      expect(imageFacts?.columns[column], `image_usage_facts ${column}`).toMatchObject({ notNull: false });
    }
    expect(imageFacts?.columns.cost_usd.type).toMatch(/^numeric\(38,\s*10\)$/);

    const storage = snapshot.tables["public.storage_reservations"];
    for (const column of [
      "actor_user_id",
      "owner_user_id",
      "session_id",
      "declared_bytes",
      "actual_bytes",
      "actual_content_type",
      "etag",
      "state",
    ]) {
      expect(storage?.columns[column], `storage ${column}`).toBeDefined();
    }
    expect(storage?.columns.actual_bytes.notNull).toBe(false);
    expect(storage?.columns.actual_content_type.notNull).toBe(false);
    expect(Object.keys(storage?.indexes ?? {})).toEqual(expect.arrayContaining([
      "storage_reservations_actor_state_window_idx",
      "storage_reservations_owner_state_idx",
    ]));
  });

  it("is additive/replayable and never rewrites legacy ledgers or prior migrations", () => {
    expect(migrationSql).not.toBe("");
    expect(migrationSql).toContain("CREATE TABLE IF NOT EXISTS");
    expect(migrationSql).toContain("ADD COLUMN IF NOT EXISTS");
    expect(migrationSql).toContain("ON CONFLICT");
    expect(migrationSql).not.toMatch(/\bDROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT|TRIGGER)\b/i);
    expect(migrationSql).not.toMatch(/\bRENAME\s+(TO|COLUMN)\b/i);
    expect(migrationSql).not.toMatch(/\b(?:UPDATE|INSERT\s+INTO)\s+"?(?:run_usage|image_jobs)"?/i);
  });
});

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL).sequential("0038 against isolated real Postgres", () => {
  let fresh: MigrationScratch;
  let upgrade: MigrationScratch;
  let freshDb: Db;
  let upgradeDb: Db;
  let legacyUserId: string;
  let legacySessionId: string;
  let legacyRunId: string;
  let legacyUsageId: string;

  beforeAll(async () => {
    [fresh, upgrade] = await Promise.all([
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0038_fresh"),
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0038_upgrade"),
    ]);
    await Promise.all([migrate(fresh.url), migrateThrough(upgrade.url, 30)]);

    legacyUserId = newId();
    legacySessionId = newId();
    legacyRunId = newId();
    legacyUsageId = newId();
    const legacyMessageId = newId();
    await upgrade.client`INSERT INTO users (uid, email) VALUES (${legacyUserId}, NULL)`;
    await upgrade.client`INSERT INTO sessions (id, user_id, title)
      VALUES (${legacySessionId}, ${legacyUserId}, 'legacy quota reader')`;
    await upgrade.client`INSERT INTO messages (id, session_id, role, content)
      VALUES (${legacyMessageId}, ${legacySessionId}, 'user', 'legacy quota reader')`;
    await upgrade.client`INSERT INTO runs (id, session_id, status, prompt_message_id)
      VALUES (${legacyRunId}, ${legacySessionId}, 'completed', ${legacyMessageId})`;
    await upgrade.client`INSERT INTO run_usage
      (id, user_id, session_id, run_id, model, input_tokens, output_tokens, created_at)
      VALUES (${legacyUsageId}, ${legacyUserId}, ${legacySessionId}, ${legacyRunId},
              'legacy-model', 5, 2, '2026-10-24T08:00:00.000Z')`;
    await upgrade.client`INSERT INTO image_jobs
      (account, request, fingerprint, state, reserved, charged, actual, budget_window, created_at)
      VALUES (${legacyUserId}, 'legacy-image', 'fingerprint', 'done', '0.1', '0.1', NULL, '2026-10', 1792800000)`;

    await migrate(upgrade.url);
    freshDb = createDb(fresh.url, { max: 8 });
    upgradeDb = createDb(upgrade.url, { max: 4 });
  }, 180_000);

  afterAll(async () => {
    await freshDb?.$client.end({ timeout: 5 });
    await upgradeDb?.$client.end({ timeout: 5 });
    await Promise.all([fresh?.close(), upgrade?.close()]);
  }, 30_000);

  it("fresh installs keep old-shaped run/image writes readable with nullable unknowns", async () => {
    const uid = newId();
    const sessionId = newId();
    const runId = newId();
    const messageId = newId();
    const usageId = newId();
    await users.ensure(freshDb, uid, null);
    await fresh.client`INSERT INTO sessions (id, user_id, title) VALUES (${sessionId}, ${uid}, 'old writer')`;
    await fresh.client`INSERT INTO messages (id, session_id, role, content)
      VALUES (${messageId}, ${sessionId}, 'user', 'old writer')`;
    await fresh.client`INSERT INTO runs (id, session_id, status, prompt_message_id)
      VALUES (${runId}, ${sessionId}, 'completed', ${messageId})`;
    await fresh.client`INSERT INTO run_usage (id, user_id, session_id, run_id, model)
      VALUES (${usageId}, ${uid}, ${sessionId}, ${runId}, 'legacy')`;
    await fresh.client`INSERT INTO image_jobs
      (account, request, fingerprint, state, reserved, charged, budget_window, created_at)
      VALUES (${uid}, 'old-image', 'old-fingerprint', 'pending', '0', '0', '2026-10', 1792800000)`;

    const usage = await fresh.client`
      SELECT id, model, input_tokens, output_tokens, quota_reservation_id, quota_call_id,
             attempt_id, requested_model, provider_model, cost_usd, cost_source
        FROM run_usage WHERE id = ${usageId}`;
    expect(usage).toEqual([{
      id: usageId,
      model: "legacy",
      input_tokens: 0,
      output_tokens: 0,
      quota_reservation_id: null,
      quota_call_id: null,
      attempt_id: null,
      requested_model: null,
      provider_model: null,
      cost_usd: null,
      cost_source: null,
    }]);
    await fresh.client`INSERT INTO image_usage_facts (account, request) VALUES (${uid}, 'old-image')`;
    const image = await fresh.client`
      SELECT i.request, i.state, f.session_id, f.run_id, f.generate_count, f.edit_count, f.cost_usd
        FROM image_jobs i
        LEFT JOIN image_usage_facts f ON f.account = i.account AND f.request = i.request
       WHERE i.account = ${uid} AND i.request = 'old-image'`;
    expect(image).toEqual([{
      request: "old-image",
      state: "pending",
      session_id: null,
      run_id: null,
      generate_count: null,
      edit_count: null,
      cost_usd: null,
    }]);
  });

  it("upgrade from 0030 preserves legacy readers and backfills only evidenced usage counters", async () => {
    const oldUsage = await upgrade.client`
      SELECT id, user_id, session_id, run_id, model, input_tokens, output_tokens
        FROM run_usage WHERE id = ${legacyUsageId}`;
    expect(oldUsage).toEqual([{
      id: legacyUsageId,
      user_id: legacyUserId,
      session_id: legacySessionId,
      run_id: legacyRunId,
      model: "legacy-model",
      input_tokens: 5,
      output_tokens: 2,
    }]);
    const oldImage = await upgrade.client`
      SELECT i.request, i.fingerprint, i.state, i.reserved, i.charged, i.actual,
             f.session_id, f.run_id, f.generate_count, f.edit_count, f.cost_usd
        FROM image_jobs i
        LEFT JOIN image_usage_facts f ON f.account = i.account AND f.request = i.request
       WHERE i.account = ${legacyUserId} AND i.request = 'legacy-image'`;
    expect(oldImage).toEqual([{
      request: "legacy-image",
      fingerprint: "fingerprint",
      state: "done",
      reserved: "0.1",
      charged: "0.1",
      actual: null,
      session_id: null,
      run_id: null,
      generate_count: null,
      edit_count: null,
      cost_usd: null,
    }]);
    const counters = await upgrade.client`
      SELECT window_kind, used_tokens::int, reserved_tokens::int, used_usd::text, reserved_usd::text
        FROM usage_quota_counters WHERE actor_user_id = ${legacyUserId} ORDER BY window_kind`;
    expect(counters).toEqual([
      { window_kind: "day", used_tokens: 7, reserved_tokens: 0, used_usd: "0.0000000000", reserved_usd: "0.0000000000" },
      { window_kind: "month", used_tokens: 7, reserved_tokens: 0, used_usd: "0.0000000000", reserved_usd: "0.0000000000" },
    ]);
    for (const table of QUOTA_TABLES) {
      const tables = await upgrade.client`
        SELECT count(*)::int AS count FROM information_schema.tables
         WHERE table_schema = 'public' AND table_name = ${table}`;
      expect(tables[0]?.count, table).toBe(1);
    }
  });

  it("journal idempotence and manual replay preserve one trigger and one exact charge", async () => {
    await migrate(fresh.url);
    await applyMigrationFile(fresh.client, MIGRATION_PATH);
    const triggerRows = await fresh.client`
      SELECT count(*)::int AS count FROM pg_trigger
       WHERE tgname = 'run_usage_quota_counters_0038' AND NOT tgisinternal`;
    expect(triggerRows).toEqual([{ count: 1 }]);

    const uid = newId();
    const sessionId = newId();
    const runId = newId();
    const messageId = newId();
    const usageId = newId();
    await users.ensure(freshDb, uid, null);
    await fresh.client`INSERT INTO sessions (id, user_id, title) VALUES (${sessionId}, ${uid}, 'replay')`;
    await fresh.client`INSERT INTO messages (id, session_id, role, content)
      VALUES (${messageId}, ${sessionId}, 'user', 'replay')`;
    await fresh.client`INSERT INTO runs (id, session_id, status, prompt_message_id)
      VALUES (${runId}, ${sessionId}, 'completed', ${messageId})`;
    await fresh.client`INSERT INTO run_usage
      (id, user_id, session_id, run_id, model, input_tokens, output_tokens, cost_usd)
      VALUES (${usageId}, ${uid}, ${sessionId}, ${runId}, 'replay', 1, 1, 0.0000000001)`;
    await applyMigrationFile(fresh.client, MIGRATION_PATH);
    const counters = await fresh.client`
      SELECT used_tokens::int, used_usd::text FROM usage_quota_counters
       WHERE actor_user_id = ${uid} AND window_kind = 'day'`;
    expect(counters).toEqual([{ used_tokens: 2, used_usd: "0.0000000001" }]);
    const triggerRowsAfter = await fresh.client`
      SELECT count(*)::int AS count FROM pg_trigger
       WHERE tgname = 'run_usage_quota_counters_0038' AND NOT tgisinternal`;
    expect(triggerRowsAfter).toEqual([{ count: 1 }]);
  });

  it("enforces reservation identity/state checks and a real two-instance cap race after migration", async () => {
    const uid = newId();
    await users.ensure(freshDb, uid, null);
    const session = await sessions.create(freshDb, uid, "race");
    const prompt = await messages.append(freshDb, { sessionId: session.id, role: "user", content: "race" });
    const run = await runs.create(freshDb, { sessionId: session.id, promptMessageId: prompt.id });
    const second = createDb(fresh.url, { max: 2 });
    const third = createDb(fresh.url, { max: 2 });
    try {
      const options = {
        now: () => new Date("2026-10-24T12:00:00.000Z"),
        tokenCaps: { perDay: 50, perMonth: 50 },
      };
      const [a, b] = await Promise.all([
        new RunQuotaService(second, options).reserveModelCall({
          actorUserId: uid, runId: run.id, reservationKey: "migration-race-a",
          inputTokens: 50, maxOutputTokens: 0,
        }),
        new RunQuotaService(third, options).reserveModelCall({
          actorUserId: uid, runId: run.id, reservationKey: "migration-race-b",
          inputTokens: 50, maxOutputTokens: 0,
        }),
      ]);
      expect([a, b].filter((result) => result.ok)).toHaveLength(1);
      const identity = await fresh.client`
        SELECT count(*)::int AS count FROM usage_quota_reservations
         WHERE actor_user_id = ${uid} AND reservation_key IN ('migration-race-a', 'migration-race-b')`;
      expect(identity[0]?.count).toBe(1);
      await expect(fresh.client`
        INSERT INTO usage_quota_reservations
          (id, actor_user_id, run_id, reservation_key, state, input_tokens, max_output_tokens,
           day_window_start, month_window_start, reserved_at, updated_at)
        VALUES (${newId()}, ${uid}, ${run.id}, 'bad-state', 'invalid', 0, 0,
                '2026-10-24T00:00:00.000Z', '2026-10-01T00:00:00.000Z', now(), now())`)
        .rejects.toMatchObject({ code: "23514" });
    } finally {
      await second.$client.end({ timeout: 5 });
      await third.$client.end({ timeout: 5 });
    }
  });
});
