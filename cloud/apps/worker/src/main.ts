import { pathToFileURL } from "node:url";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { Redis } from "ioredis";
import { createDb, eventMirror as eventMirrorRepo, fileManifests as fileManifestsRepo, runs as runsRepo, users, workspaceObjects as workspaceObjectsRepo } from "@ovid/db";
import { createRedisEventLog } from "@ovid/events";
import {
  createBrowserEngine,
  createLocalDiskBrowserStateStore,
  createStorageStatePersistence,
  loadBrowserEngineConfig,
} from "@ovid/browser";
import {
  createAgentRunsWorker,
  createHibernateWorker,
  createHydrateWorker,
  createQueues,
  hibernateJobSchema,
  hydrateJobSchema,
} from "@ovid/queue";
import {
  awaitWarm,
  createActivityTracker,
  createNoopSandboxEviction,
  createStorage,
  diskAlertFractionFromEnv,
  hibernateWorkspace,
  hydrateWorkspace,
  loadStorageEnv,
  maxWarmBytesFromEnv,
  reconcileStuckHibernations,
  STUCK_STATE_MS,
  SWEEP_INTERVAL_MS,
  sweepWorkspaces,
  type HibernateDeps,
  type HydrateDeps,
  type WarmConfig,
  type WarmDeps,
} from "@ovid/storage";
import {
  createCgroupManager,
  createRootmapLauncher,
  createSandboxManager,
  createSetuidLauncher,
  loadSandboxConfig,
  resolveRootfs,
  selectQuotaBackend,
} from "@ovid/sandbox";
import {
  createGuardedEgressFetch,
  createSsrfGuard,
  type EgressFetch,
  type GitHubApiPort,
} from "@ovid/agent-core";
import type { KeyProvider } from "@ovid/shared";
import { createFullAgentRunProcessor } from "./runProcessor.js";
import { buildFileService } from "./fileService.js";
import { startWorkerPtyBridge } from "./ptyBridge.js";
import { createSandboxPort } from "./sandboxAdapter.js";
import { sweepStaleRuns } from "./staleRuns.js";
import { createColdRowScan, createStuckHibernationScan, createStuckHydrationScan } from "./storageScans.js";

export interface WorkerEnv {
  nodeEnv: string;
  databaseUrl: string;
  redisQUrl: string;
  redisMintUrl: string;
  litellmBaseUrl: string;
  defaultModel: string;
  anthropicBaseUrl: string;
  windowTokens: number;
  approvalTimeoutMs: number;
  githubToken: string | null;
  runStaleMs: number;
  runQueueWaitMs: number;
  /** P7 Task 11: shared secret for the internal file service. */
  internalToken: string;
  /** P7 Task 11: container-internal file-service port. */
  workerFilePort: number;
  /** P7 Task 11: ensureWarm timeout (hydrate job + poll). */
  hydrateTimeoutMs: number;
  /** P7 Task 11: inline read cap; larger/binary files redirect to an artifact. */
  inlineMaxBytes: number;
  /** P7 Task 10: the ONE warm-disk knob pair. */
  warmConfig: WarmConfig;
  /** P6 Task 14: browser login-state persistence (null ⇒ off). */
  browserStateDir: string | null;
  /**
   * P6 Task 14: the browser-state encryption key. REQUIRED non-empty when
   * OVID_BROWSER_STATE_DIR is set (loadWorkerEnv refuses boot otherwise) —
   * persisting logins unencrypted is not a mode we ship.
   */
  masterKey: string | null;
}

/** A 'running' run older than this is considered stranded (sweeper threshold). */
const DEFAULT_RUN_STALE_MS = 600_000;
/** How often the stale-run sweeper re-checks after the boot pass. */
const STALE_SWEEP_INTERVAL_MS = 60_000;
/**
 * C1 default: how long a job may wait for older active same-session runs
 * (OVID_RUN_QUEUE_WAIT_MS); mirrors the processor's DEFAULT_RUN_QUEUE_WAIT_MS.
 */
