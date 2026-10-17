/**
 * Task 18 — installed-base import #3: Python shares SQLite → Postgres.
 *
 * EXECUTION IS OWNER-GATED (DECOMMISSION.md Step 3 / Q1 "installed base").
 * Drain/stop the Python shares service first (`--drained` required).
 *
 * Preserved exactly:
 *   - token, owner uid, session id, request id;
 *   - the snapshot JSON (content) and message count;
 *   - created/expires timestamps at millisecond precision;
 *   - revoked rows as revoked receipts (content cleared, revoked_at = the
 *     import moment — Python stores only a 0/1 flag, no timestamp);
 *   - EVERY row, including revoked and expired ones: the lifetime quota
 *     counters (`sharesRepo.counts`) must match before/after, and dedup
 *     history must survive so an old request id can never republish;
 *   - share forks (Python's `share_forks.owner_uid` is the RECIPIENT uid).
 *
 * Python's `deleted_accounts` tombstones are NOT copied into a table: the
 * Python delete path already removes the uid's shares/forks, and the TS
 * lifecycle owns deletion state (`account_deletions`). Creating a tombstone
 * here would start a deletion state machine for an already-clean account.
 * The script reports them and verifies no shares rows survived.
 *
 * Inserts are insert-if-absent — re-running is safe and never rewrites a
 * receipt.
 *
 * Usage:
 *   node --experimental-strip-types cloud/scripts/migrate/importSharesSqlite.ts \
 *     --sqlite /opt/ovid-gateway/shares/shares.sqlite3 --drained \
 *     [--database-url postgres://…] [--dry-run]
 */

import { createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import {
  closeDb,
  hasFlag,
  isMain,
  line,
  ok,
  openDb,
  requiredSetting,
  type DbHandle,
} from "./runtime.js";

const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

interface ShareMessage {
  role: string;
  content: string;
}

interface SourceShare {
  token: string;
  ownerUid: string;
  sessionId: string;
  requestId: string;
  content: { messages: ShareMessage[] } | null;
  messageCount: number;
  createdAt: number; // epoch ms
  expiresAt: number; // epoch ms
  revokedAt: number | null; // epoch ms
  fingerprint: string;
}

interface SourceFork {
  token: string;
  recipientUid: string;
  requestId: string;
  sessionId: string;
  createdAt: number; // epoch ms
}

export interface ImportSharesReport {
  shares: number;
  revoked: number;
  expiredPurged: number;
  forks: number;
  deletedAccounts: number;
  deletedAccountRowsStillPresent: string[];
}

function secondsToMs(value: unknown, field: string, token: string): number {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) {
    throw new Error(`share ${token}: ${field} must be a finite epoch-seconds number`);
  }
  return Math.round(n * 1000);
}

/** Same canonical fingerprint the Postgres repo recomputes (moneyRepos.ts). */
export function shareFingerprint(sessionId: string, messages: ShareMessage[]): string {
  const canonical = JSON.stringify({
    messages: messages.map((m) => ({ content: m.content, role: m.role })),
  });
  return createHash("sha256").update(`${sessionId}\n${canonical}`).digest("hex");
}

function parseSnapshot(raw: unknown, token: string): { messages: ShareMessage[] } | null {
  if (raw === null || raw === undefined || raw === "") return null;
  if (typeof raw !== "string") {
    throw new Error(`share ${token}: snapshot must be TEXT`);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(`share ${token}: snapshot is not valid JSON`);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`share ${token}: snapshot must be a JSON object`);
  }
  const messages = (parsed as { messages?: unknown }).messages;
  if (!Array.isArray(messages)) {
    throw new Error(`share ${token}: snapshot.messages must be an array`);
  }
  const out: ShareMessage[] = messages.map((message, index) => {
    if (
      typeof message !== "object" ||
      message === null ||
      typeof (message as ShareMessage).role !== "string" ||
      typeof (message as ShareMessage).content !== "string"
    ) {
      throw new Error(`share ${token}: message ${index} must be {role, content} strings`);
    }
    return {
      role: (message as ShareMessage).role,
      content: (message as ShareMessage).content,
    };
  });
  return { messages: out };
}

export function mapShareRow(raw: Record<string, unknown>, nowMs: number): SourceShare {
  const token = String(raw.token ?? "");
  if (!TOKEN_RE.test(token)) {
    throw new Error(`share token ${JSON.stringify(token)} is not a 43-char base64url token`);
  }
  const ownerUid = String(raw.owner_uid ?? "");
  const sessionId = String(raw.session_id ?? "");
  const requestId = String(raw.request_id ?? "");
  if (ownerUid === "" || sessionId === "" || requestId === "") {
    throw new Error(`share ${token}: owner_uid/session_id/request_id must be non-empty`);
  }
  const revoked = Number(raw.revoked ?? 0) !== 0;
  const parsed = parseSnapshot(raw.snapshot, token);
  const messages = parsed?.messages ?? [];
  const fingerprint = String(raw.fingerprint ?? "");
  if (parsed !== null) {
    const expected = shareFingerprint(sessionId, messages);
    if (fingerprint !== "" && fingerprint !== expected) {
      throw new Error(
        `share ${token}: stored fingerprint does not match the snapshot (source corruption)`,
      );
    }
  }
  return {
    token,
    ownerUid,
    sessionId,
    requestId,
    content: revoked ? null : parsed,
    messageCount: messages.length,
    createdAt: secondsToMs(raw.created_at, "created_at", token),
    expiresAt: secondsToMs(raw.expires_at, "expires_at", token),
    revokedAt: revoked ? nowMs : null,
    fingerprint,
  };
}

