/**
 * Task 18 — installed-base import #2: Python images SQLite → Postgres.
 *
 * EXECUTION IS OWNER-GATED (DECOMMISSION.md Step 3 / Q1 "installed base").
 * The owner MUST drain/stop the Python image workers before running this
 * (`--drained` is required): importing a live SQLite file can miss rows that
 * commit between the read and the flip.
 *
 * Money fidelity (the whole point):
 *   - `reserved`, `charged`, `actual` cross the boundary as the EXACT source
 *     strings — no Number(), no float, no canonicalization.
 *   - `pending`/`unknown` rows keep their reservations; an unresolved row is
 *     NEVER converted to `failed` and never expires.
 *   - replay/receipt deadlines are preserved; rows imported from a pre-upgrade
 *     schema (no replay_until/receipt_until columns) follow the Python
 *     coordinated-upgrade rule: legacy response blobs are dropped (no new
 *     replay lease) and done/failed receipts get now+90d. Pending/unknown
 *     stay unresolved.
 *   - tombstones are copied verbatim (deleted_at).
 *
 * Inserts are insert-if-absent (ON CONFLICT DO NOTHING) — re-running is safe
 * and can never rewrite a charge.
 *
 * Usage:
 *   node --experimental-strip-types cloud/scripts/migrate/importImagesLedger.ts \
 *     --sqlite /opt/ovid-gateway/images/images.sqlite3 --drained \
 *     [--database-url postgres://…] [--dry-run]
 */

// `node:sqlite` is a Node builtin that Vite 5's static external list does not
// know. Load it through createRequire so the vitest suite can import this
// module without Vite trying to bundle `sqlite`.
import { createRequire } from "node:module";
type DatabaseSync = import("node:sqlite").DatabaseSync;
const { DatabaseSync: DatabaseSyncCtor } = createRequire(import.meta.url)(
  "node:sqlite",
) as typeof import("node:sqlite");
import {
  closeDb,
  hasFlag,
  isMain,
  line,
  ok,
  openDb,
  ovidDb,
  requiredSetting,
  type DbHandle,
} from "./runtime.js";

export const REPLAY_RETENTION = 24 * 86_400;
export const RECEIPT_RETENTION = 90 * 86_400;
export const IMAGE_STATES = new Set(["pending", "unknown", "done", "failed"]);

export interface SourceImageRow {
  account: string;
  request: string;
  fingerprint: string;
  state: string;
  reserved: string;
  charged: string;
  actual: string | null;
  response: unknown;
  budget_window: string;
  served_model: string | null;
  replay_until: number | null;
  receipt_until: number | null;
  created_at: number;
}

export interface ImportImagesReport {
  rows: number;
  byState: Record<string, number>;
  tombstones: number;
  unresolved: Array<{ account: string; request: string; state: string; reserved: string }>;
  legacyRowsWithoutLeases: number;
}

function hasColumn(columns: Set<string>, name: string): boolean {
  return columns.has(name);
}

function str(value: unknown, field: string, account: string, request: string): string {
  if (typeof value !== "string") {
    throw new Error(
      `image row ${account}/${request}: ${field} must be a string, got ${typeof value}`,
    );
  }
  return value;
}

function nullableStr(value: unknown): string | null {
  return typeof value === "string" ? value : value === null || value === undefined ? null : String(value);
}

function nullableInt(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) ? Math.trunc(n) : null;
}

/**
 * Map one SQLite row to the Postgres raw-row shape. Pure and exported so the
 * unit tests can pin every money/lease rule without a database.
 */
