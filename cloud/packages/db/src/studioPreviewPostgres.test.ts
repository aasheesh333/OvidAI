// UNEXECUTED: authored while HEAVY-COMMANDS-PAUSED.md prohibits test execution.
// These are real-PostgreSQL integration regressions, not in-memory substitutes.
// Run with TEST_DATABASE_URL after the pause; without it every suite is skipped.
import { afterEach, describe, expect, it } from "vitest";

import { createDb, migrate, type Db } from "./client.js";
import {
  createMigrationScratch,
  migrateThrough,
  type MigrationScratch,
} from "./migrationTestKit.js";
import { newId, sessions, users } from "./repos.js";
import { createStudioPreviewPostgresStore } from "./studioPreviewPostgres.js";
import {
  createStudioPreviewStore,
  type StudioPreviewRecord,
  type StudioPreviewStore,
} from "./studioPreviewStore.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const CAPS = { perUser: 2, global: 32 } as const;
const T0 = Date.parse("2026-10-24T12:00:00.000Z");

function iso(offsetMs = 0): string {
  return new Date(T0 + offsetMs).toISOString();
}

function previewId(value: number): string {
  return `00000000-0000-4000-8000-${String(value).padStart(12, "0")}`;
}

interface Owner {
  userId: string;
  sessionId: string;
}

interface Fixture {
  scratch: MigrationScratch;
  db: Db;
  store: StudioPreviewStore;
  owner: Owner;
  connection(): { db: Db; store: StudioPreviewStore };
  seedOwner(label: string): Promise<Owner>;
  close(): Promise<void>;
}

const cleanups: Array<() => Promise<void>> = [];

afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()));
}, 30_000);

async function openFixture(prefix: string, through?: number): Promise<Fixture> {
  const scratch = await createMigrationScratch(TEST_DATABASE_URL!, prefix);
  const connections: Db[] = [];
  let closed = false;
  const close = async () => {
    if (closed) return;
    closed = true;
    try {
      await Promise.all(connections.map((db) => db.$client.end({ timeout: 5 })));
    } finally {
      await scratch.close();
    }
  };
  cleanups.push(close);
  try {
    if (through !== undefined) await migrateThrough(scratch.url, through);
    await migrate(scratch.url);
    const connection = () => {
      const db = createDb(scratch.url, { max: 4 });
      connections.push(db);
      return { db, store: createStudioPreviewStore(createStudioPreviewPostgresStore(db)) };
    };
    const first = connection();
    const owner = { userId: `${prefix}-owner`, sessionId: "" };
    await users.ensure(first.db, owner.userId, null);
    owner.sessionId = (await sessions.create(first.db, owner.userId, prefix)).id;
    return {
      scratch,
      db: first.db,
      store: first.store,
      owner,
      connection,
      async seedOwner(label) {
        const seeded = { userId: `${prefix}-${label}`, sessionId: "" };
        await users.ensure(first.db, seeded.userId, null);
        seeded.sessionId = (await sessions.create(first.db, seeded.userId, label)).id;
        return seeded;
      },
      close,
    };
  } catch (error) {
    await close();
    throw error;
  }
}

function devRecord(owner: Owner, id = newId()): StudioPreviewRecord {
  return {
    id,
    sessionId: owner.sessionId,
    userId: owner.userId,
    generation: 1,
    kind: "dev_server",
    workspacePath: `/srv/ovid/workspaces/${owner.userId}`,
    projectDir: `/srv/ovid/workspaces/${owner.userId}/app`,
    startScript: "dev",
    processId: null,
    processGroupId: null,
    workerEpoch: "worker-a",
    bindHost: "127.0.0.1",
    port: 20_000,
    status: "starting",
    createdAt: iso(),
    lastAccessAt: null,
    expiresAt: iso(60 * 60_000),
    endedAt: null,
    exitCode: null,
    failureCode: null,
    logBytes: 0,
  };
}

