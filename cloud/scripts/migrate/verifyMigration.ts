/**
 * Task 18 — dual-run verification (installed base) / settings-only
 * verification (clean break).
 *
 * EXECUTION IS OWNER-GATED (DECOMMISSION.md Step 3). Read-only: it never
 * writes Postgres/Redis and never submits a paid request. `/usage` is a
 * read-only POST that requires a real Firebase ID token per uid — the owner
 * supplies a tokens file captured from app sessions. Tokens are never logged.
 *
 * Installed base (zero mismatches REQUIRED before any Caddy flip):
 *   - config:limits + config:base_daily_usd field-by-field (Postgres ↔ Redis)
 *   - row-count parity: image_jobs by state, tombstones, shares, forks
 *   - pending/unknown reservation parity (exact strings, unresolved money)
 *   - sampled receipt equality (exact reserved/charged/actual strings)
 *   - shares lifetime counts per owner (all rows, incl. revoked/expired)
 *   - /usage body equality for N sampled uids (Python :8090 vs TS :8091)
 *
 * Clean break (settings-only):
 *   - config:limits + /plans equality
 *   - /usage SHAPE equality for one synthetic user (key sets + value types)
 *
 * Usage:
 *   node --experimental-strip-types cloud/scripts/migrate/verifyMigration.ts \
 *     --mode installed-base --images-sqlite … --shares-sqlite … \
 *     --tokens /secure/usage-tokens.json [--usage-sample 20]
 *   node --experimental-strip-types cloud/scripts/migrate/verifyMigration.ts \
 *     --mode clean-break [--tokens …] [--usage-shape]
 */

import { readFileSync } from "node:fs";
import { getSettings } from "../../apps/mint/dist/settings.js";
import { serializeSettings, type Settings } from "../../apps/mint/dist/planMath.js";
import { readSourceRows } from "./importImagesLedger.js";
import { readSharesSource } from "./importSharesSqlite.js";
import {
  argValue,
  closeDb,
  hasFlag,
  isMain,
  ok,
  openDb,
  openRedis,
  ovidDb,
  requiredSetting,
  type DbHandle,
  type RedisLike,
} from "./runtime.js";

export const DB2_LIMITS_HASH = "config:limits";
export const DB2_BASE_BUDGET_KEY = "config:base_daily_usd";

export interface CheckResult {
  name: string;
  ok: boolean;
  detail: string;
}

export interface VerifyReport {
  ok: boolean;
  mode: "installed-base" | "clean-break";
  checks: CheckResult[];
}

type Json = unknown;

/** Deterministic JSON (sorted object keys) for structural equality. */
export function canonicalJson(value: Json): string {
  const walk = (v: Json): Json => {
    if (Array.isArray(v)) return v.map(walk);
    if (typeof v === "object" && v !== null) {
      const out: Record<string, Json> = {};
      for (const key of Object.keys(v as Record<string, Json>).sort()) {
        out[key] = walk((v as Record<string, Json>)[key]);
      }
      return out;
    }
    return v;
  };
  return JSON.stringify(walk(value));
}

export function jsonEqual(a: Json, b: Json): boolean {
  return canonicalJson(a) === canonicalJson(b);
}

/** First differing path (for a useful failure detail), or null. */
export function firstDiff(a: Json, b: Json, path = "$"): string | null {
  if (a === b) return null;
  if (typeof a !== typeof b) return `${path}: type ${typeof a} ≠ ${typeof b}`;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b)) return `${path}: array vs non-array`;
    if (a.length !== b.length) return `${path}: length ${a.length} ≠ ${b.length}`;
    for (let i = 0; i < a.length; i++) {
      const diff = firstDiff(a[i], b[i], `${path}[${i}]`);
      if (diff !== null) return diff;
    }
    return null;
  }
  if (typeof a === "object" && a !== null && b !== null) {
    const ao = a as Record<string, Json>;
    const bo = b as Record<string, Json>;
    const keys = new Set([...Object.keys(ao), ...Object.keys(bo)]);
    for (const key of [...keys].sort()) {
      if (!(key in ao)) return `${path}.${key}: missing on left`;
      if (!(key in bo)) return `${path}.${key}: missing on right`;
      const diff = firstDiff(ao[key], bo[key], `${path}.${key}`);
      if (diff !== null) return diff;
    }
    return null;
  }
  return `${path}: ${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`;
}

