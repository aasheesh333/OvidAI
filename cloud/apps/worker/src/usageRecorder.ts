import type { AgentTransport } from "@ovid/agent-core";
import { runUsage, type Db } from "@ovid/db";

/**
 * Wave 3 usage ledger: a transport decorator that records one row per model
 * call (AgentResponse.usage) into `run_usage`. Strictly best-effort — a
 * recorder failure is logged and swallowed, never failing or delaying the
 * run beyond the single awaited insert. `model` is the model id REQUESTED
 * from LiteLLM (req.model), e.g. "auto".
 */

export interface UsageRecord {
  userId: string;
  sessionId: string;
  runId: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

export interface UsageRecordingOptions {
  userId: string;
  sessionId: string;
  runId: string;
  record(row: UsageRecord): Promise<unknown>;
  log?: (message: string) => void;
}

/** The production binding: per-run ids + `runUsage.record` on the worker's db. */
export function usageFor(
  db: Db,
  userId: string,
  sessionId: string,
  runId: string,
): UsageRecordingOptions {
  return { userId, sessionId, runId, record: (row) => runUsage.record(db, row) };
}

export function withUsageRecording(base: AgentTransport, o: UsageRecordingOptions): AgentTransport {
  const log = o.log ?? ((message: string) => console.warn(message));
  return {
    apiFormat: base.apiFormat,
    async stream(req, h, signal) {
      // Handlers pass through as-is (onThinkingDelta presence is preserved).
      const res = await base.stream(req, h, signal);
      const usage = res.usage;
      if (usage !== null && usage !== undefined) {
        try {
          await o.record({
            userId: o.userId,
            sessionId: o.sessionId,
            runId: o.runId,
            model: req.model,
            inputTokens: usage.inputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0,
            cacheReadTokens: usage.cacheReadTokens ?? 0,
            cacheWriteTokens: usage.cacheWriteTokens ?? 0,
          });
        } catch (err) {
          log(
            `[worker] run_usage record failed (run ${o.runId}): ${err instanceof Error ? err.message : String(err)}`,
          );
        }
      }
      return res;
    },
  };
}
