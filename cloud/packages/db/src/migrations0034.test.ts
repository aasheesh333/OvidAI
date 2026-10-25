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
import { eventMirror, messages, newId, runs, sessions, users } from "./repos.js";
import { admitDispatches, type AdmissionRequest } from "./subagentAdmission.js";

const MIGRATION_PATH = fileURLToPath(
  new URL("../drizzle/0034_subagent_lifecycle.sql", import.meta.url),
);
const SNAPSHOT_PATH = fileURLToPath(
  new URL("../drizzle/meta/0034_snapshot.json", import.meta.url),
);
const JOURNAL_PATH = fileURLToPath(new URL("../drizzle/meta/_journal.json", import.meta.url));
const migrationSql = existsSync(MIGRATION_PATH) ? readFileSync(MIGRATION_PATH, "utf8") : "";
const lifecycleTables = [
  "subagent_session_admission",
  "subagent_batches",
  "subagent_dispatches",
  "subagent_logical_workers",
  "subagent_attempts",
  "subagent_reports",
  "subagent_checkpoints",
  "subagent_control_audit",
  "subagent_roots",
  "subagent_root_finalizations",
] as const;

describe("0034 subagent lifecycle migration metadata", () => {
  it("preserves the journal-wide 0031 to 0033 to 0034 chain with increasing timestamps", () => {
    const journal = JSON.parse(readFileSync(JOURNAL_PATH, "utf8")) as {
      entries: Array<{ idx: number; tag: string; when: number }>;
    };
    const lineage = journal.entries.filter((candidate) => [31, 33, 34].includes(candidate.idx));
    expect(lineage.map((candidate) => candidate.tag)).toEqual([
      "0031_attachment_provider_connections",
      "0033_system_requests_outbox",
      "0034_subagent_lifecycle",
    ]);
    for (let index = 1; index < lineage.length; index += 1) {
      expect(lineage[index]!.when).toBeGreaterThan(lineage[index - 1]!.when);
    }
    expect(journal.entries.filter((candidate) => candidate.idx === 34)).toHaveLength(1);
  });

  it("has a current snapshot and the required active/deferred/finalization indexes", () => {
    expect(existsSync(SNAPSHOT_PATH)).toBe(true);
    const snapshot = existsSync(SNAPSHOT_PATH)
      ? JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8"))
      : { tables: {}, id: "", prevId: "" };
    const previous = JSON.parse(readFileSync(
      fileURLToPath(new URL("../drizzle/meta/0033_snapshot.json", import.meta.url)),
      "utf8",
    )) as { id: string; tables: Record<string, unknown> };
    expect(snapshot.prevId).toBe(previous.id);
    const columnCount = Object.values(snapshot.tables as Record<string, { columns: Record<string, unknown> }>)
      .reduce((sum, table) => sum + Object.keys(table.columns).length, 0);
    // 538 = the 537-column lineage baseline plus 0034 subagent_dispatches.temperature.
    expect({ tables: Object.keys(snapshot.tables).length, columns: columnCount })
      .toEqual({ tables: 56, columns: 538 });
    expect(Object.keys(snapshot.tables).sort())
      .toEqual(expect.arrayContaining(Object.keys(previous.tables).sort()));
    for (const [table, definition] of Object.entries(previous.tables)) {
      expect(snapshot.tables[table], `preserve entire 0033 table ${table}`).toEqual(definition);
    }
    expect(snapshot.tables["public.users"]?.columns.response_wait_seconds)
      .toMatchObject({ type: "integer", notNull: true, default: 45 });
    expect(snapshot.tables["public.billing_purchases"]?.columns.period)
      .toMatchObject({ type: "text", notNull: false });
    for (const table of [
      "system_requests",
      "system_request_responses",
      "run_outbox",
      "billing_entitlement_events",
    ]) {
      expect(snapshot.tables[`public.${table}`], `cumulative 0033 table ${table}`).toBeDefined();
    }
    for (const table of lifecycleTables) {
      expect(snapshot.tables[`public.${table}`], table).toBeDefined();
    }
    const attempts = snapshot.tables["public.subagent_attempts"];
    const dispatches = snapshot.tables["public.subagent_dispatches"];
    const finals = snapshot.tables["public.subagent_root_finalizations"];
    expect(Object.keys(attempts?.indexes ?? {})).toEqual(expect.arrayContaining([
      "subagent_attempts_session_active_idx",
      "subagent_attempts_one_active_worker_uq",
    ]));
    expect(Object.keys(dispatches?.indexes ?? {})).toEqual(expect.arrayContaining([
      "subagent_dispatches_session_state_idx",
    ]));
    expect(Object.keys(finals?.indexes ?? {})).toEqual(expect.arrayContaining([
      "subagent_root_finalizations_epoch_uq",
    ]));
  });

  it("is additive and does not rewrite legacy history", () => {
    expect(migrationSql).not.toBe("");
    expect(migrationSql).not.toMatch(/\bDROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT)\b/i);
    expect(migrationSql).not.toMatch(/\bRENAME\s+(TO|COLUMN)\b/i);
    expect(migrationSql).not.toMatch(/\b(?:UPDATE|INSERT\s+INTO)\s+"?(?:sessions|messages|runs|session_event_mirror)"?/i);
  });
});

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL).sequential("0034 against real Postgres", () => {
  let fresh: MigrationScratch;
  let upgrade: MigrationScratch;
  let freshDb: Db;
  let upgradeDb: Db;
  let legacySessionId: string;
  let legacyChildSessionId: string;
  let legacyMessageId: string;
  let legacyChildMessageId: string;
  let legacyChildRunId: string;

  beforeAll(async () => {
    [fresh, upgrade] = await Promise.all([
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0034_fresh"),
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0034_upgrade"),
    ]);
    await Promise.all([migrate(fresh.url), migrateThrough(upgrade.url, 30)]);

    legacySessionId = newId();
    legacyChildSessionId = newId();
    legacyMessageId = newId();
    const legacyRootRunId = newId();
    legacyChildRunId = newId();
    legacyChildMessageId = newId();
    await upgrade.client`INSERT INTO users (uid, email) VALUES ('task5-legacy-user', NULL)`;
    await upgrade.client`INSERT INTO sessions (id, user_id, title) VALUES
      (${legacySessionId}, 'task5-legacy-user', 'legacy parent'),
      (${legacyChildSessionId}, 'task5-legacy-user', 'legacy child')`;
    await upgrade.client`INSERT INTO messages (id, session_id, role, content) VALUES
      (${legacyMessageId}, ${legacySessionId}, 'user', 'legacy root remains canonical'),
      (${legacyChildMessageId}, ${legacyChildSessionId}, 'user', 'legacy child prompt remains canonical')`;
    await upgrade.client`INSERT INTO runs (id, session_id, status, prompt_message_id, started_at) VALUES
      (${legacyRootRunId}, ${legacySessionId}, 'running', ${legacyMessageId}, now()),
      (${legacyChildRunId}, ${legacyChildSessionId}, 'completed', ${legacyChildMessageId}, now())`;
    await upgrade.client`INSERT INTO session_event_mirror (session_id, seq, type, payload, ts) VALUES
      (${legacySessionId}, '1-0', 'subagent_started', ${JSON.stringify({
        runId: legacyRootRunId,
        childSessionId: legacyChildSessionId,
        childRunId: legacyChildRunId,
        prompt: "bounded preview only",
        agentType: "general-purpose",
      })}::jsonb, now()),
      (${legacySessionId}, '2-0', 'subagent_requested', ${JSON.stringify({
        runId: legacyRootRunId,
        prompt: "unbacked request preview",
      })}::jsonb, now())`;

    await migrate(upgrade.url);
    freshDb = createDb(fresh.url, { max: 8 });
    upgradeDb = createDb(upgrade.url, { max: 2 });
  }, 180_000);

  afterAll(async () => {
    await freshDb?.$client.end({ timeout: 5 });
    await upgradeDb?.$client.end({ timeout: 5 });
    await Promise.all([fresh?.close(), upgrade?.close()]);
  }, 30_000);

  it("fresh install supports concurrent 50/51 admission through the real migrator", async () => {
    const userId = "task5-fresh-user";
    await users.ensure(freshDb, userId, null);
    const parent = await sessions.create(freshDb, userId, "fresh concurrent");
    const prompt = await messages.append(freshDb, {
      sessionId: parent.id, role: "user", content: "fresh root",
    });
    const root = await runs.create(freshDb, { sessionId: parent.id, promptMessageId: prompt.id });
    expect(await runs.claimNext(freshDb, root.id)).toBe(true);
    const second = createDb(fresh.url, { max: 2 });
    try {
      const makeRequests = (batchId: string, count: number, provenance: "web" | "android") =>
        Array.from({ length: count }, (_, index): AdmissionRequest => ({
          requestId: newId(), index, sessionId: parent.id, userId,
          rootTaskRunId: root.id, parentRunId: root.id, batchId,
          prompt: `fresh-${provenance}-${index}`, provenance,
          requestedAt: new Date(Date.now() - 1000 + index),
          modelContext: {
            requestedModel: null, byokKeyId: null, actorUserId: userId,
          },
        }));
      const [a, b] = await Promise.all([
        admitDispatches(freshDb, makeRequests(newId(), 26, "web")),
        admitDispatches(second, makeRequests(newId(), 25, "android")),
      ]);
      expect([...a, ...b].filter((outcome) => outcome.admission === "admitted")).toHaveLength(50);
      expect([...a, ...b].filter((outcome) => outcome.admission === "awaiting_next_user_task")).toHaveLength(1);
      const counts = await fresh.client`
        SELECT
          (SELECT count(*)::int FROM subagent_attempts WHERE session_id = ${parent.id} AND status = 'running') AS active,
          (SELECT count(*)::int FROM subagent_dispatches WHERE session_id = ${parent.id} AND state = 'awaiting_next_user_task') AS awaiting,
          (SELECT count(*)::int FROM run_usage WHERE session_id = ${parent.id}) AS usage_rows`;
      expect(counts[0]).toEqual({ active: 50, awaiting: 1, usage_rows: 0 });
    } finally {
      await second.$client.end({ timeout: 5 });
    }
  }, 180_000);

  it("upgrade preserves legacy event/message/run readers without inferred deferred or checkpoint lineage", async () => {
    const message = await messages.get(upgradeDb, legacyMessageId);
    expect(message?.content).toBe("legacy root remains canonical");
    const events = await eventMirror.readSince(upgradeDb, legacySessionId, null, 10);
    expect(events.map((event) => event.type)).toEqual(["subagent_started", "subagent_requested"]);
    expect(events[0]?.payload).toMatchObject({
      childSessionId: legacyChildSessionId,
      childRunId: legacyChildRunId,
      prompt: "bounded preview only",
    });
    const oldRun = await upgrade.client`
      SELECT id, session_id, status, prompt_message_id FROM runs WHERE id = ${legacyChildRunId}`;
    expect(oldRun).toEqual([{
      id: legacyChildRunId,
      session_id: legacyChildSessionId,
      status: "completed",
      prompt_message_id: legacyChildMessageId,
    }]);
    const admissionRows = await upgrade.client`
      SELECT session_id FROM subagent_session_admission ORDER BY session_id`;
    expect(admissionRows.map((row) => row.session_id).sort()).toEqual(
      [legacySessionId, legacyChildSessionId].sort(),
    );
    for (const table of lifecycleTables.filter((name) => name !== "subagent_session_admission")) {
      const rows = await upgrade.client.unsafe(`SELECT count(*)::int AS count FROM ${table}`);
      expect(rows[0]?.count, table).toBe(0);
    }
    const oldMessages = await upgrade.client`
      SELECT id, session_id, role, content FROM messages WHERE id = ${legacyMessageId}`;
    expect(oldMessages).toEqual([{
      id: legacyMessageId,
      session_id: legacySessionId,
      role: "user",
      content: "legacy root remains canonical",
    }]);
  });

  it("journal idempotence and manual replay preserve the lifecycle constraints", async () => {
    await migrate(fresh.url);
    await applyMigrationFile(fresh.client, MIGRATION_PATH);
    const tables = await fresh.client`
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name LIKE 'subagent_%'`;
    expect(tables.map((row) => row.table_name).sort()).toEqual([...lifecycleTables].sort());
    const indexes = await fresh.client`
      SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname IN
        ('subagent_attempts_one_active_worker_uq', 'subagent_root_finalizations_epoch_uq',
         'subagent_dispatches_session_state_idx')`;
    expect(indexes).toHaveLength(3);
    const root = (await fresh.client`
      SELECT root_task_run_id, session_id FROM subagent_roots LIMIT 1`)[0]!;
    expect(root).toBeDefined();
    await fresh.client`
      INSERT INTO subagent_root_finalizations
        (id, root_task_run_id, session_id, execution_epoch, active_attempt_ids)
      VALUES (${newId()}, ${root.root_task_run_id}, ${root.session_id}, 1, '[]'::jsonb)`;
    await expect(fresh.client`
      INSERT INTO subagent_root_finalizations
        (id, root_task_run_id, session_id, execution_epoch, active_attempt_ids)
      VALUES (${newId()}, ${root.root_task_run_id}, ${root.session_id}, 1, '[]'::jsonb)`)
      .rejects.toMatchObject({ code: "23505" });
  });
});
