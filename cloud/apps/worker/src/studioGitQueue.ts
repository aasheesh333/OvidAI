/**
 * BullMQ registration for the Studio git jobs (P0 "Studio credential helper",
 * worker half).
 *
 * The service (`studioGit.ts`) is transport-free; this module is the queue
 * consumer:
 *
 *  - queue name `studio_git`, job name `studio-git` (pinned constants — the
 *    gateway enqueues against the same names);
 *  - the job payload is validated with a strict zod schema BEFORE the service
 *    sees it (a malformed job fails as `invalid_job`, never half-clones);
 *  - concurrency is small on purpose: clone/fetch are network- and disk-heavy,
 *    and the box also runs the agent-run workers and their jails;
 *  - failures are typed: `StudioGitError` (from the service) keeps its
 *    machine-readable `code`, and payload failures are `StudioGitJobError`.
 *
 * The token is NOT part of the job payload. `createStudioGitProcessor` (see
 * studioGit.ts) resolves it per USER through the injected `tokenFor`, and the
 * outcome never carries it either.
 *
 * The `userId` in the payload is MAC-bound: every job must be signed with
 * OVID_INTERNAL_API_SECRET (`signStudioGitJob`) and the worker refuses
 * unsigned/tampered payloads BEFORE the service sees them. That stops a Redis
 * writer from cloning into another user's workspace.
 */

import { createHmac, timingSafeEqual } from "node:crypto";
import { Worker, type ConnectionOptions, type Job } from "bullmq";
import { z } from "zod";

import {
  StudioGitError,
  type StudioGit,
  type StudioGitErrorCode,
  type StudioGitJob,
  type StudioGitOutcome,
} from "./studioGit.js";

/** Queue name — pinned; the gateway's producer must use this exact string. */
export const STUDIO_GIT_QUEUE = "studio_git";

/** Job name callers pass to `studio_git.add(...)`. */
export const STUDIO_GIT_JOB_NAME = "studio-git";

/**
 * Default worker concurrency. Git clone/fetch are network + disk bound and
 * each invocation may spawn `git` (and its pack helpers); the storage queues
 * run at 2 for the same reason. Four leaves headroom for the agent-run
 * workers without serializing Studio behind a single slow clone.
 */
export const STUDIO_GIT_CONCURRENCY = 4;

const idSchema = z.string().trim().min(1).max(200);
const repoDirSchema = z.string().trim().min(1).max(255);
const branchSchema = z.string().trim().min(1).max(255);
const repoSchema = z.string().trim().min(1).max(2_048);

/**
 * Strict payload schema: every accepted key is declared, so a typo or a
 * future field leaking into the wrong queue fails loudly instead of being
 * silently ignored.
 */
export const studioGitJobSchema = z.discriminatedUnion("op", [
  z
    .object({
      op: z.literal("clone"),
      userId: idSchema,
      sessionId: idSchema.optional(),
      repo: repoSchema,
      branch: branchSchema.optional(),
      dest: repoDirSchema.optional(),
    })
    .strict(),
  z
    .object({
      op: z.literal("sync"),
      userId: idSchema,
      sessionId: idSchema.optional(),
      repoDir: repoDirSchema.optional(),
    })
    .strict(),
  z
    .object({
      op: z.literal("switch_branch"),
      userId: idSchema,
      sessionId: idSchema.optional(),
      repoDir: repoDirSchema.optional(),
      branch: branchSchema,
    })
    .strict(),
]);

/** A signed payload as it travels through Redis. */
export type StudioGitSignedJob = StudioGitJob & { sig: string };

const SIG_RE = /^[0-9a-f]{64}$/;

/** Deterministic JSON: flat keys in sorted order, `sig` excluded. */
function canonicalJobJson(job: Record<string, unknown>): string {
  const keys = Object.keys(job)
    .filter((key) => key !== "sig")
    .sort();
  const ordered: Record<string, unknown> = {};
  for (const key of keys) ordered[key] = job[key];
  return JSON.stringify(ordered);
}

/**
 * Producer-side signing. The gateway (or any other producer) must call this
 * with the same shared secret the worker verifies with. The payload's
 * `userId` is part of the MAC, so a Redis writer cannot clone into another
 * user's workspace even though the userId itself is not a secret.
 */
export function signStudioGitJob(job: StudioGitJob, secret: string): StudioGitSignedJob {
  if (secret === "") throw new Error("studio_git job secret must be non-empty");
  const sig = createHmac("sha256", secret)
    .update(canonicalJobJson(job as unknown as Record<string, unknown>))
    .digest("hex");
  return { ...job, sig };
}

/**
 * Consumer-side verification. Unsigned, truncated, wrong-secret or tampered
 * payloads all fail identically (constant-time compare, no oracle).
 */
