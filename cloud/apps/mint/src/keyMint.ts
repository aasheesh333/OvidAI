import { plansRepo } from "@ovid/db";
import { pyNumStr } from "@ovid/money";
import { checkNewKeyBreaker } from "./antiAbuse.js";
import type { MintDeps } from "./app.js";
import { HttpContractError } from "./app.js";
import { catalogFor } from "./catalog.js";
import { OVID_UIDS_SET } from "./planMath.js";
import { parseTime } from "./usage.js";
import {
  ensureUserBudget,
  poolRateLimits,
  poolUserKeyIds,
  tierBudget,
} from "./windows.js";

/**
 * keyMint.ts — the port of mint.py's litellm_mint_or_get. One Google account
 * gets EXACTLY one key per platform (android "" / web "web:"); re-calling
 * returns the same key and never creates a second one.
 *
 * The Redis shapes are a HARD contract with windows.ts/usage.ts and the
 * unmodified Python hook:
 *   user:{uid}:keyid        the hashed key id (LiteLLM `token`)
 *   user:{uid}:key          the virtual key returned to the app
 *   user:{uid}:web:keyid / :web:key   the web platform's pair
 *
 * Race safety: a per-UID `mintlock:{ns}{uid}` SET NX EX 30. A loser waits
 * 20 × 250 ms for the winner's key, then raises the contract 409. The global
 * new-key breaker runs INSIDE the lock — so a lock race always resolves to
 * 409 before the breaker can 503.
 */

export const KEY_NAMESPACES = ["", "web:"] as const;

export interface MintLockOptions {
  pollMs?: number;
  polls?: number;
}

function clockNow(deps: MintDeps): Date {
  const clock = deps.clock ?? (() => new Date());
  return new Date(clock().getTime());
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : String(err);
}

/**
 * The global new-key circuit breaker (mint.py inside the mintlock) is Task
 * 7's antiAbuse.checkNewKeyBreaker — imported above so there is exactly one
 * implementation. It caps brand-new keys per window so no mass-creation
 * event can run away.
 */

/**
 * Shared LiteLLM team for web keys; its daily budget caps total web spend.
 * mint.py web_team_id: cache config:web_team_id, create "ovid-web" once, and
 * re-sync config:web_team_budget whenever WEB_TEAM_DAILY_USD changes.
 */
export async function webTeamId(deps: MintDeps): Promise<string> {
  const team = await deps.redis.get("config:web_team_id");
  // Python str(WEB_TEAM_DAILY_USD) renders a float ("25.0") — pyNumStr.
  const want = pyNumStr(deps.env.webTeamDailyUsd);
  if (team) {
    if ((await deps.redis.get("config:web_team_budget")) !== want) {
      const status = await deps.litellm.teamUpdate({
        team_id: team,
        max_budget: deps.env.webTeamDailyUsd,
        budget_duration: "1d",
      });
      if (status > 0 && status < 300) {
        await deps.redis.set("config:web_team_budget", want);
      }
    }
    return team;
  }
  const created = await deps.litellm.teamNew({
    team_alias: "ovid-web",
    max_budget: deps.env.webTeamDailyUsd,
    budget_duration: "1d",
  });
  await deps.redis.set("config:web_team_id", created.team_id);
  await deps.redis.set("config:web_team_budget", want);
  return created.team_id;
}

/**
 * The explicit model scope for a newly minted key: every public catalog group
 * plus the image alias (P9 gives keys an explicit scope; the old Python body
 * had none). An EMPTY catalog is never turned into an alias-only scope — a
 * transient LiteLLM outage must not mint a key that cannot chat.
 */
async function publicModelScope(deps: MintDeps): Promise<string[] | null> {
  const catalog = await catalogFor(deps);
  const names = Object.keys(catalog.groups);
  if (names.length === 0) {
    return null;
  }
  if (!names.includes("ovid-image")) {
    names.push("ovid-image");
  }
  return names;
}

/**
 * mint.py _key_state: (usable, info). Only 401/403/404 and an expired
 * `expires` are unusable; upstream errors/timeouts count as usable so an
 * outage never churns keys.
 */
async function keyState(
  deps: MintDeps,
  keyId: string,
): Promise<{ usable: boolean; info: Record<string, unknown> | null }> {
  const { status, info } = await deps.litellm.keyInfoStatus(keyId);
  if (status === 401 || status === 403 || status === 404) {
    return { usable: false, info: null };
  }
  if (status !== 200) {
    return { usable: true, info: null };
  }
  const row = (info ?? null) as Record<string, unknown> | null;
  const expires = row?.expires;
  if (typeof expires === "string" && expires !== "") {
    const when = parseTime(expires);
    if (when !== null && when.getTime() <= clockNow(deps).getTime()) {
      return { usable: false, info: row };
    }
  }
  return { usable: true, info: row };
}

