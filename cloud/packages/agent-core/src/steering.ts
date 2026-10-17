// Steering queue (P3 Task 14) — the cloud port of Dart's in-run message
// queue drain (_drainQueueIntoMsgs, lib/core/agent_service.dart
// AS:10399–10464): messages the user sent while a run was active join the
// ACTIVE run's next model request instead of waiting for a run of their own.
// Dart joins before EVERY model request (AS:12277–12281), after a final
// reply with queued msgs arrived mid-reply (AS:12505–12515) and after a tool
// round (AS:12766–12772) — Task 15's loop calls this drain at those points.
//
// CLOUD MAPPING: the queue is the `runs` table (status 'queued'), not an
// in-memory list. A queued run merged here is claimed, its ALREADY-PERSISTED
// prompt row (the gateway appends before enqueueing — messages.ts:215–244)
// becomes a user message in the active run, and the run row is terminalized
// 'completed' with a system_note run_merged event so the client sees where
// it went. The prompt row is never re-appended — Dart AS:10424 persists a
// user row because its queue is memory-only; the cloud queue is durable.
// Dart joins multi-part queue entries into ONE user row (AS:10455); each
// cloud run carries exactly one prompt, so one user row per merged run.
//
// CLAIM RACE (Review Focus #5, cloud-only — BullMQ did not exist in Dart):
// a queued run's BullMQ job can be delivered to a worker at the same moment
// the active run's loop drains it. The drain's runs.claimNext is the SAME
// conditional UPDATE (queued→running) the delivery's processor uses —
// exactly one of the two wins. If the DELIVERY wins, this drain's claim
// returns false and it skips silently (no message, no merge note, no
// finish); the delivery processes the run as its own. If the DRAIN wins,
// the delivery's claim fails and its processor no-ops (the runProcessor
// claim-false path). Inject-once / merge-once is therefore structural.
// Dart's steer / stop-and-send-now / delete-edit-of-queued legs are UI
// affordances with no cloud surface — only the inject-once, merge-once and
// claim-race semantics port.

import { messages, runs, type Db } from "@ovid/db";

import type { EventSink } from "./ports.js";
import type { AgentMessage } from "./types.js";

export interface SteeringDeps {
  db: Db;
  sink: EventSink;
}

/**
 * Drains the session's queued runs into the active run: oldest-first
 * ((createdAt, id) — the same determinism as runs.activeForSession), each
 * exactly once. Returns the injected user rows in queue order; the caller
 * appends them to the in-flight request.
 */
export async function drainQueuedRuns(
  deps: SteeringDeps,
  o: { sessionId: string; activeRunId: string },
): Promise<AgentMessage[]> {
  const queued = await runs.listQueuedForSession(deps.db, o.sessionId);
  const injected: AgentMessage[] = [];
  for (const run of queued) {
    // The repo filters status='queued'; the active-run exclusion is enforced
    // HERE (the repo signature is session-scoped, per the plan). Defensive
    // even though the engine claims the active run before the loop starts.
    if (run.id === o.activeRunId) continue;

    // Race-safe claim (conditional UPDATE queued→running): false = a
    // concurrent BullMQ delivery won this run — skip silently.
    const claimed = await runs.claimNext(deps.db, run.id);
    if (!claimed) continue;

    // The prompt row is already persisted; load it, never re-append. A
    // missing row is an integrity anomaly the gateway's
    // append-then-create order makes impossible — the claimed run is still
    // terminalized and noted (it must never strand in 'running'), but no
    // empty user row is injected.
    const promptRow = run.promptMessageId
      ? await messages.get(deps.db, run.promptMessageId)
      : null;
    if (promptRow) injected.push({ role: "user", content: promptRow.content });

    await runs.finish(deps.db, run.id, "completed");
    await deps.sink.emit("system_note", {
      code: "run_merged",
      mergedRunId: run.id,
      runId: o.activeRunId,
    });
  }
  return injected;
}