export interface VerifyDeps {
  db: DbHandle;
  redis: RedisLike;
  fetchImpl?: typeof fetch;
  pythonBase?: string;
  tsBase?: string;
  imagesSqlite?: string;
  sharesSqlite?: string;
  tokens?: Record<string, string>;
  usageSample?: number;
  usageShape?: boolean;
  skipUsage?: boolean;
  now?: number;
}

function check(name: string, failures: string[]): CheckResult {
  return failures.length === 0
    ? { name, ok: true, detail: "match" }
    : { name, ok: false, detail: failures.slice(0, 10).join("; ") };
}

function sample<T>(rows: T[], limit: number): T[] {
  if (rows.length <= limit) return rows;
  const step = Math.ceil(rows.length / limit);
  const out: T[] = [];
  for (let i = 0; i < rows.length && out.length < limit; i += step) out.push(rows[i]!);
  return out;
}

async function checkSettings(deps: VerifyDeps): Promise<CheckResult> {
  const failures: string[] = [];
  const settings = (await getSettings({ db: deps.db })) as Settings;
  const { baseDaily, fields } = serializeSettings(settings);
  const hash = await deps.redis.hgetall(DB2_LIMITS_HASH);
  const base = await deps.redis.get(DB2_BASE_BUDGET_KEY);

  if (base !== baseDaily) {
    failures.push(`${DB2_BASE_BUDGET_KEY}: redis=${JSON.stringify(base)} pg=${JSON.stringify(baseDaily)}`);
  }
  for (const [key, value] of Object.entries(fields)) {
    const redisValue = hash[key];
    if (redisValue === undefined) {
      failures.push(`${DB2_LIMITS_HASH}.${key}: missing in redis`);
      continue;
    }
    if (key === "plans" || key === "auto_oss_members") {
      try {
        if (!jsonEqual(JSON.parse(redisValue), JSON.parse(value))) {
          failures.push(
            `${DB2_LIMITS_HASH}.${key}: ${firstDiff(JSON.parse(value), JSON.parse(redisValue))}`,
          );
        }
      } catch {
        failures.push(`${DB2_LIMITS_HASH}.${key}: unparseable JSON on one side`);
      }
    } else if (redisValue !== value) {
      failures.push(
        `${DB2_LIMITS_HASH}.${key}: redis=${JSON.stringify(redisValue)} pg=${JSON.stringify(value)}`,
      );
    }
  }
  for (const key of Object.keys(hash)) {
    if (!(key in fields)) failures.push(`${DB2_LIMITS_HASH}.${key}: unknown redis field`);
  }
  return check("settings (config:limits + base_daily_usd)", failures);
}

interface PlansBody {
  plans?: unknown;
}

async function fetchJson(
  deps: VerifyDeps,
  url: string,
  init?: RequestInit,
): Promise<{ status: number; body: unknown }> {
  const fetchImpl = deps.fetchImpl ?? fetch;
  const response = await fetchImpl(url, init);
  const text = await response.text();
  let body: unknown = null;
  try {
    body = text === "" ? null : JSON.parse(text);
  } catch {
    body = text;
  }
  return { status: response.status, body };
}

async function checkPlans(deps: VerifyDeps): Promise<CheckResult> {
  const failures: string[] = [];
  const python = await fetchJson(deps, `${deps.pythonBase ?? "http://127.0.0.1:8090"}/plans`);
  const ts = await fetchJson(deps, `${deps.tsBase ?? "http://127.0.0.1:8091"}/plans`);
  if (python.status !== 200) failures.push(`python /plans status ${python.status}`);
  if (ts.status !== 200) failures.push(`ts /plans status ${ts.status}`);
  if (failures.length === 0) {
    const sortPlans = (body: unknown): unknown => {
      const plans = (body as PlansBody | null)?.plans;
      if (!Array.isArray(plans)) return body;
      return {
        plans: [...plans].sort((a, b) =>
          String((a as { id?: unknown }).id).localeCompare(String((b as { id?: unknown }).id)),
        ),
      };
    };
    const diff = firstDiff(sortPlans(python.body), sortPlans(ts.body));
    if (diff !== null) failures.push(diff);
  }
  return check("/plans", failures);
}

