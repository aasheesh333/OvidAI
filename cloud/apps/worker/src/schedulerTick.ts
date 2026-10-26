import { RunQuotaService, type Db, type QuotaBillingClass, type ScheduleRow, messages, runs, schedules, scheduleRuns, sessionState, turns, users, type Tx } from "@ovid/db";
import type { SystemBus } from "@ovid/events";
import {
  isRecurringTrigger,
  nextFireAfter,
  nextIntervalSlot,
  nextSlotAfterMissed,
  schedulePrompt,
  decideMissedRun,
} from "@ovid/shared";
import { AGENT_RUN_JOB_NAME, addScheduleMirrorJob, type QueueServices } from "@ovid/queue";
import { loadRunAccountContext, snapshotRunModelContext } from "./runAccount.js";
import { settleScheduleRuns as defaultSettle, type SettleDeps } from "./schedulerSettle.js";
import type { FinalDelivery } from "./runFinalDelivery.js";
import { recoverPendingCompactionContinuations } from "./compactionContinuation.js";

/**
 * P4 Task 8: the scheduler's firing engine — occurrence claiming, the
 * missed-run policy, and the 15 s tick loop (Dart schedule_coordinator port,
 * cloud side).
 *
 * Concurrency contract (spec §8):
 *   - ONE Postgres transaction per schedule: the schedule row is locked
 *     `FOR UPDATE SKIP LOCKED`, so two concurrent fires of the SAME schedule
 *     serialize (the loser sees the advanced `next_run_at` → `not_due`) and
 *     fires of DIFFERENT schedules never block each other.
 *   - The durable idempotency key is `schedule_runs` UNIQUE(schedule_id,
 *     scheduled_for): a claim that loses the ledger race rolls its message +
 *     run inserts back and returns `duplicate_claim` (Review Focus 1 backstop).
 *   - The queue is only a wake-up MIRROR. The row is the source of truth:
 *     `expectedScheduledFor` is checked against the locked row's `nextRunAt`
 *     (±1 ms) so a stale mirror job that lost the race resolves to `not_due`
 *     instead of double-firing (T6 review note — jobId idempotence only holds
 *     while the delayed job exists; this fire-side check is what survives a
 *     redelivered/re-created mirror).
 *
 * Post-commit side effects (enqueue, system publish, mirror re-arm) run AFTER
 * the transaction commits and in the pinned order; an enqueue failure is
 * logged loudly and never rethrown — the run row stays `queued` and Task 9's
 * settle stale path recovers the occurrence.
 */

/** The plan-pinned tick cadence (Dart: 15 s). */
export const SCHEDULER_TICK_MS = 15_000;
/** Max due schedules handled per tick pass. */
export const TICK_BATCH_LIMIT = 50;
/** Max staged model-call settlements replayed per tick pass. */
const SETTLEMENT_RECOVERY_BATCH_LIMIT = 50;

export type ModelCallSettlementQuota = Pick<
  RunQuotaService,
  "pendingSettlements" | "settleModelCall"
>;

/**
 * The scheduler's optional recovery seams. `abandonedReservations` /
 * `sweepAbandonedReservations` are optional so the preserved settlement-only
 * doubles stay valid; absent → that recovery step is skipped, exactly like the
 * other optional seams.
 */
export type ModelCallRecoveryQuota = ModelCallSettlementQuota &
  Partial<Pick<RunQuotaService, "abandonedReservations" | "sweepAbandonedReservations">>;

/**
 * R2 extends the committed recovery dependency with canonical run admission.
 * `admitRun` is optional so the preserved R1b recovery doubles (settlement
 * only) stay valid; when it is absent the canonical service on this same DB
 * admits instead, exactly like production's default.
 */
export type SchedulerQuota = ModelCallRecoveryQuota &
  Partial<Pick<RunQuotaService, "admitRun">>;

export interface SchedulerDeps {
  db: Db;
  queues: QueueServices;
  system: SystemBus;
  /** Recovery + admission; both default to the canonical service on this DB. */
  quota?: SchedulerQuota;
  /**
   * Final-response delivery recovery (run outbox). Present in the worker
   * composition (main.ts) and in tests; absent → the pass skips it, exactly
   * like the settlement recovery's optional quota seam.
   */
  finalDelivery?: Pick<FinalDelivery, "recover">;
  /** Injectable for tests; defaults to the wall clock. */
  clock?: () => Date;
}

