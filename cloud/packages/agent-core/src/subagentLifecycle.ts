export const DEFAULT_SUBAGENT_MAX_RUNTIME_MS = 28_800_000;
export const SUBAGENT_CHECKPOINT_LEAD_MS = 300_000;

export interface VerifiedCheckpoint {
  checkpointId: string;
  hash: string;
  createdAt: string;
}

export type SubagentTerminalOutcome = "completed" | "failed" | "cancelled" | "timeout";

export interface SubagentReleaseResult {
  released: boolean;
  cleanupError?: string;
}

/** Injectable persisted-wall-clock + timer seam; no process start is used as attempt start. */
export interface SubagentLifecycleClock {
  now(): Date;
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(handle: unknown): void;
}

const systemClock: SubagentLifecycleClock = {
  now: () => new Date(),
  setTimeout: (callback, delayMs) => setTimeout(callback, delayMs),
  clearTimeout: (handle) => clearTimeout(handle as NodeJS.Timeout),
};

export function subagentDeadline(
  startedAt: Date,
  maxRuntimeMs: number = DEFAULT_SUBAGENT_MAX_RUNTIME_MS,
): { checkpointAt: Date; deadlineAt: Date } {
  if (!Number.isFinite(startedAt.getTime())) throw new RangeError("Invalid persisted attempt start");
  if (!Number.isFinite(maxRuntimeMs) || maxRuntimeMs <= 0) {
    throw new RangeError("Subagent runtime must be positive");
  }
  const deadlineAt = new Date(startedAt.getTime() + maxRuntimeMs);
  return {
    checkpointAt: new Date(deadlineAt.getTime() - SUBAGENT_CHECKPOINT_LEAD_MS),
    deadlineAt,
  };
}

export interface SubagentLifecycleHooks {
  /** Must return only a checkpoint whose durable persistence was verified. */
  checkpoint?(input: { attemptId: string; now: Date }): Promise<VerifiedCheckpoint | null>;
  /** Called after checkpoint() returns a verified object, never for an attempted write. */
  onCheckpoint?(input: { attemptId: string; checkpoint: VerifiedCheckpoint }): void | Promise<void>;
  cancel?(input: { attemptId: string; reason: "timeout" | "shutdown" }): void | Promise<void>;
  /** Records terminal intent for the resource adapter; it is not a success claim. */
  recordOutcome?(input: {
    attemptId: string;
    outcome: SubagentTerminalOutcome;
    error: string | null;
    checkpoint: VerifiedCheckpoint | null;
  }): void | Promise<void>;
  /** The one cleanup fence used by every outcome, admission failure, and shutdown. */
  releaseAttempt(attemptId: string): Promise<SubagentReleaseResult>;
}

export interface RunSubagentAttemptInput {
  attemptId: string;
  /** Actual persisted subagent_attempts.started_at, reused verbatim after restart. */
  startedAt: Date;
  execute(signal: AbortSignal): Promise<SubagentTerminalOutcome>;
  hooks: SubagentLifecycleHooks;
  clock?: SubagentLifecycleClock;
  signal?: AbortSignal;
  maxRuntimeMs?: number;
}

export interface SubagentLifecycleResult {
  outcome: SubagentTerminalOutcome;
  error: string | null;
  checkpoint: VerifiedCheckpoint | null;
  cleanup: SubagentReleaseResult;
}

