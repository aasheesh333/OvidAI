import { afterAll, beforeAll, describe, expect, it } from "vitest";
import postgres from "postgres";
import { accountDeletions, createDb, migrate, type Db } from "@ovid/db";
import { createPostgresDeletionStore, type DeletionRow } from "./store.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const NOW = 1_700_000_000;

function row(over: Partial<DeletionRow> & Pick<DeletionRow, "uid">): DeletionRow {
  return {
    request_id: `request-${over.uid}`,
    state: "pending",
    requested_at: NOW,
    delete_after: NOW + 86_400,
    baseline_login_ms: 0,
    fence_at: null,
    fence_owned: false,
    completed: [],
    request_aliases: [],
    attempts: 0,
    next_attempt: 0,
    previous_requests: [],
    ...over,
  };
}

describe.skipIf(!TEST_DATABASE_URL)("createPostgresDeletionStore (real postgres)", () => {
  let db: Db;

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    const admin = postgres(url, { max: 1, onnotice: () => {} });
    try {
      await admin.unsafe(`DROP SCHEMA IF EXISTS drizzle CASCADE`);
      await admin.unsafe(`DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE`);
      await admin.unsafe(
        `DROP TABLE IF EXISTS schedules, schedule_runs, devices, notifications, grants, file_manifests, workspace_objects, attachments, session_event_mirror, session_agent_state, runs, messages, sessions, users,` +
          ` plans, mint_settings, user_plan_overrides, mint_audit, billing_purchases, image_jobs,` +
          ` image_deleted_accounts, image_cards, image_card_history, image_probe_log, image_probe_state,` +
          ` shares, share_forks, reports, account_deletions, byok_keys,` +
          ` mcp_servers, mcp_oauth_tokens, mcp_oauth_flows, plugins, plugin_grants, run_usage CASCADE`,
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

  it("round-trips the Python record shape through the jsonb column", async () => {
    const store = createPostgresDeletionStore(db);
    const saved = row({ uid: "store-roundtrip", request_aliases: ["alias-1"] });
    await store.locked("store-roundtrip", async (s) => {
      expect(await s.get("store-roundtrip")).toBeNull();
      await s.save(saved);
    });
    const read = await store.locked("store-roundtrip", async (s) => s.get("store-roundtrip"));
    expect(read).toEqual(saved);
    const raw = await accountDeletions.get(db, "store-roundtrip");
    expect(raw).toMatchObject({
      uid: "store-roundtrip",
      state: "pending",
      deleteAfter: saved.delete_after,
    });
    expect(raw!.record).toMatchObject({ uid: "store-roundtrip", request_id: "request-store-roundtrip" });
  });

  it("stores and queries a fractional delete_after (Python clock parity, C1)", async () => {
    // server/account/domain.py's default clock is time.time(): FRACTIONAL.
    // The column is `double precision` in Python (schema.sql) and must accept
    // these values through the real Postgres store — a bigint column raised
    // 22P02 and made account deletion dead in production (P9 final review C1).
    const store = createPostgresDeletionStore(db);
    const uid = "store-fractional";
    const deadline = NOW + 0.25;
    await store.locked(uid, async (s) => s.save(row({ uid, delete_after: deadline })));

    const read = await store.locked(uid, async (s) => s.get(uid));
    expect(read!.delete_after).toBe(deadline);
    expect((await accountDeletions.get(db, uid))!.deleteAfter).toBe(deadline);

    // The sweeper clock is fractional too: not due before, due after.
    expect(await store.due(NOW + 0.1)).not.toContain(uid);
    expect(await store.due(NOW + 0.5)).toContain(uid);
  });

  it("due() delegates the exact Python eligibility/order (unattempted before poison)", async () => {
    const store = createPostgresDeletionStore(db);
    // Due now, unattempted.
    await store.locked("due-a", async (s) =>
      s.save(row({ uid: "due-a", delete_after: NOW - 1 })),
    );
    // Due now, attempted once.
    await store.locked("due-b", async (s) =>
      s.save(row({ uid: "due-b", delete_after: NOW - 1, attempts: 1 })),
    );
    // Not due (delete_after in the future).
    await store.locked("due-future", async (s) =>
      s.save(row({ uid: "due-future", delete_after: NOW + 10 })),
    );
    // Cancelled with a worker-owned fence → due regardless of deadline.
    await store.locked("due-cancel", async (s) =>
      s.save(row({ uid: "due-cancel", state: "cancelled", fence_owned: true })),
    );
    // Cancelled without a fence → not due.
    await store.locked("due-cancel-clean", async (s) =>
      s.save(row({ uid: "due-cancel-clean", state: "cancelled", fence_owned: false })),
    );
    // Backoff not yet elapsed.
    await store.locked("due-backoff", async (s) =>
      s.save(row({ uid: "due-backoff", delete_after: NOW - 1, next_attempt: NOW + 60 })),
    );

    // next_attempt (all 0) → attempts (a=0, cancel=0, b=1) → delete_after → uid.
    expect(await store.due(NOW)).toEqual(["due-a", "due-cancel", "due-b"]);
  });

  it("serializes concurrent critical sections and releases the advisory lock on error", async () => {
    const store = createPostgresDeletionStore(db);
    const events: string[] = [];
    let active = 0;
    let maxActive = 0;
    const section = (id: string) =>
      store.locked("store-lock", async (s) => {
        active += 1;
        maxActive = Math.max(maxActive, active);
        events.push(`start-${id}`);
        await new Promise((r) => setTimeout(r, 10));
        events.push(`end-${id}`);
        active -= 1;
        await s.get("store-lock");
      });
    await Promise.all([section("1"), section("2")]);
    expect(maxActive).toBe(1);
    expect(events).toHaveLength(4);

    await expect(
      store.locked("store-lock", async () => {
        throw new Error("boom");
      }),
    ).rejects.toThrow("boom");
    // If the lock leaked, this would block for the 30 s lock_timeout.
    await expect(store.locked("store-lock", async () => "recovered")).resolves.toBe("recovered");
  }, 10_000);
});
