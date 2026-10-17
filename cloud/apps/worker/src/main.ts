import { pathToFileURL } from "node:url";
import { Redis } from "ioredis";
import { createDb, users } from "@ovid/db";
import { createRedisEventLog } from "@ovid/events";
import { createAgentRunsWorker } from "@ovid/queue";
import {
  createCgroupManager,
  createRootmapLauncher,
  createSandboxManager,
  createSetuidLauncher,
  loadSandboxConfig,
  resolveRootfs,
  selectQuotaBackend,
} from "@ovid/sandbox";
import type { KeyProvider } from "@ovid/shared";
import { createOpenAiTransport } from "./liteLlm.js";
import { createAgentRunProcessor } from "./runProcessor.js";
import { startWorkerPtyBridge } from "./ptyBridge.js";
import { createToolRegistry } from "./tools/registry.js";
import { sweepStaleRuns } from "./staleRuns.js";

export interface WorkerEnv {
  nodeEnv: string;
  databaseUrl: string;
  redisQUrl: string;
  redisMintUrl: string;
  litellmBaseUrl: string;
  defaultModel: string;
  runStaleMs: number;
  runQueueWaitMs: number;
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

  return {
    nodeEnv: raw.NODE_ENV?.trim() || "development",
    databaseUrl: required("DATABASE_URL"),
    redisQUrl: required("REDIS_Q_URL"),
    redisMintUrl: required("REDIS_MINT_URL"),
    litellmBaseUrl: required("OVID_LITELLM_BASE"),
    defaultModel: required("OVID_DEFAULT_MODEL"),
    runStaleMs,
    runQueueWaitMs,
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

  const processor = createAgentRunProcessor({
    db,
    events,
    keys: createMintRedisKeyProvider(redisMint),
    transport: createOpenAiTransport(),
    litellmBaseUrl: cfg.litellmBaseUrl,
    defaultModel: cfg.defaultModel,
    runQueueWaitMs: cfg.runQueueWaitMs,
    sandbox: manager,
    tools: createToolRegistry(),
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

  let shuttingDown: Promise<void> | null = null;
  const shutdown = (): Promise<void> => {
    shuttingDown ??= (async () => {
      clearInterval(sweeper);
      // P2 Task 13 pin: the pty bridge stops FIRST (no new ctl mid-teardown),
      // then the sandbox manager — manager.close() kills every live pty leaf,
      // and each pty's onExit publishes its `exit` + HDELs its registry key.
      await stopPtyBridge();
      // P2 Task 12 pin: manager.close() BEFORE the drain — sandbox envs (their
      // cgroup trees, live leaves and admission slots) tear down first.
      await manager.close();
      // Drains in-flight jobs and stops fetching new ones (force=false).
      await worker.close();
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
