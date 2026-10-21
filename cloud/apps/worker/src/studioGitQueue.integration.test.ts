import { Queue, type Job } from "bullmq";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import {
  STUDIO_GIT_JOB_NAME,
  STUDIO_GIT_QUEUE,
  createStudioGitWorker,
  signStudioGitJob,
  type StudioGitSignedJob,
} from "./studioGitQueue.js";
import type { StudioGitJob, StudioGitOutcome } from "./studioGit.js";

const JOB_SECRET = "studio-git-integration-secret-0123456789";

/**
 * Real BullMQ leg (skipped without TEST_REDIS_URL): proves the worker created
 * by `createStudioGitWorker` actually consumes the `studio_git` queue, hands
 * the service a validated payload, and fails a malformed job with the typed
 * `invalid_job` message.
 */
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const QUEUE_PREFIX = process.env.OVID_TEST_QUEUE_PREFIX
  ? `${process.env.OVID_TEST_QUEUE_PREFIX}-studio`
  : "ovid-test-studio";

const SYNC_RESULT = {
  status: "up_to_date" as const,
  dirty: false,
  behind: 0,
  ahead: 0,
  branch: "main",
  message: "Up to date.",
};

describe.skipIf(!TEST_REDIS_URL)("studio_git BullMQ registration (real Redis)", () => {
  const connection = { url: TEST_REDIS_URL! };
  let queue: Queue<StudioGitSignedJob>;
  let worker: ReturnType<typeof createStudioGitWorker>;
  const seen: StudioGitJob[] = [];

  beforeAll(async () => {
    queue = new Queue<StudioGitSignedJob>(STUDIO_GIT_QUEUE, {
      connection,
      prefix: QUEUE_PREFIX,
    });
    await queue.obliterate({ force: true }); // our prefix only
    worker = createStudioGitWorker({
      connection,
      prefix: QUEUE_PREFIX,
      jobSecret: JOB_SECRET,
      concurrency: 2,
      processor: async (job): Promise<StudioGitOutcome> => {
        seen.push(job);
        return { op: "sync", result: SYNC_RESULT };
      },
    });
  });

  afterAll(async () => {
    await worker?.close();
    await queue?.obliterate({ force: true });
    await queue?.close();
  });

  function settled(kind: "completed" | "failed"): Promise<{ job: Job<StudioGitSignedJob>; err?: Error }> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`timed out waiting for a ${kind} job`)),
        15_000,
      );
      if (kind === "failed") {
        worker.once(
          "failed",
          (job: Job<StudioGitSignedJob> | undefined, err: Error) => {
            clearTimeout(timer);
            if (job === undefined) reject(new Error("failed event carried no job"));
            else resolve({ job, err });
          },
        );
      } else {
        worker.once("completed", (job: Job<StudioGitSignedJob>) => {
          clearTimeout(timer);
          resolve({ job });
        });
      }
    });
  }

  it("consumes a job added to studio_git and returns the typed outcome", async () => {
    const completion = settled("completed");
    const added = await queue.add(
      STUDIO_GIT_JOB_NAME,
      signStudioGitJob({ op: "sync", userId: "user-1", repoDir: "app" }, JOB_SECRET),
    );
    await completion;

    const job = (await queue.getJob(added.id!))!;
    expect(seen).toEqual([{ op: "sync", userId: "user-1", repoDir: "app" }]);
    expect(await job.getState()).toBe("completed");
    expect(job.returnvalue).toEqual({ op: "sync", result: SYNC_RESULT });
  });

  it("fails a malformed payload with the typed invalid_job reason", async () => {
    const failure = settled("failed");
    await queue.add(
      STUDIO_GIT_JOB_NAME,
      // userId missing, but correctly signed: the failure must come from the
      // payload schema, not the signature check.
      signStudioGitJob({ op: "sync" } as unknown as StudioGitJob, JOB_SECRET),
    );
    const { job, err } = await failure;

    expect(await job.getState()).toBe("failed");
    expect(err?.name).toBe("StudioGitJobError");
    expect((err as { code?: string }).code).toBe("invalid_job");
    expect(job.failedReason).toContain("invalid studio_git job payload");
  });
});