/** mint.py _safe_user_budget: a budget backstop failure never fails mint. */
async function safeUserBudget(deps: MintDeps, uid: string, tier: string): Promise<void> {
  try {
    await ensureUserBudget(deps, uid, tier, false, null);
  } catch (err) {
    console.log(`[mint] user budget error: ${errorName(err)}`);
  }
}

/**
 * Strictly idempotent per (uid, platform). Returns the virtual key.
 */
export async function litellmMintOrGet(
  deps: MintDeps,
  uid: string,
  tier: string,
  platform: "android" | "web",
  opts: MintLockOptions = {},
): Promise<string> {
  const { budget, duration } = await tierBudget(deps, uid, tier);
  const ns = platform === "web" ? "web:" : "";
  const idKey = `user:${uid}:${ns}keyid`;
  const plainKey = `user:${uid}:${ns}key`;

  const existing = await deps.redis.get(idKey);
  const body: Record<string, unknown> = {
    user_id: uid,
    max_budget: budget,
    budget_duration: duration,
    metadata: { tier, ovid_uid: uid, platform },
    // Runtime-editable limits; slow-mode limits while the user is in it.
    ...(await poolRateLimits(deps, uid)),
  };
  const models = await publicModelScope(deps);
  if (models !== null) {
    body.models = models;
  }
  if (platform === "web") {
    body.team_id = await webTeamId(deps);
  }

  let info: Record<string, unknown> | null = null;
  let usable = false;
  if (existing) {
    ({ usable, info } = await keyState(deps, existing));
  }

  if (existing && usable) {
    const update: Record<string, unknown> = { key: existing, ...body };
    // Re-sending an unchanged budget_duration restarts LiteLLM's budget
    // clock on every app launch; only send it when it changes (or when the
    // stored state is unknown because of an outage).
    if (info === null || info.budget_duration === duration) {
      delete update.budget_duration;
    }
    await deps.litellm.keyUpdate(update);
    await safeUserBudget(deps, uid, tier);
    await deps.redis.sadd(OVID_UIDS_SET, uid);
    // I4: mint-provisioned (the durable analogue of Python's ovid:uids).
    await plansRepo.markProvisioned(deps.db, uid);
    const stored = await deps.redis.get(plainKey);
    if (stored) {
      return stored;
    }
  }

  if (existing) {
    // Stored key is gone/expired/rejected (or its plaintext is missing):
    // replace it so the app is never stuck retrying a dead key.
    console.log(`[mint] re-issuing unusable key for ${uid.slice(0, 6)}`);
    try {
      await deps.litellm.keyDelete([existing]);
    } catch {
      // Python swallows this too.
    }
    await deps.redis.del(idKey, plainKey);
  }

  // No usable key → per-UID creation lock so concurrent calls for a brand-new
  // account cannot each mint a key (race-safe idempotency).
  const lock = `mintlock:${ns}${uid}`;
  const got = await deps.redis.set(lock, "1", "EX", 30, "NX");
  if (got !== "OK") {
    const pollMs = opts.pollMs ?? 250;
    const polls = opts.polls ?? 20;
    for (let i = 0; i < polls; i++) {
      await sleep(pollMs);
      const stored = await deps.redis.get(plainKey);
      if (stored) {
        return stored;
      }
    }
    throw new HttpContractError(409, "key creation in progress, retry");
  }

  try {
    // Re-check inside the lock (someone may have just created it).
    const stored = await deps.redis.get(plainKey);
    if (stored) {
      return stored;
    }
    await checkNewKeyBreaker(deps);
    const data = await deps.litellm.keyGenerate(body);
    const key = data.key;
    await deps.redis.set(idKey, data.token ?? key);
    await deps.redis.set(plainKey, key);
    await deps.redis.sadd(OVID_UIDS_SET, uid);
    await plansRepo.markProvisioned(deps.db, uid);
    await safeUserBudget(deps, uid, tier);
    return key;
  } finally {
    await deps.redis.del(lock);
  }
}

/**
 * {namespace: keyid} across android + web. Delegates to Task 5's canonical
 * prefixed helper (the T5 review carry: Task 6 must NOT re-read the keys).
 */
export async function userKeyIds(
  deps: MintDeps,
  uid: string,
): Promise<Record<string, string>> {
  return poolUserKeyIds(deps, uid);
}