export function readSharesSource(
  sqlitePath: string,
  nowMs: number,
): { shares: SourceShare[]; forks: SourceFork[]; deletedAccounts: string[] } {
  const sqlite = new DatabaseSync(sqlitePath, { readOnly: true });
  try {
    const shares = (
      sqlite
        .prepare("SELECT * FROM shares ORDER BY owner_uid, request_id, token")
        .all() as Array<Record<string, unknown>>
    ).map((row) => mapShareRow(row, nowMs));

    const forks = (
      sqlite
        .prepare("SELECT * FROM share_forks ORDER BY owner_uid, request_id")
        .all() as Array<Record<string, unknown>>
    ).map((row) => ({
      token: String(row.source_token ?? ""),
      recipientUid: String(row.owner_uid ?? ""),
      requestId: String(row.request_id ?? ""),
      sessionId: String(row.session_id ?? ""),
      createdAt: secondsToMs(row.created_at, "share_forks.created_at", String(row.source_token)),
    }));

    const deletedAccounts = (
      sqlite.prepare("SELECT uid FROM deleted_accounts ORDER BY uid").all() as Array<{
        uid: string;
      }>
    ).map((row) => row.uid);

    return { shares, forks, deletedAccounts };
  } finally {
    sqlite.close();
  }
}

export async function importSharesSqlite(deps: {
  db: DbHandle;
  sqlitePath: string;
  now?: number;
  drained: boolean;
  dryRun?: boolean;
}): Promise<ImportSharesReport> {
  if (!deps.drained) {
    throw new Error(
      "refusing to import: drain/stop the Python shares service first, then pass --drained",
    );
  }
  const nowMs = deps.now ?? Date.now();
  const now = Math.floor(nowMs / 1000);
  const { shares, forks, deletedAccounts } = readSharesSource(deps.sqlitePath, nowMs);

  const revoked = shares.filter((s) => s.revokedAt !== null).length;
  const expiredPurged = shares.filter(
    (s) => s.revokedAt === null && s.content === null && s.expiresAt <= nowMs,
  ).length;

  const stillPresent: string[] = [];
  for (const uid of deletedAccounts) {
    if (shares.some((s) => s.ownerUid === uid)) stillPresent.push(uid);
  }

  if (deps.dryRun !== true) {
    for (const share of shares) {
      await deps.db.$client`
        INSERT INTO shares
          (token, owner_uid, session_id, request_id, content, message_count,
           created_at, expires_at, revoked_at, purged_at, fork_of_token)
        VALUES (
          ${share.token}, ${share.ownerUid}, ${share.sessionId}, ${share.requestId},
          ${share.content === null ? null : JSON.stringify(share.content)},
          ${share.messageCount}, ${new Date(share.createdAt).toISOString()},
          ${new Date(share.expiresAt).toISOString()},
          ${share.revokedAt === null ? null : new Date(share.revokedAt).toISOString()},
          ${null}, ${null}
        )
        ON CONFLICT DO NOTHING`;
    }
    for (const fork of forks) {
      await deps.db.$client`
        INSERT INTO share_forks (token, recipient_uid, request_id, session_id, created_at)
        VALUES (${fork.token}, ${fork.recipientUid}, ${fork.requestId}, ${fork.sessionId},
                ${new Date(fork.createdAt).toISOString()})
        ON CONFLICT DO NOTHING`;
    }
  }

  return {
    shares: shares.length,
    revoked,
    expiredPurged,
    forks: forks.length,
    deletedAccounts: deletedAccounts.length,
    deletedAccountRowsStillPresent: stillPresent,
  };
}

export function formatReport(report: ImportSharesReport): string[] {
  return [
    line("share rows", report.shares),
    line("  revoked", report.revoked),
    line("  expired/purged (receipt kept)", report.expiredPurged),
    line("share forks", report.forks),
    line("python deleted_accounts tombstones", report.deletedAccounts),
    line(
      "deleted uids still holding shares",
      report.deletedAccountRowsStillPresent.length,
    ),
    ...report.deletedAccountRowsStillPresent.map(
      (uid) => `  WARNING deleted uid ${uid} still has share rows — reconcile before flipping`,
    ),
  ];
}

async function cli(): Promise<void> {
  const argv = process.argv.slice(2);
  const sqlitePath = requiredSetting(argv, "--sqlite", "SHARES_SQLITE_PATH");
  const databaseUrl = requiredSetting(argv, "--database-url", "DATABASE_URL");
  const drained = hasFlag(argv, "--drained");
  const dryRun = hasFlag(argv, "--dry-run");
  if (!drained) {
    throw new Error(
      "refusing to import: drain/stop the Python shares service first, then pass --drained",
    );
  }

  const db = openDb(databaseUrl);
  try {
    const report = await importSharesSqlite({ db, sqlitePath, drained, dryRun });
    console.log(`[importSharesSqlite]${dryRun ? " DRY RUN" : ""} ${sqlitePath}`);
    for (const row of formatReport(report)) console.log(row);
    if (report.deletedAccountRowsStillPresent.length > 0) {
      console.warn(
        "WARN deleted accounts still hold share rows; verifyMigration will fail until reconciled",
      );
    }
    if (!dryRun) ok("shares SQLite → Postgres import complete (insert-if-absent)");
  } finally {
    await closeDb(db);
  }
}

if (isMain(import.meta.url)) {
  cli().catch((err) => {
    console.error(
      `[importSharesSqlite] FAILED: ${err instanceof Error ? err.message : String(err)}`,
    );
    process.exit(1);
  });
}
