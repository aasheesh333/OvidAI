/**
 * Session activity tracker — P7 statehydrator.
 *
 * One plain string key per session holds the last-activity epoch ms. The
 * hibernate engine (Task 8) treats a key fresher than the idle threshold as
 * `recent_activity` and skips hibernation; the Task 10 sweeper reads many at
 * once for LRU ordering. Bumps are O(1) SETs with a 7 d TTL so the
 * allkeys-lru redis can evict cold entries freely — a missing key reads as
 * null (UNKNOWN last-use, not "long ago") and callers fall back to the
 * file_manifests row's updated_at.
 *
 * The redis parameter is a structural, ioredis-shaped interface: production
 * passes a live ioredis instance, tests pass fakes — @ovid/storage takes no
 * runtime dependency on ioredis.
 */

/** Redis key prefix: `ovid:activity:${sessionId}` → epoch-ms string. */
export const ACTIVITY_KEY_PREFIX = "ovid:activity:";

/** 7 days, refreshed on every bump. */
export const ACTIVITY_TTL_SECONDS = 604_800;

export interface ActivityTracker {
  /** SET key <now epoch ms> EX ttl — records use and refreshes the TTL. */
  bump(sessionId: string): Promise<void>;
  /** Epoch ms of the last bump, or null when the key is missing/evicted. */
  read(sessionId: string): Promise<number | null>;
  /**
   * Bulk read: epoch ms per present session id (missing/evicted keys are
   * omitted from the Map). MGET is issued in batches of 500 keys.
   */
  readMany(sessionIds: string[]): Promise<Map<string, number>>;
}

/** MGET key count per round trip — keeps each reply bounded. */
const MGET_BATCH_SIZE = 500;

function toEpochMs(raw: unknown): number | null {
  if (raw === null || raw === undefined) return null;
  const ms = Number(raw);
  return Number.isFinite(ms) ? ms : null;
}

export function createActivityTracker(
  redis: {
    set(k: string, v: string, mode: "EX", ttl: number): unknown;
    get(k: string): unknown;
    mget(...ks: string[]): unknown;
  },
  opts?: { keyPrefix?: string; ttlSeconds?: number; clock?: () => Date },
): ActivityTracker {
  const keyPrefix = opts?.keyPrefix ?? ACTIVITY_KEY_PREFIX;
  const ttlSeconds = opts?.ttlSeconds ?? ACTIVITY_TTL_SECONDS;
  const clock = opts?.clock ?? (() => new Date());

  const key = (sessionId: string): string => `${keyPrefix}${sessionId}`;

  return {
    async bump(sessionId) {
      await redis.set(key(sessionId), String(clock().getTime()), "EX", ttlSeconds);
    },

    async read(sessionId) {
      return toEpochMs(await redis.get(key(sessionId)));
    },

    async readMany(sessionIds) {
      const result = new Map<string, number>();
      for (let i = 0; i < sessionIds.length; i += MGET_BATCH_SIZE) {
        const batch = sessionIds.slice(i, i + MGET_BATCH_SIZE);
        if (batch.length === 0) continue; // never issue a zero-key MGET
        const values = await redis.mget(...batch.map(key));
        if (!Array.isArray(values)) continue;
        for (let j = 0; j < batch.length; j += 1) {
          const ms = toEpochMs(values[j]);
          if (ms !== null) result.set(batch[j], ms);
        }
      }
      return result;
    },
  };
}
