/**
 * Hydration engine — full cold→warm extraction plus the lazy single-file read
 * path (P7 Task 9, spike §9.1/§9.3).
 *
 * Two read modes, one source of truth:
 *
 *  - WARM: the session dir exists on disk. Reads are jailed to it with a
 *    realpath prefix check (a planted symlink can never serve /etc/*), and
 *    v1 serves regular files only (dirs/symlinks → NotFoundError).
 *  - COLD: the dir stays ABSENT. The archive index comes from the sidecar
 *    (`*.manifest.json`) — or, when that is missing/corrupt, from the archive
 *    footer via `readIndex` (indexHash-verified) — and one member is
 *    range-read out of the archive (`extractFile`). This is the Studio lazy
 *    path: a cold session never pays a full extraction to open one file.
 *
 * `hydrateWorkspace` is the full path. Its pinned order mirrors Task 8:
 * claim (beginHydration) → reclaim any crash-remnant dir (the T8-review carry:
 * a cold row may still carry its warm dir after a crash between the durable
 * cold marker and the local rm) → read the index → extractAll → du →
 * markWarm → activity.bump → event + mirror. ANY failure in the extraction
 * phase wipes the partial dir and flips the row back to cold through the
 * injected `markColdRetry` (a state-rechecked UPDATE, T6 carry), then throws
 * the typed error so BullMQ's attempts:3 retries cleanly. The whole-archive
 * sha256 is deliberately NOT recomputed here — hibernate verified it at
 * upload; per-frame xxh64 + per-file sha256 guard every read (spike §9.1).
 *
 * @ovid/db / @ovid/events / @ovid/queue are consumed ONLY through the
 * structural mirrors below (same pattern as hibernate.ts: @ovid/storage has
 * no package edge on them, and the parallel-wave NO-lockfile rule forbids
 * adding one). `awaitWarm` is the one exception forced by its pinned 4-arg
 * signature (`db` is the only handle it receives): it reads the two fields it
 * polls through `db.$client.unsafe` — the real drizzle handle's postgres.js
 * client — or through the optional injected `fileManifests` repo when the
 * wiring layer chooses to pass one.
 */