export type FireOutcome =
  | "fired"
  | "retry_fired"
  | "skipped_next"
  | "paused"
  | "deferred_busy"
  | "duplicate_claim"
  | "not_due"
  | "not_found"
  | "quota_exhausted";

export interface TickReport {
  fired: number;
  retried: number;
  skipped: number;
  paused: number;
  deferred: number;
  duplicates: number;
}

/**
 * Raw SQL pinned to the open transaction's connection. drizzle's postgres-js
 * session keeps the transaction-scoped client on `session.client`; the worker
 * app does not (and must not) depend on drizzle-orm directly, so this is the
 * one sanctioned escape hatch for the `FOR UPDATE SKIP LOCKED` row lock the
 * repos do not expose (the brief's "or raw SQL" branch).
 */
type PinnedSql = (
  strings: TemplateStringsArray,
  ...values: unknown[]
) => Promise<Array<Record<string, unknown>>>;

function txSql(tx: Tx): PinnedSql {
  return (tx as unknown as { session: { client: PinnedSql } }).session.client;
}

/** Sentinel thrown inside the tx to force a ROLLBACK (lost the claim race). */
const CLAIM_LOST = Symbol("scheduler claim lost — rollback");

/**
 * The canonical admission authority. A recovery-only override falls back to
 * the service on this DB rather than skipping admission: an omitted injection
 * must never become an admission bypass.
 */
function admissionFor(deps: SchedulerDeps): Pick<RunQuotaService, "admitRun"> {
  const injected = deps.quota?.admitRun;
  if (injected !== undefined) {
    const quota = deps.quota!;
    return { admitRun: (input) => injected.call(quota, input) };
  }
  return new RunQuotaService(deps.db);
}

/**
 * Fire one occurrence of a schedule (retry pass first, then a new-occurrence
 * pass). `expectedScheduledFor` — what the CALLER believed `nextRunAt` was
 * when it decided this schedule is due (the tick passes the scanned row's
 * `nextRunAt`; a mirror job passes its own `scheduledFor`). NON-NULL values
 * are checked against the locked row: a mismatch means the row already moved
 * on → `not_due`. null SKIPS the guard entirely — that is how retry-driven
 * rows (next_run_at NULL) still fire.
 */
