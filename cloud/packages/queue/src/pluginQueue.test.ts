/**
 * P5 Task 14 — plugin-installs queue contract.
 *
 * Pure schema/default tests always run; the real-BullMQ round-trip is gated
 * on TEST_REDIS_URL. The suite scopes ALL of its keys behind a suite-unique
 * prefix (the P1 discipline) so it can never collide with queues.test.ts or
 * another suite sharing the dev redis. FLUSHDB is never used.
 */

import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { ConnectionOptions, Job, Worker } from "bullmq";
import {
  createPluginInstallsWorker,
  createQueues,
  PLUGIN_INSTALLS,
  PLUGIN_INSTALL_JOB_DEFAULTS,
  PLUGIN_INSTALL_JOB_NAME,
  pluginInstallJobSchema,
  type PluginInstallJob,
  type QueueServices,
} from "./queues.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

function jobPayload(over: Partial<PluginInstallJob> = {}): PluginInstallJob {
  return {
    installId: `install-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
    userId: "user-1",
    pluginId: "acme/demo",
    mode: "install",
    source: { kind: "paste", label: "fixture", config: "{}" },
    ...over,
  };
}

// ---------------------------------------------------------------------------
// Pure contract tests — no redis needed, always run.
// ---------------------------------------------------------------------------

describe("pluginInstallJobSchema", () => {
  it("accepts a well-formed install job (source is the canonical shared shape)", () => {
    const valid = jobPayload();
    expect(pluginInstallJobSchema.safeParse(valid)).toEqual({
      success: true,
      data: valid,
    });
  });

  it("accepts an uninstall job without a source", () => {
    const valid = jobPayload({ mode: "uninstall", source: undefined });
    expect(pluginInstallJobSchema.safeParse(valid).success).toBe(true);
  });

  it("rejects a missing identity field, a bad mode, and an invalid source", () => {
    const { installId: _installId, ...missingInstallId } = jobPayload();
    expect(pluginInstallJobSchema.safeParse(missingInstallId).success).toBe(false);
    expect(
      pluginInstallJobSchema.safeParse({ ...jobPayload(), mode: "reinstall" }).success,
    ).toBe(false);
    expect(
      pluginInstallJobSchema.safeParse({
        ...jobPayload(),
        source: { kind: "github", owner: "", repo: "x" },
      }).success,
    ).toBe(false);
  });

  it("bounds installId / userId / pluginId lengths (M5 — path-segment safety)", () => {
    expect(
      pluginInstallJobSchema.safeParse(jobPayload({ installId: "i".repeat(101) })).success,
    ).toBe(false);
    expect(
      pluginInstallJobSchema.safeParse(jobPayload({ userId: "u".repeat(201) })).success,
    ).toBe(false);
    expect(
      pluginInstallJobSchema.safeParse(jobPayload({ pluginId: `${"p".repeat(199)}/x` })).success,
    ).toBe(false);
    // Exactly at the cap still parses.
    expect(
      pluginInstallJobSchema.safeParse(jobPayload({ installId: "i".repeat(100) })).success,
    ).toBe(true);
  });
});

describe("PLUGIN_INSTALLS constants", () => {
  it("pins the queue name, job name and the attempts:1 + removal defaults", () => {
    expect(PLUGIN_INSTALLS).toBe("plugin-installs");
    expect(PLUGIN_INSTALL_JOB_NAME).toBe("plugin-install");
    // HIGH-2: removal is load-bearing — BullMQ dedupes a stable jobId across
    // completed/failed states, so without these a reinstall is a silent no-op.
    expect(PLUGIN_INSTALL_JOB_DEFAULTS).toEqual({
      attempts: 1,
      removeOnComplete: true,
      removeOnFail: true,
    });
  });
});

// ---------------------------------------------------------------------------
// Real-redis round-trip (processor stub — the real processor is Task 14's
// apps/worker/src/pluginInstallProcessor.ts and is tested separately).
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_REDIS_URL)("plugin-installs queue against real redis", () => {
  // Distinct from queues.test.ts's prefix — same shared dev redis, own keys.
  const base = process.env.OVID_TEST_QUEUE_PREFIX ?? "ovid-test-queue";
  const QUEUE_PREFIX = `${base}-plugin`;
  const connection: ConnectionOptions = { url: TEST_REDIS_URL! };
  let queues: QueueServices;
  let worker: Worker<PluginInstallJob> | undefined;

  beforeAll(() => {
    queues = createQueues(connection, {
      prefix: QUEUE_PREFIX,
      withPluginInstalls: true,
    });
    expect(queues.pluginInstalls).toBeDefined();
  });

  beforeEach(async () => {
    // Only this suite's prefixed keys — never FLUSHDB (shared dev redis).
    await queues.pluginInstalls!.obliterate({ force: true });
  });

  afterEach(async () => {
    // One worker per test: two live workers on the same queue would race for
    // the same job and make the reinstall assertion non-deterministic.
    if (worker !== undefined) {
      await worker.close();
      worker = undefined;
    }
  });

  afterAll(async () => {
    if (worker !== undefined) {
      await worker.close();
      worker = undefined;
    }
    if (queues !== undefined) {
      await queues.pluginInstalls!.obliterate({ force: true });
      await queues.pluginInstalls!.close();
      await queues.agentRuns.close();
      await queues.hibernate.close();
      await queues.hydrate.close();
      await queues.schedules.close();
    }
  });

  it("createQueues is additive: no pluginInstalls queue unless opted in", async () => {
    const off = createQueues(connection, { prefix: `${QUEUE_PREFIX}-off` });
    expect(off.pluginInstalls).toBeUndefined();
    await off.agentRuns.close();
    await off.hibernate.close();
    await off.hydrate.close();
    await off.schedules.close();

    const on = createQueues(connection, {
      prefix: `${QUEUE_PREFIX}-on`,
      withPluginInstalls: true,
    });
    expect(on.pluginInstalls).toBeDefined();
    expect(on.pluginInstalls!.name).toBe(PLUGIN_INSTALLS);
    expect(on.pluginInstalls!.opts.prefix).toBe(`${QUEUE_PREFIX}-on`);
    await on.pluginInstalls!.obliterate({ force: true });
    await on.pluginInstalls!.close();
    await on.agentRuns.close();
    await on.hibernate.close();
    await on.hydrate.close();
    await on.schedules.close();
  });

  it("round-trips a priority-2 job through a real BullMQ worker", async () => {
    const processed: PluginInstallJob[] = [];
    const done = new Promise<Job<PluginInstallJob>>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("timed out waiting for plugin-install worker")),
        5_000,
      );
      worker = createPluginInstallsWorker(
        connection,
        async (job) => {
          processed.push(job.data);
          return undefined;
        },
        { prefix: QUEUE_PREFIX },
      );
      worker.once("completed", (job) => {
        clearTimeout(timer);
        resolve(job);
      });
      worker.once("failed", (_job, err) => {
        clearTimeout(timer);
        reject(err);
      });
    });

    const payload = jobPayload({ installId: "install-roundtrip-1" });
    const added = await queues.pluginInstalls!.add(
      PLUGIN_INSTALL_JOB_NAME,
      payload,
      { jobId: payload.installId, priority: 2 },
    );

    const completed = await done;
    expect(completed.id).toBe(added.id);
    expect(completed.data).toEqual(payload); // payload round-trips intact
    expect(completed.opts.priority).toBe(2);
    expect(completed.opts.attempts).toBe(1); // add-side and worker-side agree
    expect(processed).toEqual([payload]);
  });

  it("applies attempts:1 as the package default (no caller override)", async () => {
    const payload = jobPayload({ installId: "install-defaults-1" });
    await queues.pluginInstalls!.add(PLUGIN_INSTALL_JOB_NAME, payload, {
      jobId: payload.installId,
    });
    const stored = await queues.pluginInstalls!.getJob(payload.installId);
    expect(stored?.opts.attempts).toBe(1);
    expect(stored?.opts.removeOnComplete).toBe(true);
    expect(stored?.opts.removeOnFail).toBe(true);
  });

  it("HIGH-2: re-adding the SAME jobId after completion runs the processor again", async () => {
    // The gateway uses the stable row id as the job id, and `plugins.upsert`
    // keeps that id on reinstall/upgrade. Without removeOnComplete the second
    // add returned the retained completed job and the processor ran once.
    const runs: string[] = [];
    let completed = 0;
    let wake: (() => void) | undefined;

    worker = createPluginInstallsWorker(
      connection,
      async (job) => {
        runs.push(job.data.installId);
      },
      { prefix: QUEUE_PREFIX },
    );
    worker.on("completed", () => {
      completed += 1;
      wake?.();
      wake = undefined;
    });

    const awaitCompletions = async (n: number): Promise<void> => {
      const deadline = Date.now() + 5_000;
      while (completed < n) {
        if (Date.now() > deadline) {
          throw new Error(`timed out waiting for ${n} plugin-install completions`);
        }
        await new Promise<void>((resolve) => {
          wake = resolve;
          setTimeout(resolve, 100);
        });
      }
    };

    const payload = jobPayload({ installId: "stable-row-id" });
    await queues.pluginInstalls!.add(PLUGIN_INSTALL_JOB_NAME, payload, {
      jobId: payload.installId,
    });
    await awaitCompletions(1);

    // The completed record was removed, so the same jobId can be added again.
    expect(await queues.pluginInstalls!.getJob(payload.installId)).toBeUndefined();
    await queues.pluginInstalls!.add(PLUGIN_INSTALL_JOB_NAME, payload, {
      jobId: payload.installId,
    });
    await awaitCompletions(2);

    expect(runs).toEqual([payload.installId, payload.installId]);
    expect(completed).toBe(2);
  });

  it("the worker threads the caller's prefix so jobs meet", async () => {
    const w = createPluginInstallsWorker(
      connection,
      async () => undefined,
      { prefix: QUEUE_PREFIX },
    );
    expect(w.opts.prefix).toBe(QUEUE_PREFIX);
    await w.close();
  });
});
