import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import postgres from "postgres";
import {
  byokKeysRepo,
  createDb,
  imagesRepo,
  migrate,
  sharesRepo,
  type Db,
} from "@ovid/db";
import type { App } from "firebase-admin/app";
import type { Redis } from "ioredis";
import {
  AccountError,
  createCloudCleanup,
  createFirebaseAdmin,
  createHttpKeyAdmin,
  createNoopR2Deleter,
  type KeyAdmin,
  type R2Deleter,
} from "./adapters.js";

// ---------------------------------------------------------------------------
// Port of server/account/tests/test_adapters.py + the cleanup assertions from
// parallel_account_cleanup_test.py, against a real Postgres schema.
// ---------------------------------------------------------------------------

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

class FakeRedis {
  strings = new Map<string, string>();
  sets = new Map<string, Set<string>>();
  deleted: string[] = [];

  async get(key: string): Promise<string | null> {
    return this.strings.get(key) ?? null;
  }
  async scan(_cursor: string | number, ...args: Array<string | number>): Promise<[string, string[]]> {
    const match = String(args[args.indexOf("MATCH") + 1]);
    const re = new RegExp(
      "^" +
        match
          .replace(/[.+^${}()|[\]\\]/g, "\\$&")
          .replace(/\*/g, ".*")
          .replace(/\?/g, ".") +
        "$",
    );
    const keys = [...this.strings.keys(), ...this.sets.keys()].filter((k) => re.test(k));
    return ["0", keys];
  }
  async del(...keys: string[]): Promise<number> {
    let n = 0;
    for (const key of keys) {
      this.deleted.push(key);
      if (this.strings.delete(key)) n += 1;
      if (this.sets.delete(key)) n += 1;
    }
    return n;
  }
  async srem(key: string, member: string): Promise<number> {
    const set = this.sets.get(key);
    if (set === undefined) return 0;
    return set.delete(member) ? 1 : 0;
  }
}

class FakeKeyAdmin implements KeyAdmin {
  blocked: string[] = [];
  deletedKeys: string[] = [];
  /** LiteLLM-side ownership; includes keys whose Redis mapping was lost. */
  listTokens: string[] = [];
  blockStatus = 200;
  deleteStatus = 200;
  listCalls: string[] = [];
  listThrows = false;
  async keyBlock(key: string): Promise<number> {
    this.blocked.push(key);
    return this.blockStatus;
  }
  async keyDelete(keys: string[]): Promise<number> {
    this.deletedKeys.push(...keys);
    return this.deleteStatus;
  }
  async listKeys(userId: string): Promise<string[]> {
    this.listCalls.push(userId);
    if (this.listThrows) throw new Error("key list failed");
    return [...this.listTokens];
  }
}

class FakeR2 implements R2Deleter {
  prefixes: string[] = [];
  async deletePrefix(prefix: string): Promise<void> {
    this.prefixes.push(prefix);
  }
}