import { createHash, randomBytes } from "node:crypto";
import {
  chmod,
  lstat,
  mkdir,
  readFile,
  realpath,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { dirname, join, sep } from "node:path";
import type { SessionEvent, SessionEventType, WorkspaceState } from "@ovid/shared";

import type { ActivityTracker } from "./activity.js";
import type { StorageAdapter } from "./adapter.js";
import { extractAll, extractFile } from "./archive/extract.js";
import { ARCHIVE_VERSION, FORMAT_NAME } from "./archive/format.js";
import {
  decodeIndexWire,
  walkWorkspace,
  type ArchiveIndex,
} from "./archive/pack.js";
import { readIndex } from "./archive/readIndex.js";
import {
  ArchiveCorruptError,
  FileNotInArchiveError,
  FileTooLargeError,
  NotFoundError,
  StorageError,
  WorkspaceStateError,
} from "./errors.js";
import type { FileManifestRowView } from "./hibernate.js";
import { assertSafeRelPath, r2Keys } from "./keys.js";
import { openReader } from "./rangeReader.js";
import { workspaceDir } from "./workspacePaths.js";

// ---------------------------------------------------------------------------
// Structural mirrors of the @ovid/db / @ovid/queue surfaces (exact signatures;
// the wiring layer injects the real namespaces with zero adapter code)
// ---------------------------------------------------------------------------

/** Opaque stand-in for @ovid/db's `Db` — only threaded through to the repos. */
export type HydrateDbLike = unknown;

/** Mirror of @ovid/queue's `HydrateReason`. */
export type HydrateReason = "run" | "open" | "write" | "manual";

/** Mirror of @ovid/queue's `HydrateJob`. */
export interface HydrateJob {
  sessionId: string;
  userId: string;
  /** The cold row's generation to restore; 0 = never hibernated. */
  generation: number;
  reason: HydrateReason;
}

/** Mirror of @ovid/queue's HYDRATE_JOB_NAME. */
export const HYDRATE_JOB_NAME = "hydrate-workspace";

/**
 * The file_manifests surface hydration needs. `markColdRetry` is NEW (the
 * @ovid/db repo has no such method yet): the wiring layer supplies a
 * state-rechecked `UPDATE … SET state='cold' WHERE session_id=$1 AND
 * state='hydrating'` so a failed attempt can never stomp a concurrent
 * transition (T6 carry). The other four methods are the real repo's exact
 * signatures.
 */
export interface HydrateFileManifestsRepo {
  get(db: HydrateDbLike, sessionId: string): Promise<FileManifestRowView | null>;
  /** Race-safe cold → hydrating claim (false = not cold / unknown). */
  beginHydration(db: HydrateDbLike, sessionId: string): Promise<boolean>;
  /** Terminal hydrate write; the caller holds the beginHydration claim. */
  markWarm(db: HydrateDbLike, i: { sessionId: string; workspaceBytes: number | null }): Promise<void>;
  upsertWarm(
    db: HydrateDbLike,
    i: { sessionId: string; userId: string; workspaceBytes: number | null },
  ): Promise<unknown>;
  /** Failure restore: cold again, ONLY while the row is still 'hydrating'. */
  markColdRetry(db: HydrateDbLike, sessionId: string): Promise<void>;
}

/** Mirror of @ovid/events' `EventLog.append`. */
export interface HydrateEventLog {
  append(
    sessionId: string,
    type: SessionEventType,
    payload: Record<string, unknown>,
  ): Promise<SessionEvent>;
}

/** Mirror of @ovid/db's `eventMirror.put`. */
export interface HydrateEventMirror {
  put(db: HydrateDbLike, e: SessionEvent): Promise<void>;
}

export interface HydrateDeps {
  db: HydrateDbLike;
  events: HydrateEventLog;
  storage: StorageAdapter;
  workspacesRoot: string;
  activity: ActivityTracker;
  clock?: () => Date;
  /** The real @ovid/db repo namespaces, injected by the wiring layer. */
  fileManifests: HydrateFileManifestsRepo;
  eventMirror: HydrateEventMirror;
}

export interface HydrateResult {
  status: "hydrated" | "skipped";
  reason?: "already_warm" | "stale_generation" | "no_archive";
  files?: number;
  ms?: number;
}

export interface ReadFileResult {
  bytes: Buffer;
  sizeBytes: number;
  sha256Hex: string;
  contentType: string;
  source: "warm" | "archive";
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function sha256Hex(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

async function isDirectory(p: string): Promise<boolean> {
  try {
    return (await stat(p)).isDirectory();
  } catch {
    return false;
  }
}

/**
 * Recursive sum of REGULAR-FILE bytes. Task 10's warmLru owns the exported
 * `du`; hydration only needs the one value at markWarm time. Symlink target
 * bytes are excluded (they are not disk usage), matching `du`'s pinned
 * contract.
 */
async function du(dir: string): Promise<number> {
  const entries = await walkWorkspace(dir);
  let total = 0;
  for (const e of entries) {
    if (e.type === 0) total += e.size;
  }
  return total;
}

/** Stable per-(session, generation) job id — T7's `storageJobId` (mirrored). */
function storageJobId(sessionId: string, generation: number): string {
  return `${sessionId}~${generation}`;
}

function asHydrateError(err: unknown, sessionId: string): StorageError {
  if (err instanceof StorageError) return err;
  const detail = err instanceof Error ? err.message : String(err);
  return new StorageError(`hydrate of session ${sessionId} failed: ${detail}`, {
    code: "hydrate_failed",
    cause: err,
  });
}

// ---------------------------------------------------------------------------
// Content-type policy (shared by the lazy read path and the artifacts pipeline)
// ---------------------------------------------------------------------------

const CONTENT_TYPES: Readonly<Record<string, string>> = {
  ".ts": "text/plain",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".json": "application/json",
  ".md": "text/markdown",
  ".txt": "text/plain",
  ".html": "text/html",
  ".css": "text/css",
  ".csv": "text/csv",
  ".log": "text/plain",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".gif": "image/gif",
  ".pdf": "application/pdf",
  ".zip": "application/zip",
  ".tar": "application/x-tar",
  ".gz": "application/gzip",
  ".so": "application/octet-stream",
};

/** Extension map for workspace/artifact content types (default octet-stream). */
export function contentTypeFor(name: string): string {
  const base = name.slice(name.lastIndexOf("/") + 1);
  const dot = base.lastIndexOf(".");
  if (dot <= 0) return "application/octet-stream";
  return CONTENT_TYPES[base.slice(dot).toLowerCase()] ?? "application/octet-stream";
}

const INLINE_APPLICATION_TYPES: ReadonlySet<string> = new Set([
  "application/json",
  "application/javascript",
  "application/xml",
  "image/svg+xml",
]);

/**
 * True iff a file must be served via a presigned redirect rather than inline:
 * larger than the inline cap, OR not text/* and not one of the small set of
 * inline-safe application types.
 */
export function shouldPresign(
  contentType: string,
  sizeBytes: number,
  inlineMaxBytes: number,
): boolean {
  if (sizeBytes > inlineMaxBytes) return true;
  const base = (contentType.split(";")[0] ?? "").trim().toLowerCase();
  if (base.startsWith("text/")) return false;
  return !INLINE_APPLICATION_TYPES.has(base);
}

// ---------------------------------------------------------------------------
// Archive index cache — per process, keyed `${sessionId}:${generation}`.
// FIFO-evict at INDEX_CACHE_MAX_ENTRIES: a hot session keeps its index while
// the Studio reads many files; old sessions fall out in insertion order.
// ---------------------------------------------------------------------------

export const INDEX_CACHE_MAX_ENTRIES = 8;

const indexCache = new Map<string, ArchiveIndex>();

/** Test seam: drop every cached index. */
export function clearIndexCache(): void {
  indexCache.clear();
}

function cacheIndex(key: string, index: ArchiveIndex): void {
  if (!indexCache.has(key) && indexCache.size >= INDEX_CACHE_MAX_ENTRIES) {
    const oldest = indexCache.keys().next().value;
    if (oldest !== undefined) indexCache.delete(oldest);
  }
  indexCache.set(key, index);
}

/**
 * Sidecar-first index load (one small GET, no reader setup); falls back to
 * the archive footer's index frame, which verifies indexHash. Only a
 * successful decode is cached.
 */
async function loadIndex(
  deps: HydrateDeps,
  userId: string,
  sessionId: string,
  generation: number,
  archiveKey: string,
): Promise<ArchiveIndex> {
  const cacheKey = `${sessionId}:${generation}`;
  const cached = indexCache.get(cacheKey);
  if (cached !== undefined) return cached;

  const sidecarKey = r2Keys.workspaceManifest(userId, sessionId);
  try {
    const buf = await deps.storage.getBuffer(sidecarKey);
    if (buf !== null) {
      const index = decodeIndexWire(buf);
      cacheIndex(cacheKey, index);
      return index;
    }
  } catch {
    // Corrupt sidecar: fall through to the indexHash-verified archive read.
  }

  const spec = await deps.storage.readerSpec(archiveKey);
  if (spec === null) {
    throw new NotFoundError(`workspace archive ${archiveKey} is missing`);
  }
  const reader = await openReader(spec);
  let index: ArchiveIndex;
  try {
    index = await readIndex(reader);
  } finally {
    await reader.close();
  }
  cacheIndex(cacheKey, index);
  return index;
}

/**
 * Realpath jail for a path whose leaf may not exist yet: resolve the nearest
 * EXISTING ancestor and require it to stay under the resolved workspace root.
 * Checking before `mkdir -p` is load-bearing — a symlinked component inside
 * the workspace must not let directory creation land outside it.
 */
async function assertParentInsideWorkspace(realDir: string, target: string): Promise<void> {
  let probe = target;
  for (;;) {
    try {
      const real = await realpath(probe);
      if (real !== realDir && !real.startsWith(realDir + sep)) {
        throw new NotFoundError(`'${target}' resolves outside the workspace`);
      }
      return;
    } catch (err) {
      if (err instanceof StorageError) throw err;
      const up = dirname(probe);
      if (up === probe) {
        throw new NotFoundError(`'${target}' has no resolvable ancestor`);
      }
      probe = up;
    }
  }
}

// ---------------------------------------------------------------------------
// hydrateWorkspace — cold → warm
// ---------------------------------------------------------------------------

export async function hydrateWorkspace(
  deps: HydrateDeps,
  job: HydrateJob,
  opts: { workers?: number } = {},
): Promise<HydrateResult> {
  const clock = deps.clock ?? (() => new Date());
  const startedMs = clock().getTime();
  const dir = workspaceDir(deps.workspacesRoot, job.userId, job.sessionId);

  const row = await deps.fileManifests.get(deps.db, job.sessionId);
  if (row === null) {
    return { status: "skipped", reason: "no_archive" };
  }
  if (row.state !== "cold") {
    // warm / hydrating (another job owns it) / hibernating: nothing to do.
    return { status: "skipped", reason: "already_warm" };
  }
  if (job.generation !== row.generation) {
    return { status: "skipped", reason: "stale_generation" };
  }
  // A cold row with no archive has nothing to restore (generation 0, never
  // hibernated). The warm-state check above wins for a never-hibernated warm
  // session, which must answer already_warm rather than no_archive.
  if (row.archiveKey === null || row.archiveKey === "") {
    return { status: "skipped", reason: "no_archive" };
  }
  if (!(await deps.fileManifests.beginHydration(deps.db, job.sessionId))) {
    return { status: "skipped", reason: "already_warm" };
  }

  const archiveKey = row.archiveKey;
  let files = 0;
  try {
    // T8-review carry: wipe a crash-remnant dir FIRST. A crash between the
    // durable cold marker and the local rm (or a failed rm) leaves a full
    // warm dir behind a cold row; a clean retry must never extract over it.
    await rm(dir, { recursive: true, force: true });
    await mkdir(dir, { recursive: true });

    const spec = await deps.storage.readerSpec(archiveKey);
    if (spec === null) {
      throw new NotFoundError(`workspace archive ${archiveKey} is missing`);
    }
    const reader = await openReader(spec);
    let index: ArchiveIndex;
    try {
      index = await readIndex(reader);
    } finally {
      await reader.close();
    }
    // readIndex/decodeIndexWire already validated the wire shape; re-assert
    // the format identity so a foreign object can never seed a warm tree.
    if (index.archiveVersion !== ARCHIVE_VERSION || index.format !== FORMAT_NAME) {
      throw new ArchiveCorruptError(
        `archive ${archiveKey} is not an ${FORMAT_NAME} v${ARCHIVE_VERSION} object`,
      );
    }

    const report = await extractAll(
      spec,
      index,
      dir,
      opts.workers === undefined ? {} : { workers: opts.workers },
    );
    files = report.files;

    const workspaceBytes = await du(dir);
    // T6 carry: re-check the claim before the terminal warm write — a row
    // that moved on between the claim and here is never stomped.
    const current = await deps.fileManifests.get(deps.db, job.sessionId);
    if (current !== null && current.state === "hydrating") {
      await deps.fileManifests.markWarm(deps.db, {
        sessionId: job.sessionId,
        workspaceBytes,
      });
    }
  } catch (err) {
    // Partial tree never survives a failed attempt; the row goes back to
    // cold (state-rechecked) so BullMQ's attempts:3 retry extracts cleanly.
    await rm(dir, { recursive: true, force: true }).catch(() => {});
    await deps.fileManifests.markColdRetry(deps.db, job.sessionId).catch(() => {});
    throw asHydrateError(err, job.sessionId);
  }

  // The workspace is durably warm. A redis failure here loses the
  // notification (the retry converges to skipped already_warm) but must
  // never undo the extracted tree.
  await deps.activity.bump(job.sessionId);
  const ms = clock().getTime() - startedMs;
  const event = await deps.events.append(job.sessionId, "workspace_hydrated", {
    generation: job.generation,
    ms,
  });
  await deps.eventMirror.put(deps.db, event);

  return { status: "hydrated", files, ms };
}

// ---------------------------------------------------------------------------
// awaitWarm — shared by the worker's ensureWarm (Task 11) and the gateway
// (Task 12). Dedupes concurrent callers through the storage job id.
// ---------------------------------------------------------------------------

export interface AwaitWarmQueue {
  add(name: string, job: HydrateJob, opts: { jobId: string }): unknown;
}

export interface AwaitWarmOpts {
  reason: HydrateReason;
  timeoutMs: number;
  pollMs?: number;
  clock?: () => Date;
  /**
   * Optional injected repo. Without it the poll reads `generation`/`state`
   * through the drizzle handle's `$client` (see the module header).
   */
  fileManifests?: Pick<HydrateFileManifestsRepo, "get">;
}

interface ManifestStateView {
  generation: number;
  state: WorkspaceState;
}

interface DbWithClient {
  $client: {
    unsafe(query: string, params?: unknown[]): Promise<unknown>;
  };
}

async function readManifestState(
  db: HydrateDbLike,
  sessionId: string,
): Promise<ManifestStateView | null> {
  const client = (db as Partial<DbWithClient>).$client;
  if (client === undefined || typeof client.unsafe !== "function") {
    throw new WorkspaceStateError(
      "awaitWarm needs a db handle exposing $client.unsafe (or opts.fileManifests)",
    );
  }
  const rows = (await client.unsafe(
    `SELECT generation, state FROM file_manifests WHERE session_id = $1 LIMIT 1`,
    [sessionId],
  )) as Array<{ generation: number | string; state: string }>;
  const first = rows[0];
  if (first === undefined) return null;
  return { generation: Number(first.generation), state: first.state as WorkspaceState };
}

/**
 * Resolves once the session's workspace is warm (or absent — a missing row
 * means "never hibernated", and the disk is the truth downstream).
 *
 * cold      → enqueue hydrate-workspace with `jobId = storageJobId(sid, g)`
 *             (BullMQ returns the existing job for a duplicate id), then poll.
 * hydrating → poll only (another job owns the transition).
 * warm/none → resolve immediately.
 * timeout   → WorkspaceStateError code "hydrate_timeout".
 */
export async function awaitWarm(
  db: HydrateDbLike,
  hydrateQueue: AwaitWarmQueue,
  ref: { sessionId: string; userId: string },
  opts: AwaitWarmOpts,
): Promise<{ generation: number }> {
  const clock = opts.clock ?? (() => new Date());
  const pollMs = opts.pollMs ?? 250;
  const startedMs = clock().getTime();
  let added = false;

  const readState = async (): Promise<ManifestStateView | null> => {
    if (opts.fileManifests !== undefined) {
      const row = await opts.fileManifests.get(db, ref.sessionId);
      return row === null ? null : { generation: row.generation, state: row.state };
    }
    return readManifestState(db, ref.sessionId);
  };

  for (;;) {
    const row = await readState();
    if (row === null || row.state === "warm") {
      return { generation: row?.generation ?? 0 };
    }
    if (!added && row.state === "cold") {
      await Promise.resolve(
        hydrateQueue.add(
          HYDRATE_JOB_NAME,
          {
            sessionId: ref.sessionId,
            userId: ref.userId,
            generation: row.generation,
            reason: opts.reason,
          },
          { jobId: storageJobId(ref.sessionId, row.generation) },
        ),
      );
      added = true;
    }
    if (clock().getTime() - startedMs >= opts.timeoutMs) {
      throw new WorkspaceStateError(
        `workspace ${ref.sessionId} did not become warm within ${opts.timeoutMs} ms`,
        { code: "hydrate_timeout" },
      );
    }
    await new Promise((resolve) => setTimeout(resolve, pollMs));
  }
}

// ---------------------------------------------------------------------------
// readWorkspaceFile — warm-dir read or lazy archive member read
// ---------------------------------------------------------------------------

export async function readWorkspaceFile(
  deps: HydrateDeps,
  ref: { userId: string; sessionId: string; path: string },
  opts: { maxBytes?: number } = {},
): Promise<ReadFileResult> {
  const rel = assertSafeRelPath(ref.path);
  const maxBytes = opts.maxBytes ?? Number.POSITIVE_INFINITY;
  const dir = workspaceDir(deps.workspacesRoot, ref.userId, ref.sessionId);

  // -- warm truth ----------------------------------------------------------
  if (await isDirectory(dir)) {
    const full = join(dir, rel);
    // v1 serves regular files only: dirs and symlinks are not readable
    // members, even when they point inside the workspace.
    let linkStat: Awaited<ReturnType<typeof lstat>>;
    try {
      linkStat = await lstat(full);
    } catch {
      throw new NotFoundError(`'${rel}' is not present in the workspace`);
    }
    if (linkStat.isDirectory() || linkStat.isSymbolicLink()) {
      throw new NotFoundError(`'${rel}' is not a regular file`);
    }

    // Symlink-escape jail: the RESOLVED target must stay under the RESOLVED
    // workspace root (a planted link to /etc/hostname fails here).
    let realDir: string;
    let realFull: string;
    try {
      realDir = await realpath(dir);
      realFull = await realpath(full);
    } catch {
      throw new NotFoundError(`'${rel}' is not present in the workspace`);
    }
    if (realFull !== realDir && !realFull.startsWith(realDir + sep)) {
      throw new NotFoundError(`'${rel}' resolves outside the workspace`);
    }

    const st = await stat(realFull);
    if (!st.isFile()) throw new NotFoundError(`'${rel}' is not a regular file`);
    if (st.size > maxBytes) {
      throw new FileTooLargeError(`'${rel}' is ${st.size} bytes (> ${maxBytes} max)`, {
        sizeBytes: st.size,
      });
    }
    const bytes = await readFile(realFull);
    return {
      bytes,
      sizeBytes: bytes.length,
      sha256Hex: sha256Hex(bytes),
      contentType: contentTypeFor(rel),
      source: "warm",
    };
  }

  // -- lazy archive path (dir stays ABSENT) --------------------------------
  const row = await deps.fileManifests.get(deps.db, ref.sessionId);
  if (row !== null && row.archiveKey !== null && row.archiveKey !== "") {
    const index = await loadIndex(
      deps,
      ref.userId,
      ref.sessionId,
      row.generation,
      row.archiveKey,
    );
    const rec = index.files.find((f) => f.path === rel);
    if (rec === undefined || rec.type !== 0) {
      throw new FileNotInArchiveError(`'${rel}' is not a file in the archive`);
    }
    if (rec.size > maxBytes) {
      throw new FileTooLargeError(`'${rel}' is ${rec.size} bytes (> ${maxBytes} max)`, {
        sizeBytes: rec.size,
      });
    }

    const spec = await deps.storage.readerSpec(row.archiveKey);
    if (spec === null) {
      throw new NotFoundError(`workspace archive ${row.archiveKey} is missing`);
    }
    const reader = await openReader(spec);
    try {
      const { bytes } = await extractFile(reader, index, rel);
      return {
        bytes,
        sizeBytes: bytes.length,
        sha256Hex: sha256Hex(bytes),
        contentType: contentTypeFor(rel),
        source: "archive",
      };
    } finally {
      await reader.close();
    }
  }

  throw new NotFoundError(`workspace ${ref.sessionId} has no readable file '${rel}'`);
}

// ---------------------------------------------------------------------------
// writeWorkspaceFile — warm-only, atomic temp+rename
// ---------------------------------------------------------------------------

export async function writeWorkspaceFile(
  deps: HydrateDeps,
  ref: { userId: string; sessionId: string; path: string },
  content: Buffer,
): Promise<{ path: string; sizeBytes: number; sha256Hex: string }> {
  const rel = assertSafeRelPath(ref.path);
  const dir = workspaceDir(deps.workspacesRoot, ref.userId, ref.sessionId);
  if (!(await isDirectory(dir))) {
    throw new WorkspaceStateError(
      `workspace ${ref.sessionId} is not warm — hydrate before writing`,
      { code: "not_warm" },
    );
  }

  const dest = join(dir, rel);
  const parent = dirname(dest);
  const realDir = await realpath(dir);
  // Same realpath jail as reads: a symlinked parent can never redirect the
  // write outside the workspace. Checked BEFORE mkdir so no directory is
  // created through an escaping symlink.
  await assertParentInsideWorkspace(realDir, parent);
  await mkdir(parent, { recursive: true });

  // Cheap du accounting: the delta from the file being replaced. Never a
  // recursive du on the write path (the T10 sweeper owns exact refresh).
  let priorSize = 0;
  try {
    const prev = await lstat(dest);
    if (prev.isFile()) priorSize = prev.size;
  } catch {
    priorSize = 0;
  }

  const tmp = `${dest}.part-${process.pid}-${randomBytes(4).toString("hex")}`;
  try {
    await writeFile(tmp, content);
    await chmod(tmp, 0o644);
    await rename(tmp, dest);
  } catch (err) {
    await rm(tmp, { force: true }).catch(() => {});
    throw err;
  }

  const sha256 = sha256Hex(content);
  await deps.activity.bump(ref.sessionId);

  // T6 carry: re-read the row and only refresh while it is still warm — the
  // upsert's conflict arm forces state='warm', so it must never race a
  // hibernate claim. Missing row / null du: the sweeper registers/refreshes.
  const row = await deps.fileManifests.get(deps.db, ref.sessionId);
  if (row !== null && row.state === "warm" && row.workspaceBytes !== null) {
    await deps.fileManifests.upsertWarm(deps.db, {
      sessionId: ref.sessionId,
      userId: ref.userId,
      workspaceBytes: Math.max(0, row.workspaceBytes + content.length - priorSize),
    });
  }

  return { path: rel, sizeBytes: content.length, sha256Hex: sha256 };
}

