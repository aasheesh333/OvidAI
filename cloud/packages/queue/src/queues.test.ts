import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { ConnectionOptions, Job, Worker } from "bullmq";
import {
  AGENT_RUN_JOB_DEFAULTS,
  AGENT_RUN_JOB_NAME,
  AGENT_RUNS,
  AGENT_RUNS_DEFAULT_CONCURRENCY,
  AGENT_RUNS_STALLED_INTERVAL_MS,
  agentRunJobSchema,
  createAgentRunsWorker,
  createQueues,
  type AgentRunJob,
  type QueueServices,
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
});

describe("AGENT_RUN_JOB_DEFAULTS", () => {
  it("pins BullMQ attempts to 1 — model-call retries live inside the Task 9 processor; two retry layers would multiply (controller ruling)", () => {
    expect(AGENT_RUN_JOB_DEFAULTS.attempts).toBe(1);
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

describe.skipIf(!TEST_REDIS_URL)("agent-runs queue against real redis", () => {
  const QUEUE_PREFIX = process.env.OVID_TEST_QUEUE_PREFIX
    ? `${process.env.OVID_TEST_QUEUE_PREFIX}-queue`
    : "ovid-test-queue";
  const connection: ConnectionOptions = { url: TEST_REDIS_URL! };
  let queues: QueueServices;
  const openWorkers: Worker<AgentRunJob>[] = [];

  function trackWorker(w: Worker<AgentRunJob>): Worker<AgentRunJob> {
    openWorkers.push(w);
    return w;
  }

  async function closeWorker(w: Worker<AgentRunJob>): Promise<void> {
    const i = openWorkers.indexOf(w);
    if (i >= 0) openWorkers.splice(i, 1);
    await w.close();
  }

  beforeAll(() => {
    queues = createQueues(connection, { prefix: QUEUE_PREFIX });
    expect(AGENT_RUNS).toBe("agent-runs");
  });

  beforeEach(async () => {
    // Deterministic job counts: wipe only this suite's prefixed keys (also
    // shields the suite from leftovers of a previously crashed run).
    await queues.agentRuns.obliterate({ force: true });
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
    }
  });

  it("prefix option scopes the queue keys: default 'bull' (production layout), custom prefix applies to queue and worker", async () => {
    // Default must stay BullMQ's own "bull" — production key layout is a
    // contract with the deploy (compose env, monitoring, restore drills).
    const unscoped = createQueues(connection);
    expect(unscoped.agentRuns.opts.prefix).toBe("bull");
    await unscoped.agentRuns.close();

    const scoped = createQueues(connection, { prefix: "t:iso" });
    expect(scoped.agentRuns.opts.prefix).toBe("t:iso");
    await scoped.agentRuns.obliterate({ force: true }); // only "t:iso" keys
    await scoped.agentRuns.close();

    const worker = trackWorker(
      createAgentRunsWorker(connection, async () => undefined, { prefix: "t:iso" }),
    );
    expect(worker.opts.prefix).toBe("t:iso"); // must match the add side or jobs never meet
    await closeWorker(worker);

    // And this suite's own queues are prefixed.
    expect(queues.agentRuns.opts.prefix).toBe(QUEUE_PREFIX);
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
});
