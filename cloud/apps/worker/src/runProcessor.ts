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
 * - run_failed         {code: "key_not_minted" | "model_transient_exhausted"}
 *                      | {code: "model_terminal", message}
 *   (the stale-run sweeper emits a third variant, {runId, code:"run_lost"} —
 *   see staleRuns.ts)
 */

export interface RunDeps {
  db: Db;
  events: EventLog;
  keys: KeyProvider;
  transport: ModelTransport;
  litellmBaseUrl: string;
  defaultModel: string;
  sleep?: (ms: number) => Promise<void>;
}

/** Model-call retry policy (spec §6.1): 5 attempts, backoff 3/9/27/60 s between them. */
const MAX_MODEL_ATTEMPTS = 5;
const RETRY_BACKOFF_MS: readonly number[] = [3_000, 9_000, 27_000, 60_000];

/** Context window cap for v0: newest 100 stored messages, oldest-first. */
const HISTORY_LIMIT = 100;

const defaultSleep = (ms: number): Promise<void> =>
  new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });

export function createAgentRunProcessor(
  deps: RunDeps,
): (job: { data: AgentRunJob }) => Promise<void> {
  const sleep = deps.sleep ?? defaultSleep;

  return async (job) => {
    const { runId, sessionId, userId } = job.data;

    // Race-safe claim: exactly one concurrent delivery flips queued → running.
    // false = duplicate/stale delivery (or already-finished run) → silent no-op.
    const claimed = await runs.claimNext(deps.db, runId);
    if (!claimed) return;

    const emit = async (
      type: SessionEventType,
      payload: Record<string, unknown>,
    ): Promise<SessionEvent> => {
      const event = await deps.events.append(sessionId, type, payload);
      await eventMirror.put(deps.db, event);
      return event;
    };

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
        await runs.finish(deps.db, runId, "completed");
        await emit("run_completed", { runId });
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