const DEFAULT_RUN_QUEUE_WAIT_MS = 600_000;
/** P3 Task 16 defaults. */
const DEFAULT_ANTHROPIC_BASE = "https://api.anthropic.com";
const DEFAULT_WINDOW_TOKENS = 128_000;
const DEFAULT_APPROVAL_TIMEOUT_MS = 120_000;
/** P7 Task 11 defaults. */
const DEFAULT_WORKER_FILE_PORT = 8091;
const DEFAULT_HYDRATE_TIMEOUT_MS = 60_000;
const DEFAULT_INLINE_MAX_BYTES = 1024 * 1024;

/**
 * Validate the worker environment — same production-safety mindset as the
 * gateway's loadGatewayEnv (throws with the offending variable name), but
 * WITHOUT a test-mode bypass: a worker silently booted against empty
 * DATABASE_URL/REDIS_Q_URL would consume nothing and leave runs stalled in
 * 'queued' forever, which is worse than refusing to start. Variable names are
 * shared with the gateway's env where they overlap (deploy .env lists both).
 */
export function loadWorkerEnv(raw: NodeJS.ProcessEnv): WorkerEnv {
  const required = (name: string): string => {
    const value = raw[name]?.trim() ?? "";
    if (value === "") throw new Error(`${name} is required`);
    return value;
  };

  // Optional, but if set at all it must be a positive integer (ms) — an empty
  // or malformed value is a deployment misconfiguration and fails loudly at
  // startup (same mindset as the gateway's PORT validation).
  let runStaleMs = DEFAULT_RUN_STALE_MS;
  const staleRaw = raw.OVID_RUN_STALE_MS;
  if (staleRaw !== undefined) {
    const parsed = Number(staleRaw.trim());
    if (staleRaw.trim() === "" || !Number.isInteger(parsed) || parsed <= 0) {
      throw new Error(
        `OVID_RUN_STALE_MS must be a positive integer (milliseconds), got: ${staleRaw}`,
      );
    }
    runStaleMs = parsed;
  }

  // C1: how long a job may wait for older active runs of the same session
  // before run_queue_wait_timeout. Same validation discipline as above.
  let runQueueWaitMs = DEFAULT_RUN_QUEUE_WAIT_MS;
  const queueWaitRaw = raw.OVID_RUN_QUEUE_WAIT_MS;
  if (queueWaitRaw !== undefined) {
    const parsed = Number(queueWaitRaw.trim());
    if (queueWaitRaw.trim() === "" || !Number.isInteger(parsed) || parsed <= 0) {
      throw new Error(
        `OVID_RUN_QUEUE_WAIT_MS must be a positive integer (milliseconds), got: ${queueWaitRaw}`,
      );
    }
    runQueueWaitMs = parsed;
  }

  // P3 Task 16: optional positive-integer knobs, same fail-loud discipline.
  const positiveInt = (name: string, fallback: number): number => {
    const rawValue = raw[name];
    if (rawValue === undefined || rawValue.trim() === "") return fallback;
    const parsed = Number(rawValue.trim());
    if (!Number.isInteger(parsed) || parsed <= 0) {
      throw new Error(`${name} must be a positive integer, got: ${rawValue}`);
    }
    return parsed;
  };

  const anthropicBaseUrl =
    raw.OVID_ANTHROPIC_BASE?.trim() !== undefined &&
    raw.OVID_ANTHROPIC_BASE!.trim() !== ""
      ? raw.OVID_ANTHROPIC_BASE!.trim()
      : DEFAULT_ANTHROPIC_BASE;
  const githubToken = raw.GITHUB_API_TOKEN?.trim();
  const windowTokens = positiveInt("OVID_WINDOW_TOKENS", DEFAULT_WINDOW_TOKENS);
  const approvalTimeoutMs = positiveInt(
    "OVID_APPROVAL_TIMEOUT_MS",
    DEFAULT_APPROVAL_TIMEOUT_MS,
  );

  // P7 Task 11: the file service is internal-only but still token-gated; a
  // worker booted without the shared secret would either be unreachable or,
  // worse, open — refuse to start. The port/timeout knobs follow the same
  // positive-integer discipline as the rest of this loader.
  const internalToken = required("OVID_INTERNAL_TOKEN");
  const workerFilePort = positiveInt(
    "OVID_WORKER_FILE_PORT",
    DEFAULT_WORKER_FILE_PORT,
  );
  const hydrateTimeoutMs = positiveInt(
    "OVID_HYDRATE_TIMEOUT_MS",
    DEFAULT_HYDRATE_TIMEOUT_MS,
  );
  const inlineMaxBytes = positiveInt(
    "OVID_INLINE_MAX_BYTES",
    DEFAULT_INLINE_MAX_BYTES,
  );

  // P7 Task 10: the warm-cache knobs (maxWarmBytesFromEnv /
  // diskAlertFractionFromEnv throw on malformed values, naming the var).
  const warmConfig: WarmConfig = {
    maxWarmBytes: maxWarmBytesFromEnv(raw),
    diskAlertFraction: diskAlertFractionFromEnv(raw),
  };

  // P6 Task 14: browser login-state persistence. A state dir without a
  // master key would mean persisting logins unencrypted — refuse to boot,
  // naming the missing variable (same loud-failure mindset as the rest of
  // this loader).
  const browserStateDir = raw.OVID_BROWSER_STATE_DIR?.trim() || null;
  const masterKeyRaw = raw.OVID_MASTER_KEY?.trim() ?? "";
  if (browserStateDir !== null && masterKeyRaw === "") {
    throw new Error(
      "OVID_MASTER_KEY is required (non-empty) when OVID_BROWSER_STATE_DIR is set — refusing to persist browser login state unencrypted",
    );
  }
  const masterKey = masterKeyRaw === "" ? null : masterKeyRaw;

  return {
    nodeEnv: raw.NODE_ENV?.trim() || "development",
    databaseUrl: required("DATABASE_URL"),
    redisQUrl: required("REDIS_Q_URL"),
    redisMintUrl: required("REDIS_MINT_URL"),
    litellmBaseUrl: required("OVID_LITELLM_BASE"),
    defaultModel: required("OVID_DEFAULT_MODEL"),
    anthropicBaseUrl,
    windowTokens,
    approvalTimeoutMs,
    githubToken: githubToken !== undefined && githubToken !== "" ? githubToken : null,
    runStaleMs,
    runQueueWaitMs,
    internalToken,
    workerFilePort,
    hydrateTimeoutMs,
    inlineMaxBytes,
    warmConfig,
    browserStateDir,
    masterKey,
  };
}

