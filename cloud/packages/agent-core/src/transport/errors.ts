/**
 * Model error taxonomy (spec §6.1, consumed by retry loops) — moved VERBATIM
 * from P1/P2's worker liteLlm.ts to agent-core (P3 Task 4): same names, same
 * classification. The worker's liteLlm.ts now re-exports these.
 *
 * - TransientModelError: 429, 5xx, network/socket failures, mid-stream
 *   connection resets, truncated streams (ended without [DONE]) → retryable.
 * - TerminalModelError: any other 4xx → fail the run immediately.
 * An aborted AbortSignal rejects with the abort error itself (never wrapped),
 * so callers can distinguish "we gave up" from "the model failed".
 */

export class TransientModelError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "TransientModelError";
  }
}

export class TerminalModelError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "TerminalModelError";
  }
}