export function verifyStudioGitJob(data: unknown, secret: string): StudioGitJob {
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    throw new StudioGitJobError("invalid_job", "invalid studio_git job signature");
  }
  const record = data as Record<string, unknown>;
  const sig = record.sig;
  if (typeof sig !== "string" || !SIG_RE.test(sig)) {
    throw new StudioGitJobError(
      "invalid_job",
      "missing studio_git job signature — the producer must sign the payload",
    );
  }
  const expected = createHmac("sha256", secret)
    .update(canonicalJobJson(record))
    .digest();
  const provided = Buffer.from(sig, "hex");
  if (provided.length !== expected.length || !timingSafeEqual(provided, expected)) {
    throw new StudioGitJobError("invalid_job", "invalid studio_git job signature");
  }
  const { sig: _sig, ...payload } = record;
  return parseStudioGitJob(payload);
}

export type StudioGitJobFailureCode = "invalid_job" | "unknown";

/** A typed job-level failure (payload or infrastructure, never user text). */
export class StudioGitJobError extends Error {
  readonly name = "StudioGitJobError";

  constructor(
    readonly code: StudioGitJobFailureCode,
    message: string,
    readonly issues: readonly string[] = [],
  ) {
    super(message);
  }
}

/** Parse/validate a raw BullMQ payload. Throws `StudioGitJobError`. */
export function parseStudioGitJob(data: unknown): StudioGitJob {
  const parsed = studioGitJobSchema.safeParse(data);
  if (!parsed.success) {
    const issues = parsed.error.issues.map(
      (issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`,
    );
    throw new StudioGitJobError(
      "invalid_job",
      `invalid ${STUDIO_GIT_QUEUE} job payload: ${issues.join("; ")}`,
      issues,
    );
  }
  return parsed.data as StudioGitJob;
}

/**
 * The BullMQ processor body, split out so tests can exercise validation and
 * dispatch without a live Redis connection. `job.data` is unknown on purpose:
 * the queue is the trust boundary.
 */
export function createStudioGitJobHandler(
  processor: (job: StudioGitJob) => Promise<StudioGitOutcome>,
  opts: { secret: string },
): (job: { data: unknown }) => Promise<StudioGitOutcome> {
  if (opts.secret === "") throw new Error("studio_git job secret must be non-empty");
  return async (job) => {
    // Verify BEFORE parsing: the MAC covers userId, so an unauthenticated
    // Redis writer cannot retarget a job at another user's workspace.
    const parsed = verifyStudioGitJob(job.data, opts.secret);
    try {
      return await processor(parsed);
    } catch (err) {
      // Keep the service's typed failure (its `code` is the contract); wrap
      // anything else so the queue never surfaces a bare stringly error.
      if (err instanceof StudioGitError || err instanceof StudioGitJobError) throw err;
      throw new StudioGitJobError(
        "unknown",
        err instanceof Error ? err.message : String(err),
      );
    }
  };
}

export interface StudioGitWorkerOptions {
  /** BullMQ connection OPTIONS OBJECT (a bare URL string hangs — Task 7). */
  connection: ConnectionOptions;
  processor: (job: StudioGitJob) => Promise<StudioGitOutcome>;
  /**
   * Shared HMAC secret for job signatures (OVID_INTERNAL_API_SECRET). Required:
   * without it any Redis writer could retarget a job at another user.
   */
  jobSecret: string;
  /** Defaults to STUDIO_GIT_CONCURRENCY; must be a positive integer. */
  concurrency?: number;
  /** Test/namespace prefix; must match the producer's prefix. */
  prefix?: string;
}

/**
 * BullMQ requires `maxRetriesPerRequest: null` on blocking connections; a
 * plain options object gets it applied here (same rule as @ovid/queue).
 */
function withBlockingSafeRetries(connection: ConnectionOptions): ConnectionOptions {
  if (typeof (connection as { duplicate?: unknown }).duplicate === "function") {
    return connection;
  }
  return { ...(connection as Record<string, unknown>), maxRetriesPerRequest: null } as ConnectionOptions;
}

/**
 * Create the `studio_git` consumer. `main.ts` registers it beside the other
 * processors and closes it during shutdown (before the sandbox manager, since
 * every job attaches a workspace handle).
 */
export function createStudioGitWorker(
  opts: StudioGitWorkerOptions,
): Worker<StudioGitJob> {
  const concurrency = opts.concurrency ?? STUDIO_GIT_CONCURRENCY;
  if (!Number.isInteger(concurrency) || concurrency < 1) {
    throw new Error(
      `studio_git concurrency must be a positive integer, got: ${concurrency}`,
    );
  }
  if (typeof opts.jobSecret !== "string" || opts.jobSecret === "") {
    throw new Error("studio_git jobSecret must be a non-empty string");
  }
  return new Worker<StudioGitJob>(
    STUDIO_GIT_QUEUE,
    createStudioGitJobHandler(opts.processor, { secret: opts.jobSecret }),
    {
      connection: withBlockingSafeRetries(opts.connection),
      ...(opts.prefix !== undefined ? { prefix: opts.prefix } : {}),
      concurrency,
    },
  );
}

/**
 * A producer-side queue is the gateway's (out of this package); this alias
 * exists so a caller that already holds a BullMQ `Queue` can type it without
 * re-declaring the payload shape.
 */
export type StudioGitQueueJob = StudioGitJob;

/** Convenience re-export: the service error codes a failed job may carry. */
export type { StudioGitErrorCode };