function staticRecord(owner: Owner, id = newId()): StudioPreviewRecord {
  return {
    id,
    sessionId: owner.sessionId,
    userId: owner.userId,
    generation: 1,
    kind: "static",
    workspacePath: `/srv/ovid/workspaces/${owner.userId}/dist`,
    projectDir: null,
    startScript: null,
    processId: null,
    processGroupId: null,
    workerEpoch: null,
    bindHost: null,
    port: null,
    status: "running",
    createdAt: iso(),
    lastAccessAt: null,
    expiresAt: iso(60 * 60_000),
    endedAt: null,
    exitCode: null,
    failureCode: null,
    logBytes: null,
  };
}

async function only(fixture: Fixture, id: string): Promise<StudioPreviewRecord> {
  const rows = await fixture.store.getForUser(
    fixture.owner.userId,
    fixture.owner.sessionId,
    id,
  );
  expect(rows).toHaveLength(1);
  return rows[0]!;
}

describe.skipIf(!TEST_DATABASE_URL).sequential("Studio preview 0041 real Postgres migrations", () => {
  // Break caught: a migration that omits/alters fields, constraints or adds duplicate indexes.
  it("fresh install creates the exact additive table, types, indexes and restrictive FKs", async () => {
    const fixture = await openFixture("studio_preview_fresh");
    const columns = await fixture.scratch.client`
      SELECT column_name, data_type, is_nullable
        FROM information_schema.columns
       WHERE table_schema = current_schema() AND table_name = 'studio_previews'
       ORDER BY ordinal_position`;
    expect(columns.map((row) => row.column_name)).toEqual([
      "id", "session_id", "user_id", "generation", "kind", "workspace_path",
      "project_dir", "start_script", "process_id", "process_group_id", "worker_epoch",
      "bind_host", "port", "status", "created_at", "last_access_at", "expires_at",
      "ended_at", "exit_code", "failure_code", "log_bytes",
    ]);
    expect(columns.map((row) => row.data_type)).toEqual([
      "uuid", "character", "text", "bigint", "text", "text", "text", "text", "integer",
      "text", "text", "text", "integer", "text", "timestamp with time zone",
      "timestamp with time zone", "timestamp with time zone", "timestamp with time zone",
      "integer", "text", "bigint",
    ]);
    expect(columns.filter((row) => row.is_nullable === "YES").map((row) => row.column_name))
      .toEqual([
        "project_dir", "start_script", "process_id", "process_group_id", "worker_epoch",
        "bind_host", "port", "last_access_at", "ended_at", "exit_code", "failure_code",
        "log_bytes",
      ]);

    const indexes = await fixture.scratch.client`
      SELECT indexname, indexdef FROM pg_indexes
       WHERE schemaname = current_schema() AND tablename = 'studio_previews'
       ORDER BY indexname`;
    expect(indexes.map((row) => row.indexname)).toEqual([
      "studio_previews_expiry_sweep_idx",
      "studio_previews_id_generation_uq",
      "studio_previews_pkey",
      "studio_previews_session_status_idx",
      "studio_previews_user_status_idx",
    ]);
    expect(indexes.find((row) => row.indexname === "studio_previews_id_generation_uq")?.indexdef)
      .toContain("UNIQUE INDEX");
    expect(indexes.find((row) => row.indexname === "studio_previews_expiry_sweep_idx")?.indexdef)
      .toContain("(expires_at, id)");

    const foreignKeys = await fixture.scratch.client`
      SELECT c.conname, c.confdeltype
        FROM pg_constraint c
       WHERE c.conrelid = to_regclass('studio_previews') AND c.contype = 'f'
       ORDER BY c.conname`;
    expect(foreignKeys).toEqual([
      { conname: "studio_previews_session_id_sessions_id_fk", confdeltype: "a" },
      { conname: "studio_previews_user_id_users_uid_fk", confdeltype: "a" },
    ]);
    const checks = await fixture.scratch.client`
      SELECT conname FROM pg_constraint
       WHERE conrelid = to_regclass('studio_previews') AND contype = 'c'
       ORDER BY conname`;
    expect(checks.map((row) => row.conname)).toEqual([
      "studio_previews_generation_check",
      "studio_previews_kind_check",
      "studio_previews_launch_definition_check",
      "studio_previews_log_bytes_check",
      "studio_previews_port_check",
      "studio_previews_script_check",
      "studio_previews_status_check",
    ]);
  }, 180_000);

  // Break caught: a non-additive 0040→0041 upgrade that breaks existing readers or writers.
  it("upgrades through 0040 and preserves an existing legacy reader and writer", async () => {
    const scratch = await createMigrationScratch(TEST_DATABASE_URL!, "studio_preview_upgrade");
    let db: Db | undefined;
    let closed = false;
    cleanups.push(async () => {
      if (closed) return;
      closed = true;
      try {
        await db?.$client.end({ timeout: 5 });
      } finally {
        await scratch.close();
      }
    });
    await migrateThrough(scratch.url, 40);
    db = createDb(scratch.url, { max: 2 });
    const userId = "studio-preview-legacy-owner";
    await users.ensure(db, userId, null);
    const legacy = await sessions.create(db, userId, "legacy preview reader", new Date(iso()));
    const before = await sessions.get(db, legacy.id, userId);
    expect((await scratch.client`SELECT to_regclass('studio_previews') AS table_name`)[0])
      .toEqual({ table_name: null });

    await migrate(scratch.url);

    expect(await sessions.get(db, legacy.id, userId)).toEqual(before);
    const inserted = await sessions.create(db, userId, "legacy writer after 0041");
    expect((await sessions.get(db, inserted.id, userId))?.title).toBe("legacy writer after 0041");
    expect((await scratch.client`SELECT to_regclass('studio_previews') AS table_name`)[0])
      .toEqual({ table_name: "studio_previews" });
  }, 180_000);

  // Break caught: cascading parent deletion that erases a live process recovery record.
  it("restricts parent deletion while preview evidence exists instead of cascading it away", async () => {
    const fixture = await openFixture("studio_preview_delete_fence");
    const record = devRecord(fixture.owner);
    await fixture.store.start(record, CAPS);

    await expect(fixture.scratch.client`
      DELETE FROM sessions WHERE id = ${record.sessionId}`)
      .rejects.toMatchObject({ code: "23503" });
    await expect(fixture.scratch.client`
      DELETE FROM users WHERE uid = ${record.userId}`)
      .rejects.toMatchObject({ code: "23503" });
    expect(await only(fixture, record.id)).toEqual(record);

    const stopped = await fixture.store.update(record.id, 1, {
      status: "stopped",
      endedAt: iso(60_000),
    });
    expect(stopped).toMatchObject({ generation: 2, status: "stopped" });
    // stopSession/terminal CAS precedes the integration owner's explicit terminal
    // evidence purge; the FK itself never silently chooses that purge.
    await fixture.scratch.client`DELETE FROM studio_previews WHERE id = ${record.id}`;
    await fixture.scratch.client`DELETE FROM sessions WHERE id = ${record.sessionId}`;
    expect(await fixture.store.getForUser(fixture.owner.userId, fixture.owner.sessionId)).toEqual([]);
  }, 180_000);
});

