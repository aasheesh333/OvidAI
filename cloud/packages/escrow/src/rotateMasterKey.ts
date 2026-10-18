#!/usr/bin/env node
/**
 * P10 Task 10 — BYOK escrow master-key rotation.
 *
 * The `byok_keys` envelope binds both layers to the row id
 * (`byok_keys:{id}`) and wraps a per-record DEK under `OVID_MASTER_KEY`. To
 * rotate the master key every row must be unwrapped with the OLD key and
 * re-encrypted under the NEW key; the row id (and therefore the AAD binding)
 * never changes.
 *
 * Safety properties:
 *  - Pre-flight validation: every row is decrypted with the old key BEFORE
 *    the first write. One bad row aborts the whole rotation (no half-rotated
 *    table), and the report names only row ids.
 *  - `--dry-run` validates and counts, writes nothing.
 *  - Each row is written in its own transaction (plan contract) so a crash
 *    leaves the table at a well-defined row boundary.
 *  - Keys are read from NAMED environment variables only — never from argv
 *    (process lists are world-readable) — and are never printed.
 *
 * Scope: `byok_keys` only (the P9 escrow surface). The same OVID_MASTER_KEY
 * also seals MCP/plugin rows and worker browser state; see
 * cloud/deploy/KEY-ROTATION.md for the owner procedure and v1 limitation.
 */

import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createDb, type Db } from "@ovid/db";
import { createEnvelopeCrypto } from "./envelope.js";
import { byokRecordId } from "./provider.js";

interface EnvelopeRow {
  id: string;
  wrapped_dek: string;
  iv: string;
  ciphertext: string;
  tag: string;
}

export interface RotateMasterKeyOptions {
  /** Postgres URL. Ignored when `db` is supplied (tests). */
  databaseUrl?: string;
  /** Injected handle (tests); ownership of its connection stays with caller. */
  db?: Db;
  oldKeyHex: string;
  newKeyHex: string;
  /** Optional owner narrowing (tests / per-user drills). Omitted → every row. */
  userId?: string;
  dryRun?: boolean;
  log?: (line: string) => void;
}

export interface RotateFailure {
  id: string;
  reason: string;
}

export interface RotateMasterKeyResult {
  total: number;
  rotated: number;
  dryRun: boolean;
  failures: RotateFailure[];
}

/**
 * The operator-facing truth after a failed run. Phase 1 failures leave the
 * table unchanged (nothing was written); a phase-2 failure after N successful
 * writes leaves the table MIXED — N rows under the new key, the rest under the
 * old one. Saying "table unchanged" in that state is dangerous mid-incident.
 */
export interface RotateMasterKeyFailureState {
  mixed: boolean;
  rotated: number;
  remaining: number;
  failed: number;
  summary: string;
  guidance: string;
}

export function rotationFailureState(
  result: RotateMasterKeyResult,
): RotateMasterKeyFailureState {
  const remaining = Math.max(0, result.total - result.rotated);
  const mixed = result.rotated > 0;
  return {
    mixed,
    rotated: result.rotated,
    remaining,
    failed: result.failures.length,
    summary: mixed
      ? `FAIL — rotated ${result.rotated}/${result.total} row(s); ` +
        `${remaining} row(s) still under the old key; table is MIXED`
      : `FAIL — 0/${result.total} row(s) rotated; table unchanged (no row was written)`,
    guidance: mixed
      ? "Old-key rows are still readable with the OLD key; rotated rows only with the NEW key. " +
        "Resume the rotation with the same old/new keys or roll back."
      : "Fix the reported row(s) and re-run; no partial write occurred.",
  };
}

function envelopeOf(row: EnvelopeRow) {
  return {
    wrappedDek: row.wrapped_dek,
    iv: row.iv,
    ciphertext: row.ciphertext,
    tag: row.tag,
  };
}

/**
 * Rotate every `byok_keys` envelope from `oldKeyHex` to `newKeyHex`.
 *
 * The function never throws for a row-level auth failure — it reports it in
 * `failures` (with the row id and a fixed reason) and rotates nothing.
 */
