import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { ConnectionOptions, Job, Queue, Worker } from "bullmq";
import {
  AGENT_RUN_JOB_DEFAULTS,
  AGENT_RUN_JOB_NAME,
  AGENT_RUNS,
  AGENT_RUNS_DEFAULT_CONCURRENCY,
  AGENT_RUNS_STALLED_INTERVAL_MS,
  agentRunJobSchema,
  addScheduleMirrorJob,
  createAgentRunsWorker,
  createHibernateWorker,
  createHydrateWorker,
  createQueues,
  createScheduleFireWorker,
  HIBERNATE,
  HIBERNATE_JOB_NAME,
  hibernateJobSchema,
  HYDRATE,
  HYDRATE_JOB_NAME,
  hydrateJobSchema,
  SCHEDULE_FIRE_JOB_NAME,
  SCHEDULES,
  scheduleFireJobSchema,
  scheduleMirrorJobId,
  STORAGE_JOB_CONCURRENCY,
  STORAGE_JOB_DEFAULTS,
  storageJobId,
  type AgentRunJob,
  type HibernateJob,
  type HydrateJob,
  type QueueServices,
  type ScheduleFireJob,
} from "./queues.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

let counter = 0;
function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

function jobPayload(): AgentRunJob {
  return {
    runId: uid("run"),
    sessionId: uid("sess"),
    userId: uid("user"),
    prompt: "tell me a story",
  };
}

// ---------------------------------------------------------------------------
// Pure contract tests — no redis needed, always run.
// ---------------------------------------------------------------------------

describe("agentRunJobSchema", () => {
  const valid: AgentRunJob = {
    runId: "r1",
    sessionId: "s1",
    userId: "u1",
    prompt: "hi",
  };

  it("accepts a well-formed AgentRunJob", () => {
    expect(agentRunJobSchema.safeParse(valid)).toEqual({
      success: true,
      data: valid,
    });
  });

  it("rejects a job missing prompt", () => {
    const missing = { runId: "r1", sessionId: "s1", userId: "u1" };
    expect(agentRunJobSchema.safeParse(missing).success).toBe(false);
  });

  it("rejects wrong types and empty strings", () => {
    expect(
      agentRunJobSchema.safeParse({ ...valid, prompt: 42 }).success,
    ).toBe(false);
    expect(
      agentRunJobSchema.safeParse({ ...valid, runId: "" }).success,
    ).toBe(false);
    expect(agentRunJobSchema.safeParse(null).success).toBe(false);
  });

  it("accepts an optional attachmentIds list (P8 Task 3) and rejects malformed ones", () => {
    expect(
      agentRunJobSchema.safeParse({ ...valid, attachmentIds: ["a1", "a2"] }),
    ).toEqual({ success: true, data: { ...valid, attachmentIds: ["a1", "a2"] } });
    expect(agentRunJobSchema.safeParse(valid).success).toBe(true);
    expect(
      agentRunJobSchema.safeParse({ ...valid, attachmentIds: [] }).success,
    ).toBe(true);
    expect(
      agentRunJobSchema.safeParse({ ...valid, attachmentIds: "a1" }).success,
    ).toBe(false);
    expect(
      agentRunJobSchema.safeParse({ ...valid, attachmentIds: [""] }).success,
    ).toBe(false);
  });

  it("P3 Task 16: preserves unattended/autonomy/mode through validation (additive, old payloads unchanged)", () => {
    // The fields the gateway sends for unattended runs and mode selection.
    const enriched = {
      ...valid,
      unattended: true,
      autonomy: "safe" as const,
      mode: "drive" as const,
    };
    expect(agentRunJobSchema.safeParse(enriched)).toEqual({
      success: true,
      data: enriched,
    });
    // A payload WITHOUT the new fields parses unchanged — z.object must not
    // strip anything that was absent, and nothing new is required.
    expect(agentRunJobSchema.safeParse(valid)).toEqual({ success: true, data: valid });
    // Reject values outside the pinned enums.
    expect(
      agentRunJobSchema.safeParse({ ...valid, autonomy: "full" }).success,
    ).toBe(false);
    expect(
      agentRunJobSchema.safeParse({ ...valid, mode: "readonly" }).success,
    ).toBe(false);
    expect(
      agentRunJobSchema.safeParse({ ...valid, unattended: "yes" }).success,
    ).toBe(false);
  });

  it("P4 Task 6: parses a payload with the optional schedule ref; one without parses unchanged (additivity pin)", () => {
    // A P1-era payload (pre-scheduler) must still parse — nothing new is
    // required and absent keys stay absent.
    expect(agentRunJobSchema.safeParse(valid)).toEqual({ success: true, data: valid });

    // The scheduler's run ref rides the same agent-run job.
    const withSchedule = {
      ...valid,
      schedule: { scheduleId: "sch-1", scheduleRunId: "sr-1", autonomy: "safe" as const },
    };
    expect(agentRunJobSchema.safeParse(withSchedule)).toEqual({
      success: true,
      data: withSchedule,
    });

    // Reject malformed refs: bad autonomy, empty ids, wrong shapes.
    expect(
      agentRunJobSchema.safeParse({
        ...valid,
        schedule: { scheduleId: "sch-1", scheduleRunId: "sr-1", autonomy: "full" },
      }).success,
    ).toBe(false);
    expect(
      agentRunJobSchema.safeParse({
        ...valid,
        schedule: { scheduleId: "", scheduleRunId: "sr-1", autonomy: "auto" },
      }).success,
    ).toBe(false);
    expect(
      agentRunJobSchema.safeParse({ ...valid, schedule: "sch-1" }).success,
    ).toBe(false);
  });
});

