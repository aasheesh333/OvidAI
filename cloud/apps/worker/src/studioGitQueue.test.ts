import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * Registration is pinned WITHOUT a live Redis: bullmq's Worker is mocked so
 * the test can inspect exactly what the composition root would construct
 * (queue name, concurrency, blocking-safe connection options) and can invoke
 * the processor the worker would run.
 */
const captured = vi.hoisted(() => ({
  workers: [] as Array<{
    name: string;
    processor: (job: { data: unknown }) => Promise<unknown>;
    opts: Record<string, unknown>;
  }>,
}));

vi.mock("bullmq", () => ({
  Worker: class {
    constructor(
      name: string,
      processor: (job: { data: unknown }) => Promise<unknown>,
      opts: Record<string, unknown>,
    ) {
      captured.workers.push({ name, processor, opts });
    }
    on(): this {
      return this;
    }
    async close(): Promise<void> {}
  },
}));

import { StudioGitError } from "./studioGit.js";
import {
  STUDIO_GIT_CONCURRENCY,
  STUDIO_GIT_JOB_NAME,
  STUDIO_GIT_QUEUE,
  StudioGitJobError,
  createStudioGitJobHandler,
  createStudioGitWorker,
  parseStudioGitJob,
  studioGitJobSchema,
} from "./studioGitQueue.js";

const SYNC_RESULT = {
  status: "up_to_date" as const,
  dirty: false,
  behind: 0,
  ahead: 0,
  branch: "main",
  message: "Up to date.",
};

beforeEach(() => {
  captured.workers.length = 0;
});

describe("studio_git payload validation", () => {
  it("pins the queue and job names", () => {
    expect(STUDIO_GIT_QUEUE).toBe("studio_git");
    expect(STUDIO_GIT_JOB_NAME).toBe("studio-git");
  });

  it("accepts every supported operation and trims the payload", () => {
    expect(
      studioGitJobSchema.parse({
        op: "clone",
        userId: " u1 ",
        repo: " acme/app ",
        branch: " main ",
        dest: "app",
      }),
    ).toEqual({
      op: "clone",
      userId: "u1",
      repo: "acme/app",
      branch: "main",
      dest: "app",
    });
    expect(
      studioGitJobSchema.parse({ op: "sync", userId: "u1", repoDir: "app" }),
    ).toEqual({ op: "sync", userId: "u1", repoDir: "app" });
    expect(
      studioGitJobSchema.parse({
        op: "switch_branch",
        userId: "u1",
        repoDir: "app",
        branch: "feature",
      }),
    ).toEqual({
      op: "switch_branch",
      userId: "u1",
      repoDir: "app",
      branch: "feature",
    });
  });

  it("rejects an unknown op, missing fields and undeclared keys", () => {
    expect(studioGitJobSchema.safeParse({ op: "merge", userId: "u1" }).success).toBe(false);
    expect(studioGitJobSchema.safeParse({ op: "sync" }).success).toBe(false);
    expect(
      studioGitJobSchema.safeParse({ op: "switch_branch", userId: "u1" }).success,
    ).toBe(false);
    // Strict: a token smuggled into the payload is a validation failure.
    expect(
      studioGitJobSchema.safeParse({
        op: "sync",
        userId: "u1",
        token: "ghp_nope",
      }).success,
    ).toBe(false);
  });

  it("parseStudioGitJob throws a typed invalid_job error naming the issues", () => {
    let caught: unknown;
    try {
      parseStudioGitJob({ op: "clone" });
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(StudioGitJobError);
    expect(caught).toMatchObject({ code: "invalid_job" });
    expect((caught as StudioGitJobError).issues.length).toBeGreaterThan(0);
    expect((caught as Error).message).toContain("invalid studio_git job payload");
  });
});

describe("studio_git job handler", () => {
  it("validates BEFORE the service sees the job", async () => {
    const processor = vi.fn(async () => ({ op: "sync" as const, result: SYNC_RESULT }));
    const handler = createStudioGitJobHandler(processor);

    await expect(handler({ data: { op: "sync" } })).rejects.toMatchObject({
      code: "invalid_job",
    });
    expect(processor).not.toHaveBeenCalled();
  });

  it("dispatches the parsed job and returns the service outcome", async () => {
    const seen: unknown[] = [];
    const handler = createStudioGitJobHandler(async (job) => {
      seen.push(job);
      return { op: "sync", result: SYNC_RESULT };
    });

    const outcome = await handler({ data: { op: "sync", userId: "u1", repoDir: "app" } });
    expect(outcome).toEqual({ op: "sync", result: SYNC_RESULT });
    expect(seen).toEqual([{ op: "sync", userId: "u1", repoDir: "app" }]);
  });

  it("keeps the service's typed failure and wraps unknown throws", async () => {
    const typed = new StudioGitError("token_unavailable", "Reconnect GitHub.");
    const keeps = createStudioGitJobHandler(async () => {
      throw typed;
    });
    await expect(keeps({ data: { op: "sync", userId: "u1" } })).rejects.toBe(typed);

    const wraps = createStudioGitJobHandler(async () => {
      throw new Error("git binary missing");
    });
    await expect(wraps({ data: { op: "sync", userId: "u1" } })).rejects.toMatchObject({
      name: "StudioGitJobError",
      code: "unknown",
      message: "git binary missing",
    });
  });
});

describe("studio_git worker registration", () => {
  const processor = async () => ({ op: "sync" as const, result: SYNC_RESULT });

  it("registers on the studio_git queue with a sane concurrency and blocking-safe options", () => {
    createStudioGitWorker({
      connection: { url: "redis://127.0.0.1:6379" },
      processor,
    });

    const worker = captured.workers.at(-1)!;
    expect(worker.name).toBe("studio_git");
    expect(worker.opts["concurrency"]).toBe(STUDIO_GIT_CONCURRENCY);
    // BullMQ blocking reads must never abandon the request.
    expect(
      (worker.opts["connection"] as Record<string, unknown>)["maxRetriesPerRequest"],
    ).toBeNull();
    expect(STUDIO_GIT_CONCURRENCY).toBeGreaterThanOrEqual(1);
    expect(STUDIO_GIT_CONCURRENCY).toBeLessThanOrEqual(8);
  });

  it("honours an explicit concurrency and a queue prefix", () => {
    createStudioGitWorker({
      connection: { url: "redis://127.0.0.1:6379" },
      processor,
      concurrency: 2,
      prefix: "ovid-test-studio",
    });

    const worker = captured.workers.at(-1)!;
    expect(worker.opts).toMatchObject({
      concurrency: 2,
      prefix: "ovid-test-studio",
    });
    expect(
      (worker.opts["connection"] as Record<string, unknown>)["maxRetriesPerRequest"],
    ).toBeNull();
  });

  it("refuses an invalid concurrency instead of silently using the default", () => {
    for (const concurrency of [0, -1, 1.5]) {
      expect(() =>
        createStudioGitWorker({
          connection: { url: "redis://127.0.0.1:6379" },
          processor,
          concurrency,
        }),
      ).toThrow(/positive integer/);
    }
  });

  it("the registered processor validates and dispatches through the handler", async () => {
    createStudioGitWorker({
      connection: { url: "redis://127.0.0.1:6379" },
      processor,
    });
    const worker = captured.workers.at(-1)!;

    await expect(worker.processor({ data: { op: "nope" } })).rejects.toMatchObject({
      code: "invalid_job",
    });
    await expect(
      worker.processor({ data: { op: "sync", userId: "u1" } }),
    ).resolves.toEqual({ op: "sync", result: SYNC_RESULT });
  });
});
