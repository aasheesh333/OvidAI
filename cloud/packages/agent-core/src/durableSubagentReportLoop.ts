import type { Db } from "@ovid/db";

import {
  createDurableSubagentReportDrain,
  createPostgresDurableSubagentReportStore,
  durableSubagentReportMessageId,
} from "./durableSubagentReports.js";
import type { AgentMessage } from "./types.js";

export interface DurableSubagentReportLoopProjection {
  history: AgentMessage[];
  volatileRows: AgentMessage[];
}

/**
 * Remove the persisted stable report row from the in-memory request history,
 * then represent its refreshed content once in the legacy volatile position.
 * This prevents both stale-history duplication and per-turn queue replay.
 */
export function projectDurableSubagentReportsForLoop(input: {
  sessionId: string;
  history: readonly AgentMessage[];
  content: string | null;
}): DurableSubagentReportLoopProjection {
  const messageId = durableSubagentReportMessageId(input.sessionId);
  const history = input.history.filter((message) => message.id !== messageId);
  return {
    history,
    volatileRows: input.content === null
      ? []
      : [{ role: "system", content: input.content, volatile: true, id: messageId }],
  };
}

/** Production loop adapter; no legacy in-memory queue fallback exists here. */
export async function drainDurableSubagentReportsForLoop(input: {
  db: Db;
  sessionId: string;
  history: readonly AgentMessage[];
}): Promise<DurableSubagentReportLoopProjection> {
  const drain = createDurableSubagentReportDrain(
    createPostgresDurableSubagentReportStore(input.db),
  );
  const result = await drain.drain({ sessionId: input.sessionId });
  return projectDurableSubagentReportsForLoop({
    sessionId: input.sessionId,
    history: input.history,
    content: result.content,
  });
}
