import { pathToFileURL } from "node:url";
import { hostname } from "node:os";
import { initializeApp, getApps } from "firebase-admin/app";
import { Redis } from "ioredis";
import { assertSessionFileCapacity, createDb, createStorageQuotaRepos, RunQuotaService, createStudioPreviewPostgresStore, createStudioPreviewStore, dbPoolOptionsFromEnv, byokKeysRepo, eventMirror as eventMirrorRepo, fileManifests as fileManifestsRepo, imagesRepo, mcpOauthFlows, mcpServers as mcpServersRepo, messages as messagesRepo, runs as runsRepo, sharesRepo, users, workspaceObjects as workspaceObjectsRepo, type Db, type DbOrTx } from "@ovid/db";
import {
  createCloudCleanup,
  createFirebaseAdmin,
  createHttpKeyAdmin,
  createLifecycle,
  createNoopR2Deleter,
  createPostgresDeletionStore,
  type AccountDataDeleter,
} from "@ovid/account";
import { createRedisEventLog, createRedisSystemBus } from "@ovid/events";
import {
  createBrowserEngine,
  createLocalDiskBrowserStateStore,
  createStorageStatePersistence,
  loadBrowserEngineConfig,
} from "@ovid/browser";
import {
  AGENT_RUN_JOB_NAME,
  createAgentRunsWorker,
  createHibernateWorker,
  createHydrateWorker,
  createPluginInstallsWorker,
  createQueues,
  createScheduleFireWorker,
  hibernateJobSchema,
  hydrateJobSchema,
} from "@ovid/queue";
import {
  awaitWarm,
  createActivityTracker,
  createR2PrefixDeleterFromEnv,
  createSandboxManagerEviction,
  createStorage,
  createHttpArtifactGrantFactory,
  diskAlertFractionFromEnv,
  hibernateWorkspace,
  hydrateWorkspace,
  loadStorageEnv,
  loadCdnConfig,
  maxWarmBytesFromEnv,
  reconcileStuckHibernations,
  registerArtifact,
  STUCK_STATE_MS,
  SWEEP_INTERVAL_MS,
  sweepWorkspaces,
  type HibernateDeps,
  type HydrateDeps,
  type ArtifactProjectCapacity,
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
  createSsrfGuard,
  type EgressFetch,
  type GitHubApiPort,
} from "@ovid/agent-core";
import type { KeyResolver } from "@ovid/shared";
import { createSecretRedactor } from "@ovid/mcp";
import { createByokKeyProvider, createEnvelopeCrypto } from "@ovid/escrow";
import {
  createFullAgentRunProcessor,
  type FullAgentRunProcessor,
  type FullRunDeps,
  type RunAttachmentStorage,
} from "./runProcessor.js";
import { createServerKeyResolver } from "./keyResolver.js";
import { buildFileService } from "./fileService.js";
import { createStudioGitService, parseStudioGitAllowedHosts } from "./studioGitRoutes.js";
import { createMcpRuntime } from "./mcpRuntime.js";
import { createFetchEgressPolicy } from "./fetchEgressPolicy.js";
import {
  createJailedStudioPreviewProcessRunner,
  createStudioPreviewManager,
  type StudioPreviewManager,
} from "./studioPreview.js";
import { StudioRunBinding } from "./studioRunBinding.js";
import { createNotifier, createFcmPushSender } from "./notify.js";
import { createWebPushSender } from "./webPush.js";
import { createPluginInstallProcessor } from "./pluginInstallProcessor.js";
import { startWorkerPtyBridge } from "./ptyBridge.js";
import { createSandboxPort, createStepLimiter } from "./sandboxAdapter.js";
import { adaptBrowserTools, createUserBrowserLeases } from "./browserToolAdapter.js";
import { createBrowserArtifactVaultPort, createBrowserCredentialsPort } from "./browserCredentials.js";
import { createModelCatalogReader } from "./modelCapabilities.js";
import { createSandboxSeam } from "./sandboxSeam.js";
import { createScheduleFireProcessor, resyncScheduleMirror } from "./schedulerMirror.js";
import { createScheduleTools, toCoreTools } from "./scheduleTools.js";
import {
  createImageTools,
  createInternalImageClient,
  fetchImageCapabilities,
  type ImageCapabilities,
  type ImageTooling,
} from "./tools/imageTools.js";
import { startSchedulerLoop } from "./schedulerTick.js";
import { sweepStaleRuns } from "./staleRuns.js";
import { createColdRowScan, createStuckHibernationScan, createStuckHydrationScan } from "./storageScans.js";
import { createUnattendedApprovalHook } from "./unattended.js";
import { startAccountDeletionSweeper } from "./accountSweep.js";