describe("createFirebaseAdmin", () => {
  function fakeAuth(over: Record<string, unknown> = {}) {
    return {
      verifyIdToken: vi.fn(),
      getUser: vi.fn(),
      updateUser: vi.fn(),
      deleteUser: vi.fn(),
      ...over,
    };
  }
  function fakeAppCheck(appId = "android-app") {
    return { verifyToken: vi.fn(async () => ({ app_id: appId })) };
  }

  it("rejects a wrong App Check app before verifying the ID token", async () => {
    const auth = fakeAuth();
    const admin = createFirebaseAdmin({} as App, new Set(["android-app"]), {
      auth: auth as never,
      appCheck: fakeAppCheck("other-app") as never,
    });
    await expect(admin.verify("token", "attestation")).rejects.toMatchObject({
      code: "invalid_attestation",
      status: 401,
    });
    expect(auth.verifyIdToken).not.toHaveBeenCalled();
  });

  it("rejects a revoked Firebase token for cancel (never trusts it)", async () => {
    const auth = fakeAuth({
      verifyIdToken: vi.fn(async () => {
        throw Object.assign(new Error("revoked"), { code: "auth/id-token-revoked" });
      }),
    });
    const admin = createFirebaseAdmin({} as App, new Set(["android-app"]), {
      auth: auth as never,
      appCheck: fakeAppCheck() as never,
    });
    await expect(admin.verify("token", "attestation", { allowDisabled: true })).rejects.toMatchObject({
      code: "invalid_authentication",
      status: 401,
    });
  });

  it("recovers a disabled token only when allowed, and checks revocation metadata", async () => {
    const claims = {
      uid: "alice",
      auth_time: 1000,
      firebase: { sign_in_provider: "password" },
    };
    const auth = fakeAuth({
      verifyIdToken: vi
        .fn()
        .mockRejectedValueOnce(Object.assign(new Error("disabled"), { code: "auth/user-disabled" }))
        .mockResolvedValueOnce(claims),
      getUser: vi.fn(async () => ({
        metadata: { lastSignInTime: "Thu, 01 Jan 1970 00:16:39 GMT" },
        tokensValidAfterTime: "Thu, 01 Jan 1970 00:16:39 GMT",
      })),
    });
    const admin = createFirebaseAdmin({} as App, new Set(["android-app"]), {
      auth: auth as never,
      appCheck: fakeAppCheck() as never,
    });
    const decoded = await admin.verify("token", "attestation", { allowDisabled: true });
    expect(decoded._account_disabled).toBe(true);
    expect(auth.verifyIdToken).toHaveBeenNthCalledWith(2, "token", false);
    // Without the allowance the disabled token stays a 401.
    auth.verifyIdToken.mockRejectedValueOnce(
      Object.assign(new Error("disabled"), { code: "auth/user-disabled" }),
    );
    await expect(admin.verify("token", "attestation")).rejects.toMatchObject({
      code: "invalid_authentication",
    });
  });

  it("maps users, disable/enable and idempotent delete", async () => {
    const auth = fakeAuth({
      getUser: vi.fn(async (uid: string) => {
        if (uid === "missing") {
          throw Object.assign(new Error("not found"), { code: "auth/user-not-found" });
        }
        return {
          disabled: false,
          metadata: { lastSignInTime: "Thu, 01 Jan 1970 00:16:40 GMT" },
        };
      }),
      deleteUser: vi.fn(async (uid: string) => {
        if (uid === "missing") {
          throw Object.assign(new Error("not found"), { code: "auth/user-not-found" });
        }
      }),
    });
    const admin = createFirebaseAdmin({} as App, new Set(["android-app"]), {
      auth: auth as never,
      appCheck: fakeAppCheck() as never,
    });
    expect(await admin.user("alice")).toEqual({ disabled: false, last_login_ms: 1_000_000 });
    expect(await admin.user("missing")).toBeNull();
    await admin.disable("alice");
    expect(auth.updateUser).toHaveBeenCalledWith("alice", { disabled: true });
    await admin.enable("alice");
    expect(auth.updateUser).toHaveBeenCalledWith("alice", { disabled: false });
    await expect(admin.delete("missing")).resolves.toBeUndefined();
  });

  it("refuses an empty App Check allowlist", () => {
    expect(() => createFirebaseAdmin({} as App, new Set())).toThrow(
      "App Check app ID allowlist is required",
    );
  });
});

