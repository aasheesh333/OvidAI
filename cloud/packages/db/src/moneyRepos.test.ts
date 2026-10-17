import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import postgres from "postgres";
import { createDb, migrate, type Db } from "./client.js";
import { newId, users as usersRepo } from "./repos.js";
import { imageDeletedAccounts, plans as plansTable } from "./schema.js";
import {
  accountDeletions,
  billingPurchases,
  byokKeysRepo,
  imageJobsRepo,
  plansRepo,
  reportsRepo,
  sharesRepo,
  withUidLock,
  PurchaseConflictError,
  ShareConflictError,
  ShareNotFoundError,
  type DeletionRecord,
  type EntitlementFields,
  type ImageJobRow,
  type PlanRecord,
} from "./moneyRepos.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

// Fixed epoch bases — seconds for the Python-ported epoch columns, ms for the
// timestamptz ones — so no assertion depends on wall-clock ties.
const NOW_S = 1_700_000_000;
const NOW_MS = 1_700_000_000_000;

const UUIDV7_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
// 32 random bytes, base64url, unpadded (Python secrets.token_urlsafe(32)).
const SHARE_TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe.skipIf(!TEST_DATABASE_URL)("money repos against real postgres", () => {
  let db: Db;

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    // Same drop/recreate discipline as repos.test.ts (P8-T3 invariant): the
    // drizzle journal, the sandbox-uid sequence and EVERY table any migration
    // creates are dropped so migrate() re-applies from scratch on every run.
    const admin = postgres(url, { max: 1, onnotice: () => {} });
    try {
      await admin.unsafe(`DROP SCHEMA IF EXISTS drizzle CASCADE`);
      await admin.unsafe(`DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE`);
      await admin.unsafe(
        `DROP TABLE IF EXISTS grants, file_manifests, workspace_objects, attachments, session_event_mirror, runs, messages, sessions, users,` +
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

  async function seedUser(): Promise<string> {
    const uid = newId();
    await usersRepo.ensure(db, uid, `u-${uid.slice(0, 8)}@test.local`);
    return uid;
  }

  const plan = (id: string, position: number, over: Partial<PlanRecord> = {}): PlanRecord => ({
    id,
    name: id,
    priceUsd: "5",
    enabled: true,
    aliases: [id],
    windowHours: 24,
    mult: "3",
    slowMode: false,
    autoOss: false,
    position,
    ...over,
  });

  // -------------------------------------------------------------------------
  // plansRepo — plans-as-data, mint settings singleton, per-user overrides
  // -------------------------------------------------------------------------

  it("plans: upsert/list ordered by position, setEnabled; settings singleton round-trip; overrides save/clear; allUids", async () => {
    await plansRepo.upsert(db, plan("starter", 2));
    await plansRepo.upsert(db, plan("free", 0, { priceUsd: "0", aliases: [], mult: "1" }));
    await plansRepo.upsert(
      db,
      plan("pro", 1, { priceUsd: "25", aliases: ["7x"], mult: "23", autoOss: true }),
    );
    let rows = await plansRepo.list(db);
    expect(rows.map((r) => r.id)).toEqual(["free", "pro", "starter"]);
    expect(rows[0]!.aliases).toEqual([]);
    expect(rows[2]!.windowHours).toBe(24);

    // upsert updates in place (same id → changed fields win)
    await plansRepo.upsert(db, plan("pro", 1, { name: "Pro", priceUsd: "25", aliases: ["7x"], mult: "23", autoOss: true }));
    rows = await plansRepo.list(db);
    expect(rows.find((r) => r.id === "pro")!.name).toBe("Pro");

    await plansRepo.setEnabled(db, "starter", false);
    expect((await plansRepo.list(db)).find((r) => r.id === "starter")!.enabled).toBe(false);

    // settings: singleton (id=1) — absent, then saved, then overwritten
    expect(await plansRepo.getSettings(db)).toBeNull();
    const s1 = {
      baseDailyUsd: "0.15",
      scalars: { normal_rpm: 240, hard_ceiling_mult: 3.0 },
      autoOssMembers: [{ model: "gpt-image-1", weight: 1 }],
    };
    await plansRepo.saveSettings(db, s1);
    expect(await plansRepo.getSettings(db)).toEqual(s1);
    await plansRepo.saveSettings(db, { ...s1, baseDailyUsd: "0.50" });
    expect(await plansRepo.getSettings(db)).toEqual({ ...s1, baseDailyUsd: "0.50" });

    // overrides: partial save merges, null clears the field, null row deletes
    const uid = await seedUser();
    expect(await plansRepo.getOverride(db, uid)).toBeNull();
    await plansRepo.saveOverride(db, uid, { dailyUsd: "0.50" });
    expect(await plansRepo.getOverride(db, uid)).toEqual({
      dailyUsd: "0.50",
      monthlyCapUsd: null,
      pools: null,
    });
    await plansRepo.saveOverride(db, uid, { pools: { mult: 2, window_hours: 720 } });
    expect(await plansRepo.getOverride(db, uid)).toEqual({
      dailyUsd: "0.50",
      monthlyCapUsd: null,
      pools: { mult: 2, window_hours: 720 },
    });
    await plansRepo.saveOverride(db, uid, { dailyUsd: null });
    expect(await plansRepo.getOverride(db, uid)).toEqual({
      dailyUsd: null,
      monthlyCapUsd: null,
      pools: { mult: 2, window_hours: 720 },
    });
    await plansRepo.saveOverride(db, uid, null);
    expect(await plansRepo.getOverride(db, uid)).toBeNull();

    const uid2 = await seedUser();
    const uids = await plansRepo.allUids(db);
    expect(uids).toContain(uid);
    expect(uids).toContain(uid2);
  });

  // -------------------------------------------------------------------------
  // billingPurchases — sticky ledger (port of server/billing/store.py)
  // -------------------------------------------------------------------------

  it("billingPurchases: upsert, sticky revoked/replaced, linkedToken replacement, effective ranking, owner conflict", async () => {
    const uid = await seedUser();
    const other = await seedUser();
    const ent = (over: Partial<EntitlementFields> = {}): EntitlementFields => ({
      status: "active",
      tier: "3x",
      product_id: "ovid_plus_monthly",
      expires_at: NOW_S + 100,
      auto_renewing: true,
      linked_token: null,
      account_hash: "hash-a",
      ...over,
    });

    // fresh record binds the owner
    const a1 = await billingPurchases.record(db, "tok-a", ent(), NOW_S, uid);
    expect(a1).toMatchObject({
      token: "tok-a",
      uid,
      productId: "ovid_plus_monthly",
      tier: "3x",
      status: "active",
      expiresAt: NOW_S + 100,
      autoRenewing: true,
      accountHash: "hash-a",
      updatedAt: NOW_S,
    });

    // upsert: a later Play read refreshes fields
    const a2 = await billingPurchases.record(
      db,
      "tok-a",
      ent({ expires_at: NOW_S + 50, auto_renewing: false }),
      NOW_S + 10,
      uid,
    );
    expect(a2.expiresAt).toBe(NOW_S + 50);
    expect(a2.autoRenewing).toBe(false);
    expect(a2.updatedAt).toBe(NOW_S + 10);

    // mark revoked → tier drops to free, auto-renew off
    const revoked = await billingPurchases.mark(db, "tok-a", "revoked", NOW_S + 20);
    expect(revoked).toMatchObject({ status: "revoked", tier: "free", autoRenewing: false });

    // STICKY: a later Play read (even expired/active) never un-revokes
    const sticky = await billingPurchases.record(
      db,
      "tok-a",
      ent({ status: "expired", tier: "7x" }),
      NOW_S + 30,
      uid,
    );
    expect(sticky).toMatchObject({ status: "revoked", tier: "free" });

    // linkedPurchaseToken: the old token is terminally replaced
    await billingPurchases.record(db, "tok-old", ent(), NOW_S, uid);
    const upgraded = await billingPurchases.record(
      db,
      "tok-new",
      ent({ tier: "7x", product_id: "ovid_pro_monthly", linked_token: "tok-old" }),
      NOW_S + 40,
      uid,
    );
    expect(upgraded.tier).toBe("7x");
    expect(await billingPurchases.get(db, "tok-old")).toMatchObject({
      status: "replaced",
      tier: "free",
      autoRenewing: false,
      updatedAt: NOW_S + 40,
    });

    // effective: active + unexpired, highest tier then latest expiry
    await billingPurchases.record(
      db,
      "tok-3x-long",
      ent({ expires_at: NOW_S + 900 }),
      NOW_S,
      uid,
    );
    expect((await billingPurchases.effective(db, uid, NOW_S + 1))?.token).toBe("tok-new"); // 7x beats a later-expiring 3x
    await billingPurchases.record(
      db,
      "tok-longer",
      ent({ tier: "7x", product_id: "ovid_pro_monthly", expires_at: NOW_S + 950 }),
      NOW_S,
      uid,
    );
    expect((await billingPurchases.effective(db, uid, NOW_S + 1))?.token).toBe("tok-longer"); // later expiry
    await billingPurchases.record(
      db,
      "tok-max",
      ent({ tier: "15x", product_id: "ovid_max_monthly", expires_at: NOW_S + 5 }),
      NOW_S,
      uid,
    );
    expect((await billingPurchases.effective(db, uid, NOW_S + 1))?.token).toBe("tok-max"); // higher tier beats later expiry
    expect((await billingPurchases.effective(db, uid, NOW_S + 10))?.token).toBe("tok-longer"); // tok-max expired
    expect(await billingPurchases.effective(db, uid, NOW_S + 10_000)).toBeNull(); // everything expired
    expect(await billingPurchases.effective(db, other, NOW_S + 1)).toBeNull(); // no purchases

    // owner mismatch with an explicit uid → conflict; omitted uid never conflicts
    await expect(billingPurchases.record(db, "tok-a", ent(), NOW_S, other)).rejects.toBeInstanceOf(
      PurchaseConflictError,
    );
    const unbound = await billingPurchases.record(db, "tok-unbound", ent(), NOW_S, uid);
    expect(unbound.uid).toBe(uid);
    await expect(
      billingPurchases.record(db, "tok-unbound", ent(), NOW_S + 1, other),
    ).rejects.toBeInstanceOf(PurchaseConflictError);
    const reread = await billingPurchases.record(db, "tok-unbound", ent({ status: "pending" }), NOW_S + 2);
    expect(reread.status).toBe("pending");
    expect(reread.uid).toBe(uid); // owner sticky when uid omitted

    expect(await billingPurchases.get(db, "missing-token")).toBeNull();
  });

  // -------------------------------------------------------------------------
  // imageJobsRepo — raw import surface for the Task-18 migration scripts
  // -------------------------------------------------------------------------

  it("imageJobsRepo: insert-if-absent round-trip with exact decimal strings and blobs, countByState, tombstones", async () => {
    const pending: ImageJobRow = {
      account: "acct-1",
      request: "req-1",
      fingerprint: "fp-1",
      state: "pending",
      reserved: "0.0300",
      charged: "0",
      actual: null,
      response: null,
      servedModel: null,
      budgetWindow: "uid-1:30d",
      replayUntil: null,
      receiptUntil: null,
      createdAt: NOW_S,
    };
    await imageJobsRepo.insertRaw(db, pending);
    await imageJobsRepo.insertRaw(db, { ...pending, charged: "9.99" }); // existing (account, request) → no-op
    const done: ImageJobRow = {
      ...pending,
      request: "req-0",
      state: "done",
      charged: "0.0300",
      actual: "0.1000",
      response: { data: [{ b64_json: "QUJD", mime_type: "image/png" }], created: NOW_S },
      servedModel: "gpt-image-1",
      replayUntil: NOW_S + 86_400,
      receiptUntil: NOW_S + 90 * 86_400,
    };
    await imageJobsRepo.insertRaw(db, done);

    const rows = await imageJobsRepo.listRaw(db);
    expect(rows).toEqual([done, pending]); // deterministic (account, request) order
    expect(await imageJobsRepo.listRaw(db, { states: ["done"] })).toEqual([done]);
    expect(await imageJobsRepo.listRaw(db, { limit: 1 })).toEqual([done]);
    expect(await imageJobsRepo.countByState(db)).toEqual({ done: 1, pending: 1 });

    await imageJobsRepo.insertDeletedAccountRaw(db, "acct-gone", NOW_S);
    await imageJobsRepo.insertDeletedAccountRaw(db, "acct-gone", NOW_S + 5); // idempotent
    const tombs = await db
      .select()
      .from(imageDeletedAccounts)
      .where(eq(imageDeletedAccounts.account, "acct-gone"));
    expect(tombs).toEqual([{ account: "acct-gone", deletedAt: NOW_S }]);
  });

  // -------------------------------------------------------------------------
  // sharesRepo — receipts, dedup, revoke, fork, purge, account tombstones
  // -------------------------------------------------------------------------

  it("shares: create dedup/conflict, counts, list, update, revoke, fork, publicSnapshot, purgeExpired, deleteAccount", async () => {
    const owner = await seedUser();
    const other = await seedUser();
    const t0 = new Date(NOW_MS);
    // The repo defaults omitted clocks to wall time (production behavior);
    // every call below pins `now` inside the shares' 1 h validity window so
    // the fixed 2023 timestamps never read as expired.
    const at = (ms: number) => ({ now: new Date(NOW_MS + ms) });
    const msgs = [{ role: "user", content: "hello" }];
    const body1 = { sessionId: "sess-1", requestId: "req-1", messages: msgs };

    const r1 = await sharesRepo.create(db, owner, body1, { now: t0, ttlSeconds: 3600 });
    expect(r1.token).toMatch(SHARE_TOKEN_RE);
    expect(r1.sessionId).toBe("sess-1");
    expect(r1.requestId).toBe("req-1");
    expect(r1.createdAt).toEqual(t0);
    expect(r1.expiresAt).toEqual(new Date(NOW_MS + 3_600_000));

    // identical retry → the SAME receipt
    const again = await sharesRepo.create(db, owner, body1, {
      now: new Date(NOW_MS + 5_000),
      ttlSeconds: 3600,
    });
    expect(again).toEqual(r1);

    // changed content under the same request id → conflict (no silent republish)
    await expect(
      sharesRepo.create(
        db,
        owner,
        { ...body1, messages: [{ role: "user", content: "changed" }] },
        { now: t0, ttlSeconds: 3600 },
      ),
    ).rejects.toBeInstanceOf(ShareConflictError);

    expect(await sharesRepo.counts(db, owner, at(30_000))).toEqual({ active: 1, lifetime: 1 });

    const r2 = await sharesRepo.create(
      db,
      owner,
      { sessionId: "sess-2", requestId: "req-2", messages: msgs },
      { now: new Date(NOW_MS + 10_000), ttlSeconds: 3600 },
    );
    const r3 = await sharesRepo.create(
      db,
      owner,
      { sessionId: "sess-1", requestId: "req-3", messages: msgs },
      { now: new Date(NOW_MS + 20_000), ttlSeconds: 10 }, // short-lived
    );
    expect((await sharesRepo.list(db, owner, null, at(25_000))).map((r) => r.requestId)).toEqual([
      "req-3",
      "req-2",
      "req-1",
    ]); // newest first
    expect(
      (await sharesRepo.list(db, owner, "sess-1", at(25_000))).map((r) => r.requestId),
    ).toEqual(["req-3", "req-1"]);

    // update replaces content; the receipt itself is immutable
    const upd = await sharesRepo.update(
      db,
      owner,
      r1.token,
      { ...body1, messages: [{ role: "user", content: "v2" }] },
      at(30_000),
    );
    expect(upd).toEqual(r1);
    expect(await sharesRepo.publicSnapshot(db, r1.token, at(30_000))).toEqual({
      sessionId: "sess-1",
      messages: [{ role: "user", content: "v2" }],
    });
    expect(await sharesRepo.publicSnapshot(db, "x".repeat(43), at(30_000))).toBeNull();

    // fork: idempotent per (token, recipient, requestId)
    const f1 = await sharesRepo.fork(db, other, r1.token, "fork-1", at(30_000));
    expect(f1.sessionId).toMatch(/^[A-Za-z0-9_-]{22}$/);
    expect(
      (await sharesRepo.fork(db, other, r1.token, "fork-1", at(31_000))).sessionId,
    ).toBe(f1.sessionId);
    const f2 = await sharesRepo.fork(db, other, r1.token, "fork-2", at(32_000));
    expect(f2.sessionId).not.toBe(f1.sessionId);
    const rOther = await sharesRepo.create(
      db,
      other,
      { sessionId: "sess-o", requestId: "req-o", messages: msgs },
      { now: t0, ttlSeconds: 3600 },
    );
    // recipient's request id already bound to a different source → conflict
    await expect(
      sharesRepo.fork(db, other, rOther.token, "fork-1", at(33_000)),
    ).rejects.toBeInstanceOf(
      ShareConflictError,
    );
    // revoked source → conflict
    await sharesRepo.revoke(db, owner, r2.token, at(34_000));
    await expect(
      sharesRepo.fork(db, other, r2.token, "fork-3", at(35_000)),
    ).rejects.toBeInstanceOf(
      ShareConflictError,
    );

    // revoke: idempotent for the owner, 404 for wrong owner/unknown, row kept
    await sharesRepo.revoke(db, owner, r2.token, at(36_000));
    await expect(sharesRepo.revoke(db, other, r1.token, at(37_000))).rejects.toBeInstanceOf(
      ShareNotFoundError,
    );
    await expect(sharesRepo.revoke(db, owner, "z".repeat(43), at(38_000))).rejects.toBeInstanceOf(
      ShareNotFoundError,
    );
    expect(
      (await sharesRepo.list(db, owner, null, at(39_000))).map((r) => r.requestId),
    ).toEqual(["req-1"]); // r2 revoked; r3 expired at +30 s (ttl 10 from +20 s)
    expect(await sharesRepo.publicSnapshot(db, r2.token, at(39_000))).toBeNull();
    // expired-but-unpurged r3 already left the active quota, stays in lifetime
    expect(await sharesRepo.counts(db, owner, at(39_000))).toEqual({ active: 1, lifetime: 3 });
    // a revoked request id can never be republished
    await expect(
      sharesRepo.create(
        db,
        owner,
        { sessionId: "sess-2", requestId: "req-2", messages: msgs },
        { now: t0, ttlSeconds: 3600 },
      ),
    ).rejects.toBeInstanceOf(ShareConflictError);

    // purgeExpired: content erased past expiry, receipt row retained for dedup
    const purged = await sharesRepo.purgeExpired(db, 100, at(60_000));
    expect(purged).toBe(1); // r3 (ttl 10 s); r1 live, r2 already content-null
    expect(await sharesRepo.publicSnapshot(db, r3.token, at(61_000))).toBeNull();
    expect((await sharesRepo.counts(db, owner, at(61_000))).active).toBe(1);
    await expect(
      sharesRepo.create(db, owner, { sessionId: "sess-1", requestId: "req-3", messages: msgs }, {
        now: new Date(NOW_MS + 61_000),
        ttlSeconds: 3600,
      }),
    ).rejects.toBeInstanceOf(ShareConflictError);

    // deleteAccount: rows kept as tombstones (content null, purgedAt set), forks erased
    await sharesRepo.deleteAccount(db, other, at(62_000));
    const f1again = await sharesRepo.fork(db, other, r1.token, "fork-1", at(62_500));
    expect(f1again.sessionId).not.toBe(f1.sessionId); // the old fork row is gone
    await sharesRepo.deleteAccount(db, owner, at(63_000));
    await sharesRepo.deleteAccount(db, owner, at(64_000)); // idempotent
    expect(await sharesRepo.counts(db, owner, at(65_000))).toEqual({ active: 0, lifetime: 3 });
    expect(await sharesRepo.publicSnapshot(db, r1.token, at(65_000))).toBeNull();
    await expect(
      sharesRepo.create(db, owner, body1, { now: new Date(NOW_MS + 65_000), ttlSeconds: 3600 }),
    ).rejects.toBeInstanceOf(ShareConflictError);
  });

  // -------------------------------------------------------------------------
  // reportsRepo
  // -------------------------------------------------------------------------

  it("reports: create dedup on (reporter, requestId), listOpen oldest first", async () => {
    const reporter = await seedUser();
    const other = await seedUser();
    const body = {
      requestId: "req-report-0001",
      kind: "ai_output",
      reason: "spam",
      details: "d",
      excerpt: "e",
      targetId: null,
      model: "auto",
    };
    const first = await reportsRepo.create(db, reporter, body);
    expect(first.created).toBe(true);
    expect(first.id).toMatch(UUIDV7_RE);
    expect(await reportsRepo.create(db, reporter, body)).toEqual({ id: first.id, created: false });
    // same request id under a different reporter is a distinct report
    expect((await reportsRepo.create(db, other, body)).created).toBe(true);

    const open = await reportsRepo.listOpen(db, 100);
    const mine = open.filter((r) => r.requestId === body.requestId);
    expect(mine).toHaveLength(2);
    expect(mine.every((r) => r.status === "open" && r.reporterUid !== null)).toBe(true);
  });

  // -------------------------------------------------------------------------
  // byokKeysRepo
  // -------------------------------------------------------------------------

  it("byokKeys: ownership scoping, setTestResult, remove, deleteAccount idempotent", async () => {
    const uid = await seedUser();
    const stranger = await seedUser();
    const ins = {
      userId: uid,
      providerId: "openai",
      endpoint: "https://api.openai.com/v1",
      label: "main",
      wrappedDek: "wd",
      iv: "iv",
      ciphertext: "ct",
      tag: "tag",
    };
    const k1 = await byokKeysRepo.create(db, ins);
    expect(k1.id).toMatch(UUIDV7_RE);
    expect(k1.status).toBe("active");
    expect(k1.lastTestAt).toBeNull();
    expect(k1.lastTestOk).toBeNull();
    const k2 = await byokKeysRepo.create(db, { ...ins, label: null });

    expect((await byokKeysRepo.list(db, uid)).map((k) => k.id).sort()).toEqual(
      [k1.id, k2.id].sort(),
    );
    expect(await byokKeysRepo.list(db, stranger)).toEqual([]);
    expect(await byokKeysRepo.get(db, k1.id, stranger)).toBeNull(); // wrong owner → null
    expect((await byokKeysRepo.get(db, k1.id, uid))!.ciphertext).toBe("ct");

    const at = new Date(NOW_MS);
    await byokKeysRepo.setTestResult(db, k1.id, true, at);
    const tested = await byokKeysRepo.get(db, k1.id, uid);
    expect(tested!.lastTestOk).toBe(true);
    expect(tested!.lastTestAt).toEqual(at);

    expect(await byokKeysRepo.remove(db, k1.id, stranger)).toBe(false);
    expect(await byokKeysRepo.remove(db, k1.id, uid)).toBe(true);
    expect(await byokKeysRepo.remove(db, k1.id, uid)).toBe(false);

    await byokKeysRepo.deleteAccount(db, uid);
    expect(await byokKeysRepo.list(db, uid)).toEqual([]);
    await byokKeysRepo.deleteAccount(db, uid); // idempotent re-run
  });

  // -------------------------------------------------------------------------
  // accountDeletions — due() with the exact Python ordering
  // -------------------------------------------------------------------------

  it("accountDeletions: due() eligibility + ordering (poison row after unattempted); get/save round-trip", async () => {
    const rec = (over: Record<string, unknown> = {}) => ({
      request_id: "rid",
      state: "pending",
      requested_at: NOW_S - 100,
      delete_after: NOW_S - 50,
      fence_at: null,
      fence_owned: false,
      completed: [],
      request_aliases: [],
      attempts: 0,
      next_attempt: 0,
      previous_requests: [],
      ...over,
    });
    const save = (uid: string, state: string, deleteAfter: number, record: Record<string, unknown>) =>
      accountDeletions.save(db, { uid, state, deleteAfter, record });

    await save("u-poison", "pending", NOW_S - 500, rec({ attempts: 9 }));
    await save("u-a", "pending", NOW_S - 300, rec());
    await save("u-b", "pending", NOW_S - 400, rec());
    await save("u-future", "pending", NOW_S + 1000, rec()); // delete_after in future → not due
    await save("u-cf", "cancelled", NOW_S + 5000, rec({ state: "cancelled", fence_owned: true })); // fence handback → due
    await save("u-cp", "cancelled", NOW_S + 5000, rec({ state: "cancelled" })); // no fence → not due
    await save("u-backoff", "pending", NOW_S - 600, rec({ next_attempt: NOW_S + 100 })); // retry backoff → not due
    await save("u-deleting", "deleting", NOW_S - 10, rec({ state: "deleting", attempts: 2 }));

    // ORDER BY next_attempt, attempts, delete_after, uid (server/account/postgres.py)
    expect(await accountDeletions.due(db, NOW_S)).toEqual([
      "u-b",
      "u-a",
      "u-cf",
      "u-deleting",
      "u-poison",
    ]);

    const got = await accountDeletions.get(db, "u-a");
    expect(got).toEqual({ uid: "u-a", state: "pending", deleteAfter: NOW_S - 300, record: rec() });
    expect(await accountDeletions.get(db, "missing")).toBeNull();

    await accountDeletions.save(db, {
      uid: "u-a",
      state: "fenced",
      deleteAfter: NOW_S - 300,
      record: rec({ state: "fenced", fence_owned: true }),
    } satisfies DeletionRecord);
    expect((await accountDeletions.get(db, "u-a"))!.state).toBe("fenced");
  });

  // -------------------------------------------------------------------------
  // withUidLock — advisory-lock serialization (port of the Python store lock)
  // -------------------------------------------------------------------------

  it("withUidLock: serializes concurrent critical sections on one uid; releases on success and error", async () => {
    await plansRepo.upsert(db, plan("locktest", 0));
    const bump = (uid: string) =>
      withUidLock(db, uid, async (tx) => {
        const [row] = await tx.select().from(plansTable).where(eq(plansTable.id, "locktest"));
        const pos = row!.position;
        await sleep(60); // widen the race window: unlocked, both sections read the same pos
        await tx.update(plansTable).set({ position: pos + 1 }).where(eq(plansTable.id, "locktest"));
      });
    await Promise.all([bump("lock-uid"), bump("lock-uid")]);
    const [after] = await db.select().from(plansTable).where(eq(plansTable.id, "locktest"));
    expect(after!.position).toBe(2); // the second section saw the first's write

    // lock released after the section: an immediate re-acquire does not wait
    await withUidLock(db, "lock-uid", async () => {});
    // errors propagate and still release the lock
    await expect(
      withUidLock(db, "lock-uid", async () => {
        throw new Error("boom");
      }),
    ).rejects.toThrow("boom");
    await withUidLock(db, "lock-uid", async () => {}); // would hit the 30 s lock timeout if leaked
  });
});
