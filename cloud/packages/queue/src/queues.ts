import { Queue, Worker } from "bullmq";
import type {
  ConnectionOptions,
  Processor,
  RedisOptions,
} from "bullmq";
import { z } from "zod";

/** Queue name — pinned by the plan; `createQueues` offers no override. */
export const AGENT_RUNS = "agent-runs";

/** Job name callers pass to `agentRuns.add(AGENT_RUN_JOB_NAME, payload, …)`. */
export const AGENT_RUN_JOB_NAME = "agent-run";

export interface AgentRunJob {
  runId: string;
  sessionId: string;
  userId: string;
  prompt: string;
}

// Wire-format ids are plain nonempty strings (same convention as
// @ovid/shared's sessionEventSchema); UUIDv7 shape is a DB-boundary concern.
export const agentRunJobSchema: z.ZodType<AgentRunJob> = z.object({
  runId: z.string().min(1),
  sessionId: z.string().min(1),
  userId: z.string().min(1),
  prompt: z.string().min(1),
});

/**
 * Package-level default job options for agent-runs — callers must not drift.
 *
 * Ruling: BullMQ `attempts` is 1. Model-call retries (5 attempts, 3/9/27/60 s
 * backoff, spec §6.1) live INSIDE the Task 9 processor; a second retry layer
 * at the queue level would multiply them (5×5). Crashed workers are covered by
 * stalled-job redelivery (AGENT_RUNS_STALLED_INTERVAL_MS), not by `attempts`.
 *
 * All other add-time options stay the caller's responsibility: `jobId: runId`
 * (idempotent adds) and `priority` (1 = Pro, 2 = Free) — see Task 7.
 */
export const AGENT_RUN_JOB_DEFAULTS = { attempts: 1 } as const;

/** Default worker concurrency for agent-runs. */
export const AGENT_RUNS_DEFAULT_CONCURRENCY = 8;

/**
 * Stalled-job check interval: a worker that dies mid-run stops renewing its
 * lock; after this interval BullMQ moves the stalled job to FAILED — with
 * `attempts: 1` it is NEVER redelivered to a live worker. The stale-run
 * sweeper (apps/worker staleRuns.ts) is the recovery mechanism: it
 * terminalizes the run row the dead job left stranded in 'running'.
 */
export const AGENT_RUNS_STALLED_INTERVAL_MS = 30_000;

/**
 * BullMQ key prefix for a queue/worker pair. `undefined` keeps BullMQ's
 * default ("bull") — production keys unchanged. Test suites pass a distinct
 * prefix (env `OVID_TEST_QUEUE_PREFIX` + suite suffix) so parallel suites on
 * the SHARED dev redis cannot obliterate each other's agent-runs keys:
 * every key the suite creates (`{prefix}:agent-runs:*`) is its own.
 */
export interface QueuePrefixOptions {
  prefix?: string;
}

export interface QueueServices {
  agentRuns: Queue<AgentRunJob>;
}

/**
 * BullMQ requires `maxRetriesPerRequest: null` on its connections: blocking
 * reads (worker job fetch, stalled checks) must never abandon the request —
 * retry policy belongs to the job layer, not the socket layer. Plain option
 * objects get the override applied here; pre-built client instances are
 * caller-owned and passed through untouched (BullMQ itself rejects instances
 * that violate its blocking requirements).
 */
function withBlockingSafeRetries(connection: ConnectionOptions): ConnectionOptions {
  if (typeof (connection as { duplicate?: unknown }).duplicate === "function") {
    return connection;
  }
  return { ...(connection as RedisOptions), maxRetriesPerRequest: null };
}

export function createQueues(
  connection: ConnectionOptions,
  opts: QueuePrefixOptions = {},
): QueueServices {
  return {
    agentRuns: new Queue<AgentRunJob>(
      AGENT_RUNS,
      // No prefix key at all when unset → BullMQ default ("bull"):
      // production key layout is unchanged; test suites scope their own
      // keys (see QueuePrefixOptions).
      {
        connection: withBlockingSafeRetries(connection),
        ...(opts.prefix !== undefined ? { prefix: opts.prefix } : {}),
        // attempts: 1 per the ruling above — the add side (Task 7) and the
        // worker side (Task 9) agree through this single source of truth.
        defaultJobOptions: { ...AGENT_RUN_JOB_DEFAULTS },
      },
    ),
  };
}

export function createAgentRunsWorker(
  connection: ConnectionOptions,
  processor: Processor<AgentRunJob>,
  opts: { concurrency?: number } & QueuePrefixOptions = {},
): Worker<AgentRunJob> {
  return new Worker<AgentRunJob>(
    AGENT_RUNS,
    processor,
    {
      connection: withBlockingSafeRetries(connection),
      // must match the add-side queue's prefix or jobs never meet
      ...(opts.prefix !== undefined ? { prefix: opts.prefix } : {}),
      concurrency: opts.concurrency ?? AGENT_RUNS_DEFAULT_CONCURRENCY,
      stalledInterval: AGENT_RUNS_STALLED_INTERVAL_MS,
    },
  );
}
