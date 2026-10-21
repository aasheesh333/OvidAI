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

// ── bounded tail reads (the main agent's read_subagent_log tool) ───────────
//
// A log is an AUDIT TRAIL, not a transcript: the main agent may read it on
// demand, but a tool result must stay bounded. The reader therefore walks the
// file BACKWARDS from EOF, reads at most a fixed number of bytes, and returns
// only the requested number of trailing lines. It never slurps the whole file
// into the result, and a file larger than the scan cap is reported as
// truncated rather than returned in full.

/** Default trailing-line budget for one read (SI spec §9 read-on-demand). */
export const SUBAGENT_LOG_TAIL_DEFAULT = 200;
/** Hard ceiling on trailing lines for one read — never the whole file. */
export const SUBAGENT_LOG_TAIL_MAX = 2_000;
/** Longest single log line returned; a giant tool payload is clipped. */
export const SUBAGENT_LOG_LINE_MAX_CHARS = 2_000;
/** Marker appended when earlier lines/bytes were omitted or a line clipped. */
export const SUBAGENT_LOG_TRUNCATION_MARKER = "…[truncated]";

/** Backwards read chunk (bytes) and total scan cap for one read. */
const TAIL_CHUNK_BYTES = 64 * 1024;
const TAIL_SCAN_MAX_BYTES = 4 * 1024 * 1024;

export class SubagentLogNotFoundError extends Error {
  readonly sessionId: string;

  constructor(sessionId: string) {
    super(`no subagent log found for ${sessionId}`);
    this.name = "SubagentLogNotFoundError";
    this.sessionId = sessionId;
  }
}

/** Clamp an untrusted `tailLines` argument to [1, SUBAGENT_LOG_TAIL_MAX]. */
export function clampSubagentLogTailLines(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return SUBAGENT_LOG_TAIL_DEFAULT;
  }
  return Math.min(SUBAGENT_LOG_TAIL_MAX, Math.max(1, Math.floor(value)));
}

export interface ReadSubagentLogOptions {
  sessionId: string;
  /** Defaults to SUBAGENT_LOG_DIR. */
  dir?: string;
  /** Trailing lines to return (default 200, clamped to 1..2,000). */
  tailLines?: number;
}

export interface SubagentLogTailText {
  /** Returned lines, oldest first, newest last. */
  lines: string[];
  /** True when earlier lines/bytes were omitted or a line was clipped. */
  truncated: boolean;
  /** Render-ready text: the lines plus the truncation marker when shortened. */
  text: string;
}

export interface SubagentLogTail extends SubagentLogTailText {
  sessionId: string;
  path: string;
  /** The clamped line budget this read honoured. */
  tailLines: number;
}

/** The read seam — the worker may replace this with a sandbox-backed reader. */
export type SubagentLogReader = (options: ReadSubagentLogOptions) => Promise<SubagentLogTail>;

function clipLogLine(line: string): string {
  if (line.length <= SUBAGENT_LOG_LINE_MAX_CHARS) return line;
  const keep = Math.max(0, SUBAGENT_LOG_LINE_MAX_CHARS - SUBAGENT_LOG_TRUNCATION_MARKER.length);
  return `${line.slice(0, keep)}${SUBAGENT_LOG_TRUNCATION_MARKER}`;
}

/** Slice/clip/render one set of lines under the same bounds the reader uses. */
function boundTailLines(
  lines: readonly string[],
  tailLines: number,
  alreadyTruncated: boolean,
): SubagentLogTailText {
  let out = [...lines];
  let truncated = alreadyTruncated;
  if (out.length > tailLines) {
    out = out.slice(out.length - tailLines);
    truncated = true;
  }
  const clipped = out.map((line) => {
    const bounded = clipLogLine(line);
    if (bounded !== line) truncated = true;
    return bounded;
  });
  const body = clipped.join("\n");
  const text = truncated
    ? body === ""
      ? SUBAGENT_LOG_TRUNCATION_MARKER
      : body.includes(SUBAGENT_LOG_TRUNCATION_MARKER)
        ? body
        : `${body}\n${SUBAGENT_LOG_TRUNCATION_MARKER}`
    : body;
  return { lines: clipped, truncated, text };
}

