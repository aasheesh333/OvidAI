/**
 * P10 Task 10 — canary leak sweep.
 *
 * Injects a distinct `sk-CANARY-<uuid>` per secret role into the workload
 * environment, tees the workload's stdout/stderr to capture files, then greps
 * every configured corpus (capture files, log files, and caller-supplied
 * corpora such as `session_event_mirror` rows or raw Redis `XRANGE` payloads).
 *
 * Any canary occurrence is a leak entry. The sweep deliberately does NOT
 * redact the canary from its own output: an operator needs the exact location
 * to fix the emitting site, and the canary is throwaway test material.
 */

import { randomUUID } from "node:crypto";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

/** One canary value per secret role. */
export interface CanarySet {
  masterKey: string;
  byokKey: string;
  mintKey: string;
  redisPassword: string;
  dbPassword: string;
}

export type CanaryRole = keyof CanarySet;

/**
 * Environment variable names the sweep populates. They are the variables a
 * leaked-secret bug most plausibly echoes (a stack trace, a debug log, a
 * serialized config); the role-to-name mapping is part of the sweep contract.
 */
export const CANARY_ENV: Readonly<Record<CanaryRole, string>> = Object.freeze({
  masterKey: "OVID_MASTER_KEY",
  byokKey: "OVID_CANARY_BYOK_KEY",
  mintKey: "OVID_CANARY_MINT_KEY",
  redisPassword: "REDIS_PASSWORD",
  dbPassword: "OVID_CANARY_DB_PASSWORD",
});

export const CANARY_ROLES: readonly CanaryRole[] = Object.freeze([
  "masterKey",
  "byokKey",
  "mintKey",
  "redisPassword",
  "dbPassword",
]);

/** A non-file corpus, e.g. DB rows or Redis stream entries. */
export interface CanaryCorpus {
  /** Human-readable location reported in `leaks[].where`. */
  where: string;
  /** The raw text to grep; invoked after the workload finishes. */
  read: () => string | Promise<string>;
}

export interface CanarySweepOptions {
  /** Extra environment merged over the injected canaries (e.g. process.env). */
  env?: Record<string, string>;
  /**
   * The workload. It receives the fully merged environment so a child process
   * can be spawned with exactly the canary values. (A zero-argument callback
   * is assignable and may read `process.env` instead.)
   */
  run: (env: Record<string, string>) => Promise<void>;
  /** [stdout, stderr] capture file paths. Created/truncated before the run. */
  captures?: string[];
  /** Existing log files to grep (gateway/worker logs, compose captures). */
  logFiles?: string[];
  /** Extra in-memory/file-backed corpora (DB mirror rows, Redis XRANGE payloads). */
  corpora?: CanaryCorpus[];
  /** Deterministic override for tests; omitted roles are generated. */
  canaries?: Partial<CanarySet>;
}

export interface CanaryLeak {
  canary: string;
  where: string;
}

export interface CanarySweepResult {
  leaks: CanaryLeak[];
  /** Number of corpus locations actually scanned (files + corpora). */
  scanned: number;
  /** The exact canary values injected (never printed by default callers). */
  canaries: CanarySet;
}

function generatedCanary(): string {
  return `sk-CANARY-${randomUUID()}`;
}

export function createCanarySet(overrides: Partial<CanarySet> = {}): CanarySet {
  return {
    masterKey: overrides.masterKey ?? generatedCanary(),
    byokKey: overrides.byokKey ?? generatedCanary(),
    mintKey: overrides.mintKey ?? generatedCanary(),
    redisPassword: overrides.redisPassword ?? generatedCanary(),
    dbPassword: overrides.dbPassword ?? generatedCanary(),
  };
}

type StreamWrite = typeof process.stdout.write;

/**
 * Wrap a stream's `write` so every chunk is appended to `file` AND forwarded
 * to the real stream. `console.log`/`console.error` go through these methods,
 * so in-process workloads are captured without changing their code.
 */
function teeWrite(original: StreamWrite, file: string | undefined): StreamWrite {
  return ((chunk: unknown, encoding?: unknown, callback?: unknown) => {
    if (file !== undefined) {
      try {
        appendFileSync(
          file,
          chunk as string | Uint8Array,
          typeof encoding === "string" ? (encoding as BufferEncoding) : undefined,
        );
      } catch {
        // A capture failure must never break the workload; the sweep reports
        // whatever it could read and the caller still gets the run result.
      }
    }
    return (original as (...args: unknown[]) => boolean)(chunk, encoding, callback);
  }) as StreamWrite;
}