export function mapSourceRow(
  raw: Record<string, unknown>,
  columns: Set<string>,
  now: number,
): SourceImageRow {
  const account = str(raw.account, "account", "?", "?");
  const request = str(raw.request, "request", account, "?");
  const state = str(raw.state, "state", account, request);
  if (!IMAGE_STATES.has(state)) {
    throw new Error(`image row ${account}/${request}: unknown state ${JSON.stringify(state)}`);
  }
  const reserved = str(raw.reserved, "reserved", account, request);
  const charged = raw.charged === null || raw.charged === undefined
    ? "0"
    : str(raw.charged, "charged", account, request);
  const actual = raw.actual === null || raw.actual === undefined
    ? null
    : str(raw.actual, "actual", account, request);
  const budgetWindow = str(raw.budget_window, "budget_window", account, request);
  const fingerprint = str(raw.fingerprint, "fingerprint", account, request);

  const hasLeaseColumns =
    hasColumn(columns, "replay_until") && hasColumn(columns, "receipt_until");
  let replayUntil = hasLeaseColumns ? nullableInt(raw.replay_until) : null;
  let receiptUntil = hasLeaseColumns ? nullableInt(raw.receipt_until) : null;
  let response: unknown = null;
  let legacyRowsWithoutLeases = 0;

  if (hasLeaseColumns) {
    if (raw.response !== null && raw.response !== undefined && raw.response !== "") {
      try {
        response = JSON.parse(str(raw.response, "response", account, request));
      } catch {
        throw new Error(
          `image row ${account}/${request}: response is not valid JSON — refusing to import a lossy replay blob`,
        );
      }
    }
  } else {
    // Python's coordinated-upgrade branch: legacy blobs have no creation time,
    // so they get NO replay lease; completed receipts keep 90 days from now.
    legacyRowsWithoutLeases++;
    if (state === "done" || state === "failed") {
      replayUntil = 0;
      receiptUntil = now + RECEIPT_RETENTION;
    }
  }

  // createdAt is not in the Python schema. Reconstruct the most conservative
  // bound from the retention leases; unresolved rows get the import time (they
  // never expire and their reservation is preserved regardless).
  let createdAt: number;
  if (receiptUntil !== null && receiptUntil > 0) {
    createdAt = Math.max(0, receiptUntil - RECEIPT_RETENTION);
  } else if (replayUntil !== null && replayUntil > 0) {
    createdAt = Math.max(0, replayUntil - REPLAY_RETENTION);
  } else {
    createdAt = now;
  }

  return {
    account,
    request,
    fingerprint,
    state,
    reserved,
    charged,
    actual,
    response,
    budget_window: budgetWindow,
    served_model: hasColumn(columns, "served_model")
      ? nullableStr(raw.served_model)
      : null,
    replay_until: replayUntil,
    receipt_until: receiptUntil,
    created_at: createdAt,
  };
}

function readColumns(sqlite: DatabaseSync, table: string): Set<string> {
  const rows = sqlite.prepare(`PRAGMA table_info(${table})`).all() as Array<{
    name: string;
  }>;
  return new Set(rows.map((row) => row.name));
}

export function readSourceRows(
  sqlitePath: string,
  now: number,
): { rows: SourceImageRow[]; tombstones: Array<{ account: string; deleted_at: number }>; legacy: number } {
  const sqlite = new DatabaseSyncCtor(sqlitePath, { readOnly: true });
  try {
    const jobColumns = readColumns(sqlite, "image_jobs");
    const rawRows = sqlite
      .prepare("SELECT * FROM image_jobs ORDER BY account, request")
      .all() as Array<Record<string, unknown>>;
    let legacy = 0;
    const rows = rawRows.map((raw) => {
      const mapped = mapSourceRow(raw, jobColumns, now);
      if (!jobColumns.has("replay_until")) legacy++;
      return mapped;
    });

    const tombstoneColumns = readColumns(sqlite, "image_deleted_accounts");
    if (!tombstoneColumns.has("account") || !tombstoneColumns.has("deleted_at")) {
      throw new Error("image_deleted_accounts must have account + deleted_at columns");
    }
    const tombstones = (
      sqlite
        .prepare("SELECT account, deleted_at FROM image_deleted_accounts ORDER BY account")
        .all() as Array<{ account: string; deleted_at: number }>
    ).map((row) => ({ account: row.account, deleted_at: Math.trunc(row.deleted_at) }));
    return { rows, tombstones, legacy };
  } finally {
    sqlite.close();
  }
}

