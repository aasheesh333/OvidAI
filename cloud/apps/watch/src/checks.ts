/**
 * Task 11 — the on-box check set.
 *
 * Every check returns a `CheckResult`; a dependency that throws degrades ONLY
 * that check (`ok:false`), never the whole pass. Thresholds are the plan's
 * locked defaults, overridable through `WATCH_*` env vars (env.ts).
 *
 * The spend-parity check reconciles the two independent money ledgers:
 *   - the TS-mint usage ledger (`pool:{uid}:spend` in redis db2 — the counter
 *     the unmodified LiteLLM Python hook writes and P9's TS mint maintains),
 *   - LiteLLM's own `LiteLLM_SpendLogs` Postgres table.
 * Money is integer cents end to end. The drift threshold is the GREATER of
 * `WATCH_SPEND_DRIFT_CENTS` (default 100¢) and `WATCH_SPEND_DRIFT_PCT`
 * (default 2 %) of the mint ledger — a fixed 100¢ floor stops rounding noise
 * from alerting, the percentage keeps the check meaningful for large spenders.
 */

export type CheckName =
  | "gateway-health"
  | "queue-depth"
  | "worker-lag"
  | "disk-80"
  | "redis-mem-80"
  | "spend-parity"
  | "anomaly-enforcement"
  | "suspension-mail"
  | "reservation-reconciliation"
  | "notification-delivery";

export interface CheckResult {
  name: CheckName;
  ok: boolean;
  value: number;
  threshold: number;
  detail: string;
}

export interface WatchThresholds {
  queueWaiting: number;
  workerLagS: number;
  diskPct: number;
  redisMemPct: number;
  spendDriftCents: number;
  spendDriftPct: number;
}

/** The plan's locked defaults (Task 11 Produces). */
export const DEFAULT_THRESHOLDS: WatchThresholds = {
  queueWaiting: 50,
  workerLagS: 300,
  diskPct: 80,
  redisMemPct: 80,
  spendDriftCents: 100,
  spendDriftPct: 2,
};

export const DEFAULT_QUEUE_NAMES = ["agent-runs"] as const;
export const DEFAULT_DISK_PATH = "/";
export const DEFAULT_GATEWAY_HEALTH_URL = "http://127.0.0.1:8082/cloud/v1/health";

/** A per-user spend total in integer cents. */
export interface SpendRow {
  uid: string;
  cents: number;
}

/** Optional knobs; main wires them from `WatchEnv`, tests use the defaults. */
export interface WatchCheckConfig {
  queueNames: string[];
  gatewayHealthUrl: string;
  diskPath: string;
  spendParity: boolean;
  thresholds: WatchThresholds;
}

/**
 * Injected side-effect seams (the plan's pinned shape) plus two additive,
 * documented seams needed to make the spend check honest without abusing
 * `sql` for a Redis lookup:
 *   - `config` groups the env-derived knobs,
 *   - `mintSpendCents` reads the TS-mint ledger.
 * `sql` stays the LiteLLM_SpendLogs reader.
 */
export interface WatchDeps {
  fetchJson(url: string): Promise<unknown>;
  redisInfo(section: string): Promise<Record<string, string>>;
  queueWaiting(name: string): Promise<number>;
  queueOldestWaitingAgeS(name: string): Promise<number>;
  sql<T>(q: string): Promise<T[]>;
  dfPct(path: string): Promise<number>;
  now(): Date;
  config?: Partial<WatchCheckConfig>;
  mintSpendCents?(): Promise<SpendRow[]>;
}

/**
 * LiteLLM_SpendLogs query (P9 reconciliation — the table lives in LiteLLM's
 * own Postgres DB, not `ovid_cloud`). `"user"` carries the Ovid uid: P9's key
 * provisioning sets the LiteLLM `user_id` to the uid. `startTime` is LiteLLM's
 * camelCase column. Values are dollars → cents in integer arithmetic.
 */
export function liteLlmSpendSql(sinceIso: string): string {
  return `SELECT COALESCE("user", '') AS uid,
       ROUND(SUM(COALESCE(spend, 0)) * 100)::bigint AS cents
  FROM "LiteLLM_SpendLogs"
 WHERE "startTime" >= '${sinceIso}'::timestamptz
   AND COALESCE("user", '') <> ''
 GROUP BY 1`;
}

/** UTC midnight for the given instant (the per-user daily drift window). */
export function startOfUtcDay(now: Date): Date {
  return new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 0, 0, 0, 0),
  );
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function round2(value: number): number {
  return Number(value.toFixed(2));
}

