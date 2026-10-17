// Agent engine (P3 Task 15) — the composition seam the worker's processor
// calls: per-session event sink, per-session run token (cancel + generation),
// and the P1 never-throw contract around the turn loop.
//
// OWNERSHIP (Dart `runEpoch` / `activeRunId`, AS:822–827, AS:12813–12857):
// exactly one live run token per session. Starting a run bumps the session's
// generation, so an OLD chain still unwinding after Stop (or after a queued
// continuation was promoted) sees `isStale()` and stops at its next await
// point instead of clobbering the successor's bookkeeping — the Dart
// ghost/duplicate-response fix. `cancel()` targets a sessionId, never "the
// active one", and returns false when that session has no live run.
//
// SINK (P1 emit parity, runProcessor.ts:172–178): every event is appended to
// the Redis session log AND mirrored to Postgres (history beyond the stream's
// trim window). The sink is built per session because the event log is
// session-scoped.
//
// NEVER-THROW (P1 contract): run-level failures are terminal states — the
// loop emits their events and flips the run row. Only infrastructure errors
// (db/redis down, composition bugs) propagate, so the worker's job fails
// loudly and the stale-run sweeper is the recovery.

import { eventMirror, type Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import type { SessionEventType } from "@ovid/shared";

import { runAgentLoop, type AgentRunJob, type LoopDeps, type LoopResult, type RunTime } from "./loop.js";
import type { EventSink } from "./ports.js";
import type { SessionMode } from "./types.js";

export interface AgentEngine {
  /**
   * Runs one job to a terminal state. `claimNext` is the CALLER's (Task 16);
   * this method never claims. Never throws for run-level failures.
   */
  run(
    job: AgentRunJob & { unattended?: boolean; autonomy?: "safe" | "auto"; mode?: SessionMode },
  ): Promise<void>;
  /** Flips the run token and aborts the in-flight transport. false = no live run. */
  cancel(sessionId: string, reason?: string): Promise<boolean>;
  activeRun(sessionId: string): { runId: string } | null;
}

export interface AgentEngineDeps extends LoopDeps {
  events: EventLog;
}

interface LiveRun {
  runId: string;
  generation: number;
  rt: RunTime;
  controller: AbortController;
}

export function createAgentEngine(deps: AgentEngineDeps): AgentEngine {
  /** sessionId → the one live run token (Dart's per-session run bucket). */
  const live = new Map<string, LiveRun>();
  /** sessionId → monotonic generation (Dart `runEpoch`). */
  const epochs = new Map<string, number>();

  function sinkFor(sessionId: string): EventSink {
    return {
      async emit(type: SessionEventType, payload: Record<string, unknown>) {
        const event = await deps.events.append(sessionId, type, payload);
        await eventMirror.put(deps.db, event);
      },
    };
  }

  return {
    async run(job): Promise<void> {
      const generation = (epochs.get(job.sessionId) ?? 0) + 1;
      epochs.set(job.sessionId, generation);

      const controller = new AbortController();
      const rt: RunTime = {
        cancelled: false,
        generation,
        signal: controller.signal,
        // A newer run (or cancel) invalidated this chain: stop at the next
        // await boundary. The loop checks this at every step it also checks
        // `cancelled`, so a stale chain can never emit into the successor.
        isStale: () => {
          const current = epochs.get(job.sessionId);
          return current !== undefined && current !== generation;
        },
      };
      live.set(job.sessionId, { runId: job.runId, generation, rt, controller });

      try {
        await runAgentLoop(
          {
            runId: job.runId,
            sessionId: job.sessionId,
            userId: job.userId,
            prompt: job.prompt,
            unattended: job.unattended ?? false,
            ...(job.autonomy !== undefined ? { autonomy: job.autonomy } : {}),
            ...(job.mode !== undefined ? { mode: job.mode } : {}),
          },
          { ...deps, sink: sinkFor(job.sessionId) },
          rt,
        );
      } catch (err) {
        // The loop maps every MODEL-level failure to a terminal event. An
        // escape here is infrastructure (db/redis down, composition bug):
        // propagate so the job fails loudly (P1 contract).
        throw err;
      } finally {
        // Only the run that still owns the bucket may clear it (Dart
        // `ownsRun`, AS:12824–12831): an old chain unwinding after Stop or a
        // promoted continuation must not hide the successor's Stop button.
        const current = live.get(job.sessionId);
        if (current !== undefined && current.generation === generation) {
          live.delete(job.sessionId);
        }
      }
    },

    async cancel(sessionId, reason): Promise<boolean> {
      const current = live.get(sessionId);
      if (current === undefined) return false;
      // Invalidate the chain AND flip the token: cancel beats a Stop-hook
      // veto structurally (fireStop receives userStopRequested).
      epochs.set(sessionId, current.generation + 1);
      current.rt.cancelled = true;
      if (reason !== undefined) current.rt.cancelReason = reason;
      current.controller.abort();
      return true;
    },

    activeRun(sessionId) {
      const current = live.get(sessionId);
      return current === undefined ? null : { runId: current.runId };
    },
  };
}

export type { LoopResult };
