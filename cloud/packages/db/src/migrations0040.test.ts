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

const MIGRATION_PATH = fileURLToPath(new URL("../drizzle/0040_collaboration.sql", import.meta.url));
const SNAPSHOT_PATH = fileURLToPath(new URL("../drizzle/meta/0040_snapshot.json", import.meta.url));
const JOURNAL_PATH = fileURLToPath(new URL("../drizzle/meta/_journal.json", import.meta.url));
const migrationSql = existsSync(MIGRATION_PATH) ? readFileSync(MIGRATION_PATH, "utf8") : "";
const TABLES = ["collab_rooms", "collab_members", "collab_invites", "collab_turns", "collab_sender_leases"] as const;
const LEGACY_SCHEMA_PATH = fileURLToPath(
  new URL("../../../../server/account/schema_collaboration.sql", import.meta.url),
);
const LEGACY_SESSION_ID = `s${"1".repeat(32)}`;
const LEGACY_INVITE_ID = `i${"2".repeat(32)}`;

function errorChain(error: unknown): string {
  const messages: string[] = [];
  let current = error;
  for (let depth = 0; current instanceof Error && depth < 8; depth += 1) {
    messages.push(current.message);
    const code = (current as { code?: unknown }).code;
    if (code !== undefined) messages.push(String(code));
    current = (current as { cause?: unknown }).cause;
  }
  return messages.join("\n");
}

