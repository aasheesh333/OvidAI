import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import postgres from "postgres";
import type { UiManifest } from "@ovid/shared";
import { createDb, migrate, type Db } from "./client.js";
import {
  fileManifests,
  newId,
  runs,
  sessions,
  workspaceObjects,
} from "./repos.js";
import {
  fileManifests as fileManifestsTable,
  runs as runsTable,
  users,
  workspaceObjects as workspaceObjectsTable,
} from "./schema.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

const UUIDV7_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

// Fixed base (2023-11-14T22:13:20Z) for pinned updatedAt values so LRU order
// assertions never depend on wall-clock ties.
const BASE = 1_700_000_000_000;

const SHA_A = "a".repeat(64);
const SHA_B = "b".repeat(64);
const SHA_C = "c".repeat(64);
const SHA_D = "d".repeat(64);

/** A non-empty pruned tree for markCold (deep-equal roundtrip pin). */
function uiTreeFixture(): UiManifest {
  return {
    version: 1,
    generatedAt: "2026-10-17T00:00:00Z",
    truncated: false,
    totals: { files: 2, dirs: 1, bytes: 1234 },
    roots: [
      {
        name: "proj",
        path: "proj",
        type: "dir",
        children: [
          { name: "a.txt", path: "proj/a.txt", type: "file", sizeBytes: 1000 },
          { name: "b.txt", path: "proj/b.txt", type: "file", sizeBytes: 234 },
        ],
      },
    ],
  };
}

