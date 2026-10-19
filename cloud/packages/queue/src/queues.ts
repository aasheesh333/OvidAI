import { Queue, Worker } from "bullmq";
import type {
  ConnectionOptions,
  Processor,
  RedisOptions,
} from "bullmq";
import { z } from "zod";
import {
  MAX_OUTPUT_TOKENS_CAP,
  pluginSourceInputSchema,
  type PluginSourceInput,
} from "@ovid/shared";

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

/** Queue name — P4 scheduler: delayed mirror of upcoming schedule occurrences. */
export const SCHEDULES = "schedules";

/** Job name callers pass to `schedules.add(SCHEDULE_FIRE_JOB_NAME, payload, …)`. */
export const SCHEDULE_FIRE_JOB_NAME = "schedule-fire";

/** Queue name — P5 plugin install/uninstall transactions. */
export const PLUGIN_INSTALLS = "plugin-installs";

/** Job name callers pass to `pluginInstalls.add(PLUGIN_INSTALL_JOB_NAME, …)`. */
export const PLUGIN_INSTALL_JOB_NAME = "plugin-install";

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
   * The user's max completion tokens (additive, optional — old payloads
   * still parse): the Settings "Max output tokens" pick as the gateway
   * validated it (int 1..MAX_OUTPUT_TOKENS_CAP). The worker maps it onto
   * the engine request's `maxTokens`. Absent = the provider's own default.
   */
  maxOutputTokens?: number;
  /**
   * P9 Task 9 (additive, optional): the BYOK key row this run must use.
   * Present → the worker resolves it through the escrow provider and FAILS
   * the run (key_not_minted) if it cannot be decrypted; absent → the normal
   * LiteLLM/internal-mint path. Old payloads still parse.
   */
  byokKeyId?: string | null;
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
  /**
   * P4 Task 6 (additive, optional — old payloads still parse): the run was
   * fired by the scheduler; ties the agent run back to its schedule row and
   * occurrence so the worker can mark the run and re-arm cold retries with
   * the schedule's own autonomy, not the sender's.
   */
  schedule?: ScheduleRunRef;
}

// Wire-format ids are plain nonempty strings (same convention as
// @ovid/shared's sessionEventSchema); UUIDv7 shape is a DB-boundary concern.
const scheduleRunRefSchema: z.ZodType<ScheduleRunRef> = z.object({
  scheduleId: z.string().min(1),
  scheduleRunId: z.string().min(1),
  autonomy: z.enum(["safe", "auto"]),
});