async function checkImages(deps: VerifyDeps): Promise<CheckResult[]> {
  if (deps.imagesSqlite === undefined) return [];
  const failures: string[] = [];
  const reservationFailures: string[] = [];
  const now = deps.now ?? Math.floor(Date.now() / 1000);
  const source = readSourceRows(deps.imagesSqlite, now);

  const sourceByState: Record<string, number> = {};
  for (const row of source.rows) {
    sourceByState[row.state] = (sourceByState[row.state] ?? 0) + 1;
  }
  const pgByState = await ovidDb.imageJobsRepo.countByState(deps.db);
  for (const state of new Set([...Object.keys(sourceByState), ...Object.keys(pgByState)])) {
    if ((sourceByState[state] ?? 0) !== (pgByState[state] ?? 0)) {
      failures.push(`image_jobs.${state}: sqlite=${sourceByState[state] ?? 0} pg=${pgByState[state] ?? 0}`);
    }
  }

  const [pgTombstones] = await deps.db.$client`
    SELECT count(*)::int AS n FROM image_deleted_accounts`;
  if (Number(pgTombstones?.n ?? -1) !== source.tombstones.length) {
    failures.push(
      `image_deleted_accounts: sqlite=${source.tombstones.length} pg=${String(pgTombstones?.n)}`,
    );
  }

  // Sampled row equality — exact money strings are load-bearing.
  const sampled = sample(source.rows, 200);
  const rows = await deps.db.$client`
    SELECT account, request, fingerprint, state, reserved, charged, actual,
           response, served_model, budget_window, replay_until, receipt_until, created_at
    FROM image_jobs ORDER BY account, request`;
  const pg = new Map(
    (rows as Array<Record<string, unknown>>).map((row) => [
      `${String(row.account)}\u0000${String(row.request)}`,
      row,
    ]),
  );
  for (const row of sampled) {
    const other = pg.get(`${row.account}\u0000${row.request}`);
    if (other === undefined) {
      failures.push(`image ${row.account}/${row.request}: missing in pg`);
      continue;
    }
    for (const field of ["fingerprint", "state", "reserved", "charged", "budget_window"]) {
      if (String(other[field]) !== String(row[field as keyof typeof row])) {
        failures.push(
          `image ${row.account}/${row.request}.${field}: ${JSON.stringify(other[field])} ≠ ${JSON.stringify(row[field as keyof typeof row])}`,
        );
      }
    }
    const actualPg = other.actual === null ? null : String(other.actual);
    if (actualPg !== row.actual) {
      failures.push(`image ${row.account}/${row.request}.actual: ${JSON.stringify(actualPg)} ≠ ${JSON.stringify(row.actual)}`);
    }
    if (!jsonEqual(other.response ?? null, row.response ?? null)) {
      failures.push(`image ${row.account}/${row.request}.response differs`);
    }
    if (String(other.served_model ?? "") !== String(row.served_model ?? "")) {
      failures.push(`image ${row.account}/${row.request}.served_model differs`);
    }
    for (const field of ["replay_until", "receipt_until", "created_at"] as const) {
      const pgValue = other[field] === null || other[field] === undefined
        ? null
        : Number(other[field]);
      const sourceValue = row[field];
      if (pgValue !== sourceValue) {
        failures.push(
          `image ${row.account}/${row.request}.${field}: pg=${String(pgValue)} sqlite=${String(sourceValue)}`,
        );
      }
    }
  }

  // Tombstone values must match, not just their count.
  const pgTombstoneRows = (await deps.db.$client`
    SELECT account, deleted_at FROM image_deleted_accounts ORDER BY account`) as Array<{
    account: string;
    deleted_at: number;
  }>;
  const pgTombstoneMap = new Map(
    pgTombstoneRows.map((row) => [String(row.account), Number(row.deleted_at)]),
  );
  for (const tombstone of source.tombstones) {
    if (pgTombstoneMap.get(tombstone.account) !== tombstone.deleted_at) {
      failures.push(
        `tombstone ${tombstone.account}: pg=${String(pgTombstoneMap.get(tombstone.account))} sqlite=${tombstone.deleted_at}`,
      );
    }
  }

  // Unresolved reservations are money: count AND exact strings must match.
  const unresolved = source.rows.filter((r) => r.state === "pending" || r.state === "unknown");
  const pgUnresolved = (rows as Array<Record<string, unknown>>).filter(
    (r) => r.state === "pending" || r.state === "unknown",
  );
  if (unresolved.length !== pgUnresolved.length) {
    reservationFailures.push(
      `unresolved rows: sqlite=${unresolved.length} pg=${pgUnresolved.length}`,
    );
  }
  const pgUnresolvedMap = new Map(
    pgUnresolved.map((r) => [`${String(r.account)}\u0000${String(r.request)}`, String(r.reserved)]),
  );
  for (const row of unresolved) {
    const reserved = pgUnresolvedMap.get(`${row.account}\u0000${row.request}`);
    if (reserved !== row.reserved) {
      reservationFailures.push(
        `unresolved ${row.account}/${row.request}: reserved pg=${JSON.stringify(reserved)} sqlite=${JSON.stringify(row.reserved)}`,
      );
    }
  }

  return [
    check("images: row counts + tombstones + sampled rows", failures),
    check("images: unresolved reservations (exact)", reservationFailures),
  ];
}

