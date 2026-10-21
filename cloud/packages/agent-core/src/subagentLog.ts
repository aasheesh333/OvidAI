// Append-only per-subagent log (SI spec §9 / plan Task 8.10).
//
// Every subagent owns one file at `/workspace/.ovid/logs/subagent_{id}.log`.
// The file is opened in append mode, created 0600 inside a 0700 directory, and
// never truncated: a cold resume of the same child id appends a new header
// rather than erasing what the first process wrote. Writes are serialized so
// interleaved tool events cannot tear a line.
//
// The default path is the SANDBOX workspace (`/workspace`), which is what the
// spec names. agent-core itself may run on the worker host, so the directory is
// an injectable dependency (`logDir`) and `createSubagentLog` is a seam the
// worker can replace with a sandbox-backed writer later. Tests always inject a
// temp directory and never touch `/workspace`.

import { constants } from "node:fs";
import { mkdir, open, type FileHandle } from "node:fs/promises";
import { dirname, resolve, sep } from "node:path";

export const SUBAGENT_LOG_DIR = "/workspace/.ovid/logs";
export const SUBAGENT_LOG_PREFIX = "subagent_";

/** Session ids are uuid-ish; anything else cannot escape the log directory. */
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;

export class SubagentLogPathError extends Error {
  constructor(sessionId: string) {
    super(`unsafe subagent id for log path: ${JSON.stringify(sessionId)}`);
    this.name = "SubagentLogPathError";
  }
}

/** Resolve (and validate) the log path without touching the filesystem. */
export function subagentLogPath(sessionId: string, dir: string = SUBAGENT_LOG_DIR): string {
  if (!SAFE_ID.test(sessionId)) throw new SubagentLogPathError(sessionId);
  const base = resolve(dir);
  const expected = `${base.endsWith(sep) ? base : `${base}${sep}`}` +
    `${SUBAGENT_LOG_PREFIX}${sessionId}.log`;
  const file = resolve(base, `${SUBAGENT_LOG_PREFIX}${sessionId}.log`);
  // Defence in depth: the regex already forbids separators, but verify the
  // resolved file still sits directly inside the log directory.
  if (file !== expected || dirname(file) !== base) {
    throw new SubagentLogPathError(sessionId);
  }
  return file;
}

export type SubagentLogEntry = Record<string, unknown> & { type: string };

export interface SubagentLog {
  readonly path: string;
  /** Append one JSON line. Never truncates; serialized with prior writes. */
  append(entry: SubagentLogEntry): Promise<void>;
  /** Flush and close. Idempotent. */
  close(): Promise<void>;
  /** The first write error, if any (logging is fail-open for the run). */
  lastError(): Error | null;
}

export interface CreateSubagentLogOptions {
  sessionId: string;
  /** Defaults to SUBAGENT_LOG_DIR. Tests inject a temp directory. */
  dir?: string;
  now?: () => number;
  /** Extra header facts (parent, agent type, task prompt, …). */
  header?: Record<string, unknown>;
}

/**
 * Create/open the child's append-only log.
 *
 * `mkdir` is recursive + 0700 and the file is opened with the `a` flag, so an
 * existing log is extended, never replaced. A caller that cannot create the
 * directory gets the real error (the supervisor decides whether to fail the
 * run); ordinary write errors after open are recorded and swallowed so a full
 * disk cannot wedge a child.
 */
export async function createSubagentLog(
  options: CreateSubagentLogOptions,
): Promise<SubagentLog> {
  const path = subagentLogPath(options.sessionId, options.dir ?? SUBAGENT_LOG_DIR);
  const dir = dirname(path);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const handle: FileHandle = await open(
    path,
    constants.O_APPEND |
      constants.O_CREAT |
      constants.O_WRONLY |
      (constants.O_NOFOLLOW ?? 0),
    0o600,
  );
  const now = options.now ?? Date.now;

  let tail: Promise<void> = Promise.resolve();
  let closed = false;
  let error: Error | null = null;

  function write(entry: SubagentLogEntry): Promise<void> {
    if (closed) return tail;
    const line = `${JSON.stringify({ ts: now(), ...entry })}\n`;
    tail = tail
      .then(() => handle.write(line))
      .then(() => undefined)
      .catch((err: unknown) => {
        error ??= err instanceof Error ? err : new Error(String(err));
      });
    return tail;
  }

  const log: SubagentLog = {
    path,
    append(entry) {
      return write(entry);
    },
    async close() {
      if (closed) {
        await tail;
        return;
      }
      closed = true;
      await tail;
      await handle.close().catch((err: unknown) => {
        error ??= err instanceof Error ? err : new Error(String(err));
      });
    },
    lastError() {
      return error;
    },
  };

  await write({
    type: "subagent_log_started",
    sessionId: options.sessionId,
    ...(options.header ?? {}),
  });
  return log;
}
