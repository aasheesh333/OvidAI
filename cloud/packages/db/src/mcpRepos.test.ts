import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import postgres from "postgres";
import { createDb, migrate, type Db } from "./client.js";
import {
  mcpOauthFlows,
  mcpOauthTokens,
  mcpServers,
  newId,
  pluginGrants,
  plugins,
  users as usersRepo,
} from "./repos.js";
import {
  mcpServers as mcpServersTable,
  plugins as pluginsTable,
  users,
} from "./schema.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

const UUIDV7_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

// ---------------------------------------------------------------------------
// LOCAL test-db helpers — the apps/gateway/src/test/db.ts conventions copied
// as literal code, deliberately NOT imported: a @ovid/db package test must not
// import from an app. (The drop-list discipline below follows repos.test.ts /
// moneyRepos.test.ts instead: this file owns a full drop/recreate so the
// journal re-applies from scratch on every run.)
// ---------------------------------------------------------------------------

async function openTestDb(): Promise<Db> {
  const url = TEST_DATABASE_URL!;
  await migrate(url);
  return createDb(url);
}

/** Fresh per-test uid (never collides with other files' data). */
function testUid(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

/** Structural EncryptedEnvelope fixture — repos never decrypt, just store. */
function sealed(): { wrappedDek: string; iv: string; ciphertext: string; tag: string } {
  return {
    wrappedDek: Buffer.from(newId()).toString("base64"),
    iv: Buffer.alloc(12, 7).toString("base64"),
    ciphertext: Buffer.from(`${newId()}${newId()}`).toString("base64"),
    tag: Buffer.alloc(16, 3).toString("base64"),
  };
}

describe.skipIf(!TEST_DATABASE_URL)("mcp/plugin repos against real postgres", () => {
  let db: Db;

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    // onnotice: swallow server NOTICEs ("table … does not exist, skipping") on fresh DBs
    const admin = postgres(url, { max: 1, onnotice: () => {} });
    try {
      await admin.unsafe(`DROP SCHEMA IF EXISTS drizzle CASCADE`);
      await admin.unsafe(`DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE`);
      // Every table any migration creates (the P8-T3 rerunnability invariant —
      // this list is kept in sync with repos.test.ts and moneyRepos.test.ts).
      await admin.unsafe(
        `DROP TABLE IF EXISTS file_manifests, workspace_objects, attachments, session_event_mirror, runs, messages, sessions, users,` +
          ` plans, mint_settings, user_plan_overrides, mint_audit, billing_purchases, image_jobs,` +
          ` image_deleted_accounts, image_cards, image_card_history, image_probe_log, image_probe_state,` +
          ` shares, share_forks, reports, account_deletions, byok_keys,` +
          ` mcp_oauth_tokens, mcp_oauth_flows, plugins, plugin_grants, mcp_servers CASCADE`,
      );
    } finally {
      await admin.end({ timeout: 5 });
    }
    db = await openTestDb();
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function seedUser(): Promise<string> {
    const uid = testUid("mcp");
    await db.insert(users).values({ uid, email: `u-${uid.slice(0, 12)}@test.local` });
    return uid;
  }

  // -------------------------------------------------------------------------

  it("mcpServers CRUD round-trip; UNIQUE(user_id, name) violation surfaces", async () => {
    const uid = await seedUser();
    const secrets = sealed();

    const server = await mcpServers.create(db, {
      userId: uid,
      name: "github",
      transport: "http",
      curatedId: "github",
      config: { url: "https://api.github.com/mcp", type: "http" },
      secretsSealed: secrets,
    });
    expect(server.id).toMatch(UUIDV7_RE);
    expect(server.userId).toBe(uid);
    expect(server.name).toBe("github");
    expect(server.transport).toBe("http");
    expect(server.curatedId).toBe("github");
    expect(server.config).toEqual({ url: "https://api.github.com/mcp", type: "http" });
    expect(server.secretsSealed).toEqual(secrets);
    expect(server.enabled).toBe(true); // column default
    expect(server.createdAt).toBeInstanceOf(Date);
    expect(server.updatedAt).toBeInstanceOf(Date);

    // get + findByName
    expect(await mcpServers.get(db, server.id, uid)).toEqual(server);
    expect((await mcpServers.findByName(db, uid, "github"))!.id).toBe(server.id);
    expect(await mcpServers.findByName(db, uid, "nope")).toBeNull();

    // list
    const other = await mcpServers.create(db, {
      userId: uid,
      name: "local-fs",
      transport: "stdio",
      config: { command: "npx", args: ["-y", "fs-mcp"] },
    });
    const listed = await mcpServers.list(db, uid);
    expect(listed.map((r) => r.id).sort()).toEqual([server.id, other.id].sort());

    // update (partial patch)
    const patched = await mcpServers.update(db, server.id, uid, {
      name: "github-main",
      enabled: false,
      secretsSealed: sealed(),
    });
    expect(patched!.name).toBe("github-main");
    expect(patched!.enabled).toBe(false);
    expect(patched!.transport).toBe("http"); // untouched
    expect(patched!.secretsSealed).not.toEqual(secrets);
    expect(patched!.updatedAt.getTime()).toBeGreaterThanOrEqual(server.updatedAt.getTime());

    // UNIQUE(user_id, name): a second server with the same name for the SAME
    // user raises 23505 at the DB — the violation must surface (not be
    // silently swallowed by an upsert). Drizzle wraps the driver error, so
    // the code lives on the .cause chain (same shape as
    // users.allocateSandboxUid's handling).
    const dup = mcpServers.create(db, { userId: uid, name: "github-main", transport: "http" });
    await expect(dup).rejects.toThrow();
    await dup.catch((err: unknown) => {
      let e: unknown = err;
      let sawUnique = false;
      for (let depth = 0; e instanceof Error && depth < 5; depth++) {
        if (/duplicate key|unique/i.test(e.message)) sawUnique = true;
        e = (e as { cause?: unknown }).cause;
      }
      expect(sawUnique).toBe(true);
    });
    // …while the same name under a DIFFERENT user is fine (the constraint is
    // per-user).
    const uid2 = await seedUser();
    const sameName = await mcpServers.create(db, { userId: uid2, name: "github-main", transport: "http" });
    expect(sameName.userId).toBe(uid2);

    // remove
    expect(await mcpServers.remove(db, other.id, uid)).toBe(true);
    expect(await mcpServers.get(db, other.id, uid)).toBeNull();
    expect(await mcpServers.remove(db, other.id, uid)).toBe(false); // already gone
  });

  it("mcpServers ownership: wrong uid → null/false, row untouched", async () => {
    const uid = await seedUser();
    const stranger = await seedUser();
    const server = await mcpServers.create(db, {
      userId: uid,
      name: "owned",
      transport: "http",
      config: { url: "https://mcp.example" },
    });

    expect(await mcpServers.get(db, server.id, stranger)).toBeNull();
    expect(await mcpServers.findByName(db, stranger, "owned")).toBeNull();
    expect(await mcpServers.list(db, stranger)).toEqual([]);

    const patched = await mcpServers.update(db, server.id, stranger, { enabled: false });
    expect(patched).toBeNull();
    const untouched = await mcpServers.get(db, server.id, uid);
    expect(untouched!.enabled).toBe(true); // the stranger's write did NOT land

    expect(await mcpServers.remove(db, server.id, stranger)).toBe(false);
    expect(await mcpServers.get(db, server.id, uid)).not.toBeNull(); // still there
  });

  it("mcpOauthTokens put/get/remove (ownership-scoped)", async () => {
    const uid = await seedUser();
    const stranger = await seedUser();
    const server = await mcpServers.create(db, { userId: uid, name: "oauth-srv", transport: "http" });

    const tokens = sealed();
    await mcpOauthTokens.put(db, { userId: uid, serverId: server.id, tokensSealed: tokens });
    let row = await mcpOauthTokens.get(db, server.id, uid);
    expect(row!.serverId).toBe(server.id);
    expect(row!.tokensSealed).toEqual(tokens);
    expect(row!.updatedAt).toBeInstanceOf(Date);

    // put again = upsert (UNIQUE(server_id)): tokens replaced, no second row.
    const refreshed = sealed();
    await mcpOauthTokens.put(db, { userId: uid, serverId: server.id, tokensSealed: refreshed });
    row = await mcpOauthTokens.get(db, server.id, uid);
    expect(row!.tokensSealed).toEqual(refreshed);

    // wrong owner → null
    expect(await mcpOauthTokens.get(db, server.id, stranger)).toBeNull();
    // wrong owner remove → row survives
    await mcpOauthTokens.remove(db, server.id, stranger);
    expect(await mcpOauthTokens.get(db, server.id, uid)).not.toBeNull();

    await mcpOauthTokens.remove(db, server.id, uid);
    expect(await mcpOauthTokens.get(db, server.id, uid)).toBeNull();
  });

  it("mcpOauthFlows.consume is one-use; expired → null", async () => {
    const uid = await seedUser();
    const server = await mcpServers.create(db, { userId: uid, name: "flow-srv", transport: "http" });
    const state = `st-${newId()}`;

    await mcpOauthFlows.create(db, {
      state,
      userId: uid,
      serverId: server.id,
      verifierSealed: sealed(),
      config: { clientId: "abc", authUrl: "https://auth.example", tokenUrl: "https://token.example" },
      expiresAt: new Date(Date.now() + 60_000),
    });

    // First consume wins and returns the row.
    const consumed = await mcpOauthFlows.consume(db, state);
    expect(consumed!.userId).toBe(uid);
    expect(consumed!.serverId).toBe(server.id);
    expect(consumed!.used).toBe(true);
    expect(consumed!.verifierSealed).toEqual(expect.anything());
    expect(consumed!.config).toMatchObject({ clientId: "abc" });

    // Second consume of the SAME state → null (atomic one-use).
    expect(await mcpOauthFlows.consume(db, state)).toBeNull();

    // Unknown state → null.
    expect(await mcpOauthFlows.consume(db, `st-${newId()}`)).toBeNull();

    // Expired flow → null (inserted with a past expires_at, never consumed).
    const expiredState = `st-${newId()}`;
    await mcpOauthFlows.create(db, {
      state: expiredState,
      userId: uid,
      serverId: server.id,
      verifierSealed: sealed(),
      config: null,
      expiresAt: new Date(Date.now() - 1_000),
    });
    expect(await mcpOauthFlows.consume(db, expiredState)).toBeNull();
  });

  it("plugins.upsert updates on (user_id, plugin_id) conflict", async () => {
    const uid = await seedUser();

    const first = await plugins.upsert(db, {
      userId: uid,
      pluginId: "ovid/emoji",
      version: "1.0.0",
      source: { kind: "npm", spec: "ovid-emoji@1.0.0" },
      status: "installing",
    });
    expect(first.id).toMatch(UUIDV7_RE);
    expect(first.pluginId).toBe("ovid/emoji");
    expect(first.status).toBe("installing");
    expect(first.installedAt).toBeInstanceOf(Date);

    // Same (user, pluginId) → UPDATE, not a duplicate row.
    const second = await plugins.upsert(db, {
      userId: uid,
      pluginId: "ovid/emoji",
      version: "1.1.0",
      source: { kind: "npm", spec: "ovid-emoji@1.1.0" },
      status: "active",
      manifest: { name: "emoji", version: "1.1.0" },
    });
    expect(second.id).toBe(first.id);
    expect(second.version).toBe("1.1.0");
    expect(second.status).toBe("active");
    expect(second.manifest).toEqual({ name: "emoji", version: "1.1.0" });

    const rows = await db.select().from(pluginsTable).where(eq(pluginsTable.userId, uid));
    expect(rows).toHaveLength(1);

    // A different user's same pluginId is a separate row.
    const stranger = await seedUser();
    const theirs = await plugins.upsert(db, {
      userId: stranger,
      pluginId: "ovid/emoji",
      version: "1.1.0",
      source: { kind: "npm", spec: "ovid-emoji@1.1.0" },
      status: "installing",
    });
    expect(theirs.id).not.toBe(first.id);

    // get / getByPluginId / list / setStatus / remove, ownership-scoped.
    expect(await plugins.get(db, first.id, uid)).toEqual(second);
    expect(await plugins.get(db, first.id, stranger)).toBeNull();
    expect((await plugins.getByPluginId(db, uid, "ovid/emoji"))!.id).toBe(first.id);
    expect(await plugins.getByPluginId(db, stranger, "nope")).toBeNull();
    expect(await plugins.list(db, uid)).toHaveLength(1);

    await plugins.setStatus(db, first.id, uid, "degraded", {
      probeFailures: [{ at: 1_700_000_000_000, error: "probe timeout" }],
    });
    const degraded = await plugins.get(db, first.id, uid);
    expect(degraded!.status).toBe("degraded");
    expect(degraded!.probeFailures).toEqual([{ at: 1_700_000_000_000, error: "probe timeout" }]);

    // setStatus with wrong uid → row untouched.
    await plugins.setStatus(db, first.id, stranger, "failed");
    expect((await plugins.get(db, first.id, uid))!.status).toBe("degraded");

    expect(await plugins.remove(db, first.id, stranger)).toBe(false);
    expect(await plugins.get(db, first.id, uid)).not.toBeNull();
    expect(await plugins.remove(db, first.id, uid)).toBe(true);
    expect(await plugins.get(db, first.id, uid)).toBeNull();
  });

  it("pluginGrants.put upserts capabilities; get/remove ownership-scoped", async () => {
    const uid = await seedUser();
    const stranger = await seedUser();

    await pluginGrants.put(db, {
      userId: uid,
      pluginId: "ovid/emoji",
      capabilities: ["fs:read", "net:fetch"],
      envNames: ["EMOJI_API_KEY"],
      manifestDigest: "sha256:" + "a".repeat(64),
      allowDependencyScripts: false,
    });
    let grant = await pluginGrants.get(db, uid, "ovid/emoji");
    expect(grant!.capabilities).toEqual(["fs:read", "net:fetch"]);
    expect(grant!.envNames).toEqual(["EMOJI_API_KEY"]);
    expect(grant!.manifestDigest).toBe("sha256:" + "a".repeat(64));
    expect(grant!.allowDependencyScripts).toBe(false);
    expect(grant!.grantedAt).toBeInstanceOf(Date);

    // put again = upsert: capabilities replaced, grantedAt refreshed.
    await pluginGrants.put(db, {
      userId: uid,
      pluginId: "ovid/emoji",
      capabilities: ["fs:read"],
      envNames: [],
      manifestDigest: "sha256:" + "b".repeat(64),
      allowDependencyScripts: true,
    });
    grant = await pluginGrants.get(db, uid, "ovid/emoji");
    expect(grant!.capabilities).toEqual(["fs:read"]);
    expect(grant!.envNames).toEqual([]);
    expect(grant!.allowDependencyScripts).toBe(true);

    // Ownership scoping.
    expect(await pluginGrants.get(db, stranger, "ovid/emoji")).toBeNull();
    await pluginGrants.remove(db, stranger, "ovid/emoji");
    expect(await pluginGrants.get(db, uid, "ovid/emoji")).not.toBeNull();
    await pluginGrants.remove(db, uid, "ovid/emoji");
    expect(await pluginGrants.get(db, uid, "ovid/emoji")).toBeNull();
  });

  it("users.getTier: missing row → 'free'; tier 'pro' round-trips", async () => {
    const missing = testUid("ghost");
    expect(await usersRepo.getTier(db, missing)).toBe("free");

    const uid = await seedUser();
    expect(await usersRepo.getTier(db, uid)).toBe("free"); // column default
    await db.update(users).set({ tier: "pro" }).where(eq(users.uid, uid));
    expect(await usersRepo.getTier(db, uid)).toBe("pro");
  });
});