async function checkShares(deps: VerifyDeps): Promise<CheckResult[]> {
  if (deps.sharesSqlite === undefined) return [];
  const failures: string[] = [];
  const lifetimeFailures: string[] = [];
  const now = deps.now ?? Date.now();
  const source = readSharesSource(deps.sharesSqlite, now);

  const [pgCounts] = await deps.db.$client`
    SELECT count(*)::int AS n,
           count(*) FILTER (WHERE revoked_at IS NOT NULL)::int AS revoked
    FROM shares`;
  if (Number(pgCounts?.n ?? -1) !== source.shares.length) {
    failures.push(`shares: sqlite=${source.shares.length} pg=${String(pgCounts?.n)}`);
  }
  if (Number(pgCounts?.revoked ?? -1) !== source.shares.filter((s) => s.revokedAt !== null).length) {
    failures.push(
      `revoked shares: sqlite=${source.shares.filter((s) => s.revokedAt !== null).length} pg=${String(pgCounts?.revoked)}`,
    );
  }
  const [pgForks] = await deps.db.$client`SELECT count(*)::int AS n FROM share_forks`;
  if (Number(pgForks?.n ?? -1) !== source.forks.length) {
    failures.push(`share_forks: sqlite=${source.forks.length} pg=${String(pgForks?.n)}`);
  }
  for (const uid of source.deletedAccounts) {
    if (source.shares.some((s) => s.ownerUid === uid)) {
      failures.push(`deleted uid ${uid} still has source share rows`);
    }
  }

  // Lifetime quota parity per owner (all rows, incl. revoked/expired).
  const sourceLifetime = new Map<string, number>();
  for (const share of source.shares) {
    sourceLifetime.set(share.ownerUid, (sourceLifetime.get(share.ownerUid) ?? 0) + 1);
  }
  const pgLifetimeRows = (await deps.db.$client`
    SELECT owner_uid, count(*)::int AS n FROM shares GROUP BY owner_uid`) as Array<{
    owner_uid: string;
    n: number;
  }>;
  const pgLifetime = new Map(pgLifetimeRows.map((r) => [String(r.owner_uid), Number(r.n)]));
  for (const uid of new Set([...sourceLifetime.keys(), ...pgLifetime.keys()])) {
    if ((sourceLifetime.get(uid) ?? 0) !== (pgLifetime.get(uid) ?? 0)) {
      lifetimeFailures.push(
        `uid ${uid}: sqlite=${sourceLifetime.get(uid) ?? 0} pg=${pgLifetime.get(uid) ?? 0}`,
      );
    }
  }

  // Sampled receipt equality (exact content + timestamps).
  const sampled = sample(source.shares, 200);
  const pgRows = (await deps.db.$client`
    SELECT token, owner_uid, session_id, request_id, content, message_count,
           created_at, expires_at, revoked_at
    FROM shares ORDER BY owner_uid, request_id, token`) as Array<Record<string, unknown>>;
  const pg = new Map(pgRows.map((row) => [String(row.token), row]));
  for (const share of sampled) {
    const other = pg.get(share.token);
    if (other === undefined) {
      failures.push(`share ${share.token}: missing in pg`);
      continue;
    }
    if (
      String(other.owner_uid) !== share.ownerUid ||
      String(other.session_id) !== share.sessionId ||
      String(other.request_id) !== share.requestId ||
      Number(other.message_count) !== share.messageCount
    ) {
      failures.push(`share ${share.token}: identity/message_count differs`);
    }
    if (new Date(String(other.created_at)).getTime() !== share.createdAt) {
      failures.push(`share ${share.token}.created_at differs`);
    }
    if (new Date(String(other.expires_at)).getTime() !== share.expiresAt) {
      failures.push(`share ${share.token}.expires_at differs`);
    }
    if ((other.revoked_at === null) !== (share.revokedAt === null)) {
      failures.push(`share ${share.token}.revoked_at presence differs`);
    }
    const content = other.content === null ? null : JSON.parse(String(other.content));
    if (!jsonEqual(content, share.content)) {
      failures.push(`share ${share.token}.content differs`);
    }
  }

  return [
    check("shares: counts + sampled receipts", failures),
    check("shares: lifetime counts per owner", lifetimeFailures),
  ];
}

