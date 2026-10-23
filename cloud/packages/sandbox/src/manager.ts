import { chown, mkdir, readdir, stat, statfs } from "node:fs/promises";
import { basename, join } from "node:path";
import type { CgroupManager } from "./cgroups.js";
import type { SandboxConfig } from "./config.js";
import { renderEtcBundle, renderHomeDotfiles, writeEnvFiles } from "./etcFiles.js";
import { execOnce, makeJailContext } from "./exec.js";
import {
  createJobRegistry,
  spawnLongRunning,
  type JobRegistry,
  type SpawnedProcess,
} from "./jobs.js";
import { JAIL_WORKSPACE } from "./invocation.js";
import type { JailLauncher } from "./launcher.js";
import {
  createPtySession,
  type PtyHandlers,
  type PtyRequest,
  type PtySession,
} from "./pty.js";
import { cacheProjectId, workspaceProjectId, type QuotaBackend } from "./quota.js";
import type { ResolvedRootfs } from "./rootfs.js";
import type { ExecRequest, ExecResult, JailContext } from "./types.js";

/**
 * SandboxManager (P2 Task 8): lifecycle, FIFO admission beyond
 * maxActiveSandboxes, per-user XFS/noop quotas, boot recovery, and the
 * workspaceDir(userId, sessionId) seam.
 *
 * Task 9: handles grow createPty/getPty/jobs/spawnProcess (PTY sessions and
 * background jobs under the env, leaves killed FIRST on destroy) and the
 * workspaceDir seam's quota application is tier-aware (Task 8 review F1:
 * re-asserting the free-tier limit on a pro user's project silently
 * downgraded their live quota).
 */

const MB = 1024 * 1024;
const GB = 1024 * 1024 * 1024;

/** Workspace quota tier label: explicit "pro", anything-else-is-"free" (least-privilege attach rule). */
type WorkspaceTier = "free" | "pro";

/**
 * One live sandbox environment. Task 9 grew this with createPty/getPty/
 * jobs/spawnProcess — the handle is the env those leaves hang under.
 */
export interface SandboxHandle {
  readonly userId: string;
  readonly uid: number;
  /** HOST path: {workspacesRoot}/{uid}/workspace (jail: /workspace). */
  readonly workspaceDir: string;
  /** HOST path: {workspacesRoot}/{uid}/.home (jail: /root). */
  readonly homeDir: string;
  readonly jailWorkspaceDir: string;
  exec(req: ExecRequest): Promise<ExecResult>;
  /** Task 9: interactive PTY session under a pty-{id} leaf of this env. */
  createPty(req: PtyRequest, handlers: PtyHandlers): Promise<PtySession>;
  getPty(ptyId: string): PtySession | undefined;
  /** Background jobs under job-{id} leaves of this env. */
  readonly jobs: JobRegistry;
  /**
   * Task 9 (gap G3): long-lived jailed process with PIPES — the P5
   * SandboxSpawner stdio-MCP backing (pipes only, never a pty).
   */
  spawnProcess(req: { argv: string[]; cwd?: string; env?: Record<string, string> }): Promise<SpawnedProcess>;
  /**
   * Kill all live leaves (ptys/jobs/spawned processes) FIRST, kill+rmdir the
   * env cgroup, deregister, release the admission slot. Workspace DATA
   * persists — purge is P9 account deletion.
   */
  destroy(): Promise<void>;
}

export interface SandboxInfo {
  userId: string;
  uid: number;
  createdAt: string;
}

