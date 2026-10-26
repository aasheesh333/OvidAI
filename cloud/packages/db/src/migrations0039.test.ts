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
import { appendExactItem, readExactHistory } from "./compactionRepos.js";
import { messages, newId, runs, sessions, users } from "./repos.js";
import { admitDispatches, settleAttemptAndMaybeWake } from "./subagentAdmission.js";

// FIX ROUND 2 executable-chain/legacy-history regressions are UNEXECUTED under
// HEAVY-COMMANDS-PAUSED.md. Historical migration logs predate every fix round.
const MIGRATION_PATH = fileURLToPath(
  new URL("../drizzle/0039_lossless_compaction.sql", import.meta.url),
);
const SNAPSHOT_PATH = fileURLToPath(
  new URL("../drizzle/meta/0039_snapshot.json", import.meta.url),
);
const JOURNAL_PATH = fileURLToPath(new URL("../drizzle/meta/_journal.json", import.meta.url));
const migrationSql = existsSync(MIGRATION_PATH) ? readFileSync(MIGRATION_PATH, "utf8") : "";
const COMPACTION_TABLES = [
  "compaction_history_items",
  "compaction_checkpoints",
  "compaction_cursors",
] as const;
const LEGACY_SECRET = "sk-legacy-0039-existing-canonical-only-41b8d0";

