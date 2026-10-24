import {
  drainReports as drainDurableReports,
  newId,
  settleAttemptAndMaybeWake,
  type Db,
  type SubagentReportRecord,
} from "@ovid/db";
import type { StructuredSubagentReport } from "@ovid/shared";

export type SubagentResourceOutcome = "completed" | "failed" | "cancelled" | "timeout";

export interface VerifiedCheckpoint {
  checkpointId: string;
  hash: string;
  createdAt: string;
}

export interface SubagentResourceAttempt {
  attemptId: string;
  logicalWorkerId: string;
  sessionId: string;
  rootTaskRunId: string;
  childSessionId: string;
  childRunId: string;
  status: SubagentResourceOutcome | "running";
  startedAt: Date;
}

export interface SubagentCheckpointCapture {
  hash: string;
  objectRef?: string | null;
  provenance?: Record<string, unknown>;
}

export interface SubagentOutcomeReport {
  summary: string;
  structuredReport: StructuredSubagentReport;
}

export interface SubagentResources {
  checkpoint(input: { attemptId: string; now: Date }): Promise<VerifiedCheckpoint | null>;
  releaseAttempt(attemptId: string): Promise<{ released: boolean; cleanupError?: string }>;
  recordOutcome(input: {
    attemptId: string;
    outcome: SubagentResourceOutcome;
    error: string | null;
    checkpoint?: VerifiedCheckpoint | null;
    report?: SubagentOutcomeReport;
  }): void;
  cancel(input: { attemptId: string; reason: "timeout" | "shutdown" }): Promise<void>;
  retryCleanup(attemptId: string): Promise<{ released: boolean; cleanupError?: string }>;
  getAttempt(attemptId: string): Promise<SubagentResourceAttempt | null>;
  hasPendingOutcome(attemptId: string): boolean;
  listActiveAttempts(limit?: number, afterId?: string): Promise<SubagentResourceAttempt[]>;
  listCleanupAttempts(limit?: number): Promise<SubagentResourceAttempt[]>;
}

type CleanupHook = (attempt: SubagentResourceAttempt) => void | Promise<void>;

export interface SubagentResourceDeps {
  db: Db;
  captureCheckpoint?(input: {
    attemptId: string;
    now: Date;
  }): Promise<SubagentCheckpointCapture | null>;
  abortTransport?: CleanupHook;
  killJobs?: CleanupHook;
  releaseMcpLeases?: CleanupHook;
  releaseBrowserLeases?: CleanupHook;
  closeLog?: CleanupHook;
  freeCapacity?: CleanupHook;
  /** Bounds one cleanup hook; its lease remains held until the real hook settles. */
  hookTimeoutMs?: number;
}

interface PendingOutcome {
  outcome: SubagentResourceOutcome;
  error: string | null;
  checkpoint?: VerifiedCheckpoint | null;
  report?: SubagentOutcomeReport;
}

const OUTCOMES = new Set<SubagentResourceOutcome>([
  "completed",
  "failed",
  "cancelled",
  "timeout",
]);
const CLEANUP_ACTION = "subagent_cleanup";
const DEFAULT_SWEEP_LIMIT = 100;
const DEFAULT_HOOK_TIMEOUT_MS = 30_000;
const MISSING_CHECKPOINT_DISCLOSURE = "No verified checkpoint was produced.";
const REPORT_SUMMARY_LIMIT = 1_200;
const REPORT_FAILURE_LIMIT = 4_000;
const OBSERVED_MAX_ITEMS = 100;
const OBSERVED_ITEM_MAX_CHARS = 512;
const OBSERVED_LIST_MAX_BYTES = 8_192;
const OBSERVED_AGGREGATE_MAX_BYTES = 16_384;

type AttemptRow = Omit<SubagentResourceAttempt, "startedAt"> & {
  startedAt: Date | string;
};

function asDate(value: Date | string): Date {
  return value instanceof Date ? value : new Date(value);
}