describe("createHttpKeyAdmin", () => {
  it("calls LiteLLM /key/block and /key/delete with the master key and a timeout", async () => {
    const calls: Array<{ url: string; body: unknown; auth: string | null }> = [];
    const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({
        url: String(input),
        body: JSON.parse(String(init?.body)),
        auth: new Headers(init?.headers).get("authorization"),
      });
      return new Response("{}", { status: 200 });
    }) as typeof fetch;
    const admin = createHttpKeyAdmin("https://litellm.invalid/", "sk-master", fetchImpl);
    expect(await admin.keyBlock("tok-a")).toBe(200);
    expect(await admin.keyDelete(["tok-a", "tok-b"])).toBe(200);
    expect(calls).toEqual([
      { url: "https://litellm.invalid/key/block", body: { key: "tok-a" }, auth: "Bearer sk-master" },
      {
        url: "https://litellm.invalid/key/delete",
        body: { keys: ["tok-a", "tok-b"] },
        auth: "Bearer sk-master",
      },
    ]);
  });

  it("returns status 0 on a network failure (caller decides)", async () => {
    const admin = createHttpKeyAdmin("https://litellm.invalid", "sk", (async () => {
      throw new Error("down");
    }) as typeof fetch);
    expect(await admin.keyBlock("tok")).toBe(0);
    expect(await admin.keyDelete(["tok"])).toBe(0);
  });

  it("enumerates owned keys from GET /key/list?user_id= (H4)", async () => {
    const calls: Array<{ url: string; method: string | undefined; auth: string | null }> = [];
    const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({
        url: String(input),
        method: init?.method,
        auth: new Headers(init?.headers).get("authorization"),
      });
      return new Response(
        JSON.stringify({ keys: ["tok-a", { token: "tok-b" }, { key: "tok-c" }, 7, ""] }),
        { status: 200 },
      );
    }) as typeof fetch;
    const admin = createHttpKeyAdmin("https://litellm.invalid/", "sk-master", fetchImpl);
    expect(await admin.listKeys("u1")).toEqual(["tok-a", "tok-b", "tok-c"]);
    expect(calls).toEqual([
      {
        url: "https://litellm.invalid/key/list?user_id=u1",
        method: "GET",
        auth: "Bearer sk-master",
      },
    ]);
  });

  it("fails loudly when the key list cannot be read (never finalize blind)", async () => {
    const down = createHttpKeyAdmin("https://litellm.invalid", "sk", (async () => {
      throw new Error("down");
    }) as typeof fetch);
    await expect(down.listKeys("u1")).rejects.toThrow("key list failed");

    const notFound = createHttpKeyAdmin("https://litellm.invalid", "sk", (async () => {
      return new Response("{}", { status: 404 });
    }) as typeof fetch);
    await expect(notFound.listKeys("u1")).rejects.toThrow("key list failed");
  });
});

describe("createNoopR2Deleter", () => {
  it("pins the seam without any AWS dependency", async () => {
    await expect(createNoopR2Deleter().deletePrefix("users/x/")).resolves.toBeUndefined();
  });
});

const UID = "acct-cleanup-user";
const OTHER = "acct-cleanup-other";
const SESSION = "11111111-1111-7111-8111-111111111111";
const OTHER_SESSION = "22222222-2222-7222-8222-222222222222";
const SCHEDULE = "33333333-3333-7333-8333-333333333333";
const SHARE_TOKEN = "A".repeat(43);
const OTHER_SHARE_TOKEN = "B".repeat(43);