export async function fireScheduleOccurrence(
  deps: SchedulerDeps,
  scheduleId: string,
  opts?: { expectedScheduledFor?: Date | null },
): Promise<FireOutcome> {
  const now = deps.clock?.() ?? new Date();
  /** Post-commit side effects, in the pinned order. A returned outcome replaces
   * the committed one (only admission refusal does that). */
  let postCommit: (() => Promise<FireOutcome | null>) | null = null;

  /**
   * R2: capture the schedule owner's model/billing snapshot ONCE, admit the
   * run under `run:${runId}:${source}`, and only then add it to the queue.
   *
   * Admission is the canonical Ovid gate, so it must precede the queue add:
   * a refused run never reaches a worker, a provider, or a start event. The
   * occurrence and run rows were already committed above, so refusal
   * finalizes both truthfully (`quota_exhausted`) instead of leaving them
   * running. Infrastructure failures below keep the existing contract: the
   * run stays `queued` and settle's stale arm recovers it as `run_lost`.
   */
  const enqueue = async (o: {
    row: ScheduleRow;
    runId: string;
    scheduleRunId: string;
    prompt: string;
    source: "schedule_tick" | "schedule_retry";
  }): Promise<boolean> => {
    // The schedule owner is the run's initiating actor: schedules execute as
    // the owner, never as a session guest. Session preset/model (including an
    // effort suffix) and the owner's BYOK identity are captured together so
    // the nested snapshot and the admission decision cannot disagree.
    const account = await loadRunAccountContext(deps.db, o.row.userId);
    const state = await sessionState.get(deps.db, o.row.sessionId);
    const preset = account.presets(state.presetId);
    const modelContext = snapshotRunModelContext({
      actorUserId: o.row.userId,
      requestedModel: state.modelPin,
      presetModel: preset?.model ?? null,
      ...(preset?.temperature != null ? { presetTemperature: preset.temperature } : {}),
      byokKeyId: null,
      byokDefault: account.byokDefault,
    });
    const billingClass: QuotaBillingClass =
      modelContext.byokKeyId === null ? "ovid_allowance" : "byok";
    const admitted = await admissionFor(deps).admitRun({
      actorUserId: o.row.userId,
      source: o.source,
      runId: o.runId,
      idempotencyKey: `run:${o.runId}:${o.source}`,
      billingClass,
    });
    if (!admitted.ok) {
      console.error("[scheduler] run admission refused", {
        scheduleId: o.row.id,
        runId: o.runId,
        source: o.source,
        window: admitted.window,
      });
      await runs.finish(deps.db, o.runId, "failed", "quota_exhausted");
      await scheduleRuns.finish(deps.db, o.scheduleRunId, "failed", "quota_exhausted");
      return false;
    }
    try {
      const tier = (await users.ensure(deps.db, o.row.userId, null)).tier;
      await deps.queues.agentRuns.add(
        AGENT_RUN_JOB_NAME,
        {
          runId: o.runId,
          sessionId: o.row.sessionId,
          userId: o.row.userId,
          prompt: o.prompt,
          // H1 (final review): autonomy is the schedule's permission profile
          // and MUST reach the run as a mode. `mode` is the only read-only
          // gate on the run path (agent-core roster.modePolicy); without this
          // projection a `safe` schedule silently inherited the session's
          // mode — `auto` (default) mutated, `drive` ran with no prompts at
          // all. `safe` = read-only; `auto` = the explicit mutation opt-in
          // (spec §8), never widened by a `drive` session binding.
          autonomy: o.row.autonomy as "safe" | "auto",
          mode: o.row.autonomy === "safe" ? "safe" : "auto",
          // R2: the producer's identity travels with the job so the worker
          // rechecks the SAME actor/source/run/billing admission the
          // scheduler just made, and the root engine runs from this snapshot
          // instead of rebuilding one from whatever settings exist later.
          source: o.source,
          actorUserId: o.row.userId,
          provenance: "server",
          modelContext,
          // Compatibility mirror: the legacy top-level fields stay EQUAL to
          // the nested snapshot (byokModel only when the snapshot has one).
          byokKeyId: modelContext.byokKeyId,
          ...(modelContext.byokModel !== undefined
            ? { byokModel: modelContext.byokModel }
            : {}),
          schedule: {
            scheduleId: o.row.id,
            scheduleRunId: o.scheduleRunId,
            autonomy: o.row.autonomy as "safe" | "auto",
          },
        },
        { jobId: o.runId, priority: tier === "free" ? 2 : 1 },
      );
    } catch (err) {
      // Never rethrow: the occurrence IS claimed and committed — the run row
      // stays 'queued' and Task 9's settle stale path recovers it.
      console.error("[scheduler] enqueue failed", { scheduleId: o.row.id, runId: o.runId, err });
    }
    return true;
  };

  let outcome: FireOutcome;
  try {
    outcome = await deps.db.transaction(async (tx) => {
      const tdb = tx as unknown as Db;

      // Step 1: lock the pending row, or classify why we cannot.
      const locked = await txSql(tx)`SELECT id FROM schedules WHERE id = ${scheduleId} AND status = 'pending' FOR UPDATE SKIP LOCKED`;
      if (locked.length === 0) {
        // Absent → not_found. Present but not pending (paused/cancelled/…),
        // or pending but another fire currently holds the lock → not_due.
        return (await schedules.getById(tdb, scheduleId)) === null ? "not_found" : "not_due";
      }
      const row = await schedules.getById(tdb, scheduleId);
      if (row === null || row.status !== "pending") return "not_found";

      // Mirror-race guard (row is the source of truth). NON-NULL expected
      // only: null is how retry-driven rows (next_run_at NULL) get through.
      if (opts?.expectedScheduledFor != null) {
        if (
          row.nextRunAt === null ||
          Math.abs(row.nextRunAt.getTime() - opts.expectedScheduledFor.getTime()) > 1
        ) {
          return "not_due";
        }
      }

      // Step 2: retry pass FIRST — a due retry is the alternative to the
      // expectedScheduledFor path, never both.
      const retry = await scheduleRuns.claimRetryDue(tdb, scheduleId, now);
      if (retry !== null) {
        if ((await runs.activeForSession(tdb, row.sessionId)) !== null) return "deferred_busy";
        const prompt = schedulePrompt(row.title, row.description);
        const message = await messages.append(tdb, {
          sessionId: row.sessionId,
          role: "user",
          content: prompt,
        });
        // Admit through the ordering primitive, not `runs.create`: the run's
        // `created_at` is GREATEST(clock_timestamp(), session max + 1µs)
        // under the session advisory lock, so a scheduled run cannot be
        // ordered before a turn admitted while this transaction was open.
        // `defaultNow()` (transaction-start time) could, and the resulting
        // `seq`/admission disagreement drops a legitimate run as
        // `newer_turn_running`.
        const run = await turns.admit(tdb, {
          sessionId: row.sessionId,
          promptMessageId: message.id,
        });
        const claimed = await scheduleRuns.claimRetry(tdb, retry.id, run.runId, {
          sessionId: row.sessionId,
          triggerKind: row.trigger.kind,
        });
        if (claimed === null) throw CLAIM_LOST; // lost the retry race: rollback
        postCommit = async () =>
          (await enqueue({
            row,
            runId: run.runId,
            scheduleRunId: claimed!.id,
            prompt,
            source: "schedule_retry",
          }))
            ? null
            : "quota_exhausted";
        return "retry_fired";
      }

      // Step 3: new-occurrence pass.
      if (row.nextRunAt === null || row.nextRunAt.getTime() > now.getTime()) return "not_due";
      const due = row.nextRunAt;

      // Busy defers with the row untouched — NO policy applied while the
      // session is busy (Dart parity: policy applies only when free).
      if ((await runs.activeForSession(tdb, row.sessionId)) !== null) return "deferred_busy";

      const decision = decideMissedRun(row.trigger, due, now);
      if (decision === "onTime" || decision === "runNow") {
        const ranLate = decision === "runNow";
        const prompt = schedulePrompt(row.title, row.description);
        const message = await messages.append(tdb, {
          sessionId: row.sessionId,
          role: "user",
          content: prompt,
        });
        // Same admission rule as the retry pass above: ordered insert, never
        // `runs.create`'s transaction-start `defaultNow()`.
        const run = await turns.admit(tdb, {
          sessionId: row.sessionId,
          promptMessageId: message.id,
        });
        const claimed = await scheduleRuns.claim(tdb, {
          scheduleId,
          scheduledFor: due,
          runId: run.runId,
          ranLate,
          sessionId: row.sessionId,
          triggerKind: row.trigger.kind,
        });
        if (claimed === null) throw CLAIM_LOST; // ledger race: rollback message+run

        // Advance: `every` stays anchored at the occurrence; other recurring
        // triggers take their next fire after now; one-offs are done.
        const next = isRecurringTrigger(row.trigger)
          ? row.trigger.kind === "every"
            ? nextIntervalSlot(due, row.trigger.seconds, now)
            : nextFireAfter(row.trigger, now)
          : null;
        await schedules.update(tdb, scheduleId, { nextRunAt: next });

        const nextRunAt = next;
        postCommit = async () => {
          // Admission precedes the queue add (and the start event): a refused
          // occurrence is finalized as failed and announces nothing.
          if (!(await enqueue({
            row,
            runId: run.runId,
            scheduleRunId: claimed!.id,
            prompt,
            source: "schedule_tick",
          }))) {
            // The schedule keeps its committed advance, so the mirror is
            // still re-armed for the next occurrence.
            if (nextRunAt !== null) {
              await addScheduleMirrorJob(deps.queues, scheduleId, nextRunAt, now);
            }
            return "quota_exhausted";
          }
          await deps.system.publish(row.userId, {
            type: "schedule_run_started",
            scheduleId,
            ts: now.toISOString(),
            payload: {
              scheduleRunId: claimed!.id,
              runId: run.runId,
              scheduledFor: due.toISOString(),
              ranLate,
              attempt: claimed!.attempt,
            },
          });
          if (nextRunAt !== null) {
            await addScheduleMirrorJob(deps.queues, scheduleId, nextRunAt, now);
          }
          return null;
        };
        return "fired";
      }

      if (decision === "skipToNext") {
        const skipped = await scheduleRuns.recordSkip(tdb, {
          scheduleId,
          scheduledFor: due,
          sessionId: row.sessionId,
          triggerKind: row.trigger.kind,
        });
        if (skipped === null) throw CLAIM_LOST; // someone else ledgered this occurrence
        const next = nextSlotAfterMissed(row.trigger, due, now);
        await schedules.update(tdb, scheduleId, { nextRunAt: next });
        const nextRunAt = next;
        postCommit = async () => {
          await deps.system.publish(row.userId, {
            type: "schedule_updated",
            scheduleId,
            ts: now.toISOString(),
            payload: {
              reason: "skipped_missed",
              skippedFor: due.toISOString(),
              nextRunAt: nextRunAt?.toISOString() ?? null,
            },
          });
          if (nextRunAt !== null) {
            await addScheduleMirrorJob(deps.queues, scheduleId, nextRunAt, now);
          }
          return null;
        };
        return "skipped_next";
      }

      // pauseForReview (one-off, beyond grace): never fire a stale action by
      // surprise — pause and keep nextRunAt (informational; resume recomputes).
      await schedules.update(tdb, scheduleId, {
        status: "paused",
        pausedReason: "missed_beyond_grace",
      });
      postCommit = async () => {
        await deps.system.publish(row.userId, {
          type: "schedule_run_paused",
          scheduleId,
          ts: now.toISOString(),
          payload: { reason: "missed_beyond_grace", scheduledFor: due.toISOString() },
        });
        return null;
      };
      return "paused";
    });
  } catch (err) {
    if (err === CLAIM_LOST) return "duplicate_claim";
    throw err;
  }

  // TypeScript's control-flow analysis cannot see assignments made inside the
  // transaction callback and still believes the initializer's `null`; widen
  // the read back to the declared union before calling.
  const afterCommit = postCommit as (() => Promise<FireOutcome | null>) | null;
  if (afterCommit !== null) {
    const replaced = await afterCommit();
    if (replaced !== null) return replaced;
  }
  return outcome;
}