/**
 * Worker-local copy of the gateway's mint-Redis key provider (controller
 * ruling: apps never import from apps — the KeyProvider INTERFACE comes from
 * @ovid/shared; slight duplication accepted until P9 consolidates).
 * REDIS_MINT_URL carries the db selector (mint's db2), so a plain GET.
 */
export function createMintRedisKeyProvider(redisMint: Redis): KeyProvider {
  return {
    getKeyForUser(uid) {
      return redisMint.get(`user:${uid}:key`);
    },
  };
}

/**
 * The GitHub REST port (P3 Task 16): `repo_tree`'s backing. The token is the
 * deployment's single GITHUB_API_TOKEN (P4 owns per-user OAuth); the port is
 * null when the env var is absent, so the roster never advertises repo_tree
 * without a credential. Egress is the SSRF-guarded fetch — never raw fetch.
 */
export function createGitHubApiPort(deps: {
  token: string;
  egress: EgressFetch;
}): GitHubApiPort {
  return {
    async getTree(_userId, o) {
      const ref = o.ref !== undefined && o.ref !== "" ? o.ref : "HEAD";
      const url =
        `https://api.github.com/repos/${encodeURIComponent(o.owner)}/` +
        `${encodeURIComponent(o.repo)}/git/trees/${encodeURIComponent(ref)}` +
        "?recursive=1";
      const res = await deps.egress(url, {
        headers: {
          authorization: `Bearer ${deps.token}`,
          accept: "application/vnd.github+json",
          "user-agent": "OvidCloud/1.0",
        },
      });
      if (!res.ok) {
        const body = (await res.text().catch(() => "")).trim().slice(0, 200);
        throw new Error(`GitHub HTTP ${res.status}${body === "" ? "" : `: ${body}`}`);
      }
      const parsed = (await res.json()) as {
        tree?: Array<{ path?: unknown; type?: unknown; size?: unknown }>;
      };
      const entries: Array<{ path: string; type: "blob" | "tree"; size?: number }> = [];
      for (const e of parsed.tree ?? []) {
        if (typeof e.path !== "string") continue;
        const type = e.type === "tree" ? "tree" : "blob";
        entries.push({
          path: e.path,
          type,
          ...(typeof e.size === "number" ? { size: e.size } : {}),
        });
      }
      return entries;
    },
  };
}

