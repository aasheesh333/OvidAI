import { Redis } from "ioredis";
import { createDb, migrate, type Db } from "@ovid/db";

export const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
export const TEST_MINT_REDIS_URL = process.env.TEST_MINT_REDIS_URL;

/**
 * Mint-side test env (gateway src/test/db.ts pattern). Two differences from
 * the gateway's helper:
 *  - the drop/recreate discipline IS applied here: the settings/projection
 *    tests assert first-run SEEDING behavior, which needs genuinely empty
 *    money tables (same P8-T3 invariant list as @ovid/db's moneyRepos.test.ts,
 *    which this list is kept in sync with — including the grants table);
 *  - the raw drops run through drizzle's $client (postgres.js `.unsafe`)
 *    because `postgres` is not a direct @ovid/mint dependency.
 *
 * The Redis URL carries the db selector (…/9 — db2 in production, db9 here);
 * the code under test never hardcodes an index.
 */
export async function resetTestDb(): Promise<Db> {
  const url = TEST_DATABASE_URL!;
  const admin = createDb(url);
  try {
    // One simple-protocol batch on ONE pool connection: the leading
    // SET client_min_messages silences the expected DROP NOTICEs ("drop
    // cascades to …") — same discipline as @ovid/db's moneyRepos.test.ts
    // (noise on every run, never actionable; postgres.js binds onnotice at
    // connection creation, which createDb cannot pass, so the session filter
    // does it instead).
    //
    // The drizzle journal, the sandbox-uid sequence and EVERY table any
    // migration creates are dropped so migrate() re-applies from scratch.
    await admin.$client.unsafe(
      `SET client_min_messages = warning;` +
        ` DROP SCHEMA IF EXISTS drizzle CASCADE;` +
        ` DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE;` +
        ` DROP TABLE IF EXISTS grants, file_manifests, workspace_objects, attachments, session_event_mirror, runs, messages, sessions, users,` +
        ` plans, mint_settings, user_plan_overrides, mint_audit, billing_purchases, image_jobs,` +
        ` image_deleted_accounts, image_cards, image_card_history, image_probe_log, image_probe_state,` +
        ` shares, share_forks, reports, account_deletions, byok_keys,` +
        ` mcp_servers, mcp_oauth_tokens, mcp_oauth_flows, plugins, plugin_grants CASCADE`,
    );
  } finally {
    await admin.$client.end({ timeout: 5 });
  }
  await migrate(url);
  return createDb(url);
}

/** A db handle on the migrated schema WITHOUT resetting it (fresh-process read). */
export function openDb(): Db {
  return createDb(TEST_DATABASE_URL!);
}

export async function closeDb(db: Db | undefined): Promise<void> {
  await db?.$client.end({ timeout: 5 });
}

/** Redis on db9, flushed — the db2-projection tests own the whole index. */
export async function openFlushedRedis(): Promise<Redis> {
  const redis = new Redis(TEST_MINT_REDIS_URL!);
  await redis.flushdb();
  return redis;
}

export async function closeRedis(redis: Redis | undefined): Promise<void> {
  await redis?.quit();
}

/** Fresh per-test uid (never collides with other files' data). */
export function testUid(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

/**
 * Inert Redis stand-in for settings.test.ts: that file tests the POSTGRES
 * authority (per its brief); the Redis publish half of storeSettings is
 * projection.test.ts / hookContract.test.ts's subject.
 */
export function inertRedis(): Redis {
  return { set: async () => "OK", hset: async () => 0 } as unknown as Redis;
}
