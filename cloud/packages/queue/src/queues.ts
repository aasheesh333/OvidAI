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

/** Queue name — P7 statehydrator: warm → cold workspace packing. */
export const HIBERNATE = "hibernate";

/** Queue name — P7 statehydrator: cold → warm workspace extraction. */
export const HYDRATE = "hydrate";

/** Job name callers pass to `hibernate.add(HIBERNATE_JOB_NAME, payload, …)`. */
export const HIBERNATE_JOB_NAME = "hibernate-workspace";

/** Job name callers pass to `hydrate.add(HYDRATE_JOB_NAME, payload, …)`. */
export const HYDRATE_JOB_NAME = "hydrate-workspace";

export interface AgentRunJob {
  runId: string;
  sessionId: string;
  userId: string;
  prompt: string;
  /**
   * P2 Task 12 (additive, optional — old payloads still parse): the caller's
   * users.tier at enqueue time; the worker passes it to
   * SandboxManager.attach so the workspace quota project matches the user's
   * tier. Raw DB tier text ("free" / anything-else-is-"pro").
   */
  tier?: string;
  /**
   * P8 Task 3 (additive, optional): attachment ids the message was sent with.
   * The gateway validated every id against the session's attachment rows
   * BEFORE enqueueing; the processor materializes each into
   * uploads/{sanitizedName} inside the sandbox workspace before the first
   * provider call. Absent/empty = no attachments.
   */
  attachmentIds?: string[];
  /**
   * P3 Task 16 (additive, optional — old payloads still parse): the run has
   * no attending user, so approval cards may not wait forever; the gate's
   * timeout applies to every request kind.
   */
  unattended?: boolean;
  /** P3 Task 16 (additive): the caller's autonomy policy (carried, not gated). */
  autonomy?: "safe" | "auto";
  /** P3 Task 16 (additive): the run's access mode (ruling R4 — job wins over session state). */
  mode?: "safe" | "auto" | "drive" | "studio";
}

// Wire-format ids are plain nonempty strings (same convention as
// @ovid/shared's sessionEventSchema); UUIDv7 shape is a DB-boundary concern.
export const agentRunJobSchema: z.ZodType<AgentRunJob> = z.object({
  runId: z.string().min(1),
  sessionId: z.string().min(1),
  userId: z.string().min(1),
  prompt: z.string().min(1),
  tier: z.string().min(1).optional(),
  attachmentIds: z.array(z.string().min(1)).optional(),
  unattended: z.boolean().optional(),
  autonomy: z.enum(["safe", "auto"]).optional(),
  mode: z.enum(["safe", "auto", "drive", "studio"]).optional(),
});

/** Why a workspace is being hibernated (warm → cold). */
export type HibernateReason = "idle" | "pressure" | "manual";

/** Why a workspace is being hydrated (cold → warm). */
export type HydrateReason = "run" | "open" | "write" | "manual";

export interface HibernateJob {
  sessionId: string;
  userId: string;
  /**
   * Row generation + 1: the hibernate engine (Task 8) only honors the claim
   * while the file_manifests row still sits at `generation - 1`, so stale
   * re-deliveries skip with `stale_generation` instead of double-packing.
   * Floor 1 — a generation-0 row has never hibernated.
   */
  generation: number;
  reason: HibernateReason;
}

export interface HydrateJob {
  sessionId: string;
  userId: string;
  /**
   * The cold row's generation to restore; 0 is valid (cold session that has
   * no archive yet — hydrate materializes an empty workspace).
   */
  generation: number;
  reason: HydrateReason;
}

// Wire-format ids are plain nonempty strings (same convention as
// agentRunJobSchema); the DB boundary owns UUID shapes.
export const hibernateJobSchema: z.ZodType<HibernateJob> = z.object({
  sessionId: z.string().min(1),
  userId: z.string().min(1),
  generation: z.number().int().min(1),
  reason: z.enum(["idle", "pressure", "manual"]),
});