/**
 * Composition root — intentionally untested-thin (Task 10's e2e exercises the
 * wiring): env → real deps → BullMQ worker on "agent-runs" → graceful
 * shutdown. Not invoked at import; `node dist/main.js` invokes it.
 */
export async function main(env: NodeJS.ProcessEnv = process.env): Promise<void> {
  const cfg = loadWorkerEnv(env);

  const db = createDb(cfg.databaseUrl);
  // The session event ledger shares the QUEUE Redis — the SAME instance the
  // gateway reads replay/live from (Task 8 concern), so every worker append is
  // visible to subscribed clients.
  const redisQ = new Redis(cfg.redisQUrl);
  const redisMint = new Redis(cfg.redisMintUrl);
  const events = createRedisEventLog(redisQ);

  // ---- P7 Task 11/10: storage, activity cache and the storage queues. ----
  // Storage selection fails loud (production may not use the fs backend).
  const storage = createStorage(loadStorageEnv(env));
  // Activity keys are cache-class (spec §10 redis-c). REDIS_C_URL is optional:
  // when absent we share redis-q and say so once — eviction fails safe (the
  // sweeper falls back to file_manifests.updated_at).
  const redisCUrl = env.REDIS_C_URL?.trim();
  const redisC =
    redisCUrl !== undefined && redisCUrl !== ""
      ? new Redis(redisCUrl)
      : redisQ;
  if (redisC === redisQ) {
    console.warn(
      "[worker] REDIS_C_URL is not set — activity keys share REDIS_Q_URL " +
        "(cache-class fallback; spec §10 redis-c is preferred in production)",
    );
  }
  const activity = createActivityTracker(redisC);
  // Connection OPTIONS OBJECT (Task 7 lesson): a bare URL string hangs.
  const queues = createQueues({ url: cfg.redisQUrl });

  // ---- P2 Task 12: the SandboxManager chain (pinned composition order). ----
  // Every step fails LOUDLY at boot: a worker without a rootfs must never run
  // (the systemd unit is ordered after the rootfs install — Task 16), and a
  // half-booted cgroup tree is worse than refusing to start. main() stays
  // composition-root-thin on purpose (P1 convention): Task 14's e2e exercises
  // this wiring end to end.
  const sandboxConfig = loadSandboxConfig(env);
  const rootfs = await resolveRootfs(sandboxConfig.rootfsPath);
  const cgroups = createCgroupManager(sandboxConfig);
  await cgroups.init(); // leaf-first bootstrap (no-internal-process rule)
  const quota = await selectQuotaBackend(sandboxConfig.workspacesRoot);
  const launcher =
    sandboxConfig.launch === "rootmap"
      ? createRootmapLauncher(sandboxConfig)
      : createSetuidLauncher(sandboxConfig);
  const manager = createSandboxManager({
    config: sandboxConfig,
    allocateUid: (userId) => users.allocateSandboxUid(db, userId),
    cgroups,
    quota,
    launcher,
    rootfs,
  });
  await manager.recover(); // orphan env cgroups from a crashed run die now

  // P2 Task 13: the terminal-over-WS worker bridge. Started AFTER recovery —
  // a pty ctl can only be served once the manager chain is ready; its stop()
  // runs BEFORE manager.close() in shutdown() (the manager's env teardown
  // kills every live pty leaf; the bridge itself never kills ptys).
  const stopPtyBridge = await startWorkerPtyBridge({ sandbox: manager, redis: redisQ });

  // ---- P6 Task 14: the browser engine facade. -----------------------------
  // Config comes from the same env (every knob fails fast inside
  // loadBrowserEngineConfig, naming its variable). Persistence only when BOTH
  // the state dir and the master key are present — loadWorkerEnv already
  // refused the dir-without-key combination. The engine's bridge connections
  // ride redis-q per the P6-Q6 ruling (ephemeral pub/sub, AG3-safe).
  const browserEngineCfg = loadBrowserEngineConfig(env);
  const browserPersistence =
    cfg.browserStateDir !== null && cfg.masterKey !== null
      ? createStorageStatePersistence(createLocalDiskBrowserStateStore(cfg.browserStateDir), cfg.masterKey)
      : null;
  const browser = await createBrowserEngine({
    cfg: browserEngineCfg,
    redisFactory: () => new Redis(cfg.redisQUrl),
    persistence: browserPersistence,
    // P2's resolved root (OVID_WORKSPACES_ROOT) — the same layout the
    // SandboxManager and the hydrator engines use, so browser artifacts land
    // inside the session's workspace jail.
    workspaceDir: async (userId: string, sessionId: string) => {
      const dir = join(sandboxConfig.workspacesRoot, userId, "sessions", sessionId);
      await mkdir(dir, { recursive: true });
      return dir;
    },
  });

  // ---- P7 Task 8/9/10: state-hydrator engines + internal file service. ----
  // workspacesRoot is P2's resolved root (OVID_WORKSPACES_ROOT,
  // /workspaces/users by default): P7 MUST use the same root or the engines
  // and the SandboxManager would disagree about where a session lives.
  const workspacesRoot = sandboxConfig.workspacesRoot;
  const hibernateDeps: HibernateDeps = {
    db,
    events,
    storage,
    workspacesRoot,
    // TODO(P2): replace the noop seam with the real SandboxManager-backed
    // eviction once P2 exposes it (contract 1). The engine itself is done.
    sandbox: createNoopSandboxEviction((msg) => console.warn(`[worker] ${msg}`)),
    activity,
    fileManifests: fileManifestsRepo,
    workspaceObjects: workspaceObjectsRepo,
    runs: runsRepo,
    eventMirror: eventMirrorRepo,
    stuckHibernationScan: createStuckHibernationScan(),
  };
  const hydrateDeps: HydrateDeps = {
    db,
    events,
    storage,
    workspacesRoot,
    activity,
    fileManifests: fileManifestsRepo,
    eventMirror: eventMirrorRepo,
  };
  const warmDeps: WarmDeps = {
    ...hibernateDeps,
    // The spread above narrows fileManifests to T8's mirror; T10's LRU needs
    // the real repo's extra methods (upsertWarm/listWarmForLru/markColdRetry).
    fileManifests: fileManifestsRepo,
    queues: { hibernate: queues.hibernate },
    stuckHydrationScan: createStuckHydrationScan(),
    // T10-review carry (T8-F1): the bounded cold-row scan is what finds a
    // post-markCold residue dir the (already evicted) seam cannot see.
    coldRowScan: createColdRowScan(),
  };

  // Validate the wire payload with the queue schema before the engine sees it
  // (a malformed job must fail loudly, not half-hibernate a workspace).
  const hibernateWorker = createHibernateWorker({ url: cfg.redisQUrl }, async (job) =>
    hibernateWorkspace(hibernateDeps, hibernateJobSchema.parse(job.data)),
  );
  hibernateWorker.on("error", (err) => {
    console.error("[worker] hibernate worker error", err);
  });
  const hydrateWorker = createHydrateWorker({ url: cfg.redisQUrl }, async (job) =>
    hydrateWorkspace(hydrateDeps, hydrateJobSchema.parse(job.data)),
  );
  hydrateWorker.on("error", (err) => {
    console.error("[worker] hydrate worker error", err);
  });

  // Internal HTTP: container network only (never a host-published port).
  const fileService = buildFileService({
    db,
    events,
    storage,
    workspacesRoot,
    activity,
    internalToken: cfg.internalToken,
    inlineMaxBytes: cfg.inlineMaxBytes,
    port: cfg.workerFilePort,
    host: "0.0.0.0",
    fileManifests: fileManifestsRepo,
    eventMirror: eventMirrorRepo,
    workspaceObjects: workspaceObjectsRepo,
  });
  await fileService.listen({ port: cfg.workerFilePort, host: "0.0.0.0" });
  console.log(`[worker] internal file service listening on :${cfg.workerFilePort}`);

  // P7 Task 11: the run hook — hydrate before any tool touches the
  // workspace. T9-review I3: pass the repo so awaitWarm does not need the
  // raw `$client.unsafe` path.
  const ensureWarm = async (sessionId: string, userId: string): Promise<void> => {
    await awaitWarm(
      db,
      queues.hydrate,
      { sessionId, userId },
      {
        reason: "run",
        timeoutMs: cfg.hydrateTimeoutMs,
        fileManifests: fileManifestsRepo,
      },
    );
  };


  // P3 Task 16: the production processor is the FULL engine. Egress is the
  // SSRF-guarded fetch at every construction site (T5-I1 / M-4): model
  // transports and the GitHub REST port alike. No raw-fetch default remains
  // in the worker's production path.
  const egress = createGuardedEgressFetch(createSsrfGuard());
  const github =
    cfg.githubToken !== null
      ? createGitHubApiPort({ token: cfg.githubToken, egress })
      : null;
  const processor = createFullAgentRunProcessor({
    db,
    events,
    keys: createMintRedisKeyProvider(redisMint),
    redisQ,
    // P2's manager adapted onto the canonical SandboxPort (Task 9). The
    // provider egress inside the processor allowlists this configured
    // LiteLLM origin (which is loopback in production) — user URLs stay
    // fully guarded.
    sandbox: createSandboxPort(manager),
    // Review I2: one port per tier so the workspace quota project matches
    // the user's plan (free 500 MB / pro 2048 MB), and the P2 handle the
    // adapted six-tool roster needs is attached with the SAME tier.
    sandboxForTier: (tier) => createSandboxPort(manager, { tier }),
    sandboxHandleFor: (userId, tier) => manager.attach(userId, { tier }),
    github,
    litellmBaseUrl: cfg.litellmBaseUrl,
    defaultModel: cfg.defaultModel,
    anthropicBaseUrl: cfg.anthropicBaseUrl,
    windowTokens: cfg.windowTokens,
    approvalTimeoutMs: cfg.approvalTimeoutMs,
    runQueueWaitMs: cfg.runQueueWaitMs,
    ensureWarm,
    activity,
  });

  // Connection OPTIONS OBJECT — a bare URL string silently spreads into
  // garbage opts and hangs (Task 7 lesson, pinned by its health test).
  const worker = createAgentRunsWorker({ url: cfg.redisQUrl }, processor);
  worker.on("error", (err) => {
    console.error("[worker] bullmq worker error", err);
  });
  console.log(
    `[worker] consuming agent-runs (env=${cfg.nodeEnv}, model=${cfg.defaultModel}, litellm=${cfg.litellmBaseUrl})`,
  );

  // Stale-run sweeper (fix-round ruling): with attempts:1, failed jobs are
  // never redelivered and a mid-run crash strands the run row in 'running'
  // forever — the sweeper terminalizes those (run_failed {code:"run_lost"}).
  // Once at boot, then every 60 s; sweep errors are logged, never fatal (the
  // next pass retries), and the interval must never hold the process open.
  const sweep = async (label: string): Promise<void> => {
    try {
      const swept = await sweepStaleRuns(
        { db, events },
        { staleAfterMs: cfg.runStaleMs },
      );
      if (swept > 0) {
        console.log(`[worker] stale-run sweep (${label}): terminalized ${swept} stranded run(s)`);
      }
    } catch (err) {
      console.error(`[worker] stale-run sweep (${label}) failed`, err);
    }
  };
  await sweep("boot");
  const sweeper = setInterval(() => {
    void sweep("interval");
  }, STALE_SWEEP_INTERVAL_MS);
  sweeper.unref();

  // P7 Task 10/11: crash recovery FIRST (hibernating rows whose dir is gone
  // get closed cold; a present dir is reset warm), then the warm sweeper in
  // the EXACT stale-run interval shape: once at boot ("boot" label), every
  // 30 s after ("interval"), errors logged never fatal, .unref() so the
  // process can exit, cleared in shutdown().
  try {
    const reconciled = await reconcileStuckHibernations(hibernateDeps, {
      stuckAfterMs: STUCK_STATE_MS,
    });
    if (reconciled.resetToWarm > 0 || reconciled.closedToCold > 0) {
      console.log(
        `[worker] stuck-hibernation reconcile (boot): ${reconciled.resetToWarm} reset warm, ` +
          `${reconciled.closedToCold} closed cold`,
      );
    }
  } catch (err) {
    console.error("[worker] stuck-hibernation reconcile (boot) failed", err);
  }
  const sweepWarm = async (label: string): Promise<void> => {
    try {
      const result = await sweepWorkspaces(warmDeps, cfg.warmConfig);
      if (
        result.registered > 0 ||
        result.enqueuedIdle > 0 ||
        result.enqueuedPressure > 0
      ) {
        console.log(
          `[worker] warm sweep (${label}): registered ${result.registered}, ` +
            `idle ${result.enqueuedIdle}, pressure ${result.enqueuedPressure}`,
        );
      }
    } catch (err) {
      console.error(`[worker] warm sweep (${label}) failed`, err);
    }
  };
  await sweepWarm("boot");
  const warmSweeper = setInterval(() => {
    void sweepWarm("interval");
  }, SWEEP_INTERVAL_MS);
  warmSweeper.unref();

  let shuttingDown: Promise<void> | null = null;
  const shutdown = (): Promise<void> => {
    shuttingDown ??= (async () => {
      clearInterval(sweeper);
      clearInterval(warmSweeper);
      // P2 Task 13 pin: the pty bridge stops FIRST (no new ctl mid-teardown),
      // then the sandbox manager — manager.close() kills every live pty leaf,
      // and each pty's onExit publishes its `exit` + HDELs its registry key.
      await stopPtyBridge();
      // P2 Task 12 pin: manager.close() BEFORE the drain — sandbox envs (their
      // cgroup trees, live leaves and admission slots) tear down first.
      await manager.close();
      // P6 Task 14 pin: browser state is flushed BEFORE the run worker drains
      // — close() releases every live session (capture → persistence.flush →
      // context close) so logins survive the restart, then tears down the
      // bridge, research and pool in order.
      await browser.close();
      // Drains in-flight jobs and stops fetching new ones (force=false).
      await worker.close();
      // P7 Task 11: stop storage consumers before their producer queues.
      await hibernateWorker.close();
      await hydrateWorker.close();
      await fileService.close();
      await queues.agentRuns.close();
      await queues.hibernate.close();
      await queues.hydrate.close();
      // Reap the approval bridge's subscription (pending asks fail closed).
      await processor.close();
      if (redisC !== redisQ) redisC.disconnect();
      redisQ.disconnect();
      redisMint.disconnect();
      await db.$client.end({ timeout: 5 });
    })();
    return shuttingDown;
  };
  const onSignal = (signal: string): void => {
    console.log(`[worker] ${signal} received — draining and shutting down`);
    shutdown().then(
      () => process.exit(0),
      (err) => {
        console.error("[worker] shutdown failed", err);
        process.exit(1);
      },
    );
  };
  process.once("SIGTERM", () => onSignal("SIGTERM"));
  process.once("SIGINT", () => onSignal("SIGINT"));
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error("[worker] fatal startup error", err);
    process.exit(1);
  });
}
