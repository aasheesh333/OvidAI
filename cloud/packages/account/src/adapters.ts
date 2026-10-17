/**
 * Production cleanup adapters — the port of `server/account/adapters.py`
 * (Firebase Admin) plus the cloud equivalents of the gateway/SQL/Redis cleanup
 * steps. No credentials or environment reads happen at import time.
 */

import { getAppCheck, type AppCheck } from "firebase-admin/app-check";
import { getAuth, type Auth, type DecodedIdToken } from "firebase-admin/auth";
import type { App } from "firebase-admin/app";
import type { Db } from "@ovid/db";
import type { Redis } from "ioredis";
import {
  AccountError,
  identity,
  type AdminAdapter,
  type Claims,
  type CleanupContext,
  type CleanupStep,
  type DataAdapter,
} from "./domain.js";

// ---------------------------------------------------------------------------
// Firebase Admin
// ---------------------------------------------------------------------------

export interface FirebaseAdminOverrides {
  auth?: Pick<Auth, "verifyIdToken" | "getUser" | "updateUser" | "deleteUser">;
  appCheck?: Pick<AppCheck, "verifyToken">;
}

export type FirebaseAdminAdapter = AdminAdapter & {
  verify(
    token: string,
    attestation: string,
    opts?: { allowDisabled?: boolean },
  ): Promise<Claims>;
};

function authErrorCode(err: unknown): string | null {
  if (typeof err === "object" && err !== null && "code" in err) {
    const code = (err as { code?: unknown }).code;
    return typeof code === "string" ? code : null;
  }
  return null;
}

/**
 * Firebase Admin adapter with the disabled-token recovery path: a cancel (or
 * status) token for a worker-disabled account is accepted ONLY with
 * `allowDisabled`, still checks revocation, and is marked
 * `_account_disabled` so the lifecycle can confine it to recovery.
 */
export function createFirebaseAdmin(
  app: App,
  allowedAppIds: Set<string>,
  overrides: FirebaseAdminOverrides = {},
): FirebaseAdminAdapter {
  if (allowedAppIds.size === 0) {
    throw new Error("App Check app ID allowlist is required");
  }
  let services: { auth: Auth | FirebaseAdminOverrides["auth"]; appCheck: AppCheck | FirebaseAdminOverrides["appCheck"] } | null =
    null;
  const svc = () => {
    services ??= {
      auth: overrides.auth ?? getAuth(app),
      appCheck: overrides.appCheck ?? getAppCheck(app),
    };
    return services as {
      auth: NonNullable<FirebaseAdminOverrides["auth"]>;
      appCheck: NonNullable<FirebaseAdminOverrides["appCheck"]>;
    };
  };

  return {
    async verify(token, attestation, opts = {}) {
      try {
        const check = await svc().appCheck.verifyToken(attestation);
        // firebase-admin v14 returns `appId`; the decoded token shape (and
        // Python's SDK) spells it `app_id` — accept both structurally.
        const appId =
          (check as { appId?: unknown }).appId ??
          (check as { app_id?: unknown }).app_id;
        if (typeof appId !== "string" || !allowedAppIds.has(appId)) {
          throw new AccountError("invalid_attestation", 401);
        }
        let claims: DecodedIdToken;
        try {
          claims = await svc().auth.verifyIdToken(token, true);
        } catch (err) {
          if (authErrorCode(err) !== "auth/user-disabled") throw err;
          if (opts.allowDisabled !== true) throw err;
          claims = await svc().auth.verifyIdToken(token, false);
          const user = await svc().auth.getUser(claims.uid);
          const validAfterMs =
            user.tokensValidAfterTime === undefined
              ? 0
              : Date.parse(user.tokensValidAfterTime);
          if (Number.isFinite(validAfterMs) && (claims.auth_time ?? 0) * 1000 < validAfterMs) {
            throw new AccountError("revoked_token", 401);
          }
          (claims as unknown as Record<string, unknown>)._account_disabled = true;
        }
        // Verify legacy credentials, but let the lifecycle authorize only
        // existing deletion recovery. Ordinary access rejects password.
        identity(claims as unknown as Claims, { allowLegacyPassword: true });
        return claims as unknown as Claims;
      } catch (err) {
        if (err instanceof AccountError) throw err;
        throw new AccountError("invalid_authentication", 401);
      }
    },

    async user(uid) {
      try {
        const user = await svc().auth.getUser(uid);
        const parsed =
          user.metadata?.lastSignInTime !== undefined
            ? Date.parse(user.metadata.lastSignInTime)
            : 0;
        return {
          disabled: user.disabled,
          last_login_ms: Number.isFinite(parsed) ? parsed : 0,
        };
      } catch (err) {
        if (authErrorCode(err) === "auth/user-not-found") return null;
        throw err;
      }
    },

    async disable(uid) {
      await svc().auth.updateUser(uid, { disabled: true });
    },

    async enable(uid) {
      await svc().auth.updateUser(uid, { disabled: false });
    },

    async delete(uid) {
      try {
        await svc().auth.deleteUser(uid);
      } catch (err) {
        if (authErrorCode(err) !== "auth/user-not-found") throw err;
      }
    },
  };
}

