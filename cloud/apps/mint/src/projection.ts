import { plansRepo, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { pyNumStr } from "@ovid/money";
import { DB2, OVID_UIDS_SET, SCALARS, parseSettings, serializeSettings, validatePlan, type PlanData, type Settings } from "./planMath.js";
import { getSettings, publishSettingsToRedis } from "./settings.js";
import {
  BILLING_REFRESH_GENERATION_KEY,
  currentBillingProjectionGeneration,
  StaleBillingAccountWriteError,
} from "./windows.js";

/**
 * The Redis db2 request-time projection. Postgres is the durable authority
 * (Ruling Q4): every publish here renders Postgres state into the EXACT
 * key-shapes the UNMODIFIED Python hook reads (config:limits,
 * config:base_daily_usd, user:{uid}:tier|dailyUsd|pools|monthlyCapUsd|banned|email,
 * email:{email}, config:model_groups), resyncAtBoot overwrites any db2 value
 * that disagrees with Postgres, and importFromRedisOnce is the one-shot
 * Task-18 migration direction (insert-if-absent, never deletes Redis keys).
 *
 * `user:{uid}:tier_expires_at` (value: the expiry epoch, same TTL) is a NEW
 * key mint owns — the hook never reads it; it exists so the tier self-expires
 * (EXAT expiry + TIER_SKEW_SECONDS) while the durable copy stays greppable.
 */

/** Paid-tier Redis TTL skew past the purchase expiry (plan constant, Task 10 consumes it). */
export const TIER_SKEW_SECONDS = 600;

export interface ReconcileReport {
  rewritten: string[];
  identical: number;
  conflictsResolvedFromPostgres: number;
}

export interface Projection {
  publishSettings(): Promise<void>;
  resyncAtBoot(): Promise<ReconcileReport>;
  publishUserTier(uid: string, tier: string | null, expiresAtEpoch: number | null): Promise<void>;
  publishUserState(uid: string, opts?: { clearBan?: boolean }): Promise<void>;
  publishModelGroups(names: string[]): Promise<void>;
  importFromRedisOnce(): Promise<{ imported: { users: number; plans: boolean; settings: boolean } }>;
}

/** One projected key: value null means the key must NOT exist (DEL). */
interface KeyWrite {
  key: string;
  value: string | null;
  /** SET … EXAT <epoch> — the tier keys' self-expiry. */
  exatEpoch?: number;
}

/**
 * The users-row fields the projection needs. Read via raw SQL that projects
 * timestamptz to EPOCH SECONDS and the ban flag to a boolean — raw postgres.js
 * rows come back with snake_case keys and (under drizzle's client parsers)
 * timestamptz as ambiguous local-time strings, so the SQL itself does the
 * unambiguous conversion.
 */
interface UserStateRow {
  email: string | null;
  tier: string;
  tierExpiresAtEpoch: number | null;
  banned: boolean;
  bannedReason: string | null;
}

export function createProjection(deps: { db: Db; redis: Redis }): Projection {
  const { db, redis } = deps;

  /** users-row read via drizzle's $client (apps must not import drizzle-orm directly). */
  async function readUserRow(uid: string): Promise<UserStateRow | null> {
    const rows = await db.$client`
      SELECT email, tier,
             extract(epoch FROM tier_expires_at)::double precision AS tier_expires_epoch,
             banned_at IS NOT NULL AS banned,
             banned_reason
      FROM users WHERE uid = ${uid}`;
    const raw = rows[0] as
      | {
          email: string | null;
          tier: string;
          tier_expires_epoch: number | null;
          banned: boolean;
          banned_reason: string | null;
        }
      | undefined;
    if (raw === undefined) {
      return null;
    }
    return {
      email: raw.email,
      tier: raw.tier,
      tierExpiresAtEpoch: raw.tier_expires_epoch === null ? null : Math.floor(raw.tier_expires_epoch),
      banned: Boolean(raw.banned),
      bannedReason: raw.banned_reason,
    };
  }

  async function applyKeys(uid: string, writes: KeyWrite[]): Promise<void> {
    const generation = currentBillingProjectionGeneration();
    if (generation === undefined) {
      for (const w of writes) {
        if (w.value === null) {
          await redis.del(w.key);
        } else if (w.exatEpoch !== undefined) {
          await redis.set(w.key, w.value, "EXAT", w.exatEpoch);
        } else {
          await redis.set(w.key, w.value);
        }
      }
      return;
    }

    const script = ["if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end"];
    const args = [String(generation)];
    writes.forEach((write, index) => {
      const keyIndex = index + 2;
      if (write.value === null) {
        script.push(`redis.call('DEL', KEYS[${keyIndex}])`);
        return;
      }
      args.push(write.value);
      const valueIndex = args.length;
      if (write.exatEpoch !== undefined) {
        args.push(String(write.exatEpoch));
        script.push(
          `redis.call('SET', KEYS[${keyIndex}], ARGV[${valueIndex}], 'EXAT', ARGV[${args.length}])`,
        );
      } else {
        script.push(`redis.call('SET', KEYS[${keyIndex}], ARGV[${valueIndex}])`);
      }
    });
    const result = await redis.eval(
      script.join("\n") + "\nreturn 1",
      writes.length + 1,
      BILLING_REFRESH_GENERATION_KEY(uid),
      ...writes.map((write) => write.key),
      ...args,
    );
    if (Number(result) !== 1) throw new StaleBillingAccountWriteError();
  }

  /**
   * The tier key pair. Paid tier: SET user:{uid}:tier (+
   * user:{uid}:tier_expires_at = the expiry epoch) EXAT expiry+600; a paid
   * tier with no expiry is a plain SET; tier null/free (or blank) deletes
   * both keys — a free user is free by ABSENCE, like Python.
   */
  function tierKeys(uid: string, tier: string | null, expiresAtEpoch: number | null): KeyWrite[] {
    const paid = tier !== null && tier !== "" && tier !== "free";
    if (!paid) {
      return [
        { key: `user:${uid}:tier`, value: null },
        { key: `user:${uid}:tier_expires_at`, value: null },
      ];
    }
    const writes: KeyWrite[] = [{ key: `user:${uid}:tier`, value: tier }];
    if (expiresAtEpoch !== null && expiresAtEpoch !== undefined) {
      const exat = Math.floor(expiresAtEpoch) + TIER_SKEW_SECONDS;
      writes[0]!.exatEpoch = exat;
      writes.push({
        key: `user:${uid}:tier_expires_at`,
        value: String(Math.floor(expiresAtEpoch)),
        exatEpoch: exat,
      });
    } else {
      writes.push({ key: `user:${uid}:tier_expires_at`, value: null });
    }
    return writes;
  }

  /**
   * The per-user state keys from the Postgres override + users row.
   *
   * BAN PRESERVATION (I2): when Postgres says "not banned" but Redis already
   * carries a ban flag this projection did not derive from Postgres (an
   * "auto" ban written by recordStrike while the DB write was in flight/failed,
   * or a Redis-only ban imported from the Python install), the key is
   * deliberately OMITTED instead of written as null. Writing null here is the
   * bug that let an unrelated /admin/user/update silently unban an auto-banned
   * account. An explicit admin unban deletes the key itself.
   */
  function desiredUserStateKeys(
    uid: string,
    row: UserStateRow | null,
    override: { dailyUsd: string | null; monthlyCapUsd: string | null; pools: Record<string, unknown> | null } | null,
    currentBanned: string | null,
    clearBan = false,
  ): KeyWrite[] {
    const keys: KeyWrite[] = [
      { key: `user:${uid}:dailyUsd`, value: override?.dailyUsd ?? null },
      { key: `user:${uid}:monthlyCapUsd`, value: override?.monthlyCapUsd ?? null },
      { key: `user:${uid}:pools`, value: override?.pools != null ? JSON.stringify(override.pools) : null },
      { key: `user:${uid}:email`, value: row?.email ?? null },
    ];
    const banned = row?.banned ? (row.bannedReason ?? "admin") : null;
    // Preserve a Redis-only ban: Postgres has not derived it (yet), so this
    // projection must not be the thing that removes it. An explicit admin
    // unban passes clearBan to override the preservation.
    if (clearBan || !(banned === null && currentBanned !== null && currentBanned !== "")) {
      keys.push({ key: `user:${uid}:banned`, value: banned });
    }
    if (row?.email != null) {
      keys.push({ key: `email:${row.email}`, value: uid });
    }
    return keys;
  }

  async function publishSettings(): Promise<void> {
    const s = await getSettings({ db });
    await publishSettingsToRedis(redis, s);
  }

  async function publishUserTier(
    uid: string,
    tier: string | null,
    expiresAtEpoch: number | null,
  ): Promise<void> {
    await applyKeys(uid, tierKeys(uid, tier, expiresAtEpoch));
  }

  async function publishUserState(
    uid: string,
    opts: { clearBan?: boolean } = {},
  ): Promise<void> {
    const [row, override, currentBanned, previousEmail] = await Promise.all([
      readUserRow(uid),
      plansRepo.getOverride(db, uid),
      redis.get(`user:${uid}:banned`),
      redis.get(`user:${uid}:email`),
    ]);
    const writes = desiredUserStateKeys(uid, row, override, currentBanned, opts.clearBan ?? false);
    // Include reverse-email cleanup in the same generation-checked Lua write.
    if (row?.email == null && previousEmail !== null && previousEmail !== "") {
      writes.push({ key: `email:${previousEmail}`, value: null });
    }
    await applyKeys(uid, writes);
  }

  async function resyncAtBoot(): Promise<ReconcileReport> {
    const report: ReconcileReport = { rewritten: [], identical: 0, conflictsResolvedFromPostgres: 0 };

    // settings — field-level compare, then full re-publish (Q4: Postgres wins)
    const s = await getSettings({ db });
    const { baseDaily, fields } = serializeSettings(s);
    const hash = await redis.hgetall(DB2.LIMITS_HASH);
    for (const [key, value] of Object.entries(fields)) {
      if (hash[key] === value) {
        report.identical++;
      } else {
        report.rewritten.push(`config:limits.${key}`);
        report.conflictsResolvedFromPostgres++;
      }
    }
    if ((await redis.get(DB2.BASE_BUDGET_KEY)) === baseDaily) {
      report.identical++;
    } else {
      report.rewritten.push(DB2.BASE_BUDGET_KEY);
      report.conflictsResolvedFromPostgres++;
    }
    await publishSettingsToRedis(redis, s);

    // users — full re-publish of tier + state for every MINT-PROVISIONED user
    // (I4: chat-only gateway rows are not mint users), counting every db2 key
    // that disagreed before Postgres overwrote it
    const uids = await plansRepo.mintUids(db);
    for (const uid of uids) {
      const [row, override, currentBanned] = await Promise.all([
        readUserRow(uid),
        plansRepo.getOverride(db, uid),
        redis.get(`user:${uid}:banned`),
      ]);
      const writes = [
        ...tierKeys(uid, row?.tier ?? null, row?.tierExpiresAtEpoch ?? null),
        ...desiredUserStateKeys(uid, row, override, currentBanned),
      ];
      for (const w of writes) {
        const current = await redis.get(w.key);
        if ((w.value === null && current === null) || (w.value !== null && current === w.value)) {
          report.identical++;
        } else {
          report.rewritten.push(w.key);
          report.conflictsResolvedFromPostgres++;
        }
      }
      await applyKeys(uid, writes);
    }
    return report;
  }

  /**
   * SET config:model_groups = sorted JSON array — only when changed (Python
   * catalog_for's `if rds.get(...) != blob` guard). An empty catalog is never
   * published: a transient LiteLLM outage must not wipe the hook's known-set.
   */
  async function publishModelGroups(names: string[]): Promise<void> {
    if (names.length === 0) {
      return;
    }
    const blob = JSON.stringify([...names].sort());
    if ((await redis.get(DB2.MODEL_GROUPS_KEY)) !== blob) {
      await redis.set(DB2.MODEL_GROUPS_KEY, blob);
    }
  }

  /**
   * ONE-SHOT seeding mode (Task 18 migration): reads live db2 into Postgres
   * for rows that don't exist yet — settings singleton, plan rows, users (the
   * ovid:uids registry + their tier/email/banned/override keys). NEVER
   * deletes or rewrites Redis keys, and never overwrites an existing Postgres
   * row (insert-if-absent only).
   */
  async function importFromRedisOnce(): Promise<{
    imported: { users: number; plans: boolean; settings: boolean };
  }> {
    const hash = await redis.hgetall(DB2.LIMITS_HASH);
    const base = await redis.get(DB2.BASE_BUDGET_KEY);

    // settings singleton — only when Postgres has none and db2 has something
    const existingSettings = await plansRepo.getSettings(db);
    let settingsImported = false;
    if (existingSettings === null && (Object.keys(hash).length > 0 || base !== null)) {
      const s = parseSettings(hash, base);
      await plansRepo.saveSettings(db, {
        baseDailyUsd: pyNumStr(s.free_daily_usd),
        scalars: scalarsRecord(s),
        autoOssMembers: s.auto_oss_members,
      });
      settingsImported = true;
    }

    // plan rows for ids not present yet (corrupt entries are skipped)
    const existingPlans = await plansRepo.list(db);
    const known = new Set(existingPlans.map((r) => r.id));
    const nextPosition = existingPlans.reduce((m, r) => Math.max(m, r.position), -1) + 1;
    let plansImported = false;
    let index = 0;
    for (const entry of parseJsonArray(hash.plans)) {
      const plan = tryValidatePlan(entry);
      if (plan === null || known.has(plan.id)) {
        continue;
      }
      await plansRepo.upsert(db, {
        id: plan.id,
        name: plan.name,
        priceUsd: String(plan.price_usd),
        enabled: plan.enabled,
        aliases: plan.aliases,
        windowHours: Math.trunc(plan.window_hours),
        mult: String(plan.mult),
        slowMode: plan.slow_mode,
        autoOss: plan.auto_oss,
        position: nextPosition + index++,
      });
      known.add(plan.id);
      plansImported = true;
    }

    // users from the Python registry — INSERT … ON CONFLICT DO NOTHING
    const uids = await redis.smembers(OVID_UIDS_SET);
    let usersImported = 0;
    for (const uid of uids) {
      const [tier, email, banned, tierExpiresRaw] = await Promise.all([
        redis.get(`user:${uid}:tier`),
        redis.get(`user:${uid}:email`),
        redis.get(`user:${uid}:banned`),
        redis.get(`user:${uid}:tier_expires_at`),
      ]);
      const tierExpires = Number(tierExpiresRaw);
      const tierExpiresAt =
        tierExpiresRaw !== null && Number.isFinite(tierExpires)
          ? new Date(tierExpires * 1000).toISOString() // raw templates bind ISO strings (not Date)
          : null;
      // bannedAt time is not in Redis — the import moment is the best bound
      const inserted = await db.$client`
        INSERT INTO users (uid, email, tier, tier_expires_at, banned_at, banned_reason, mint_provisioned)
        VALUES (${uid}, ${email ?? null}, ${tier || "free"}, ${tierExpiresAt},
                ${banned !== null ? new Date().toISOString() : null}, ${banned ?? null}, true)
        ON CONFLICT (uid) DO NOTHING
        RETURNING uid`;
      if (inserted.length === 0) {
        // The row already exists (e.g. the gateway created it for chat): it is
        // still in ovid:uids, so adopt it into the mint-provisioned set.
        await plansRepo.markProvisioned(db, uid);
        continue;
      }
      usersImported++;
      // overrides — read only for freshly imported users (insert-if-absent)
      const [dailyUsd, monthlyCapUsd, poolsRaw] = await Promise.all([
        redis.get(`user:${uid}:dailyUsd`),
        redis.get(`user:${uid}:monthlyCapUsd`),
        redis.get(`user:${uid}:pools`),
      ]);
      const pools = poolsRaw !== null ? parseJsonObject(poolsRaw) : null;
      if (dailyUsd !== null || monthlyCapUsd !== null || pools !== null) {
        await plansRepo.saveOverride(db, uid, {
          dailyUsd,
          monthlyCapUsd,
          pools: pools as { mult?: number | null; window_hours?: number | null; slow_mode?: boolean | null; auto_oss?: boolean | null } | null,
        });
      }
    }

    return { imported: { users: usersImported, plans: plansImported, settings: settingsImported } };
  }

  function scalarsRecord(s: Settings): Record<string, number> {
    const rec: Record<string, number> = {};
    for (const name of Object.keys(SCALARS)) {
      rec[name] = (s as unknown as Record<string, number>)[name]!;
    }
    return rec;
  }

  function parseJsonArray(raw: string | undefined | null): unknown[] {
    if (raw == null || raw === "") {
      return [];
    }
    try {
      const v = JSON.parse(raw);
      return Array.isArray(v) ? v : [];
    } catch {
      return [];
    }
  }

  function parseJsonObject(raw: string): Record<string, unknown> | null {
    try {
      const v = JSON.parse(raw);
      return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
    } catch {
      return null;
    }
  }

  function tryValidatePlan(entry: unknown): PlanData | null {
    try {
      return validatePlan(entry);
    } catch {
      return null;
    }
  }

  return {
    publishSettings,
    resyncAtBoot,
    publishUserTier,
    publishUserState,
    publishModelGroups,
    importFromRedisOnce,
  };
}