interface ExecutionResult {
  outcome: SubagentTerminalOutcome;
  error: string | null;
  cancelReason?: "timeout" | "shutdown";
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Run one admitted attempt with a persisted 8h fence. The engine promise is
 * raced with cancellation, so even a transport that ignores AbortSignal cannot
 * postpone cleanup. Checkpointing is best-effort and never awaits past the cap.
 */
export async function runSubagentAttempt(
  input: RunSubagentAttemptInput,
): Promise<SubagentLifecycleResult> {
  const clock = input.clock ?? systemClock;
  const timing = subagentDeadline(input.startedAt, input.maxRuntimeMs);
  const controller = new AbortController();
  let terminal = false;
  let checkpointStarted = false;
  let verifiedCheckpoint: VerifiedCheckpoint | null = null;
  let checkpointTimer: unknown;
  let deadlineTimer: unknown;

  const startCheckpoint = async (): Promise<void> => {
    if (checkpointStarted || terminal || input.hooks.checkpoint === undefined) return;
    // A delayed 7h55 timer may first run at/after the hard cap. The persisted
    // deadline wins before capture is allowed to start.
    if (clock.now().getTime() >= timing.deadlineAt.getTime()) {
      triggerTimeout();
      return;
    }
    checkpointStarted = true;
    let persisted: VerifiedCheckpoint | null = null;
    try {
      persisted = await input.hooks.checkpoint({
        attemptId: input.attemptId,
        now: clock.now(),
      });
    } catch {
      return;
    }
    if (persisted === null || terminal) return;
    // Verification itself may have completed late. It is not a live checkpoint
    // result/event at or beyond 8h, even if the adapter already stored bytes.
    if (clock.now().getTime() >= timing.deadlineAt.getTime()) {
      triggerTimeout();
      return;
    }
    verifiedCheckpoint = persisted;
    try {
      await input.hooks.onCheckpoint?.({
        attemptId: input.attemptId,
        checkpoint: persisted,
      });
    } catch {
      // Event delivery cannot revoke an already verified checkpoint or delay the cap.
    }
  };

  let resolveTimeout!: (result: ExecutionResult) => void;
  const timeout = new Promise<ExecutionResult>((resolve) => {
    resolveTimeout = resolve;
  });
  const triggerTimeout = (): void => {
    if (terminal) return;
    controller.abort();
    resolveTimeout({ outcome: "timeout", error: null, cancelReason: "timeout" });
  };

  let resolveShutdown!: (result: ExecutionResult) => void;
  const shutdown = new Promise<ExecutionResult>((resolve) => {
    resolveShutdown = resolve;
  });
  const onShutdown = (): void => {
    if (terminal) return;
    controller.abort();
    resolveShutdown({ outcome: "cancelled", error: null, cancelReason: "shutdown" });
  };
  if (input.signal?.aborted === true) onShutdown();
  else input.signal?.addEventListener("abort", onShutdown, { once: true });

  const candidates: Array<Promise<ExecutionResult>> = [timeout, shutdown];
  const alreadyExpired = clock.now().getTime() >= timing.deadlineAt.getTime();
  const alreadyShutDown = input.signal?.aborted === true;
  if (alreadyExpired) {
    triggerTimeout();
  } else if (!alreadyShutDown) {
    if (clock.now().getTime() >= timing.checkpointAt.getTime()) {
      void startCheckpoint();
    } else {
      checkpointTimer = clock.setTimeout(() => {
        void startCheckpoint();
      }, timing.checkpointAt.getTime() - clock.now().getTime());
    }
    deadlineTimer = clock.setTimeout(
      triggerTimeout,
      timing.deadlineAt.getTime() - clock.now().getTime(),
    );
    const execution = Promise.resolve()
      .then(() => input.execute(controller.signal))
      .then(
        (outcome): ExecutionResult => ({ outcome, error: null }),
        (error: unknown): ExecutionResult => ({
          outcome: input.signal?.aborted === true ? "cancelled" : "failed",
          error: errorMessage(error),
          ...(input.signal?.aborted === true ? { cancelReason: "shutdown" as const } : {}),
        }),
      );
    candidates.push(execution);
  }

  let result: ExecutionResult;
  try {
    result = await Promise.race(candidates);
  } finally {
    terminal = true;
    if (checkpointTimer !== undefined) clock.clearTimeout(checkpointTimer);
    if (deadlineTimer !== undefined) clock.clearTimeout(deadlineTimer);
    input.signal?.removeEventListener("abort", onShutdown);
  }

  const cleanupErrors: string[] = [];
  let cleanup: SubagentReleaseResult = { released: false };
  try {
    if (result.cancelReason !== undefined) {
      try {
        const cancellation = input.hooks.cancel?.({
          attemptId: input.attemptId,
          reason: result.cancelReason,
        });
        // Cancellation is a signal, never a gate in front of the hard-deadline
        // cleanup fence. The worker release adapter performs its own bounded,
        // idempotent transport abort and reports any real cleanup failure.
        void Promise.resolve(cancellation).catch(() => {});
      } catch {
        cleanupErrors.push("cancel failed");
      }
    }
    try {
      await input.hooks.recordOutcome?.({
        attemptId: input.attemptId,
        outcome: result.outcome,
        error: result.error,
        checkpoint: verifiedCheckpoint,
      });
    } catch {
      cleanupErrors.push("outcome recording failed");
    }
  } finally {
    // The single terminal/admission-failure/shutdown cleanup fence.
    try {
      cleanup = await input.hooks.releaseAttempt(input.attemptId);
    } catch {
      cleanup = { released: false, cleanupError: "releaseAttempt failed" };
    }
  }
  if (cleanupErrors.length > 0) {
    cleanup = {
      ...cleanup,
      cleanupError: [...cleanupErrors, cleanup.cleanupError].filter(Boolean).join("; "),
    };
  }
  return {
    outcome: result.outcome,
    error: result.error,
    checkpoint: verifiedCheckpoint,
    cleanup,
  };
}