/**
 * Apply the reader's bounds to an ALREADY-READ log string.
 *
 * The worker's sandbox-backed `logReader` uses this after
 * `SandboxPort.readFile`, so the sandbox path and the host path cannot drift:
 * same default, same 2,000-line cap, same per-line clip, same marker.
 */
export function tailSubagentLogText(
  content: string,
  tailLines?: number,
): SubagentLogTailText {
  const budget = clampSubagentLogTailLines(tailLines);
  const lines = content.split(/\r?\n/);
  // A trailing newline terminates the last line; it is not an extra empty one.
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return boundTailLines(lines, budget, false);
}

function countNewlines(buffer: Buffer): number {
  let count = 0;
  for (const byte of buffer) if (byte === 0x0a) count += 1;
  return count;
}

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

/**
 * Read the BOUNDED tail of a child's log.
 *
 * Guarantees:
 *  • `lines.length <= clampSubagentLogTailLines(options.tailLines)` (≤ 2,000);
 *  • at most TAIL_SCAN_MAX_BYTES are read from the file, so an enormous log is
 *    never materialised in memory or in the result;
 *  • each line is clipped to SUBAGENT_LOG_LINE_MAX_CHARS;
 *  • `text` carries SUBAGENT_LOG_TRUNCATION_MARKER whenever anything was
 *    omitted, so a shortened read can never look complete.
 *
 * The id is validated by `subagentLogPath` exactly like the writer's.
 */
export async function readSubagentLogTail(
  options: ReadSubagentLogOptions,
): Promise<SubagentLogTail> {
  const path = subagentLogPath(options.sessionId, options.dir ?? SUBAGENT_LOG_DIR);
  const tailLines = clampSubagentLogTailLines(options.tailLines);

  let handle: FileHandle;
  try {
    handle = await open(path, "r");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") {
      throw new SubagentLogNotFoundError(options.sessionId);
    }
    throw err;
  }

  try {
    const { size } = await handle.stat();
    if (size === 0) {
      return {
        sessionId: options.sessionId,
        path,
        tailLines,
        lines: [],
        truncated: false,
        text: "",
      };
    }

    // Walk backwards until we hold more than `tailLines` newlines (so the
    // first buffered line can be discarded when it is a fragment) or until
    // the scan cap / start of file is reached.
    let position = size;
    let buffer = Buffer.alloc(0);
    let scanned = 0;
    while (
      position > 0 &&
      countNewlines(buffer) <= tailLines &&
      scanned < TAIL_SCAN_MAX_BYTES
    ) {
      const readSize = Math.min(
        TAIL_CHUNK_BYTES,
        position,
        TAIL_SCAN_MAX_BYTES - scanned,
      );
      if (readSize <= 0) break;
      position -= readSize;
      scanned += readSize;
      const chunk = Buffer.alloc(readSize);
      const { bytesRead } = await handle.read(chunk, 0, readSize, position);
      buffer = Buffer.concat([chunk.subarray(0, bytesRead), buffer]);
    }

    // Not reaching offset 0 means at least one earlier byte was omitted.
    const truncated = position > 0;
    let lines = buffer.toString("utf8").split(/\r?\n/);
    // A trailing newline terminates the last line; it is not an extra empty one.
    if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
    // If the buffer begins mid-line, that fragment is not a usable line.
    if (truncated && lines.length > 0) {
      lines.shift();
      if (lines.length === 0) {
        // A single line larger than the scan cap: keep its bounded tail rather
        // than returning nothing.
        lines = [buffer.toString("utf8").slice(-SUBAGENT_LOG_LINE_MAX_CHARS)];
      }
    }
    return {
      sessionId: options.sessionId,
      path,
      tailLines,
      ...boundTailLines(lines, tailLines, truncated),
    };
  } finally {
    await handle.close();
  }
}