/**
 * Release holds orphaned by a process that died between the reserve and the
 * staging commit. This path has no provider call and no settlement: the row
 * has no staged usage, so nothing can be charged, but the actor's allowance is
 * still reserved. Without this pass the hold would be permanent.
 *
 * Never races a live call: `RunQuotaService.abandonedReservations` requires the
 * run to be terminal AND the hold to be older than the sweep window, and the
 * service's release refuses a row whose usage was staged meanwhile.
 */
export async function releaseAbandonedModelReservations(
  deps: SchedulerDeps,
  opts?: { now?: Date; olderThanMs?: number; limit?: number },
): Promise<void> {
  const quota = deps.quota ?? new RunQuotaService(deps.db);
  if (quota.sweepAbandonedReservations === undefined) return;
  try {
    const released = await quota.sweepAbandonedReservations({
      now: opts?.now ?? deps.clock?.() ?? new Date(),
      ...(opts?.olderThanMs === undefined ? {} : { olderThanMs: opts.olderThanMs }),
      ...(opts?.limit === undefined ? {} : { limit: opts.limit }),
    });
    if (released.length > 0) {
      console.warn("[scheduler] released abandoned model-call holds", {
        count: released.length,
      });
    }
  } catch (err) {
    // Recovery is never fatal: an unreadable batch must not stop scheduling.
    console.error("[scheduler] abandoned model-call hold sweep failed", err);
  }
}