describe("AGENT_RUN_JOB_DEFAULTS", () => {
  it("pins BullMQ attempts to 1 — model-call retries live inside the Task 9 processor; two retry layers would multiply (controller ruling)", () => {
    expect(AGENT_RUN_JOB_DEFAULTS.attempts).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// P7 Task 7 — hibernate/hydrate storage queues (pure contract tests).
// ---------------------------------------------------------------------------

describe("storage job ids and defaults", () => {
  it("storageJobId composes `${sessionId}~${generation}` — the idempotent add id (spike §9.3; `~` not `:`: BullMQ rejects custom ids containing ':')", () => {
    expect(storageJobId("sess-1", 3)).toBe("sess-1~3");
    expect(storageJobId("s", 0)).toBe("s~0");
  });

  it("STORAGE_JOB_DEFAULTS pins 3 attempts with exponential 5 s backoff and removes settled jobs (C2: completed/failed jobIds must be reusable)", () => {
    expect(STORAGE_JOB_DEFAULTS).toEqual({
      attempts: 3,
      backoff: { type: "exponential", delay: 5_000 },
      removeOnComplete: true,
      removeOnFail: true,
    });
  });

  it("STORAGE_JOB_CONCURRENCY is 2 — pack/extract are CPU+IO heavy on the 8-core box", () => {
    expect(STORAGE_JOB_CONCURRENCY).toBe(2);
  });
});

describe("hibernateJobSchema", () => {
  const valid: HibernateJob = {
    sessionId: "s1",
    userId: "u1",
    generation: 1,
    reason: "idle",
  };

  it("round-trips a well-formed HibernateJob", () => {
    expect(hibernateJobSchema.safeParse(valid)).toEqual({
      success: true,
      data: valid,
    });
  });

  it("accepts every HibernateReason", () => {
    for (const reason of ["idle", "pressure", "manual"] as const) {
      expect(hibernateJobSchema.safeParse({ ...valid, reason }).success).toBe(true);
    }
  });

  it("rejects a non-integer generation (1.5)", () => {
    expect(
      hibernateJobSchema.safeParse({ ...valid, generation: 1.5 }).success,
    ).toBe(false);
  });

  it("rejects generation 0 — hibernate claims are row.generation + 1, so 1 is the floor", () => {
    expect(hibernateJobSchema.safeParse({ ...valid, generation: 0 }).success).toBe(false);
  });

  it("rejects an unknown reason and empty ids", () => {
    expect(hibernateJobSchema.safeParse({ ...valid, reason: "bogus" }).success).toBe(false);
    expect(hibernateJobSchema.safeParse({ ...valid, sessionId: "" }).success).toBe(false);
    expect(hibernateJobSchema.safeParse({ ...valid, userId: "" }).success).toBe(false);
  });
});

describe("hydrateJobSchema", () => {
  const valid: HydrateJob = {
    sessionId: "s1",
    userId: "u1",
    generation: 0,
    reason: "run",
  };

  it("round-trips a well-formed HydrateJob — generation 0 is valid (cold, never hibernated)", () => {
    expect(hydrateJobSchema.safeParse(valid)).toEqual({ success: true, data: valid });
  });

  it("accepts every HydrateReason", () => {
    for (const reason of ["run", "open", "write", "manual"] as const) {
      expect(hydrateJobSchema.safeParse({ ...valid, reason }).success).toBe(true);
    }
  });

  it("rejects negative and non-integer generations", () => {
    expect(hydrateJobSchema.safeParse({ ...valid, generation: -1 }).success).toBe(false);
    expect(hydrateJobSchema.safeParse({ ...valid, generation: 0.5 }).success).toBe(false);
  });

  it("rejects a reason from the wrong enum", () => {
    expect(hydrateJobSchema.safeParse({ ...valid, reason: "idle" }).success).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// P4 Task 6 — schedules mirror queue (pure contract tests).
// ---------------------------------------------------------------------------

describe("scheduleFireJobSchema", () => {
  const valid: ScheduleFireJob = {
    scheduleId: "s1",
    scheduledFor: "2026-10-17T00:00:00.000Z",
  };

  it("round-trips a well-formed ScheduleFireJob", () => {
    expect(scheduleFireJobSchema.safeParse(valid)).toEqual({
      success: true,
      data: valid,
    });
  });

  it("rejects missing or empty fields", () => {
    expect(scheduleFireJobSchema.safeParse({ scheduleId: "s1" }).success).toBe(false);
    expect(
      scheduleFireJobSchema.safeParse({ scheduleId: "", scheduledFor: valid.scheduledFor })
        .success,
    ).toBe(false);
    expect(
      scheduleFireJobSchema.safeParse({ scheduleId: "s1", scheduledFor: "" }).success,
    ).toBe(false);
    expect(scheduleFireJobSchema.safeParse(null).success).toBe(false);
  });
});

describe("scheduleMirrorJobId", () => {
  it("composes `${scheduleId}~${scheduledForMs}` — the storageJobId `~` ruling (BullMQ rejects ':' in custom job ids)", () => {
    // The plan's literal was `${scheduleId}:${scheduledForMs}`, but BullMQ
    // (5.81.5) throws "Custom Id cannot contain :" on any non-3-part colon
    // id — the same deviation storageJobId already ruled on. Consumers treat
    // the id as opaque (add + getJob); `~` keeps the pinned semantics: same
    // id for the same (schedule, occurrence) → idempotent re-adds.
    expect(scheduleMirrorJobId("s", 123)).toBe("s~123");
    expect(scheduleMirrorJobId("sched-9", 1_778_000_000_000)).toBe(
      "sched-9~1778000000000",
    );
  });
});

// ---------------------------------------------------------------------------
// Real-redis behavior. Parallel test suites share the dev redis, so this suite
// scopes ALL its BullMQ keys behind a suite-unique prefix
// (OVID_TEST_QUEUE_PREFIX + "-queue"; default "ovid-test-queue") — its
// obliterate calls can then never wipe another suite's agent-runs queue. Job
// uniqueness comes from per-run job ids; our own keys are obliterated before
// each test and in afterAll (shared dev redis — FLUSHDB and other suites'
// keys are off-limits).
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_REDIS_URL)("agent-runs and storage queues against real redis", () => {
  const QUEUE_PREFIX = process.env.OVID_TEST_QUEUE_PREFIX
    ? `${process.env.OVID_TEST_QUEUE_PREFIX}-queue`
    : "ovid-test-queue";
  const connection: ConnectionOptions = { url: TEST_REDIS_URL! };
  let queues: QueueServices;
  type AnyWorker =
    | Worker<AgentRunJob>
    | Worker<HibernateJob>
    | Worker<HydrateJob>
    | Worker<ScheduleFireJob>;
  const openWorkers: AnyWorker[] = [];

  function trackWorker<T extends AnyWorker>(w: T): T {
    openWorkers.push(w);
    return w;
  }

  async function closeWorker(w: AnyWorker): Promise<void> {
    const i = openWorkers.indexOf(w);
    if (i >= 0) openWorkers.splice(i, 1);
    await w.close();
  }

  /** Wait until a settled job's key is gone (removeOnComplete/removeOnFail). */
  async function waitForJobGone(
    queue: Queue<HibernateJob> | Queue<HydrateJob>,
    jobId: string,
    timeoutMs = 5_000,
  ): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      if ((await queue.getJob(jobId)) === undefined) return;
      if (Date.now() >= deadline) {
        throw new Error(`job ${jobId} was not removed within ${timeoutMs} ms`);
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }

  beforeAll(() => {
    queues = createQueues(connection, { prefix: QUEUE_PREFIX });
    expect(AGENT_RUNS).toBe("agent-runs");
  });

  beforeEach(async () => {
    // Deterministic job counts: wipe only this suite's prefixed keys (also
    // shields the suite from leftovers of a previously crashed run).
    await queues.agentRuns.obliterate({ force: true });
    await queues.hibernate.obliterate({ force: true });
    await queues.hydrate.obliterate({ force: true });
    await queues.schedules.obliterate({ force: true });
  });

  afterAll(async () => {
    // BullMQ keeps blocking connections open — vitest hangs unless every
    // queue/worker created here is closed and our keys are removed.
    for (const w of [...openWorkers]) {
      await closeWorker(w);
    }
    if (queues) {
      await queues.agentRuns.obliterate({ force: true });
      await queues.agentRuns.close();
      await queues.hibernate.obliterate({ force: true });
      await queues.hibernate.close();
      await queues.hydrate.obliterate({ force: true });
      await queues.hydrate.close();
      await queues.schedules.obliterate({ force: true });
      await queues.schedules.close();
    }
  });

  it("prefix option scopes the queue keys: default 'bull' (production layout), custom prefix applies to queue and worker", async () => {
    // Default must stay BullMQ's own "bull" — production key layout is a
    // contract with the deploy (compose env, monitoring, restore drills).
    const unscoped = createQueues(connection);
    expect(unscoped.agentRuns.opts.prefix).toBe("bull");
    expect(unscoped.hibernate.opts.prefix).toBe("bull");
    expect(unscoped.hydrate.opts.prefix).toBe("bull");
    expect(unscoped.schedules.opts.prefix).toBe("bull");
    await unscoped.agentRuns.close();
    await unscoped.hibernate.close();
    await unscoped.hydrate.close();
    await unscoped.schedules.close();

    const scoped = createQueues(connection, { prefix: "t:iso" });
    expect(scoped.agentRuns.opts.prefix).toBe("t:iso");
    expect(scoped.hibernate.opts.prefix).toBe("t:iso"); // P1 prefix discipline: EVERY queue in createQueues threads the prefix
    expect(scoped.hydrate.opts.prefix).toBe("t:iso");
    expect(scoped.schedules.opts.prefix).toBe("t:iso"); // P4: the scheduler queue inherits the same discipline
    await scoped.agentRuns.obliterate({ force: true }); // only "t:iso" keys
    await scoped.hibernate.obliterate({ force: true });
    await scoped.hydrate.obliterate({ force: true });
    await scoped.schedules.obliterate({ force: true });
    await scoped.agentRuns.close();
    await scoped.hibernate.close();
    await scoped.hydrate.close();
    await scoped.schedules.close();

    const worker = trackWorker(
      createAgentRunsWorker(connection, async () => undefined, { prefix: "t:iso" }),
    );
    expect(worker.opts.prefix).toBe("t:iso"); // must match the add side or jobs never meet
    await closeWorker(worker);

    const hworker = trackWorker(
      createHibernateWorker(connection, async () => undefined, { prefix: "t:iso" }),
    );
    expect(hworker.opts.prefix).toBe("t:iso");
    await closeWorker(hworker);

    const sfworker = trackWorker(
      createScheduleFireWorker(connection, async () => undefined, { prefix: "t:iso" }),
    );
    expect(sfworker.opts.prefix).toBe("t:iso");
    await closeWorker(sfworker);

    // And this suite's own queues are prefixed.
    expect(queues.agentRuns.opts.prefix).toBe(QUEUE_PREFIX);
    expect(queues.hibernate.opts.prefix).toBe(QUEUE_PREFIX);
    expect(queues.hydrate.opts.prefix).toBe(QUEUE_PREFIX);
    expect(queues.schedules.opts.prefix).toBe(QUEUE_PREFIX);
  });

  it("adding the same jobId twice dedupes: same job id, one job in the queue", async () => {
    const payload = jobPayload();
    const first = await queues.agentRuns.add(AGENT_RUN_JOB_NAME, payload, {
      jobId: payload.runId,
    });
    const second = await queues.agentRuns.add(AGENT_RUN_JOB_NAME, payload, {
      jobId: payload.runId,
    });

    expect(second.id).toBe(first.id);
    expect(first.id).toBe(payload.runId); // caller-chosen jobId = runId (idempotent adds)

    const counts = await queues.agentRuns.getJobCounts();
    const total = Object.values(counts).reduce((a, b) => a + b, 0);
    expect(total).toBe(1); // no duplicate queued
  });

  it("applies attempts: 1 as the package default job option", async () => {
    const payload = jobPayload();
    // Caller passes its own options (jobId, priority) but never attempts —
    // the queue default must still pin attempts to 1 (ruling).
    await queues.agentRuns.add(AGENT_RUN_JOB_NAME, payload, {
      jobId: payload.runId,
      priority: 2,
    });

    const stored = await queues.agentRuns.getJob(payload.runId);
    expect(stored?.opts.attempts).toBe(1);
  });

  it("createAgentRunsWorker processes an added job with pinned defaults (concurrency 8, stalledInterval 30s)", async () => {
    const processed: AgentRunJob[] = [];
    const worker = trackWorker(
      createAgentRunsWorker(connection, async (job) => {
        processed.push(job.data);
      }, { prefix: QUEUE_PREFIX }),
    );

    // Plan-pinned worker configuration: default concurrency 8; the stalled
    // check moves a crashed job to FAILED every 30 s (attempts: 1 → never
    // redelivered; the stale-run sweeper is the recovery mechanism — see
    // queues.ts and apps/worker staleRuns.ts).
    expect(AGENT_RUNS_DEFAULT_CONCURRENCY).toBe(8);
    expect(worker.opts.concurrency).toBe(8);
    expect(AGENT_RUNS_STALLED_INTERVAL_MS).toBe(30_000);
    expect(worker.opts.stalledInterval).toBe(30_000);

    const completed = new Promise<Job<AgentRunJob>>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("timed out waiting for worker completed event")),
        5_000,
      );
      worker.once("completed", (job) => {
        clearTimeout(timer);
        resolve(job);
      });
    });

    const payload = jobPayload();
    const added = await queues.agentRuns.add(AGENT_RUN_JOB_NAME, payload, {
      jobId: payload.runId,
    });

    const done = await completed;
    expect(done.id).toBe(added.id);
    expect(done.data).toEqual(payload); // payload round-trips through the queue
    expect(done.opts.attempts).toBe(1); // add-side and worker-side agree (ruling)
    expect(processed).toEqual([payload]);

    await closeWorker(worker);
  });

  it("honors an explicit concurrency override", async () => {
    const worker = trackWorker(
      createAgentRunsWorker(connection, async () => undefined, {
        concurrency: 3,
        prefix: QUEUE_PREFIX,
      }),
    );
    expect(worker.opts.concurrency).toBe(3);
    await closeWorker(worker);
  });

  // -------------------------------------------------------------------------
  // P7 Task 7 — hibernate/hydrate storage queues.
  // -------------------------------------------------------------------------

  it("exposes hibernate and hydrate queues with pinned names", () => {
    expect(HIBERNATE).toBe("hibernate");
    expect(HYDRATE).toBe("hydrate");
    expect(HIBERNATE_JOB_NAME).toBe("hibernate-workspace");
    expect(HYDRATE_JOB_NAME).toBe("hydrate-workspace");
    expect(queues.hibernate.name).toBe("hibernate");
    expect(queues.hydrate.name).toBe("hydrate");
  });

  it("adding the same storageJobId twice dedupes: same job id, one job in each queue", async () => {
    const hjob: HibernateJob = {
      sessionId: uid("sess"),
      userId: uid("user"),
      generation: 4,
      reason: "pressure",
    };
    const hid = storageJobId(hjob.sessionId, hjob.generation);
    const h1 = await queues.hibernate.add(HIBERNATE_JOB_NAME, hjob, {
      jobId: hid,
    });
    const h2 = await queues.hibernate.add(HIBERNATE_JOB_NAME, hjob, {
      jobId: hid,
    });
    expect(h2.id).toBe(h1.id);
    expect(h1.id).toBe(hid);
    const hcounts = await queues.hibernate.getJobCounts();
    expect(Object.values(hcounts).reduce((a, b) => a + b, 0)).toBe(1);

    const yjob: HydrateJob = {
      sessionId: uid("sess"),
      userId: uid("user"),
      generation: 0,
      reason: "open",
    };
    const yid = storageJobId(yjob.sessionId, yjob.generation);
    const y1 = await queues.hydrate.add(HYDRATE_JOB_NAME, yjob, {
      jobId: yid,
    });
    const y2 = await queues.hydrate.add(HYDRATE_JOB_NAME, yjob, {
      jobId: yid,
    });
    expect(y2.id).toBe(y1.id);
    expect(y1.id).toBe(yid);
    const ycounts = await queues.hydrate.getJobCounts();
    expect(Object.values(ycounts).reduce((a, b) => a + b, 0)).toBe(1);
  });

  it("applies STORAGE_JOB_DEFAULTS as both storage queues' default job options", async () => {
    const job: HibernateJob = {
      sessionId: uid("sess"),
      userId: uid("user"),
      generation: 1,
      reason: "manual",
    };
    await queues.hibernate.add(HIBERNATE_JOB_NAME, job, {
      jobId: storageJobId(job.sessionId, job.generation),
    });
    const stored = await queues.hibernate.getJob(
      storageJobId(job.sessionId, job.generation),
    );
    expect(stored?.opts.attempts).toBe(3);
    expect(stored?.opts.backoff).toEqual({ type: "exponential", delay: 5_000 });
    expect(stored?.opts.removeOnComplete).toBe(true);
    expect(stored?.opts.removeOnFail).toBe(true);

    const yjob: HydrateJob = {
      sessionId: uid("sess"),
      userId: uid("user"),
      generation: 2,
      reason: "run",
    };
    await queues.hydrate.add(HYDRATE_JOB_NAME, yjob, {
      jobId: storageJobId(yjob.sessionId, yjob.generation),
    });
    const ystored = await queues.hydrate.getJob(
      storageJobId(yjob.sessionId, yjob.generation),
    );
    expect(ystored?.opts.attempts).toBe(3);
    expect(ystored?.opts.backoff).toEqual({ type: "exponential", delay: 5_000 });
    expect(ystored?.opts.removeOnComplete).toBe(true);
    expect(ystored?.opts.removeOnFail).toBe(true);
  });

  it("re-runs a COMPLETED storage jobId (C2: removeOnComplete releases the dedupe key)", async () => {
    const runs: string[] = [];
    const worker = trackWorker(
      createHibernateWorker(
        connection,
        async (job) => {
          runs.push(String(job.id));
        },
        { prefix: QUEUE_PREFIX },
      ),
    );

    const payload: HibernateJob = {
      sessionId: uid("sess"),
      userId: uid("user"),
      generation: 1,
      reason: "idle",
    };
    const jobId = storageJobId(payload.sessionId, payload.generation);

    const onceCompleted = () =>
      new Promise<void>((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error("timed out waiting for hibernate completion")),
          5_000,
        );
        worker.once("completed", () => {
          clearTimeout(timer);
          resolve();
        });
      });

    // First run completes (this is the "skipped idle hibernate" shape: the
    // processor returns and the job settles).
    const first = onceCompleted();
    await queues.hibernate.add(HIBERNATE_JOB_NAME, payload, { jobId });
    await first;
    await waitForJobGone(queues.hibernate, jobId);

    // Re-adding the SAME (session, generation) id must actually run again —
    // without removeOnComplete BullMQ would return the settled job and the
    // processor would never be invoked (C2 reproduction).
    const second = onceCompleted();
    await queues.hibernate.add(HIBERNATE_JOB_NAME, payload, { jobId });
    await second;

    expect(runs).toHaveLength(2);
    await closeWorker(worker);
  });

  it("re-runs a FAILED storage jobId (C2: removeOnFail releases the dedupe key)", async () => {
    let runs = 0;
    const worker = trackWorker(
      createHydrateWorker(
        connection,
        async () => {
          runs += 1;
          throw new Error("simulated extract failure");
        },
        { prefix: QUEUE_PREFIX },
      ),
    );

    const payload: HydrateJob = {
      sessionId: uid("sess"),
      userId: uid("user"),
      generation: 7,
      reason: "run",
    };
    const jobId = storageJobId(payload.sessionId, payload.generation);

    const onceFailed = () =>
      new Promise<void>((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error("timed out waiting for hydrate failure")),
          5_000,
        );
        worker.once("failed", () => {
          clearTimeout(timer);
          resolve();
        });
      });

    // attempts: 1 keeps the test fast; the failure is terminal either way.
    const first = onceFailed();
    await queues.hydrate.add(HYDRATE_JOB_NAME, payload, { jobId, attempts: 1 });
    await first;
    await waitForJobGone(queues.hydrate, jobId);

    const second = onceFailed();
    await queues.hydrate.add(HYDRATE_JOB_NAME, payload, { jobId, attempts: 1 });
    await second;

    expect(runs).toBe(2);
    await closeWorker(worker);
  });

  it("createHibernateWorker consumes an added job (exact payload, concurrency 2 default)", async () => {
    const processed: HibernateJob[] = [];
    const worker = trackWorker(
      createHibernateWorker(
        connection,
        async (job) => {
          processed.push(job.data);
        },
        { prefix: QUEUE_PREFIX },
      ),
    );
    expect(STORAGE_JOB_CONCURRENCY).toBe(2);
    expect(worker.opts.concurrency).toBe(2);

    const completed = new Promise<Job<HibernateJob>>((resolve, reject) => {
      const timer = setTimeout(
        () =>
          reject(new Error("timed out waiting for hibernate worker completed event")),
        5_000,
      );
      worker.once("completed", (job) => {
        clearTimeout(timer);
        resolve(job);
      });
    });

    const payload: HibernateJob = {
      sessionId: uid("sess"),
      userId: uid("user"),
      generation: 1,
      reason: "idle",
    };
    const added = await queues.hibernate.add(HIBERNATE_JOB_NAME, payload, {
      jobId: storageJobId(payload.sessionId, payload.generation),
    });

    const done = await completed;
    expect(done.id).toBe(added.id);
    expect(done.data).toEqual(payload); // payload round-trips through the queue
    expect(done.opts.attempts).toBe(3); // add side and worker side share the defaults
    expect(processed).toEqual([payload]);

    await closeWorker(worker);
  });

  it("createHydrateWorker consumes an added job and honors a concurrency override", async () => {
    const processed: HydrateJob[] = [];
    const worker = trackWorker(
      createHydrateWorker(
        connection,
        async (job) => {
          processed.push(job.data);
        },
        { concurrency: 1, prefix: QUEUE_PREFIX },
      ),
    );
    expect(worker.opts.concurrency).toBe(1);

    const completed = new Promise<Job<HydrateJob>>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("timed out waiting for hydrate worker completed event")),
        5_000,
      );
      worker.once("completed", (job) => {
        clearTimeout(timer);
        resolve(job);
      });
    });

    const payload: HydrateJob = {
      sessionId: uid("sess"),
      userId: uid("user"),
      generation: 0,
      reason: "run",
    };
    const added = await queues.hydrate.add(HYDRATE_JOB_NAME, payload, {
      jobId: storageJobId(payload.sessionId, payload.generation),
    });

    const done = await completed;
    expect(done.id).toBe(added.id);
    expect(done.data).toEqual(payload);
    expect(done.opts.attempts).toBe(3);
    expect(processed).toEqual([payload]);

    await closeWorker(worker);
  });

  // -------------------------------------------------------------------------
  // P4 Task 6 — schedules mirror queue.
  // -------------------------------------------------------------------------

  it("exposes the schedules queue with its pinned name and suite prefix", () => {
    expect(SCHEDULES).toBe("schedules");
    expect(SCHEDULE_FIRE_JOB_NAME).toBe("schedule-fire");
    expect(queues.schedules.name).toBe("schedules");
    // Isolation is additive with the queue: the schedules keys live under the
    // same suite prefix as agent-runs (P1 fix-wave discipline).
    expect(queues.schedules.opts.prefix).toBe(QUEUE_PREFIX);
  });

  it("addScheduleMirrorJob enqueues a delayed, idempotent mirror job (jobId = mirror id)", async () => {
    const scheduleId = uid("sched");
    const now = new Date();
    const nextRunAt = new Date(now.getTime() + 5_000);

    await addScheduleMirrorJob(queues, scheduleId, nextRunAt, now);

    const counts = await queues.schedules.getJobCounts();
    expect(counts.delayed).toBe(1); // future occurrence → delayed, not waiting

    const mirrorId = scheduleMirrorJobId(scheduleId, nextRunAt.getTime());
    const job = await queues.schedules.getJob(mirrorId);
    expect(job?.id).toBe(mirrorId);
    expect(job?.name).toBe(SCHEDULE_FIRE_JOB_NAME);
    expect(job?.data).toEqual({
      scheduleId,
      scheduledFor: nextRunAt.toISOString(), // ISO of the occurrence
    });
    // defaultJobOptions {}: schedules jobs carry NO package defaults — the
    // delay is per-add, and attempts stays BullMQ's own unset marker (0),
    // i.e. neither agent-runs' pinned 1 nor storage's 3 applies here.
    expect(job?.opts.attempts).toBe(0);

    // Deterministic jobId → re-adding the same occurrence is a no-op.
    await addScheduleMirrorJob(queues, scheduleId, nextRunAt, now);
    const recount = await queues.schedules.getJobCounts();
    expect(recount.delayed).toBe(1);
  });

  it("a past nextRunAt clamps the delay to ≥1 so the job fires through createScheduleFireWorker", async () => {
    const processed: ScheduleFireJob[] = [];
    const worker = trackWorker(
      createScheduleFireWorker(
        connection,
        async (job) => {
          processed.push(job.data);
        },
        { prefix: QUEUE_PREFIX },
      ),
    );

    const completed = new Promise<Job<ScheduleFireJob>>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("timed out waiting for schedule-fire worker completed event")),
        5_000,
      );
      worker.once("completed", (job) => {
        clearTimeout(timer);
        resolve(job);
      });
    });

    const scheduleId = uid("sched");
    const now = new Date();
    const nextRunAt = new Date(now.getTime() - 10_000); // overdue occurrence
    await addScheduleMirrorJob(queues, scheduleId, nextRunAt, now);

    // A negative delay would throw/misfire; clamped to ≥1 the job is
    // immediately waitable and the worker picks it up.
    const done = await completed;
    const mirrorId = scheduleMirrorJobId(scheduleId, nextRunAt.getTime());
    expect(done.id).toBe(mirrorId);
    expect(done.data).toEqual({
      scheduleId,
      scheduledFor: nextRunAt.toISOString(),
    });
    expect(processed).toEqual([
      { scheduleId, scheduledFor: nextRunAt.toISOString() },
    ]);

    await closeWorker(worker);
  });
});