function mapAttempt(row: AttemptRow): SubagentResourceAttempt {
  return { ...row, startedAt: asDate(row.startedAt) };
}

function boundedLimit(limit: number | undefined): number {
  if (limit === undefined) return DEFAULT_SWEEP_LIMIT;
  if (!Number.isInteger(limit) || limit < 1 || limit > 500) {
    throw new RangeError("Subagent sweep limit must be an integer from 1 to 500");
  }
  return limit;
}

function isOutcome(value: unknown): value is SubagentResourceOutcome {
  return typeof value === "string" && OUTCOMES.has(value as SubagentResourceOutcome);
}

function clipText(value: string, maximum: number): string {
  const text = value.trim();
  if (text.length <= maximum) return text;
  if (maximum <= 0) return "";
  if (maximum === 1) return "…";
  return `${text.slice(0, maximum - 1)}…`;
}

interface ObservedEntry {
  value: string;
  clipped: boolean;
}

function clipObserved(value: string): ObservedEntry {
  const normalized = value.trim();
  const characters = Array.from(normalized);
  if (characters.length <= OBSERVED_ITEM_MAX_CHARS) {
    return { value: normalized, clipped: false };
  }
  return {
    value: `${characters.slice(0, OBSERVED_ITEM_MAX_CHARS - 1).join("")}…`,
    clipped: true,
  };
}

function boundObserved(values: readonly string[]): {
  entries: ObservedEntry[];
  omitted: number;
} {
  const entries: ObservedEntry[] = [];
  const seen = new Set<string>();
  let omitted = 0;
  for (const raw of values) {
    const normalized = raw.trim();
    if (normalized === "" || seen.has(normalized)) continue;
    seen.add(normalized);
    const entry = clipObserved(normalized);
    if (entries.length >= OBSERVED_MAX_ITEMS) {
      omitted += 1;
      continue;
    }
    const candidate = [...entries, entry];
    if (Buffer.byteLength(JSON.stringify(candidate.map((item) => item.value)), "utf8") >
      OBSERVED_LIST_MAX_BYTES) {
      omitted += 1;
      continue;
    }
    entries.push(entry);
  }
  return { entries, omitted };
}

function normalizeStructuredReport(
  report: StructuredSubagentReport,
): StructuredSubagentReport {
  const files = boundObserved(report.files_modified);
  const artifacts = boundObserved(report.artifacts_created);
  const aggregateBytes = () => Buffer.byteLength(JSON.stringify({
    files_modified: files.entries.map((entry) => entry.value),
    artifacts_created: artifacts.entries.map((entry) => entry.value),
  }), "utf8");
  while (aggregateBytes() > OBSERVED_AGGREGATE_MAX_BYTES) {
    if (artifacts.entries.length >= files.entries.length && artifacts.entries.length > 0) {
      artifacts.entries.pop();
      artifacts.omitted += 1;
    } else if (files.entries.length > 0) {
      files.entries.pop();
      files.omitted += 1;
    } else {
      break;
    }
  }
  const clipped = [...files.entries, ...artifacts.entries]
    .filter((entry) => entry.clipped).length;
  const hasTruncation = files.omitted > 0 || artifacts.omitted > 0 || clipped > 0;
  const note = hasTruncation
    ? `Observed list truncation: ${files.omitted} files and ` +
      `${artifacts.omitted} artifacts omitted; ${clipped} observed entries clipped.`
    : "";
  const findingsBudget = report.status === "completed"
    ? REPORT_SUMMARY_LIMIT
    : REPORT_FAILURE_LIMIT;
  const suffix = note === ""
    ? ""
    : report.key_findings.trim() === ""
      ? note
      : `\n\n${note}`;
  const keyFindings = note === ""
    ? clipText(report.key_findings, findingsBudget)
    : `${clipText(report.key_findings, Math.max(0, findingsBudget - suffix.length))}${suffix}`;
  return {
    subagent_id: report.subagent_id,
    status: report.status,
    files_modified: files.entries.map((entry) => entry.value),
    artifacts_created: artifacts.entries.map((entry) => entry.value),
    key_findings: keyFindings,
    error_if_any: report.status === "timeout" && report.error_if_any === null
      ? "Timed out before finishing."
      : report.error_if_any === null
        ? null
        : clipText(report.error_if_any, REPORT_FAILURE_LIMIT),
  };
}