export async function importImagesLedger(deps: {
  db: DbHandle;
  sqlitePath: string;
  now?: number;
  drained: boolean;
  dryRun?: boolean;
}): Promise<ImportImagesReport> {
  if (!deps.drained) {
    throw new Error(
      "refusing to import: drain/stop the Python image workers first, then pass --drained",
    );
  }
  const now = deps.now ?? Math.floor(Date.now() / 1000);
  const { rows, tombstones, legacy } = readSourceRows(deps.sqlitePath, now);

  const byState: Record<string, number> = {};
  const unresolved: ImportImagesReport["unresolved"] = [];
  for (const row of rows) {
    byState[row.state] = (byState[row.state] ?? 0) + 1;
    if (row.state === "pending" || row.state === "unknown") {
      unresolved.push({
        account: row.account,
        request: row.request,
        state: row.state,
        reserved: row.reserved,
      });
    }
  }

  if (deps.dryRun !== true) {
    for (const row of rows) {
      await ovidDb.imageJobsRepo.insertRaw(deps.db, {
        account: row.account,
        request: row.request,
        fingerprint: row.fingerprint,
        state: row.state,
        reserved: row.reserved,
        charged: row.charged,
        actual: row.actual,
        response: row.response,
        servedModel: row.served_model,
        budgetWindow: row.budget_window,
        replayUntil: row.replay_until,
        receiptUntil: row.receipt_until,
        createdAt: row.created_at,
      });
    }
    for (const tombstone of tombstones) {
      await ovidDb.imageJobsRepo.insertDeletedAccountRaw(
        deps.db,
        tombstone.account,
        tombstone.deleted_at,
      );
    }
  }

  return {
    rows: rows.length,
    byState,
    tombstones: tombstones.length,
    unresolved,
    legacyRowsWithoutLeases: legacy,
  };
}

export function formatReport(report: ImportImagesReport): string[] {
  return [
    line("rows read", report.rows),
    line("by state", JSON.stringify(report.byState)),
    line("tombstones", report.tombstones),
    line("unresolved reservations", report.unresolved.length),
    line("legacy rows without leases", report.legacyRowsWithoutLeases),
    ...report.unresolved.map(
      (row) =>
        `  ${row.state.padEnd(7)} ${row.account}/${row.request} reserved=${row.reserved}`,
    ),
  ];
}

async function cli(): Promise<void> {
  const argv = process.argv.slice(2);
  const sqlitePath = requiredSetting(argv, "--sqlite", "IMAGES_SQLITE_PATH");
  const databaseUrl = requiredSetting(argv, "--database-url", "DATABASE_URL");
  const drained = hasFlag(argv, "--drained");
  const dryRun = hasFlag(argv, "--dry-run");
  if (!drained) {
    throw new Error(
      "refusing to import: drain/stop the Python image workers first, then pass --drained",
    );
  }

  const db = openDb(databaseUrl);
  try {
    const report = await importImagesLedger({ db, sqlitePath, drained, dryRun });
    console.log(`[importImagesLedger]${dryRun ? " DRY RUN" : ""} ${sqlitePath}`);
    for (const row of formatReport(report)) console.log(row);
    if (report.unresolved.length > 0) {
      console.warn(
        "WARN unresolved reservations imported as-is (never converted to failed) — reconcile them after the flip",
      );
    }
    if (!dryRun) ok("images SQLite → Postgres import complete (insert-if-absent)");
  } finally {
    await closeDb(db);
  }
}

if (isMain(import.meta.url)) {
  cli().catch((err) => {
    console.error(
      `[importImagesLedger] FAILED: ${err instanceof Error ? err.message : String(err)}`,
    );
    process.exit(1);
  });
}