describe.skipIf(!TEST_DATABASE_URL)("storage repos against real postgres", () => {
  let db: Db;

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    // Same drop/recreate discipline as repos.test.ts / moneyRepos.test.ts /
    // mcpRepos.test.ts (the P8-T3 rerunnability invariant): the drizzle
    // journal, the sandbox-uid sequence and EVERY table any migration creates
    // are dropped so migrate() re-applies from scratch on every run.
    const admin = postgres(url, { max: 1, onnotice: () => {} });
    try {
      await admin.unsafe(`DROP SCHEMA IF EXISTS drizzle CASCADE`);
      await admin.unsafe(`DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE`);
      await admin.unsafe(
        `DROP TABLE IF EXISTS schedules, schedule_runs, devices, notifications, grants, file_manifests, workspace_objects, attachments, session_event_mirror, session_agent_state, runs, messages, sessions, users,` +
          ` plans, mint_settings, user_plan_overrides, mint_audit, billing_purchases, image_jobs,` +
          ` image_deleted_accounts, image_cards, image_card_history, image_probe_log, image_probe_state,` +
          ` shares, share_forks, reports, account_deletions, byok_keys,` +
          ` mcp_servers, mcp_oauth_tokens, mcp_oauth_flows, plugins, plugin_grants, run_usage,` +
          ` private_memory_files, projects CASCADE`,
      );
    } finally {
      await admin.end({ timeout: 5 });
    }
    await migrate(url);
    db = createDb(url);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function seedUser(): Promise<string> {
    const uid = newId();
    await db.insert(users).values({ uid, email: `u-${uid.slice(0, 8)}@test.local` });
    return uid;
  }

  // -------------------------------------------------------------------------

  it("upsertWarm creates a warm row (generation 0, empty tree); re-upsert moves only state/du/updatedAt", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "w1");

    const row = await fileManifests.upsertWarm(db, {
      sessionId: s.id,
      userId: uid,
      workspaceBytes: 1000,
    });
    expect(row.sessionId).toBe(s.id);
    expect(row.userId).toBe(uid);
    expect(row.state).toBe("warm");
    expect(row.generation).toBe(0); // column default
    expect(row.workspaceBytes).toBe(1000);
    expect(row.archiveKey).toBeNull(); // null until first hibernate
    expect(row.archiveBytes).toBeNull();
    expect(row.archiveSha256).toBeNull();
    expect(row.entryCount).toBeNull();
    expect(row.updatedAt).toBeInstanceOf(Date);
    // fresh row carries the EMPTY tree literal
    expect(row.uiTree.version).toBe(1);
    expect(row.uiTree.truncated).toBe(false);
    expect(row.uiTree.totals).toEqual({ files: 0, dirs: 0, bytes: 0 });
    expect(row.uiTree.roots).toEqual([]);

    // Cold it (generation 1 + archive ledger + real tree), then re-upsert:
    // the conflict arm updates ONLY state, workspace_bytes, updated_at.
    const tree = uiTreeFixture();
    await fileManifests.markCold(db, {
      sessionId: s.id,
      generation: 1,
      archiveKey: `users/${uid}/workspaces/${s.id}.tar.zst`,
      archiveBytes: 4444,
      archiveSha256: SHA_A,
      entryCount: 7,
      uiTree: tree,
    });
    const re = await fileManifests.upsertWarm(db, {
      sessionId: s.id,
      userId: uid,
      workspaceBytes: 2222,
    });
    expect(re.state).toBe("warm");
    expect(re.workspaceBytes).toBe(2222);
    expect(re.generation).toBe(1); // NEVER touched by upsertWarm
    expect(re.archiveKey).toBe(`users/${uid}/workspaces/${s.id}.tar.zst`);
    expect(re.archiveBytes).toBe(4444);
    expect(re.archiveSha256).toBe(SHA_A);
    expect(re.entryCount).toBe(7);
    expect(re.uiTree).toEqual(tree); // the cold tree survives re-warming

    // null workspaceBytes is legal (du unknown) and equally non-destructive
    const re2 = await fileManifests.upsertWarm(db, {
      sessionId: s.id,
      userId: uid,
      workspaceBytes: null,
    });
    expect(re2.workspaceBytes).toBeNull();
    expect(re2.generation).toBe(1);
    expect(re2.archiveKey).toBe(`users/${uid}/workspaces/${s.id}.tar.zst`);

    // get: unknown session → null
    expect(await fileManifests.get(db, newId())).toBeNull();
  });

  it("beginHibernation claims warm→hibernating exactly once (race-safe); false from cold/unknown", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "w2");
    await fileManifests.upsertWarm(db, { sessionId: s.id, userId: uid, workspaceBytes: 10 });

    expect(await fileManifests.beginHibernation(db, s.id)).toBe(true);
    // The second claim loses — the WHERE state='warm' predicate is the race
    // guard (sequential form of two concurrent claimants).
    expect(await fileManifests.beginHibernation(db, s.id)).toBe(false);
    expect((await fileManifests.get(db, s.id))!.state).toBe("hibernating");

    // Truly concurrent pair on a fresh row: exactly one winner.
    const s2 = await sessions.create(db, uid, "w2b");
    await fileManifests.upsertWarm(db, { sessionId: s2.id, userId: uid, workspaceBytes: 10 });
    const claims = await Promise.all([
      fileManifests.beginHibernation(db, s2.id),
      fileManifests.beginHibernation(db, s2.id),
    ]);
    expect(claims.filter((c) => c === true)).toHaveLength(1);
    expect((await fileManifests.get(db, s2.id))!.state).toBe("hibernating");

    // Cold rows are not claimable.
    const s3 = await sessions.create(db, uid, "w2c");
    await fileManifests.upsertWarm(db, { sessionId: s3.id, userId: uid, workspaceBytes: 10 });
    await fileManifests.markCold(db, {
      sessionId: s3.id,
      generation: 1,
      archiveKey: `users/${uid}/workspaces/${s3.id}.tar.zst`,
      archiveBytes: 99,
      archiveSha256: SHA_A,
      entryCount: 1,
      uiTree: uiTreeFixture(),
    });
    expect(await fileManifests.beginHibernation(db, s3.id)).toBe(false);

    // Unknown session.
    expect(await fileManifests.beginHibernation(db, newId())).toBe(false);
  });

  it("markCold writes the exact archive ledger in one UPDATE (workspace_bytes cleared)", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "w3");
    await fileManifests.upsertWarm(db, { sessionId: s.id, userId: uid, workspaceBytes: 1000 });
    await fileManifests.beginHibernation(db, s.id);

    const tree = uiTreeFixture();
    await fileManifests.markCold(db, {
      sessionId: s.id,
      generation: 3,
      archiveKey: `users/${uid}/workspaces/${s.id}.tar.zst`,
      archiveBytes: 987_654,
      archiveSha256: SHA_B,
      entryCount: 42,
      uiTree: tree,
    });

    const row = await fileManifests.get(db, s.id);
    expect(row).not.toBeNull();
    expect(row!.state).toBe("cold");
    expect(row!.generation).toBe(3);
    expect(row!.archiveKey).toBe(`users/${uid}/workspaces/${s.id}.tar.zst`);
    expect(row!.archiveBytes).toBe(987_654);
    expect(row!.archiveSha256).toBe(SHA_B);
    expect(row!.entryCount).toBe(42);
    expect(row!.uiTree).toEqual(tree);
    expect(row!.workspaceBytes).toBeNull(); // warm du is dropped on cold
  });

  it("beginHydration claims cold→hydrating only; markWarm restores warm and keeps the archive ledger", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "w4");
    await fileManifests.upsertWarm(db, { sessionId: s.id, userId: uid, workspaceBytes: 10 });
    await fileManifests.markCold(db, {
      sessionId: s.id,
      generation: 1,
      archiveKey: `users/${uid}/workspaces/${s.id}.tar.zst`,
      archiveBytes: 500,
      archiveSha256: SHA_A,
      entryCount: 2,
      uiTree: uiTreeFixture(),
    });

    expect(await fileManifests.beginHydration(db, s.id)).toBe(true);
    expect(await fileManifests.beginHydration(db, s.id)).toBe(false); // already claimed
    expect((await fileManifests.get(db, s.id))!.state).toBe("hydrating");

    // Warm rows are not hydratable (a warm workspace IS the truth).
    const sWarm = await sessions.create(db, uid, "w4b");
    await fileManifests.upsertWarm(db, { sessionId: sWarm.id, userId: uid, workspaceBytes: 1 });
    expect(await fileManifests.beginHydration(db, sWarm.id)).toBe(false);

    // Hibernating rows are not hydratable (a hibernate job owns the row).
    const sHib = await sessions.create(db, uid, "w4c");
    await fileManifests.upsertWarm(db, { sessionId: sHib.id, userId: uid, workspaceBytes: 1 });
    await fileManifests.beginHibernation(db, sHib.id);
    expect(await fileManifests.beginHydration(db, sHib.id)).toBe(false);

    // Unknown session.
    expect(await fileManifests.beginHydration(db, newId())).toBe(false);

    await fileManifests.markWarm(db, { sessionId: s.id, workspaceBytes: 555 });
    const row = await fileManifests.get(db, s.id);
    expect(row!.state).toBe("warm");
    expect(row!.workspaceBytes).toBe(555);
    // the cold ledger survives markWarm — a re-hibernate bumps generation in place
    expect(row!.generation).toBe(1);
    expect(row!.archiveKey).toBe(`users/${uid}/workspaces/${s.id}.tar.zst`);
    expect(row!.archiveBytes).toBe(500);
    expect(row!.archiveSha256).toBe(SHA_A);
    expect(row!.entryCount).toBe(2);

    // null du is legal after hydration
    await fileManifests.markWarm(db, { sessionId: s.id, workspaceBytes: null });
    expect((await fileManifests.get(db, s.id))!.workspaceBytes).toBeNull();
  });

  it("markColdRetry restores cold ONLY from the hydrating claim (T6 carry)", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "w4d");
    await fileManifests.upsertWarm(db, { sessionId: s.id, userId: uid, workspaceBytes: 10 });
    await fileManifests.markCold(db, {
      sessionId: s.id,
      generation: 1,
      archiveKey: `users/${uid}/workspaces/${s.id}.tar.zst`,
      archiveBytes: 500,
      archiveSha256: SHA_A,
      entryCount: 2,
      uiTree: uiTreeFixture(),
    });

    // A failed hydrate flips the row back so BullMQ's next attempt can claim it.
    expect(await fileManifests.beginHydration(db, s.id)).toBe(true);
    await fileManifests.markColdRetry(db, s.id);
    expect((await fileManifests.get(db, s.id))!.state).toBe("cold");

    // The state re-check: a warm row is never stomped back to cold.
    await fileManifests.markWarm(db, { sessionId: s.id, workspaceBytes: 42 });
    await fileManifests.markColdRetry(db, s.id);
    expect((await fileManifests.get(db, s.id))!.state).toBe("warm");
    expect((await fileManifests.get(db, s.id))!.workspaceBytes).toBe(42);

    // Unknown session is a silent no-op.
    await fileManifests.markColdRetry(db, newId());
  });

  it("listWarmForLru returns only warm rows, oldest updated_at first", async () => {
    const uid = await seedUser();
    const sids: string[] = [];
    for (let i = 0; i < 3; i++) {
      const s = await sessions.create(db, uid, `lru${i}`);
      sids.push(s.id);
      await fileManifests.upsertWarm(db, { sessionId: s.id, userId: uid, workspaceBytes: i * 100 });
    }
    // Pin the warm rows' updatedAt order (oldest first).
    for (let i = 0; i < sids.length; i++) {
      await db
        .update(fileManifestsTable)
        .set({ updatedAt: new Date(BASE + i * 1000) })
        .where(eq(fileManifestsTable.sessionId, sids[i]!));
    }
    // A cold row and a hibernating row (pinned NEWEST updatedAt) must be absent.
    const sCold = await sessions.create(db, uid, "lrucold");
    await fileManifests.upsertWarm(db, { sessionId: sCold.id, userId: uid, workspaceBytes: 9 });
    await fileManifests.markCold(db, {
      sessionId: sCold.id,
      generation: 1,
      archiveKey: `users/${uid}/workspaces/${sCold.id}.tar.zst`,
      archiveBytes: 9,
      archiveSha256: SHA_A,
      entryCount: 1,
      uiTree: uiTreeFixture(),
    });
    const sHib = await sessions.create(db, uid, "lruhib");
    await fileManifests.upsertWarm(db, { sessionId: sHib.id, userId: uid, workspaceBytes: 9 });
    await fileManifests.beginHibernation(db, sHib.id);
    for (const sid of [sCold.id, sHib.id]) {
      await db
        .update(fileManifestsTable)
        .set({ updatedAt: new Date(BASE + 10_000) })
        .where(eq(fileManifestsTable.sessionId, sid));
    }

    const rows = await fileManifests.listWarmForLru(db);
    const mine = rows.filter((r) => r.userId === uid);
    expect(mine.map((r) => r.sessionId)).toEqual(sids); // ASC, warm only
    expect(mine.map((r) => r.sessionId)).not.toContain(sCold.id);
    expect(rows.every((r) => r.updatedAt instanceof Date)).toBe(true);
    expect(mine[0]).toMatchObject({
      sessionId: sids[0],
      userId: uid,
      generation: 0,
      workspaceBytes: 0,
    });
  });

  it("putArchive upserts the archive + manifest rows on stable r2 keys (generation bumped in place)", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "arch");
    const archiveKey = `users/${uid}/workspaces/${s.id}.tar.zst`;
    const manifestKey = `users/${uid}/workspaces/${s.id}.manifest.json`;

    await workspaceObjects.putArchive(db, {
      userId: uid,
      sessionId: s.id,
      generation: 1,
      archiveKey,
      manifestKey,
      bytes: 5000,
      sha256: SHA_A,
      entryCount: 10,
      manifestBytes: 320,
      manifestSha256: SHA_B,
    });
    // Generation 2 over the SAME keys: both rows upsert, never duplicate.
    await workspaceObjects.putArchive(db, {
      userId: uid,
      sessionId: s.id,
      generation: 2,
      archiveKey,
      manifestKey,
      bytes: 6000,
      sha256: SHA_C,
      entryCount: 11,
      manifestBytes: 330,
      manifestSha256: SHA_D,
    });

    const rows = await db
      .select()
      .from(workspaceObjectsTable)
      .where(eq(workspaceObjectsTable.sessionId, s.id));
    expect(rows).toHaveLength(2); // one archive row + one manifest row

    const archive = rows.find((r) => r.kind === "workspace_archive")!;
    expect(archive.id).toMatch(UUIDV7_RE);
    expect(archive.r2Key).toBe(archiveKey);
    expect(archive.userId).toBe(uid);
    expect(archive.bytes).toBe(6000);
    expect(archive.sha256).toBe(SHA_C);
    expect(archive.generation).toBe(2); // bumped in place
    expect(archive.status).toBe("active");
    expect(archive.meta).toEqual({ entryCount: 11, zstdLevel: 9 });
    expect(archive.createdAt).toBeInstanceOf(Date);

    const manifest = rows.find((r) => r.kind === "workspace_manifest")!;
    expect(manifest.r2Key).toBe(manifestKey);
    expect(manifest.bytes).toBe(330);
    expect(manifest.sha256).toBe(SHA_D); // the SIDECAR's own digest, never the archive's
    expect(manifest.generation).toBeNull(); // archives only
    expect(manifest.status).toBe("active");
  });

  it("registerArtifact + listArtifacts keyset paging + ownership-scoped getArtifact", async () => {
    const uid = await seedUser();
    const stranger = await seedUser();
    const s = await sessions.create(db, uid, "art");

    // Sequential newId()s are UUIDv7-monotonic → id order = insertion order.
    const ids = [newId(), newId(), newId()];
    for (let i = 0; i < ids.length; i++) {
      await workspaceObjects.registerArtifact(db, {
        id: ids[i]!,
        userId: uid,
        sessionId: s.id,
        r2Key: `users/${uid}/artifacts/${s.id}/${ids[i]!}-shot${i}.png`,
        bytes: 100 + i,
        sha256: `${i}${SHA_A.slice(1)}`,
        contentType: "image/png",
        meta: { name: `shot${i}.png` },
      });
    }
    // A deleted row must never list.
    const goneId = newId();
    await workspaceObjects.registerArtifact(db, {
      id: goneId,
      userId: uid,
      sessionId: s.id,
      r2Key: `users/${uid}/artifacts/${s.id}/${goneId}-gone.png`,
      bytes: 1,
      sha256: SHA_A,
      contentType: "image/png",
      meta: { name: "gone.png" },
    });
    await db
      .update(workspaceObjectsTable)
      .set({ status: "deleted" })
      .where(eq(workspaceObjectsTable.id, goneId));

    // Page 1: newest-first, limit 2 → nextCursor = oldest id on the page.
    const p1 = await workspaceObjects.listArtifacts(db, s.id, { limit: 2 });
    expect(p1.rows.map((r) => r.id)).toEqual([ids[2], ids[1]]);
    expect(p1.nextCursor).toBe(ids[1]);
    // Page 2: beforeId excludes itself → the last item, no cursor.
    const p2 = await workspaceObjects.listArtifacts(db, s.id, {
      limit: 2,
      beforeId: p1.nextCursor,
    });
    expect(p2.rows.map((r) => r.id)).toEqual([ids[0]]);
    expect(p2.nextCursor).toBeNull();
    // Exact fit: no cursor.
    const all = await workspaceObjects.listArtifacts(db, s.id, { limit: 3 });
    expect(all.rows.map((r) => r.id)).toEqual([...ids].reverse());
    expect(all.nextCursor).toBeNull();
    // Row shape: meta carries the display name.
    const first = all.rows.find((r) => r.id === ids[0])!;
    expect(first.meta).toEqual({ name: "shot0.png" });
    expect(first.bytes).toBe(100);
    expect(first.contentType).toBe("image/png");
    expect(first.kind).toBe("artifact");

    // Artifacts of ANOTHER session never leak into this session's pages.
    const sOther = await sessions.create(db, uid, "art-other");
    await workspaceObjects.registerArtifact(db, {
      id: newId(),
      userId: uid,
      sessionId: sOther.id,
      r2Key: `users/${uid}/artifacts/${sOther.id}/other.png`,
      bytes: 5,
      sha256: SHA_A,
      contentType: "image/png",
      meta: { name: "other.png" },
    });
    const scoped = await workspaceObjects.listArtifacts(db, s.id, { limit: 10 });
    expect(scoped.rows.every((r) => r.sessionId === s.id)).toBe(true);
    expect(scoped.rows).toHaveLength(3);

    // Ownership-scoped getArtifact: right owner → row, wrong owner → null
    // (same 404-no-existence-leak rule as sessions.get).
    const got = await workspaceObjects.getArtifact(db, ids[0]!, uid);
    expect(got).not.toBeNull();
    expect(got!.id).toBe(ids[0]);
    expect(await workspaceObjects.getArtifact(db, ids[0]!, stranger)).toBeNull();
    expect(await workspaceObjects.getArtifact(db, newId(), uid)).toBeNull();
  });

  it("bytes-typed inputs reject non-safe-integer and negative values at the repo boundary", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "guard");
    const bads = [1.5, -1, Number.MAX_SAFE_INTEGER + 1, NaN, Infinity];

    for (const bad of bads) {
      await expect(
        fileManifests.upsertWarm(db, { sessionId: s.id, userId: uid, workspaceBytes: bad }),
      ).rejects.toThrow(/safe integer/);
      await expect(
        fileManifests.markCold(db, {
          sessionId: s.id,
          generation: 1,
          archiveKey: `users/${uid}/workspaces/${s.id}.tar.zst`,
          archiveBytes: bad,
          archiveSha256: SHA_A,
          entryCount: 1,
          uiTree: uiTreeFixture(),
        }),
      ).rejects.toThrow(/safe integer/);
      await expect(
        fileManifests.markWarm(db, { sessionId: s.id, workspaceBytes: bad }),
      ).rejects.toThrow(/safe integer/);
      await expect(
        workspaceObjects.putArchive(db, {
          userId: uid,
          sessionId: s.id,
          generation: 1,
          archiveKey: `users/${uid}/workspaces/${s.id}.tar.zst`,
          manifestKey: `users/${uid}/workspaces/${s.id}.manifest.json`,
          bytes: bad,
          sha256: SHA_A,
          entryCount: 1,
          manifestBytes: 10,
          manifestSha256: SHA_B,
        }),
      ).rejects.toThrow(/safe integer/);
      await expect(
        workspaceObjects.putArchive(db, {
          userId: uid,
          sessionId: s.id,
          generation: 1,
          archiveKey: `users/${uid}/workspaces/${s.id}.tar.zst`,
          manifestKey: `users/${uid}/workspaces/${s.id}.manifest.json`,
          bytes: 10,
          sha256: SHA_A,
          entryCount: 1,
          manifestBytes: bad,
          manifestSha256: SHA_B,
        }),
      ).rejects.toThrow(/safe integer/);
      await expect(
        workspaceObjects.registerArtifact(db, {
          id: newId(),
          userId: uid,
          sessionId: s.id,
          r2Key: `users/${uid}/artifacts/${s.id}/x.png`,
          bytes: bad,
          sha256: SHA_A,
          contentType: "image/png",
          meta: { name: "x.png" },
        }),
      ).rejects.toThrow(/safe integer/);
    }

    // The guard fires BEFORE any write: no manifest row, no object rows.
    expect(await fileManifests.get(db, s.id)).toBeNull();
    const objs = await db
      .select()
      .from(workspaceObjectsTable)
      .where(eq(workspaceObjectsTable.sessionId, s.id));
    expect(objs).toHaveLength(0);
  });

  it("fileManifests.remove deletes the row", async () => {
    const uid = await seedUser();
    const s = await sessions.create(db, uid, "rm");
    await fileManifests.upsertWarm(db, { sessionId: s.id, userId: uid, workspaceBytes: 3 });
    await fileManifests.remove(db, s.id);
    expect(await fileManifests.get(db, s.id)).toBeNull();
    // idempotent on unknown/already-removed
    await expect(fileManifests.remove(db, s.id)).resolves.toBeUndefined();
  });

  // -- cross-session liveness guard repos (P0: the per-user workspace) ------

  it("hasOtherWarmSession: only OTHER sessions' WARM rows count; activeForUserExcept: only OTHER sessions' active runs", async () => {
    const uid = await seedUser();
    const uidOther = await seedUser();
    const a = await sessions.create(db, uid, "guard-a");
    const b = await sessions.create(db, uid, "guard-b");
    const c = await sessions.create(db, uid, "guard-c"); // cold sibling
    const other = await sessions.create(db, uidOther, "guard-other"); // other user, warm

    // No rows at all yet — nothing is live.
    expect(await fileManifests.hasOtherWarmSession(db, uid, a.id)).toBe(false);

    // A warm sibling row (B) trips the manifest half; A's OWN row must not.
    await fileManifests.upsertWarm(db, { sessionId: a.id, userId: uid, workspaceBytes: 1 });
    expect(await fileManifests.hasOtherWarmSession(db, uid, a.id)).toBe(false);
    await fileManifests.upsertWarm(db, { sessionId: b.id, userId: uid, workspaceBytes: 1 });
    expect(await fileManifests.hasOtherWarmSession(db, uid, a.id)).toBe(true);
    // A COLD sibling does not count.
    await fileManifests.markCold(db, {
      sessionId: b.id,
      generation: 1,
      archiveKey: `users/${uid}/workspaces/${b.id}.tar.zst`,
      archiveBytes: 99,
      archiveSha256: SHA_A,
      entryCount: 1,
      uiTree: uiTreeFixture(),
    });
    expect(await fileManifests.hasOtherWarmSession(db, uid, a.id)).toBe(false);
    // ...and a cold-but-registered sibling row for C neither trips nor counts.
    await fileManifests.upsertWarm(db, { sessionId: c.id, userId: uid, workspaceBytes: 1 });
    await fileManifests.markCold(db, {
      sessionId: c.id,
      generation: 1,
      archiveKey: `users/${uid}/workspaces/${c.id}.tar.zst`,
      archiveBytes: 99,
      archiveSha256: SHA_A,
      entryCount: 1,
      uiTree: uiTreeFixture(),
    });
    expect(await fileManifests.hasOtherWarmSession(db, uid, a.id)).toBe(false);
    // Another user's warm row never counts (user scoping).
    await fileManifests.upsertWarm(db, {
      sessionId: other.id,
      userId: uidOther,
      workspaceBytes: 1,
    });
    expect(await fileManifests.hasOtherWarmSession(db, uid, a.id)).toBe(false);

    // Runs half: a queued run on B trips it; A's own run and terminal runs
    // on siblings do not; another user's run never does.
    expect(await runs.activeForUserExcept(db, uid, a.id)).toBeNull();
    await db.insert(runsTable).values({ id: newId(), sessionId: b.id, status: "queued" });
    const active = await runs.activeForUserExcept(db, uid, a.id);
    expect(active).not.toBeNull();
    expect(active!.sessionId).toBe(b.id);
    expect(await runs.activeForUserExcept(db, uid, b.id)).toBeNull(); // B's own run excluded
    // B's run goes terminal → no longer live for A.
    await db
      .update(runsTable)
      .set({ status: "completed" })
      .where(eq(runsTable.sessionId, b.id));
    expect(await runs.activeForUserExcept(db, uid, a.id)).toBeNull();
    // A's OWN active run never counts (exceptSessionId).
    await db.insert(runsTable).values({ id: newId(), sessionId: a.id, status: "running" });
    expect(await runs.activeForUserExcept(db, uid, a.id)).toBeNull();
    await db.insert(runsTable).values({ id: newId(), sessionId: other.id, status: "running" });
    expect(await runs.activeForUserExcept(db, uid, a.id)).toBeNull(); // other user
    await db.insert(runsTable).values({ id: newId(), sessionId: c.id, status: "completed" });
    expect(await runs.activeForUserExcept(db, uid, a.id)).toBeNull(); // terminal
    // uidOther's own run IS found when a DIFFERENT session id is excluded
    // (exclusion is by session id — a.id is not even uidOther's).
    expect(await runs.activeForUserExcept(db, uidOther, a.id)).not.toBeNull();
  });
});
