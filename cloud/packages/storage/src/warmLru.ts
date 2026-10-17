/**
 * Warm-cache LRU, disk-pressure guard and registry reconcile (P7 Task 10,
 * spike §9.3; controller ruling R2).
 *
 * ONE warm-disk knob: `OVID_MAX_WARM_GB` (default 8). P7's LRU owns
 * enforcement; P2's attach-guard reads the same variable as an advisory check
 * (reconcile to one value at deploy — a mismatch is logged by the composition
 * root, not here). The disk alert is `OVID_DISK_ALERT_PCT` (default 80).
 *
 * Authority split (ruling R1, load-bearing):
 *  - The P2 `SandboxEviction` seam is the ONLY enumeration of warm workspaces.
 *    This module never walks `${workspacesRoot}/*\/sessions/*` — Postgres
 *    `file_manifests` + `workspace_objects` stay the durable authority.
 *  - LRU sizes come from the seam (`entry.bytes`) or the row
 *    (`workspaceBytes`); `du()` exists for the hydrate `markWarm` path and
 *    for tests, never for raw LRU accounting.
 *
 * The pre-P2 noop seam returns `[]` with `authoritative: false`. Reconcile
 * treats that as "unknown" and skips the destructive "warm row without a
 * seam entry" arm; otherwise the first boot sweep would archive every
 * registered row. Once P2 lands (authoritative true/absent), the arm runs.
 *
 * Crash recovery owned here (ledgered carries):
 *  - T9-I1: a hard crash mid-extract leaves `state='hydrating'` with a
 *    partial dir. `reconcileWarmRegistry` scans stuck hydrating rows,
 *    `fs.rm`s the partial dir and calls the state-rechecked `markColdRetry`
 *    (cold + wipe), so the next hydrate retries cleanly.
 *  - T8-F1: a crash after `markCold` but before `fs.rm` leaves a COLD row
 *    with a full warm dir. Two arms reclaim it: (a) when the seam still
 *    reports the session, the entry loop verifies the archive and removes the
 *    dir; (b) when it does not (the hibernate path already called
 *    `evictWorkspace`, so the real crash window is seam-invisible), the
 *    optional `coldRowScan` dep enumerates recently-cold rows and the same
 *    verified `fs.rm` runs. T9's wipe-on-hydrate covers the reopened case.
 *
 * @ovid/queue is consumed through a local mirror (`HIBERNATE_JOB_NAME`,
 * `storageJobId`) for the same no-lockfile reason as hibernate.ts; the test
 * suite pins the mirror against the real @ovid/queue source.
 */

import { createHash } from "node:crypto";
import { rm as rmDir, stat, statfs } from "node:fs/promises";

import type { StorageAdapter } from "./adapter.js";
import { ARCHIVE_VERSION, FORMAT_NAME } from "./archive/format.js";
import {
  decodeIndexWire,
  walkWorkspace,
  type ArchiveIndex,
} from "./archive/pack.js";
import { readIndex } from "./archive/readIndex.js";
import { uiTree } from "./archive/uiTree.js";
import {
  reconcileStuckHibernations,
  type DbLike,
  type FileManifestRowView,
  type FileManifestsRepo,
  type HibernateDeps,
  type HibernateJobInput,
} from "./hibernate.js";
import { r2Keys } from "./keys.js";
import { openReader } from "./rangeReader.js";
import { workspaceDir } from "./workspacePaths.js";

// ---------------------------------------------------------------------------
// Pinned constants
// ---------------------------------------------------------------------------

/** Q8-design ruling default (ruling R2); the 8→12 retune is an owner call. */
export const MAX_WARM_GB_DEFAULT = 8;

/** Disk-used alert threshold default, percent. */
export const DISK_ALERT_PCT_DEFAULT = 80;

/** Spike §9.3 sweeper tick. */
export const SWEEP_INTERVAL_MS = 30_000;

/** G7: 3-minute idle before a warm workspace is hibernated. */
export const IDLE_THRESHOLD_MS = 180_000;