describe("0039 lossless compaction migration metadata", () => {
  it("extends the ordered 0038 journal exactly once", () => {
    const journal = JSON.parse(readFileSync(JOURNAL_PATH, "utf8")) as {
      entries: Array<{ idx: number; tag: string; when: number }>;
    };
    const lineage = journal.entries.filter((candidate) => [31, 33, 34, 35, 38, 39].includes(candidate.idx));
    expect(lineage.map((candidate) => candidate.tag)).toEqual([
      "0031_attachment_provider_connections",
      "0033_system_requests_outbox",
      "0034_subagent_lifecycle",
      "0035_attachment_declaration_presence",
      "0038_usage_billing_windows",
      "0039_lossless_compaction",
    ]);
    for (let index = 1; index < lineage.length; index += 1) {
      expect(lineage[index]!.when).toBeGreaterThan(lineage[index - 1]!.when);
    }
    expect(journal.entries.filter((candidate) => candidate.idx === 39)).toHaveLength(1);
  });

  it("uses cumulative 0038 and adds only exact-history, checkpoint and cursor contracts", () => {
    expect(existsSync(SNAPSHOT_PATH)).toBe(true);
    const snapshot = existsSync(SNAPSHOT_PATH)
      ? JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8"))
      : { tables: {}, id: "", prevId: "" };
    const previous = JSON.parse(readFileSync(
      fileURLToPath(new URL("../drizzle/meta/0038_snapshot.json", import.meta.url)),
      "utf8",
    )) as { id: string; tables: Record<string, unknown> };
    expect(snapshot.prevId).toBe(previous.id);
    expect(Object.keys(snapshot.tables)).toHaveLength(Object.keys(previous.tables).length + 3);
    for (const [table, definition] of Object.entries(previous.tables)) {
      expect(snapshot.tables[table], `preserve entire 0038 table ${table}`).toEqual(definition);
    }
    for (const table of COMPACTION_TABLES) {
      expect(snapshot.tables[`public.${table}`], table).toBeDefined();
    }
    const checkpoints = snapshot.tables["public.compaction_checkpoints"];
    for (const column of [
      "checkpoint_id", "compaction_id", "root_task_run_id", "logical_worker_id", "attempt_id",
      "model", "context_limit", "before_tokens", "after_tokens", "usage_source",
      "cutoff_cursor", "ledger_version", "continuation",
    ]) {
      expect(checkpoints?.columns[column], column).toBeDefined();
    }
    for (const column of [
      "root_task_run_id", "logical_worker_id", "attempt_id", "model", "context_limit",
      "before_tokens", "after_tokens", "usage_source", "summary", "created_at",
    ]) {
      expect(checkpoints?.columns[column]?.notNull, `historical ${column} remains nullable`).toBe(false);
    }
    const history = snapshot.tables["public.compaction_history_items"];
    expect(Object.keys(history?.indexes ?? {})).toEqual(expect.arrayContaining([
      "compaction_history_scope_position_idx",
      "compaction_history_reference_idx",
      "compaction_history_identity_uq",
    ]));
    const cursors = snapshot.tables["public.compaction_cursors"];
    expect(Object.keys(cursors?.indexes ?? {})).toEqual(expect.arrayContaining([
      "compaction_cursors_worker_idx",
      "compaction_cursors_checkpoint_idx",
    ]));
  });

  it("is additive/replayable and never rewrites canonical history or prior migrations", () => {
    expect(migrationSql).not.toBe("");
    expect(migrationSql).toContain("CREATE TABLE IF NOT EXISTS");
    expect(migrationSql).toContain("ON CONFLICT");
    expect(migrationSql).not.toMatch(/\bDROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT|TRIGGER)\b/i);
    expect(migrationSql).not.toMatch(/\bRENAME\s+(TO|COLUMN)\b/i);
    expect(migrationSql).not.toMatch(/\b(?:UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+"?(?:sessions|messages|runs|session_event_mirror|session_agent_state|system_requests|system_request_responses|workspace_objects|attachments)"?/i);
  });
});

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL).sequential("0039 against isolated real Postgres — FIX ROUND 2 UNEXECUTED", () => {
  let fresh: MigrationScratch;
  let upgrade: MigrationScratch;
  let upgrade30: MigrationScratch;
  let executableChain: MigrationScratch;
  let freshDb: Db;
  let upgradeDb: Db;
  let upgrade30Db: Db;
  let executableChainDb: Db;
  let legacyUserId: string;
  let legacySessionId: string;
  let legacyRootRunId: string;
  let legacyMessageId: string;
  let legacyToolMessageId: string;
  let legacyApprovalId: string;
  let legacyArtifactId: string;
  let legacyChildSessionId: string;
  let legacyChildRunId: string;
  let legacyWorkerId: string;
  let legacyAttemptId: string;
  let legacyChildApprovalId: string;
  let legacyChildResponseId: string;
  let legacyVersionedApprovalId: string;
  let legacyVersionedResponseV1Id: string;
  let legacyVersionedResponseV2Id: string;
  let legacySubagentCheckpointId: string;
  let legacyControlId: string;
  let legacyLaterRootRunId: string;
  let chainSessionId: string;
  let chainRootRunId: string;
  let chainChildSessionId: string;
  let chainWorkerId: string;
  let chainAttemptId: string;
  let chainChildRunId: string;
  let chainApprovalId: string;
  let chainResponseId: string;
  let chainChildPromptMessageId: string;
  let legacy30SessionId: string;
  let legacy30MessageId: string;

  beforeAll(async () => {
    [fresh, upgrade, upgrade30, executableChain] = await Promise.all([
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0039_fresh"),
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0039_upgrade"),
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0039_up30"),
      createMigrationScratch(TEST_DATABASE_URL!, "contracts_0039_chain"),
    ]);
    await Promise.all([
      migrate(fresh.url),
      migrateThrough(upgrade.url, 38),
      migrateThrough(upgrade30.url, 30),
      migrateThrough(executableChain.url, 38),
    ]);

    legacyUserId = newId();
    legacySessionId = newId();
    legacyRootRunId = newId();
    legacyMessageId = newId();
    legacyToolMessageId = newId();
    legacyApprovalId = `legacy-approval-${newId()}`;
    legacyArtifactId = newId();
    await upgrade.client`INSERT INTO users (uid, email) VALUES (${legacyUserId}, NULL)`;
    await upgrade.client`INSERT INTO sessions (id, user_id, title)
      VALUES (${legacySessionId}, ${legacyUserId}, 'legacy exact compaction')`;
    await upgrade.client`INSERT INTO messages (id, session_id, role, content, reasoning) VALUES
      (${legacyMessageId}, ${legacySessionId}, 'user', ${`legacy canonical ${LEGACY_SECRET}`}, NULL),
      (${legacyToolMessageId}, ${legacySessionId}, 'tool', 'legacy full tool result remains exact', NULL)`;
    await upgrade.client`INSERT INTO runs (id, session_id, status, prompt_message_id)
      VALUES (${legacyRootRunId}, ${legacySessionId}, 'running', ${legacyMessageId})`;
    await upgrade.client`INSERT INTO session_event_mirror (session_id, seq, type, payload, ts) VALUES
      (${legacySessionId}, '1-0', 'tool_terminal', ${upgrade.client.json({ runId: legacyRootRunId, exact: "event-payload" })}, '2026-10-24T08:00:00.000Z')`;
    await upgrade.client`INSERT INTO system_requests
      (request_id, user_id, session_id, run_id, kind, safe_payload, sensitive, status, expires_at, version)
      VALUES (${legacyApprovalId}, ${legacyUserId}, ${legacySessionId}, ${legacyRootRunId},
              'approval', '{"tool":"run_shell","summary":"legacy approval"}'::jsonb,
              false, 'resolved', '2026-10-24T23:00:00.000Z', 1)`;
    await upgrade.client`INSERT INTO system_request_responses
      (response_id, request_id, user_id, request_version, client_response_id, response, response_digest)
      VALUES (${newId()}, ${legacyApprovalId}, ${legacyUserId}, 1, ${`legacy-response-${newId()}`},
              '{"decision":"allow"}'::jsonb, ${"a".repeat(64)})`;
    await upgrade.client`INSERT INTO workspace_objects
      (id, user_id, session_id, kind, r2_key, bytes, sha256, content_type)
      VALUES (${legacyArtifactId}, ${legacyUserId}, ${legacySessionId}, 'artifact',
              'legacy/exact/artifact.txt', 23, ${"b".repeat(64)}, 'text/plain')`;
    await upgrade.client`INSERT INTO session_agent_state (session_id, state) VALUES (
      ${legacySessionId},
      ${upgrade.client.json({
        compaction: {
          ledger: { v: 1, folded: 2 },
          summary: `legacy model summary ${LEGACY_SECRET}`,
          cutoffMessageId: legacyMessageId,
          compactedAtCount: 3,
        },
      })})`;

    // Actual 0034 lineage, not a guessed child/root relationship. These rows
    // exist before 0039 so the backfill must map child runs to their real root.
    upgradeDb = createDb(upgrade.url, { max: 4 });
    const [child] = await admitDispatches(upgradeDb, [{
      requestId: newId(), index: 0, sessionId: legacySessionId, userId: legacyUserId,
      rootTaskRunId: legacyRootRunId, parentRunId: legacyRootRunId,
      batchId: newId(), prompt: "legacy child exact history", provenance: "server",
      requestedAt: new Date("2026-10-24T08:01:00.000Z"),
      modelContext: { requestedModel: null, byokKeyId: null, actorUserId: legacyUserId },
    }]);
    expect(child?.admission).toBe("admitted");
    legacyChildSessionId = child!.childSessionId!;
    legacyChildRunId = child!.childRunId!;
    legacyWorkerId = child!.logicalWorkerId!;
    legacyAttemptId = child!.attemptId!;
    legacySubagentCheckpointId = newId();
    legacyControlId = newId();
    await upgrade.client`INSERT INTO subagent_checkpoints
      (id, session_id, logical_worker_id, attempt_id, root_task_run_id, hash, verified_at)
      VALUES (${legacySubagentCheckpointId}, ${legacySessionId}, ${legacyWorkerId}, ${legacyAttemptId},
        ${legacyRootRunId}, 'legacy-checkpoint-hash', '2026-10-24T08:01:30.000Z')`;
    await upgrade.client`INSERT INTO subagent_control_audit
      (id, session_id, actor_run_id, root_task_run_id, logical_worker_id, source_attempt_id, action, decision)
      VALUES (${legacyControlId}, ${legacySessionId}, ${legacyRootRunId}, ${legacyRootRunId},
        ${legacyWorkerId}, ${legacyAttemptId}, 'legacy-worker-control', 'performed')`;
    const legacyLaterRootMessageId = newId();
    legacyLaterRootRunId = newId();
    await upgrade.client`INSERT INTO messages (id, session_id, role, content)
      VALUES (${legacyLaterRootMessageId}, ${legacySessionId}, 'user', 'later root after legacy history')`;
    await upgrade.client`INSERT INTO runs (id, session_id, status, prompt_message_id)
      VALUES (${legacyLaterRootRunId}, ${legacySessionId}, 'running', ${legacyLaterRootMessageId})`;
    await upgrade.client`INSERT INTO session_event_mirror (session_id, seq, type, payload, ts)
      VALUES (${legacySessionId}, '2-0', 'tool_terminal', ${upgrade.client.json({
        runId: legacyChildRunId,
        logicalWorkerId: legacyWorkerId,
        attemptId: legacyAttemptId,
        exact: "legacy-child-event",
      })}, '2026-10-24T08:02:00.000Z')`;
    legacyChildApprovalId = `legacy-child-approval-${newId()}`;
    legacyChildResponseId = newId();
    await upgrade.client`INSERT INTO system_requests
      (request_id, user_id, session_id, run_id, kind, safe_payload, sensitive, status, expires_at, version)
      VALUES (${legacyChildApprovalId}, ${legacyUserId}, ${legacySessionId}, ${legacyChildRunId},
        'approval', '{"tool":"run_shell","summary":"legacy child approval"}'::jsonb,
        false, 'resolved', '2026-10-24T23:00:00.000Z', 1)`;
    await upgrade.client`INSERT INTO system_request_responses
      (response_id, request_id, user_id, request_version, client_response_id, response, response_digest)
      VALUES (${legacyChildResponseId}, ${legacyChildApprovalId}, ${legacyUserId}, 1,
        ${`legacy-child-response-${newId()}`}, '{"decision":"allow"}'::jsonb, ${"c".repeat(64)})`;

    legacyVersionedApprovalId = `legacy-versioned-approval-${newId()}`;
    legacyVersionedResponseV1Id = newId();
    legacyVersionedResponseV2Id = newId();
    await upgrade.client`INSERT INTO system_requests
      (request_id, user_id, session_id, run_id, kind, safe_payload, sensitive, status, expires_at, version)
      VALUES (${legacyVersionedApprovalId}, ${legacyUserId}, ${legacySessionId}, ${legacyRootRunId},
        'approval', '{"summary":"version one request"}'::jsonb,
        false, 'resolved', '2026-10-24T23:00:00.000Z', 1)`;
    await upgrade.client`INSERT INTO system_request_responses
      (response_id, request_id, user_id, request_version, client_response_id, response, response_digest)
      VALUES (${legacyVersionedResponseV1Id}, ${legacyVersionedApprovalId}, ${legacyUserId}, 1,
        ${`legacy-v1-response-${newId()}`}, '{"decision":"deny-v1"}'::jsonb, ${"d".repeat(64)})`;
    await upgrade.client`UPDATE system_requests SET version = 2,
      safe_payload = '{"summary":"version two request"}'::jsonb
      WHERE request_id = ${legacyVersionedApprovalId}`;
    await upgrade.client`INSERT INTO system_request_responses
      (response_id, request_id, user_id, request_version, client_response_id, response, response_digest)
      VALUES (${legacyVersionedResponseV2Id}, ${legacyVersionedApprovalId}, ${legacyUserId}, 2,
        ${`legacy-v2-response-${newId()}`}, '{"decision":"allow-v2"}'::jsonb, ${"e".repeat(64)})`;

    // UNEXECUTED executable-chain fixture: the real journal must apply 0039
    // and then 0040 to a populated 0038 database, including a child response.
    const chainUserId = newId();
    chainSessionId = newId();
    chainRootRunId = newId();
    chainApprovalId = `chain-approval-${newId()}`;
    chainResponseId = newId();
    const chainPromptId = newId();
    await executableChain.client`INSERT INTO users (uid, email) VALUES (${chainUserId}, NULL)`;
    await executableChain.client`INSERT INTO sessions (id, user_id, title)
      VALUES (${chainSessionId}, ${chainUserId}, 'real 0038-0039-0040 chain')`;
    await executableChain.client`INSERT INTO messages (id, session_id, role, content)
      VALUES (${chainPromptId}, ${chainSessionId}, 'user', 'chain root')`;
    await executableChain.client`INSERT INTO runs (id, session_id, status, prompt_message_id)
      VALUES (${chainRootRunId}, ${chainSessionId}, 'running', ${chainPromptId})`;
    executableChainDb = createDb(executableChain.url, { max: 4 });
    const [chainChild] = await admitDispatches(executableChainDb, [{
      requestId: newId(), index: 0, sessionId: chainSessionId, userId: chainUserId,
      rootTaskRunId: chainRootRunId, parentRunId: chainRootRunId,
      batchId: newId(), prompt: "chain worker", provenance: "server", requestedAt: new Date(),
      modelContext: { requestedModel: null, byokKeyId: null, actorUserId: chainUserId },
    }]);
    expect(chainChild?.admission).toBe("admitted");
    chainChildSessionId = chainChild!.childSessionId!;
    chainWorkerId = chainChild!.logicalWorkerId!;
    chainAttemptId = chainChild!.attemptId!;
    chainChildRunId = chainChild!.childRunId!;
    await executableChain.client`INSERT INTO system_requests
      (request_id, user_id, session_id, run_id, kind, safe_payload, sensitive, status, expires_at, version)
      VALUES (${chainApprovalId}, ${chainUserId}, ${chainSessionId}, ${chainChildRunId},
        'approval', '{"summary":"chain child approval"}'::jsonb,
        false, 'resolved', '2026-10-24T23:00:00.000Z', 1)`;
    await executableChain.client`INSERT INTO system_request_responses
      (response_id, request_id, user_id, request_version, client_response_id, response, response_digest)
      VALUES (${chainResponseId}, ${chainApprovalId}, ${chainUserId}, 1,
        ${`chain-response-${newId()}`}, '{"decision":"allow"}'::jsonb, ${"f".repeat(64)})`;

    // Two evidenced attempts intentionally share one prompt. The backfill must
    // not choose whichever attempt happens to sort first or relabel a child run
    // as the root when that prompt's worker lineage is ambiguous.
    chainChildPromptMessageId = (await executableChain.client`
      SELECT prompt_message_id FROM subagent_attempts WHERE id = ${chainAttemptId}`)[0]!.prompt_message_id;
    await settleAttemptAndMaybeWake(executableChainDb, {
      attemptId: chainAttemptId, outcome: "completed",
    });
    const repeatedRunId = newId();
    const repeatedAttemptId = newId();
    await executableChain.client`INSERT INTO runs (id, session_id, status, prompt_message_id)
      VALUES (${repeatedRunId}, ${chainChildSessionId}, 'running', ${chainChildPromptMessageId})`;
    await executableChain.client`INSERT INTO subagent_attempts
      (id, logical_worker_id, session_id, root_task_run_id, execution_epoch, attempt_number,
       child_session_id, child_run_id, prompt_message_id, status, admitted_at, started_at)
      VALUES (${repeatedAttemptId}, ${chainWorkerId}, ${chainSessionId}, ${chainRootRunId}, 1, 2,
        ${chainChildSessionId}, ${repeatedRunId}, ${chainChildPromptMessageId},
        'running', now(), now())`;
    await executableChain.client`UPDATE subagent_logical_workers SET status = 'running' WHERE id = ${chainWorkerId}`;
    await executableChain.client`UPDATE subagent_roots SET active_worker_count = 1 WHERE root_task_run_id = ${chainRootRunId}`;
    await migrate(executableChain.url);

    await upgrade30.client`INSERT INTO users (uid, email) VALUES ('task9-upgrade30-user', NULL)`;
    legacy30SessionId = newId();
    legacy30MessageId = newId();
    await upgrade30.client`INSERT INTO sessions (id, user_id, title)
      VALUES (${legacy30SessionId}, 'task9-upgrade30-user', 'upgrade from 0030')`;
    await upgrade30.client`INSERT INTO messages (id, session_id, role, content)
      VALUES (${legacy30MessageId}, ${legacy30SessionId}, 'assistant', '0030 exact assistant history')`;

    await applyMigrationFile(upgrade.client, MIGRATION_PATH);
    await migrate(upgrade30.url);
    freshDb = createDb(fresh.url, { max: 6 });
    upgrade30Db = createDb(upgrade30.url, { max: 2 });
  }, 240_000);

  afterAll(async () => {
    await freshDb?.$client.end({ timeout: 5 });
    await upgradeDb?.$client.end({ timeout: 5 });
    await upgrade30Db?.$client.end({ timeout: 5 });
    await executableChainDb?.$client.end({ timeout: 5 });
    await Promise.all([fresh?.close(), upgrade?.close(), upgrade30?.close(), executableChain?.close()]);
  }, 30_000);

  it("fresh installs preserve old-shaped writes and can recall them by canonical reference", async () => {
    const uid = newId();
    await users.ensure(freshDb, uid, null);
    const session = await sessions.create(freshDb, uid, "fresh old writer");
    const rootMessage = await messages.append(freshDb, {
      sessionId: session.id, role: "user", content: "fresh canonical root",
    });
    const root = await runs.create(freshDb, { sessionId: session.id, promptMessageId: rootMessage.id });
    // Exact history writes require a running main root (stale_root otherwise).
    expect(await runs.claimNext(freshDb, root.id)).toBe(true);
    const legacy = await fresh.client`INSERT INTO messages (id, session_id, role, content)
      VALUES (${newId()}, ${session.id}, 'tool', 'fresh old-shaped tool row') RETURNING id, content`;
    const item = {
      stableId: legacy[0]!.id,
      kind: "message" as const,
      sessionId: session.id,
      rootTaskRunId: root.id,
      logicalWorkerId: null,
      attemptId: null,
      eventCursor: legacy[0]!.id,
      objectRef: `postgres:messages/${legacy[0]!.id}`,
      byteLength: Buffer.byteLength(JSON.stringify(legacy[0])),
    };
    await appendExactItem(freshDb, item);
    const page = await readExactHistory(freshDb, { sessionId: session.id, rootTaskRunId: root.id });
    expect(page.items).toHaveLength(1);
    expect(page.items[0]?.data).toMatchObject({ id: legacy[0]!.id, content: "fresh old-shaped tool row" });
    expect(legacy[0]?.content).toBe("fresh old-shaped tool row");
  });

  it("0038 upgrade recalls exact legacy messages, events, approvals and artifacts with null unknown usage", async () => {
    const page = await readExactHistory(upgradeDb, { sessionId: legacySessionId, limit: 100 });
    const message = page.items.find((entry) => entry.item.stableId === legacyMessageId);
    expect(message?.item.rootTaskRunId).toBe(legacyRootRunId);
    expect(message?.data).toMatchObject({ id: legacyMessageId, content: `legacy canonical ${LEGACY_SECRET}` });
    expect(page.items.find((entry) => entry.item.stableId === legacyToolMessageId)?.data)
      .toMatchObject({ content: "legacy full tool result remains exact" });
    expect(page.items.find((entry) => entry.item.kind === "event")?.data)
      .toMatchObject({ type: "tool_terminal", payload: { exact: "event-payload" } });
    const approval = page.items.find((entry) => entry.item.stableId === legacyApprovalId);
    expect(approval?.data).toMatchObject({
      request_id: legacyApprovalId,
      response_version: 1,
      status: "resolved",
      safe_payload: { tool: "run_shell", summary: "legacy approval" },
      response: { decision: "allow" },
    });
    expect(page.items.find((entry) => entry.item.stableId === legacyArtifactId)?.data)
      .toMatchObject({ id: legacyArtifactId, r2_key: "legacy/exact/artifact.txt", bytes: 23 });

    const legacyCompaction = page.items.find((entry) => entry.item.kind === "compaction");
    expect(legacyCompaction?.data).toMatchObject({
      summary: `legacy model summary ${LEGACY_SECRET}`,
      cutoffMessageId: legacyMessageId,
      compactedAtCount: 3,
    });
    const checkpoints = await upgrade.client`
      SELECT model, context_limit, before_tokens, after_tokens, usage_source, summary,
             root_task_run_id, logical_worker_id, attempt_id, ledger_version, continuation, created_at
        FROM compaction_checkpoints WHERE session_id = ${legacySessionId}`;
    expect(checkpoints).toEqual([{
      model: null,
      context_limit: null,
      before_tokens: null,
      after_tokens: null,
      usage_source: null,
      summary: null,
      root_task_run_id: null,
      logical_worker_id: null,
      attempt_id: null,
      ledger_version: null,
      continuation: null,
      created_at: null,
    }]);
    const newRows = await upgrade.client`
      SELECT summary::text AS summary, active_state::text AS active_state FROM compaction_checkpoints
       WHERE session_id = ${legacySessionId}`;
    expect(JSON.stringify(newRows)).not.toContain(LEGACY_SECRET);
    const [canonical] = await upgrade.client`
      SELECT state->'compaction'->>'summary' AS summary FROM session_agent_state
       WHERE session_id = ${legacySessionId}`;
    expect(canonical?.summary).toBe(`legacy model summary ${LEGACY_SECRET}`);
  });

  it("UNEXECUTED: maps legacy child-run events and approvals through actual attempt lineage", async () => {
    const page = await readExactHistory(upgradeDb, {
      sessionId: legacyChildSessionId,
      rootTaskRunId: legacyRootRunId,
      logicalWorkerId: legacyWorkerId,
      attemptId: legacyAttemptId,
      limit: 100,
    });
    const event = page.items.find((entry) => entry.item.kind === "event");
    expect(event?.item).toMatchObject({
      sessionId: legacyChildSessionId,
      rootTaskRunId: legacyRootRunId,
      logicalWorkerId: legacyWorkerId,
      attemptId: legacyAttemptId,
    });
    expect(event?.data).toMatchObject({ payload: { runId: legacyChildRunId, exact: "legacy-child-event" } });
    expect(page.items.find((entry) => entry.item.stableId === legacyChildApprovalId)?.data)
      .toMatchObject({ request_id: legacyChildApprovalId, run_id: legacyChildRunId, response_version: 1 });
    expect(page.items.find((entry) => entry.item.stableId === legacyChildResponseId)?.data)
      .toMatchObject({ response_id: legacyChildResponseId, request_version: 1 });
    const wronglyScoped = await readExactHistory(upgradeDb, {
      sessionId: legacyChildSessionId,
      rootTaskRunId: legacyChildRunId,
      logicalWorkerId: legacyWorkerId,
      attemptId: legacyAttemptId,
      limit: 100,
    }).catch((error: unknown) => error);
    expect(wronglyScoped).toMatchObject({ code: "actor_mismatch" });
  });

  it("UNEXECUTED: parent-stored legacy worker, attempt, checkpoint and control remain exactly readable", async () => {
    const logicalWorker = await readExactHistory(upgradeDb, {
      sessionId: legacySessionId,
      rootTaskRunId: legacyRootRunId,
      logicalWorkerId: legacyWorkerId,
      attemptId: null,
      reference: { kind: "logical_worker", id: legacyWorkerId },
    });
    expect(logicalWorker.items).toHaveLength(1);
    expect(logicalWorker.items[0]?.item).toMatchObject({
      sessionId: legacySessionId,
      rootTaskRunId: legacyRootRunId,
      logicalWorkerId: legacyWorkerId,
      attemptId: null,
    });
    expect(logicalWorker.items[0]?.data).toMatchObject({ id: legacyWorkerId });

    const attempt = await readExactHistory(upgradeDb, {
      sessionId: legacySessionId,
      rootTaskRunId: legacyRootRunId,
      logicalWorkerId: legacyWorkerId,
      attemptId: legacyAttemptId,
      reference: { kind: "attempt", id: legacyAttemptId },
    });
    expect(attempt.items[0]?.item).toMatchObject({
      sessionId: legacySessionId,
      rootTaskRunId: legacyRootRunId,
      logicalWorkerId: legacyWorkerId,
      attemptId: legacyAttemptId,
    });
    expect(attempt.items[0]?.data).toMatchObject({ id: legacyAttemptId, root_task_run_id: legacyRootRunId });

    const checkpoint = await readExactHistory(upgradeDb, {
      sessionId: legacySessionId,
      rootTaskRunId: legacyRootRunId,
      logicalWorkerId: legacyWorkerId,
      attemptId: legacyAttemptId,
      reference: { kind: "checkpoint", id: legacySubagentCheckpointId },
    });
    expect(checkpoint.items[0]?.data).toMatchObject({ id: legacySubagentCheckpointId });
    const control = await readExactHistory(upgradeDb, {
      sessionId: legacySessionId,
      rootTaskRunId: legacyRootRunId,
      logicalWorkerId: legacyWorkerId,
      attemptId: legacyAttemptId,
      reference: { kind: "control", id: legacyControlId },
    });
    expect(control.items[0]?.data).toMatchObject({ id: legacyControlId });

    const allWorkerHistory = await readExactHistory(upgradeDb, {
      sessionId: legacySessionId,
      rootTaskRunId: legacyRootRunId,
      logicalWorkerId: legacyWorkerId,
      limit: 100,
    });
    expect(allWorkerHistory.items.some((entry) => entry.item.kind === "logical_worker")).toBe(true);
    expect(allWorkerHistory.items.some((entry) => entry.item.kind === "attempt")).toBe(true);
    expect(allWorkerHistory.items.some((entry) => entry.item.kind === "event")).toBe(true);

    // Moving the worker to a later root must not erase or relabel the exact
    // old attempt lineage. Read authorization uses that attempt's actual root;
    // new writes remain latest-root/attempt fenced by a separate code path.
    await upgrade.client`UPDATE subagent_logical_workers
      SET current_root_task_run_id = ${legacyLaterRootRunId} WHERE id = ${legacyWorkerId}`;
    const historical = await readExactHistory(upgradeDb, {
      sessionId: legacySessionId,
      rootTaskRunId: legacyRootRunId,
      logicalWorkerId: legacyWorkerId,
      attemptId: legacyAttemptId,
      reference: { kind: "attempt", id: legacyAttemptId },
    });
    expect(historical.items[0]?.data).toMatchObject({ id: legacyAttemptId, root_task_run_id: legacyRootRunId });

    await expect(readExactHistory(upgradeDb, {
      sessionId: legacySessionId,
      rootTaskRunId: legacyChildRunId,
      logicalWorkerId: legacyWorkerId,
      attemptId: legacyAttemptId,
    })).rejects.toMatchObject({ code: "actor_mismatch" });
  });

  it("UNEXECUTED: real populated 0038 to 0039 to 0040 journal applies response backfill and preserves exact child lineage", async () => {
    const objects = await executableChain.client`
      SELECT to_regclass('compaction_history_items') AS history,
             to_regclass('compaction_checkpoints') AS checkpoints,
             to_regclass('collab_rooms') AS collab`;
    expect(objects).toEqual([{ history: "compaction_history_items", checkpoints: "compaction_checkpoints", collab: "collab_rooms" }]);
    const response = await readExactHistory(executableChainDb, {
      sessionId: chainChildSessionId,
      rootTaskRunId: chainRootRunId,
      logicalWorkerId: chainWorkerId,
      attemptId: chainAttemptId,
      reference: { kind: "approval", id: chainResponseId },
    });
    expect(response.items).toHaveLength(1);
    expect(response.items[0]?.item).toMatchObject({
      sessionId: chainChildSessionId,
      rootTaskRunId: chainRootRunId,
      logicalWorkerId: chainWorkerId,
      attemptId: chainAttemptId,
    });
    expect(response.items[0]?.data).toMatchObject({
      response_id: chainResponseId,
      request_version: 1,
      response: { decision: "allow" },
    });
    const request = await readExactHistory(executableChainDb, {
      sessionId: chainChildSessionId,
      rootTaskRunId: chainRootRunId,
      logicalWorkerId: chainWorkerId,
      attemptId: chainAttemptId,
      reference: { kind: "approval", id: chainApprovalId },
    });
    expect(request.items[0]?.data).toMatchObject({
      request_id: chainApprovalId,
      run_id: chainChildRunId,
      response_version: 1,
      response: { decision: "allow" },
    });
  });

  it("UNEXECUTED: repeated prompt attempts keep ambiguous lineage null instead of inventing a root", async () => {
    const recalled = await readExactHistory(executableChainDb, {
      sessionId: chainChildSessionId,
      reference: { kind: "message", id: chainChildPromptMessageId },
    });
    expect(recalled.items).toHaveLength(1);
    expect(recalled.items[0]?.item).toMatchObject({
      stableId: chainChildPromptMessageId,
      rootTaskRunId: null,
      logicalWorkerId: null,
      attemptId: null,
    });
    expect(recalled.items[0]?.data).toMatchObject({ id: chainChildPromptMessageId });
    await expect(readExactHistory(executableChainDb, {
      sessionId: chainChildSessionId,
      rootTaskRunId: chainChildRunId,
      logicalWorkerId: chainWorkerId,
      attemptId: chainAttemptId,
    })).rejects.toMatchObject({ code: "actor_mismatch" });
  });

  it("UNEXECUTED: binds approval requests to their current version and keeps historical responses exact", async () => {
    const request = await readExactHistory(upgradeDb, {
      sessionId: legacySessionId,
      rootTaskRunId: legacyRootRunId,
      reference: { kind: "approval", id: legacyVersionedApprovalId },
    });
    expect(request.items).toHaveLength(1);
    expect(request.items[0]?.data).toMatchObject({
      request_id: legacyVersionedApprovalId,
      version: 2,
      response_version: 2,
      safe_payload: { summary: "version two request" },
      response: { decision: "allow-v2" },
    });
    const responses = await readExactHistory(upgradeDb, {
      sessionId: legacySessionId,
      rootTaskRunId: legacyRootRunId,
      reference: { kind: "approval", id: legacyVersionedResponseV1Id },
    });
    expect(responses.items[0]?.data).toMatchObject({
      response_id: legacyVersionedResponseV1Id,
      request_version: 1,
      response: { decision: "deny-v1" },
    });
    const current = await readExactHistory(upgradeDb, {
      sessionId: legacySessionId,
      rootTaskRunId: legacyRootRunId,
      reference: { kind: "approval", id: legacyVersionedResponseV2Id },
    });
    expect(current.items[0]?.data).toMatchObject({
      response_id: legacyVersionedResponseV2Id,
      request_version: 2,
      response: { decision: "allow-v2" },
    });
  });

  it("upgrade from 0030 retains exact old history without inventing root lineage or usage", async () => {
    const page = await readExactHistory(upgrade30Db, { sessionId: legacy30SessionId });
    expect(page.items).toHaveLength(1);
    expect(page.items[0]?.item).toMatchObject({
      stableId: legacy30MessageId,
      kind: "message",
      rootTaskRunId: null,
      logicalWorkerId: null,
      attemptId: null,
    });
    expect(page.items[0]?.data).toMatchObject({
      id: legacy30MessageId,
      content: "0030 exact assistant history",
    });
    await expect(readExactHistory(upgrade30Db, {
      sessionId: legacy30SessionId,
      rootTaskRunId: newId(),
    })).rejects.toMatchObject({ code: "actor_mismatch" });
  });

  it("manual replay and journal idempotence preserve one exact item and one null-usage legacy checkpoint", async () => {
    const before = await upgrade.client`
      SELECT
        (SELECT count(*)::int FROM compaction_history_items WHERE session_id = ${legacySessionId}) AS history,
        (SELECT count(*)::int FROM compaction_checkpoints WHERE session_id = ${legacySessionId}) AS checkpoints`;
    await applyMigrationFile(upgrade.client, MIGRATION_PATH);
    await migrate(upgrade.url);
    await applyMigrationFile(upgrade.client, MIGRATION_PATH);
    expect(await upgrade.client`
      SELECT
        (SELECT count(*)::int FROM compaction_history_items WHERE session_id = ${legacySessionId}) AS history,
        (SELECT count(*)::int FROM compaction_checkpoints WHERE session_id = ${legacySessionId}) AS checkpoints`)
      .toEqual(before);
    const identities = await upgrade.client`
      SELECT count(*)::int AS count FROM (
        SELECT session_id, kind, stable_id, event_cursor FROM compaction_history_items
         WHERE session_id = ${legacySessionId}
         GROUP BY session_id, kind, stable_id, event_cursor HAVING count(*) > 1
      ) duplicates`;
    expect(identities).toEqual([{ count: 0 }]);
  });

  it("enforces exact payload form, scoped recall and safe actor identity in real SQL", async () => {
    await expect(fresh.client`
      INSERT INTO compaction_history_items
        (session_id, kind, stable_id, event_cursor, byte_length)
        SELECT id, 'message', id, id, 0 FROM sessions LIMIT 1`)
      .rejects.toMatchObject({ code: "23514" });
    await expect(readExactHistory(upgradeDb, {
      sessionId: newId(), rootTaskRunId: legacyRootRunId,
    })).rejects.toMatchObject({ code: "history_scope_not_found" });
    await expect(readExactHistory(upgradeDb, {
      sessionId: legacySessionId, rootTaskRunId: newId(),
    })).rejects.toMatchObject({ code: "actor_mismatch" });
    const indexes = await fresh.client`
      SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname IN
        ('compaction_history_scope_position_idx', 'compaction_history_reference_idx',
         'compaction_history_identity_uq', 'compaction_cursors_worker_idx',
         'compaction_cursors_checkpoint_idx')`;
    expect(indexes).toHaveLength(5);
  });
});
