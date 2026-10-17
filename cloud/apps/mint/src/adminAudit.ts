import { randomBytes } from "node:crypto";
import { appendFile } from "node:fs/promises";
import { statSync } from "node:fs";
import { join } from "node:path";
import { schema, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import type { MintEnv } from "./env.js";
import { isoUtc } from "./windows.js";

/**
 * The owner admin audit trail — port of mint.py's audit() (mint.py:1595).
 * THREE sinks, each append-only, each failure-tolerant (logged, never thrown
 * — one sink being down must never block a route or the other sinks):
 *
 *  1. Postgres mint_audit — the durable copy (Task 2's table);
 *  2. the `audit:admin` Redis list — newest first, capped at AUDIT_MAX for
 *     the console (GET /admin/audit reads this one);
 *  3. admin-audit.jsonl in MINT_STATE_DIR — append-only on the mint volume,
 *     NEVER trimmed (Python's off-box backup trail).
 *
 * Entry shape is Python's: {ts, action, actor, ip, target, before, after},
 * serialized with sorted keys like json.dumps(sort_keys=True). The Python
 * `result` field is not ported — the schema (Task 2) settles the row shape
 * and the route responses carry their own reapplied/reset results.
 */

export const AUDIT_LIST = "audit:admin";
export const AUDIT_FILE_NAME = "admin-audit.jsonl";

/** audit()'s structural deps — a full MintDeps satisfies them. */
export interface AuditDeps {
  db: Db;
  redis: Redis;
  env: Pick<MintEnv, "auditMax" | "mintStateDir">;
  clock?: () => Date;
}

export interface AuditOptions {
  target?: unknown;
  before?: unknown;
  after?: unknown;
  ip?: string;
}

export interface AuditEntry {
  ts: string;
  action: string;
  actor: string;
  ip: string;
  target: unknown;
  before: unknown;
  after: unknown;
}

/**
 * UUIDv7 (time-ordered) for mint_audit.id — the schema's pinned id shape.
 * Local implementation: @ovid/mint must not grow the `uuidv7` dependency
 * (@ovid/db owns it; no lockfile changes in this task).
 */
function uuidv7(now: Date): string {
  const ts = BigInt(now.getTime());
  const b = randomBytes(16);
  b[0] = Number((ts >> 40n) & 0xffn);
  b[1] = Number((ts >> 32n) & 0xffn);
  b[2] = Number((ts >> 24n) & 0xffn);
  b[3] = Number((ts >> 16n) & 0xffn);
  b[4] = Number((ts >> 8n) & 0xffn);
  b[5] = Number(ts & 0xffn);
  b[6] = (b[6]! & 0x0f) | 0x70; // version 7
  b[8] = (b[8]! & 0x3f) | 0x80; // RFC 4122 variant
  const hex = b.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** json.dumps(sort_keys=True) parity: object keys sorted at every depth. */
function sortedValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sortedValue);
  }
  if (value !== null && typeof value === "object") {
    const rec = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(rec).sort()) {
      out[key] = sortedValue(rec[key]);
    }
    return out;
  }
  return value;
}

/** The exact line stored in Redis and appended to the JSONL file. */
export function auditLine(entry: AuditEntry): string {
  return JSON.stringify(sortedValue(entry));
}

/** Python _state_path: the JSONL path, or null when the state dir is absent. */
function jsonlPath(env: AuditDeps["env"]): string | null {
  if (!env.mintStateDir) {
    return null;
  }
  try {
    if (!statSync(env.mintStateDir).isDirectory()) {
      return null;
    }
  } catch {
    return null;
  }
  return join(env.mintStateDir, AUDIT_FILE_NAME);
}

/**
 * Append one admin action to all three sinks. NEVER throws: each sink's
 * failure is logged with Python's message shape and the rest still run.
 */
export async function audit(
  deps: AuditDeps,
  action: string,
  opts: AuditOptions = {},
): Promise<void> {
  const now = new Date((deps.clock ?? (() => new Date()))().getTime());
  const entry: AuditEntry = {
    ts: isoUtc(now),
    action,
    actor: "master-key",
    ip: opts.ip ?? "unknown",
    target: opts.target === undefined ? null : opts.target,
    before: opts.before === undefined ? null : opts.before,
    after: opts.after === undefined ? null : opts.after,
  };
  const line = auditLine(entry);

  // 1. durable Postgres row (drizzle table object — no drizzle-orm import,
  //    the app never touches drizzle operators directly)
  try {
    await deps.db.insert(schema.mintAudit).values({
      id: uuidv7(now),
      at: now,
      actor: entry.actor,
      action,
      target: entry.target,
      before: entry.before,
      after: entry.after,
      ip: entry.ip,
    });
  } catch (err) {
    console.log(`[mint] audit db error: ${errorName(err)}`);
  }

  // 2. capped Redis list, newest first (what GET /admin/audit reads)
  try {
    await deps.redis.lpush(AUDIT_LIST, line);
    await deps.redis.ltrim(AUDIT_LIST, 0, deps.env.auditMax - 1);
  } catch (err) {
    console.log(`[mint] audit redis error: ${errorName(err)}`);
  }

  // 3. append-only JSONL on the mint volume (never trimmed)
  const path = jsonlPath(deps.env);
  if (path !== null) {
    try {
      await appendFile(path, `${line}\n`);
    } catch (err) {
      console.log(`[mint] audit file error: ${errorName(err)}`);
    }
  }
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : String(err);
}
