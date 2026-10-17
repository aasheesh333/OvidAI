/**
 * P4 Task 7: the unattended-approval seam over P3's approval gate.
 *
 * P3 Task 12 exported that decision point on purpose — `createApprovalGate`'s
 * optional `timeoutPolicy(req, { unattended })` — so the scheduler lane could
 * extend it here without touching agent-core. When the scheduler fires a run
 * for a claimed `schedule_runs` occurrence, the wiring (Task 8/9's loop)
 * builds the gate's timeout policy from this hook: an approval that nobody
 * answers within UNATTENDED_APPROVAL_TIMEOUT_MS (spec §6.2 default-deny) is
 * auto-denied, the denial is ledgered on the occurrence (`auto_denied`), and
 * the user got a push BEFORE the clock ran out (onApprovalRequested).
 * Attended runs — a run no schedule_run references — are strict no-ops.
 */

import type { ApprovalTimeoutPolicy } from "@ovid/agent-core";
import { schedules, scheduleRuns, sessions, type Db } from "@ovid/db";

import type { Notifier } from "./notify.js";

/** Spec §6.2 default-deny timeout — the attended AND unattended default. */
export const UNATTENDED_APPROVAL_TIMEOUT_MS = 120_000;

export interface UnattendedApprovalHook {
  /** A schedule_run row references this run (scheduleRuns.getByRunId). */
  isUnattendedRun(runId: string): Promise<boolean>;
  /** Unattended → push the approval card (attended → no-op). */
  onApprovalRequested(
    runId: string,
    req: { toolName: string; summary: string; question?: boolean },
  ): Promise<void>;
  /** Unattended → ledger the timeout denial (attended → no-op). */
  onApprovalAutoDenied(
    runId: string,
    req: { toolName: string; summary: string },
  ): Promise<void>;
}

/** The run/schedule context a hook call needs, or null for an attended run. */
interface UnattendedContext {
  scheduleRunId: string;
  userId: string;
  sessionId: string;
}

export function createUnattendedApprovalHook(deps: {
  db: Db;
  notifier: Notifier;
}): UnattendedApprovalHook {
  async function contextFor(runId: string): Promise<UnattendedContext | null> {
    const run = await scheduleRuns.getByRunId(deps.db, runId);
    if (run === null) return null;
    // The schedule row is the only owner of userId/sessionId (the occurrence
    // references it; schedule_id cascades, so the join target always exists).
    const schedule = await schedules.getById(deps.db, run.scheduleId);
    if (schedule === null) return null;
    return {
      scheduleRunId: run.id,
      userId: schedule.userId,
      sessionId: schedule.sessionId,
    };
  }

  return {
    async isUnattendedRun(runId) {
      return (await scheduleRuns.getByRunId(deps.db, runId)) !== null;
    },

    async onApprovalRequested(runId, req) {
      try {
        const ctx = await contextFor(runId);
        if (ctx === null) return; // attended run: strictly no-op
        const session = await sessions.get(deps.db, ctx.sessionId, ctx.userId);
        await deps.notifier.notifyApprovalRequest({
          userId: ctx.userId,
          sessionId: ctx.sessionId,
          sessionTitle: session?.title ?? "",
          summary: req.summary,
          question: req.question ?? false,
        });
      } catch (err) {
        // Best-effort by contract: a push failure never breaks the approval
        // flow it is advertising.
        console.error("[unattended] approval-request push failed", err);
      }
    },

    async onApprovalAutoDenied(runId, req) {
      try {
        const ctx = await contextFor(runId);
        if (ctx === null) return; // attended run: strictly no-op
        await scheduleRuns.appendAutoDenied(deps.db, ctx.scheduleRunId, {
          toolName: req.toolName,
          summary: req.summary,
          ts: new Date().toISOString(),
        });
      } catch (err) {
        console.error("[unattended] auto-denied ledger append failed", err);
      }
    },
  };
}

/**
 * P4 Task 10 — the composition-root wiring of the hook into P3's
 * `createApprovalGate` seam.
 *
 * P3 exports exactly one per-request decision point,
 * `timeoutPolicy(req, { unattended }) => number`, and it is synchronous. The
 * hook's push/ledger methods are async and keyed by runId, which the policy
 * does not receive — so this adapter supplies the half the gate can consume:
 * unattended requests get the hook's pinned 120 s default-deny; attended
 * requests keep the env override (or the 120 s default). `undefined` means
 * "do not install a policy" (the processor is used without the hook, e.g.
 * P1/P2 tests), preserving the gate's structural attended question/plan rule.
 */
export function unattendedTimeoutPolicy(
  hook: UnattendedApprovalHook | undefined,
  attendedTimeoutMs: number,
): ApprovalTimeoutPolicy | undefined {
  if (hook === undefined) return undefined;
  return (_req, ctx) =>
    ctx.unattended ? UNATTENDED_APPROVAL_TIMEOUT_MS : attendedTimeoutMs;
}
