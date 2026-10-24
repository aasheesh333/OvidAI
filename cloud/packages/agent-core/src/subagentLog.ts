import { constants } from "node:fs";
import { mkdir, open, type FileHandle } from "node:fs/promises";
import { basename, dirname, resolve, sep } from "node:path";

export const SUBAGENT_LOG_DIR = "/workspace/.ovid/logs";
export const SUBAGENT_LOG_PREFIX = "subagent_";
export const SUBAGENT_LOG_MAX_BYTES = 16_777_216;
export const SUBAGENT_LOG_TAIL_DEFAULT = 200;
export const SUBAGENT_LOG_TAIL_MAX = 2_000;
export const SUBAGENT_LOG_LINE_MAX_CHARS = 2_000;
export const SUBAGENT_LOG_READ_MAX_BYTES = 4 * 1024 * 1024;
export const SUBAGENT_LOG_TRUNCATION_MARKER = "…[truncated]";
export const SUBAGENT_LOG_REDACTED = "[REDACTED]";

const TAIL_CHUNK_BYTES = 64 * 1024;
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;
const SECRET_NAMES = [
  "authorization",
  "proxy-authorization",
  "cookie",
  "set-cookie",
  "x-api-key",
  "api-key",
  "apikey",
  "api_key",
  "private-token",
  "x-figma-token",
  "access_token",
  "refresh_token",
  "client_secret",
  "code_verifier",
  "password",
  "secret",
  "token",
  "credential",
  "private_key",
  "x-amz-security-token",
  "x-amz-credential",
  "x-amz-signature",
  "signature",
  "sig",
] as const;
const SECRET_NAME_PATTERN = SECRET_NAMES.join("|");
const SENSITIVE_KEYS = new Set<string>(SECRET_NAMES);

export class SubagentLogNotFoundError extends Error {
  readonly sessionId: string;

  constructor(sessionId: string) {
    super(`no subagent log found for ${sessionId}`);
    this.name = "SubagentLogNotFoundError";
    this.sessionId = sessionId;
  }
}

export class SubagentLogPathError extends Error {
  constructor(sessionId: string) {
    super("unsafe subagent id for log path");
    this.name = "SubagentLogPathError";
  }
}

export class SubagentLogAuthorizationError extends Error {
  constructor() {
    super("subagent log reference is not an authorized @subagent_id");
    this.name = "SubagentLogAuthorizationError";
  }
}

export function clampSubagentLogTailLines(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return SUBAGENT_LOG_TAIL_DEFAULT;
  }
  return Math.min(SUBAGENT_LOG_TAIL_MAX, Math.max(1, Math.floor(value)));
}

export function subagentLogPath(
  sessionId: string,
  dir: string = SUBAGENT_LOG_DIR,
): string {
  if (!SAFE_ID.test(sessionId)) throw new SubagentLogPathError(sessionId);
  const base = resolve(dir);
  const expected = `${base.endsWith(sep) ? base : `${base}${sep}`}` +
    `${SUBAGENT_LOG_PREFIX}${sessionId}.log`;
  const file = resolve(base, `${SUBAGENT_LOG_PREFIX}${sessionId}.log`);
  if (file !== expected || dirname(file) !== base) throw new SubagentLogPathError(sessionId);
  return file;
}

type DirectoryOpenHook = (directory: string) => void | Promise<void>;

function errnoCode(error: unknown): string | undefined {
  return (error as NodeJS.ErrnoException | null)?.code;
}

/**
 * Open every path component without following symlinks, then address the log
 * through the held directory descriptor. A rename/symlink substitution after
 * this point cannot redirect either the chmod or the final file open.
 */