/**
 * Replay actual facts already staged by the canonical quota service. This path
 * has no provider call: it discovers exact reservations, then settles them in
 * canonical order with a bounded sequential batch. Per-item failures stay
 * pending for a later pass. The service's user/reservation locks and settled
 * fact checks make concurrent and repeated replay idempotent across processes.
 */
export async function recoverPendingModelCallSettlements(
  deps: SchedulerDeps,
  opts?: { limit?: number },
): Promise<void> {
  const quota = deps.quota ?? new RunQuotaService(deps.db);
  const pending = await quota.pendingSettlements(
    opts?.limit ?? SETTLEMENT_RECOVERY_BATCH_LIMIT,
  );
  for (const reservation of pending) {
    try {
      await quota.settleModelCall({
        reservationId: reservation.reservationId,
        usage: reservation.usage,
      });
    } catch (err) {
      console.error("[scheduler] model usage settlement recovery failed", {
        reservationId: reservation.reservationId,
        err,
      });
    }
  }
}

/**
 * Replay run completions whose durable intent committed but whose terminal
 * events / completion push did not. Same shape as the settlement recovery
 * above: bounded sequential batch, per-item continuation, Postgres as the
 * authority (a failed item stays pending for the next pass).
 */
export async function recoverRunFinalDeliveries(
  deps: SchedulerDeps,
  opts?: { limit?: number },
): Promise<void> {
  if (deps.finalDelivery === undefined) return;
  try {
    await deps.finalDelivery.recover(opts);
  } catch (err) {
    console.error("[scheduler] final delivery recovery failed", err);
  }
}

