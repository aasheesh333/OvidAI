import { spawnSync } from "node:child_process";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";
import { Redis } from "ioredis";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createDb,
  migrate,
  sessions as sessionsRepo,
  users as usersRepo,
  type Db,
} from "@ovid/db";
import {
  buildMintApps,
  createBillingService,
  createLiteLlmAdmin,
  createProjection,
  findPlan,
  getSettings,
  HttpContractError,
  loadMintEnv,
  reapplyUser,
  type BillingService,
  type MintDeps,
  type MintEnv,
  type MintIdentityVerifier,
} from "@ovid/mint";
import {
  buildGateway,
  createInternalMintProvisioner,
  createTestVerifier,
  createTicketStore,
} from "@ovid/gateway";
import { createRedisEventLog, createRedisSystemBus } from "@ovid/events";
import type { QueueServices } from "@ovid/queue";
import type { KeyProvider } from "@ovid/shared";
import {
  cleanupHookContract,
  seedHookContract,
  type HookContractSeed,
} from "../hook-contract/seed.js";

/**
 * P9 Task 17 — the money path end to end.
 *
 * Two proofs in one file:
 *
 *  1. The TypeScript mint/billing/gateway path composed against REAL Postgres
 *     and REAL Redis, with only the two outer boundaries mocked: LiteLLM
 *     admin+proxy (a local http server) and Google Play (an injected fake).
 *     Pinned flows: POST /mint -> key+tier; hook-written spend -> /usage
 *     remaining_fraction; /billing/verify -> Redis tier EXAT + Postgres tier +
 *     captured /key/update budget; free-cap -> gateway 402 relay; admin ban ->
 *     /key/block captured + /mint 403.
 *
 *  2. The REAL, UNMODIFIED Python hook (server/mint/litellm_hook/ovid_pools.py)
 *     running against the state TypeScript wrote (hook-contract/seed.ts), with
 *     the six contracts pinned in test_hook_contract.py. The wrapper asserts
 *     pytest actually EXECUTED tests; it skips loudly (never silently) when
 *     python3 or pytest/redis-py are unavailable.
 *
 * Services: disposable Postgres (TEST_DATABASE_URL, e.g. ovid_mint_t17) and
 * Redis (TEST_MINT_REDIS_URL, db 9). The suite never FLUSHDBs db 9: it only
 * deletes the uids it created (plus the hook harness's restored config keys).
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_MINT_REDIS_URL = process.env.TEST_MINT_REDIS_URL;
const HOOK_CONTRACT_REDIS_URL =
  process.env.HOOK_CONTRACT_REDIS_URL ?? TEST_MINT_REDIS_URL;

const MASTER_KEY = "sk-litellm-master-t17";
const ADMIN_KEY = "sk-admin-t17";
const INTERNAL_SECRET = "sk-internal-t17-secret-0123456789abcdef";
const PACKAGE_NAME = "com.dhanuk.ovidai";
const PRODUCT_ID = "ovid_plus_monthly"; // -> tier "3x"

const REPO_ROOT = fileURLToPath(new URL("../../../../", import.meta.url));

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

let uidCounter = 0;
function uniqueUid(prefix: string): string {
  uidCounter += 1;
  return `${prefix}-${Date.now().toString(36)}-${uidCounter}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

let ipCounter = 0;
function uniqueIp(): string {
  ipCounter += 1;
  return `198.51.100.${(ipCounter % 200) + 10}`;
}

interface FakeKey {
  token: string;
  spend: number;
  max_budget: number | null;
  budget_duration: string | null;
  blocked: boolean;
}

interface FakeCall {
  method: string;
  path: string;
  body: Record<string, unknown>;
  params: Record<string, string>;
}

/**
 * Local LiteLLM admin+proxy. Every endpoint mint touches is covered; calls
 * are captured so budget/ban effects can be asserted. NO network.
 */
class FakeLiteLlm {
  readonly keys = new Map<string, FakeKey>();
  readonly users = new Map<string, { spend: number; budget_duration?: string | null; max_budget?: number | null }>();
  readonly calls: FakeCall[] = [];
  readonly models: Array<{
    model_name: string;
    litellm_params: { model: string };
    model_info: Record<string, unknown>;
  }> = [];
  baseUrl = "";
  private server: Server | undefined;
  private counter = 0;