async function postUsage(
  deps: VerifyDeps,
  base: string,
  token: string,
): Promise<{ status: number; body: unknown }> {
  return fetchJson(deps, `${base}/usage`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: "{}",
  });
}

async function checkUsage(deps: VerifyDeps, shapeOnly: boolean): Promise<CheckResult> {
  const failures: string[] = [];
  const tokens = deps.tokens ?? {};
  const uids = Object.keys(tokens).sort();
  if (uids.length === 0) {
    return {
      name: "/usage equality",
      ok: false,
      detail:
        "no tokens supplied — pass --tokens <json> (uid → Firebase ID token); a missing token is a FAILURE, never a silent skip",
    };
  }
  const selected = uids.slice(0, Math.max(1, deps.usageSample ?? 20));
  const pythonBase = deps.pythonBase ?? "http://127.0.0.1:8090";
  const tsBase = deps.tsBase ?? "http://127.0.0.1:8091";
  for (const uid of selected) {
    const [python, ts] = await Promise.all([
      postUsage(deps, pythonBase, tokens[uid]!),
      postUsage(deps, tsBase, tokens[uid]!),
    ]);
    if (python.status !== 200 || ts.status !== 200) {
      failures.push(`uid ${uid}: python=${python.status} ts=${ts.status}`);
      continue;
    }
    if (shapeOnly) {
      const shape = (value: unknown): unknown => {
        if (Array.isArray(value)) return value.length === 0 ? [] : [shape(value[0])];
        if (typeof value === "object" && value !== null) {
          const out: Record<string, unknown> = {};
          for (const key of Object.keys(value as Record<string, unknown>).sort()) {
            out[key] = shape((value as Record<string, unknown>)[key]);
          }
          return out;
        }
        return typeof value;
      };
      const diff = firstDiff(shape(python.body), shape(ts.body));
      if (diff !== null) failures.push(`uid ${uid} shape: ${diff}`);
    } else {
      const diff = firstDiff(python.body, ts.body);
      if (diff !== null) failures.push(`uid ${uid}: ${diff}`);
    }
  }
  return check(shapeOnly ? "/usage shape" : "/usage equality", failures);
}