function normalizeReport(report: SubagentOutcomeReport): SubagentOutcomeReport {
  return {
    summary: clipText(
      report.summary,
      report.structuredReport.status === "completed"
        ? REPORT_SUMMARY_LIMIT
        : REPORT_FAILURE_LIMIT,
    ),
    structuredReport: normalizeStructuredReport(report.structuredReport),
  };
}

function withMissingCheckpointDisclosure(summary: string): string {
  if (summary.includes(MISSING_CHECKPOINT_DISCLOSURE)) {
    return clipText(summary, REPORT_FAILURE_LIMIT);
  }
  const suffix = summary.trim() === ""
    ? MISSING_CHECKPOINT_DISCLOSURE
    : `\n\n${MISSING_CHECKPOINT_DISCLOSURE}`;
  return `${clipText(summary, REPORT_FAILURE_LIMIT - suffix.length)}${suffix}`;
}

function partialFindings(summary: string): string {
  const marker = "Unverified partial work:";
  const index = summary.indexOf(marker);
  return index < 0 ? "" : clipText(summary.slice(index), REPORT_FAILURE_LIMIT);
}

interface OutstandingCleanup {
  promise: Promise<unknown>;
  settled: boolean;
}

interface CleanupLease {
  owner: string;
  finish(outstanding: readonly OutstandingCleanup[]): Promise<void>;
}

/**
 * Worker-owned adapters over Task 5's approved lifecycle rows. Cleanup intent
 * is durable before side effects; pending intents are the sweeper's only retry
 * work. This module never selects deferred requests or starts/resumes an engine.
 */