  async start(): Promise<string> {
    this.server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on("data", (chunk: Buffer) => chunks.push(chunk));
      req.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let body: Record<string, unknown> = {};
        try {
          const parsed: unknown = JSON.parse(text);
          if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
            body = parsed as Record<string, unknown>;
          }
        } catch {
          // keep {}
        }
        this.handle(req, res, body);
      });
    });
    await new Promise<void>((resolve) => this.server!.listen(0, "127.0.0.1", resolve));
    const { port } = this.server.address() as AddressInfo;
    this.baseUrl = `http://127.0.0.1:${port}`;
    this.addStandardModels();
    return this.baseUrl;
  }

  async stop(): Promise<void> {
    if (this.server === undefined) return;
    const server = this.server;
    this.server = undefined;
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  addModel(name: string, under: string, inp?: number, out?: number, perImage?: number, mode?: string): void {
    const info: Record<string, unknown> = { id: `dep-${this.models.length}` };
    if (inp !== undefined) info.input_cost_per_token = inp;
    if (out !== undefined) info.output_cost_per_token = out;
    if (perImage !== undefined) info.output_cost_per_image = perImage;
    if (mode !== undefined) info.mode = mode;
    this.models.push({ model_name: name, litellm_params: { model: under }, model_info: info });
  }

  private addStandardModels(): void {
    const prices: Record<string, [number, number]> = {
      "deepseek-v4.1-flash": [1e-7, 4e-7],
      "glm-5.3-flash": [2e-7, 8e-7],
      "gemini-3.7-flash": [1.5e-7, 6e-7],
      "gemini-3.8-flash": [3e-7, 2.5e-6],
      "minimax-m3": [2e-7, 1e-6],
      "gpt-5.6-luna": [2.5e-7, 2e-6],
    };
    for (const [name, [inp, out]] of Object.entries(prices)) {
      this.addModel(name, `prov/${name}`, inp, out, undefined, "chat");
      this.addModel("auto", `prov/${name}`, inp, out, undefined, "chat");
    }
    this.addModel("ovid-image", "prov/img-1", undefined, undefined, 0.04, "image_generation");
  }

  posts(path: string): Record<string, unknown>[] {
    return this.calls.filter((c) => c.method === "POST" && c.path === path).map((c) => c.body);
  }

  private handle(req: IncomingMessage, res: ServerResponse, body: Record<string, unknown>): void {
    if (req.headers.authorization !== `Bearer ${MASTER_KEY}`) {
      json(res, 401, { error: "auth" });
      return;
    }
    const url = new URL(req.url ?? "/", "http://fake");
    const path = url.pathname;
    const params: Record<string, string> = {};
    for (const [k, v] of url.searchParams) params[k] = v;
    this.calls.push({ method: req.method ?? "", path, body, params });

    if (path === "/key/info") {
      const info = this.keys.get(params.key ?? "");
      json(res, info === undefined ? 404 : 200, info === undefined ? { error: "nf" } : { key: params.key, info });
      return;
    }
    if (path === "/key/update") {
      const info = this.keys.get(String(body.key ?? ""));
      if (info === undefined) {
        json(res, 404, {});
        return;
      }
      for (const field of ["max_budget", "budget_duration", "spend"] as const) {
        if (field in body) {
          (info as unknown as Record<string, unknown>)[field] = body[field];
        }
      }
      json(res, 200, info);
      return;
    }
    if (path === "/key/block" || path === "/key/unblock") {
      const info = this.keys.get(String(body.key ?? ""));
      if (info !== undefined) info.blocked = path === "/key/block";
      json(res, 200, {});
      return;
    }
    if (path === "/key/delete") {
      const keys = Array.isArray(body.keys) ? (body.keys as string[]) : [];
      for (const key of keys) this.keys.delete(key);
      json(res, 200, {});
      return;
    }
    if (path === "/key/generate") {
      this.counter += 1;
      const token = `hashed-${this.counter}`;
      this.keys.set(token, {
        token,
        spend: 0,
        max_budget: (body.max_budget as number | undefined) ?? null,
        budget_duration: (body.budget_duration as string | undefined) ?? null,
        blocked: false,
      });
      json(res, 200, { key: `sk-live-${this.counter}`, token });
      return;
    }
    if (path === "/user/info") {
      const user = this.users.get(params.user_id ?? "");
      json(res, user === undefined ? 404 : 200, user === undefined ? {} : { user_info: user });
      return;
    }
    if (path === "/user/update") {
      const uid = String(body.user_id ?? "");
      const user = this.users.get(uid) ?? { spend: 0 };
      for (const field of ["max_budget", "budget_duration", "spend"] as const) {
        if (field in body) (user as unknown as Record<string, unknown>)[field] = body[field];
      }
      this.users.set(uid, user);
      json(res, 200, user);
      return;
    }
    if (path === "/model/info") {
      json(res, 200, { data: this.models });
      return;
    }
    if (path === "/spend/logs") {
      json(res, 200, []);
      return;
    }
    if (path === "/team/new" || path === "/team/update") {
      json(res, 200, { team_id: "team-web" });
      return;
    }
    json(res, 404, { error: path });
  }
}