describe.skipIf(!TEST_DATABASE_URL).sequential("Studio preview Drizzle/Postgres adapter", () => {
  // Break caught: dropping nullable fields or returning driver-form timestamps/objects.
  it("round-trips exact 21-field records with ISO timestamps and null preservation", async () => {
    const fixture = await openFixture("studio_preview_roundtrip");
    const nullable = staticRecord(fixture.owner, previewId(1));
    const started = await fixture.store.start(nullable, CAPS);
    expect(started).toEqual(nullable);
    expect(Object.keys(started)).toHaveLength(21);
    expect(await only(fixture, nullable.id)).toEqual(nullable);

    const terminal = {
      ...devRecord(fixture.owner, previewId(2)),
      generation: 7,
      startScript: "preview" as const,
      processId: 4242,
      processGroupId: "/sys/fs/cgroup/ovid/preview-2",
      workerEpoch: "worker-epoch-2",
      bindHost: "::1",
      port: 29_999,
      status: "failed" as const,
      createdAt: "2026-10-24T12:00:00.123Z",
      lastAccessAt: "2026-10-24T12:01:00.456Z",
      expiresAt: "2026-10-24T13:00:00.789Z",
      endedAt: "2026-10-24T12:02:00.987Z",
      exitCode: 1,
      failureCode: "startup_failed",
      logBytes: 262_144,
    };
    expect(await fixture.store.start(terminal, CAPS)).toEqual(terminal);
    expect(await only(fixture, terminal.id)).toEqual(terminal);
  }, 180_000);

  // Break caught: id-only or user-only reads, or terminal rows leaking into recovery reads.
  it("scopes reads by owner and session and returns only live rows from getLive", async () => {
    const fixture = await openFixture("studio_preview_scopes");
    const other = await fixture.seedOwner("other");
    const ownedLive = await fixture.store.start(devRecord(fixture.owner, previewId(1)), CAPS);
    const ownedTerminal = await fixture.store.start({
      ...devRecord(fixture.owner, previewId(2)),
      status: "stopped",
      endedAt: iso(60_000),
    }, CAPS);
    const foreign = await fixture.store.start(devRecord(other, previewId(3)), CAPS);
    const ownedRunning = await fixture.store.start({
      ...devRecord(fixture.owner, previewId(4)), status: "running",
    }, CAPS);
    const ownedStopping = await fixture.store.start({
      ...staticRecord(fixture.owner, previewId(5)), status: "stopping",
    }, CAPS);

    expect((await fixture.store.getForUser(fixture.owner.userId, fixture.owner.sessionId))
      .map((row) => row.id).sort()).toEqual([
        ownedLive.id, ownedTerminal.id, ownedRunning.id, ownedStopping.id,
      ].sort());
    expect(await fixture.store.getForUser(other.userId, fixture.owner.sessionId, ownedLive.id)).toEqual([]);
    expect(await fixture.store.getForUser(fixture.owner.userId, other.sessionId, ownedLive.id)).toEqual([]);
    expect(await fixture.store.getForUser(fixture.owner.userId, fixture.owner.sessionId, "not-a-uuid")).toEqual([]);
    expect(await fixture.store.getForUser(other.userId, other.sessionId, foreign.id)).toEqual([foreign]);
    expect((await fixture.store.getLive()).map((row) => row.id).sort())
      .toEqual([ownedLive.id, ownedRunning.id, ownedStopping.id, foreign.id].sort());
  }, 180_000);

  // Break caught: missing/late advisory locking, unlocked counts, or insertion before refusal rollback.
  it("races three admissions on two connections without exceeding per-user 2 or retaining a refused row", async () => {
    const fixture = await openFixture("studio_preview_user_race");
    const second = fixture.connection();
    const candidates = [devRecord(fixture.owner), devRecord(fixture.owner), devRecord(fixture.owner)];
    candidates[1]!.port = 20_001;
    candidates[2]!.port = 20_002;
    const stores = [fixture.store, second.store, fixture.store];

    const results = await Promise.allSettled(candidates.map((record, index) =>
      stores[index]!.start(record, CAPS)));

    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(2);
    const refusedIndex = results.findIndex((result) => result.status === "rejected");
    expect(refusedIndex).toBeGreaterThanOrEqual(0);
    expect((results[refusedIndex] as PromiseRejectedResult).reason).toMatchObject({
      name: "StudioPreviewCapacityError",
      code: "per_user_capacity",
    });
    const rows = await fixture.store.getForUser(fixture.owner.userId, fixture.owner.sessionId);
    expect(rows).toHaveLength(2);
    expect(rows.some((row) => row.id === candidates[refusedIndex]!.id)).toBe(false);

    const stopping = rows[0]!;
    await fixture.store.update(stopping.id, stopping.generation, { status: "stopping" });
    const refusedWhileStopping = devRecord(fixture.owner);
    await expect(fixture.store.start(refusedWhileStopping, CAPS))
      .rejects.toMatchObject({ code: "per_user_capacity" });
    expect(await fixture.store.getForUser(
      fixture.owner.userId,
      fixture.owner.sessionId,
      refusedWhileStopping.id,
    )).toEqual([]);
  }, 180_000);

  // Break caught: per-user-only serialization or a global count that includes static/terminal rows.
  it("races 33 admissions on two connections without exceeding global 32 or retaining a refused row", async () => {
    const fixture = await openFixture("studio_preview_global_race");
    const second = fixture.connection();
    const stores = [fixture.store, second.store];
    const candidates: StudioPreviewRecord[] = [];
    for (let index = 0; index < 33; index += 1) {
      const owner = await fixture.seedOwner(`global-${index}`);
      candidates.push({ ...devRecord(owner), port: 20_000 + (index % 10_000) });
    }
    // Neither static nor terminal dev registrations consume process slots.
    await fixture.store.start(staticRecord(fixture.owner), CAPS);
    await fixture.store.start({
      ...devRecord(fixture.owner), status: "stopped", endedAt: iso(60_000),
    }, CAPS);

    const results = await Promise.allSettled(candidates.map((record, index) =>
      stores[index % 2]!.start(record, CAPS)));

    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(32);
    const refusedIndex = results.findIndex((result) => result.status === "rejected");
    expect(refusedIndex).toBeGreaterThanOrEqual(0);
    expect((results[refusedIndex] as PromiseRejectedResult).reason).toMatchObject({
      name: "StudioPreviewCapacityError",
      code: "global_capacity",
    });
    const counts = await fixture.scratch.client`
      SELECT count(*) FILTER (WHERE kind = 'dev_server'
        AND status IN ('starting','running','stopping'))::int AS live,
        count(*)::int AS total
      FROM studio_previews`;
    expect(counts).toEqual([{ live: 32, total: 34 }]);
    expect(await fixture.scratch.client`
      SELECT count(*)::int AS count FROM studio_previews WHERE id = ${candidates[refusedIndex]!.id}`)
      .toEqual([{ count: 0 }]);
  }, 180_000);

  // Break caught: charging static rows to either process cap.
  it("admits static rows beyond both process caps without weakening dev-server admission", async () => {
    const fixture = await openFixture("studio_preview_static_slots");
    for (let index = 0; index < 33; index += 1) {
      await fixture.store.start(staticRecord(fixture.owner), CAPS);
    }
    await fixture.store.start(devRecord(fixture.owner), CAPS);
    await fixture.store.start({ ...devRecord(fixture.owner), port: 20_001 }, CAPS);
    await expect(fixture.store.start({ ...devRecord(fixture.owner), port: 20_002 }, CAPS))
      .rejects.toMatchObject({ code: "per_user_capacity" });
    expect((await fixture.store.getForUser(fixture.owner.userId, fixture.owner.sessionId)))
      .toHaveLength(35);
  }, 180_000);

  // Break caught: read-then-write CAS, generation drift, lost null patches or mutable identity/launch data.
  it("performs one-generation CAS, refuses stale writes and keeps identity and launch definition immutable", async () => {
    const fixture = await openFixture("studio_preview_cas");
    const original = devRecord(fixture.owner);
    await fixture.store.start(original, CAPS);
    const updated = await fixture.store.update(original.id, 1, {
      status: "running",
      processId: 4242,
      processGroupId: "/sys/fs/cgroup/ovid/preview-cas",
      lastAccessAt: iso(30_000),
      logBytes: 128,
    });
    expect(updated).toEqual({
      ...original,
      generation: 2,
      status: "running",
      processId: 4242,
      processGroupId: "/sys/fs/cgroup/ovid/preview-cas",
      lastAccessAt: iso(30_000),
      logBytes: 128,
    });
    if (updated === null) throw new Error("successful CAS returned null");
    expect(await fixture.store.update(original.id, 1, { status: "failed" })).toBeNull();
    expect(await fixture.store.update(newId(), 1, { status: "failed" })).toBeNull();
    expect(await fixture.store.update("not-a-uuid", 1, { status: "failed" })).toBeNull();
    expect(await only(fixture, original.id)).toEqual(updated);

    const nulled = await fixture.store.update(original.id, 2, {
      processId: null,
      processGroupId: null,
      lastAccessAt: null,
    });
    expect(nulled).toEqual({ ...updated, generation: 3, processId: null, processGroupId: null, lastAccessAt: null });
    await expect(fixture.store.update(original.id, 3, {
      projectDir: "/outside/bound/repository",
      userId: "different-owner",
    } as never)).rejects.toThrow(/immutable|unsupported/i);
    expect(await only(fixture, original.id)).toEqual(nulled);

    const second = fixture.connection();
    const contested = await Promise.all([
      fixture.store.update(original.id, 3, { status: "stopping" }),
      second.store.update(original.id, 3, { status: "failed", endedAt: iso(60_000) }),
    ]);
    expect(contested.filter((row) => row === null)).toHaveLength(1);
    const winner = contested.find((row) => row !== null);
    expect(winner).toMatchObject({ generation: 4 });
    expect(await only(fixture, original.id)).toEqual(winner);
  }, 180_000);

  // Break caught: touch mutating generation/content, accepting stale/terminal/expired rows or ignoring throttle.
  it("atomically touches only lastAccessAt and returns false for stale, throttled, expired and terminal writes", async () => {
    const fixture = await openFixture("studio_preview_touch");
    const current = await fixture.store.start(staticRecord(fixture.owner, previewId(1)), CAPS);
    const stopping = staticRecord(fixture.owner, previewId(2));
    stopping.status = "stopping";
    const terminal = staticRecord(fixture.owner, previewId(3));
    terminal.status = "stopped";
    terminal.endedAt = iso();
    const expired = staticRecord(fixture.owner, previewId(4));
    expired.expiresAt = iso(30_000);
    for (const record of [stopping, terminal, expired]) await fixture.store.start(record, CAPS);

    expect(await fixture.store.touch({ id: current.id, generation: 1, now: iso(30_000) })).toBe(true);
    const first = { ...current, lastAccessAt: iso(30_000) };
    expect(await only(fixture, current.id)).toEqual(first);
    expect(await fixture.store.touch({ id: current.id, generation: 1, now: iso(30_999) })).toBe(false);
    expect(await only(fixture, current.id)).toEqual(first);
    expect(await fixture.store.touch({ id: current.id, generation: 1, now: iso(31_000) })).toBe(true);
    const second = { ...current, lastAccessAt: iso(31_000) };
    expect(await only(fixture, current.id)).toEqual(second);

    expect(await fixture.store.touch({ id: current.id, generation: 0, now: iso(32_000) })).toBe(false);
    expect(await fixture.store.touch({ id: newId(), generation: 1, now: iso(32_000) })).toBe(false);
    expect(await fixture.store.touch({ id: "not-a-uuid", generation: 1, now: iso(32_000) })).toBe(false);
    for (const denied of [stopping, terminal, expired]) {
      expect(await fixture.store.touch({ id: denied.id, generation: 1, now: iso(30_000) })).toBe(false);
      expect(await only(fixture, denied.id)).toEqual(denied);
    }
    expect(await only(fixture, current.id)).toEqual(second);
  }, 180_000);

  // Break caught: unbounded/unordered expiry reads or terminal updates before manager cleanup/CAS.
  it("returns a bounded (expiresAt,id) sweep without prematurely terminalizing candidates", async () => {
    const fixture = await openFixture("studio_preview_sweep");
    const earliest = devRecord(fixture.owner, previewId(5));
    earliest.status = "stopping";
    earliest.expiresAt = iso(-3_000);
    const tiedFirst = devRecord(fixture.owner, previewId(1));
    tiedFirst.expiresAt = iso(-2_000);
    const tiedSecond = devRecord(fixture.owner, previewId(2));
    tiedSecond.status = "starting";
    tiedSecond.expiresAt = iso(-2_000);
    const later = devRecord(fixture.owner, previewId(3));
    later.status = "running";
    later.expiresAt = iso(-1_000);
    const terminal = devRecord(fixture.owner, previewId(4));
    terminal.status = "stopped";
    terminal.endedAt = iso(-4_000);
    terminal.expiresAt = iso(-4_000);
    const future = staticRecord(fixture.owner, previewId(6));
    future.expiresAt = iso(1_000);
    const records = [earliest, tiedFirst, tiedSecond, later, terminal, future];
    for (const record of records) await fixture.store.start(record, { perUser: 10, global: 10 });

    expect((await fixture.store.sweepExpired(iso(), 2)).map((row) => row.id))
      .toEqual([earliest.id, tiedFirst.id]);
    expect((await fixture.store.sweepExpired(iso(), 10)).map((row) => row.id))
      .toEqual([earliest.id, tiedFirst.id, tiedSecond.id, later.id]);
    for (const record of records) expect(await only(fixture, record.id)).toEqual(record);
  }, 180_000);
});
