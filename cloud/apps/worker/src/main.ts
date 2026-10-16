import { pathToFileURL } from "node:url";
import { Redis } from "ioredis";
import { createDb } from "@ovid/db";
import { createRedisEventLog } from "@ovid/events";
import { createAgentRunsWorker } from "@ovid/queue";
import type { KeyProvider } from "@ovid/shared";
import { createOpenAiTransport } from "./liteLlm.js";
import { createAgentRunProcessor } from "./runProcessor.js";

export interface WorkerEnv {
  nodeEnv: string;
  databaseUrl: string;
  redisQUrl: string;
  redisMintUrl: string;
  litellmBaseUrl: string;
  defaultModel: string;
}

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
  return {
    nodeEnv: raw.NODE_ENV?.trim() || "development",
    databaseUrl: required("DATABASE_URL"),
    redisQUrl: required("REDIS_Q_URL"),
    redisMintUrl: required("REDIS_MINT_URL"),
    litellmBaseUrl: required("OVID_LITELLM_BASE"),
    defaultModel: required("OVID_DEFAULT_MODEL"),
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

  const processor = createAgentRunProcessor({
    db,
    events: createRedisEventLog(redisQ),
    keys: createMintRedisKeyProvider(redisMint),
    transport: createOpenAiTransport(),
    litellmBaseUrl: cfg.litellmBaseUrl,
    defaultModel: cfg.defaultModel,
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

  let shuttingDown: Promise<void> | null = null;
  const shutdown = (): Promise<void> => {
    shuttingDown ??= (async () => {
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