function json(res: ServerResponse, status: number, payload: unknown): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload));
}

class FakePlay {
  readonly tokens = new Map<string, unknown>();
  async getSubscription(token: string): Promise<unknown> {
    const resource = this.tokens.get(token);
    if (resource === undefined) throw new Error("unknown token");
    return resource;
  }
}

function authHeaders(uid: string, appCheck = "attest"): Record<string, string> {
  return {
    authorization: `Bearer test:${uid}`,
    "x-firebase-appcheck": appCheck,
    "x-forwarded-for": uniqueIp(),
    "content-type": "application/json",
  };
}

async function post(
  baseUrl: string,
  path: string,
  body: unknown,
  headers: Record<string, string>,
): Promise<{ status: number; body: any; headers: Record<string, string> }> {
  const res = await fetch(`${baseUrl}${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let parsed: any = text;
  try {
    parsed = JSON.parse(text);
  } catch {
    // raw text body
  }
  return {
    status: res.status,
    body: parsed,
    // Lowercased plain record — assertable like light-my-request headers.
    headers: Object.fromEntries(res.headers.entries()),
  };
}

describe.skipIf(!TEST_DATABASE_URL || !TEST_MINT_REDIS_URL)(
  "P9 money path e2e (TS mint/billing/gateway + real Python hook)",
  () => {
    let db: Db;
    let redis: Redis;
    let fake: FakeLiteLlm;
    let play: FakePlay;
    let env: MintEnv;
    let deps: MintDeps;
    let billing: BillingService;
    let publicApp: ReturnType<typeof buildMintApps>["publicApp"];
    let adminApp: ReturnType<typeof buildMintApps>["adminApp"];
    let mintBase = "";
    let adminBase = "";
    let gateway: ReturnType<typeof buildGateway> | undefined;
    let gatewayBase = "";
    const createdUids: string[] = [];

    const verifyIdentity: MintIdentityVerifier = async ({ authorization }) => {
      const match = /^bearer\s+test:(\S+)$/i.exec(authorization);
      if (match === null) throw new HttpContractError(401, "invalid test token");
      return { uid: match[1]!, email: null, platform: "android" };
    };

    beforeAll(async () => {
      // Isolated schema: drop + migrate (same discipline as mint's test/env.ts).
      const admin = createDb(TEST_DATABASE_URL!);
      try {
        await admin.$client.unsafe(
          `SET client_min_messages = warning;` +
            ` DROP SCHEMA IF EXISTS drizzle CASCADE;` +
            ` DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE;` +
            ` DROP TABLE IF EXISTS schedules, schedule_runs, devices, notifications, grants, file_manifests, workspace_objects, attachments, session_event_mirror, session_agent_state, runs, messages, sessions, users,` +
            ` plans, mint_settings, user_plan_overrides, mint_audit, billing_purchases, image_jobs,` +
            ` image_deleted_accounts, image_cards, image_card_history, image_probe_log, image_probe_state,` +
            ` shares, share_forks, reports, account_deletions, byok_keys,` +
            ` mcp_servers, mcp_oauth_tokens, mcp_oauth_flows, plugins, plugin_grants, run_usage,` +
            ` private_memory_files, projects CASCADE`,
        );
      } finally {
        await admin.$client.end({ timeout: 5 });
      }
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      redis = new Redis(TEST_MINT_REDIS_URL!);

      fake = new FakeLiteLlm();
      const litellmBase = await fake.start();
      play = new FakePlay();

      env = loadMintEnv({
        NODE_ENV: "test",
        DATABASE_URL: TEST_DATABASE_URL!,
        REDIS_DB2_URL: TEST_MINT_REDIS_URL!,
        LITELLM_BASE: litellmBase,
        LITELLM_MASTER_KEY: MASTER_KEY,
        OVID_ADMIN_MASTER_KEY: ADMIN_KEY,
        OVID_INTERNAL_API_SECRET: INTERNAL_SECRET,
        FIREBASE_PROJECT_ID: "ovid-t17",
        APPCHECK_ENABLED: "false",
        OVID_PLAY_PACKAGE: PACKAGE_NAME,
      });

      const projection = createProjection({ db, redis });
      const litellm = createLiteLlmAdmin(litellmBase, MASTER_KEY);
      deps = {
        db,
        redis,
        litellm,
        env,
        alerter: async () => {},
        verifyIdentity,
      };
      billing = createBillingService({
        db,
        redis,
        env,
        projection,
        reapplyUser: (uid) => reapplyUser(deps, uid),
        api: play,
      });
      deps.billing = billing;

      const apps = buildMintApps(deps);
      publicApp = apps.publicApp;
      adminApp = apps.adminApp;
      await publicApp.listen({ host: "127.0.0.1", port: 0 });
      await adminApp.listen({ host: "127.0.0.1", port: 0 });
      mintBase = `http://127.0.0.1:${(publicApp.server.address() as AddressInfo).port}`;
      adminBase = `http://127.0.0.1:${(adminApp.server.address() as AddressInfo).port}`;
    });

    afterAll(async () => {
      for (const uid of createdUids) {
        await redis.del(
          `user:${uid}:tier`,
          `user:${uid}:tier_expires_at`,
          `user:${uid}:keyid`,
          `user:${uid}:key`,
          `user:${uid}:web:keyid`,
          `user:${uid}:web:key`,
          `user:${uid}:banned`,
          `user:${uid}:email`,
          `pool:${uid}:start`,
          `pool:${uid}:spend`,
          `pool:${uid}:auto`,
          `usagecache:${uid}`,
        );
        await redis.srem("ovid:uids", uid);
      }
      await gateway?.close();
      await publicApp?.close();
      await adminApp?.close();
      await fake?.stop();
      await redis?.quit();
      await db?.$client.end({ timeout: 5 });
    });

    // -----------------------------------------------------------------------
    // POST /mint -> key + tier, then hook-written spend -> /usage
    // -----------------------------------------------------------------------
    it("mint issues one idempotent key and /usage reflects the hook's spend counter", async () => {
      const uid = uniqueUid("t17-mint");
      createdUids.push(uid);

      const first = await post(mintBase, "/mint", {}, authHeaders(uid));
      expect(first.status, JSON.stringify(first.body)).toBe(200);
      expect(typeof first.body.key).toBe("string");
      expect(first.body.key).toMatch(/^sk-live-/);
      expect(first.body.tier).toBe("free");
      expect(first.body.base_url).toBe(env.publicBaseUrl);

      const keyid = await redis.get(`user:${uid}:keyid`);
      expect(keyid).not.toBeNull();
      expect(await redis.get(`user:${uid}:key`)).toBe(first.body.key);

      const rows = (await db.$client`
        SELECT tier, mint_provisioned FROM users WHERE uid = ${uid}`) as Array<{
        tier: string;
        mint_provisioned: boolean;
      }>;
      expect(rows).toHaveLength(1);
      expect(rows[0]).toEqual({ tier: "free", mint_provisioned: true });

      // A second call is idempotent (same key, no second /key/generate).
      const second = await post(mintBase, "/mint", {}, authHeaders(uid));
      expect(second.status).toBe(200);
      expect(second.body.key).toBe(first.body.key);
      expect(fake.posts("/key/generate")).toHaveLength(1);

      // Simulate the Python hook's success accounting: a live window + spend.
      const start = Math.floor(Date.now() / 1000);
      await redis.set(`pool:${uid}:start`, String(start));
      await redis.set(`pool:${uid}:spend`, "0.05");
      await redis.del(`usagecache:${uid}`);

      const usage = await post(mintBase, "/usage", {}, authHeaders(uid));
      expect(usage.status, JSON.stringify(usage.body)).toBe(200);
      // Free allowance $0.15, spent $0.05 -> 2/3 remaining, rounded half-even.
      expect(usage.body.daily_spent_usd).toBe(0.05);
      expect(usage.body.daily_budget_usd).toBe(0.15);
      expect(usage.body.remaining_fraction).toBe(0.6667);
      expect(usage.body.pools[0]).toMatchObject({
        class: "all",
        remaining_fraction: 0.6667,
        slow_mode: false,
      });
      expect(usage.body.tier).toBe("free");
    });

    // -----------------------------------------------------------------------
    // /billing/verify -> Redis EXAT tier + Postgres tier + LiteLLM budget
    // -----------------------------------------------------------------------
    it("billing verify applies a 3x tier durably, self-expiring, and re-applies the key budget", async () => {
      const uid = uniqueUid("t17-billing");
      createdUids.push(uid);

      const minted = await post(mintBase, "/mint", {}, authHeaders(uid));
      expect(minted.status).toBe(200);
      const keyid = (await redis.get(`user:${uid}:keyid`))!;
      expect(keyid).not.toBeNull();

      const expiry = Math.floor(Date.now() / 1000) + 30 * 86400;
      const token = `play-token-${uid}`;
      const { accountHash } = await import("@ovid/mint");
      play.tokens.set(token, {
        subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
        acknowledgementState: "ACKNOWLEDGEMENT_STATE_PENDING",
        lineItems: [
          {
            productId: PRODUCT_ID,
            expiryTime: new Date(expiry * 1000).toISOString(),
            autoRenewingPlan: { autoRenewEnabled: true },
          },
        ],
        externalAccountIdentifiers: { obfuscatedExternalAccountId: accountHash(uid) },
      });

      const verify = await post(
        mintBase,
        "/billing/verify",
        { purchase_token: token, product_id: PRODUCT_ID, package_name: PACKAGE_NAME },
        authHeaders(uid),
      );
      expect(verify.status, JSON.stringify(verify.body)).toBe(200);
      expect(verify.body).toMatchObject({
        ok: true,
        status: "active",
        tier: "3x",
        product_id: PRODUCT_ID,
        auto_renewing: true,
        acknowledge: true,
      });

      // Redis projection: tier "3x" + self-expiry at expiry + 600 s.
      expect(await redis.get(`user:${uid}:tier`)).toBe("3x");
      const pttl = await redis.pttl(`user:${uid}:tier`);
      const expectedPttl = (expiry - Math.floor(Date.now() / 1000)) * 1000 + 600_000;
      expect(pttl).toBeGreaterThan(expectedPttl - 60_000);
      expect(pttl).toBeLessThanOrEqual(expectedPttl + 60_000);
      expect(Number(await redis.get(`user:${uid}:tier_expires_at`))).toBe(expiry);

      // Postgres durable authority: billing tier "3x" resolves to plan "starter".
      const rows = (await db.$client`
        SELECT tier FROM users WHERE uid = ${uid}`) as Array<{ tier: string }>;
      expect(rows[0]!.tier).toBe("3x");
      const settings = await getSettings({ db });
      expect(findPlan(settings, rows[0]!.tier).id).toBe("starter");

      // Enforcement follows: the captured /key/update carries the 3x budget
      // ($0.15 base × mult 3 = $0.45) for the minted key.
      const updates = fake.posts("/key/update").filter((b) => b.key === keyid);
      expect(updates.length).toBeGreaterThan(0);
      expect(updates.at(-1)!.max_budget).toBeCloseTo(0.45, 10);
    });

    // -----------------------------------------------------------------------
    // Free-cap exhausted -> the gateway re-envelopes mint's 402 for the client
    // -----------------------------------------------------------------------
    it("gateway messages re-envelopes mint's free-cap 402 (daily_limit_reached) and leaves no run behind", async () => {
      const uid = uniqueUid("t17-cap");
      createdUids.push(uid);
      await usersRepo.ensure(db, uid, null);
      await sessionsRepo.create(db, uid, "t17 free cap");
      const session = (await db.$client`
        SELECT id FROM sessions WHERE user_id = ${uid} LIMIT 1`) as Array<{ id: string }>;

      // The LiteLLM user budget has consumed the $10 monthly backstop.
      fake.users.set(uid, { spend: 10.0, budget_duration: "30d", max_budget: 10 });

      gateway = buildGateway({
        db,
        queues: {
          agentRuns: { add: async () => ({}) },
        } as unknown as QueueServices,
        verifier: createTestVerifier(),
        tickets: createTicketStore(redis),
        keys: { getKeyForUser: async () => null } as KeyProvider,
        mint: createInternalMintProvisioner(adminBase, INTERNAL_SECRET),
        events: createRedisEventLog(redis),
        system: createRedisSystemBus(redis),
      });
      await gateway.listen({ host: "127.0.0.1", port: 0 });
      gatewayBase = `http://127.0.0.1:${(gateway.server.address() as AddressInfo).port}`;

      const res = await post(
        gatewayBase,
        `/cloud/v1/sessions/${session[0]!.id}/messages`,
        { content: "hello" },
        authHeaders(uid),
      );
      expect(res.status).toBe(402);
      // The mint's FastAPI-parity {"detail":…} is re-enveloped as the
      // ApiError shape the thin client parses (cloud_rest.dart _toError),
      // under the client's own 402 code (cloud_session_store.dart). The
      // mint attaches x-ovid-resets-at only when LiteLLM reports the user
      // budget's clock (user_info.budget_reset_at); this fake user has none,
      // so no header and the client shows no countdown.
      expect(res.body).toEqual({
        error: { code: "daily_limit_reached", message: "monthly free limit reached" },
      });
      expect(res.headers["x-ovid-resets-at"]).toBeUndefined();

      const counts = (await db.$client`
        SELECT
          (SELECT count(*)::int FROM messages WHERE session_id = ${session[0]!.id}) AS messages,
          (SELECT count(*)::int FROM runs WHERE session_id = ${session[0]!.id}) AS runs`) as Array<{
        messages: number;
        runs: number;
      }>;
      expect(counts[0]).toEqual({ messages: 0, runs: 0 });

      await gateway.close();
      gateway = undefined;
    });

    // -----------------------------------------------------------------------
    // Ban -> /key/block captured, /mint 403
    // -----------------------------------------------------------------------
    it("admin ban blocks the live key and /mint answers 403 account suspended", async () => {
      const uid = uniqueUid("t17-ban");
      createdUids.push(uid);

      const minted = await post(mintBase, "/mint", {}, authHeaders(uid));
      expect(minted.status).toBe(200);
      const keyid = (await redis.get(`user:${uid}:keyid`))!;

      const ban = await post(
        adminBase,
        "/admin/ban",
        { uid },
        { authorization: `Bearer ${ADMIN_KEY}`, "content-type": "application/json" },
      );
      expect(ban.status, JSON.stringify(ban.body)).toBe(200);
      expect(ban.body).toEqual({ ok: true });

      expect(await redis.get(`user:${uid}:banned`)).toBe("admin");
      expect(fake.keys.get(keyid)?.blocked).toBe(true);
      expect(
        fake.calls.some(
          (c) => c.method === "POST" && c.path === "/key/block" && c.body.key === keyid,
        ),
      ).toBe(true);

      const denied = await post(mintBase, "/mint", {}, authHeaders(uid));
      expect(denied.status).toBe(403);
      expect(denied.body).toEqual({ detail: "account suspended" });
    });

    // -----------------------------------------------------------------------
    // Internal server-to-server minting (P9 Task 9). Guarded so this suite
    // stays runnable while that lane is unlanded; when present, proves the
    // key is identical across the internal and public paths.
    // -----------------------------------------------------------------------
    it("internal mint (signed server-to-server) returns the same key as /mint", async (ctx) => {
      const workerModule = (await import("@ovid/worker").catch(() => null)) as
        | { createServerKeyResolver?: unknown }
        | null;
      const createResolver = workerModule?.createServerKeyResolver;
      if (typeof createResolver !== "function") {
        console.warn(
          "[money e2e] SKIP internal-mint leg: @ovid/worker exports no createServerKeyResolver " +
            "(P9 Task 9 is not landed in this tree). Reported as blocked; no assertion weakened.",
        );
        ctx.skip();
        return;
      }

      const uid = uniqueUid("t17-internal");
      createdUids.push(uid);

      const resolver = (createResolver as (d: unknown) => {
        resolveForRun(
          uid: string,
          ctx: { unattended: boolean; byokKeyId?: string | null },
        ): Promise<{ kind: string; key?: string } | null>;
      })({
        redisMint: redis,
        internalMint: { baseUrl: adminBase, secret: INTERNAL_SECRET },
        byok: null,
        litellmBaseUrl: fake.baseUrl,
      });

      const resolved = await resolver.resolveForRun(uid, { unattended: true });
      expect(resolved).toMatchObject({ kind: "litellm" });
      const internalKey = resolved!.key!;
      expect(typeof internalKey).toBe("string");

      const publicMint = await post(mintBase, "/mint", {}, authHeaders(uid));
      expect(publicMint.status).toBe(200);
      expect(publicMint.body.key).toBe(internalKey);
    });

    // -----------------------------------------------------------------------
    // The real, unmodified Python hook against TS-written db2 (LAST: it
    // replaces the settings rows with the hook-contract fixture).
    // -----------------------------------------------------------------------
    it("the unmodified Python hook honors the TS projection (executed, not skipped)", async (ctx) => {
      const pythonEnv: NodeJS.ProcessEnv = {
        ...process.env,
        PYTHONDONTWRITEBYTECODE: "1",
      };
      if (process.env.HOOK_CONTRACT_PYTHONPATH) {
        pythonEnv.PYTHONPATH = [
          process.env.HOOK_CONTRACT_PYTHONPATH,
          process.env.PYTHONPATH ?? "",
        ]
          .filter(Boolean)
          .join(":");
      }
      const probe = spawnSync("python3", ["-c", "import pytest, redis.asyncio"], {
        env: pythonEnv,
        encoding: "utf8",
      });
      if (probe.status !== 0) {
        console.warn(
          "[money e2e] SKIP real-Python hook contract: python3 with pytest + redis.asyncio " +
            `is unavailable (${(probe.stderr ?? "").trim().split("\n").at(-1) ?? "unknown error"}). ` +
            "Install them outside the repo (see hook-contract/README.md) to run the proof.",
        );
        ctx.skip();
        return;
      }

      const seed: HookContractSeed = await seedHookContract(redis, db);
      try {
        const run = spawnSync(
          "python3",
          [
            "-m",
            "pytest",
            "cloud/apps/e2e/hook-contract",
            "-q",
            "-p",
            "no:cacheprovider",
          ],
          {
            cwd: REPO_ROOT,
            env: {
              ...pythonEnv,
              HOOK_CONTRACT_REDIS_URL: HOOK_CONTRACT_REDIS_URL!,
              HOOK_CONTRACT_FIXTURE: JSON.stringify(seed.uids),
            },
            encoding: "utf8",
            timeout: 180_000,
          },
        );
        const output = `${run.stdout ?? ""}\n${run.stderr ?? ""}`;
        console.log(`[money e2e] real-Python hook harness:\n${output.trim()}`);
        expect(run.status, `pytest failed:\n${output}`).toBe(0);

        // Prove the tests RAN: no silent all-skipped green.
        const passed = /(\d+) passed/.exec(output);
        expect(passed, `pytest summary missing:\n${output}`).not.toBeNull();
        expect(Number(passed![1])).toBeGreaterThanOrEqual(6);
        expect(output).not.toMatch(/\b\d+ skipped\b/);
      } finally {
        await cleanupHookContract(redis, seed);
      }
    });
  },
);