export interface SandboxManager {
  /**
   * Create-if-needed. FIFO admission queue beyond maxActiveSandboxes;
   * rejects SandboxAdmissionError (wire "sandbox_busy") after
   * acquireTimeoutMs, SandboxCapacityError (wire "sandbox_unavailable") on
   * disk pressure.
   */
  attach(userId: string, opts?: { tier?: "free" | "pro" }): Promise<SandboxHandle>;
  /**
   * Create-if-needed for ONE chat. Reuses the user's env (one cgroup, one
   * `.home`, one admission slot) but binds
   * `{workspacesRoot}/{uid}/sessions/{sessionId}/workspace` at `/workspace`,
   * so two chats of one user can never read each other's files. Idempotent
   * per (userId, sessionId).
   */
  attachSession(
    userId: string,
    sessionId: string,
    opts?: { tier?: "free" | "pro" },
  ): Promise<SandboxHandle>;
  /**
   * Host path of a session's workspace (`…/sessions/{sessionId}/workspace`),
   * created, chowned and quota-applied. The same path `attachSession` binds.
   */
  sessionWorkspaceDir(userId: string, sessionId: string): Promise<string>;
  get(userId: string): SandboxHandle | undefined;
  destroy(userId: string): Promise<void>;
  list(): SandboxInfo[];
  activeCount(): number;
  /**
   * The G1 seam (ruling P6-Q2; P6 injects this as its
   * BrowserToolsDeps.workspaceDir(userId, sessionId); P5's SandboxFiles maps
   * onto the same per-user tree): allocateUid (idempotent — NO jail, cgroup
   * or env creation), mkdir -p {workspacesRoot}/{uid}/sessions/{sessionId},
   * apply the per-user workspace quota project id
   * (workspaceProjectId(uid) — quota semantics stay PER-USER, shared with
   * the agent workspace; there is no session-scoped quota), return the HOST
   * path. P6's {root}/{userId}/sessions/{sessionId} default is only its own
   * test fallback.
   */
  workspaceDir(userId: string, sessionId: string): Promise<string>;
  /**
   * Boot recovery: scan workspacesRoot numeric dirs → known envs (cold —
   * data present, env not active); orphan env cgroups WITHOUT a workspace →
   * kill+rmdir. attach() re-warms cold envs (recreate the cgroup + rewrite
   * etc/home files, never touching data). Sweeping {uid}/sessions/* whose
   * sessionId no longer exists in the DB is P7 hibernation's eviction —
   * v1 deliberately leaves them.
   */
  recover(): Promise<void>;
  /** Destroy all — worker shutdown. */
  close(): Promise<void>;
}

/** Admission timed out — the sandbox gate is full (wire code "sandbox_busy"). */
export class SandboxAdmissionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SandboxAdmissionError";
  }
}

/** Host capacity exhausted (wire code "sandbox_unavailable"). */
export class SandboxCapacityError extends Error {
  constructor(readonly reason: "disk_pressure") {
    super(`sandbox capacity exhausted: ${reason}`);
    this.name = "SandboxCapacityError";
  }
}

export interface SandboxManagerDeps {
  config: SandboxConfig;
  /** Prod: (u) => users.allocateSandboxUid(db, u) — idempotent per user. */
  allocateUid(userId: string): Promise<number>;
  cgroups: CgroupManager;
  quota: QuotaBackend;
  launcher: JailLauncher;
  /** Task 3 resolveRootfs. */
  rootfs: ResolvedRootfs;
  /** Default: statvfs(workspacesRoot) + du of the workspace tree. */
  diskUsage?(): Promise<{ freeGb: number; warmGb: number }>;
  clock?(): Date;
}

interface ManagedHandle extends SandboxHandle {
  readonly createdAt: Date;
  /**
   * Task 8 review F1 carry: the tier this env's workspace quota was applied
   * with. Mutable: an upgrade-on-reattach (free→pro) rewrites it.
   */
  tier: WorkspaceTier;
  /** Task 9: kill every live leaf of this env (ptys/jobs/spawned) — FIRST. */
  killLeaves(): Promise<void>;
}

interface Waiter {
  resolve(): void;
  timer: NodeJS.Timeout;
}

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