function scanText(
  text: string,
  where: string,
  canaries: CanarySet,
  leaks: CanaryLeak[],
  seen: Set<string>,
): void {
  for (const role of CANARY_ROLES) {
    const canary = canaries[role];
    if (!text.includes(canary)) continue;
    const key = `${canary}\u0000${where}`;
    if (seen.has(key)) continue;
    seen.add(key);
    leaks.push({ canary, where });
  }
}

function readIfPresent(path: string): string | null {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

/**
 * Run `opts.run` with canaries injected, then grep every corpus.
 *
 * Capture files are truncated first so a stale run can never produce a false
 * positive (or hide a fresh leak behind old output).
 */
export async function runCanarySweep(
  opts: CanarySweepOptions,
): Promise<CanarySweepResult> {
  const canaries = createCanarySet(opts.canaries);
  const captures = opts.captures ?? [];
  const env: Record<string, string> = {
    ...(opts.env ?? {}),
    [CANARY_ENV.masterKey]: canaries.masterKey,
    [CANARY_ENV.byokKey]: canaries.byokKey,
    [CANARY_ENV.mintKey]: canaries.mintKey,
    [CANARY_ENV.redisPassword]: canaries.redisPassword,
    [CANARY_ENV.dbPassword]: canaries.dbPassword,
  };

  for (const file of captures) {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, "", "utf8");
  }

  const stdoutFile = captures[0];
  const stderrFile = captures[1];
  const originalStdoutWrite = process.stdout.write.bind(process.stdout) as StreamWrite;
  const originalStderrWrite = process.stderr.write.bind(process.stderr) as StreamWrite;
  process.stdout.write = teeWrite(originalStdoutWrite, stdoutFile);
  process.stderr.write = teeWrite(originalStderrWrite, stderrFile);
  try {
    await opts.run(env);
  } finally {
    process.stdout.write = originalStdoutWrite;
    process.stderr.write = originalStderrWrite;
  }

  const leaks: CanaryLeak[] = [];
  const seen = new Set<string>();
  let scanned = 0;

  for (const file of captures) {
    const text = readIfPresent(file);
    if (text === null) continue;
    scanned += 1;
    scanText(text, `capture:${file}`, canaries, leaks, seen);
  }
  for (const file of opts.logFiles ?? []) {
    const text = readIfPresent(file);
    if (text === null) continue;
    scanned += 1;
    scanText(text, `log:${file}`, canaries, leaks, seen);
  }
  for (const corpus of opts.corpora ?? []) {
    scanned += 1;
    scanText(await corpus.read(), corpus.where, canaries, leaks, seen);
  }

  return { leaks, scanned, canaries };
}

/**
 * Redis stream corpus: every `sess:*:events` entry, JSON-encoded field/value
 * pairs exactly as stored. Typed structurally so the load package does not
 * depend on ioredis' concrete class.
 */
export interface RedisStreamReader {
  scan(cursor: string, ...args: (string | number)[]): Promise<[string, string[]]>;
  xrange(key: string, start: string, end: string): Promise<unknown>;
}

export function redisStreamsCorpus(redis: RedisStreamReader): CanaryCorpus {
  return {
    where: "redis:sess:*:events",
    async read() {
      const chunks: string[] = [];
      let cursor = "0";
      do {
        const [next, keys] = await redis.scan(cursor, "MATCH", "sess:*:events", "COUNT", 100);
        cursor = next;
        for (const key of keys) {
          chunks.push(JSON.stringify(await redis.xrange(key, "-", "+")));
        }
      } while (cursor !== "0");
      return chunks.join("\n");
    },
  };
}

/**
 * `session_event_mirror` corpus. Takes a query function so the caller owns the
 * DB client (the load package does not import @ovid/db at runtime).
 */
export function sessionMirrorCorpus(
  query: (sqlText: string) => Promise<Array<Record<string, unknown>>>,
): CanaryCorpus {
  return {
    where: "session_event_mirror",
    async read() {
      const rows = await query(
        "SELECT session_id, seq, type, payload::text AS payload, ts::text AS ts FROM session_event_mirror",
      );
      return JSON.stringify(rows);
    },
  };
}
