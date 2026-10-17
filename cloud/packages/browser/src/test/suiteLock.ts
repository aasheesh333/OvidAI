/**
 * Cross-suite redis lock for browser pub/sub tests (T13 precedent, binding
 * P6 ruling): `pnpm -r test` runs the gateway/worker/browser suites
 * concurrently and redis pub/sub is not db-scoped, so every suite that emits
 * on browser channels takes `browser:test:suite-lock` so only one runs at a
 * time.
 *
 * The lock is TTL-guarded (a crashed holder frees it) and REFRESHED while
 * held: the Task-14 engine suite runs real chromium legs that can outlive a
 * short TTL, and an unrefreshed lock expiring mid-run would silently admit a
 * second concurrent suite — the exact hazard the lock exists to prevent.
 * The refresh is token-checked (eval), so a holder that already lost the key
 * (expired + re-acquired by someone else) can never steal it back.
 */

import { randomUUID } from "node:crypto";

import type { Redis } from "ioredis";

export const BROWSER_SUITE_LOCK_KEY = "browser:test:suite-lock";

export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** Atomically extend OUR lock's TTL; a no-op if the key is gone or ours. */
const EXTEND_SCRIPT =
  "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('pexpire', KEYS[1], ARGV[2]) else return 0 end";

/** Atomically delete OUR lock only (a TTL expiry between GET and DEL must not
 * delete the next holder's key). */
const RELEASE_SCRIPT =
  "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end";

export async function acquireBrowserSuiteLock(
  redis: Redis,
  opts: { ttlMs?: number; deadlineMs?: number } = {},
): Promise<() => Promise<void>> {
  const ttlMs = opts.ttlMs ?? 30_000;
  const refreshMs = Math.max(250, Math.floor(ttlMs / 3));
  const deadlineMs = opts.deadlineMs ?? 120_000;
  const token = randomUUID();
  const deadline = Date.now() + deadlineMs;
  for (;;) {
    const ok = await redis.set(BROWSER_SUITE_LOCK_KEY, token, "PX", ttlMs, "NX");
    if (ok === "OK") break;
    if (Date.now() > deadline) {
      throw new Error(`browser suite lock not free within ${deadlineMs}ms`);
    }
    await sleep(50);
  }
  const refresher = setInterval(() => {
    void redis.eval(EXTEND_SCRIPT, 1, BROWSER_SUITE_LOCK_KEY, token, ttlMs).catch(() => {});
  }, refreshMs);
  refresher.unref?.();
  let released = false;
  return async () => {
    if (released) return;
    released = true;
    clearInterval(refresher);
    await redis.eval(RELEASE_SCRIPT, 1, BROWSER_SUITE_LOCK_KEY, token).catch(() => {});
  };
}