describe("0040 collaboration migration allocation and contract", () => {
  it("allocates the owner exception exactly once after 0038 without using 0035/0036/0037/0039", () => {
    const journal = JSON.parse(readFileSync(JOURNAL_PATH, "utf8")) as {
      entries: Array<{ idx: number; tag: string; when: number }>;
    };
    const positions = journal.entries
      .map((entry, position) => ({ entry, position }))
      .filter(({ entry }) => entry.idx === 40);
    expect(positions).toHaveLength(1);
    const [{ entry, position }] = positions;
    expect(entry.tag).toBe("0040_collaboration");
    expect(journal.entries[position - 1]?.tag).toBe("0039_lossless_compaction");
    expect(entry.when).toBeGreaterThan(journal.entries[position - 1]!.when);
    expect(journal.entries.some((candidate) => candidate.tag === "0035_collaboration")).toBe(false);
    for (const idx of [36, 37]) expect(journal.entries.some((candidate) => candidate.idx === idx)).toBe(false);
    expect(journal.entries.filter((candidate) => candidate.idx === 39)).toHaveLength(1);
  });

  it("chains the latest real 0039 snapshot and contains only metadata plus required fencing indexes", () => {
    expect(existsSync(SNAPSHOT_PATH)).toBe(true);
    const snapshot = existsSync(SNAPSHOT_PATH)
      ? JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8"))
      : { id: "", prevId: "", tables: {} };
    const previous = JSON.parse(readFileSync(
      fileURLToPath(new URL("../drizzle/meta/0039_snapshot.json", import.meta.url)),
      "utf8",
    )) as { id: string; tables: Record<string, unknown> };
    expect(snapshot.prevId).toBe(previous.id);
    for (const [name, definition] of Object.entries(previous.tables)) {
      expect(snapshot.tables[name], `preserve ${name}`).toEqual(definition);
    }
    for (const table of TABLES) expect(snapshot.tables[`public.${table}`], table).toBeDefined();
    expect(snapshot.tables["public.collab_rooms"]?.columns.token_hash).toBeDefined();
    expect(snapshot.tables["public.collab_rooms"]?.columns.session_token).toBeUndefined();
    expect(snapshot.tables["public.collab_invites"]?.columns.code_hash).toBeDefined();
    expect(snapshot.tables["public.collab_invites"]?.columns.invite_code).toBeUndefined();
    expect(snapshot.tables["public.collab_turns"]?.columns.actor_user_id).toBeDefined();
    expect(snapshot.tables["public.collab_sender_leases"]?.columns.holder_user_id).toBeDefined();
    expect(Object.keys(snapshot.tables["public.collab_rooms"]?.indexes ?? {})).toEqual(expect.arrayContaining([
      "collab_rooms_owner_request_uq",
    ]));
    expect(Object.keys(snapshot.tables["public.collab_members"]?.indexes ?? {})).toEqual(expect.arrayContaining([
      "collab_members_room_active_owner_uq",
      "collab_members_room_status_idx",
    ]));
    expect(Object.keys(snapshot.tables["public.collab_turns"]?.indexes ?? {})).toEqual(expect.arrayContaining([
      "collab_turns_room_idempotency_uq",
    ]));
    expect(Object.keys(snapshot.tables["public.collab_sender_leases"]?.indexes ?? {})).toEqual(expect.arrayContaining([
      "collab_sender_leases_room_active_uq",
    ]));
    for (const forbidden of ["collab_events", "collab_transcript", "collab_messages"]) {
      expect(snapshot.tables[`public.${forbidden}`]).toBeUndefined();
    }
  });

  // UNEXECUTED fix-round-3 static regression: exact canonical and legacy signatures.
  it("preflights complete canonical/legacy definitions and never drops legacy shares or canonical history", () => {
    expect(migrationSql).not.toBe("");
    expect(migrationSql).toContain("CREATE TABLE IF NOT EXISTS");
    expect(migrationSql).toContain("CREATE UNIQUE INDEX IF NOT EXISTS");
    expect(migrationSql).toContain("collab_legacy_invites_require_cutover");
    expect(migrationSql).toContain("collab_invites_incompatible");
    expect(migrationSql).toContain("format_type(a.atttypid, a.atttypmod)");
    expect(migrationSql).toContain("a.attnotnull = expected.not_null");
    expect(migrationSql).toContain("a.atthasdef");
    expect(migrationSql).toContain("pg_get_constraintdef(c.oid) = expected.definition");
    expect(migrationSql).toContain("i.indexdef = expected.index_definition");
    expect(migrationSql).toContain("i.tablename <> 'collab_invites'");
    expect(migrationSql).toContain("IF legacy_ok THEN");
    expect(migrationSql).toContain("collab_invites_max_uses_check");
    expect(migrationSql).toContain("collab_invites_revoked_check");
    expect(migrationSql).toContain("collab_invites_code_hash_key");
    expect(migrationSql).not.toContain("present_columns @>");
    expect(migrationSql).not.toMatch(/\bDROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT|TRIGGER)\b/i);
    const withoutApprovedLegacyRename = migrationSql.replace(
      'ALTER TABLE "collab_invites" RENAME TO "legacy_collab_invites_0040";',
      "",
    );
    expect(withoutApprovedLegacyRename).not.toMatch(/\bRENAME\s+(TO|COLUMN)\b/i);
    expect(migrationSql).not.toMatch(/\b(?:UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+"?(?:shares|messages|runs|session_event_mirror)"?/i);
  });
});

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL).sequential("0040 against isolated fresh and upgraded real Postgres", () => {
  let fresh: MigrationScratch;
  let upgrade: MigrationScratch;
  let legacy: MigrationScratch;
  const legacyToken = "L".repeat(43);
  const legacySessionId = newId();

  beforeAll(async () => {
    [fresh, upgrade, legacy] = await Promise.all([
      createMigrationScratch(TEST_DATABASE_URL!, "collab_0040_fresh"),
      createMigrationScratch(TEST_DATABASE_URL!, "collab_0040_upgrade"),
      createMigrationScratch(TEST_DATABASE_URL!, "collab_0040_legacy"),
    ]);
    await Promise.all([migrateThrough(upgrade.url, 39), migrateThrough(legacy.url, 30)]);
    for (const scratch of [upgrade, legacy]) {
      await scratch.client`INSERT INTO shares
        (token, owner_uid, session_id, request_id, content, message_count, created_at, expires_at)
        VALUES (${legacyToken}, 'legacy-share-owner', ${legacySessionId}, 'legacy-share-request',
                ${scratch.client.json({ messages: [{ role: "user", content: "legacy remains readable" }] })}::jsonb,
                1, now(), now() + interval '1 day')`;
    }
    await Promise.all([migrate(fresh.url), migrate(upgrade.url), migrate(legacy.url)]);
  }, 180_000);

  afterAll(async () => {
    await Promise.all([fresh?.close(), upgrade?.close(), legacy?.close()]);
  }, 30_000);

  it("fresh install exposes exactly the five metadata tables and no second transcript", async () => {
    const rows = await fresh.client`SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name LIKE 'collab_%' ORDER BY table_name`;
    expect(rows.map((row) => row.table_name)).toEqual([...TABLES].sort());
  });

  it("upgrades directly from 0030 without changing legacy share data", async () => {
    const rows = await legacy.client`SELECT token, content, message_count FROM shares WHERE token = ${legacyToken}`;
    expect(rows).toEqual([{
      token: legacyToken,
      content: { messages: [{ role: "user", content: "legacy remains readable" }] },
      message_count: 1,
    }]);
    const tables = await legacy.client`SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name LIKE 'collab_%' ORDER BY table_name`;
    expect(tables.map((row) => row.table_name)).toEqual([...TABLES].sort());
  });

  it("upgrade and manual replay preserve legacy share data and hash-only constraints", async () => {
    const before = await upgrade.client`SELECT token, content, message_count FROM shares WHERE token = ${legacyToken}`;
    await applyMigrationFile(upgrade.client, MIGRATION_PATH);
    const after = await upgrade.client`SELECT token, content, message_count FROM shares WHERE token = ${legacyToken}`;
    expect(after).toEqual(before);
    await expect(upgrade.client`INSERT INTO collab_rooms
      (id, token_hash, session_id, owner_user_id, request_id, lifecycle, generation, created_at)
      VALUES (${newId()}, 'not-a-sha256-hash', ${legacySessionId}, 'legacy-share-owner', 'bad', 'active', 1, now())`)
      .rejects.toMatchObject({ code: "23514" });
  });
});