/** hibernating/hydrating rows older than this are crash-stranded. */
export const STUCK_STATE_MS = 900_000;

/** Refresh a warm row's workspaceBytes at most this often during reconcile. */
export const WARM_DU_REFRESH_MS = 600_000;

/** Anti-thrash bound: at most this many evictions per enforceWarmCap pass. */
export const MAX_EVICTIONS_PER_PASS = 8;

/**
 * Bounded cold-row scan per sweep for the T8-F1 residue arm. The wiring
 * layer should order `updated_at DESC` (a crash residue is recent: it is
 * created by the markCold that preceded the failed rm).
 */
export const COLD_RESIDUE_SCAN_LIMIT = 200;

/** Mirror of @ovid/queue's HIBERNATE_JOB_NAME (no package edge — see header). */
export const HIBERNATE_JOB_NAME = "hibernate-workspace";

/** Mirror of @ovid/queue's storageJobId (`~` separator — see queues.ts). */
export function storageJobId(sessionId: string, generation: number): string {
  return `${sessionId}~${generation}`;
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

export interface WarmConfig {
  maxWarmBytes: number;
  diskAlertFraction: number;
}

/**
 * `OVID_MAX_WARM_GB` → bytes. Unset/empty = the 8 GB default; anything that
 * is not a positive integer GB throws (a silently-wrong cap is worse than a
 * failed boot). Integer math only: `gb * 1024^3`.
 */
export function maxWarmBytesFromEnv(env: NodeJS.ProcessEnv): number {
  const raw = env.OVID_MAX_WARM_GB;
  if (raw === undefined || raw === "") {
    return MAX_WARM_GB_DEFAULT * 1024 ** 3;
  }
  if (!/^[1-9][0-9]*$/.test(raw)) {
    throw new Error(
      `OVID_MAX_WARM_GB must be a positive integer number of GB (got ${JSON.stringify(raw)})`,
    );
  }
  const gb = Number(raw);
  const bytes = gb * 1024 ** 3;
  if (!Number.isSafeInteger(gb) || !Number.isSafeInteger(bytes)) {
    throw new Error(`OVID_MAX_WARM_GB is out of range (got ${JSON.stringify(raw)})`);
  }
  return bytes;
}

/**
 * `OVID_DISK_ALERT_PCT` → fraction. Unset/empty = 0.80; only an integer
 * 1..99 is accepted (100 would evict forever, 0 would never alert).
 */
export function diskAlertFractionFromEnv(env: NodeJS.ProcessEnv): number {
  const raw = env.OVID_DISK_ALERT_PCT;
  if (raw === undefined || raw === "") {
    return DISK_ALERT_PCT_DEFAULT / 100;
  }
  if (!/^(?:[1-9]|[1-9][0-9])$/.test(raw)) {
    throw new Error(
      `OVID_DISK_ALERT_PCT must be an integer 1..99 (got ${JSON.stringify(raw)})`,
    );
  }
  return Number(raw) / 100;
}

// ---------------------------------------------------------------------------
// Deps (HibernateDeps + the T10 additions below)
// ---------------------------------------------------------------------------

/** A warm row as `fileManifests.listWarmForLru` selects it. */
export interface WarmRowView {
  sessionId: string;
  userId: string;
  generation: number;
  workspaceBytes: number | null;
  updatedAt: Date;
}

/**
 * Crash-stranded 'hydrating' scan (T9-review I1). The @ovid/db repo has no
 * such query yet, so the wiring layer owns this select — the same pattern as
 * `StuckHibernationScan`:
 *   WHERE state = 'hydrating' AND updated_at < $1
 */
export interface StuckHydrationScan {
  listStuckHydrating(db: DbLike, olderThan: Date): Promise<WarmRowView[]>;
}

/**
 * T8-F1 residue scan (optional; T11 should wire it):
 *   WHERE state = 'cold' ORDER BY updated_at DESC LIMIT $1
 * returning the full manifest-row view. Used to reclaim a cold row's
 * leftover warm dir when the session is never reopened. Bounded by
 * COLD_RESIDUE_SCAN_LIMIT per sweep.
 */
export interface ColdRowScan {
  listColdRows(db: DbLike, opts: { limit: number }): Promise<FileManifestRowView[]>;
}

/**
 * The file_manifests surface T10 needs on top of T8's mirror:
 *  - `upsertWarm` registers never-hibernated sessions and refreshes stale du;
 *  - `listWarmForLru` is the warm-row scan (oldest updated_at first);
 *  - `markColdRetry` is the state-rechecked hydrating → cold reset
 *    (`WHERE state='hydrating'`) T11/P4 supplies.
 */
export interface WarmFileManifestsRepo extends FileManifestsRepo {
  upsertWarm(
    db: DbLike,
    i: { sessionId: string; userId: string; workspaceBytes: number | null },
  ): Promise<unknown>;
  listWarmForLru(db: DbLike): Promise<WarmRowView[]>;
  markColdRetry(db: DbLike, sessionId: string): Promise<void>;
}

export interface HibernateQueue {
  add(name: string, job: HibernateJobInput, opts: { jobId: string }): unknown;
}

export type WarmDeps = HibernateDeps & {
  fileManifests: WarmFileManifestsRepo;
  queues: { hibernate: HibernateQueue };
  /** Injectable for tests; production uses `statfsUsage`. */
  diskProbe?: (path: string) => Promise<DiskUsage>;
  /** Required forcing function (T9-I1): T11 must wire the hydrating scan. */
  stuckHydrationScan: StuckHydrationScan;
  /** Optional T8-F1 never-reopened residue scan (see ColdRowScan). */
  coldRowScan?: ColdRowScan;
};

export interface DiskUsage {
  totalBytes: number;
  freeBytes: number;
  usedFraction: number;
}

async function pathExists(p: string): Promise<boolean> {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Disk helpers
// ---------------------------------------------------------------------------

/**
 * Recursive sum of REGULAR-FILE bytes (symlink targets excluded). Relative
 * ordering is all the LRU needs; this is documented as a small underestimate
 * vs `du --block-size` (directory blocks are not counted). Used only on
 * session workspace dirs P7 owns the path of (hydrate's markWarm) — LRU
 * sizes come from the seam.
 */
export async function du(dir: string): Promise<number> {
  const entries = await walkWorkspace(dir);
  let total = 0;
  for (const e of entries) {
    if (e.type === 0) total += e.size;
  }
  return total;
}

/**
 * `fsPromises.statfs` → integer bytes. `freeBytes` is `bavail` (space
 * available to unprivileged writers, matching `df`'s Avail), so reserved
 * blocks count toward `usedFraction` — conservative for an alert. The
 * fraction is the ONLY float here and is never persisted.
 */
export async function statfsUsage(path: string): Promise<DiskUsage> {
  const st = await statfs(path);
  const bsize = Number(st.bsize);
  const totalBytes = bsize * Number(st.blocks);
  const freeBytes = bsize * Number(st.bavail);
  const raw = totalBytes <= 0 ? 0 : (totalBytes - freeBytes) / totalBytes;
  return {
    totalBytes,
    freeBytes,
    usedFraction: Math.min(1, Math.max(0, raw)),
  };
}

// ---------------------------------------------------------------------------
// Reconcile
// ---------------------------------------------------------------------------

export interface ReconcileResult {
  registered: number;
  reset: number;
  totalWarmBytes: number;
  disk: DiskUsage;
}

/**
 * Seam ↔ Postgres warm-row reconcile. See the module header for the
 * authority split and the two crash-recovery arms.
 *
 * `reset` counts rows the crash-recovery arms repaired: stuck 'hibernating'
 * → warm (T8's reconcile) plus stuck 'hydrating' → cold (T9-I1). The
 * cold-row residue reclaim does not change state and is not counted.
 */
export async function reconcileWarmRegistry(
  deps: WarmDeps,
  cfg: WarmConfig,
  opts: { now?: Date } = {},
): Promise<ReconcileResult> {
  const now = opts.now ?? (deps.clock?.() ?? new Date());
  const nowMs = now.getTime();
  const probe = deps.diskProbe ?? statfsUsage;
  const disk = await probe(deps.workspacesRoot);

  const entries = await deps.sandbox.listWarmWorkspaces();
  const rows = await deps.fileManifests.listWarmForLru(deps.db);
  const entryBySid = new Map(entries.map((e) => [e.sessionId, e]));
  const rowBySid = new Map(rows.map((r) => [r.sessionId, r]));
  let registered = 0;
  let reset = 0;

  // -- (1) seam entries ↔ PG rows -----------------------------------------
  for (const entry of entries) {
    const warmRow = rowBySid.get(entry.sessionId);
    if (warmRow !== undefined) {
      // Known warm row: refresh its du at most every WARM_DU_REFRESH_MS.
      if (nowMs - warmRow.updatedAt.getTime() > WARM_DU_REFRESH_MS) {
        await refreshWarmBytes(deps, entry.sessionId, entry.bytes);
      }
      continue;
    }

    // Not in the warm-row scan: either no row at all (register), a row in a
    // non-warm state, or a row that appeared after the scan.
    const current = await deps.fileManifests.get(deps.db, entry.sessionId);
    if (current === null) {
      // T6 carry: this re-check runs immediately before the upsert so a
      // concurrent claim (hibernating/hydrating) is never stomped back to
      // warm by upsertWarm's unconditional conflict arm.
      await deps.fileManifests.upsertWarm(deps.db, {
        sessionId: entry.sessionId,
        userId: entry.userId,
        workspaceBytes: entry.bytes,
      });
      registered += 1;
      continue;
    }
    if (current.state === "cold") {
      // T8-F1: cold row + a live dir the seam still reports = post-markCold
      // crash residue. Reclaim ONLY when the archive is verifiably present;
      // otherwise the dir may be the only copy and is left alone.
      await reclaimColdResidue(deps, current);
      continue;
    }
    if (
      current.state === "warm" &&
      nowMs - current.updatedAt.getTime() > WARM_DU_REFRESH_MS
    ) {
      await refreshWarmBytes(deps, entry.sessionId, entry.bytes);
    }
    // hibernating / hydrating: the state machine (and the stuck scans below)
    // owns those rows; never touch them from the warm-registry side.
  }

  // -- (2) warm rows with no seam entry -----------------------------------
  // The noop pre-P2 seam returns [] non-authoritatively: [] is "unknown",
  // not "every workspace vanished". Skipping this arm until P2 lands is what
  // keeps the boot sweep from archiving every registered row.
  if (deps.sandbox.authoritative !== false) {
    for (const row of rows) {
      if (entryBySid.has(row.sessionId)) continue;
      await closeWarmRow(deps, row.sessionId);
    }
  }

  // -- (2b) T8-F1 residue the seam cannot see ------------------------------
  // A hibernate crash between markCold and fs.rm leaves a cold row + a full
  // dir. The engine already evicted the sandbox, so the seam will NOT list
  // the session; the bounded cold-row scan is the only way to find it
  // without raw-walking the workspace tree (ruling R1).
  if (deps.coldRowScan !== undefined) {
    const coldRows = await deps.coldRowScan.listColdRows(deps.db, {
      limit: COLD_RESIDUE_SCAN_LIMIT,
    });
    for (const scanned of coldRows) {
      // State re-check (T6 carry): only a row still cold is ours.
      const row = await deps.fileManifests.get(deps.db, scanned.sessionId);
      if (row === null || row.state !== "cold") continue;
      await reclaimColdResidue(deps, row);
    }
  }

  // -- (3) crash-stranded hibernating rows (T8 delegation) ----------------
  const stuckHib = await reconcileStuckHibernations(deps, {
    stuckAfterMs: STUCK_STATE_MS,
    now,
  });
  reset += stuckHib.resetToWarm;

  // -- (4) crash-stranded hydrating rows (T9-review I1) -------------------
  const hydratingCutoff = new Date(nowMs - STUCK_STATE_MS);
  const stuckHydrating =
    await deps.stuckHydrationScan.listStuckHydrating(deps.db, hydratingCutoff);
  for (const scanned of stuckHydrating) {
    // State re-check (T6 carry): only a row still in 'hydrating' is ours.
    const row = await deps.fileManifests.get(deps.db, scanned.sessionId);
    if (row === null || row.state !== "hydrating") continue;

    // Wipe the partial tree FIRST (a crash mid-extract leaves a partial
    // workspace), then state-rechecked cold. A failed rm leaves the residue
    // to hydrate's own wipe-on-hydrate path; the row must still go cold.
    const dir = workspaceDir(deps.workspacesRoot, row.userId, row.sessionId);
    try {
      await rmDir(dir, { recursive: true, force: true });
    } catch (err) {
      console.error(
        `[warm-lru] hydration reset: failed to remove partial dir ${dir}`,
        err,
      );
    }
    await deps.fileManifests.markColdRetry(deps.db, row.sessionId);
    reset += 1;
  }

  // -- (5) total warm bytes (authoritative re-read) -----------------------
  const finalRows = await deps.fileManifests.listWarmForLru(deps.db);
  const totalWarmBytes = finalRows.reduce(
    (n, r) => n + (r.workspaceBytes ?? 0),
    0,
  );

  return { registered, reset, totalWarmBytes, disk };
}

/** Refresh a warm row's workspaceBytes only while it is still warm. */
async function refreshWarmBytes(
  deps: WarmDeps,
  sessionId: string,
  bytes: number,
): Promise<void> {
  const current = await deps.fileManifests.get(deps.db, sessionId);
  if (current === null || current.state !== "warm") return;
  await deps.fileManifests.upsertWarm(deps.db, {
    sessionId,
    userId: current.userId,
    workspaceBytes: bytes,
  });
}

/**
 * T8-F1 residue reclaim: a COLD row whose warm dir is still present (found
 * through the seam or the bounded cold-row scan). Deletes the dir only after
 * confirming the archive exists — the dir is never the last copy.
 */
async function reclaimColdResidue(
  deps: WarmDeps,
  row: FileManifestRowView,
): Promise<boolean> {
  const dir = workspaceDir(deps.workspacesRoot, row.userId, row.sessionId);
  // Cheap existence probe first: the cold-row scan is bounded but runs every
  // sweep, and the overwhelming majority of cold rows have no dir.
  if (!(await pathExists(dir))) return false;
  if (row.archiveKey === null || row.archiveKey === "") {
    console.warn(
      `[warm-lru] cold session ${row.sessionId} has a live dir but no archive — ` +
        "leaving the dir (it may be the only copy)",
    );
    return false;
  }
  const head = await deps.storage.head(row.archiveKey);
  if (head === null) {
    console.warn(
      `[warm-lru] cold session ${row.sessionId} has a live dir but no archive — ` +
        "leaving the dir (it may be the only copy)",
    );
    return false;
  }
  try {
    await rmDir(dir, { recursive: true, force: true });
    return true;
  } catch (err) {
    console.error(`[warm-lru] failed to reclaim cold residue dir ${dir}`, err);
    return false;
  }
}

/**
 * A warm row the authoritative seam no longer reports: verify its archive
 * and close it cold (rebuilt uiTree), or remove it + `workspace_lost` when
 * no usable archive exists. Every write is preceded by a state re-check.
 */
async function closeWarmRow(
  deps: WarmDeps,
  sessionId: string,
): Promise<"cold" | "lost" | "skipped"> {
  const row = await deps.fileManifests.get(deps.db, sessionId);
  if (row === null || row.state !== "warm") return "skipped";

  const archiveKey = row.archiveKey;
  if (archiveKey === null || archiveKey === "") {
    return loseWarmRow(deps, sessionId);
  }

  const index = await readArchiveIndex(deps, row, archiveKey);
  if (index === null) return loseWarmRow(deps, sessionId);

  const head = await deps.storage.head(archiveKey);
  if (head === null) return loseWarmRow(deps, sessionId);

  // R2's head never returns a digest (T2 carry): re-download when absent.
  const archiveSha256 = head.sha256Hex ?? (await rehashObject(deps.storage, archiveKey));
  if (archiveSha256 === null) return loseWarmRow(deps, sessionId);

  // T6 carry: re-check immediately before the terminal write.
  const current = await deps.fileManifests.get(deps.db, sessionId);
  if (current === null || current.state !== "warm") return "skipped";

  await deps.fileManifests.markCold(deps.db, {
    sessionId,
    generation: row.generation,
    archiveKey,
    archiveBytes: head.bytes,
    archiveSha256,
    entryCount: index.files.length,
    uiTree: uiTree(index),
  });
  return "cold";
}

/** Archive footer first (indexHash-verified), sidecar second. */
async function readArchiveIndex(
  deps: WarmDeps,
  row: FileManifestRowView,
  archiveKey: string,
): Promise<ArchiveIndex | null> {
  try {
    const spec = await deps.storage.readerSpec(archiveKey);
    if (spec !== null) {
      const reader = await openReader(spec);
      try {
        const index = await readIndex(reader);
        if (isOurArchive(index)) return index;
      } finally {
        await reader.close();
      }
    }
  } catch {
    // Fall through to the sidecar.
  }

  try {
    const buf = await deps.storage.getBuffer(
      r2Keys.workspaceManifest(row.userId, row.sessionId),
    );
    if (buf !== null) {
      const index = decodeIndexWire(buf);
      if (isOurArchive(index)) return index;
    }
  } catch {
    // Corrupt/missing sidecar: no usable index.
  }
  return null;
}

function isOurArchive(index: ArchiveIndex): boolean {
  return index.archiveVersion === ARCHIVE_VERSION && index.format === FORMAT_NAME;
}

async function loseWarmRow(
  deps: WarmDeps,
  sessionId: string,
): Promise<"lost" | "skipped"> {
  // T6 carry: never remove a row that moved on between scan and write.
  const current = await deps.fileManifests.get(deps.db, sessionId);
  if (current === null || current.state !== "warm") return "skipped";
  await deps.fileManifests.remove(deps.db, sessionId);
  await appendSystemNote(deps, sessionId, { code: "workspace_lost" });
  return "lost";
}

async function appendSystemNote(
  deps: WarmDeps,
  sessionId: string,
  payload: Record<string, unknown>,
): Promise<void> {
  const event = await deps.events.append(sessionId, "system_note", payload);
  await deps.eventMirror.put(deps.db, event);
}

async function rehashObject(
  storage: StorageAdapter,
  key: string,
): Promise<string | null> {
  const stream = await storage.get(key);
  if (stream === null) return null;
  const hash = createHash("sha256");
  for await (const chunk of stream) {
    hash.update(chunk as Buffer);
  }
  return hash.digest("hex");
}

// ---------------------------------------------------------------------------
// Warm-cap enforcement
// ---------------------------------------------------------------------------

export interface EnforceCapResult {
  evicted: number;
  freedBytes: number;
}

/**
 * Process-wide "first crossing" latches for the disk alert (brief pin). The
 * warning and the ONE system_note are tracked separately: a first crossing
 * with no warm candidates has no session to note, so a later crossing may
 * still append it. Tests call `resetDiskAlertStateForTests()` between cases.
 */
let diskAlertWarned = false;
let diskAlertNoted = false;

/** Test seam: forget this process's disk-pressure warning/note latches. */
export function resetDiskAlertStateForTests(): void {
  diskAlertWarned = false;
  diskAlertNoted = false;
}

/**
 * While Σ warm workspaceBytes > maxWarmBytes OR disk.usedFraction ≥
 * diskAlertFraction: enqueue a pressure hibernate for the warm session with
 * the OLDEST activity (missing activity key → row.updatedAt fallback).
 *
 * Anti-thrash: at most `maxEvictions` (default 8) adds per pass. On the FIRST
 * disk-alert crossing of this process, logs one warning and appends one
 * `system_note {code:"disk_pressure", usedPct}` to the last session evicted
 * in that pass (no eviction → no session to note).
 */
export async function enforceWarmCap(
  deps: WarmDeps,
  cfg: WarmConfig,
  opts: { maxEvictions?: number } = {},
): Promise<EnforceCapResult> {
  const maxEvictions = opts.maxEvictions ?? MAX_EVICTIONS_PER_PASS;
  const probe = deps.diskProbe ?? statfsUsage;
  const disk = await probe(deps.workspacesRoot);

  const rows = await deps.fileManifests.listWarmForLru(deps.db);
  let totalBytes = rows.reduce((n, r) => n + (r.workspaceBytes ?? 0), 0);

  const activity = await readActivitySafely(
    deps,
    rows.map((r) => r.sessionId),
  );
  const candidates = rows
    .map((row) => ({
      row,
      lastActivity: activity.get(row.sessionId) ?? row.updatedAt.getTime(),
    }))
    .sort(
      (a, b) =>
        a.lastActivity - b.lastActivity ||
        a.row.updatedAt.getTime() - b.row.updatedAt.getTime() ||
        a.row.sessionId.localeCompare(b.row.sessionId),
    );

  const overDisk = disk.usedFraction >= cfg.diskAlertFraction;
  const firstCrossing = overDisk && !diskAlertWarned;
  if (firstCrossing) {
    diskAlertWarned = true;
    console.warn(
      `[warm-lru] disk usage ${(disk.usedFraction * 100).toFixed(1)}% >= alert ` +
        `${(cfg.diskAlertFraction * 100).toFixed(1)}% (${disk.freeBytes} bytes free)`,
    );
  }

  let evicted = 0;
  let freedBytes = 0;
  let lastEvicted: WarmRowView | null = null;
  let index = 0;

  while (
    index < candidates.length &&
    evicted < maxEvictions &&
    (totalBytes > cfg.maxWarmBytes || disk.usedFraction >= cfg.diskAlertFraction)
  ) {
    const candidate = candidates[index++]!;
    const row = candidate.row;
    const generation = row.generation + 1;
    try {
      await Promise.resolve(
        deps.queues.hibernate.add(
          HIBERNATE_JOB_NAME,
          {
            sessionId: row.sessionId,
            userId: row.userId,
            generation,
            reason: "pressure",
          },
          { jobId: storageJobId(row.sessionId, generation) },
        ),
      );
      evicted += 1;
      freedBytes += row.workspaceBytes ?? 0;
      totalBytes -= row.workspaceBytes ?? 0;
      lastEvicted = row;
    } catch (err) {
      // The queue being down must not wedge the pass; the next tick retries.
      console.error(
        `[warm-lru] failed to enqueue pressure hibernate for ${row.sessionId}`,
        err,
      );
    }
  }

  if (overDisk && !diskAlertNoted && lastEvicted !== null) {
    diskAlertNoted = true;
    try {
      await appendSystemNote(deps, lastEvicted.sessionId, {
        code: "disk_pressure",
        usedPct: Math.round(disk.usedFraction * 100),
      });
    } catch (err) {
      // The note is advisory; never let it fail the eviction pass. Reset the
      // latch so the next tick can retry the note.
      diskAlertNoted = false;
      console.error("[warm-lru] failed to append disk_pressure system_note", err);
    }
  }

  return { evicted, freedBytes };
}

/** Activity failures degrade to the row.updatedAt fallback, never throw. */
async function readActivitySafely(
  deps: WarmDeps,
  sessionIds: string[],
): Promise<Map<string, number>> {
  if (sessionIds.length === 0) return new Map();
  try {
    return await deps.activity.readMany(sessionIds);
  } catch (err) {
    console.error(
      "[warm-lru] activity.readMany failed; falling back to row.updatedAt",
      err,
    );
    return new Map();
  }
}