export async function verifyMigration(
  mode: "installed-base" | "clean-break",
  deps: VerifyDeps,
): Promise<VerifyReport> {
  const checks: CheckResult[] = [];
  checks.push(await checkSettings(deps));
  checks.push(await checkPlans(deps));

  if (mode === "installed-base") {
    checks.push(...(await checkImages(deps)));
    checks.push(...(await checkShares(deps)));
    checks.push(await checkUsage(deps, false));
    if (deps.imagesSqlite === undefined) {
      checks.push({
        name: "images source supplied",
        ok: false,
        detail: "installed-base verification requires --images-sqlite",
      });
    }
    if (deps.sharesSqlite === undefined) {
      checks.push({
        name: "shares source supplied",
        ok: false,
        detail: "installed-base verification requires --shares-sqlite",
      });
    }
  } else {
    if (deps.skipUsage === true) {
      checks.push({
        name: "/usage shape",
        ok: true,
        detail: "SKIPPED by owner (--skip-usage) — record this in the activation ledger",
      });
    } else {
      checks.push(await checkUsage(deps, true));
    }
  }

  return { ok: checks.every((c) => c.ok), mode, checks };
}

export function formatReport(report: VerifyReport): string[] {
  const lines = [`[verifyMigration] mode=${report.mode}`];
  for (const c of report.checks) {
    lines.push(`  ${c.ok ? "PASS" : "FAIL"}  ${c.name}${c.ok ? "" : ` — ${c.detail}`}`);
  }
  lines.push(report.ok ? "RESULT: zero mismatches" : "RESULT: MISMATCHES — do not flip");
  return lines;
}

function readTokens(path: string | undefined): Record<string, string> {
  if (path === undefined) return {};
  const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("--tokens must be a JSON object mapping uid → Firebase ID token");
  }
  const out: Record<string, string> = {};
  for (const [uid, token] of Object.entries(parsed as Record<string, unknown>)) {
    if (typeof token !== "string" || token === "") {
      throw new Error(`--tokens: uid ${uid} must map to a non-empty string`);
    }
    out[uid] = token;
  }
  return out;
}

async function cli(): Promise<void> {
  const argv = process.argv.slice(2);
  const modeRaw = argValue(argv, "--mode") ?? "installed-base";
  if (modeRaw !== "installed-base" && modeRaw !== "clean-break") {
    throw new Error("--mode must be installed-base or clean-break");
  }
  const mode = modeRaw;
  const databaseUrl = requiredSetting(argv, "--database-url", "DATABASE_URL");
  const redisUrl = requiredSetting(argv, "--redis-url", "REDIS_DB2_URL");

  const db = openDb(databaseUrl);
  const redis = openRedis(redisUrl);
  try {
    const report = await verifyMigration(mode, {
      db,
      redis,
      imagesSqlite: argValue(argv, "--images-sqlite"),
      sharesSqlite: argValue(argv, "--shares-sqlite"),
      pythonBase: argValue(argv, "--python-base") ?? "http://127.0.0.1:8090",
      tsBase: argValue(argv, "--ts-base") ?? "http://127.0.0.1:8091",
      tokens: readTokens(argValue(argv, "--tokens")),
      usageSample: Number(argValue(argv, "--usage-sample") ?? (mode === "installed-base" ? 20 : 1)),
      usageShape: hasFlag(argv, "--usage-shape") || mode === "clean-break",
      skipUsage: mode === "clean-break" && hasFlag(argv, "--skip-usage"),
    });
    for (const row of formatReport(report)) console.log(row);
    if (!report.ok) process.exitCode = 1;
    else ok("migration verification passed");
  } finally {
    redis.disconnect();
    await closeDb(db);
  }
}

if (isMain(import.meta.url)) {
  cli().catch((err) => {
    console.error(`[verifyMigration] FAILED: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  });
}
