/**
 * Hibernation engine — pack, verified upload, crash-safe evict (P7 Task 8,
 * spike §9.3). The pinned order is load-bearing for crash safety:
 *
 *   verify (active run / fresh activity / warm dir) → claim (generation +
 *   beginHibernation) → sandbox evict → pack+upload → sidecar → VERIFY
 *   (head bytes + full re-download sha256 + readIndex) → Postgres cold
 *   marker → ONLY THEN fs.rm the local dir → event + mirror.
 *
 * Local data is deleted strictly after the verified upload AND the durable
 * cold marker. R2 has zero egress fees, so the full re-download re-hash is
 * affordable and is the ONLY guarantee strong enough to justify deleting the
 * only other copy (per-file hashes protect hydration, but a corrupt upload
 * would otherwise destroy the source).
 *
 * Crash windows, precisely: BEFORE the cold marker commits, a crash leaves
 * the row 'hibernating' with the dir intact — reconcileStuckHibernations
 * resets it to warm for a later re-pack. AFTER the marker commits (before or
 * during the local rm), the workspace is DURABLY cold — archive verified,
 * ledger written, data safety complete — and only local bytes linger on
 * disk: the BullMQ retry skips stale_generation, reconcile scans
 * 'hibernating' rows only, and reclamation of that residue is owned
 * downstream (T9's wipe-a-present-dir-before-extract on hydrate; T10's
 * reconcile delegation for never-reopened sessions — ledgered carry), not by
 * this engine.
 *
 * @ovid/db / @ovid/events / @ovid/queue are consumed here ONLY through the
 * structural mirrors below — @ovid/storage cannot take a dependency on them
 * (pnpm links only declared deps, and the parallel-wave NO-lockfile rule
 * forbids adding any). The method-syntax interfaces are exactly the real
 * namespaces' signatures, so the wiring layer injects the real repos with
 * zero adapter code (the same pattern activity.ts uses for redis). The test
 * suite pins the fit by injecting the REAL @ovid/db / @ovid/events objects.
 */

import { createHash } from "node:crypto";
import { rm as rmDir, stat } from "node:fs/promises";
import type {
  SessionEvent,
  SessionEventType,
  UiManifest,
  WorkspaceState,
} from "@ovid/shared";

import type { ActivityTracker } from "./activity.js";
import type { StorageAdapter } from "./adapter.js";
import { packToStorage, encodeIndexWire, type ArchiveIndex, type PackReport } from "./archive/pack.js";
import { readIndex } from "./archive/readIndex.js";
import { uiTree } from "./archive/uiTree.js";
import { StorageError } from "./errors.js";
import { r2Keys } from "./keys.js";
import { openReader } from "./rangeReader.js";
import { workspaceDir } from "./workspacePaths.js";

/** G7: 3-minute idle before a warm workspace is hibernated. */
export const HIBERNATE_IDLE_MS = 180_000;

// ---------------------------------------------------------------------------
// SandboxEviction — the P2 seam (controller ruling R1, cross-plan contract 1)
// ---------------------------------------------------------------------------

/** Per-session warm entry as P2's SandboxManager enumerates them. */
export interface WarmWorkspaceEntry {
  userId: string;
  sessionId: string;
  bytes: number;
  lastAccessMs: number | null;
}

/**
 * CONSUMED from @ovid/sandbox (ruling R1, contract 1). `evictWorkspace` is a
 * pack-safe destroy via SandboxManager: kill the jail/PTY/background jobs for
 * the session, LEAVE the files (the engine packs them afterwards and deletes
 * them itself only once the upload is verified). P7 never raw-walks the
 * per-user session dirs under workspacesRoot — Postgres file_manifests /
 * workspace_objects stay the authority.
 */
export interface SandboxEviction {
  listWarmWorkspaces(): Promise<WarmWorkspaceEntry[]>;
  evictWorkspace(userId: string, sessionId: string): Promise<void>;
}

/**
 * Pre-P2 stand-in: `listWarmWorkspaces()` returns [] (the sweeper registers
 * nothing until P2 lands — logged once) and `evictWorkspace` resolves and
 * logs (TODO(P2) markers). Swap the real SandboxManager-backed seam in when
 * P2 lands; the engine and sweeper need no other change.
 */