/** Default disk usage: statfs free bytes + recursive size of the whole tree. */
async function defaultDiskUsage(
  workspacesRoot: string,
): Promise<{ freeGb: number; warmGb: number }> {
  let freeGb = 0;
  try {
    const st = await statfs(workspacesRoot);
    freeGb = (st.bsize * st.bavail) / GB;
  } catch (err) {
    if (!isErrnoException(err) || err.code !== "ENOENT") throw err;
    // A missing workspaces root IS disk pressure (the volume is not mounted
    // / not provisioned) — refuse loudly rather than bootstrapping into /.
    return { freeGb: 0, warmGb: 0 };
  }
  let warmBytes = 0;
  const walk = async (dir: string): Promise<void> => {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return; // raced-away subtree — count what we saw
    }
    for (const e of entries) {
      const p = join(dir, e.name);
      if (e.isDirectory()) await walk(p);
      else if (e.isFile()) warmBytes += (await stat(p)).size;
    }
  };
  await walk(workspacesRoot);
  return { freeGb, warmGb: warmBytes / GB };
}

/**
 * Capacity wave 2026-10-19: the default disk guard walks the WHOLE workspaces
 * tree (a readdir + stat per file of every user). It ran on every cold
 * attach, so a ramp of N new users cost O(N × total files) — profiled at
 * >60 % of the worker's CPU during an 1800-user ramp, and the reason a first
 * run took ~8 s to its first token. The guard is a coarse pressure check, so
 * a result up to `ttlMs` old is fine; concurrent attaches share ONE walk.
 */
export const DISK_USAGE_CACHE_MS = 30_000;

export function createCachedDiskUsage(
  compute: () => Promise<{ freeGb: number; warmGb: number }>,
  ttlMs: number = DISK_USAGE_CACHE_MS,
  now: () => number = Date.now,
): () => Promise<{ freeGb: number; warmGb: number }> {
  let cached: { at: number; value: { freeGb: number; warmGb: number } } | null = null;
  let inFlight: Promise<{ freeGb: number; warmGb: number }> | null = null;
  return () => {
    if (cached !== null && now() - cached.at < ttlMs) return Promise.resolve(cached.value);
    if (inFlight !== null) return inFlight;
    const started = now();
    inFlight = compute()
      .then((value) => {
        cached = { at: started, value };
        return value;
      })
      .finally(() => {
        inFlight = null;
      });
    return inFlight;
  };
}