describe.skipIf(!TEST_DATABASE_URL)("createCloudCleanup (real postgres)", () => {
  let db: Db;
  let redis: FakeRedis;
  let keys: FakeKeyAdmin;
  let r2: FakeR2;
  let cleanup: ReturnType<typeof createCloudCleanup>;

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

  beforeEach(async () => {
    await db.$client`DELETE FROM schedule_runs`;
    await db.$client`DELETE FROM schedules`;
    await db.$client`DELETE FROM devices`;
    await db.$client`DELETE FROM notifications`;
    await db.$client`DELETE FROM grants`;
    await db.$client`DELETE FROM file_manifests`;
    await db.$client`DELETE FROM workspace_objects`;
    await db.$client`DELETE FROM attachments`;
    await db.$client`DELETE FROM session_event_mirror`;
    await db.$client`DELETE FROM session_agent_state`;
    await db.$client`DELETE FROM runs`;
    await db.$client`DELETE FROM messages`;
    await db.$client`DELETE FROM sessions`;
    await db.$client`DELETE FROM plugins`;
    await db.$client`DELETE FROM plugin_grants`;
    await db.$client`DELETE FROM mcp_oauth_flows`;
    await db.$client`DELETE FROM mcp_oauth_tokens`;
    await db.$client`DELETE FROM mcp_servers`;
    await db.$client`DELETE FROM byok_keys`;
    await db.$client`DELETE FROM shares`;
    await db.$client`DELETE FROM reports`;
    await db.$client`DELETE FROM user_plan_overrides`;
    await db.$client`DELETE FROM mint_audit`;
    await db.$client`DELETE FROM billing_purchases`;
    await db.$client`DELETE FROM image_jobs`;
    await db.$client`DELETE FROM image_deleted_accounts`;
    await db.$client`DELETE FROM users`;
    await db.$client`DELETE FROM account_deletions`;

    redis = new FakeRedis();
    keys = new FakeKeyAdmin();
    r2 = new FakeR2();
    cleanup = createCloudCleanup({
      db,
      redisDb2: redis as unknown as Redis,
      litellm: keys,
      r2,
      images: {
        deleteAccount: async (uid) => {
          await db.transaction(async (tx) => {
            await imagesRepo.insertDeleted(tx, uid, 1);
            await imagesRepo.clearAccount(tx, uid);
          });
        },
      },
      shares: { deleteAccount: (uid) => sharesRepo.deleteAccount(db, uid) },
      byok: { deleteAccount: (uid) => byokKeysRepo.deleteAccount(db, uid) },
    });
  });

  async function seed() {
    await db.$client`INSERT INTO users (uid, email) VALUES (${UID}, ${"u@test.local"}), (${OTHER}, ${"o@test.local"})`;
    await db.$client`INSERT INTO sessions (id, user_id) VALUES (${SESSION}, ${UID}), (${OTHER_SESSION}, ${OTHER})`;
    await db.$client`INSERT INTO messages (id, session_id, role, content) VALUES
      (${"44444444-4444-7444-8444-444444444444"}, ${SESSION}, 'user', 'secret'),
      (${"55555555-5555-7555-8555-555555555555"}, ${OTHER_SESSION}, 'user', 'keep')`;
    await db.$client`INSERT INTO runs (id, session_id, status) VALUES
      (${"66666666-6666-7666-8666-666666666666"}, ${SESSION}, 'completed')`;
    await db.$client`INSERT INTO session_event_mirror (session_id, seq, type, payload, ts) VALUES
      (${SESSION}, '1-1', 'delta', '{}'::jsonb, now())`;
    await db.$client`INSERT INTO session_agent_state (session_id, state) VALUES (${SESSION}, '{}'::jsonb)`;
    await db.$client`INSERT INTO attachments (id, session_id, user_id, name, size, r2_key) VALUES
      (${"77777777-7777-7777-8777-777777777777"}, ${SESSION}, ${UID}, 'a.txt', 3, ${`users/${UID}/sessions/${SESSION}/uploads/a`})`;
    await db.$client`INSERT INTO grants (id, user_id, session_id, kind, pattern, decision) VALUES
      (${"88888888-8888-8888-8888-888888888888"}, ${UID}, ${SESSION}, 'path', '/tmp/x', 'allow')`;
    await db.$client`INSERT INTO file_manifests (session_id, user_id, state, ui_tree) VALUES
      (${SESSION}, ${UID}, 'cold', '{"entries":[]}'::jsonb)`;
    await db.$client`INSERT INTO workspace_objects (id, user_id, session_id, kind, r2_key, bytes, sha256) VALUES
      (${"99999999-9999-9999-8999-999999999999"}, ${UID}, ${SESSION}, 'artifact', ${`users/${UID}/artifacts/${SESSION}/a`}, 3, 'abc')`;
    await db.$client`INSERT INTO schedules (id, user_id, session_id, title, description, trigger, status) VALUES
      (${SCHEDULE}, ${UID}, ${SESSION}, 't', 'd', '{"type":"cron","expr":"* * * * *"}'::jsonb, 'pending')`;
    await db.$client`INSERT INTO schedule_runs (id, schedule_id, scheduled_for, session_id, trigger_kind, status) VALUES
      (${"aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"}, ${SCHEDULE}, now(), ${SESSION}, 'cron', 'pending')`;
    await db.$client`INSERT INTO reports (id, reporter_uid, request_id, kind, reason, details, excerpt) VALUES
      (${"bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb"}, ${UID}, 'r1', 'k', 'r', 'd', 'e')`;
    await db.$client`INSERT INTO byok_keys (id, user_id, provider_id, endpoint, wrapped_dek, iv, ciphertext, tag) VALUES
      (${"cccccccc-cccc-7ccc-8ccc-cccccccccccc"}, ${UID}, 'p', 'https://p.invalid', 'w', 'i', 'c', 't')`;
    await db.$client`INSERT INTO mcp_servers (id, user_id, name, transport) VALUES
      (${"dddddddd-dddd-7ddd-8ddd-dddddddddddd"}, ${UID}, 'srv', 'http')`;
    await db.$client`INSERT INTO mcp_oauth_flows (state, user_id, server_id, expires_at) VALUES
      ('state-1', ${UID}, ${"dddddddd-dddd-7ddd-8ddd-dddddddddddd"}, now())`;
    await db.$client`INSERT INTO plugins (id, user_id, plugin_id, version, source, status) VALUES
      (${"eeeeeeee-eeee-7eee-8eee-eeeeeeeeeeee"}, ${UID}, 'p/n', '1', '{}'::jsonb, 'active')`;
    await db.$client`INSERT INTO plugin_grants (id, user_id, plugin_id, capabilities, env_names, manifest_digest) VALUES
      (${"ffffffff-ffff-7fff-8fff-ffffffffffff"}, ${UID}, 'p/n', '[]'::jsonb, '[]'::jsonb, 'd')`;
    await db.$client`INSERT INTO devices (token, user_id) VALUES ('dev-1', ${UID})`;
    await db.$client`INSERT INTO notifications (id, user_id, kind, channel, title, body, route, data) VALUES
      (${"12121212-1212-7212-8212-121212121212"}, ${UID}, 'k', 'c', 't', 'b', 'r', '{}'::jsonb)`;
    await db.$client`INSERT INTO user_plan_overrides (uid) VALUES (${UID})`;
    await db.$client`INSERT INTO mint_audit (id, actor, action, target) VALUES
      (${"13131313-1313-7313-8313-131313131313"}, 'admin', 'ban', ${JSON.stringify({ uid: UID })}::jsonb)`;
    await db.$client`INSERT INTO shares (token, owner_uid, session_id, request_id, content, message_count, created_at, expires_at) VALUES
      (${SHARE_TOKEN}, ${UID}, ${SESSION}, 'sr', '{"messages":[]}'::jsonb, 0, now(), now() + interval '1 day'),
      (${OTHER_SHARE_TOKEN}, ${OTHER}, ${OTHER_SESSION}, 'sr2', '{"messages":[]}'::jsonb, 0, now(), now() + interval '1 day')`;
    await db.$client`INSERT INTO image_jobs (account, request, fingerprint, state, reserved, charged, budget_window, created_at) VALUES
      (${UID}, 'img-1', 'f', 'done', '1', '1', 'w', 1)`;

    redis.strings.set(`user:${UID}:keyid`, "tok-a");
    redis.strings.set(`user:${UID}:web:keyid`, "tok-b");
    redis.strings.set(`user:${UID}:tier`, "pro");
    redis.strings.set(`user:${UID}:key`, "sk-plain");
    redis.strings.set(`freecap:${UID}:2026-10`, "1");
    redis.strings.set(`abuse:uid:${UID}`, "2");
    redis.strings.set(`mintlock:${UID}`, "1");
    redis.strings.set(`mintlock:web:${UID}`, "1");
    redis.strings.set(`usagecache:${UID}`, "{}");
    redis.strings.set(`abuse:ip:1.2.3.4`, "shared-counter");
    redis.strings.set(`user:${OTHER}:keyid`, "tok-other");
    redis.sets.set("ovid:uids", new Set([UID, OTHER]));
    redis.sets.set("ipacct:1.2.3.4", new Set([UID, OTHER]));
  }

  async function runAllSteps(ctx: Awaited<ReturnType<typeof cleanup.prepare>>) {
    for (const step of cleanup.deletionSteps()) {
      await step.run(UID, ctx);
    }
  }

  it("captures tokens/session ids, blocks keys, then deletes every uid-owned row idempotently", async () => {
    await seed();
    const ctx = await cleanup.prepare(UID);
    expect(ctx.tokens.sort()).toEqual(["tok-a", "tok-b"]);
    expect(ctx.session_ids).toEqual([SESSION]);

    await cleanup.revokeKeys(UID, ctx);
    expect(keys.blocked.sort()).toEqual(["tok-a", "tok-b"]);

    await runAllSteps(ctx);
    expect(keys.deletedKeys.sort()).toEqual(["tok-a", "tok-b"]);

    // Auth-last ordering is the lifecycle's job; here assert all data stages
    // actually removed their rows.
    for (const [table, column] of [
      ["sessions", "user_id"],
      ["file_manifests", "user_id"],
      ["workspace_objects", "user_id"],
      ["schedules", "user_id"],
      ["grants", "user_id"],
      ["byok_keys", "user_id"],
      ["mcp_servers", "user_id"],
      ["mcp_oauth_flows", "user_id"],
      ["plugins", "user_id"],
      ["plugin_grants", "user_id"],
      ["devices", "user_id"],
      ["notifications", "user_id"],
      ["reports", "reporter_uid"],
    ] as const) {
      const [row] = await db.$client.unsafe(
        `SELECT count(*)::int AS n FROM ${table} WHERE ${column} = $1`,
        [UID],
      );
      expect({ table, n: row.n }).toEqual({ table, n: 0 });
    }
    for (const table of ["messages", "runs", "session_event_mirror", "session_agent_state", "attachments", "schedule_runs"] as const) {
      const [row] = await db.$client.unsafe(
        table === "schedule_runs"
          ? `SELECT count(*)::int AS n FROM schedule_runs WHERE schedule_id = $1`
          : `SELECT count(*)::int AS n FROM ${table} WHERE session_id = $1`,
        [table === "schedule_runs" ? SCHEDULE : SESSION],
      );
      expect({ table, n: row.n }).toEqual({ table, n: 0 });
    }
    // users + plan override + audit-by-target.
    const [users] = await db.$client`SELECT count(*)::int AS n FROM users WHERE uid = ${UID}`;
    expect(users.n).toBe(0);
    const [overrides] = await db.$client`SELECT count(*)::int AS n FROM user_plan_overrides WHERE uid = ${UID}`;
    expect(overrides.n).toBe(0);
    const [audit] = await db.$client`SELECT count(*)::int AS n FROM mint_audit WHERE target->>'uid' = ${UID}`;
    expect(audit.n).toBe(0);
    // The other user's data is untouched.
    const [others] = await db.$client`SELECT count(*)::int AS n FROM sessions WHERE user_id = ${OTHER}`;
    expect(others.n).toBe(1);
    const [otherShare] = await db.$client`SELECT content FROM shares WHERE token = ${OTHER_SHARE_TOKEN}`;
    expect(otherShare.content).toEqual({ messages: [] });
    // Own share content is erased (receipt row retained), images tombstoned.
    const [ownShare] = await db.$client`SELECT content FROM shares WHERE token = ${SHARE_TOKEN}`;
    expect(ownShare.content).toBeNull();
    const [deleted] = await db.$client`SELECT count(*)::int AS n FROM image_deleted_accounts WHERE account = ${UID}`;
    expect(deleted.n).toBe(1);

    // Redis: uid-owned keys gone, memberships removed, shared IP counter kept.
    expect(redis.strings.has(`user:${UID}:keyid`)).toBe(false);
    expect(redis.strings.has(`freecap:${UID}:2026-10`)).toBe(false);
    expect(redis.strings.has(`usagecache:${UID}`)).toBe(false);
    expect(redis.strings.has(`abuse:ip:1.2.3.4`)).toBe(true);
    expect(redis.strings.has(`user:${OTHER}:keyid`)).toBe(true);
    expect(redis.sets.get("ovid:uids")).toEqual(new Set([OTHER]));
    expect(redis.sets.get("ipacct:1.2.3.4")).toEqual(new Set([OTHER]));

    // R2 prefixes: the whole user prefix + the browser subtree.
    expect(r2.prefixes).toContain(`users/${UID}/`);
    expect(r2.prefixes).toContain(`users/${UID}/browser/`);

    // Idempotent replay: every step tolerates already-deleted rows.
    await runAllSteps(ctx);
  });

  it("includes an orphaned LiteLLM key with no Redis keyid mapping (H4)", async () => {
    await seed();
    // The Redis mapping was lost (flush/dual-run/manual provisioning), but
    // LiteLLM still knows the key belongs to the uid.
    keys.listTokens = ["tok-orphan"];
    const ctx = await cleanup.prepare(UID);
    expect(keys.listCalls).toEqual([UID]);
    expect(ctx.tokens.sort()).toEqual(["tok-a", "tok-b", "tok-orphan"]);

    await cleanup.revokeKeys(UID, ctx);
    expect(keys.blocked.sort()).toEqual(["tok-a", "tok-b", "tok-orphan"]);
    await cleanup.deletionSteps()[0]!.run(UID, ctx);
    expect(keys.deletedKeys.sort()).toEqual(["tok-a", "tok-b", "tok-orphan"]);
  });

  it("retries rather than finalize when LiteLLM key enumeration fails (H4)", async () => {
    await seed();
    keys.listThrows = true;
    await expect(cleanup.prepare(UID)).rejects.toThrow("key list failed");
  });

  it("re-asserts child deletes in the terminal stage so a late write cannot wedge (H3)", async () => {
    await seed();
    const ctx = await cleanup.prepare(UID);
    await cleanup.revokeKeys(UID, ctx);

    // Checkpoint every stage EXCEPT the terminal `sql` stage (a durable
    // lifecycle never re-runs a completed checkpoint).
    const steps = cleanup.deletionSteps();
    const terminalIndex = steps.findIndex((step) => step.name === "sql");
    expect(terminalIndex).toBeGreaterThan(0);
    for (const step of steps.slice(0, terminalIndex)) {
      await step.run(UID, ctx);
    }

    // A concurrent gateway write lands AFTER the sessions checkpoint but
    // BEFORE `DELETE FROM users`. sessions.user_id has no ON DELETE CASCADE,
    // so a terminal stage that only deleted `users` would fail here forever.
    const lateSession = "32323232-3232-7232-8232-323232323232";
    await db.$client`INSERT INTO sessions (id, user_id) VALUES (${lateSession}, ${UID})`;
    await db.$client`INSERT INTO messages (id, session_id, role, content) VALUES
      (${"34343434-3434-7434-8434-343434343434"}, ${lateSession}, 'user', 'late')`;

    const terminal = steps[terminalIndex]!;
    await expect(terminal.run(UID, ctx)).resolves.toBeUndefined();
    const [sessions] = await db.$client`SELECT count(*)::int AS n FROM sessions WHERE user_id = ${UID}`;
    const [messages] = await db.$client`SELECT count(*)::int AS n FROM messages WHERE session_id = ${lateSession}`;
    const [users] = await db.$client`SELECT count(*)::int AS n FROM users WHERE uid = ${UID}`;
    expect({ sessions: sessions.n, messages: messages.n, users: users.n }).toEqual({
      sessions: 0,
      messages: 0,
      users: 0,
    });
    // Idempotent replay of the terminal stage.
    await expect(terminal.run(UID, ctx)).resolves.toBeUndefined();
  });

  it("fails the gateway stage on an unacknowledged key deletion (never assumes 404 success)", async () => {
    await seed();
    const ctx = await cleanup.prepare(UID);
    await cleanup.revokeKeys(UID, ctx);
    keys.deleteStatus = 404;
    const gateway = cleanup.deletionSteps()[0]!;
    expect(gateway.name).toBe("gateway");
    await expect(gateway.run(UID, ctx)).rejects.toThrow("key delete failed");
  });

  it("fails the keys stage on an unacknowledged block", async () => {
    await seed();
    const ctx = await cleanup.prepare(UID);
    keys.blockStatus = 500;
    await expect(cleanup.revokeKeys(UID, ctx)).rejects.toThrow("key block failed");
  });

  it("validates a durable cleanup context before effects", async () => {
    await seed();
    expect(() => cleanup.validateContext!({ tokens: "nope", session_ids: [] })).toThrow(
      "invalid cleanup context",
    );
    expect(() => cleanup.validateContext!({ tokens: [], session_ids: [1] })).toThrow(
      "invalid cleanup context",
    );
    expect(() => cleanup.validateContext!({ tokens: [], session_ids: [] })).not.toThrow();
  });
});