// UNEXECUTED fix-round-1 real-PostgreSQL legacy-schema regressions. Run only
// after HEAVY-COMMANDS-PAUSED.md is lifted, against disposable databases.
describe.skipIf(!TEST_DATABASE_URL).sequential("0040 legacy PostgreSQL collaboration preflight", () => {
  let emptyLegacy: MigrationScratch;
  let occupiedLegacy: MigrationScratch;
  let lookalike: MigrationScratch;
  let wrongIndex: MigrationScratch;
  let wrongOwner: MigrationScratch;

  beforeAll(async () => {
    [emptyLegacy, occupiedLegacy, lookalike, wrongIndex, wrongOwner] = await Promise.all([
      createMigrationScratch(TEST_DATABASE_URL!, "collab_0040_legacy_empty"),
      createMigrationScratch(TEST_DATABASE_URL!, "collab_0040_legacy_occupied"),
      createMigrationScratch(TEST_DATABASE_URL!, "collab_0040_lookalike"),
      createMigrationScratch(TEST_DATABASE_URL!, "collab_0040_wrong_index"),
      createMigrationScratch(TEST_DATABASE_URL!, "collab_0040_wrong_owner"),
    ]);
    const legacySql = readFileSync(LEGACY_SCHEMA_PATH, "utf8");
    await Promise.all([
      migrateThrough(emptyLegacy.url, 39),
      migrateThrough(occupiedLegacy.url, 39),
      migrateThrough(lookalike.url, 39),
      migrate(wrongIndex.url),
      migrate(wrongOwner.url),
    ]);
    await Promise.all([
      emptyLegacy.client.unsafe(legacySql),
      occupiedLegacy.client.unsafe(legacySql),
    ]);
    await lookalike.client.unsafe(`
      CREATE TABLE collab_invites (
        id text NOT NULL,
        room_id char(36) NOT NULL,
        code_hash char(64) NOT NULL,
        issued_by_user_id text NOT NULL,
        idempotency_key text NOT NULL,
        issued_generation bigint NOT NULL DEFAULT 1,
        max_uses integer NOT NULL,
        uses integer NOT NULL DEFAULT 0,
        expires_at timestamptz(3) NOT NULL,
        revoked_at timestamptz(3),
        created_at timestamptz(3) NOT NULL DEFAULT now(),
        incompatible_required_field text NOT NULL
      )`);
    await wrongIndex.client.unsafe(`DROP INDEX collab_invites_code_hash_uq`);
    await wrongIndex.client.unsafe(
      `CREATE UNIQUE INDEX collab_invites_code_hash_uq ON collab_invites (room_id)`,
    );
    await wrongOwner.client.unsafe(`DROP INDEX collab_invites_code_hash_uq`);
    await wrongOwner.client.unsafe(
      `CREATE UNIQUE INDEX collab_invites_code_hash_uq ON collab_rooms (token_hash)`,
    );
    await occupiedLegacy.client`
      INSERT INTO collab_sessions
        (session_id, token_hash, owner_uid, request_id, lifecycle, generation, next_sequence, created_at, closed_at)
      VALUES (${LEGACY_SESSION_ID}, ${"b".repeat(64)}, 'legacy-owner', 'legacy-room-request',
              'active', 1, 1, 1700000000, NULL)`;
    await occupiedLegacy.client`
      INSERT INTO collab_invites
        (invite_id, session_id, code_hash, issued_generation, max_uses, uses, revoked, created_at, expires_at)
      VALUES (${LEGACY_INVITE_ID}, ${LEGACY_SESSION_ID}, ${"a".repeat(64)},
              1, 2, 1, 0, 1700000000, 1800000000)`;
    await occupiedLegacy.client`
      INSERT INTO collab_invite_requests (session_id, owner_uid, request_id, invite_id)
      VALUES (${LEGACY_SESSION_ID}, 'legacy-owner', 'legacy-invite-request', ${LEGACY_INVITE_ID})`;
  }, 180_000);

  afterAll(async () => {
    await Promise.all([
      emptyLegacy?.close(), occupiedLegacy?.close(), lookalike?.close(),
      wrongIndex?.close(), wrongOwner?.close(),
    ]);
  }, 30_000);

  it("renames an empty legacy invite table, avoids its old PK index, and replays canonically", async () => {
    await migrate(emptyLegacy.url);
    const columns = await emptyLegacy.client`
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = current_schema() AND table_name = 'collab_invites'`;
    expect(columns.map((row) => row.column_name)).toEqual(expect.arrayContaining([
      "id", "room_id", "issued_by_user_id", "idempotency_key",
    ]));
    expect(columns.map((row) => row.column_name)).not.toContain("invite_id");
    expect(await emptyLegacy.client`SELECT count(*)::int AS count FROM legacy_collab_invites_0040`)
      .toEqual([{ count: 0 }]);
    const indexes = await emptyLegacy.client`
      SELECT tablename, indexname FROM pg_indexes
      WHERE schemaname = current_schema()
        AND tablename IN ('collab_invites', 'legacy_collab_invites_0040')`;
    expect(indexes.filter((row) => row.tablename === "legacy_collab_invites_0040").map((row) => row.indexname))
      .not.toContain("collab_invites_pkey");
    expect(indexes.filter((row) => row.tablename === "collab_invites").map((row) => row.indexname))
      .toContain("collab_invites_pkey");
    // Exact valid legacy signature: all five constraints survive the archive,
    // with only the PK renamed to free the canonical index name.
    expect((await emptyLegacy.client`
      SELECT conname FROM pg_constraint
      WHERE conrelid = to_regclass('legacy_collab_invites_0040') ORDER BY conname`)
      .map((row) => row.conname)).toEqual([
        "collab_invites_code_hash_key",
        "collab_invites_max_uses_check",
        "collab_invites_revoked_check",
        "collab_invites_uses_check",
        "legacy_collab_invites_0040_pkey",
      ]);
    expect(indexes.filter((row) => row.tablename === "legacy_collab_invites_0040").map((row) => row.indexname).sort())
      .toEqual(["collab_invites_code_hash_key", "collab_invites_session", "legacy_collab_invites_0040_pkey"]);
    expect((await emptyLegacy.client`SELECT to_regclass('collab_sessions') AS table_name`)[0]?.table_name)
      .toBe("collab_sessions");

    await applyMigrationFile(emptyLegacy.client, MIGRATION_PATH);
    expect(await emptyLegacy.client`SELECT count(*)::int AS count FROM legacy_collab_invites_0040`)
      .toEqual([{ count: 0 }]);
  });

  it("refuses a non-empty legacy invite table atomically and preserves every row and request mapping", async () => {
    let refusal: unknown = null;
    try {
      await migrate(occupiedLegacy.url);
    } catch (error) {
      refusal = error;
    }
    expect(refusal).not.toBeNull();
    expect(errorChain(refusal)).toContain("collab_legacy_invites_require_cutover");

    expect(await occupiedLegacy.client`
      SELECT invite_id, session_id, code_hash, issued_generation::int AS issued_generation,
             max_uses, uses, revoked, created_at, expires_at
      FROM collab_invites`).toEqual([{
        invite_id: LEGACY_INVITE_ID,
        session_id: LEGACY_SESSION_ID,
        code_hash: "a".repeat(64),
        issued_generation: 1,
        max_uses: 2,
        uses: 1,
        revoked: 0,
        created_at: 1_700_000_000,
        expires_at: 1_800_000_000,
      }]);
    expect(await occupiedLegacy.client`
      SELECT session_id, owner_uid, request_id, invite_id FROM collab_invite_requests`)
      .toEqual([{
        session_id: LEGACY_SESSION_ID,
        owner_uid: "legacy-owner",
        request_id: "legacy-invite-request",
        invite_id: LEGACY_INVITE_ID,
      }]);
    expect((await occupiedLegacy.client`SELECT to_regclass('collab_rooms') AS table_name`)[0]?.table_name)
      .toBeNull();
    expect((await occupiedLegacy.client`SELECT to_regclass('legacy_collab_invites_0040') AS table_name`)[0]?.table_name)
      .toBeNull();
  });

  // UNEXECUTED fix-round-2 negative fixtures: no canonical-looking subset may pass.
  it("refuses a canonical-looking table with an extra required column before subsequent DDL", async () => {
    let refusal: unknown = null;
    try {
      await applyMigrationFile(lookalike.client, MIGRATION_PATH);
    } catch (error) {
      refusal = error;
    }
    expect(refusal).not.toBeNull();
    expect(errorChain(refusal)).toContain("collab_invites_incompatible");
    expect((await lookalike.client`SELECT to_regclass('collab_rooms') AS table_name`)[0]?.table_name)
      .toBeNull();
    expect((await lookalike.client`
      SELECT count(*)::int AS count FROM information_schema.columns
      WHERE table_schema = current_schema() AND table_name = 'collab_invites'
        AND column_name = 'incompatible_required_field'`)[0]?.count).toBe(1);
  });

  it("refuses a same-named wrong invite index and leaves its definition untouched", async () => {
    let refusal: unknown = null;
    try {
      await applyMigrationFile(wrongIndex.client, MIGRATION_PATH);
    } catch (error) {
      refusal = error;
    }
    expect(refusal).not.toBeNull();
    expect(errorChain(refusal)).toContain("collab_invites_incompatible");
    const indexes = await wrongIndex.client`
      SELECT indexdef FROM pg_indexes
      WHERE schemaname = current_schema() AND tablename = 'collab_invites'
        AND indexname = 'collab_invites_code_hash_uq'`;
    expect(indexes).toHaveLength(1);
    expect(indexes[0]?.indexdef).toContain("(room_id)");
    expect(indexes[0]?.indexdef).not.toContain("(code_hash)");
    expect((await wrongIndex.client`SELECT to_regclass('legacy_collab_invites_0040') AS table_name`)[0]?.table_name)
      .toBeNull();
  });

  it("refuses a required index name owned by another table without relocating it", async () => {
    let refusal: unknown = null;
    try {
      await applyMigrationFile(wrongOwner.client, MIGRATION_PATH);
    } catch (error) {
      refusal = error;
    }
    expect(refusal).not.toBeNull();
    expect(errorChain(refusal)).toContain("collab_invites_incompatible");
    expect(await wrongOwner.client`
      SELECT tablename, indexname FROM pg_indexes
      WHERE schemaname = current_schema() AND indexname = 'collab_invites_code_hash_uq'`)
      .toEqual([{ tablename: "collab_rooms", indexname: "collab_invites_code_hash_uq" }]);
    expect((await wrongOwner.client`SELECT to_regclass('legacy_collab_invites_0040') AS table_name`)[0]?.table_name)
      .toBeNull();
  });
});