/**
 * One tick pass: recover staged model-call usage and any fold that committed a
 * checkpoint without projecting it into the legacy replay state, replay
 * run completions whose durable delivery intent outlived their terminal
 * events/push, then claim a due batch in a short transaction (FOR UPDATE SKIP
 * LOCKED — overlapping ticks partition the set). Each schedule fires in its
 * OWN transaction. A fire that throws is caught and logged — Postgres is
 * authoritative and the next tick retries.
 */
export async function runSchedulerTick(deps: SchedulerDeps): Promise<TickReport> {
  await recoverPendingModelCallSettlements(deps);
  // Then return the allowance still held by calls whose owner died before any
  // usage could be staged. Order matters: settle first, so a staged row is
  // charged rather than released, and only then release what has no usage.
  await releaseAbandonedModelReservations(deps);
  // A crash between the compaction fold commit and the legacy-state projection
  // leaves the DB cursor ahead of `session_agent_state`. Replay the committed
  // fact here (bounded, idempotent, per-item) so the next run consumes the
  // compacted context instead of re-sending folded history.
  try {
    await recoverPendingCompactionContinuations(deps);
  } catch (err) {
    // Recovery is never fatal: an unreadable recovery batch must not stop
    // scheduling. The cursor stays authoritative for the next pass.
    console.error("[scheduler] compaction continuation recovery failed", err);
  }
  // Crash-safe final delivery (run outbox): same bounded sequential shape as
  // the settlement replay above. A pending row means "answer committed, its
  // terminal events/push not confirmed"; the row is the authority.
  await recoverRunFinalDeliveries(deps);
  const now = deps.clock?.() ?? new Date();
  const report: TickReport = {
    fired: 0,
    retried: 0,
    skipped: 0,
    paused: 0,
    deferred: 0,
    duplicates: 0,
  };
  // claimDue's lock only means something inside a transaction; commit
  // immediately so the locks never span the (slow) fire phase.
  const due = await deps.db.transaction((tx) => schedules.claimDue(tx, now, TICK_BATCH_LIMIT));

  for (const row of due) {
    try {
      const outcome = await fireScheduleOccurrence(deps, row.id, {
        expectedScheduledFor: row.nextRunAt,
      });
      switch (outcome) {
        case "fired":
          report.fired += 1;
          break;
        case "retry_fired":
          report.retried += 1;
          break;
        case "skipped_next":
          report.skipped += 1;
          break;
        case "quota_exhausted":
          // Refused by canonical admission: the occurrence is terminal, but
          // no run was enqueued and no start event was published.
          report.skipped += 1;
          break;
        case "paused":
          report.paused += 1;
          break;
        case "deferred_busy":
          report.deferred += 1;
          break;
        case "duplicate_claim":
          report.duplicates += 1;
          break;
        default:
          break; // not_due / not_found — raced; the row stays authoritative
      }
    } catch (err) {
      console.error("[scheduler] fire failed", { scheduleId: row.id, err });
    }
  }
  return report;
}

/**
 * The 15 s loop: settle (Task 9) then tick, every pass — the Dart
 * `_ticking` port. A pass still running when the next interval fires is
 * SKIPPED (overlap guard); pass errors are logged, never fatal.
 */
export interface SchedulerLoopDeps extends SchedulerDeps, SettleDeps {
  /**
   * Settle-pass override (the Task-8 forward seam, now defaulted to the real
   * Task-9 reconciler). Tests substitute a counting stub; production passes
   * the plain deps and the loop settles before every tick.
   */
  settleScheduleRuns?: (deps: SettleDeps) => Promise<number>;
}

export function startSchedulerLoop(
  deps: SchedulerLoopDeps,
  opts?: { intervalMs?: number },
): { stop(): void } {
  let ticking = false;
  const timer = setInterval(() => {
    if (ticking) return; // a pass still running → skip this interval
    ticking = true;
    void (async () => {
      try {
        await (deps.settleScheduleRuns ?? defaultSettle)(deps);
        await runSchedulerTick(deps);
      } catch (err) {
        console.error("[scheduler] pass failed", err);
      } finally {
        ticking = false;
      }
    })();
  }, opts?.intervalMs ?? SCHEDULER_TICK_MS);
  timer.unref(); // never hold the process open by itself
  return {
    stop() {
      clearInterval(timer);
    },
  };
}