export function createNoopSandboxEviction(log?: (msg: string) => void): SandboxEviction {
  let listLogged = false;
  return {
    async listWarmWorkspaces(): Promise<WarmWorkspaceEntry[]> {
      if (!listLogged) {
        listLogged = true;
        log?.(
          "TODO(P2): SandboxEviction.listWarmWorkspaces is the pre-P2 stand-in — returning [] " +
            "(the sweeper registers nothing until P2 lands)",
        );
      }
      return [];
    },
    async evictWorkspace(userId: string, sessionId: string): Promise<void> {
      log?.(
        `TODO(P2): noop SandboxEviction.evictWorkspace(${userId}, ${sessionId}) — P2's ` +
          "SandboxManager will kill the session's jail/PTY/background jobs and LEAVE the files",
      );
    },
  };
}

// ---------------------------------------------------------------------------
// Structural mirrors of the @ovid/db / @ovid/queue / @ovid/events surfaces
// (see the module header — no package dependency, exact signatures)
// ---------------------------------------------------------------------------

/**
 * Opaque stand-in for @ovid/db's `Db`: the engine only THREADS the handle
 * through to the injected repos below, never touches it directly. The wiring
 * layer passes its real drizzle handle; the method-syntax mirrors make that
 * structurally valid.
 */
export type DbLike = unknown;

/** The file_manifests fields the engine reads (a subset of the real row). */
export interface FileManifestRowView {
  sessionId: string;
  userId: string;
  generation: number;
  state: WorkspaceState;
  archiveKey: string | null;
  workspaceBytes: number | null;
  updatedAt: Date;
}

/** Mirror of @ovid/db's `fileManifests` repo namespace. */
export interface FileManifestsRepo {
  get(db: DbLike, sessionId: string): Promise<FileManifestRowView | null>;
  /** Race-safe warm → hibernating claim (false = not warm / unknown). */
  beginHibernation(db: DbLike, sessionId: string): Promise<boolean>;
  /** Terminal cold write; the caller holds the beginHibernation claim. */
  markCold(
    db: DbLike,
    i: {
      sessionId: string;
      generation: number;
      archiveKey: string;
      archiveBytes: number;
      archiveSha256: string;
      entryCount: number;
      uiTree: UiManifest;
    },
  ): Promise<void>;
  markWarm(db: DbLike, i: { sessionId: string; workspaceBytes: number | null }): Promise<void>;
  remove(db: DbLike, sessionId: string): Promise<void>;
}

/** Mirror of @ovid/db's `workspaceObjects` repo namespace (T6 ruling shape). */
export interface WorkspaceObjectsRepo {
  putArchive(
    db: DbLike,
    i: {
      userId: string;
      sessionId: string;
      generation: number;
      archiveKey: string;
      manifestKey: string;
      bytes: number;
      sha256: string;
      entryCount: number;
      manifestBytes: number;
      manifestSha256: string;
    },
  ): Promise<void>;
}

/** Mirror of @ovid/db's `runs` repo namespace (null = no queued|running run). */
export interface RunsRepo {
  activeForSession(db: DbLike, sessionId: string): Promise<unknown>;
}

/** Mirror of @ovid/db's `eventMirror` repo namespace. */
export interface EventMirrorRepo {
  put(db: DbLike, e: SessionEvent): Promise<void>;
}

/** Mirror of @ovid/events' `EventLog` (redis streams + pub/sub ledger). */
export interface SessionEventLog {
  append(
    sessionId: string,
    type: SessionEventType,
    payload: Record<string, unknown>,
  ): Promise<SessionEvent>;
}

/** Rows stranded in state 'hibernating' past the stuck window. */
export type StuckHibernationRow = FileManifestRowView;

/**
 * Crash-stranded-row scan (method syntax keeps it bivariant-assignable). The
 * @ovid/db repo layer has no stuck-row query yet, so the wiring layer owns
 * this select: `WHERE state = 'hibernating' AND updated_at < $1` over
 * file_manifests.
 */