export function createSandboxManager(deps: SandboxManagerDeps): SandboxManager {
  const { config, cgroups, quota, launcher, rootfs } = deps;
  const clock = deps.clock ?? (() => new Date());
  // Only the expensive DEFAULT is cached; an injected diskUsage (tests, a
  // future incremental accountant) is called as-is.
  const diskUsage =
    deps.diskUsage ?? createCachedDiskUsage(() => defaultDiskUsage(config.workspacesRoot));

  const handles = new Map<string, ManagedHandle>();
  /** Concurrent attach for the same userId dedupes onto one create. */
  const inFlight = new Map<string, Promise<SandboxHandle>>();
  /**
   * The jail context each live env was built with, so a per-session handle can
   * clone it with a different workspace bind (one env, many session views).
   */
  const ctxByUser = new Map<string, JailContext>();
  /** Per-session handles, keyed `userId\0sessionId` — same env, own workspace. */
  const sessionHandles = new Map<string, ManagedHandle>();
  /** user → uid, so destroy→attach and workspaceDir→attach reuse the uid (the prod allocator is idempotent; this makes the manager so too). */
  const uidByUser = new Map<string, number>();
  /**
   * uid → the workspace-quota tier last applied by an attach (Task 8 review
   * F1 carry). Survives destroy so a COLD env's project limit is not silently
   * downgraded by the workspaceDir seam either.
   */
  const tierByUid = new Map<number, WorkspaceTier>();
  /** FIFO admission queue beyond maxActiveSandboxes. */
  const queue: Waiter[] = [];
  let slotsInUse = 0;

  // -- admission ------------------------------------------------------------

  function acquireSlot(): Promise<void> {
    if (slotsInUse < config.maxActiveSandboxes) {
      slotsInUse++;
      return Promise.resolve();
    }
    return new Promise<void>((resolve, reject) => {
      const waiter: Waiter = {
        resolve,
        timer: setTimeout(() => {
          const i = queue.indexOf(waiter);
          if (i === -1) return; // already granted — timer raced the transfer
          queue.splice(i, 1);
          reject(
            new SandboxAdmissionError(
              `sandbox admission timed out after ${config.acquireTimeoutMs} ms ` +
                `(${config.maxActiveSandboxes} sandboxes active)`,
            ),
          );
        }, config.acquireTimeoutMs),
      };
      queue.push(waiter);
    });
  }

  /**
   * Release an admission slot. When waiters exist the slot TRANSFERS to the
   * FIFO head (no decrement — the count never dips below reality and nobody
   * can jump the queue between release and grant).
   */
  function releaseSlot(): void {
    const next = queue.shift();
    if (next) {
      clearTimeout(next.timer);
      next.resolve();
    } else {
      slotsInUse--;
    }
  }

  // -- teardown -------------------------------------------------------------

  async function destroyUser(userId: string): Promise<void> {
    const handle = handles.get(userId);
    if (handle === undefined) return;
    handles.delete(userId);
    ctxByUser.delete(userId);
    // Session views share this env; their handles die with it.
    for (const [key, sessionHandle] of [...sessionHandles]) {
      if (sessionHandle.userId === userId) sessionHandles.delete(key);
    }
    // Task 9: kill live leaves (ptys/jobs/spawned) FIRST, before the env —
    // each leaf's tree gets its own cgroup.kill, then the env follows.
    try {
      await handle.killLeaves();
    } catch (err) {
      // allSettled inside; this is a belt so teardown never wedges admission
      console.error(`sandbox destroy: leaf teardown failed for ${userId}:`, err);
    }
    const env = cgroups.envPath(handle.uid);
    try {
      await cgroups.kill(env); // tree-kill + rmdir
    } catch (err) {
      if (isErrnoException(err) && err.code === "ENOENT") {
        // already gone (crash cleanup raced us) — nothing to do
      } else {
        console.error(`sandbox destroy: env cgroup teardown failed for ${env}:`, err);
      }
    }
    releaseSlot();
  }

  // -- attach ---------------------------------------------------------------

  async function doAttach(
    userId: string,
    tier: "free" | "pro" | undefined,
  ): Promise<SandboxHandle> {
    await acquireSlot(); // a rejection here holds no slot — nothing to release
    try {
      let uid = uidByUser.get(userId);
      if (uid === undefined) {
        uid = await deps.allocateUid(userId);
        uidByUser.set(userId, uid);
      }

      // Disk guard (pinned order: AFTER allocateUid, BEFORE any mkdir).
      const usage = await diskUsage();
      if (usage.freeGb < config.minFreeGb || usage.warmGb >= config.maxWarmGb) {
        console.error(
          `sandbox attach: DISK PRESSURE — free ${usage.freeGb.toFixed(2)} GB (min ${config.minFreeGb}), ` +
            `warm ${usage.warmGb.toFixed(2)} GB (max ${config.maxWarmGb}); refusing to create sandbox for ${userId}`,
        );
        throw new SandboxCapacityError("disk_pressure");
      }

      const userRoot = join(config.workspacesRoot, String(uid));
      const workspaceDir = join(userRoot, "workspace");
      const homeDir = join(userRoot, ".home");
      const cacheDir = join(homeDir, ".cache");
      const etcDir = join(userRoot, "etc");
      // The five subdirs; the .cache subtree lives under .home so the jail's
      // /root/.cache/{pnpm-store,uv} (BASE_JAIL_ENV) maps onto it (Task 10
      // pins the host paths {uid}/.home/.cache/…). mkdir -p is idempotent —
      // re-warming a cold env never touches data.
      const createdDirs = [
        userRoot,
        workspaceDir,
        homeDir,
        join(cacheDir, "pnpm-store"),
        join(cacheDir, "uv"),
        etcDir,
      ];
      for (const d of createdDirs) await mkdir(d, { recursive: true });
      for (const d of createdDirs) await chown(d, uid, uid);

      // Quotas: workspace tier-scoped, package cache fixed (byte math pinned:
      // MB × 2^20). Tier: pro → proWorkspaceQuotaMb, anything else (incl. a
      // no-tier attach — the ptyBridge shape) → the FREE workspaceQuotaMb —
      // least privilege, the same rule workspaceDirFor applies below.
      const tierLabel: WorkspaceTier = tier === "pro" ? "pro" : "free";
      const quotaMb = tierLabel === "free" ? config.workspaceQuotaMb : config.proWorkspaceQuotaMb;
      await quota.applyQuota(workspaceDir, workspaceProjectId(uid), quotaMb * MB);
      await quota.applyQuota(cacheDir, cacheProjectId(uid), config.storeQuotaMb * MB);
      // Task 8 review F1 carry: record the tier the workspace quota project
      // was last applied with, so the workspaceDir seam re-asserts the SAME
      // (or higher) limit instead of silently downgrading a pro user's live
      // project to the free-tier bytes.
      tierByUid.set(uid, tierLabel);

      // Private /etc + home dotfiles (rewritten on re-warm — data dirs above
      // are never touched by this).
      await writeEnvFiles({
        etcDir,
        homeDir,
        bundle: renderEtcBundle({ dns: config.sandboxDns }),
        dotfiles: renderHomeDotfiles(),
        ownerUid: uid,
      });

      await cgroups.createEnv(uid, config.limits);

      const ctx = makeJailContext({
        config,
        cgroups,
        launcher,
        uid,
        rootfs: rootfs.path,
        workspaceDir,
        homeDir,
        etcDir,
      });
      // Kept so attachSession can mint a per-session view of this same env.
      ctxByUser.set(userId, ctx);

      // -- Task 9 leaf registries (ptys / jobs / spawned processes) ---------
      const ptys = new Map<string, PtySession>();
      let jobRegistry: JobRegistry | undefined;
      const spawnedProcs = new Set<SpawnedProcess>();

      const handle: ManagedHandle = {
        userId,
        uid,
        workspaceDir,
        homeDir,
        jailWorkspaceDir: JAIL_WORKSPACE,
        exec: (req: ExecRequest) => execOnce(ctx, req),
        createPty: async (req: PtyRequest, handlers: PtyHandlers) => {
          const session = await createPtySession(ctx, req, handlers);
          ptys.set(session.id, session);
          // A dead session is no longer a live leaf — stop tracking it.
          void session.exit.then(() => {
            ptys.delete(session.id);
          });
          return session;
        },
        getPty: (ptyId: string) => ptys.get(ptyId),
        get jobs(): JobRegistry {
          if (jobRegistry === undefined) jobRegistry = createJobRegistry(ctx);
          return jobRegistry;
        },
        spawnProcess: async (req: { argv: string[]; cwd?: string; env?: Record<string, string> }) => {
          const proc = await spawnLongRunning(ctx, req);
          spawnedProcs.add(proc);
          proc.onExit(() => {
            spawnedProcs.delete(proc);
          });
          return proc;
        },
        killLeaves: async () => {
          // Live leaves die FIRST (before the env kill in destroyUser), each
          // as its own cgroup tree-kill. allSettled: one wedged leaf must
          // never wedge the env teardown after it.
          const kills: Promise<unknown>[] = [];
          for (const session of ptys.values()) kills.push(session.kill());
          if (jobRegistry !== undefined) kills.push(jobRegistry.killAll());
          for (const proc of spawnedProcs) kills.push(proc.kill());
          await Promise.allSettled(kills);
          ptys.clear();
          spawnedProcs.clear();
        },
        destroy: () => destroyUser(userId),
        createdAt: clock(),
        tier: tierLabel,
      };
      handles.set(userId, handle);
      return handle;
    } catch (err) {
      releaseSlot();
      throw err;
    }
  }

  async function attach(
    userId: string,
    opts?: { tier?: "free" | "pro" },
  ): Promise<SandboxHandle> {
    const existing = handles.get(userId);
    if (existing !== undefined) {
      // Task 8 review F1 carry: a tier change on a LIVE env re-asserts the
      // workspace quota only UPWARD (free→pro raises the project limit and
      // the record). A lower requested tier would DOWNGRADE a live pro
      // project — never; the recorded tier wins, the same rule
      // workspaceDirFor applies below.
      if (opts?.tier === "pro" && existing.tier === "free") {
        await quota.applyQuota(
          existing.workspaceDir,
          workspaceProjectId(existing.uid),
          config.proWorkspaceQuotaMb * MB,
        );
        existing.tier = "pro";
        tierByUid.set(existing.uid, "pro");
      }
      return existing;
    }
    const pending = inFlight.get(userId);
    if (pending !== undefined) return pending;
    const p = doAttach(userId, opts?.tier).finally(() => {
      inFlight.delete(userId);
    });
    inFlight.set(userId, p);
    return p;
  }

  // -- the G1 seam ----------------------------------------------------------

  async function workspaceDirFor(userId: string, sessionId: string): Promise<string> {    const attached = handles.get(userId);
    let uid = attached?.uid ?? uidByUser.get(userId);
    if (uid === undefined) {
      uid = await deps.allocateUid(userId);
      uidByUser.set(userId, uid);
    }
    const sessionsRoot = join(config.workspacesRoot, String(uid), "sessions");
    const dir = join(sessionsRoot, sessionId);
    await mkdir(dir, { recursive: true });
    await chown(sessionsRoot, uid, uid);
    await chown(dir, uid, uid);
    // Per-USER workspace quota project (ruling P6-Q2): the sessions subtree
    // shares the user's project id — its usage counts against the same
    // quota as the agent workspace; there is no session-scoped quota.
    //
    // Task 8 review F1 carry: the re-asserted limit is TIER-AWARE. XFS
    // project limits are per-project, and this is the same project the
    // workspace quota was applied to, so re-asserting the free-tier bytes
    // here would silently DOWNGRADE a pro user's live quota. We re-assert
    // the tier the manager last applied at attach (free for a uid this
    // process has never attached — attach() re-asserts the user's real tier
    // on warm-up, and a stale tier only ever errs toward the recorded one
    // until then).
    const tier = tierByUid.get(uid) ?? "free";
    const quotaMb = tier === "free" ? config.workspaceQuotaMb : config.proWorkspaceQuotaMb;
    await quota.applyQuota(dir, workspaceProjectId(uid), quotaMb * MB);
    return dir;
  }

  /**
   * The session's workspace itself (`…/sessions/{id}/workspace`), created and
   * chowned. The XFS project quota applied to the parent session dir covers
   * this subtree, so no second `applyQuota` is needed.
   */
  async function sessionWorkspaceDir(userId: string, sessionId: string): Promise<string> {
    // sessionId reaches this from a job payload: never let it escape the tree.
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(sessionId)) {
      throw new Error("sessionId must be 1-64 chars of A-Za-z0-9_-");
    }
    const sessionRoot = await workspaceDirFor(userId, sessionId);
    const dir = join(sessionRoot, "workspace");
    const uid = handles.get(userId)?.uid ?? uidByUser.get(userId);
    await mkdir(dir, { recursive: true });
    if (uid !== undefined) await chown(dir, uid, uid);
    return dir;
  }

  /**
   * A per-session VIEW of the user's env. One cgroup and one `.home` are
   * shared (an env per chat would burn an admission slot per chat); only the
   * `/workspace` bind differs, and bwrap gives every exec its own mount
   * namespace, so concurrent sessions cannot see each other's files.
   */
  async function attachSession(
    userId: string,
    sessionId: string,
    opts?: { tier?: "free" | "pro" },
  ): Promise<SandboxHandle> {
    const key = `${userId}\u0000${sessionId}`;
    const existing = sessionHandles.get(key);
    if (existing !== undefined) return existing;

    const base = await attach(userId, opts);
    const parentCtx = ctxByUser.get(userId);
    if (parentCtx === undefined) {
      throw new Error("sandbox env is missing its jail context after attach");
    }
    const workspaceDir = await sessionWorkspaceDir(userId, sessionId);
    const ctx: JailContext = { ...parentCtx, workspaceDir };

    const ptys = new Map<string, PtySession>();
    let jobRegistry: JobRegistry | undefined;
    const spawnedProcs = new Set<SpawnedProcess>();

    const handle: ManagedHandle = {
      userId,
      uid: base.uid,
      workspaceDir,
      homeDir: base.homeDir,
      jailWorkspaceDir: JAIL_WORKSPACE,
      exec: (req: ExecRequest) => execOnce(ctx, req),
      createPty: async (req: PtyRequest, handlers: PtyHandlers) => {
        const session = await createPtySession(ctx, req, handlers);
        ptys.set(session.id, session);
        void session.exit.then(() => {
          ptys.delete(session.id);
        });
        return session;
      },
      getPty: (ptyId: string) => ptys.get(ptyId),
      get jobs(): JobRegistry {
        if (jobRegistry === undefined) jobRegistry = createJobRegistry(ctx);
        return jobRegistry;
      },
      spawnProcess: async (req: { argv: string[]; cwd?: string; env?: Record<string, string> }) => {
        const proc = await spawnLongRunning(ctx, req);
        spawnedProcs.add(proc);
        proc.onExit(() => {
          spawnedProcs.delete(proc);
        });
        return proc;
      },
      killLeaves: async () => {
        const kills: Promise<unknown>[] = [];
        for (const session of ptys.values()) kills.push(session.kill());
        if (jobRegistry !== undefined) kills.push(jobRegistry.killAll());
        for (const proc of spawnedProcs) kills.push(proc.kill());
        await Promise.allSettled(kills);
        ptys.clear();
        spawnedProcs.clear();
      },
      // A session view is not an env: dropping it leaves the user's sandbox
      // (and every other chat) alive.
      destroy: async () => {
        sessionHandles.delete(key);
      },
      createdAt: clock(),
      tier: tierByUid.get(base.uid) ?? "free",
    };
    sessionHandles.set(key, handle);
    return handle;
  }

  // -- recovery -------------------------------------------------------------

  async function recover(): Promise<void> {
    // 1. Numeric dirs in the workspaces root = known (cold) envs: data is
    // present, the env is not active. They stay cold — attach() re-warms.
    const known = new Set<number>();
    try {
      const entries = await readdir(config.workspacesRoot, { withFileTypes: true });
      for (const e of entries) {
        if (e.isDirectory() && /^\d+$/.test(e.name)) known.add(Number(e.name));
      }
    } catch (err) {
      if (isErrnoException(err) && err.code === "ENOENT") return; // nothing ever created
      throw err;
    }

    // 2. Env cgroups WITHOUT a workspace = orphans from a crashed/cleaned
    // run → kill+rmdir. Env cgroups WITH a workspace survive (a live handle
    // would have a workspace too; a crash leftover is re-warmed on attach).
    let children: string[];
    try {
      children = await cgroups.listChildren(join(config.cgroupRoot, config.cgroupBase));
    } catch (err) {
      if (isErrnoException(err) && err.code === "ENOENT") return; // no cgroup tree at all
      throw err;
    }
    for (const child of children) {
      const name = basename(child);
      if (!name.startsWith("sandbox-")) continue; // the worker leaf etc.
      const uid = Number(name.slice("sandbox-".length));
      if (!Number.isInteger(uid) || uid <= 0) continue;
      if (!known.has(uid)) {
        await cgroups.kill(child).catch((err: unknown) => {
          console.error(`sandbox recover: failed to remove orphan cgroup ${child}:`, err);
        });
      }
    }
    // {uid}/sessions/* eviction is P7 hibernation's — v1 leaves them.
  }

  async function close(): Promise<void> {
    for (const userId of [...handles.keys()]) await destroyUser(userId);
  }

  return {
    attach,
    attachSession,
    sessionWorkspaceDir,
    get: (userId: string) => handles.get(userId),
    destroy: destroyUser,
    list: () =>
      [...handles.values()].map((h) => ({
        userId: h.userId,
        uid: h.uid,
        createdAt: h.createdAt.toISOString(),
      })),
    activeCount: () => slotsInUse,
    workspaceDir: workspaceDirFor,
    recover,
    close,
  };
}