export const hydrateJobSchema: z.ZodType<HydrateJob> = z.object({
  sessionId: z.string().min(1),
  userId: z.string().min(1),
  generation: z.number().int().min(0),
  reason: z.enum(["run", "open", "write", "manual"]),
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
 * Package-level default job options for the storage queues (hibernate /
 * hydrate) — callers must not drift.
 *
 * Unlike agent-runs (attempts: 1, model-call retries live in the processor),
 * pack/extract jobs are SAFE to retry at the queue layer: every step is
 * idempotent through the generation check (Task 8 skips stale generations)
 * and the `storageJobId` add-side dedupe, and a failed attempt leaves the
 * workspace warm — nothing is destroyed until the verified upload. Three
 * attempts with exponential backoff absorb transient redis/R2 glitches.
 */
export const STORAGE_JOB_DEFAULTS = {
  attempts: 3,
  backoff: { type: "exponential", delay: 5_000 },
} as const;

/**
 * Default worker concurrency for the storage queues: pack and extract are
 * CPU- (zstd) and IO-heavy; two at a time on the 8-core box leaves headroom
 * for the agent-run workers and the sandbox jails.
 */
export const STORAGE_JOB_CONCURRENCY = 2;

/**
 * Idempotent job id for storage jobs — one queue entry per
 * (session, generation): re-adding the same job (crash redelivery, retry
 * from the sweeper) lands on the SAME BullMQ job instead of piling
 * duplicates (spike §9.3 "job id = sid:generation for idempotent retries").
 *
 * RULING (separator deviation from the plan's `${sid}:${gen}` literal):
 * BullMQ (5.81.5) REJECTS custom job ids containing `:` unless they have the
 * exact 3-part repeatable-job shape — "Custom Id cannot contain :" (and
 * BullMQ's own TODO removes the 3-part exception in the next breaking
 * release). Every consumer (T8–T12) treats the id as opaque (add + getJob),
 * so the `~` separator preserves the pinned semantics — same id for the
 * same (session, generation) — with a character BullMQ accepts. The pure
 * format is pinned by test.
 */
export function storageJobId(sessionId: string, generation: number): string {
  return `${sessionId}~${generation}`;
}

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
  /** P7: hibernate jobs (warm → cold). */
  hibernate: Queue<HibernateJob>;
  /** P7: hydrate jobs (cold → warm). */
  hydrate: Queue<HydrateJob>;
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
  // The two storage queues share one construction shape: same prefix
  // threading (P1 discipline — EVERY queue in createQueues scopes with the
  // caller's prefix or none at all) and the storage job defaults.
  const storageQueue = <T>(name: string): Queue<T> =>
    new Queue<T>(name, {
      connection: withBlockingSafeRetries(connection),
      // No prefix key at all when unset → BullMQ default ("bull"):
      // production key layout is unchanged; test suites scope their own
      // keys (see QueuePrefixOptions).
      ...(opts.prefix !== undefined ? { prefix: opts.prefix } : {}),
      defaultJobOptions: { ...STORAGE_JOB_DEFAULTS },
    });

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
    hibernate: storageQueue<HibernateJob>(HIBERNATE),
    hydrate: storageQueue<HydrateJob>(HYDRATE),
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

function createStorageWorker<T>(
  name: string,
  connection: ConnectionOptions,
  processor: Processor<T>,
  opts: { concurrency?: number } & QueuePrefixOptions,
): Worker<T> {
  return new Worker<T>(name, processor, {
    connection: withBlockingSafeRetries(connection),
    // must match the add-side queue's prefix or jobs never meet
    ...(opts.prefix !== undefined ? { prefix: opts.prefix } : {}),
    concurrency: opts.concurrency ?? STORAGE_JOB_CONCURRENCY,
  });
}

/**
 * Worker for the hibernate queue. The opts type widens the brief's
 * `{ concurrency?: number }` with QueuePrefixOptions — the P1 fix wave's
 * prefix discipline is binding for every new queue/worker pair: test suites
 * MUST be able to scope their keys on the shared dev redis (the plan-pinned
 * `{ concurrency }` calls are unaffected).
 */
export function createHibernateWorker(
  connection: ConnectionOptions,
  processor: Processor<HibernateJob>,
  opts: { concurrency?: number } & QueuePrefixOptions = {},
): Worker<HibernateJob> {
  return createStorageWorker<HibernateJob>(
    HIBERNATE,
    connection,
    processor,
    opts,
  );
}

/** Worker for the hydrate queue — see createHibernateWorker. */
export function createHydrateWorker(
  connection: ConnectionOptions,
  processor: Processor<HydrateJob>,
  opts: { concurrency?: number } & QueuePrefixOptions = {},
): Worker<HydrateJob> {
  return createStorageWorker<HydrateJob>(
    HYDRATE,
    connection,
    processor,
    opts,
  );
}