export interface WorkerEnv {
  nodeEnv: string;
  databaseUrl: string;
  redisQUrl: string;
  redisMintUrl: string;
  /**
   * P9 Task 9: mint's ADMIN listener. The worker signs its own uid and calls
   * /internal/mint-key for unattended runs whose key is missing from db2.
   */
  internalMintUrl: string;
  /** Gateway-internal grant service base URL; null => CDN publication unavailable. */
  gatewayInternalUrl: string | null;
  /** P9 Task 9: shared HMAC secret (OVID_INTERNAL_API_SECRET, >= 32 bytes). */
  internalApiSecret: string;
  litellmBaseUrl: string;
  defaultModel: string;
  anthropicBaseUrl: string;
  windowTokens: number;
  approvalTimeoutMs: number;
  githubToken: string | null;
  runStaleMs: number;
  runQueueWaitMs: number;
  /** P4 Task 10: scheduler pass cadence (env OVID_SCHEDULER_TICK_MS). */
  schedulerTickMs: number;
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
/** P4 Task 10: the plan-pinned scheduler cadence (Dart: 15 s). */
const DEFAULT_SCHEDULER_TICK_MS = 15_000;
/**
 * Audit P2 (mcp_oauth_flows retention): a row is created per flow start and
 * consume() only marks it used — nothing deleted them. The sweep runs
 * daily-ish; the cutoff keeps a one-day grace window for late callbacks.
 */
const OAUTH_FLOW_SWEEP_INTERVAL_MS = 24 * 60 * 60 * 1000;
const OAUTH_FLOW_SWEEP_GRACE_MS = 24 * 60 * 60 * 1000;
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
  // P4 Task 10: scheduler tick cadence — same positive-integer discipline as
  // OVID_RUN_STALE_MS (a malformed value is a deployment bug, not a default).
  const schedulerTickMs = positiveInt(
    "OVID_SCHEDULER_TICK_MS",
    DEFAULT_SCHEDULER_TICK_MS,
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
  // M5: the MCP runtime's envelope crypto requires exactly 64 hex chars
  // (32 bytes). Validate HERE so a misconfigured key fails at boot naming
  // OVID_MASTER_KEY instead of throwing an opaque crypto error later.
  if (masterKeyRaw !== "" && !/^[0-9a-fA-F]{64}$/.test(masterKeyRaw)) {
    throw new Error(
      "OVID_MASTER_KEY must be exactly 64 hex characters (32 bytes; generate with `openssl rand -hex 32`)",
    );
  }
  if (browserStateDir !== null && masterKeyRaw === "") {
    throw new Error(
      "OVID_MASTER_KEY is required (non-empty) when OVID_BROWSER_STATE_DIR is set — refusing to persist browser login state unencrypted",
    );
  }
  const masterKey = masterKeyRaw === "" ? null : masterKeyRaw;

  // P9 Task 9: the internal mint endpoint + its HMAC secret. Both are
  // required: a worker booted without them could not mint for unattended
  // runs, and a short secret would weaken the only auth on that surface.
  const internalMintUrl = required("OVID_INTERNAL_MINT_URL");
  const internalApiSecret = required("OVID_INTERNAL_API_SECRET");
  if (Buffer.byteLength(internalApiSecret, "utf8") < 32) {
    throw new Error("OVID_INTERNAL_API_SECRET must be at least 32 bytes");
  }
  const gatewayInternalUrl = raw.OVID_GATEWAY_INTERNAL_URL?.trim() || null;
  if (gatewayInternalUrl !== null) {
    const parsed = new URL(gatewayInternalUrl);
    if ((parsed.protocol !== "http:" && parsed.protocol !== "https:") ||
        parsed.username !== "" || parsed.password !== "" || parsed.search !== "" || parsed.hash !== "") {
      throw new Error("OVID_GATEWAY_INTERNAL_URL must be an absolute http(s) base URL without credentials/query/fragment");
    }
  }

  return {
    nodeEnv: raw.NODE_ENV?.trim() || "development",
    databaseUrl: required("DATABASE_URL"),
    redisQUrl: required("REDIS_Q_URL"),
    redisMintUrl: required("REDIS_MINT_URL"),
    internalMintUrl,
    gatewayInternalUrl,
    internalApiSecret,
    litellmBaseUrl: required("OVID_LITELLM_BASE"),
    defaultModel: required("OVID_DEFAULT_MODEL"),
    anthropicBaseUrl,
    windowTokens,
    approvalTimeoutMs,
    githubToken: githubToken !== undefined && githubToken !== "" ? githubToken : null,
    runStaleMs,
    runQueueWaitMs,
    schedulerTickMs,
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
 * P9 Task 9: build the production key resolver. BYOK escrow is wired only
 * when OVID_MASTER_KEY is present; a referenced BYOK key with no provider
 * fails the run (never a silent fallback to Ovid's key — see keyResolver.ts).
 * The internal mint client signs its own uid with the shared HMAC secret.
 */
export function createProductionKeyResolver(deps: {
  db: ReturnType<typeof createDb>;
  redisMint: Redis;
  masterKey: string | null;
  internalMintUrl: string;
  internalApiSecret: string;
  litellmBaseUrl: string;
}): KeyResolver {
  const byok =
    deps.masterKey === null
      ? null
      : createByokKeyProvider(deps.db, createEnvelopeCrypto(deps.masterKey), {
          log: (message, detail) => console.warn(`[worker] ${message}`, detail ?? ""),
        });
  if (byok === null) {
    console.warn(
      "[worker] OVID_MASTER_KEY is not set — BYOK runs will fail (no silent fallback to Ovid's key)",
    );
  }
  return createServerKeyResolver({
    redisMint: deps.redisMint,
    internalMint: { baseUrl: deps.internalMintUrl, secret: deps.internalApiSecret },
    byok,
    litellmBaseUrl: deps.litellmBaseUrl,
  });
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
 * The production full-processor composition seam. Keeping the existing storage
 * adapter as a required argument makes attachment HEAD/materialization part of
 * composition rather than an optional test-only injection.
 */
export function createProductionAgentRunProcessor(
  deps: Omit<FullRunDeps, "storage">,
  storage: RunAttachmentStorage,
): FullAgentRunProcessor {
  return createFullAgentRunProcessor({ ...deps, storage });
}

const STUDIO_PREVIEW_SWEEP_INTERVAL_MS = 30_000;
const STUDIO_PREVIEW_TERMINAL_STATUSES = new Set(["stopped", "failed", "expired"]);

async function studioPreviewTableExists(db: Db): Promise<boolean> {
  const [row] = await db.$client`
    SELECT to_regclass('studio_previews') AS table_name`;
  return row?.table_name !== null && row?.table_name !== undefined;
}

/**
 * Account-owned cleanup, not a general preview delete API. Every attempt
 * re-enumerates current sessions, stops their previews, then locks and checks
 * the complete account scope before deleting terminal evidence only. The
 * terminal predicate and post-delete check keep live/unknown rows authoritative
 * even if a concurrent admission races this cleanup; parent FKs then force the
 * durable account lifecycle to retry rather than silently cascading evidence.
 */
export function createStudioPreviewAccountCleanup(deps: {
  db: Db;
  previews: Pick<StudioPreviewManager, "stopSession"> | null;
}): AccountDataDeleter {
  return {
    async deleteAccount(uid) {
      // Pre-0041 schemas retain the legacy account deletion behavior. This is
      // checked on every retry: installing the table after worker boot must
      // fail closed when this process has no preview manager, never bypass it.
      if (!(await studioPreviewTableExists(deps.db))) return;
      if (deps.previews === null) {
        throw new Error("Studio previews are unavailable; account cleanup cannot prove terminal state");
      }
      const sessions = (await deps.db.$client`
        SELECT id FROM sessions WHERE user_id = ${uid}`) as Array<{ id: string }>;
      for (const session of sessions) {
        await deps.previews.stopSession({
          userId: uid,
          sessionId: session.id,
          reason: "delete",
        });
      }
      await deps.db.$client.begin(async (tx) => {
        const registered = (await tx`
          SELECT id, status FROM studio_previews WHERE user_id = ${uid} FOR UPDATE`) as Array<{
            id: string;
            status: string;
          }>;
        if (registered.some((row) => !STUDIO_PREVIEW_TERMINAL_STATUSES.has(row.status))) {
          throw new Error("Studio preview cleanup is not terminal; account deletion must retry");
        }
        await tx`
          DELETE FROM studio_previews
           WHERE user_id = ${uid}
             AND status IN ('stopped', 'failed', 'expired')`;
        const remaining = (await tx`
          SELECT id, status FROM studio_previews WHERE user_id = ${uid}`) as Array<{
            id: string;
            status: string;
          }>;
        if (remaining.length > 0) {
          throw new Error("Studio preview terminal evidence is incomplete; account deletion must retry");
        }
      });
    },
  };
}

export interface StudioPreviewSweeper {
  /** The already-started boot pass; interval passes join it rather than overlap. */
  boot: Promise<void>;
  /** Clears the interval and awaits the currently active pass, if any. */
  stop(): Promise<void>;
}

export function startStudioPreviewSweeper(
  previews: Pick<StudioPreviewManager, "sweep">,
): StudioPreviewSweeper {
  let stopped = false;
  let active: Promise<void> | null = null;
  const run = (label: string): Promise<void> => {
    if (stopped) return Promise.resolve();
    if (active !== null) return active;
    const current = (async () => {
      try {
        const swept = await previews.sweep();
        if (swept > 0) {
          console.log(`[worker] Studio preview sweep (${label}): terminalized ${swept} preview(s)`);
        }
      } catch (err) {
        console.error(`[worker] Studio preview sweep (${label}) failed`, err);
      }
    })();
    active = current;
    const clear = (): void => {
      if (active === current) active = null;
    };
    void current.then(clear, clear);
    return current;
  };

  const boot = run("boot");
  const timer = setInterval(() => {
    void run("interval");
  }, STUDIO_PREVIEW_SWEEP_INTERVAL_MS);
  timer.unref();
  return {
    boot,
    async stop() {
      stopped = true;
      clearInterval(timer);
      await (active ?? boot);
    },
  };
}

/** The preview-specific segment of worker shutdown; DB stays open above it. */
export async function closeStudioPreviewResources(deps: {
  previewSweepStopped: Promise<void> | null;
  fileService: { close(): Promise<unknown> };
  previews: Pick<StudioPreviewManager, "close"> | null;
  closeManager: () => Promise<unknown>;
}): Promise<void> {
  await deps.previewSweepStopped;
  await deps.fileService.close();
  await deps.previews?.close();
  await deps.closeManager();
}

/**
 * Composition root — intentionally untested-thin (Task 10's e2e exercises the
 * wiring): env → real deps → BullMQ worker on "agent-runs" → graceful
 * shutdown. Not invoked at import; `node dist/main.js` invokes it.
 */
export async function main(env: NodeJS.ProcessEnv = process.env): Promise<void> {
  const cfg = loadWorkerEnv(env);
  const studioMasterKey = cfg.masterKey;
  if (studioMasterKey === null) {
    throw new Error("OVID_MASTER_KEY is required for Studio git");
  }

  // Audit P1 (MCP client): a server→client request racing a close rejects
  // inside fire-and-forget promise chains, and Node's default for an
  // unhandled rejection is to kill the process. The contained sites now
  // catch, but nothing here should ever be able to crash the worker — log
  // and carry on (the rejection carries no state we can act on).
  process.on("unhandledRejection", (err) => {
    console.error("[worker] unhandled rejection (logged, not fatal)", err);
  });

  // Pool size: OVID_DB_POOL_MAX / OVID_DB_IDLE_TIMEOUT_S (capacity wave);
  // unset keeps the postgres.js default (10).
  const db = createDb(cfg.databaseUrl, dbPoolOptionsFromEnv(env));
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
  // P5 Task 14: opt in to the plugin-installs queue (additive; the other
  // queues' key layout is unchanged).
  const queues = createQueues(
    { url: cfg.redisQUrl },
    { withPluginInstalls: true },
  );

  // ---- P4 Task 10: the scheduler's system bus + notifier. -----------------
  // ONE bus instance for the worker's publishes; the gateway's WS system
  // channel subscribes to the same `user:<uid>:system` channels. The notifier
  // is best-effort by contract (never throws, never affects bookkeeping).
  const system = createRedisSystemBus(redisQ);
  const notifier = createNotifier({
    db,
    push: createFcmPushSender(),
    webPush: createWebPushSender({
      publicKey: process.env.VAPID_PUBLIC_KEY ?? "",
      privateKey: process.env.VAPID_PRIVATE_KEY ?? "",
      subject: process.env.VAPID_SUBJECT ?? "",
      allowedHosts: (process.env.WEB_PUSH_ALLOWED_HOSTS ?? "")
        .split(",").map((host) => host.trim()).filter((host) => host !== ""),
    }),
  });

  // Shared actual-byte reservations and signed gateway grants for every
  // ordinary generated-artifact publisher. A missing gateway base URL is a
  // typed cdn_grant_not_configured failure only when CDN minting is attempted.
  const cdn = loadCdnConfig(env);
  const artifactQuota = createStorageQuotaRepos(db);
  const artifactGrantFactory = createHttpArtifactGrantFactory({
    baseUrl: cfg.gatewayInternalUrl,
    secret: cdn?.grantInternalSecret ?? cfg.internalApiSecret,
  });

  // ---- W8: cloud image generation/editing tools --------------------------
  // Host-side tools call mint's signed internal image routes. The worker
  // never hands a provider key or the model pool to the sandbox. The
  // capability response carries the USER'S plan quota, so the cache is
  // per-uid (bounded) rather than global; failures are never cached.
  const imageClient = createInternalImageClient({
    baseUrl: cfg.internalMintUrl,
    secret: cfg.internalApiSecret,
  });
  const imageCapabilitiesCache = new Map<string, { at: number; value: ImageCapabilities }>();
  const IMAGE_CAPABILITIES_TTL_MS = 300_000;
  const IMAGE_CAPABILITIES_CACHE_MAX = 1_000;
  const imageTooling: ImageTooling = {
    async capabilities(userId) {
      const now = Date.now();
      const cached = imageCapabilitiesCache.get(userId);
      if (cached !== undefined && now - cached.at < IMAGE_CAPABILITIES_TTL_MS) {
        return cached.value;
      }
      const value = await fetchImageCapabilities(imageClient, userId);
      if (value !== null) {
        imageCapabilitiesCache.set(userId, { at: now, value });
        if (imageCapabilitiesCache.size > IMAGE_CAPABILITIES_CACHE_MAX) {
          // Map preserves insertion order: drop the oldest entry.
          const oldest = imageCapabilitiesCache.keys().next().value;
          if (oldest !== undefined) imageCapabilitiesCache.delete(oldest);
        }
      }
      return value;
    },
    createTools: (o) =>
      createImageTools({
        call: imageClient,
        capabilities: o.capabilities,
        notifier,
        ...(o.visionGuard === undefined ? {} : { visionGuard: o.visionGuard }),
        publishArtifact: async (input) => {
          const record = await registerArtifact(
            {
              db,
              events,
              storage,
              workspaceObjects: workspaceObjectsRepo,
              eventMirror: eventMirrorRepo,
              quota: artifactQuota,
              grantFactory: artifactGrantFactory,
              assertProjectFileCapacity: projectFileCapacity,
              ...(cdn !== null ? { cdn } : {}),
            },
            {
              userId: input.userId,
              sessionId: input.sessionId,
              name: input.name,
              contentType: input.contentType,
              content: input.content,
            },
          );
          return {
            id: record.id,
            url: record.url,
            expiresAt: record.expiresAt,
            sizeBytes: record.sizeBytes,
            contentType: record.contentType,
          };
        },
      }),
  };

  // ---- P2 Task 12: the SandboxManager chain (pinned composition order). ----
  // Every step fails LOUDLY at boot: a worker without a rootfs must never run
  // (the systemd unit is ordered after the rootfs install — Task 16), and a
  // half-booted cgroup tree is worse than refusing to start. main() stays
  // composition-root-thin on purpose (P1 convention): Task 14's e2e exercises
  // this wiring end to end.
  // Run concurrency and STEP concurrency are different budgets (owner
  // directive 2026-10-18). A run spends most of its life streaming model
  // tokens — async I/O, no CPU, a couple of MB — so thousands may be in
  // flight. The expensive part is the brief local step (spawn a jailed
  // process, read/write a file), and THAT is what the box must bound. One
  // limiter is shared by every port instance so the bound is per-box, not
  // per-run.
  const toolStepLimit = (() => {
    const raw = env.OVID_MAX_CONCURRENT_TOOL_STEPS;
    if (raw === undefined || raw.trim() === "") return 200;
    const parsed = Number(raw);
    if (!Number.isInteger(parsed) || parsed < 1) {
      throw new Error(
        `OVID_MAX_CONCURRENT_TOOL_STEPS must be a positive integer, got: ${raw}`,
      );
    }
    return parsed;
  })();
  const stepLimit = createStepLimiter(toolStepLimit);

  const sandboxConfig = loadSandboxConfig(env);
  // The storage contract takes a HydrateDbLike handle; the canonical quota
  // reader takes the worker's Db/DbOrTx. One adapter keeps every call site on
  // the single real implementation.
  const projectFileCapacity: ArtifactProjectCapacity = (capacityDb, userId, sessionId, additional) =>
    assertSessionFileCapacity(capacityDb as unknown as DbOrTx, userId, sessionId, additional);

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

  const studioGit = createStudioGitService({
    manager,
    masterKey: studioMasterKey,
    listServers: (userId) => mcpServersRepo.list(db, userId),
    allowedHosts: parseStudioGitAllowedHosts(env.OVID_GIT_ALLOWED_HOSTS),
  });

  // 0041 is an explicit deployment gate, never an implicit migration. Routes,
  // hibernation cleanup and the preview sweeper all share this one manager; an
  // absent table disables only previews and leaves the rest of the worker up.
  const previews = (await studioPreviewTableExists(db))
    ? createStudioPreviewManager({
        store: createStudioPreviewStore(createStudioPreviewPostgresStore(db)),
        manager,
        binding: new StudioRunBinding(db),
        redact: createSecretRedactor().text,
        // A process-random epoch would orphan every cgroup recovery row on
        // restart. Configuration may distinguish hosts; hostname is stable.
        workerEpoch: env.OVID_WORKER_EPOCH?.trim() || hostname(),
        processes: createJailedStudioPreviewProcessRunner({
          manager,
          cgroups,
          launcher,
          config: sandboxConfig,
          rootfs: rootfs.path,
        }),
      })
    : null;
  if (previews === null) {
    console.warn(
      "[worker] Studio previews disabled — studio_previews is absent (apply migration 0041 explicitly)",
    );
  }

  // P3 Task 16: the production processor is the FULL engine. Egress is the
  // SSRF-guarded fetch at every construction site (T5-I1 / M-4): model
  // transports and the GitHub REST port alike. No raw-fetch default remains
  // in the worker's production path. Hoisted above the MCP runtime so the
  // curated fetch/REST/GitHub handlers share the SAME guarded egress.
  const egress = createFetchEgressPolicy(createSsrfGuard());

  // ---- P5 Task 16: the MCP runtime (router + catalog + installer). --------
  // The sandbox seam is the ONLY P2 → @ovid/mcp adaptation point; passing the
  // already-composed manager keeps one cgroup/rootfs boot per worker. The
  // runtime is optional only when OVID_MASTER_KEY is absent (it cannot seal
  // MCP credentials without it); production sets the key (deploy env).
  const mcpSandbox = createSandboxSeam({
    manager,
    tierFor: async (userId) =>
      (await users.getTier(db, userId)) === "free" ? "free" : "pro",
  });
  const mcpRuntime =
    cfg.masterKey === null
      ? null
      : createMcpRuntime({
          db,
          redisQ,
          masterKey: cfg.masterKey,
          sandbox: mcpSandbox,
          fetchImpl: egress,
          // M6: thread the configured token into plugin-source resolution
          // (the resolver's process.env fallback misses an explicit `env`).
          githubToken: cfg.githubToken ?? undefined,
        });
  if (mcpRuntime === null) {
    console.warn(
      "[worker] OVID_MASTER_KEY is not set — MCP servers/plugins are disabled " +
        "(curated fetch/REST tools are unavailable in this process)",
    );
  }

  // ---- P5 Task 14: the plugin-installs consumer. --------------------------
  // Wired to the SAME installer the MCP runtime uses: a second
  // createPluginInstaller() would build a second ContributionRegistry, and
  // installs would register into state the router never reads. The runtime
  // is null only without OVID_MASTER_KEY (the installer needs the envelope
  // crypto to seal plugin credentials), so skip the consumer in that mode
  // rather than start a worker whose every job would fail.
  let pluginInstallsWorker: ReturnType<typeof createPluginInstallsWorker> | null =
    null;
  if (mcpRuntime === null) {
    console.warn(
      "[worker] plugin-installs worker not started — OVID_MASTER_KEY is not set",
    );
  } else {
    // MEDIUM-2: the contribution registry is in-memory; rebuild it from the
    // persisted active/degraded rows so a restart does not take every
    // installed plugin dark until each user reinstalls.
    const rehydrated = await mcpRuntime.installer.rehydrate();
    console.log(`[worker] rehydrated ${rehydrated} installed plugin(s)`);

    const processPluginInstall = createPluginInstallProcessor({
      db,
      installer: mcpRuntime.installer,
      // HIGH-3: gateway-enqueued jobs carry a provisional id; the worker
      // resolves the untrusted source and adopts the row onto the canonical
      // id. The resolver is the same SSRF-guarded instance the installer
      // uses.
      resolver: mcpRuntime.resolver,
    });
    pluginInstallsWorker = createPluginInstallsWorker(
      { url: cfg.redisQUrl },
      processPluginInstall,
    );
    pluginInstallsWorker.on("error", (err) => {
      console.error("[worker] plugin-installs worker error", err);
    });
    console.log("[worker] consuming plugin-installs");
  }

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
  // Vision capability catalog (owner directive 2026-10-18): a cached read of
  // LiteLLM's model metadata, consulted only when a run carries images. The
  // worker already holds the master key for its own model calls.
  const modelCatalogReader = createModelCatalogReader({
    baseUrl: cfg.litellmBaseUrl,
    masterKey: env.OVID_LITELLM_MASTER_KEY ?? "",
  });

  const browserEngineCfg = loadBrowserEngineConfig(env);
  const browserPersistence =
    cfg.browserStateDir !== null && cfg.masterKey !== null
      ? createStorageStatePersistence(createLocalDiskBrowserStateStore(cfg.browserStateDir), cfg.masterKey)
      : null;
  const browser = await createBrowserEngine({
    cfg: browserEngineCfg,
    redisFactory: () => new Redis(cfg.redisQUrl),
    persistence: browserPersistence,
    // P2's session seam: allocates the numeric sandbox uid and creates
    // `{root}/{uid}/sessions/{sessionId}`. Browser artifacts live in this
    // per-session sibling of the agent workspace (the agent itself runs in
    // `{root}/{uid}/workspace` — see the P7 block below).
    workspaceDir: (userId: string, sessionId: string) =>
      manager.workspaceDir(userId, sessionId),
    // Wave 6 W4: owner-scoped credentials + the workspace/Artifact Vault
    // bridge. Both are server-side only; the model never sees a secret.
    credentials: createBrowserCredentialsPort({
      db,
      crypto: cfg.masterKey !== null ? createEnvelopeCrypto(cfg.masterKey) : null,
    }),
    artifactVault: createBrowserArtifactVaultPort({
      db,
      storage,
      events,
      workspaceObjects: workspaceObjectsRepo,
      eventMirror: eventMirrorRepo,
      workspaceDir: (userId: string, sessionId: string) =>
        manager.workspaceDir(userId, sessionId),
      quota: artifactQuota,
      grantFactory: artifactGrantFactory,
      assertProjectFileCapacity: projectFileCapacity,
      ...(cdn !== null ? { cdn } : {}),
    }),
  });

  const browserLeases = createUserBrowserLeases(browser);

  // ---- P7 Task 8/9/10: state-hydrator engines + internal file service. ----
  // workspacesRoot is P2's resolved root (OVID_WORKSPACES_ROOT,
  // /workspaces/users by default): P7 MUST use the same root or the engines
  // and the SandboxManager would disagree about where a session lives.
  const workspacesRoot = sandboxConfig.workspacesRoot;
  // C1: ONE userId → numeric-sandbox-uid resolver for EVERY P7 caller. P2's
  // idempotent allocator is the same function the SandboxManager uses, so the
  // engines now target `{root}/{uid}/workspace` — the directory the agent
  // actually runs in (P2's SandboxHandle.workspaceDir), not a sibling and not
  // a raw Firebase userId path segment.
  //
  // Memoized: allocateSandboxUid consumes a sequence value on every call
  // (idempotent but not free), and the file service resolves on every
  // request. sandbox_uid is immutable once assigned, so a process-local cache
  // is safe (P2's manager keeps the same cache).
  const uidByUser = new Map<string, number>();
  const sandboxUid = async (userId: string): Promise<number> => {
    const cached = uidByUser.get(userId);
    if (cached !== undefined) return cached;
    const uid = await users.allocateSandboxUid(db, userId);
    uidByUser.set(userId, uid);
    return uid;
  };
  // C3: the authoritative SandboxEviction seam built from P2's landed
  // manager surface (destroy = kill leaves, leave data). Enumeration is
  // disk-authoritative over the known userId/uid/sessionId triples; a
  // handle-only list would close every idle warm row on the first sweep.
  const sandboxEviction = createSandboxManagerEviction({
    workspacesRoot,
    manager,
    listKnownSessions: async () => {
      const rows = (await db.$client.unsafe(
        `SELECT u.uid AS user_id, u.sandbox_uid AS uid, s.id AS session_id
           FROM users u
           JOIN sessions s ON s.user_id = u.uid
          WHERE u.sandbox_uid IS NOT NULL`,
      )) as Array<{ user_id: string; uid: number | string; session_id: string }>;
      return rows.map((r) => ({
        userId: r.user_id,
        uid: r.uid,
        sessionId: r.session_id,
      }));
    },
  });
  const hibernateDeps: HibernateDeps = {
    db,
    events,
    storage,
    workspacesRoot,
    sandboxUid,
    sandbox: sandboxEviction,
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
    sandboxUid,
    activity,
    fileManifests: fileManifestsRepo,
    // Cross-session guard's runs half (liveSessionGuard): the wipe-before-
    // extract must not destroy the per-user workspace a sibling run uses.
    runs: runsRepo,
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
  const hibernateWorker = createHibernateWorker({ url: cfg.redisQUrl }, async (job) => {
    const input = hibernateJobSchema.parse(job.data);
    // Stop and durably terminalize previews BEFORE archive/eviction can remove
    // their cwd/logs. A cleanup error rejects the job for BullMQ retry.
    if (previews !== null) {
      await previews.stopSession({
        userId: input.userId,
        sessionId: input.sessionId,
        reason: "hibernate",
      });
    }
    return hibernateWorkspace(hibernateDeps, input);
  });
  hibernateWorker.on("error", (err) => {
    console.error("[worker] hibernate worker error", err);
  });
  const hydrateWorker = createHydrateWorker({ url: cfg.redisQUrl }, async (job) =>
    hydrateWorkspace(hydrateDeps, hydrateJobSchema.parse(job.data)),
  );
  hydrateWorker.on("error", (err) => {
    console.error("[worker] hydrate worker error", err);
  });

  // W12 CDN/grant dependencies were composed above and are shared by every
  // ordinary artifact publisher; absent CDN retains the short-presign path.

  // Internal HTTP: container network only (never a host-published port).
  const fileService = buildFileService({
    db,
    events,
    storage,
    workspacesRoot,
    sandboxUid,
    activity,
    internalToken: cfg.internalToken,
    studioGit,
    connectionHealthInvocations: mcpRuntime?.connectionHealthInvocations,
    inlineMaxBytes: cfg.inlineMaxBytes,
    ...(previews !== null ? { studioPreviews: previews } : {}),
    port: cfg.workerFilePort,
    host: "0.0.0.0",
    fileManifests: fileManifestsRepo,
    runs: runsRepo,
    eventMirror: eventMirrorRepo,
    workspaceObjects: workspaceObjectsRepo,
    quota: artifactQuota,
    grantFactory: artifactGrantFactory,
    assertProjectFileCapacity: projectFileCapacity,
    ...(cdn !== null ? { cdn } : {}),
  });
  await fileService.listen({ port: cfg.workerFilePort, host: "0.0.0.0" });
  console.log(`[worker] internal file service listening on :${cfg.workerFilePort}`);

  // P7 Task 11: the run hook — hydrate before any tool touches the
  // workspace. T9-review I3: pass the repo so awaitWarm does not need the
  const previewSweeper = previews === null ? null : startStudioPreviewSweeper(previews);
  await previewSweeper?.boot;

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


  // P3 Task 16: the production processor is the FULL engine. Egress (the
  // SSRF-guarded fetch) was hoisted above so the MCP runtime shares it.
  const github =
    cfg.githubToken !== null
      ? createGitHubApiPort({ token: cfg.githubToken, egress })
      : null;
  const modelCallQuota = new RunQuotaService(db);
  const processor = createProductionAgentRunProcessor({
    db,
    events,
    quota: modelCallQuota,
    keys: createProductionKeyResolver({
      db,
      redisMint,
      masterKey: cfg.masterKey,
      internalMintUrl: cfg.internalMintUrl,
      internalApiSecret: cfg.internalApiSecret,
      litellmBaseUrl: cfg.litellmBaseUrl,
    }),
    redisQ,
    // P2's manager adapted onto the canonical SandboxPort (Task 9). The
    // provider egress inside the processor allowlists this configured
    // LiteLLM origin (which is loopback in production) — user URLs stay
    // fully guarded.
    sandbox: createSandboxPort(manager, { stepLimit }),
    // Review I2: one port per tier so the workspace quota project matches
    // the user's plan (free 500 MB / pro 2048 MB), and the P2 handle the
    // adapted six-tool roster needs is attached with the SAME tier.
    sandboxForTier: (tier) => createSandboxPort(manager, { tier, stepLimit }),
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
    // P4 Task 10 / T10-review ruling: the P3-T12 approval seam. The hook's
    // onRequested push runs BEFORE the 120 s unattended default-deny clock
    // (the gate invokes it before bridge.ask) and onTimeout ledgers the
    // auto-denial on the occurrence (Task 7's contract). Both are forwarded
    // by the processor for unattended runs only.
    unattendedApprovalHook: createUnattendedApprovalHook({ db, notifier }),
    // P4 Task 13: the agent schedule tools enter P3's roster through the
    // additive FullRunDeps.extraTools seam (adapted beside P2's six).
    extraTools: toCoreTools(createScheduleTools({ db, system })),
    // P6 browser tools (owner directive 2026-10-18): the engine has always
    // been composed above, but nothing dispatched its tools — the agent could
    // not browse at all. Registered unconditionally: the browser engine is a
    // required part of the worker composition, not an MCP-dependent extra.
    // Vision gate (owner directive 2026-10-18): a run carrying images asks
    // the model catalog whether the selected model can see them, and pushes
    // the refusal when it cannot. The catalog read is lazy — only image runs
    // pay for it.
    notifier,
    modelCatalog: modelCatalogReader,
    /**
     * A detached subagent finished after its parent's turn ended. The parent
     * must still learn about it, so give it a turn: the report goes in as a
     * `system` row (agent context, never a chat bubble), and the run's prompt
     * is the same text. The loop only rewrites a TRAILING USER row, so a system
     * row is left exactly as written and the model reads it as context.
     */
    wakeParent: async ({ sessionId, userId, text, actorUserId, source, provenance, modelContext }) => {
      const row = await messagesRepo.append(db, {
        sessionId,
        role: "system",
        content: text,
      });
      const run = await runsRepo.create(db, {
        sessionId,
        promptMessageId: row.id,
      });
      await queues.agentRuns.add(
        AGENT_RUN_JOB_NAME,
        {
          runId: run.id,
          sessionId,
          userId,
          prompt: text,
          actorUserId: actorUserId ?? userId,
          source: source ?? "parent_wake",
          provenance: provenance ?? "server",
          ...(modelContext !== undefined ? { modelContext } : {}),
        },
        { jobId: run.id },
      );
    },
    // W8: generate_image / edit_image (host-side; signed internal routes).
    images: imageTooling,
    // Wave 5 (R2): ONE browser per user, shared across sessions — the leases
    // keep a run's end from closing a browser another run (or a live viewer)
    // still uses.
    browserTools: adaptBrowserTools(browser.tools, browserLeases),
    browserReleaseSession: (_sessionId: string, userId: string, runId: string) =>
      browserLeases.releaseRun(userId, runId),
    // P5 Task 11 I4: kill the run's lazily spawned per-run MCP stdio/legacy
    // SSE connections when the run ends. (connectForRun is unnecessary here:
    // the first callTool spawns under its own run context and this releases
    // it; eager connect would spawn servers the run never uses.)
    ...(mcpRuntime !== null
      ? {
          mcp: {
            activation: mcpRuntime.activation,
            router: mcpRuntime.router,
          },
          mcpReleaseRun: (
            uid: string,
            runCtx: { sessionId: string; runId: string },
          ) => mcpRuntime.router.releaseRun(uid, runCtx),
        }
      : {}),
  }, storage);

  // ---- P4 Task 10: the scheduler loop + schedules-mirror consumer. --------
  // Boot resync FIRST: rebuild the delayed mirror from Postgres (the row is
  // authoritative) before any tick can run. Deterministic jobIds make a
  // re-add after a crash a no-op.
  const mirrored = await resyncScheduleMirror({ db, queues });
  console.log(`[scheduler] mirror resync: ${mirrored} delayed job(s)`);

  // Settle-then-tick every OVID_SCHEDULER_TICK_MS (overlap-guarded; .unref()).
  const schedulerLoop = startSchedulerLoop(
    { db, queues, events, system, notifier },
    { intervalMs: cfg.schedulerTickMs },
  );
  // The mirror consumer shares the production queue key layout (no prefix:
  // BullMQ's default "bull", matching createQueues above — a deploy contract).
  const fireWorker = createScheduleFireWorker(
    { url: cfg.redisQUrl },
    createScheduleFireProcessor({ db, queues, system }),
  );
  fireWorker.on("error", (err) => {
    console.error("[worker] schedules worker error", err);
  });
  // P4 Task 13: the agent schedule tools are registered with the P3 roster
  // through FullRunDeps.extraTools above; the approval timeoutPolicy half of
  // the P3 seam is wired via unattendedApprovalHook.
  console.log("[scheduler] agent schedule tools registered (4)");

  // Connection OPTIONS OBJECT — a bare URL string silently spreads into
  // garbage opts and hangs (Task 7 lesson, pinned by its health test).
  // Concurrency: the queue default is 8, but the admission gate allows
  // OVID_MAX_ACTIVE_SANDBOXES runs at once. Leaving it at 8 means the box
  // executes a third of what it admits, and the rest waits in Redis — the
  // first full100 run measured exactly that (8 active, ~1800 queued). The
  // knob is explicit so an operator can still cap it below admission.
  const runConcurrency = (() => {
    const raw = env.OVID_AGENT_RUN_CONCURRENCY;
    if (raw === undefined || raw.trim() === "") return undefined;
    const parsed = Number(raw);
    if (!Number.isInteger(parsed) || parsed < 1) {
      throw new Error(
        `OVID_AGENT_RUN_CONCURRENCY must be a positive integer, got: ${raw}`,
      );
    }
    return parsed;
  })();
  const worker = createAgentRunsWorker(
    { url: cfg.redisQUrl },
    processor,
    runConcurrency === undefined ? {} : { concurrency: runConcurrency },
  );
  worker.on("error", (err) => {
    console.error("[worker] bullmq worker error", err);
  });
  console.log(
    `[worker] consuming agent-runs (env=${cfg.nodeEnv}, model=${cfg.defaultModel}, litellm=${cfg.litellmBaseUrl})`,
  );

  // Stale-run sweeper (fix-round ruling): with attempts:1, failed jobs are
  // never redelivered and a mid-run crash strands the run row in 'running'
  // forever — the sweeper terminalizes those (run_failed {code:"run_lost"}).
  // A worker death mid-C1-wait strands 'queued' rows the same way (wave-2
  // fix): those sweep as run_queue_wait_timeout. Once at boot, then every
  // 60 s; sweep errors are logged, never fatal (the next pass retries), and
  // the interval must never hold the process open.
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

  // Audit P2 (mcp_oauth_flows retention): the missing sweep the schema's
  // mcp_oauth_flows_expires_at_idx was created for. Exact stale-run interval
  // shape: once at boot ("boot" label), every 24 h after ("interval"),
  // errors logged never fatal, .unref() so the process can exit, cleared in
  // shutdown(). The query is index-served and cheap enough to skip entirely
  // when it deletes nothing.
  const sweepOauthFlows = async (label: string): Promise<void> => {
    try {
      const deleted = await mcpOauthFlows.deleteExpired(
        db,
        new Date(Date.now() - OAUTH_FLOW_SWEEP_GRACE_MS),
      );
      if (deleted > 0) {
        console.log(`[worker] oauth-flow sweep (${label}): deleted ${deleted} expired flow(s)`);
      }
    } catch (err) {
      console.error(`[worker] oauth-flow sweep (${label}) failed`, err);
    }
  };
  await sweepOauthFlows("boot");
  const oauthFlowSweeper = setInterval(() => {
    void sweepOauthFlows("interval");
  }, OAUTH_FLOW_SWEEP_INTERVAL_MS);
  oauthFlowSweeper.unref();

  // ---- P9 Task 15: the durable account-deletion sweeper. ------------------
  // A completed deletion request survives a process restart because the
  // sweeper re-reads `account_deletions.due(now)` every pass (boot included)
  // and the lifecycle checkpoints retry intent before effects. Opt-in via
  // OVID_ACCOUNT_FIREBASE_APP_IDS (the App Check allowlist) — without it the
  // adapter cannot verify disabled-token recovery, so the sweeper stays off.
  const accountAppIds = new Set(
    (env.OVID_ACCOUNT_FIREBASE_APP_IDS ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter((value) => value !== ""),
  );
  let accountSweeper: { stop(): Promise<void> } | null = null;
  let accountKeyAdmin: ReturnType<typeof createHttpKeyAdmin> | null = null;
  if (accountAppIds.size > 0) {
    // P9 final review H2: the real R2 ListObjectsV2 + DeleteObjects deleter.
    // Without R2 configured the no-op seam remains, but it is called out
    // loudly: deletion must not be enabled in production without it.
    const r2Deleter = createR2PrefixDeleterFromEnv(env);
    if (r2Deleter === null) {
      console.warn(
        "[account] deletion is enabled but OVID_R2_* is not configured — " +
          "workspace/browser objects under users/{uid}/ will NOT be deleted (H2)",
      );
    }
    const firebaseApp = getApps()[0] ?? initializeApp();
    const admin = createFirebaseAdmin(firebaseApp, accountAppIds);
    const deletionStore = createPostgresDeletionStore(db);
    accountKeyAdmin = createHttpKeyAdmin(
      cfg.litellmBaseUrl,
      env.OVID_LITELLM_MASTER_KEY?.trim() ?? "",
    );
    const lifecycle = createLifecycle({
      store: deletionStore,
      admin,
      data: createCloudCleanup({
        db,
        redisDb2: redisMint,
        redisQueue: redisQ,
        litellm: accountKeyAdmin,
        r2: r2Deleter ?? createNoopR2Deleter(),
        studioPreviews: createStudioPreviewAccountCleanup({ db, previews }),
        images: {
          deleteAccount: async (uid) => {
            await db.transaction(async (tx) => {
              await imagesRepo.insertDeleted(tx, uid, Math.floor(Date.now() / 1000));
              await imagesRepo.clearAccount(tx, uid);
            });
          },
        },
        shares: { deleteAccount: (uid) => sharesRepo.deleteAccount(db, uid) },
        byok: { deleteAccount: (uid) => byokKeysRepo.deleteAccount(db, uid) },
      }),
    });
    accountSweeper = startAccountDeletionSweeper({ lifecycle, store: deletionStore });
    console.log("[account] deletion sweeper started");
    if (env.OVID_LITELLM_MASTER_KEY?.trim() === undefined || env.OVID_LITELLM_MASTER_KEY.trim() === "") {
      console.warn(
        "[account] no OVID_LITELLM_MASTER_KEY — key block/delete will fail and retry",
      );
    }
  } else {
    console.log(
      "[account] deletion sweeper disabled — set OVID_ACCOUNT_FIREBASE_APP_IDS to enable it",
    );
  }

  let shuttingDown: Promise<void> | null = null;
  const shutdown = (): Promise<void> => {
    shuttingDown ??= (async () => {
      const previewSweepStopped = previewSweeper?.stop() ?? null;
      clearInterval(sweeper);
      clearInterval(warmSweeper);
      clearInterval(oauthFlowSweeper);
      // P9 Task 15: stop the account sweeper before any connection closes —
      // stop() awaits the in-flight finalize pass (durable checkpoints mean a
      // forced kill is also safe).
      try {
        await accountSweeper?.stop();
      } finally {
        // stop() drains every user of this adapter. close() releases only its
        // lazy pool and still runs if that drain reports a failure.
        await accountKeyAdmin?.close?.();
      }
      // P4 Task 10: stop the scheduler loop and drain the mirror consumer
      // BEFORE the agent-runs worker drains (a mirror job only enqueues).
      schedulerLoop.stop();
      await fireWorker.close();
      // P2 Task 13 pin: the pty bridge stops FIRST (no new ctl mid-teardown),
      // then the sandbox manager — manager.close() kills every live pty leaf,
      // and each pty's onExit publishes its `exit` + HDELs its registry key.
      await stopPtyBridge();
      // P5 Task 14: drain in-flight install transactions BEFORE the runtime
      // closes the system bus / router they report through.
      await pluginInstallsWorker?.close();
      // P5 Task 16: stop the MCP router (closes live MCP clients and the
      // system bus; pending approvals deny) BEFORE the sandbox manager kills
      // the jailed stdio processes they ride on.
      await mcpRuntime?.shutdown();
      // P2 Task 12 pin: manager.close() BEFORE the drain — sandbox envs (their
      // cgroup trees, live leaves and admission slots) tear down first.
      // P6 Task 14 pin: browser state is flushed BEFORE the run worker drains
      // — close() releases every live session (capture → persistence.flush →
      // context close) so logins survive the restart, then tears down the
      // bridge, research and pool in order.
      // Stop new internal requests, drain the preview sweep, and confirm every
      // owned preview terminal BEFORE generic sandbox teardown. DB remains open
      // for those durable CAS writes; fileService.close() has no later caller.
      await closeStudioPreviewResources({
        previewSweepStopped,
        fileService,
        previews,
        closeManager: () => manager.close(),
      });
      await browser.close();
      // Drains in-flight jobs and stops fetching new ones (force=false).
      await worker.close();
      // P7 Task 11: stop storage consumers before their producer queues.
      await hibernateWorker.close();
      await hydrateWorker.close();
      await queues.agentRuns.close();
      await queues.hibernate.close();
      await queues.hydrate.close();
      await queues.schedules.close();
      await queues.pluginInstalls?.close();
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