export async function collectChecks(deps: WatchDeps): Promise<CheckResult[]> {
  const config = deps.config ?? {};
  const thresholds: WatchThresholds = {
    ...DEFAULT_THRESHOLDS,
    ...(config.thresholds ?? {}),
  };
  const queueNames =
    config.queueNames !== undefined && config.queueNames.length > 0
      ? config.queueNames
      : [...DEFAULT_QUEUE_NAMES];
  const gatewayHealthUrl = config.gatewayHealthUrl ?? DEFAULT_GATEWAY_HEALTH_URL;
  const diskPath = config.diskPath ?? DEFAULT_DISK_PATH;
  const spendParity = config.spendParity ?? true;
  // One payload feeds gateway liveness and the four operational facts. A
  // missing field is unknown (and failing), never an implicit healthy value.
  const healthPayload = Promise.resolve().then(() => deps.fetchJson(gatewayHealthUrl));

  const gatewayHealth = async (): Promise<CheckResult> => {
    try {
      const body = (await healthPayload) as {
        status?: unknown;
        ok?: unknown;
      } | null;
      const ok = body?.status === "ok" || body?.ok === true;
      return {
        name: "gateway-health",
        ok,
        value: ok ? 1 : 0,
        threshold: 1,
        detail: ok
          ? `status ok (${gatewayHealthUrl})`
          : `status ${String(body?.status ?? "unknown")} (${gatewayHealthUrl})`,
      };
    } catch (err) {
      return {
        name: "gateway-health",
        ok: false,
        value: 0,
        threshold: 1,
        detail: `unreachable: ${errorMessage(err)}`,
      };
    }
  };

  const queueDepth = async (): Promise<CheckResult> => {
    const readings = await Promise.all(
      queueNames.map(async (name) => ({ name, waiting: await deps.queueWaiting(name) })),
    );
    const worst = readings.reduce((a, b) => (b.waiting > a.waiting ? b : a));
    const ok = worst.waiting <= thresholds.queueWaiting;
    return {
      name: "queue-depth",
      ok,
      value: worst.waiting,
      threshold: thresholds.queueWaiting,
      detail: `${worst.name}: waiting ${worst.waiting}${
        readings.length > 1
          ? ` (${readings.map((r) => `${r.name}=${r.waiting}`).join(", ")})`
          : ""
      }`,
    };
  };

  const workerLag = async (): Promise<CheckResult> => {
    const readings = await Promise.all(
      queueNames.map(async (name) => ({
        name,
        ageS: await deps.queueOldestWaitingAgeS(name),
      })),
    );
    const worst = readings.reduce((a, b) => (b.ageS > a.ageS ? b : a));
    const ok = worst.ageS <= thresholds.workerLagS;
    return {
      name: "worker-lag",
      ok,
      value: worst.ageS,
      threshold: thresholds.workerLagS,
      detail: `${worst.name}: oldest waiting ${worst.ageS}s`,
    };
  };

  const disk = async (): Promise<CheckResult> => {
    const pct = round2(await deps.dfPct(diskPath));
    return {
      name: "disk-80",
      ok: pct <= thresholds.diskPct,
      value: pct,
      threshold: thresholds.diskPct,
      detail: `${diskPath} ${pct}% used`,
    };
  };

  const redisMem = async (): Promise<CheckResult> => {
    const info = await deps.redisInfo("memory");
    const used = Number(info.used_memory);
    const max = Number(info.maxmemory);
    if (!Number.isFinite(used) || !Number.isFinite(max) || max <= 0) {
      // maxmemory=0 means "unbounded" in redis: no ratio to check. Loud in
      // the detail, never a divide-by-zero and never a false alarm.
      return {
        name: "redis-mem-80",
        ok: true,
        value: 0,
        threshold: thresholds.redisMemPct,
        detail: `maxmemory not set (used_memory=${String(info.used_memory ?? "?")})`,
      };
    }
    const pct = round2((used / max) * 100);
    return {
      name: "redis-mem-80",
      ok: pct <= thresholds.redisMemPct,
      value: pct,
      threshold: thresholds.redisMemPct,
      detail: `used ${used}/${max} bytes (${pct}%)`,
    };
  };

  const spend = async (): Promise<CheckResult> => {
    if (!spendParity) {
      return {
        name: "spend-parity",
        ok: true,
        value: 0,
        threshold: thresholds.spendDriftCents,
        detail: "disabled by WATCH_SPEND_PARITY=off",
      };
    }
    if (deps.mintSpendCents === undefined) {
      return {
        name: "spend-parity",
        ok: false,
        value: 0,
        threshold: thresholds.spendDriftCents,
        detail: "mint ledger seam not wired (set REDIS_MINT_URL and keep WATCH_SPEND_PARITY=on)",
      };
    }

    const since = startOfUtcDay(deps.now()).toISOString();
    const [mintRows, litellmRows] = await Promise.all([
      deps.mintSpendCents(),
      deps.sql<{ uid?: unknown; cents?: unknown }>(liteLlmSpendSql(since)),
    ]);

    const mint = new Map<string, number>();
    for (const row of mintRows) {
      const cents = Number(row.cents);
      if (row.uid !== "" && Number.isFinite(cents)) mint.set(row.uid, cents);
    }
    const litellm = new Map<string, number>();
    for (const row of litellmRows) {
      const uid = typeof row.uid === "string" ? row.uid : String(row.uid ?? "");
      const cents = Number(row.cents);
      if (uid !== "" && Number.isFinite(cents)) litellm.set(uid, cents);
    }

    const uids = new Set<string>([...mint.keys(), ...litellm.keys()]);
    if (uids.size === 0) {
      return {
        name: "spend-parity",
        ok: true,
        value: 0,
        threshold: thresholds.spendDriftCents,
        detail: "no spend recorded today",
      };
    }

    let worst = {
      uid: "",
      drift: 0,
      threshold: thresholds.spendDriftCents,
      mintCents: 0,
      litellmCents: 0,
    };
    for (const uid of uids) {
      const mintCents = mint.get(uid) ?? 0;
      const litellmCents = litellm.get(uid) ?? 0;
      const drift = Math.abs(mintCents - litellmCents);
      const limit = Math.max(
        thresholds.spendDriftCents,
        Math.ceil((mintCents * thresholds.spendDriftPct) / 100),
      );
      if (drift > worst.drift) {
        worst = { uid, drift, threshold: limit, mintCents, litellmCents };
      }
    }

    return {
      name: "spend-parity",
      ok: worst.drift <= worst.threshold,
      value: worst.drift,
      threshold: worst.threshold,
      detail: `${worst.uid}: mint ${worst.mintCents}¢ vs litellm ${worst.litellmCents}¢ (drift ${worst.drift}¢, limit ${worst.threshold}¢)`,
    };
  };

  const operational = async (
    name: "anomaly-enforcement" | "suspension-mail" | "reservation-reconciliation" | "notification-delivery",
    field: "anomaly" | "mail" | "reservation" | "notification",
  ): Promise<CheckResult> => {
    try {
      const body = (await healthPayload) as { checks?: unknown } | null;
      const rawChecks = typeof body === "object" && body !== null && !Array.isArray(body)
        ? body.checks
        : undefined;
      const value = typeof rawChecks === "object" && rawChecks !== null && !Array.isArray(rawChecks)
        ? (rawChecks as Record<string, unknown>)[field]
        : undefined;
      const ok = value === true;
      return {
        name,
        ok,
        value: ok ? 1 : 0,
        threshold: 1,
        detail: `${field} ${ok ? "healthy" : value === false ? "degraded" : "unknown"}`,
      };
    } catch {
      return {
        name,
        ok: false,
        value: 0,
        threshold: 1,
        detail: `${field} unknown: health payload unavailable`,
      };
    }
  };

  const checks: Array<[CheckName, () => Promise<CheckResult>]> = [
    ["gateway-health", gatewayHealth],
    ["queue-depth", queueDepth],
    ["worker-lag", workerLag],
    ["disk-80", disk],
    ["redis-mem-80", redisMem],
    ["spend-parity", spend],
    ["anomaly-enforcement", () => operational("anomaly-enforcement", "anomaly")],
    ["suspension-mail", () => operational("suspension-mail", "mail")],
    ["reservation-reconciliation", () => operational("reservation-reconciliation", "reservation")],
    ["notification-delivery", () => operational("notification-delivery", "notification")],
  ];

  const results: CheckResult[] = [];
  for (const [name, run] of checks) {
    try {
      results.push(await run());
    } catch (err) {
      // One broken backend must not blind the other five checks.
      results.push({
        name,
        ok: false,
        value: 0,
        threshold: thresholdsFor(name, thresholds),
        detail: `error: ${errorMessage(err)}`,
      });
    }
  }
  return results;
}

function thresholdsFor(name: CheckName, t: WatchThresholds): number {
  switch (name) {
    case "gateway-health":
      return 1;
    case "queue-depth":
      return t.queueWaiting;
    case "worker-lag":
      return t.workerLagS;
    case "disk-80":
      return t.diskPct;
    case "redis-mem-80":
      return t.redisMemPct;
    case "spend-parity":
      return t.spendDriftCents;
    case "anomaly-enforcement":
    case "suspension-mail":
    case "reservation-reconciliation":
    case "notification-delivery":
      return 1;
  }
}
