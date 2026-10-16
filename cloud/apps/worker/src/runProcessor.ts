import { eventMirror, messages, runs, type Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import type { AgentRunJob } from "@ovid/queue";
import type { KeyProvider, SessionEvent, SessionEventType } from "@ovid/shared";
import {
  TerminalModelError,
  TransientModelError,
  type ChatMessage,
  type ModelTransport,
} from "./liteLlm.js";

/**
 * Agent-run processor v0: the tool-less streaming loop (plan Task 9).
 *
 * One BullMQ job = one run. The processor NEVER throws for run-level failures
 * (missing key, model errors): those are terminal run states, emitted as
 * events and recorded on the run row, and the job must COMPLETE (attempts: 1 —
 * the retry ladder lives here, not in BullMQ). Crashed/failed jobs are never
 * redelivered; the stale-run sweeper (staleRuns.ts) terminalizes runs they
 * strand in 'running'. Only infrastructure errors (db/redis down) propagate
 * and fail the job loudly.
 *
 * Event contract (every append is also mirrored to Postgres via
 * eventMirror.put — history beyond the stream's trim window):
 * - run_started        {runId}
 * - message_delta      {runId, text}          — per streamed delta, in arrival order
 * - run_started_retry  {attempt, nextBackoffMs} — attempt = the attempt ABOUT
 *   to start (2..5); emitted after a transient failure of the previous one
 * - message_completed  {messageId, content}
 * - run_completed      {runId}
 * - run_failed         {code: "key_not_minted" | "model_transient_exhausted"
 *                        | "run_queue_wait_timeout"}
 *                      | {code: "model_terminal", message}
 *   (the stale-run sweeper emits a third variant, {runId, code:"run_lost"} —
 *   see staleRuns.ts)
 *
 * Terminal events are emitted BEFORE the run row's status flip on every path
 * (completed and failed alike): the C1 wait loop below unblocks the next
 * same-session run by watching the status flip, so event-first ordering is
 * what guarantees the next run's run_started lands strictly after this run's
 * terminal event.
 */

export interface RunDeps {
  db: Db;
  events: EventLog;
  keys: KeyProvider;
  transport: ModelTransport;
  litellmBaseUrl: string;
  defaultModel: string;
  sleep?: (ms: number) => Promise<void>;
  /**
   * Cap on how long a job may wait for older active runs of the same session
   * (C1), in ms. Default DEFAULT_RUN_QUEUE_WAIT_MS; the worker entry point
   * reads OVID_RUN_QUEUE_WAIT_MS.
   */
  runQueueWaitMs?: number;
}

/** Model-call retry policy (spec §6.1): 5 attempts, backoff 3/9/27/60 s between them. */
const MAX_MODEL_ATTEMPTS = 5;
const RETRY_BACKOFF_MS: readonly number[] = [3_000, 9_000, 27_000, 60_000];

/** Context window cap for v0: newest 100 stored messages, oldest-first. */
const HISTORY_LIMIT = 100;

/**
 * C1: poll interval of the single-active-run-per-session wait loop. Real
 * wall-clock waiting in production; tests inject their own sleep.
 */
const RUN_QUEUE_POLL_MS = 250;

/**
 * C1 default: a job may wait at most 10 minutes for older same-session runs
 * before it is terminalized as failed (run_queue_wait_timeout).
 */
const DEFAULT_RUN_QUEUE_WAIT_MS = 600_000;

const defaultSleep = (ms: number): Promise<void> =>
  new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });

export function createAgentRunProcessor(
  deps: RunDeps,
): (job: { data: AgentRunJob }) => Promise<void> {
  const sleep = deps.sleep ?? defaultSleep;
  const runQueueWaitMs = deps.runQueueWaitMs ?? DEFAULT_RUN_QUEUE_WAIT_MS;

  return async (job) => {
    const { runId, sessionId, userId } = job.data;

    const emit = async (
      type: SessionEventType,
      payload: Record<string, unknown>,
    ): Promise<SessionEvent> => {
      const event = await deps.events.append(sessionId, type, payload);
      await eventMirror.put(deps.db, event);
      return event;
    };

    // ---- C1: single active run per session --------------------------------
    // This is the SEED of P3's per-session run buckets: the same guarantee
    // (at most one active run per session, oldest-first) will hold there,
    // with structured per-session scheduling replacing this poll loop.
    //
    // Worker concurrency (8) + per-run claimNext would otherwise let two
    // runs of the SAME session execute concurrently — interleaved
    // message_delta events and a wrong transcript order on the client. So
    // BEFORE claiming, wait until this run is the oldest still-active
    // (queued|running) run of its session, deterministic on (createdAt, id)
    // — runs.activeForSession orders by exactly that.
    //
    // The wait is bounded by runQueueWaitMs. A waiting job occupies a worker
    // concurrency slot (deliberate: the alternative — requeueing — would
    // multiply BullMQ jobs per run); the 10-minute cap terminalizes waiters
    // instead of deadlocking them. The run stays 'queued' while waiting, so
    // the stale-run sweeper (which only sweeps 'running') never touches it.
    //
    // Terminal-event ordering: the previous run emits its terminal event
    // BEFORE its status flip (see the file header), and this loop unblocks
    // on that flip — so run N+1's run_started is guaranteed to land strictly
    // after run N's run_completed/run_failed in the session stream.
    const waitDeadline = Date.now() + runQueueWaitMs;
    for (;;) {
      const oldest = await runs.activeForSession(deps.db, sessionId);
      if (oldest === null || oldest.id === runId) break; // we're next (or nothing to wait for)
      if (Date.now() >= waitDeadline) {
        // Cap hit: emit + mirror the failure and terminalize the run FROM
        // 'queued' (the model call is never started). finish() is conditional
        // (I4b), so an operator/sweeper that already terminalized the run
        // cannot be overwritten — only the event goes out.
        await emit("run_failed", { code: "run_queue_wait_timeout" });
        await runs.finish(deps.db, runId, "failed", "run_queue_wait_timeout");
        return; // NOT a throw: the job completes, the client sees the failure event
      }
      await sleep(RUN_QUEUE_POLL_MS);
    }

    // Race-safe claim: exactly one concurrent delivery flips queued → running.
    // false = duplicate/stale delivery (or already-finished run) → silent no-op.
    const claimed = await runs.claimNext(deps.db, runId);
    if (!claimed) return;

    const apiKey = await deps.keys.getKeyForUser(userId);
    if (apiKey === null) {
      await emit("run_failed", { code: "key_not_minted" });
      await runs.finish(deps.db, runId, "failed", "key_not_minted");
      return; // NOT a throw: the job completes, the client sees the failure event
    }

    // The gateway persisted the user prompt BEFORE enqueueing, so the stored
    // history already ends with it — load, never re-append. page() is
    // newest-first: take the newest ≤100 and walk them in reverse for the
    // oldest-first model context (controller ruling).
    const { rows } = await messages.page(deps.db, sessionId, { limit: HISTORY_LIMIT });
    const history: ChatMessage[] = [];
    for (let i = rows.length - 1; i >= 0; i -= 1) {
      const row = rows[i]!;
      // 'tool' rows cannot occur in v0 (no tools) — skip them defensively.
      if (row.role === "user" || row.role === "assistant" || row.role === "system") {
        history.push({ role: row.role, content: row.content });
      }
    }

    await emit("run_started", { runId });

    for (let attempt = 1; attempt <= MAX_MODEL_ATTEMPTS; attempt += 1) {
      await runs.bumpAttempt(deps.db, runId);

      const deltas: string[] = [];
      // onDelta is synchronous; event appends are not. Serialize them on a
      // promise chain so message_delta order matches arrival order, and drain
      // the chain before any completion/retry/failure event is emitted.
      let flushed: Promise<void> = Promise.resolve();
      // v0 wires the AbortSignal through but sets no timeout (later: per-attempt caps).
      const controller = new AbortController();

      try {
        await deps.transport.stream(
          {
            baseUrl: deps.litellmBaseUrl,
            apiKey,
            model: deps.defaultModel,
            messages: history,
          },
          {
            onDelta(text) {
              deltas.push(text);
              flushed = flushed.then(() =>
                emit("message_delta", { runId, text }).then(() => undefined),
              );
              // Mark the rejection handled NOW (transport may still be
              // streaming when an early append fails — an unawaited rejection
              // would surface as an unhandledRejection); the real error
              // resurfaces at the `await flushed` below.
              flushed.catch(() => {});
            },
          },
          controller.signal,
        );
        await flushed;

        const content = deltas.join("");
        const assistant = await messages.append(deps.db, {
          sessionId,
          role: "assistant",
          content,
        });
        await emit("message_completed", { messageId: assistant.id, content });
        // Terminal event BEFORE the status flip (see file header): the next
        // same-session run (C1 wait loop) unblocks on the flip, so this order
        // is what pins run N+1's run_started strictly after run_completed.
        await emit("run_completed", { runId });
        await runs.finish(deps.db, runId, "completed");
        return;
      } catch (err) {
        // Keep ordering: pending deltas of the failed attempt settle (or are
        // abandoned) before the retry/failure event goes out.
        await flushed.catch(() => {});

        if (err instanceof TransientModelError) {
          if (attempt >= MAX_MODEL_ATTEMPTS) {
            await emit("run_failed", { code: "model_transient_exhausted" });
            await runs.finish(deps.db, runId, "failed", err.message);
            return;
          }
          const nextBackoffMs = RETRY_BACKOFF_MS[attempt - 1]!;
          await emit("run_started_retry", { attempt: attempt + 1, nextBackoffMs });
          await sleep(nextBackoffMs);
          continue;
        }

        if (err instanceof TerminalModelError) {
          await emit("run_failed", { code: "model_terminal", message: err.message });
          await runs.finish(deps.db, runId, "failed", err.message);
          return;
        }

        // Unknown/infra error (db or redis down, consumer bug): fail the job
        // loudly. With attempts:1 the job stays FAILED — BullMQ never
        // redelivers it (failed ≠ stalled; stalled handling with attempts:1
        // also fails rather than redelivers), and claimNext claims 'queued'
        // rows only, so even a redelivery would no-op. Recovery is the
        // stale-run sweeper's job (staleRuns.ts): it terminalizes runs
        // stranded in 'running' with run_failed {code:"run_lost"}.
        throw err;
      }
    }
  };
}