async function openConfinedDirectory(
  directory: string,
  create: boolean,
): Promise<FileHandle> {
  const absolute = resolve(directory);
  if (absolute === sep) throw new SubagentLogPathError("root");
  const components = absolute.split(sep).filter((component) => component !== "");
  const directoryFlags = constants.O_RDONLY |
    (constants.O_DIRECTORY ?? 0) |
    (constants.O_NOFOLLOW ?? 0);
  let current = await open(sep, directoryFlags);
  try {
    for (const component of components) {
      const childPath = `/proc/self/fd/${current.fd}/${component}`;
      let next: FileHandle;
      try {
        next = await open(childPath, directoryFlags);
      } catch (error) {
        if (!create || errnoCode(error) !== "ENOENT") throw error;
        try {
          await mkdir(childPath, { mode: 0o700 });
        } catch (mkdirError) {
          if (errnoCode(mkdirError) !== "EEXIST") throw mkdirError;
        }
        // Never trust a successful mkdir/EEXIST alone: the component may have
        // been replaced with a symlink before this no-follow open.
        next = await open(childPath, directoryFlags);
      }
      await current.close();
      current = next;
    }
    return current;
  } catch (error) {
    await current.close().catch(() => {});
    throw error;
  }
}

async function openConfinedLogFile(options: {
  path: string;
  directory: string;
  createDirectory: boolean;
  flags: number;
  mode?: number;
  onDirectoryOpen?: DirectoryOpenHook;
}): Promise<FileHandle> {
  const parent = await openConfinedDirectory(options.directory, options.createDirectory);
  try {
    if (options.createDirectory) await parent.chmod(0o700);
    const info = await parent.stat();
    if (!info.isDirectory()) throw new SubagentLogPathError(basename(options.path));
    await options.onDirectoryOpen?.(options.directory);
    return await open(
      `/proc/self/fd/${parent.fd}/${basename(options.path)}`,
      options.flags,
      options.mode,
    );
  } finally {
    await parent.close();
  }
}

function secretVariants(secrets: readonly string[]): string[] {
  const values = new Set<string>();
  for (const secret of secrets) {
    if (secret === "") continue;
    values.add(secret);
    values.add(encodeURIComponent(secret));
    values.add(new URLSearchParams({ value: secret }).toString().slice("value=".length));
    values.add(JSON.stringify(secret).slice(1, -1));
    values.add(Buffer.from(secret, "utf8").toString("base64"));
  }
  values.delete("");
  return [...values].sort((a, b) => b.length - a.length);
}