export interface StuckHibernationScan {
  listStuck(db: DbLike, olderThan: Date): Promise<StuckHibernationRow[]>;
}

/** Mirror of @ovid/queue's `HibernateJob` (`reason` rides along untouched). */
export interface HibernateJobInput {
  sessionId: string;
  userId: string;
  /** Row generation + 1; a stale value skips with `stale_generation`. */
  generation: number;
  reason: "idle" | "pressure" | "manual";
}

export interface HibernateDeps {
  db: DbLike;
  events: SessionEventLog;
  storage: StorageAdapter;
  /** The warm-workspace tree root (dev/tests pass the user id as the uid segment — the helper accepts both). */
  workspacesRoot: string;
  sandbox: SandboxEviction;
  activity: ActivityTracker;
  clock?: () => Date;
  /** The real @ovid/db repo namespaces, injected by the wiring layer. */
  fileManifests: FileManifestsRepo;
  workspaceObjects: WorkspaceObjectsRepo;
  runs: RunsRepo;
  eventMirror: EventMirrorRepo;
  /** The wiring layer's stuck-hibernating-row scan (see StuckHibernationScan). */
  stuckHibernationScan: StuckHibernationScan;
}

export interface HibernateResult {
  status: "hibernated" | "skipped";
  reason?: "not_warm" | "stale_generation" | "active_run" | "recent_activity" | "already_cold";
  generation?: number;
  archiveBytes?: number;
  ms?: number;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

async function pathExists(p: string): Promise<boolean> {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

function sha256Hex(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

/** Full re-download sha256 of a stored object, as one hex string. */
async function rehashObject(storage: StorageAdapter, key: string): Promise<string | null> {
  const stream = await storage.get(key);
  if (stream === null) return null;
  const hash = createHash("sha256");
  for await (const chunk of stream) {
    hash.update(chunk as Buffer);
  }
  return hash.digest("hex");
}

function asStorageError(err: unknown, sessionId: string): StorageError {
  if (err instanceof StorageError) return err;
  const detail = err instanceof Error ? err.message : String(err);
  return new StorageError(`hibernate of session ${sessionId} failed: ${detail}`, {
    code: "hibernate_failed",
    cause: err,
  });
}

/**
 * Best-effort restore to warm after a failed attempt. T6-review carry (the
 * upsertWarm conflict-arm stomp): the state is RE-CHECKED around the write —
 * the restore lands only while the row still sits in the claim this engine
 * holds; a concurrent cold completion or sweeper re-warm is never stomped.
 * The engine itself never calls upsertWarm: its restore path is markWarm
 * under the beginHibernation claim, so the conflict arm is never armed here.
 */
async function restoreWarm(
  deps: HibernateDeps,
  sessionId: string,
  priorWorkspaceBytes: number | null,
): Promise<void> {
  try {
    const row = await deps.fileManifests.get(deps.db, sessionId);
    if (row === null || row.state !== "hibernating") return;
    await deps.fileManifests.markWarm(deps.db, {
      sessionId,
      workspaceBytes: priorWorkspaceBytes,
    });
  } catch {
    // Best-effort: on failure the row stays 'hibernating' and the next
    // reconcileStuckHibernations pass (worker boot + sweeper) closes it.
  }
}

/**
 * Verify-before-delete (pinned): head bytes, a full re-download sha256, and a
 * structural readIndex — in that order. R2's head never returns an object
 * digest (multipart ETags are not hashes — the T2 carry), so the re-download
 * hash is the authority; when an adapter DOES surface a digest (fs), it must
 * agree. Any failure is a StorageError the caller turns into markWarm + a
 * BullMQ retry (attempts: 3).
 */
async function verifyUpload(
  storage: StorageAdapter,
  archiveKey: string,
  report: PackReport,
): Promise<void> {
  const unverified = (why: string): StorageError =>
    new StorageError(`hibernate upload of ${archiveKey} failed verification: ${why}`, {
      code: "upload_unverified",
    });

  const head = await storage.head(archiveKey);
  if (head === null) throw unverified("head() returned null after the put");
  if (head.bytes !== report.bytes) {
    throw unverified(`head().bytes ${head.bytes} !== packed ${report.bytes}`);
  }
  if (head.sha256Hex !== null && head.sha256Hex !== report.sha256Hex) {
    throw unverified("head().sha256Hex disagrees with the packed digest");
  }

  const redownloaded = await rehashObject(storage, archiveKey);
  if (redownloaded === null) throw unverified("get() returned null after the put");
  if (redownloaded !== report.sha256Hex) {
    throw unverified("full re-download sha256 mismatch");
  }

  const spec = await storage.readerSpec(archiveKey);
  if (spec === null) throw unverified("readerSpec() returned null after the put");
  const reader = await openReader(spec);
  try {
    // Throws the typed Archive* errors on a corrupt/truncated object.
    await readIndex(reader);
  } finally {
    await reader.close();
  }
}

// ---------------------------------------------------------------------------
// hibernateWorkspace
// ---------------------------------------------------------------------------

export async function hibernateWorkspace(
  deps: HibernateDeps,
  job: HibernateJobInput,
  opts: { idleMs?: number } = {},
): Promise<HibernateResult> {
  const clock = deps.clock ?? (() => new Date());
  const idleMs = opts.idleMs ?? HIBERNATE_IDLE_MS;
  const startedMs = clock().getTime();
  const dir = workspaceDir(deps.workspacesRoot, job.userId, job.sessionId);
  const archiveKey = r2Keys.workspaceArchive(job.userId, job.sessionId);
  const manifestKey = r2Keys.workspaceManifest(job.userId, job.sessionId);

  // (1) verify — re-check everything the sweeper believed when it enqueued.
  // AG1: a session with an active (queued|running) run is never evicted.
  const activeRun = await deps.runs.activeForSession(deps.db, job.sessionId);
  if (activeRun !== null) {
    return { status: "skipped", reason: "active_run" };
  }
  // The user came back: a fresh activity key beats the idle threshold. (A
  // missing key is UNKNOWN, not "long ago" — the sweeper's enqueue-side rule
  // owns the row.updatedAt fallback; this job-side check only skips.)
  const lastActivityMs = await deps.activity.read(job.sessionId);
  if (lastActivityMs !== null && clock().getTime() - lastActivityMs < idleMs) {
    return { status: "skipped", reason: "recent_activity" };
  }
  // Nothing warm on disk: a cold row re-delivery is a no-op; anything else
  // was never warm (a stranded 'hibernating' row is reconcile's business).
  const row = await deps.fileManifests.get(deps.db, job.sessionId);
  if (!(await pathExists(dir))) {
    return {
      status: "skipped",
      reason: row?.state === "cold" ? "already_cold" : "not_warm",
    };
  }
  // (2) claim — the row must be exactly one generation behind the job
  // (dedupes re-deliveries) and win the warm → hibernating transition.
  if (row === null) {
    return { status: "skipped", reason: "not_warm" };
  }
  if (row.generation + 1 !== job.generation) {
    return { status: "skipped", reason: "stale_generation", generation: row.generation };
  }
  if (!(await deps.fileManifests.beginHibernation(deps.db, job.sessionId))) {
    return { status: "skipped", reason: "not_warm" };
  }
  const priorWorkspaceBytes = row.workspaceBytes;

  let report: PackReport;
  let manifestJson: Buffer;
  let manifestSha256: string;
  try {
    // (3) P2 seam: kill the jail/PTY/background jobs, LEAVE the files.
    await deps.sandbox.evictWorkspace(job.userId, job.sessionId);

    // (4) pack, streaming straight into storage — no temp file. Codec opts
    // are pinned to the defaults so the sidecar re-encode below is
    // byte-identical to the index JSON the archive footer hashes.
    report = await packToStorage(dir, deps.storage, archiveKey);

    // (5) sidecar: the SAME compact-array index JSON bytes.
    manifestJson = encodeIndexWire(report.index);
    manifestSha256 = sha256Hex(manifestJson);
    await deps.storage.put(manifestKey, manifestJson, {
      contentType: "application/json",
      sha256Hex: manifestSha256, // R2's head never returns a digest — supply our own
    });

    // (6) verify BEFORE delete (see verifyUpload).
    await verifyUpload(deps.storage, archiveKey, report);

    // (7) durable cold marker in Postgres. entryCount = every member the
    // index carries (files + dirs + symlinks).
    const entryCount = report.index.files.length;
    await deps.fileManifests.markCold(deps.db, {
      sessionId: job.sessionId,
      generation: job.generation,
      archiveKey,
      archiveBytes: report.bytes,
      archiveSha256: report.sha256Hex,
      entryCount,
      uiTree: uiTree(report.index),
    });
    await deps.workspaceObjects.putArchive(deps.db, {
      userId: job.userId,
      sessionId: job.sessionId,
      generation: job.generation,
      archiveKey,
      manifestKey,
      bytes: report.bytes,
      sha256: report.sha256Hex,
      entryCount,
      manifestBytes: manifestJson.length,
      manifestSha256,
    });
  } catch (err) {
    // The local dir is still fully intact, so a warm row is the truth —
    // restore it (state re-checked, see restoreWarm) and let BullMQ retry.
    await restoreWarm(deps, job.sessionId, priorWorkspaceBytes);
    throw asStorageError(err, job.sessionId);
  }

  // (8) ONLY NOW is local data deleted — strictly after the verified upload
  // AND the durable cold marker. Crash-window truth: BEFORE the cold marker
  // commits, a crash leaves the row 'hibernating' + dir intact and
  // reconcileStuckHibernations resets it to warm; AFTER it commits the
  // workspace is durably cold and only local bytes linger — reclamation of
  // that residue is T9's wipe-on-hydrate / T10's reconcile delegation
  // (ledgered), not this engine's retry (a re-delivery skips
  // stale_generation, so fs.rm is never re-attempted by the queue).
  try {
    await rmDir(dir, { recursive: true, force: true });
  } catch (err) {
    // The durable state is already cold and correct; the residue is local
    // bytes. Loud and typed so the job's failure surface names it instead
    // of propagating a raw fs error.
    throw new StorageError(
      `hibernate of session ${job.sessionId}: local evict (fs.rm) of ${dir} failed — ` +
        "the workspace is durably cold; the leftover dir needs the T9/T10 reclaim path",
      { code: "evict_local_failed", cause: err },
    );
  }

  // (9) event + durable mirror. The workspace is already cold; a failure
  // here must NOT restore warm (the dir is gone — warm would lie). The job
  // retries and converges to `skipped already_cold`.
  const ms = clock().getTime() - startedMs;
  try {
    const event = await deps.events.append(job.sessionId, "workspace_hibernated", {
      generation: job.generation,
      archiveBytes: report.bytes,
      ms,
    });
    await deps.eventMirror.put(deps.db, event);
  } catch (err) {
    throw asStorageError(err, job.sessionId);
  }

  return {
    status: "hibernated",
    generation: job.generation,
    archiveBytes: report.bytes,
    ms,
  };
}

// ---------------------------------------------------------------------------
// reconcileStuckHibernations — crash recovery (worker boot + sweeper)
// ---------------------------------------------------------------------------

/**
 * Rows stuck in state 'hibernating' past `stuckAfterMs`:
 *  - dir EXISTS → markWarm (the pack never completed durably; re-pack later);
 *  - dir GONE + verifiable archive → markCold with a rebuilt uiTree and a
 *    putArchive row (generation + 1 — the in-flight job's generation); rare,
 *    ~1 s (readIndex + one full re-hash);
 *  - dir GONE + no (usable) archive → remove the row + append a system_note
 *    {code:"workspace_lost"} — counted in neither return field.
 *
 * Every write is preceded by a state re-check (the T6-review caller
 * discipline): a row that moved on between the scan and the write is never
 * stomped.
 */
export async function reconcileStuckHibernations(
  deps: HibernateDeps,
  opts: { stuckAfterMs: number },
): Promise<{ resetToWarm: number; closedToCold: number }> {
  const clock = deps.clock ?? (() => new Date());
  const cutoff = new Date(clock().getTime() - opts.stuckAfterMs);
  const rows = await deps.stuckHibernationScan.listStuck(deps.db, cutoff);

  let resetToWarm = 0;
  let closedToCold = 0;

  for (const scanned of rows) {
    // Re-check state: only rows still stranded in 'hibernating' are ours.
    const row = await deps.fileManifests.get(deps.db, scanned.sessionId);
    if (row === null || row.state !== "hibernating") continue;

    const dir = workspaceDir(deps.workspacesRoot, row.userId, row.sessionId);
    if (await pathExists(dir)) {
      await deps.fileManifests.markWarm(deps.db, {
        sessionId: row.sessionId,
        workspaceBytes: row.workspaceBytes, // prior du restored
      });
      resetToWarm += 1;
      continue;
    }

    // The R2 keys are STABLE per session: a first-hibernate crash leaves the
    // row's ledger fields null, but the archive (if the put landed) sits at
    // the same derivable key a re-hibernate would use.
    const archiveKey =
      row.archiveKey ?? r2Keys.workspaceArchive(row.userId, row.sessionId);
    const generation = row.generation + 1; // the in-flight job's generation
    if (await closeAsCold(deps, row, archiveKey, generation)) {
      closedToCold += 1;
      continue;
    }

    // No usable archive: the workspace is gone — drop the row and tell the
    // session (the system_note is the user-visible trace).
    await deps.fileManifests.remove(deps.db, row.sessionId);
    await appendSystemNote(deps, row.sessionId, "workspace_lost");
  }

  return { resetToWarm, closedToCold };
}

/**
 * Closes a dir-gone stranded row cold from the stored archive. Verification
 * failures (missing head, unreadable index, un-rehashable object, failed
 * sidecar re-put) return false → the caller takes the workspace_lost path.
 * Postgres write failures propagate (the sweeper logs and retries next pass).
 */
async function closeAsCold(
  deps: HibernateDeps,
  row: StuckHibernationRow,
  archiveKey: string,
  generation: number,
): Promise<boolean> {
  const manifestKey = r2Keys.workspaceManifest(row.userId, row.sessionId);

  // -- verify the archive (readIndex structural check + exact digests) --
  let index: ArchiveIndex;
  let archiveBytes: number;
  let archiveSha256: string;
  let manifestBytes: number;
  let manifestSha256: string;
  try {
    const spec = await deps.storage.readerSpec(archiveKey);
    if (spec === null) return false;
    const reader = await openReader(spec);
    try {
      index = await readIndex(reader);
    } finally {
      await reader.close();
    }

    const head = await deps.storage.head(archiveKey);
    if (head === null) return false;
    archiveBytes = head.bytes;

    // The row's stale ledger is from the PREVIOUS generation — recompute
    // both digests from the bytes actually stored (T2 carry).
    const redownloaded = await rehashObject(deps.storage, archiveKey);
    if (redownloaded === null) return false;
    archiveSha256 = redownloaded;

    // Sidecar re-put is idempotent self-healing: the crash may have landed
    // between the archive put and the sidecar put.
    const manifestJson = encodeIndexWire(index);
    manifestSha256 = sha256Hex(manifestJson);
    manifestBytes = manifestJson.length;
    await deps.storage.put(manifestKey, manifestJson, {
      contentType: "application/json",
      sha256Hex: manifestSha256,
    });
  } catch {
    return false; // unreadable/corrupt: not a closable cold state
  }

  // -- durable writes (failures propagate, NOT workspace_lost) --
  const entryCount = index.files.length;
  await deps.fileManifests.markCold(deps.db, {
    sessionId: row.sessionId,
    generation,
    archiveKey,
    archiveBytes,
    archiveSha256,
    entryCount,
    uiTree: uiTree(index),
  });
  await deps.workspaceObjects.putArchive(deps.db, {
    userId: row.userId,
    sessionId: row.sessionId,
    generation,
    archiveKey,
    manifestKey,
    bytes: archiveBytes,
    sha256: archiveSha256,
    entryCount,
    manifestBytes,
    manifestSha256,
  });
  return true;
}

async function appendSystemNote(
  deps: HibernateDeps,
  sessionId: string,
  code: string,
): Promise<void> {
  const event = await deps.events.append(sessionId, "system_note", { code });
  await deps.eventMirror.put(deps.db, event);
}
