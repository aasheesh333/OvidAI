import { afterAll, beforeAll, describe, expect, it } from "vitest";
import postgres from "postgres";
import { createDb, migrate, newId, sessions, type Db } from "./index.js";
import { grantsRepo } from "./repos.js";
import { users } from "./schema.js";

/**
 * grantsRepo (P3 Task 12 — hierarchical permission grants, session-scoped)
 * against real Postgres. Same drop/recreate discipline as repos.test.ts:
 * the journal, the sandbox-uid sequence and every table any migration
 * creates are dropped so migrate() re-applies from scratch on every run.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

const UUIDV7_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

describe.skipIf(!TEST_DATABASE_URL)("grantsRepo against real postgres", () => {
  let db: Db;

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    // onnotice: swallow server NOTICEs ("table … does not exist, skipping") on fresh DBs
    const admin = postgres(url, { max: 1, onnotice: () => {} });
    try {
      await admin.unsafe(`DROP SCHEMA IF EXISTS drizzle CASCADE`);
      await admin.unsafe(`DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE`);
      // Every table any migration creates (P8-T3 rerunnability invariant).
      await admin.unsafe(
        `DROP TABLE IF EXISTS grants, file_manifests, workspace_objects, attachments, session_event_mirror, session_agent_state, runs, messages, sessions, users,` +
          ` plans, mint_settings, user_plan_overrides, mint_audit, billing_purchases, image_jobs,` +
          ` image_deleted_accounts, image_cards, image_card_history, image_probe_log, image_probe_state,` +
          ` shares, share_forks, reports, account_deletions, byok_keys,` +
          ` mcp_servers, mcp_oauth_tokens, mcp_oauth_flows, plugins, plugin_grants CASCADE`,
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

  async function seedUserAndSession(): Promise<{ userId: string; sessionId: string }> {
    const uid = newId();
    await db.insert(users).values({ uid, email: `u-${uid.slice(0, 8)}@test.local` });
    const row = await sessions.create(db, uid, null);
    return { userId: uid, sessionId: row.id };
  }

  it("add/list round-trip: rows come back in insertion order with every column", async () => {
    const { userId, sessionId } = await seedUserAndSession();
    const g1 = await grantsRepo.add(db, {
      userId,
      sessionId,
      kind: "path",
      pattern: "/ws/a",
      decision: "always",
      mode: "auto",
    });
    const g2 = await grantsRepo.add(db, {
      userId,
      sessionId,
      kind: "host",
      pattern: "example.com",
      decision: "deny",
      mode: "studio",
    });
    const g3 = await grantsRepo.add(db, {
      userId,
      sessionId,
      kind: "path",
      pattern: "/etc",
      decision: "allow",
      mode: null,
    });

    expect(g1.id).toMatch(UUIDV7_RE);
    expect(g1.userId).toBe(userId);
    expect(g1.sessionId).toBe(sessionId);
    expect(g1.kind).toBe("path");
    expect(g1.pattern).toBe("/ws/a");
    expect(g1.decision).toBe("always");
    expect(g1.mode).toBe("auto");
    expect(g1.createdAt).toBeInstanceOf(Date);

    const rows = await grantsRepo.listForSession(db, userId, sessionId);
    expect(rows).toHaveLength(3);
    // Insertion order (createdAt then id — same message-page convention).
    expect(rows.map((r) => r.id)).toEqual([g1.id, g2.id, g3.id]);
    expect(rows[1]).toMatchObject({ kind: "host", pattern: "example.com", decision: "deny", mode: "studio" });
    expect(rows[2]).toMatchObject({ pattern: "/etc", decision: "allow", mode: null });
  });

  it("listForSession is scoped by BOTH userId and sessionId", async () => {
    const a = await seedUserAndSession();
    const b = await seedUserAndSession();
    await grantsRepo.add(db, {
      userId: a.userId,
      sessionId: a.sessionId,
      kind: "path",
      pattern: "/ws/a",
      decision: "always",
      mode: "auto",
    });

    // Same user, different session → empty.
    const otherSession = await sessions.create(db, a.userId, null);
    expect(await grantsRepo.listForSession(db, a.userId, otherSession.id)).toEqual([]);
    // Different user, same session id → empty (no cross-user leakage).
    expect(await grantsRepo.listForSession(db, b.userId, a.sessionId)).toEqual([]);
    // The owning pair sees exactly its row.
    expect(await grantsRepo.listForSession(db, a.userId, a.sessionId)).toHaveLength(1);
  });

  it("remove is scoped by userId: a stranger's remove is a no-op", async () => {
    const owner = await seedUserAndSession();
    const stranger = await seedUserAndSession();
    const row = await grantsRepo.add(db, {
      userId: owner.userId,
      sessionId: owner.sessionId,
      kind: "host",
      pattern: "example.com",
      decision: "always",
      mode: "auto",
    });

    expect(await grantsRepo.remove(db, row.id, stranger.userId)).toBe(false);
    expect(await grantsRepo.listForSession(db, owner.userId, owner.sessionId)).toHaveLength(1);

    expect(await grantsRepo.remove(db, row.id, owner.userId)).toBe(true);
    expect(await grantsRepo.remove(db, row.id, owner.userId)).toBe(false); // idempotent second remove
    expect(await grantsRepo.listForSession(db, owner.userId, owner.sessionId)).toEqual([]);
  });

  it("remove of an unknown id is a silent false (no existence leak)", async () => {
    const { userId } = await seedUserAndSession();
    expect(await grantsRepo.remove(db, newId(), userId)).toBe(false);
  });
});
