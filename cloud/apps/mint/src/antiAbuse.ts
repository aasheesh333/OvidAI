import type { MintDeps } from "./app.js";
import { HttpContractError } from "./app.js";
import { poolUserKeyIds } from "./windows.js";

/**
 * Port of mint.py's anti-abuse block (mint.py:790-864) — client IP
 * extraction, the shared-IP-safe signup throttle, the per-IP mint-call
 * throttle, the global new-key breaker and the UID strike counter.
 *
 * SHARED-IP SAFETY (the design note carried verbatim from mint.py):
 * CGNAT mobile carriers and college/office WiFi put thousands of legitimate
 * users behind ONE IP, so an IP is NEVER banned merely because many accounts
 * use it. App Check is the primary anti-farm signal; signup VELOCITY throttles
 * only brand-new accounts (never existing users on the IP), and abuse strikes
 * land on the UID. `ban:ip:{ip}` is reserved for corroborated/admin cases.
 *
 * THE PYTHON DEFECT FIXED HERE: mint.py's auto-ban only set
 * `user:{uid}:banned`; the already-issued LiteLLM keys kept working until the
 * user was manually unbanned/re-banned from the console. Every auto-ban now
 * also blocks the account's LiteLLM keys (android + web) via setKeyBlocked.
 */

function clockNow(deps: MintDeps): Date {
  const clock = deps.clock ?? (() => new Date());
  return new Date(clock().getTime());
}

/** Whole epoch seconds — Python `int(time.time())`. */
function epochSeconds(deps: MintDeps): number {
  return Math.floor(clockNow(deps).getTime() / 1000);
}

/** Python `int(time.time() // WINDOW_S)` (integer division on epoch seconds). */
function windowBucket(deps: MintDeps, windowS: number): number {
  return Math.floor(epochSeconds(deps) / windowS);
}

/** mint.py client_ip: first XFF hop, else x-real-ip, else "unknown". */
export function clientIp(xff: string, xRealIp: string): string {
  if (xff) {
    return xff.split(",")[0]!.trim();
  }
  return (xRealIp || "unknown").trim();
}

/** mint.py is_banned: the UID flag, or an admin-corroborated IP ban. */
export async function isBanned(deps: MintDeps, uid: string, ip: string): Promise<boolean> {
  if (await deps.redis.get(`user:${uid}:banned`)) {
    return true;
  }
  if (ip && ip !== "unknown" && (await deps.redis.get(`ban:ip:${ip}`))) {
    return true;
  }
  return false;
}

/**
 * mint.py _set_key_blocked: /key/block or /key/unblock for EVERY namespace
 * keyid (android, then web). Failures are logged by the wrapper and never
 * abort the other key (Python's per-key try/except).
 */
export async function setKeyBlocked(
  deps: MintDeps,
  uid: string,
  blocked: boolean,
): Promise<void> {
  for (const keyId of Object.values(await poolUserKeyIds(deps, uid))) {
    try {
      if (blocked) {
        await deps.litellm.keyBlock(keyId);
      } else {
        await deps.litellm.keyUnblock(keyId);
      }
    } catch (err) {
      console.log(`[mint] key block error: ${errorName(err)}`);
    }
  }
}

/**
 * mint.py record_strike: count an abuse signal on the UID (the actual bad
 * actor). At the limit the account is banned ("auto") AND its LiteLLM keys
 * are blocked — the defect fix. The IP counter stays advisory only.
 */
export async function recordStrike(deps: MintDeps, uid: string, ip: string): Promise<void> {
  const windowS = deps.env.abuse.abuseWindowS;
  const strikeKey = `abuse:uid:${uid}`;
  const n = await deps.redis.incr(strikeKey);
  if (n === 1) {
    await deps.redis.expire(strikeKey, windowS);
  }
  if (n >= deps.env.abuse.abuseStrikeLimit) {
    await deps.redis.set(`user:${uid}:banned`, "auto");
    // THE FIX: a banned account must stop spending through its cached keys.
    await setKeyBlocked(deps, uid, true);
    await deps.alerter(
      "auto_ban",
      `uid ${uid.slice(0, 6)}… auto-banned after ${n} abuse strikes`,
      600,
    );
  }

  // Advisory IP signal (admin review / corroboration only — never a ban).
  const ipKey = `abuse:ip:${ip}`;
  const m = await deps.redis.incr(ipKey);
  if (m === 1) {
    await deps.redis.expire(ipKey, windowS);
  }
}

/**
 * mint.py enforce_ip_signup_quota: throttle only the RATE of NEW account
 * creation from an IP in a short window. A returning uid on `ipacct` is never
 * touched; the IP itself is never banned.
 */
export async function enforceIpSignupQuota(
  deps: MintDeps,
  uid: string,
  ip: string,
): Promise<void> {
  if (!ip || ip === "unknown") {
    return;
  }
  const seenKey = `ipacct:${ip}`;
  if (await deps.redis.sismember(seenKey, uid)) {
    return;
  }

  const windowS = deps.env.abuse.signupVelocityWindowS;
  const velKey = `ipnew:${ip}:${windowBucket(deps, windowS)}`;
  const vel = await deps.redis.incr(velKey);
  if (vel === 1) {
    await deps.redis.expire(velKey, windowS);
  }
  if (vel > deps.env.abuse.newAccountsPerIpPerWindow) {
    await deps.alerter(
      "signup_velocity",
      `IP ${ip} exceeded ${deps.env.abuse.newAccountsPerIpPerWindow} new accounts / window`,
      1800,
    );
    // Throttle the NEW signup only — existing users unaffected, IP NOT banned.
    throw new HttpContractError(
      429,
      "sign-ups from this network are busy right now — please retry in a few minutes",
    );
  }

  await deps.redis.sadd(seenKey, uid);
  await deps.redis.expire(seenKey, deps.env.abuse.ipAccountWindowS);
}

/** mint.py's per-IP mint-call throttle (generous; caps calls, never usage). */
export async function enforceMintRateLimit(deps: MintDeps, ip: string): Promise<void> {
  if (!ip || ip === "unknown") {
    return;
  }
  const windowS = deps.env.abuse.mintWindowS;
  const key = `mintrate:${ip}:${windowBucket(deps, windowS)}`;
  const count = await deps.redis.incr(key);
  if (count === 1) {
    await deps.redis.expire(key, windowS);
  }
  if (count > deps.env.abuse.mintCallsPerIp) {
    throw new HttpContractError(429, "too many requests from this network — retry later");
  }
}

/**
 * mint.py's global new-key circuit breaker (inside the per-UID mint lock):
 * cap brand-new keys per window so no mass-creation event runs away.
 */
export async function checkNewKeyBreaker(deps: MintDeps): Promise<void> {
  const windowS = deps.env.abuse.newkeyWindowS;
  const key = `newkeys:${windowBucket(deps, windowS)}`;
  const created = await deps.redis.incr(key);
  if (created === 1) {
    await deps.redis.expire(key, windowS);
  }
  if (created > deps.env.abuse.globalNewkeysPerWindow) {
    await deps.redis.set("alert:newkey_spike", String(created), "EX", windowS);
    await deps.alerter(
      "newkey_spike",
      `${created} new keys this window (cap ${deps.env.abuse.globalNewkeysPerWindow}); sign-ups paused`,
    );
    throw new HttpContractError(
      503,
      "sign-ups are temporarily paused — please try again shortly",
    );
  }
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : String(err);
}
