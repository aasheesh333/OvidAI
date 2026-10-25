import {
  BillingRemotePlaintextUnavailableError,
  BillingRemoteStaleGenerationError,
  BillingRemoteTargetDeletedError,
  BillingRemoteUnresolvedError,
  billingUsers,
} from "@ovid/db";
import { pyNumStr } from "@ovid/money";
import { checkNewKeyBreaker } from "./antiAbuse.js";
import type { MintDeps } from "./app.js";
import { HttpContractError } from "./app.js";
import { catalogFor } from "./catalog.js";
import { OVID_UIDS_SET } from "./planMath.js";
import { parseTime } from "./usage.js";
import {
  effectiveTier,
  ensureUserBudget,
  poolRateLimits,
  poolUserKeyIds,
  tierBudget,
  updateKeyProjection,
  executeBillingRemoteOperation,
  currentBillingProjectionGeneration,
  StaleBillingAccountWriteError,
  withBillingAccountWrite,
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
const WEB_TEAM_SCOPE = "$litellm:web-team";
const WEB_TEAM_ALIAS = "ovid-web";

async function writeWebTeamConfig(
  deps: MintDeps,
  generation: number,
  teamId: string,
  budget: string,
): Promise<void> {
  const result = await deps.redis.eval(
    `if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
     redis.call('SET', KEYS[2], ARGV[2])
     redis.call('SET', KEYS[3], ARGV[3])
     return 1`,
    3,
    `user:${WEB_TEAM_SCOPE}:billing_refresh_generation`,
    "config:web_team_id",
    "config:web_team_budget",
    String(generation),
    teamId,
    budget,
  );
  if (Number(result) !== 1) throw new StaleBillingAccountWriteError();
}

export async function webTeamId(deps: MintDeps): Promise<string> {
  return withBillingAccountWrite(deps, WEB_TEAM_SCOPE, async () => {
    const generation = currentBillingProjectionGeneration();
    if (generation === undefined) throw new StaleBillingAccountWriteError();
    const team = await deps.redis.get("config:web_team_id");
    // Python str(WEB_TEAM_DAILY_USD) renders a float ("25.0") — pyNumStr.
    const want = pyNumStr(deps.env.webTeamDailyUsd);
    if (team) {
      if ((await deps.redis.get("config:web_team_budget")) !== want) {
        await executeBillingRemoteOperation(deps, WEB_TEAM_SCOPE, "team", team, {
          team_id: team,
          max_budget: deps.env.webTeamDailyUsd,
          budget_duration: "1d",
        });
        await writeWebTeamConfig(deps, generation, team, want);
      }
      return team;
    }
    const created = await executeBillingRemoteOperation(
      deps,
      WEB_TEAM_SCOPE,
      "team",
      WEB_TEAM_ALIAS,
      {
        team_alias: WEB_TEAM_ALIAS,
        max_budget: deps.env.webTeamDailyUsd,
        budget_duration: "1d",
      },
      { effect: "generate", idempotencyKey: "litellm:web-team:create" },
    );
    const responseTeam = created.response?.team_id;
    const teamId = typeof responseTeam === "string" && responseTeam !== ""
      ? responseTeam
      : created.target;
    if (teamId === undefined || teamId === "") throw new BillingRemoteUnresolvedError();
    if (created.recovered) {
      // Alias recovery proves the original create. Repair only current budget
      // amount; omitting its unchanged duration avoids a second clock reset.
      await executeBillingRemoteOperation(deps, WEB_TEAM_SCOPE, "team", teamId, {
        team_id: teamId,
        max_budget: deps.env.webTeamDailyUsd,
      });
    }
    await writeWebTeamConfig(deps, generation, teamId, want);
    return teamId;
  });
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
type KeyTargetState = "live" | "expired" | "deleted" | "unavailable";

async function keyState(
  deps: MintDeps,
  keyId: string,
): Promise<{ state: KeyTargetState; info: Record<string, unknown> | null }> {
  const { status, info } = await deps.litellm.keyInfoStatus(keyId);
  // Only authenticated 404 proves a deleted target. Auth failures and upstream
  // outages are unavailable, never permission to churn or acknowledge a key.
  if (status === 404) return { state: "deleted", info: null };
  if (status !== 200 || info === null) return { state: "unavailable", info: null };
  const row = info as Record<string, unknown>;
  const expires = row.expires;
  if (typeof expires === "string" && expires !== "") {
    const when = parseTime(expires);
    if (when !== null && when.getTime() <= clockNow(deps).getTime()) {
      return { state: "expired", info: row };
    }
  }
  return { state: "live", info: row };
}

/** A mint response requires both a live verified key and a resolved user budget. */
async function requireUserBudget(deps: MintDeps, uid: string, tier: string): Promise<void> {
  await ensureUserBudget(deps, uid, tier, false, null);
}

function requiredGeneration(): number {
  const generation = currentBillingProjectionGeneration();
  if (generation === undefined) throw new StaleBillingAccountWriteError();
  return generation;
}

async function installKeyReference(
  deps: MintDeps,
  uid: string,
  idKey: string,
  plainKey: string,
  keyId: string,
  plaintext: string,
): Promise<void> {
  if (keyId === "" || plaintext === "") throw new BillingRemoteUnresolvedError();
  const result = await deps.redis.eval(
    `if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
     redis.call('SET', KEYS[2], ARGV[2])
     redis.call('SET', KEYS[3], ARGV[3])
     redis.call('SADD', KEYS[4], ARGV[4])
     return 1`,
    4,
    `user:${uid}:billing_refresh_generation`,
    idKey,
    plainKey,
    OVID_UIDS_SET,
    String(requiredGeneration()),
    keyId,
    plaintext,
    uid,
  );
  if (Number(result) !== 1) throw new StaleBillingAccountWriteError();
}

async function clearKeyReference(
  deps: MintDeps,
  uid: string,
  idKey: string,
  plainKey: string,
  expectedKeyId: string,
): Promise<void> {
  const result = await deps.redis.eval(
    `if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
     if redis.call('GET', KEYS[2]) ~= ARGV[2] then return 0 end
     redis.call('DEL', KEYS[2], KEYS[3])
     return 1`,
    3,
    `user:${uid}:billing_refresh_generation`,
    idKey,
    plainKey,
    String(requiredGeneration()),
    expectedKeyId,
  );
  if (Number(result) !== 1) throw new StaleBillingAccountWriteError();
}

async function markMintProvisioned(deps: MintDeps, uid: string): Promise<void> {
  if (!(await billingUsers.markProvisionedForRefresh(deps.db, uid, requiredGeneration()))) {
    throw new StaleBillingAccountWriteError();
  }
}

async function requireLiveStoredKey(
  deps: MintDeps,
  keyId: string,
  plainKey: string,
): Promise<string> {
  const stored = await deps.redis.get(plainKey);
  if (stored === null || stored === "") throw new BillingRemotePlaintextUnavailableError();
  const current = await keyState(deps, keyId);
  if (current.state === "deleted" || current.state === "expired") {
    throw new BillingRemoteTargetDeletedError();
  }
  if (current.state !== "live") throw new BillingRemoteUnresolvedError();
  return stored;
}

/**
 * Strictly idempotent per (uid, platform). Returns the virtual key.
 */
async function litellmMintOrGetLocked(
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
  let state: KeyTargetState | "absent" = existing ? "unavailable" : "absent";
  if (existing) {
    const current = await keyState(deps, existing);
    state = current.state;
    info = current.info;
  }
  if (existing && state === "unavailable") throw new BillingRemoteUnresolvedError();

  if (existing && state === "live") {
    const update: Record<string, unknown> = { key: existing, ...body };
    // Re-sending an unchanged budget_duration restarts LiteLLM's budget
    // clock on every app launch; only send it when it changes (or when the
    // stored state is unknown because of an outage).
    if (info === null || info.budget_duration === duration) {
      delete update.budget_duration;
    }
    await updateKeyProjection(deps, uid, existing, update);
    await requireUserBudget(deps, uid, tier);
    await markMintProvisioned(deps, uid);
    if ((await deps.redis.get(plainKey)) !== null) {
      return requireLiveStoredKey(deps, existing, plainKey);
    }
  }

  if (existing) {
    // Stored key is gone/expired/rejected (or its plaintext is missing):
    // replace it so the app is never stuck retrying a dead key.
    console.log(`[mint] re-issuing unusable key for ${uid.slice(0, 6)}`);
    await executeBillingRemoteOperation(
      deps,
      uid,
      "key",
      existing,
      { keys: [existing] },
      { effect: "delete" },
    );
    await clearKeyReference(deps, uid, idKey, plainKey, existing);
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
      const storedId = await deps.redis.get(idKey);
      if (storedId !== null && storedId !== "") {
        return requireLiveStoredKey(deps, storedId, plainKey);
      }
    }
    throw new HttpContractError(409, "key creation in progress, retry");
  }

  try {
    // Re-check inside the lock (someone may have just created it). A plaintext
    // value without its target id is not a successful, verifiable mint.
    const storedId = await deps.redis.get(idKey);
    if (storedId !== null && storedId !== "") {
      return requireLiveStoredKey(deps, storedId, plainKey);
    }
    if ((await deps.redis.get(plainKey)) !== null) {
      throw new BillingRemotePlaintextUnavailableError();
    }

    const alias = `ovid:mint:${uid}:${platform}`;
    const created = await executeBillingRemoteOperation(
      deps,
      uid,
      "key",
      alias,
      { ...body, key_alias: alias },
      { effect: "generate", idempotencyKey: alias },
      {
        beforeSend: () => checkNewKeyBreaker(deps),
        onResult: async (_operation, response) => {
          const plaintext = response.key;
          const token = response.token ?? response.key;
          if (typeof plaintext !== "string" || typeof token !== "string") {
            throw new BillingRemoteUnresolvedError();
          }
          await installKeyReference(deps, uid, idKey, plainKey, token, plaintext);
        },
      },
    );
    const createdId = created.target ?? (await deps.redis.get(idKey));
    if (createdId === undefined || createdId === null || createdId === "") {
      throw new BillingRemotePlaintextUnavailableError();
    }
    const live = await keyState(deps, createdId);
    if (live.state !== "live") throw new BillingRemoteUnresolvedError();
    const currentUpdate: Record<string, unknown> = { key: createdId, ...body };
    if (live.info?.budget_duration === duration) delete currentUpdate.budget_duration;
    await updateKeyProjection(deps, uid, createdId, currentUpdate);
    await markMintProvisioned(deps, uid);
    await requireUserBudget(deps, uid, tier);
    // Recovery may have a live target but no original response. Only an
    // actually installed plaintext reference can be returned; never generate
    // a second credential to work around a lost response.
    return requireLiveStoredKey(deps, createdId, plainKey);
  } finally {
    await deps.redis.del(lock);
  }
}

export async function litellmMintOrGet(
  deps: MintDeps,
  uid: string,
  _tier: string,
  platform: "android" | "web",
  opts: MintLockOptions = {},
): Promise<string> {
  // Key creation cannot overwrite an existing key. A lost generate response
  // cannot install a stale Redis reference; any installed reference is visible
  // to the next entitlement repair. The account lock keeps that installation,
  // existing-key mutation, and user-budget write in one generation.
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      return await withBillingAccountWrite(deps, uid, async () => {
        // The HTTP caller's tier read can predate a refund. Authority is read
        // again only after this writer's durable generation/lock is current.
        const currentTier = await effectiveTier(deps, uid);
        return litellmMintOrGetLocked(deps, uid, currentTier, platform, opts);
      });
    } catch (error) {
      if (error instanceof BillingRemotePlaintextUnavailableError) {
        throw new HttpContractError(503, "key recovery requires administrator reconciliation");
      }
      if (error instanceof BillingRemoteUnresolvedError || error instanceof BillingRemoteTargetDeletedError) {
        throw new HttpContractError(503, "key projection is temporarily unresolved; retry later");
      }
      if (!(error instanceof StaleBillingAccountWriteError) &&
          !(error instanceof BillingRemoteStaleGenerationError)) throw error;
      // No mutation ran; retry with a fresh generation and authority read.
    }
  }
  throw new HttpContractError(503, "key projection is temporarily unresolved; retry later");
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
