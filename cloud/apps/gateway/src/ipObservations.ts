/**
 * Per-uid IP observation store — the Redis half of IP anomaly detection.
 *
 * One sorted set per uid (`ovid:ipobs:{uid}`) holds this account's recent
 * network observations. The SCORE is the observation epoch ms, so the policy
 * window is enforced by a single ZREMRANGEBYSCORE against `now - windowMs`
 * and reads are an exact ZRANGEBYSCORE — no stale entries, no client-side
 * re-scan of unbounded history.
 *
 * Each member carries a random nonce so two requests from the same IP in the
 * same millisecond are two observations, not one overwritten ZSET member:
 * the volume floor (`minObservations`) must count requests, not distinct
 * (ip, at) pairs.
 *
 * The set is also capped by rank (newest kept) and given a TTL slightly
 * longer than the window, so a noisy uid cannot grow memory without bound
 * and an abandoned uid's key expires on its own.
 *
 * ASN DATA IS TRUSTED EDGE EVIDENCE ONLY. ipAnomalyGuard supplies a numeric
 * ASN solely when a configured proxy also supplied a valid forwarding chain
 * (or the Web edge supplied a verified signature). Direct/malformed headers
 * remain null and the evaluator uses its conservative network fallback.
 *
 * The redis parameter is structural (ioredis-shaped): production passes a
 * live ioredis instance, tests pass an in-memory fake.
 */

import { randomUUID } from "node:crypto";
import type { IpObservation } from "./anomaly.js";

/** Redis key prefix: `ovid:ipobs:${uid}` → a ZSET scored by epoch ms. */
export const IP_OBSERVATION_KEY_PREFIX = "ovid:ipobs:";

/** Newest observations kept per uid. Well above the policy's thresholds. */
export const IP_OBSERVATION_MAX_ENTRIES = 2_000;

/** Matches DEFAULT_IP_ANOMALY_POLICY.windowMs; callers may override. */
export const DEFAULT_IP_OBSERVATION_WINDOW_MS = 10 * 60 * 1000;

/** TTL is the window plus a minute, so a cold key expires without a sweep. */
const TTL_SLACK_SECONDS = 60;

export interface IpObservationRedis {
  zadd(key: string, score: number, member: string): unknown;
  zremrangebyscore(
    key: string,
    min: string | number,
    max: string | number,
  ): unknown;
  zremrangebyrank(key: string, start: number, stop: number): unknown;
  zrangebyscore(
    key: string,
    min: string | number,
    max: string | number,
  ): unknown;
  expire(key: string, seconds: number): unknown;
}

export interface IpObservationStore {
  /**
   * Append one observation and return the current in-window set, INCLUDING
   * the new observation. The caller evaluates that set directly.
   */
  record(uid: string, observation: IpObservation): Promise<IpObservation[]>;
  /** Read the in-window set without recording (defaults to Date.now()). */
  read(uid: string, now?: number): Promise<IpObservation[]>;
}

/**
 * Defensive member parser: a malformed or foreign member is skipped, never
 * allowed to crash admission.
 */
export function parseIpObservationMember(raw: unknown): IpObservation | null {
  if (typeof raw !== "string") return null;
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof value !== "object" || value === null) return null;
  const record = value as Record<string, unknown>;
  const ip = record.ip;
  const at = record.at;
  const asn = record.asn;
  if (typeof ip !== "string") return null;
  if (typeof at !== "number" || !Number.isFinite(at)) return null;
  if (
    asn !== undefined &&
    asn !== null &&
    typeof asn !== "string" &&
    typeof asn !== "number"
  ) {
    return null;
  }
  return { ip, asn: (asn as string | number | null | undefined) ?? null, at };
}

export interface IpObservationStoreOptions {
  keyPrefix?: string;
  windowMs?: number;
  maxEntries?: number;
  /** Epoch-ms clock for observations with a non-finite `at`. */
  clock?: () => number;
}

export function createIpObservationStore(
  redis: IpObservationRedis,
  opts: IpObservationStoreOptions = {},
): IpObservationStore {
  const keyPrefix = opts.keyPrefix ?? IP_OBSERVATION_KEY_PREFIX;
  const windowMs = opts.windowMs ?? DEFAULT_IP_OBSERVATION_WINDOW_MS;
  const maxEntries = opts.maxEntries ?? IP_OBSERVATION_MAX_ENTRIES;
  const clock = opts.clock ?? (() => Date.now());
  const ttlSeconds = Math.ceil(windowMs / 1000) + TTL_SLACK_SECONDS;

  const key = (uid: string): string => `${keyPrefix}${uid}`;

  async function readInWindow(uid: string, now: number): Promise<IpObservation[]> {
    const raw = await redis.zrangebyscore(key(uid), now - windowMs, "+inf");
    if (!Array.isArray(raw)) return [];
    const observations: IpObservation[] = [];
    for (const member of raw) {
      const parsed = parseIpObservationMember(member);
      if (parsed !== null) observations.push(parsed);
    }
    return observations;
  }

  return {
    async record(uid, observation) {
      const at = Number.isFinite(observation.at) ? observation.at : clock();
      const member = JSON.stringify({
        ip: observation.ip,
        asn: observation.asn ?? null,
        at,
        // Unique per request so same-ms observations all count.
        n: randomUUID(),
      });
      await redis.zadd(key(uid), at, member);
      // Trim to the policy window. The window is INCLUSIVE at the cutoff
      // (`at >= now - windowMs`, matching evaluateIpAnomaly), so remove only
      // strictly older scores: max = cutoff - 1.
      await redis.zremrangebyscore(key(uid), "-inf", at - windowMs - 1);
      await redis.zremrangebyrank(key(uid), 0, -(maxEntries + 1));
      await redis.expire(key(uid), ttlSeconds);
      return readInWindow(uid, at);
    },

    async read(uid, now) {
      return readInWindow(uid, now ?? clock());
    },
  };
}