export function createSubagentResources(deps: SubagentResourceDeps): SubagentResources {
  const pending = new Map<string, PendingOutcome>();
  const releaseChains = new Map<string, Promise<unknown>>();
  let activeLeases = 0;
  const leaseWaiters: Array<() => void> = [];
  async function withLeaseSlot<T>(operation: () => Promise<T>): Promise<T> {
    if (activeLeases >= 4) {
      await new Promise<void>((resolve) => leaseWaiters.push(resolve));
    } else {
      activeLeases += 1;
    }
    try {
      return await operation();
    } finally {
      const next = leaseWaiters.shift();
      if (next === undefined) activeLeases -= 1;
      else next(); // Transfer the slot without a decrement/reacquire race.
    }
  }
  const client = deps.db.$client;
  const hookTimeoutMs = deps.hookTimeoutMs ?? DEFAULT_HOOK_TIMEOUT_MS;
  if (!Number.isInteger(hookTimeoutMs) || hookTimeoutMs < 1) {
    throw new RangeError("Subagent cleanup hook timeout must be positive");
  }
  // Drizzle intentionally installs identity serializers/parsers on $client.
  const jsonb = (value: unknown) => client.typed(JSON.stringify(value), 3802);

  async function loadAttempt(attemptId: string): Promise<SubagentResourceAttempt | null> {
    const rows = await client<[AttemptRow?]>`
      SELECT id AS "attemptId", logical_worker_id AS "logicalWorkerId",
        session_id AS "sessionId", root_task_run_id AS "rootTaskRunId",
        child_session_id AS "childSessionId", child_run_id AS "childRunId",
        status, started_at AS "startedAt"
      FROM subagent_attempts WHERE id = ${attemptId} LIMIT 1`;
    return rows[0] === undefined ? null : mapAttempt(rows[0]);
  }

  async function latestIntentOutcome(attemptId: string): Promise<SubagentResourceOutcome | null> {
    const rows = await client<[{ requestedTransition: unknown }?]>`
      SELECT requested_transition AS "requestedTransition"
      FROM subagent_control_audit
      WHERE source_attempt_id = ${attemptId} AND action = ${CLEANUP_ACTION}
        AND outcome = 'pending'
      ORDER BY created_at DESC, id DESC LIMIT 1`;
    return isOutcome(rows[0]?.requestedTransition) ? rows[0].requestedTransition : null;
  }

  async function latestCheckpoint(attemptId: string): Promise<VerifiedCheckpoint | null> {
    const rows = await client<[{ checkpointId: string; hash: string; createdAt: Date | string }?]>`
      SELECT id AS "checkpointId", hash, created_at AS "createdAt"
      FROM subagent_checkpoints WHERE attempt_id = ${attemptId}
      ORDER BY created_at DESC, id DESC LIMIT 1`;
    if (rows[0] === undefined) return null;
    return {
      checkpointId: rows[0].checkpointId,
      hash: rows[0].hash,
      createdAt: asDate(rows[0].createdAt).toISOString(),
    };
  }

  async function acquireCleanupLease(attemptId: string): Promise<CleanupLease | null> {
    const reserved = await client.reserve();
    reserved.options = client.options;
    const owner = newId();
    const key = `subagent-cleanup:${attemptId}`;
    const locked = await reserved<[{ locked: boolean }?]>`
      SELECT pg_try_advisory_lock(hashtextextended(${key}, 0)) AS locked`;
    if (locked[0]?.locked !== true) {
      await reserved.release();
      return null;
    }
    // A UUIDv7 retry cursor rotates every attempted intent behind never-tried
    // rows without requiring a global scheduler table or autonomous work queue.
    try {
      await client`
        UPDATE subagent_control_audit
        SET metadata = COALESCE(metadata, '{}'::jsonb) ||
          jsonb_build_object('retryCursor', ${owner}::text, 'leaseOwner', ${owner}::text)
        WHERE source_attempt_id = ${attemptId} AND action = ${CLEANUP_ACTION}
          AND outcome = 'pending'`;
    } catch (error) {
      try {
        await reserved`SELECT pg_advisory_unlock(hashtextextended(${key}, 0))`;
      } catch {
        // Connection release below also drops the session lock.
      }
      await reserved.release();
      throw error;
    }
    let finished = false;
    return {
      owner,
      async finish(outstanding) {
        if (finished) return;
        finished = true;
        const unlock = async (): Promise<void> => {
          try {
            await reserved`SELECT pg_advisory_unlock(hashtextextended(${key}, 0))`;
          } catch {
            // Releasing the connection also drops every session advisory lock.
          } finally {
            await reserved.release();
          }
        };
        if (outstanding.every((operation) => operation.settled)) {
          await unlock();
        } else {
          // A timed-out hook may still be running. Return bounded control to the
          // sweeper, but keep the cross-process lease until the real hook ends.
          void Promise.allSettled(outstanding.map((operation) => operation.promise)).then(unlock);
        }
      },
    };
  }

  async function ensureCleanupIntent(
    attempt: SubagentResourceAttempt,
    outcome: SubagentResourceOutcome,
    leaseOwner: string,
  ): Promise<void> {
    const existing = await client<[{ id: string }?]>`
      SELECT id FROM subagent_control_audit
      WHERE source_attempt_id = ${attempt.attemptId} AND action = ${CLEANUP_ACTION}
        AND outcome = 'pending' LIMIT 1`;
    if (existing.length > 0) return;
    await client`
      INSERT INTO subagent_control_audit
        (id, session_id, actor_run_id, root_task_run_id, logical_worker_id,
         source_attempt_id, action, decision, reason, requested_transition,
         outcome, metadata)
      VALUES
        (${newId()}, ${attempt.sessionId}, ${attempt.rootTaskRunId},
         ${attempt.rootTaskRunId}, ${attempt.logicalWorkerId}, ${attempt.attemptId},
         ${CLEANUP_ACTION}, 'retry_required', 'worker terminal cleanup',
         ${outcome}, 'pending',
         ${jsonb({ terminalOutcome: outcome, retryCursor: leaseOwner, leaseOwner })})`;
  }

  async function markCleanupIntents(
    attemptId: string,
    outcome: SubagentResourceOutcome,
    cleanupError: string | null,
  ): Promise<void> {
    if (cleanupError === null) {
      await client`
        UPDATE subagent_control_audit
        SET outcome = 'completed', decision = 'performed', reason = NULL,
          performed_transition = ${outcome},
          metadata = COALESCE(metadata, '{}'::jsonb) - 'leaseOwner'
        WHERE source_attempt_id = ${attemptId} AND action = ${CLEANUP_ACTION}
          AND outcome = 'pending'`;
    } else {
      await client`
        UPDATE subagent_control_audit
        SET reason = ${cleanupError},
          metadata = COALESCE(metadata, '{}'::jsonb) - 'leaseOwner'
        WHERE source_attempt_id = ${attemptId} AND action = ${CLEANUP_ACTION}
          AND outcome = 'pending'`;
    }
  }

  async function persistReport(
    attempt: SubagentResourceAttempt,
    canonicalOutcome: SubagentResourceOutcome,
    remembered: PendingOutcome | undefined,
  ): Promise<void> {
    const current = await client<[{ status: string; childSessionId: string; summary: string }?]>`
      SELECT status, child_session_id AS "childSessionId", summary
      FROM subagent_reports WHERE attempt_id = ${attempt.attemptId} LIMIT 1`;
    if (current[0] === undefined || current[0].status !== canonicalOutcome) return;
    const supplied = remembered?.report;
    if (
      supplied !== undefined &&
      (current[0].childSessionId !== supplied.structuredReport.subagent_id ||
        supplied.structuredReport.status !== canonicalOutcome)
    ) return;

    let checkpoint: VerifiedCheckpoint | null = null;
    if (canonicalOutcome === "timeout") {
      checkpoint = remembered?.checkpoint !== undefined
        ? remembered.checkpoint
        : await latestCheckpoint(attempt.attemptId);
    }
    const normalized = supplied === undefined ? undefined : normalizeReport(supplied);
    const summary = canonicalOutcome === "timeout" && checkpoint === null
      ? withMissingCheckpointDisclosure(normalized?.summary ?? current[0].summary)
      : normalized?.summary ?? current[0].summary;
    const structuredReport = normalized?.structuredReport ?? (
      canonicalOutcome === "timeout"
        ? normalizeStructuredReport({
            subagent_id: current[0].childSessionId,
            status: "timeout",
            files_modified: [],
            artifacts_created: [],
            key_findings: partialFindings(current[0].summary),
            error_if_any: "Timed out before finishing.",
          })
        : undefined
    );
    if (structuredReport === undefined && summary === current[0].summary) return;
    await client`
      UPDATE subagent_reports
      SET summary = ${summary},
        structured_report = ${structuredReport === undefined ? null : jsonb(structuredReport)}
      WHERE attempt_id = ${attempt.attemptId}`;
  }

  async function runCleanupStep(
    name: string,
    hook: CleanupHook | undefined,
    attempt: SubagentResourceAttempt,
    failedSteps: string[],
    outstanding: OutstandingCleanup[],
  ): Promise<void> {
    if (hook === undefined) return;
    const operation = Promise.resolve().then(() => hook(attempt));
    const tracked: OutstandingCleanup = { promise: operation, settled: false };
    void operation.then(
      () => { tracked.settled = true; },
      () => { tracked.settled = true; },
    );
    outstanding.push(tracked);
    let timer: NodeJS.Timeout | undefined;
    try {
      await Promise.race([
        operation,
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error("cleanup hook timeout")), hookTimeoutMs);
        }),
      ]);
    } catch {
      if (!failedSteps.includes(name)) failedSteps.push(name);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  }

  async function releaseNow(
    attemptId: string,
    leaseOwner: string,
    outstanding: OutstandingCleanup[],
  ): Promise<{ released: boolean; cleanupError?: string }> {
    const attempt = await loadAttempt(attemptId);
    if (attempt === null) throw new Error("Unknown subagent attempt");
    const remembered = pending.get(attemptId);
    const intended = attempt.status === "running"
      ? (await latestIntentOutcome(attemptId)) ?? remembered?.outcome ?? "failed"
      : attempt.status;

    await ensureCleanupIntent(attempt, intended, leaseOwner);
    const failedSteps: string[] = [];
    const steps: Array<[string, CleanupHook | undefined]> = [
      ["abortTransport", deps.abortTransport],
      ["killJobs", deps.killJobs],
      ["releaseMcpLeases", deps.releaseMcpLeases],
      ["releaseBrowserLeases", deps.releaseBrowserLeases],
      ["closeLog", deps.closeLog],
    ];
    for (const [name, hook] of steps) {
      await runCleanupStep(name, hook, attempt, failedSteps, outstanding);
    }

    let canonicalOutcome = intended;
    if (attempt.status === "running") {
      await settleAttemptAndMaybeWake(deps.db, { attemptId, outcome: intended });
      const settled = await loadAttempt(attemptId);
      if (settled === null || settled.status === "running") {
        throw new Error("Subagent attempt was not terminal after settlement");
      }
      canonicalOutcome = settled.status;
    }
    await persistReport(attempt, canonicalOutcome, remembered);

    let capacityReleased = true;
    const capacityFailures: string[] = [];
    await runCleanupStep(
      "freeCapacity",
      deps.freeCapacity,
      attempt,
      capacityFailures,
      outstanding,
    );
    if (capacityFailures.length > 0) {
      capacityReleased = false;
      failedSteps.push("freeCapacity");
    }
    const cleanupError = failedSteps.length === 0
      ? null
      : `cleanup failed: ${failedSteps.join(", ")}`;
    await markCleanupIntents(attemptId, canonicalOutcome, cleanupError);
    if (cleanupError === null) pending.delete(attemptId);
    return {
      released: capacityReleased,
      ...(cleanupError === null ? {} : { cleanupError }),
    };
  }

  async function releaseAttempt(attemptId: string) {
    const previous = releaseChains.get(attemptId) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(() => withLeaseSlot(async () => {
      const lease = await acquireCleanupLease(attemptId);
      if (lease === null) return { released: false, cleanupError: "cleanup lease active" };
      const outstanding: OutstandingCleanup[] = [];
      try {
        return await releaseNow(attemptId, lease.owner, outstanding);
      } finally {
        await lease.finish(outstanding);
      }
    }));
    releaseChains.set(attemptId, next);
    try {
      return await next;
    } finally {
      if (releaseChains.get(attemptId) === next) releaseChains.delete(attemptId);
    }
  }

  return {
    async checkpoint({ attemptId, now }) {
      const attempt = await loadAttempt(attemptId);
      if (attempt === null || attempt.status !== "running" || deps.captureCheckpoint === undefined) {
        return null;
      }
      const captured = await deps.captureCheckpoint({ attemptId, now });
      if (captured === null) return null;
      if (captured.hash.trim() === "") throw new Error("Checkpoint hash is required");
      // A capture that finishes after terminal cleanup cannot create/emit a new
      // checkpoint for the already-settled attempt.
      const stillRunning = await loadAttempt(attemptId);
      if (stillRunning === null || stillRunning.status !== "running") return null;
      const checkpointId = newId();
      await client`
        INSERT INTO subagent_checkpoints
          (id, session_id, logical_worker_id, attempt_id, root_task_run_id,
           hash, object_ref, provenance, verified_at, created_at)
        VALUES
          (${checkpointId}, ${attempt.sessionId}, ${attempt.logicalWorkerId},
           ${attempt.attemptId}, ${attempt.rootTaskRunId}, ${captured.hash},
           ${captured.objectRef ?? null},
           ${captured.provenance === undefined ? null : jsonb(captured.provenance)},
           ${now.toISOString()}, ${now.toISOString()})`;
      const stored = await client<[{ checkpointId: string; hash: string; createdAt: Date | string }?]>`
        SELECT id AS "checkpointId", hash, created_at AS "createdAt"
        FROM subagent_checkpoints
        WHERE id = ${checkpointId} AND attempt_id = ${attemptId} AND hash = ${captured.hash}
        LIMIT 1`;
      if (stored[0] === undefined) throw new Error("Checkpoint persistence could not be verified");
      const current = await loadAttempt(attemptId);
      if (current === null || current.status !== "running") return null;
      return {
        checkpointId: stored[0].checkpointId,
        hash: stored[0].hash,
        createdAt: asDate(stored[0].createdAt).toISOString(),
      };
    },

    releaseAttempt,
    retryCleanup: releaseAttempt,
    getAttempt: loadAttempt,

    recordOutcome(input) {
      pending.set(input.attemptId, {
        outcome: input.outcome,
        error: input.error,
        ...(input.checkpoint !== undefined ? { checkpoint: input.checkpoint } : {}),
        ...(input.report !== undefined ? { report: normalizeReport(input.report) } : {}),
      });
    },

    async cancel({ attemptId }) {
      const attempt = await loadAttempt(attemptId);
      if (attempt !== null) await deps.abortTransport?.(attempt);
    },

    hasPendingOutcome(attemptId) {
      return pending.has(attemptId);
    },

    async listActiveAttempts(limit, afterId) {
      const maximum = boundedLimit(limit);
      const rows = await client<AttemptRow[]>`
        SELECT id AS "attemptId", logical_worker_id AS "logicalWorkerId",
          session_id AS "sessionId", root_task_run_id AS "rootTaskRunId",
          child_session_id AS "childSessionId", child_run_id AS "childRunId",
          status, started_at AS "startedAt"
        FROM subagent_attempts
        WHERE status = 'running'
          AND (${afterId ?? null}::text IS NULL OR id > ${afterId ?? null})
        ORDER BY id LIMIT ${maximum}`;
      return rows.map(mapAttempt);
    },

    async listCleanupAttempts(limit) {
      const maximum = boundedLimit(limit);
      const rows = await client<AttemptRow[]>`
        SELECT * FROM (
          SELECT DISTINCT ON (a.id)
            a.id AS "attemptId", a.logical_worker_id AS "logicalWorkerId",
            a.session_id AS "sessionId", a.root_task_run_id AS "rootTaskRunId",
            a.child_session_id AS "childSessionId", a.child_run_id AS "childRunId",
            a.status, a.started_at AS "startedAt",
            COALESCE(c.metadata->>'retryCursor', c.id) AS "retryCursor",
            c.id AS "cleanupId"
          FROM subagent_control_audit c
          JOIN subagent_attempts a ON a.id = c.source_attempt_id
          WHERE c.action = ${CLEANUP_ACTION} AND c.outcome = 'pending'
          ORDER BY a.id, COALESCE(c.metadata->>'retryCursor', c.id), c.id
        ) AS cleanup_candidates
        ORDER BY "retryCursor", "cleanupId" LIMIT ${maximum}`;
      return rows.map(mapAttempt);
    },
  };
}

/** Task 5 cursor draining plus a second six-key/list bound at the read boundary. */
export async function drainReports(
  db: Db,
  input: { sessionId: string; afterId?: string; limit: number },
): Promise<{ items: SubagentReportRecord[]; nextCursor: string | null }> {
  const page = await drainDurableReports(db, input);
  return {
    nextCursor: page.nextCursor,
    items: page.items.map((item) => ({
      ...item,
      summary: clipText(
        item.summary,
        item.status === "completed" ? REPORT_SUMMARY_LIMIT : REPORT_FAILURE_LIMIT,
      ),
      ...(item.structuredReport !== undefined
        ? { structuredReport: normalizeStructuredReport(item.structuredReport) }
        : {}),
    })),
  };
}