export async function rotateMasterKey(
  opts: RotateMasterKeyOptions,
): Promise<RotateMasterKeyResult> {
  const dryRun = opts.dryRun === true;
  const log = opts.log ?? (() => {});

  if (opts.oldKeyHex.toLowerCase() === opts.newKeyHex.toLowerCase()) {
    throw new Error("old and new master keys are identical");
  }
  const oldCrypto = createEnvelopeCrypto(opts.oldKeyHex);
  const newCrypto = createEnvelopeCrypto(opts.newKeyHex);

  const db = opts.db ?? createDb(opts.databaseUrl!);
  const ownsDb = opts.db === undefined;

  try {
    const rows = (opts.userId === undefined
      ? await db.$client`
          SELECT id, wrapped_dek, iv, ciphertext, tag
          FROM byok_keys
          ORDER BY id
        `
      : await db.$client`
          SELECT id, wrapped_dek, iv, ciphertext, tag
          FROM byok_keys
          WHERE user_id = ${opts.userId}
          ORDER BY id
        `) as EnvelopeRow[];

    log(`rows=${rows.length} mode=${dryRun ? "dry-run" : "rotate"}`);

    // ── Phase 1: validate EVERY row with the old key. ──────────────────────
    const plaintexts = new Map<string, string>();
    const failures: RotateFailure[] = [];
    for (const row of rows) {
      try {
        plaintexts.set(row.id, oldCrypto.decrypt(envelopeOf(row), byokRecordId(row.id)));
        log(`row ${row.id}: old key ok`);
      } catch {
        failures.push({
          id: row.id,
          reason: "envelope failed authentication with the old key",
        });
        log(`row ${row.id}: FAILED old-key authentication`);
      }
    }
    if (failures.length > 0) {
      return { total: rows.length, rotated: 0, dryRun, failures };
    }
    if (dryRun) {
      return { total: rows.length, rotated: 0, dryRun: true, failures: [] };
    }

    // ── Phase 2: re-encrypt + write one transaction per row. ───────────────
    let rotated = 0;
    for (const row of rows) {
      const envelope = newCrypto.encrypt(plaintexts.get(row.id)!, byokRecordId(row.id));
      try {
        await db.$client.begin(async (tx) => {
          await tx`
            UPDATE byok_keys
            SET wrapped_dek = ${envelope.wrappedDek},
                iv = ${envelope.iv},
                ciphertext = ${envelope.ciphertext},
                tag = ${envelope.tag}
            WHERE id = ${row.id}
          `;
        });
        rotated += 1;
        log(`row ${row.id}: rotated`);
      } catch {
        // Never include the underlying DB error: it can carry bound values.
        failures.push({ id: row.id, reason: "database write failed" });
        log(`row ${row.id}: FAILED database write — stopping`);
        break;
      }
    }
    return { total: rows.length, rotated, dryRun: false, failures };
  } finally {
    if (ownsDb) await db.$client.end({ timeout: 5 });
  }
}

interface CliOptions {
  databaseUrl: string;
  oldKeyEnv: string;
  newKeyEnv: string;
  dryRun: boolean;
}

function usage(): string {
  return [
    "usage: rotate-master-key --database-url <url> \\",
    "         --old-key-env OVID_MASTER_KEY_OLD \\",
    "         --new-key-env OVID_MASTER_KEY_NEW [--dry-run]",
    "",
    "Keys are read from the named environment variables and are never",
    "printed. --dry-run validates every row with the old key and writes",
    "nothing. Exit 1 when any row fails.",
  ].join("\n");
}

function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = {
    databaseUrl: "",
    oldKeyEnv: "",
    newKeyEnv: "",
    dryRun: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]!;
    if (arg === "--help" || arg === "-h") {
      console.log(usage());
      process.exit(0);
    }
    if (arg === "--dry-run") {
      options.dryRun = true;
      continue;
    }
    const value = argv[i + 1];
    if (value === undefined) throw new Error(`rotate-master-key: missing value for ${arg}`);
    switch (arg) {
      case "--database-url":
        options.databaseUrl = value;
        i += 1;
        break;
      case "--old-key-env":
        options.oldKeyEnv = value;
        i += 1;
        break;
      case "--new-key-env":
        options.newKeyEnv = value;
        i += 1;
        break;
      default:
        throw new Error(`rotate-master-key: unknown argument ${arg}\n${usage()}`);
    }
  }
  if (options.databaseUrl === "") throw new Error(`rotate-master-key: --database-url is required\n${usage()}`);
  if (options.oldKeyEnv === "") throw new Error(`rotate-master-key: --old-key-env is required\n${usage()}`);
  if (options.newKeyEnv === "") throw new Error(`rotate-master-key: --new-key-env is required\n${usage()}`);
  return options;
}

function keyFromEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.trim() === "") {
    throw new Error(`environment variable ${name} is not set`);
  }
  return value.trim();
}

export async function runRotateMasterKeyCli(
  argv: string[],
  rotate: typeof rotateMasterKey = rotateMasterKey,
): Promise<number> {
  const options = parseArgs(argv);
  const oldKeyHex = keyFromEnv(options.oldKeyEnv);
  const newKeyHex = keyFromEnv(options.newKeyEnv);
  const log = (line: string) => console.log(`rotate-master-key: ${line}`);

  const result = await rotate({
    databaseUrl: options.databaseUrl,
    oldKeyHex,
    newKeyHex,
    dryRun: options.dryRun,
    log,
  });

  for (const failure of result.failures) {
    console.error(`rotate-master-key: row ${failure.id}: FAIL (${failure.reason})`);
  }
  if (result.failures.length > 0) {
    const state = rotationFailureState(result);
    console.error(`rotate-master-key: ${state.summary}`);
    console.error(`rotate-master-key: ${state.guidance}`);
    return 1;
  }
  if (result.dryRun) {
    console.log(
      `rotate-master-key: OK — validated ${result.total} row(s) with the old key; no writes (--dry-run)`,
    );
  } else {
    console.log(`rotate-master-key: OK — rotated ${result.rotated}/${result.total} row(s)`);
  }
  return 0;
}

function isDirectInvocation(): boolean {
  const invoked = process.argv[1];
  if (invoked === undefined) return false;
  try {
    return realpathSync(invoked) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
}

if (isDirectInvocation()) {
  runRotateMasterKeyCli(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (err: unknown) => {
      console.error(
        `rotate-master-key: ${err instanceof Error ? err.message : String(err)}`,
      );
      process.exit(2);
    },
  );
}
