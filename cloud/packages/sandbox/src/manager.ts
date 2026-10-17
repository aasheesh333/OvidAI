import { chown, mkdir, readdir, stat, statfs } from "node:fs/promises";
import { basename, join } from "node:path";
import type { CgroupManager } from "./cgroups.js";
import type { SandboxConfig } from "./config.js";
import { renderEtcBundle, renderHomeDotfiles, writeEnvFiles } from "./etcFiles.js";
import { execOnce, makeJailContext } from "./exec.js";
import { JAIL_WORKSPACE } from "./invocation.js";
import type { JailLauncher } from "./launcher.js";
import { cacheProjectId, workspaceProjectId, type QuotaBackend } from "./quota.js";
import type { ResolvedRootfs } from "./rootfs.js";
import type { ExecRequest, ExecResult } from "./types.js";

/**
 * SandboxManager (P2 Task 8): lifecycle, FIFO admission beyond
 * maxActiveSandboxes, per-user XFS/noop quotas, boot recovery, and the
 * workspaceDir(userId, sessionId) seam.
 */

const MB = 1024 * 1024;
const GB = 1024 * 1024 * 1024;

/**
 * One live sandbox environment. Task 9 grows this with createPty/getPty/
 * jobs/spawnProcess (the handle is the env those leaves hang under).
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
  /**
   * Kill all live leaves (ptys/jobs from Task 9), kill+rmdir the env cgroup,
   * deregister, release the admission slot. Workspace DATA persists — purge
   * is P9 account deletion.
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

export function createSandboxManager(deps: SandboxManagerDeps): SandboxManager {
  const { config, cgroups, quota, launcher, rootfs } = deps;
  const clock = deps.clock ?? (() => new Date());
  const diskUsage = deps.diskUsage ?? (() => defaultDiskUsage(config.workspacesRoot));

  const handles = new Map<string, ManagedHandle>();
  /** Concurrent attach for the same userId dedupes onto one create. */
  const inFlight = new Map<string, Promise<SandboxHandle>>();
  /** user → uid, so destroy→attach and workspaceDir→attach reuse the uid (the prod allocator is idempotent; this makes the manager so too). */
  const uidByUser = new Map<string, number>();
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
    // Task 9 grows this: kill live leaves (ptys/jobs) FIRST, before the env.
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
      // MB × 2^20). Tier: free → workspaceQuotaMb, anything else →
      // proWorkspaceQuotaMb.
      const quotaMb = tier === "free" ? config.workspaceQuotaMb : config.proWorkspaceQuotaMb;
      await quota.applyQuota(workspaceDir, workspaceProjectId(uid), quotaMb * MB);
      await quota.applyQuota(cacheDir, cacheProjectId(uid), config.storeQuotaMb * MB);

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
      const handle: ManagedHandle = {
        userId,
        uid,
        workspaceDir,
        homeDir,
        jailWorkspaceDir: JAIL_WORKSPACE,
        exec: (req: ExecRequest) => execOnce(ctx, req),
        destroy: () => destroyUser(userId),
        createdAt: clock(),
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
    if (existing !== undefined) return existing;
    const pending = inFlight.get(userId);
    if (pending !== undefined) return pending;
    const p = doAttach(userId, opts?.tier).finally(() => {
      inFlight.delete(userId);
    });
    inFlight.set(userId, p);
    return p;
  }

  // -- the G1 seam ----------------------------------------------------------

  async function workspaceDirFor(userId: string, sessionId: string): Promise<string> {
    const attached = handles.get(userId);
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
    // quota as the agent workspace; there is no session-scoped quota. The
    // free-tier byte value re-asserts the project limit (XFS limits are
    // per-project; a later pro attach raises it on the same project).
    await quota.applyQuota(dir, workspaceProjectId(uid), config.workspaceQuotaMb * MB);
    return dir;
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
