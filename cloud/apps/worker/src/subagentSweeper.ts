import type {
  SubagentResourceAttempt,
  SubagentResources,
  VerifiedCheckpoint,
} from "./subagentResources.js";

export interface SubagentSweeperDeps {
  resources: SubagentResources;
  timing(startedAt: Date): { checkpointAt: Date; deadlineAt: Date };
  now?: () => Date;
  onCheckpoint?(input: {
    attemptId: string;
    checkpoint: VerifiedCheckpoint;
  }): void | Promise<void>;
}

export interface SubagentSweepResult {
  activeChecked: number;
  cleanupRetried: number;
  cleanupFailed: number;
  checkpoints: number;
  timedOut: number;
  recoveryFailed: number;
}

/**
 * Retry only durable cleanup intents and persisted deadline work. There is no
 * deferred-request read, admission call, engine execution, or autonomous resume.
 */
export async function sweepSubagentAttempts(
  deps: SubagentSweeperDeps,
): Promise<SubagentSweepResult> {
  const now = deps.now ?? (() => new Date());
  const result: SubagentSweepResult = {
    activeChecked: 0,
    cleanupRetried: 0,
    cleanupFailed: 0,
    checkpoints: 0,
    timedOut: 0,
    recoveryFailed: 0,
  };

  // Start every pending retry independently. One hung cleanup cannot prevent a
  // different attempt's deadline task from starting.
  const pendingTasks = new Map<string, Promise<void>>();
  const pending = await deps.resources.listCleanupAttempts();
  for (const attempt of pending) {
    result.cleanupRetried += 1;
    pendingTasks.set(attempt.attemptId, (async () => {
      try {
        const cleanup = await deps.resources.retryCleanup(attempt.attemptId);
        if (cleanup.cleanupError !== undefined || !cleanup.released) result.cleanupFailed += 1;
      } catch {
        result.cleanupFailed += 1;
      }
    })());
  }

  const activeTask = (async (): Promise<void> => {
    const active: SubagentResourceAttempt[] = [];
    let afterId: string | undefined;
    for (;;) {
      const page = await deps.resources.listActiveAttempts(100, afterId);
      active.push(...page);
      if (page.length < 100) break;
      afterId = page[page.length - 1]!.attemptId;
    }
    result.activeChecked = active.length;
    await Promise.all(active.map(async (listed) => {
      if (deps.resources.hasPendingOutcome(listed.attemptId)) {
        result.cleanupRetried += 1;
        try {
          const cleanup = await deps.resources.releaseAttempt(listed.attemptId);
          if (cleanup.cleanupError !== undefined || !cleanup.released) result.cleanupFailed += 1;
        } catch {
          result.cleanupFailed += 1;
        }
        const current = await deps.resources.getAttempt(listed.attemptId);
        if (current === null || current.status !== "running") return;
        if (now().getTime() < deps.timing(current.startedAt).deadlineAt.getTime()) return;
      }
      // Await only this attempt's earlier pending cleanup. Other attempts keep
      // racing their own persisted deadlines independently.
      await pendingTasks.get(listed.attemptId);
      await recoverDeadline(deps, listed.attemptId, now, result);
    }));
  })();

  await Promise.all([...pendingTasks.values(), activeTask]);
  return result;
}

async function recoverDeadline(
  deps: SubagentSweeperDeps,
  attemptId: string,
  now: () => Date,
  result: SubagentSweepResult,
): Promise<void> {
  const attempt = await deps.resources.getAttempt(attemptId);
  if (attempt === null || attempt.status !== "running") return;
  const timing = deps.timing(attempt.startedAt);
  let settled = false;

  const timeoutAttempt = async (): Promise<void> => {
    if (settled) return;
    settled = true;
    try {
      // releaseAttempt performs transport abort first, then resource cleanup,
      // canonical outcome persistence, and capacity release. Do not await a
      // separate cancellation hook before this hard-deadline fence.
      deps.resources.recordOutcome({
        attemptId,
        outcome: "timeout",
        error: null,
        // Undefined means "look up an actually persisted earlier checkpoint".
        // A pending/unverified capture therefore remains an honest absence.
      });
      const cleanup = await deps.resources.releaseAttempt(attemptId);
      result.timedOut += 1;
      if (cleanup.cleanupError !== undefined || !cleanup.released) result.cleanupFailed += 1;
    } catch {
      result.recoveryFailed += 1;
    }
  };

  if (now().getTime() >= timing.deadlineAt.getTime()) {
    await timeoutAttempt();
    return;
  }
  if (now().getTime() < timing.checkpointAt.getTime()) return;

  let timer: NodeJS.Timeout | undefined;
  const deadline = new Promise<void>((resolve) => {
    timer = setTimeout(() => {
      void timeoutAttempt().finally(resolve);
    }, Math.max(0, timing.deadlineAt.getTime() - now().getTime()));
  });
  const checkpoint = (async (): Promise<void> => {
    try {
      if (now().getTime() >= timing.deadlineAt.getTime()) {
        await timeoutAttempt();
        return;
      }
      const verified = await deps.resources.checkpoint({ attemptId, now: now() });
      // Capture, DB readback, and event delivery can all delay the clock. Never
      // emit or continue past the persisted cap because `now` was cached.
      if (now().getTime() >= timing.deadlineAt.getTime()) {
        await timeoutAttempt();
        return;
      }
      if (verified === null) return;
      result.checkpoints += 1;
      await deps.onCheckpoint?.({ attemptId, checkpoint: verified });
      if (now().getTime() >= timing.deadlineAt.getTime()) {
        await timeoutAttempt();
      }
    } catch {
      result.recoveryFailed += 1;
    }
  })();

  try {
    await Promise.race([checkpoint, deadline]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