export const agentRunJobSchema: z.ZodType<AgentRunJob> = z.object({
  runId: z.string().min(1),
  sessionId: z.string().min(1),
  userId: z.string().min(1),
  prompt: z.string().min(1),
  tier: z.string().min(1).optional(),
  attachmentIds: z.array(z.string().min(1)).optional(),
  maxOutputTokens: z.number().int().min(1).max(MAX_OUTPUT_TOKENS_CAP).optional(),
  byokKeyId: z.string().min(1).nullable().optional(),
  unattended: z.boolean().optional(),
  autonomy: z.enum(["safe", "auto"]).optional(),
  mode: z.enum(["safe", "auto", "drive", "studio"]).optional(),
  schedule: scheduleRunRefSchema.optional(),
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
 * P4 Task 6 — one mirrored schedule occurrence. The scheduleService re-arms
 * this job after every state change (add/update/delete/pause); when it fires,
 * the worker checks the schedule row is still pending with this nextRunAt
 * (the row is the source of truth — the queue is only a wake-up mirror, so a
 * stale job that lost the race resolves to "already handled" and skips).
 */
export interface ScheduleFireJob {
  scheduleId: string;
  /** ISO timestamp of the occurrence this mirror was armed for. */
  scheduledFor: string;
}

// Wire-format ids are plain nonempty strings (same convention as
// agentRunJobSchema); the DB boundary owns UUID shapes.
export const scheduleFireJobSchema: z.ZodType<ScheduleFireJob> = z.object({
  scheduleId: z.string().min(1),
  scheduledFor: z.string().min(1),
});

/**
 * P5 Task 14 — one plugin install/uninstall transaction. Pinned
 * member-for-member with `PluginInstallJob` in `@ovid/mcp`
 * (`packages/mcp/src/plugins/install.ts`): `source` is the canonical
 * @ovid/shared source contract, never a second shape.
 *
 * Length caps are the row-write / path-segment bounds (M5): a multi-KB
 * `installId` or `pluginId` would otherwise only fail deep in the sandbox
 * seam (ENAMETOOLONG) or create absurd jail paths.
 */
export interface PluginInstallJob {
  installId: string;
  userId: string;
  pluginId: string;
  mode: "install" | "uninstall";
  source?: PluginSourceInput;
  /** HIGH-3: worker resolves the source identity before installing. */
  needsIdentity?: boolean;
}

export const pluginInstallJobSchema: z.ZodType<PluginInstallJob> = z.object({
  installId: z.string().min(1).max(100),
  userId: z.string().min(1).max(200),
  pluginId: z.string().min(1).max(200),
  mode: z.enum(["install", "uninstall"]),
  source: pluginSourceInputSchema.optional(),
  needsIdentity: z.boolean().optional(),
});

/**
 * Package-level default job options for plugin-installs — callers must not
 * drift. `attempts: 1` mirrors the P1 ruling pattern: the installer owns
 * rollback (registry restore + row restore + staging cleanup), so a queue
 * retry would re-run a rollback against an already-terminal row. A crashed
 * job is never redelivered; the processor terminalizes the row it can, and
 * the gateway's status surface is the recovery signal.
 *
 * HIGH-2 (fix round): BullMQ dedupes on `jobId` for a job key in ANY state,
 * including completed/failed. REST installs use the stable row id as the job
 * id, and `plugins.upsert` keeps that id across reinstalls/upgrades — so
 * without removal the second install returned the retained completed job,
 * the worker never ran, and the row sat `queued` while the old version
 * stayed live. Same lesson (and same remedy) as the storage queues above:
 * dedupe is only needed while a job is waiting/active, so drop the record as
 * soon as it settles.
 */
export const PLUGIN_INSTALL_JOB_DEFAULTS = {
  attempts: 1,
  removeOnComplete: true,
  removeOnFail: true,
} as const;

/**
 * P4 Task 6 — the scheduler's back-reference riding an agent-run job: which
 * schedule fired, which occurrence row it created, and the schedule's own
 * autonomy (stored grants vs read-only projection).
 */
export interface ScheduleRunRef {
  scheduleId: string;
  scheduleRunId: string;
  autonomy: "safe" | "auto";
}

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
  // C2 (fix round 1, LOAD-BEARING): BullMQ dedupes on jobId for a job key in
  // ANY state, including completed/failed. `storageJobId` is stable per
  // (session, generation), so without removal a skipped idle hibernate (or a
  // hydrate that exhausted its attempts) would permanently wedge that
  // generation — including the manual POST hibernate. Dedupe is only needed
  // while a job is waiting/active; drop the record as soon as it settles.
  removeOnComplete: true,
  removeOnFail: true,
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
 * Idempotent job id for schedule mirror jobs — one queue entry per
 * (schedule, occurrence): re-arming the SAME occurrence (schedule update
 * that keeps nextRunAt, a redelivery after a crash) lands on the SAME
 * BullMQ job instead of piling duplicates, so the mirror never double-fires.
 *
 * RULING (separator deviation from the plan's
 * `${scheduleId}:${scheduledForMs}` literal): BullMQ (5.81.5) REJECTS custom
 * job ids containing `:` unless they have the exact 3-part repeatable-job
 * shape — "Custom Id cannot contain :" — the same constraint storageJobId
 * already ruled on. Consumers treat the id as opaque (add + getJob), so `~`
 * preserves the pinned semantics: same id for the same
 * (schedule, occurrence) → idempotent re-adds. The pure format is pinned by
 * test.
 */
export function scheduleMirrorJobId(
  scheduleId: string,
  scheduledForMs: number,
): string {
  return `${scheduleId}~${scheduledForMs}`;
}

/**
 * P4 Task 6 — arm (or re-arm) the mirror job for a schedule's next
 * occurrence. The deterministic jobId makes re-adds idempotent; the delay is
 * the distance from `now` to `nextRunAt`, clamped to ≥1 ms because BullMQ
 * does not accept a non-positive delay (an overdue occurrence must fire
 * immediately, not throw).
 */
export async function addScheduleMirrorJob(
  queues: QueueServices,
  scheduleId: string,
  nextRunAt: Date,
  now: Date,
): Promise<void> {
  await queues.schedules.add(
    SCHEDULE_FIRE_JOB_NAME,
    { scheduleId, scheduledFor: nextRunAt.toISOString() },
    {
      jobId: scheduleMirrorJobId(scheduleId, nextRunAt.getTime()),
      delay: Math.max(1, nextRunAt.getTime() - now.getTime()),
    },
  );
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

/**
 * `createQueues` options. `withPluginInstalls` is additive and defaults OFF
 * so P1 consumers keep byte-identical behavior (the queue is created only
 * when the worker composition opts in).
 */
export interface QueueServicesOptions extends QueuePrefixOptions {
  withPluginInstalls?: boolean;
}

export interface QueueServices {
  agentRuns: Queue<AgentRunJob>;
  /** P7: hibernate jobs (warm → cold). */
  hibernate: Queue<HibernateJob>;
  /** P7: hydrate jobs (cold → warm). */
  hydrate: Queue<HydrateJob>;
  /** P4: delayed mirror of upcoming schedule occurrences. */
  schedules: Queue<ScheduleFireJob>;
  /** P5 Task 14: plugin install/uninstall transactions (opt-in). */
  pluginInstalls?: Queue<PluginInstallJob>;
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
  opts: QueueServicesOptions = {},
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

  const services: QueueServices = {
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
    // P4: built inline (not via storageQueue) — the brief pins
    // defaultJobOptions {} (schedules jobs carry NO package defaults: the
    // delay is per-add; attempts stay BullMQ's own) — but with the SAME
    // prefix threading as every other queue: the caller's prefix scopes the
    // `schedules` keys exactly like `agent-runs`, no special-casing.
    schedules: new Queue<ScheduleFireJob>(
      SCHEDULES,
      // No prefix key at all when unset → BullMQ default ("bull"):
      // production key layout is unchanged; test suites scope their own
      // keys (see QueuePrefixOptions).
      {
        connection: withBlockingSafeRetries(connection),
        ...(opts.prefix !== undefined ? { prefix: opts.prefix } : {}),
        defaultJobOptions: {},
      },
    ),
  };

  // P5 Task 14 (ADDITIVE): opt-in only — existing consumers never see the
  // extra queue, and no redis keys are created unless the worker opts in.
  if (opts.withPluginInstalls === true) {
    services.pluginInstalls = new Queue<PluginInstallJob>(PLUGIN_INSTALLS, {
      connection: withBlockingSafeRetries(connection),
      ...(opts.prefix !== undefined ? { prefix: opts.prefix } : {}),
      // attempts: 1 — the installer owns rollback (see the ruling above).
      defaultJobOptions: { ...PLUGIN_INSTALL_JOB_DEFAULTS },
    });
  }

  return services;
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

/**
 * P4 Task 6 — worker for the schedules mirror queue. The prefix MUST equal
 * the add-side createQueues prefix or mirror jobs never meet (P1 fix-wave
 * mechanism, same as createAgentRunsWorker; production passes NO prefix —
 * BullMQ default "bull"). Firing a schedule is one repo read plus an agent-run
 * enqueue, so unlike the agent-runs/storage workers no package-level
 * concurrency/stalledInterval constants are pinned here: an explicit
 * `concurrency` opts wins, otherwise BullMQ's own worker defaults apply.
 */
export function createScheduleFireWorker(
  connection: ConnectionOptions,
  processor: Processor<ScheduleFireJob>,
  opts: { concurrency?: number } & QueuePrefixOptions = {},
): Worker<ScheduleFireJob> {
  return new Worker<ScheduleFireJob>(
    SCHEDULES,
    processor,
    {
      connection: withBlockingSafeRetries(connection),
      // must match the add-side queue's prefix or jobs never meet
      ...(opts.prefix !== undefined ? { prefix: opts.prefix } : {}),
      ...(opts.concurrency !== undefined ? { concurrency: opts.concurrency } : {}),
    },
  );
}

/**
 * P5 Task 14 — worker for the plugin-installs queue. The prefix MUST equal
 * the add-side createQueues({withPluginInstalls:true, prefix}) or jobs never
 * meet (P1 mechanism). The processor is the worker's
 * `createPluginInstallProcessor` (apps/worker): it claims the row, calls the
 * installer, and terminalizes run-level failures; `attempts: 1` means a
 * thrown error is never redelivered into a second rollback.
 */
export function createPluginInstallsWorker(
  connection: ConnectionOptions,
  processor: Processor<PluginInstallJob>,
  opts: { concurrency?: number } & QueuePrefixOptions = {},
): Worker<PluginInstallJob> {
  return new Worker<PluginInstallJob>(
    PLUGIN_INSTALLS,
    processor,
    {
      connection: withBlockingSafeRetries(connection),
      // must match the add-side queue's prefix or jobs never meet
      ...(opts.prefix !== undefined ? { prefix: opts.prefix } : {}),
      ...(opts.concurrency !== undefined ? { concurrency: opts.concurrency } : {}),
    },
  );
}