// ---------------------------------------------------------------------------
// LiteLLM key admin (the two calls the cleanup needs)
// ---------------------------------------------------------------------------

export interface KeyAdmin {
  /** POST /key/block {key} — returns the HTTP status (0 = network failure). */
  keyBlock(key: string): Promise<number>;
  /** POST /key/delete {keys} — returns the HTTP status (0 = network failure). */
  keyDelete(keys: string[]): Promise<number>;
}

/** mint.py pins a 20 s LiteLLM admin timeout; a hung delete must not pin a uid. */
const KEY_ADMIN_TIMEOUT_MS = 20_000;

export function createHttpKeyAdmin(
  baseUrl: string,
  masterKey: string,
  fetchImpl: typeof fetch = fetch,
): KeyAdmin {
  const post = async (path: string, body: Record<string, unknown>): Promise<number> => {
    try {
      const res = await fetchImpl(new URL(path, baseUrl), {
        method: "POST",
        headers: {
          authorization: `Bearer ${masterKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(KEY_ADMIN_TIMEOUT_MS),
      });
      return res.status;
    } catch {
      return 0;
    }
  };
  return {
    keyBlock: (key) => post("/key/block", { key }),
    keyDelete: (keys) => post("/key/delete", { keys }),
  };
}

// ---------------------------------------------------------------------------
// Cloud cleanup data adapter
// ---------------------------------------------------------------------------

/** R2 prefix deletion seam — P7's storage adapter has no listing primitive. */
export interface R2Deleter {
  deletePrefix(prefix: string): Promise<void>;
}

/** Pins the seam for compositions without an R2 client (no AWS dependency). */
export function createNoopR2Deleter(): R2Deleter {
  return {
    async deletePrefix() {
      /* seam only */
    },
  };
}

export interface AccountDataDeleter {
  deleteAccount(uid: string): Promise<void>;
}

export interface CloudCleanupDeps {
  db: Db;
  /** mint db2: `user:*`, `freecap:*`, `abuse:uid:*`, `mintlock:*`, `usagecache:*`. */
  redisDb2: Redis;
  /** queue redis: `sess:{id}:events` streams. Defaults to redisDb2. */
  redisQueue?: Redis;
  litellm: KeyAdmin;
  r2: R2Deleter;
  images: AccountDataDeleter;
  shares: AccountDataDeleter;
  byok: AccountDataDeleter;
}

export type CloudCleanup = DataAdapter & {
  validateContext(ctx: CleanupContext): void;
};

function ok(status: number): boolean {
  return status >= 200 && status < 300;
}

async function scanKeys(redis: Redis, pattern: string): Promise<string[]> {
  const keys: string[] = [];
  let cursor = "0";
  do {
    const [next, batch] = await redis.scan(cursor, "MATCH", pattern, "COUNT", 100);
    cursor = next;
    keys.push(...batch);
  } while (cursor !== "0");
  return keys;
}

async function deletePattern(redis: Redis, pattern: string): Promise<void> {
  let cursor = "0";
  do {
    const [next, batch] = await redis.scan(cursor, "MATCH", pattern, "COUNT", 100);
    cursor = next;
    if (batch.length > 0) await redis.del(...batch);
  } while (cursor !== "0");
}

async function sremMembers(redis: Redis, pattern: string, member: string): Promise<void> {
  let cursor = "0";
  do {
    const [next, batch] = await redis.scan(cursor, "MATCH", pattern, "COUNT", 100);
    cursor = next;
    for (const key of batch) await redis.srem(key, member);
  } while (cursor !== "0");
}

export function createCloudCleanup(deps: CloudCleanupDeps): CloudCleanup {
  const { db, redisDb2, litellm, r2 } = deps;
  const redisQueue = deps.redisQueue ?? redisDb2;

  async function tableExists(name: string): Promise<boolean> {
    const [row] = await db.$client`SELECT to_regclass(${name}) AS t`;
    return row?.t !== null && row?.t !== undefined;
  }

  const steps: CleanupStep[] = [
    {
      // Delete via LiteLLM as well to evict its key caches. A non-2xx (or a
      // network failure) is NOT evidence of cleanup — never proceed to auth.
      name: "gateway",
      run: async (_uid, ctx) => {
        const tokens = (ctx.tokens as string[] | undefined) ?? [];
        if (tokens.length === 0) return;
        if (!ok(await litellm.keyDelete(tokens))) {
          throw new Error("key delete failed");
        }
      },
    },
    {
      // FK-safe: schedule_runs/schedules, file rows and grants all reference
      // sessions, so they are cleared here too. Each delete is idempotent, and
      // the later named stages re-assert their own scope.
      name: "sessions",
      run: async (uid, ctx) => {
        await db.$client`DELETE FROM schedule_runs WHERE schedule_id IN (SELECT id FROM schedules WHERE user_id = ${uid})`;
        await db.$client`DELETE FROM schedules WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM grants WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM attachments WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM session_event_mirror WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
        await db.$client`DELETE FROM session_agent_state WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
        await db.$client`DELETE FROM messages WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
        await db.$client`DELETE FROM runs WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
        await db.$client`DELETE FROM file_manifests WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM workspace_objects WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM sessions WHERE user_id = ${uid}`;
        const ids = (ctx.session_ids as string[] | undefined) ?? [];
        if (ids.length > 0) {
          await redisQueue.del(...ids.map((id) => `sess:${id}:events`));
        }
      },
    },
    {
      name: "workspaces",
      run: async (uid) => {
        await r2.deletePrefix(`users/${uid}/`);
        await db.$client`DELETE FROM file_manifests WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM workspace_objects WHERE user_id = ${uid}`;
      },
    },
    {
      name: "schedules",
      run: async (uid) => {
        await db.$client`DELETE FROM schedule_runs WHERE schedule_id IN (SELECT id FROM schedules WHERE user_id = ${uid})`;
        await db.$client`DELETE FROM schedules WHERE user_id = ${uid}`;
      },
    },
    {
      name: "browser",
      run: async (uid) => {
        await r2.deletePrefix(`users/${uid}/browser/`);
        // P7 owns the table; older schemas may not have it yet.
        if (await tableExists("browser_states")) {
          await db.$client`DELETE FROM browser_states WHERE user_id = ${uid}`;
        }
      },
    },
    {
      name: "byok",
      run: async (uid) => {
        await deps.byok.deleteAccount(uid);
      },
    },
    {
      name: "images",
      run: async (uid) => {
        await deps.images.deleteAccount(uid);
      },
    },
    {
      name: "shares",
      run: async (uid) => {
        await deps.shares.deleteAccount(uid);
      },
    },
    {
      name: "reports",
      run: async (uid) => {
        await db.$client`DELETE FROM reports WHERE reporter_uid = ${uid}`;
      },
    },
    {
      // All remaining uid-bearing rows, then the users row. Money history
      // (billing_purchases, image_jobs) is deliberately retained/tombstoned by
      // its own stage — never silently erased here.
      name: "sql",
      run: async (uid) => {
        await db.$client`DELETE FROM mcp_oauth_flows WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM mcp_oauth_tokens WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM mcp_servers WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM plugins WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM plugin_grants WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM devices WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM notifications WHERE user_id = ${uid}`;
        await db.$client`DELETE FROM user_plan_overrides WHERE uid = ${uid}`;
        await db.$client`DELETE FROM mint_audit WHERE target->>'uid' = ${uid}`;
        await db.$client`DELETE FROM users WHERE uid = ${uid}`;
      },
    },
    {
      // Shared IP counters (`abuse:ip:*`) are NEVER deleted: they belong to
      // every account behind that address.
      name: "redis",
      run: async (uid) => {
        for (const pattern of [
          `user:${uid}:*`,
          `freecap:${uid}:*`,
          `abuse:uid:${uid}`,
          `mintlock:${uid}`,
          `mintlock:web:${uid}`,
          `usagecache:${uid}`,
        ]) {
          await deletePattern(redisDb2, pattern);
        }
        await redisDb2.srem("ovid:uids", uid);
        await sremMembers(redisDb2, "ipacct:*", uid);
      },
    },
  ];

  return {
    async prepare(uid) {
      // Capture key ownership BEFORE any effect so retries never guess.
      const tokens = new Set<string>();
      for (const key of await scanKeys(redisDb2, `user:${uid}:*keyid`)) {
        const value = await redisDb2.get(key);
        if (typeof value === "string" && value !== "") tokens.add(value);
      }
      const sessions = (await db.$client`
        SELECT id FROM sessions WHERE user_id = ${uid}`) as Array<{ id: string }>;
      return { tokens: [...tokens], session_ids: sessions.map((s) => s.id) };
    },

    validateContext(ctx) {
      const tokens = ctx.tokens;
      const sessionIds = ctx.session_ids;
      if (
        !Array.isArray(tokens) ||
        !tokens.every((t) => typeof t === "string") ||
        !Array.isArray(sessionIds) ||
        !sessionIds.every((s) => typeof s === "string")
      ) {
        throw new Error("invalid cleanup context");
      }
    },

    async revokeKeys(uid, ctx) {
      const tokens = (ctx.tokens as string[] | undefined) ?? [];
      for (const token of tokens) {
        // Block rather than delete key rows first: token-linked spend/log
        // scopes still need those rows. Repeating a block after a crash is
        // harmless.
        if (!ok(await litellm.keyBlock(token))) {
          throw new Error("key block failed");
        }
      }
    },

    deletionSteps() {
      return [...steps];
    },
  };
}