/** The single text projection used by both append and every read path. */
export function redactSubagentLogText(
  value: string,
  secrets: readonly string[] = [],
): string {
  let output = value;
  for (const secret of secretVariants(secrets)) {
    output = output.split(secret).join(SUBAGENT_LOG_REDACTED);
  }
  // Remove URL userinfo before token-shaped text rules can consume the host.
  output = output.replace(
    /\bhttps?:\/\/[^\s\/"'<>@]+:[^\s\/"'<>@]+@/gi,
    (prefix) => `${prefix.slice(0, prefix.indexOf("://") + 3)}${SUBAGENT_LOG_REDACTED}@`,
  );
  output = output.replace(/\bgithub_pat_[A-Za-z0-9_]{8,}/gi, SUBAGENT_LOG_REDACTED);
  output = output.replace(/\bgh[pousr]_[A-Za-z0-9]{8,}/g, SUBAGENT_LOG_REDACTED);
  output = output.replace(/\bBearer\s+[^\s,;"']+/gi, `Bearer ${SUBAGENT_LOG_REDACTED}`);
  output = output.replace(
    new RegExp(
      `^(\\s*(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key|apikey|private-token|x-figma-token|x-amz-security-token)\\s*:\\s*)[^\\r\\n]*`,
      "gim",
    ),
    (_match, prefix: string) => prefix + SUBAGENT_LOG_REDACTED,
  );
  output = output.replace(
    new RegExp(
      `((?:"|')?(?:${SECRET_NAME_PATTERN})(?:"|')?\\s*:\\s*)(["']?)([^"'\\r\\n,}]+)\\2`,
      "gi",
    ),
    (_match, prefix: string, quote: string) =>
      prefix + quote + SUBAGENT_LOG_REDACTED + quote,
  );
  output = output.replace(
    new RegExp(`([?&]|^)(${SECRET_NAME_PATTERN})=([^&#\\s}"']+)`, "gim"),
    (_match, prefix: string, key: string) => `${prefix}${key}=${SUBAGENT_LOG_REDACTED}`,
  );
  return output;
}

function sensitiveKey(key: string): boolean {
  const lower = key.toLowerCase();
  return SENSITIVE_KEYS.has(lower) || SENSITIVE_KEYS.has(lower.replace(/-/g, "_"));
}

function collectSecrets(value: unknown, into: Set<string>, depth = 0): void {
  if (depth > 32 || value === null || typeof value !== "object") return;
  if (Array.isArray(value)) {
    for (const entry of value) collectSecrets(entry, into, depth + 1);
    return;
  }
  for (const [key, entry] of Object.entries(value)) {
    if (sensitiveKey(key) && typeof entry === "string" && entry.length >= 8) into.add(entry);
    collectSecrets(entry, into, depth + 1);
  }
}

export function redactSubagentLogValue<T>(
  value: T,
  secrets: readonly string[] = [],
): T {
  const allSecrets = new Set(secrets);
  collectSecrets(value, allSecrets);
  const explicit = [...allSecrets];
  const seen = new WeakSet<object>();
  let visited = 0;
  const walk = (current: unknown, key?: string, depth = 0): unknown => {
    if (key !== undefined && sensitiveKey(key)) return SUBAGENT_LOG_REDACTED;
    if (typeof current === "string") return redactSubagentLogText(current, explicit);
    if (current === null || typeof current !== "object") return current;
    if (depth > 32 || visited > 10_000 || seen.has(current)) return SUBAGENT_LOG_REDACTED;
    seen.add(current);
    visited += 1;
    if (Array.isArray(current)) return current.map((entry) => walk(entry, undefined, depth + 1));
    const output: Record<string, unknown> = {};
    for (const [entryKey, entry] of Object.entries(current)) {
      // Central projection semantics cover property names as well as values.
      const safeKey = redactSubagentLogText(entryKey, explicit);
      output[safeKey] = walk(entry, entryKey, depth + 1);
    }
    return output;
  };
  return walk(value) as T;
}

function clipLogLine(line: string): string {
  if (line.length <= SUBAGENT_LOG_LINE_MAX_CHARS) return line;
  const keep = Math.max(0, SUBAGENT_LOG_LINE_MAX_CHARS - SUBAGENT_LOG_TRUNCATION_MARKER.length);
  return `${line.slice(0, keep)}${SUBAGENT_LOG_TRUNCATION_MARKER}`;
}

export interface SubagentLogTailText {
  lines: string[];
  truncated: boolean;
  text: string;
}

function boundTailLines(
  lines: readonly string[],
  tailLines: number,
  alreadyTruncated: boolean,
  secrets: readonly string[],
): SubagentLogTailText {
  let truncated = alreadyTruncated || lines.length > tailLines;
  let out = lines.length > tailLines ? lines.slice(lines.length - tailLines) : [...lines];
  out = out.map((line) => {
    const redacted = redactSubagentLogText(line, secrets);
    const bounded = clipLogLine(redacted);
    if (bounded !== redacted) truncated = true;
    return bounded;
  });

  const lineBytes = out.map((line) => Buffer.byteLength(line, "utf8"));
  let bodyBytes = lineBytes.reduce((sum, size) => sum + size, 0) + Math.max(0, out.length - 1);
  const markerBytes = Buffer.byteLength(SUBAGENT_LOG_TRUNCATION_MARKER, "utf8");
  let start = 0;
  while (
    start < out.length &&
    (bodyBytes > SUBAGENT_LOG_READ_MAX_BYTES ||
      (truncated && bodyBytes + markerBytes + 1 > SUBAGENT_LOG_READ_MAX_BYTES))
  ) {
    bodyBytes -= lineBytes[start]! + (start < out.length - 1 ? 1 : 0);
    start += 1;
    truncated = true;
  }
  if (start > 0) out = out.slice(start);

  const body = out.join("\n");
  const text = truncated
    ? body === ""
      ? SUBAGENT_LOG_TRUNCATION_MARKER
      : body.includes(SUBAGENT_LOG_TRUNCATION_MARKER)
        ? body
        : `${body}\n${SUBAGENT_LOG_TRUNCATION_MARKER}`
    : body;
  return { lines: out, truncated, text };
}

export function tailSubagentLogText(
  content: string,
  tailLines?: number,
  secrets: readonly string[] = [],
): SubagentLogTailText {
  const budget = clampSubagentLogTailLines(tailLines);
  const lines = content.split(/\r?\n/);
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return boundTailLines(lines, budget, false, secrets);
}

export interface ReadSubagentLogOptions {
  sessionId: string;
  dir?: string;
  tailLines?: number;
  secrets?: readonly string[];
  /** Runs after the real parent is open and immediately before the file open. */
  onDirectoryOpen?: DirectoryOpenHook;
}

export interface SubagentLogTail extends SubagentLogTailText {
  sessionId: string;
  path: string;
  tailLines: number;
}

function countNewlines(buffer: Buffer): number {
  let count = 0;
  for (const byte of buffer) if (byte === 0x0a) count += 1;
  return count;
}

function noFollowReadFlags(): number {
  return constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0);
}

export async function readSubagentLogTail(
  options: ReadSubagentLogOptions,
): Promise<SubagentLogTail> {
  const path = subagentLogPath(options.sessionId, options.dir ?? SUBAGENT_LOG_DIR);
  const tailLines = clampSubagentLogTailLines(options.tailLines);
  let handle: FileHandle;
  try {
    handle = await openConfinedLogFile({
      path,
      directory: dirname(path),
      createDirectory: false,
      flags: noFollowReadFlags(),
      ...(options.onDirectoryOpen !== undefined
        ? { onDirectoryOpen: options.onDirectoryOpen }
        : {}),
    });
  } catch (error) {
    if (errnoCode(error) === "ENOENT") {
      throw new SubagentLogNotFoundError(options.sessionId);
    }
    throw error;
  }
  try {
    const info = await handle.stat();
    if (!info.isFile()) throw new SubagentLogPathError(options.sessionId);
    if (info.size === 0) {
      return {
        sessionId: options.sessionId,
        path,
        tailLines,
        lines: [],
        truncated: false,
        text: "",
      };
    }
    let position = info.size;
    let buffer = Buffer.alloc(0);
    let scanned = 0;
    while (
      position > 0 &&
      countNewlines(buffer) <= tailLines &&
      scanned < SUBAGENT_LOG_READ_MAX_BYTES
    ) {
      const readSize = Math.min(
        TAIL_CHUNK_BYTES,
        position,
        SUBAGENT_LOG_READ_MAX_BYTES - scanned,
      );
      if (readSize <= 0) break;
      position -= readSize;
      scanned += readSize;
      const chunk = Buffer.alloc(readSize);
      const { bytesRead } = await handle.read(chunk, 0, readSize, position);
      buffer = Buffer.concat([chunk.subarray(0, bytesRead), buffer]);
    }
    const truncated = position > 0;
    let lines = buffer.toString("utf8").split(/\r?\n/);
    if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
    if (truncated && lines.length > 0) {
      lines.shift();
      if (lines.length === 0) {
        lines = [buffer.toString("utf8").slice(-SUBAGENT_LOG_LINE_MAX_CHARS)];
      }
    }
    return {
      sessionId: options.sessionId,
      path,
      tailLines,
      ...boundTailLines(lines, tailLines, truncated, options.secrets ?? []),
    };
  } finally {
    await handle.close();
  }
}

export type SubagentLogEntry = Record<string, unknown> & { type: string };

export interface SubagentLog {
  readonly path: string;
  append(entry: SubagentLogEntry): Promise<void>;
  close(): Promise<void>;
  lastError(): Error | null;
  truncated(): boolean;
}

export interface CreateSubagentLogOptions {
  sessionId: string;
  dir?: string;
  now?: () => number;
  header?: Record<string, unknown>;
  secrets?: readonly string[];
  /** Test seam for the same cap algorithm; production default is exactly 16 MiB. */
  maxBytes?: number;
  /** Runs after the real parent is open and immediately before the file open. */
  onDirectoryOpen?: DirectoryOpenHook;
}

export async function createSubagentLog(
  options: CreateSubagentLogOptions,
): Promise<SubagentLog> {
  const path = subagentLogPath(options.sessionId, options.dir ?? SUBAGENT_LOG_DIR);
  const dir = dirname(path);
  const maxBytes = options.maxBytes ?? SUBAGENT_LOG_MAX_BYTES;
  if (!Number.isInteger(maxBytes) || maxBytes < 1) throw new RangeError("Invalid log byte cap");
  const handle = await openConfinedLogFile({
    path,
    directory: dir,
    createDirectory: true,
    flags: constants.O_APPEND |
      constants.O_CREAT |
      constants.O_WRONLY |
      (constants.O_NOFOLLOW ?? 0),
    mode: 0o600,
    ...(options.onDirectoryOpen !== undefined
      ? { onDirectoryOpen: options.onDirectoryOpen }
      : {}),
  });
  try {
    await handle.chmod(0o600);
    const info = await handle.stat();
    if (!info.isFile()) throw new SubagentLogPathError(options.sessionId);
    let bytes = info.size;
    let tail: Promise<void> = Promise.resolve();
    let closed = false;
    let error: Error | null = null;
    let wasTruncated = bytes >= maxBytes;
    let truncationWritten = false;

    const appendLine = async (line: string, isTruncation = false): Promise<void> => {
      const size = Buffer.byteLength(line, "utf8");
      if (bytes + size > maxBytes) {
        wasTruncated = true;
        if (!isTruncation && !truncationWritten) {
          truncationWritten = true;
          const marker = `${JSON.stringify({
            ts: (options.now ?? Date.now)(),
            type: "subagent_log_truncated",
          })}\n`;
          // Await the marker inside this same queued operation. close() therefore
          // cannot race a separately chained marker write after an overflow.
          await appendLine(marker, true);
        }
        return;
      }
      await handle.write(line);
      bytes += size;
    };

    const write = (entry: SubagentLogEntry): Promise<void> => {
      if (closed) return tail;
      const stamped = {
        ts: (options.now ?? Date.now)(),
        ...entry,
      };
      tail = tail.then(async () => {
        const line = `${JSON.stringify(redactSubagentLogValue(
          stamped,
          options.secrets ?? [],
        ))}\n`;
        await appendLine(line);
      }).catch((caught: unknown) => {
        error ??= caught instanceof Error ? caught : new Error(String(caught));
      });
      return tail;
    };

    const log: SubagentLog = {
      path,
      append: write,
      async close() {
        if (!closed) {
          closed = true;
          await tail;
          await handle.close().catch((caught: unknown) => {
            error ??= caught instanceof Error ? caught : new Error(String(caught));
          });
        } else {
          await tail;
        }
      },
      lastError: () => error,
      truncated: () => wasTruncated,
    };
    await write({
      type: "subagent_log_started",
      sessionId: options.sessionId,
      ...(options.header ?? {}),
    });
    return log;
  } catch (error) {
    await handle.close().catch(() => {});
    throw error;
  }
}

export type AuthorizedSubagentLogResult =
  | (SubagentLogTail & { available: true })
  | {
      available: false;
      sessionId: string;
      lines: [];
      truncated: false;
      text: "log unavailable";
    };

/** External/model-facing seam: only @id + actual supervisor children, never a path. */
export async function readAuthorizedSubagentLog(options: {
  reference: string;
  children: readonly { sessionId: string }[];
  dir?: string;
  tailLines?: number;
  secrets?: readonly string[];
}): Promise<AuthorizedSubagentLogResult> {
  if (!options.reference.startsWith("@")) throw new SubagentLogAuthorizationError();
  const sessionId = options.reference.slice(1);
  if (!SAFE_ID.test(sessionId) || !options.children.some((child) => child.sessionId === sessionId)) {
    throw new SubagentLogAuthorizationError();
  }
  try {
    const tail = await readSubagentLogTail({
      sessionId,
      ...(options.dir !== undefined ? { dir: options.dir } : {}),
      ...(options.tailLines !== undefined ? { tailLines: options.tailLines } : {}),
      ...(options.secrets !== undefined ? { secrets: options.secrets } : {}),
    });
    return { available: true, ...tail };
  } catch (error) {
    if (error instanceof SubagentLogNotFoundError) {
      return {
        available: false,
        sessionId,
        lines: [],
        truncated: false,
        text: "log unavailable",
      };
    }
    throw error;
  }
}