// UNEXECUTED fix-round-3 regressions: only the exact legacy signature may archive.
describe.skipIf(!TEST_DATABASE_URL).sequential("0040 exact legacy signature gate", () => {
  async function scratchWithLegacy(prefix: string, mutation?: string): Promise<MigrationScratch> {
    const scratch = await createMigrationScratch(TEST_DATABASE_URL!, prefix);
    try {
      await migrateThrough(scratch.url, 39);
      await scratch.client.unsafe(readFileSync(LEGACY_SCHEMA_PATH, "utf8"));
      if (mutation !== undefined) await scratch.client.unsafe(mutation);
      return scratch;
    } catch (error) {
      await scratch.close();
      throw error;
    }
  }

  async function expectIncompatible(
    scratch: MigrationScratch,
    preserved: () => Promise<void>,
  ): Promise<void> {
    let refusal: unknown = null;
    try {
      await applyMigrationFile(scratch.client, MIGRATION_PATH);
    } catch (error) {
      refusal = error;
    }
    expect(refusal).not.toBeNull();
    expect(errorChain(refusal)).toContain("collab_invites_incompatible");
    expect((await scratch.client`SELECT to_regclass('collab_rooms') AS table_name`)[0]?.table_name)
      .toBeNull();
    expect((await scratch.client`SELECT to_regclass('legacy_collab_invites_0040') AS table_name`)[0]?.table_name)
      .toBeNull();
    await preserved();
  }

  it("refuses an empty legacy lookalike without the required constraint/index signature", async () => {
    const scratch = await createMigrationScratch(TEST_DATABASE_URL!, "collab_0040_empty_lookalike");
    try {
      await migrateThrough(scratch.url, 39);
      await scratch.client.unsafe(`
        CREATE TABLE collab_invites (
          invite_id text NOT NULL,
          session_id text NOT NULL,
          code_hash text NOT NULL,
          issued_generation bigint NOT NULL,
          max_uses integer NOT NULL,
          uses integer NOT NULL DEFAULT 0,
          revoked integer NOT NULL DEFAULT 0,
          created_at double precision NOT NULL,
          expires_at double precision NOT NULL
        )`);
      await expectIncompatible(scratch, async () => {
        expect(await scratch.client`SELECT count(*)::int AS count FROM pg_constraint
          WHERE conrelid = to_regclass('collab_invites')`).toEqual([{ count: 0 }]);
      });
    } finally {
      await scratch.close();
    }
  });

  it("refuses a legacy column superset with an extra required column and preserves it", async () => {
    const scratch = await scratchWithLegacy(
      "collab_0040_legacy_superset",
      "ALTER TABLE collab_invites ADD COLUMN incompatible_required_field text NOT NULL",
    );
    try {
      await expectIncompatible(scratch, async () => {
        expect(await scratch.client`SELECT count(*)::int AS count FROM information_schema.columns
          WHERE table_schema = current_schema() AND table_name = 'collab_invites'
            AND column_name = 'incompatible_required_field'`).toEqual([{ count: 1 }]);
      });
    } finally {
      await scratch.close();
    }
  });

  it("refuses wrong legacy index and check definitions without repairing or archiving them", async () => {
    const scratch = await scratchWithLegacy(
      "collab_0040_legacy_wrong_signature",
      `DROP INDEX collab_invites_session;
       CREATE INDEX collab_invites_session ON collab_invites (code_hash);
       ALTER TABLE collab_invites DROP CONSTRAINT collab_invites_max_uses_check;
       ALTER TABLE collab_invites ADD CONSTRAINT collab_invites_max_uses_check CHECK (max_uses BETWEEN 1 AND 8)`,
    );
    try {
      await expectIncompatible(scratch, async () => {
        const indexes = await scratch.client`SELECT indexdef FROM pg_indexes
          WHERE schemaname = current_schema() AND tablename = 'collab_invites'
            AND indexname = 'collab_invites_session'`;
        expect(indexes).toHaveLength(1);
        expect(indexes[0]?.indexdef).toContain("(code_hash)");
        const constraints = await scratch.client`SELECT pg_get_constraintdef(oid) AS definition
          FROM pg_constraint WHERE conrelid = to_regclass('collab_invites')
            AND conname = 'collab_invites_max_uses_check'`;
        expect(constraints).toEqual([{ definition: "CHECK ((max_uses >= 1) AND (max_uses <= 8))" }]);
      });
    } finally {
      await scratch.close();
    }
  });

  it("refuses a missing legacy constraint signature and leaves it absent", async () => {
    const scratch = await scratchWithLegacy(
      "collab_0040_legacy_missing_signature",
      "ALTER TABLE collab_invites DROP CONSTRAINT collab_invites_revoked_check",
    );
    try {
      await expectIncompatible(scratch, async () => {
        expect(await scratch.client`SELECT count(*)::int AS count FROM pg_constraint
          WHERE conrelid = to_regclass('collab_invites')
            AND conname = 'collab_invites_revoked_check'`).toEqual([{ count: 0 }]);
      });
    } finally {
      await scratch.close();
    }
  });

  it("refuses extra legacy constraints and indexes and leaves both in place", async () => {
    const scratch = await scratchWithLegacy(
      "collab_0040_legacy_extra_signature",
      `ALTER TABLE collab_invites ADD CONSTRAINT legacy_extra_uses_check CHECK (uses >= 0);
       CREATE INDEX legacy_extra_invites_idx ON collab_invites (session_id, invite_id)`,
    );
    try {
      await expectIncompatible(scratch, async () => {
        expect(await scratch.client`SELECT count(*)::int AS count FROM pg_constraint
          WHERE conrelid = to_regclass('collab_invites')
            AND conname = 'legacy_extra_uses_check'`).toEqual([{ count: 1 }]);
        expect(await scratch.client`SELECT count(*)::int AS count FROM pg_indexes
          WHERE schemaname = current_schema() AND tablename = 'collab_invites'
            AND indexname = 'legacy_extra_invites_idx'`).toEqual([{ count: 1 }]);
      });
    } finally {
      await scratch.close();
    }
  });
});
