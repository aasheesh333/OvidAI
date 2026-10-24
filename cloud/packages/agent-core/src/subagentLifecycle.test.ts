import { describe, expect, it } from "vitest";

import {
  DEFAULT_SUBAGENT_MAX_RUNTIME_MS,
  SUBAGENT_CHECKPOINT_LEAD_MS,
  runSubagentAttempt,
  subagentDeadline,
  type SubagentLifecycleClock,
  type VerifiedCheckpoint,
} from "./subagentLifecycle.js";

const START = Date.parse("2026-10-24T00:00:00.000Z");
const CHECKPOINT_AT = START + 7 * 60 * 60 * 1000 + 55 * 60 * 1000;
const DEADLINE = START + 8 * 60 * 60 * 1000;

interface Scheduled {
  at: number;
  callback: () => void;
}

class FakeClock implements SubagentLifecycleClock {
  private current = START;
  private sequence = 0;
  private readonly scheduled = new Map<number, Scheduled>();

  now(): Date {
    return new Date(this.current);
  }

  setTimeout(callback: () => void, delayMs: number): unknown {
    const id = ++this.sequence;
    this.scheduled.set(id, { at: this.current + Math.max(0, delayMs), callback });
    return id;
  }

  clearTimeout(handle: unknown): void {
    this.scheduled.delete(handle as number);
  }

  setNow(value: number): void {
    this.current = value;
  }

  async advanceTo(value: number): Promise<void> {
    for (;;) {
      const due = [...this.scheduled.entries()]
        .filter(([, timer]) => timer.at <= value)
        .sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
      if (due === undefined) break;
      this.scheduled.delete(due[0]);
      this.current = Math.max(this.current, due[1].at);
      due[1].callback();
      await flush();
    }
    this.current = value;
    await flush();
  }
}

async function flush(): Promise<void> {
  for (let index = 0; index < 12; index += 1) await Promise.resolve();
}

function checkpoint(id = "checkpoint-1"): VerifiedCheckpoint {
  return {
    checkpointId: id,
    hash: "sha256:test-only-checkpoint",
    createdAt: new Date(CHECKPOINT_AT).toISOString(),
  };
}

function cleanup() {
  return { released: true as const };
}

describe("subagent persisted deadline", () => {
  it("uses the 7h55 checkpoint lead and exact 8h deadline from the persisted start", () => {
    const timing = subagentDeadline(new Date(START));
    expect(DEFAULT_SUBAGENT_MAX_RUNTIME_MS).toBe(28_800_000);
    expect(SUBAGENT_CHECKPOINT_LEAD_MS).toBe(300_000);
    expect(timing.checkpointAt.toISOString()).toBe(new Date(CHECKPOINT_AT).toISOString());
    expect(timing.deadlineAt.toISOString()).toBe(new Date(DEADLINE).toISOString());
  });

  it("starts checkpointing at 7h55 and emits only after verified persistence", async () => {
    const clock = new FakeClock();
    let resolveCheckpoint!: (value: VerifiedCheckpoint) => void;
    let checkpointCalls = 0;
    const emitted: VerifiedCheckpoint[] = [];
    let signal!: AbortSignal;
    const running = runSubagentAttempt({
      attemptId: "attempt-checkpoint",
      startedAt: new Date(START),
      clock,
      execute: (abortSignal) => {
        signal = abortSignal;
        return new Promise(() => {});
      },
      hooks: {
        checkpoint: () => {
          checkpointCalls += 1;
          return new Promise<VerifiedCheckpoint>((resolve) => {
            resolveCheckpoint = resolve;
          });
        },
        onCheckpoint: ({ checkpoint: value }) => {
          emitted.push(value);
        },
        releaseAttempt: async () => cleanup(),
      },
    });
    await flush();

    await clock.advanceTo(CHECKPOINT_AT - 1);
    expect(checkpointCalls).toBe(0);
    await clock.advanceTo(CHECKPOINT_AT);
    expect(checkpointCalls).toBe(1);
    expect(emitted).toEqual([]);

    resolveCheckpoint(checkpoint());
    await flush();
    expect(emitted).toEqual([checkpoint()]);

    await clock.advanceTo(DEADLINE);
    const result = await running;
    expect(signal.aborted).toBe(true);
    expect(result.outcome).toBe("timeout");
    expect(result.checkpoint).toEqual(checkpoint());
    expect(result.cleanup).toEqual({ released: true });
  });

  it("does not start or emit a live checkpoint when a delayed timer first runs at 8h", async () => {
    const clock = new FakeClock();
    let checkpointCalls = 0;
    const emitted: VerifiedCheckpoint[] = [];
    let releaseCalls = 0;
    const running = runSubagentAttempt({
      attemptId: "attempt-delayed-checkpoint-timer",
      startedAt: new Date(START),
      clock,
      execute: () => new Promise(() => {}),
      hooks: {
        checkpoint: async () => {
          checkpointCalls += 1;
          return checkpoint();
        },
        onCheckpoint: ({ checkpoint: value }) => {
          emitted.push(value);
        },
        releaseAttempt: async () => {
          releaseCalls += 1;
          return cleanup();
        },
      },
    });
    // Simulate an event-loop stall: both due callbacks first run at the cap.
    clock.setNow(DEADLINE);
    await clock.advanceTo(DEADLINE);
    const result = await running;
    expect(result.outcome).toBe("timeout");
    expect(checkpointCalls).toBe(0);
    expect(emitted).toEqual([]);
    expect(result.checkpoint).toBeNull();
    expect(releaseCalls).toBe(1);
  });

  it("does not emit a checkpoint whose verification completes at or after 8h", async () => {
    const clock = new FakeClock();
    let resolveCheckpoint!: (value: VerifiedCheckpoint) => void;
    const emitted: VerifiedCheckpoint[] = [];
    const running = runSubagentAttempt({
      attemptId: "attempt-late-verification",
      startedAt: new Date(START),
      clock,
      execute: () => new Promise(() => {}),
      hooks: {
        checkpoint: () => new Promise<VerifiedCheckpoint>((resolve) => {
          resolveCheckpoint = resolve;
        }),
        onCheckpoint: ({ checkpoint: value }) => {
          emitted.push(value);
        },
        releaseAttempt: async () => cleanup(),
      },
    });
    await clock.advanceTo(CHECKPOINT_AT);
    clock.setNow(DEADLINE);
    resolveCheckpoint(checkpoint("late-checkpoint"));
    await flush();
    expect(emitted).toEqual([]);
    await clock.advanceTo(DEADLINE);
    const result = await running;
    expect(result.outcome).toBe("timeout");
    expect(result.checkpoint).toBeNull();
  });

  it("does not emit for a missing or failed checkpoint and never extends the 8h cleanup fence", async () => {
    for (const failure of ["null", "reject", "pending"] as const) {
      const clock = new FakeClock();
      const emitted: VerifiedCheckpoint[] = [];
      let cancelCalls = 0;
      let releaseCalls = 0;
      const running = runSubagentAttempt({
        attemptId: `attempt-${failure}`,
        startedAt: new Date(START),
        clock,
        execute: () => new Promise(() => {}),
        hooks: {
          checkpoint: async () => {
            if (failure === "null") return null;
            if (failure === "reject") throw new Error("storage unavailable");
            return new Promise<VerifiedCheckpoint | null>(() => {});
          },
          onCheckpoint: ({ checkpoint: value }) => {
            emitted.push(value);
          },
          cancel: () => {
            cancelCalls += 1;
          },
          releaseAttempt: async () => {
            releaseCalls += 1;
            return cleanup();
          },
        },
      });
      await clock.advanceTo(CHECKPOINT_AT);
      await clock.advanceTo(DEADLINE);
      const result = await running;
      expect(result.outcome).toBe("timeout");
      expect(result.checkpoint).toBeNull();
      expect(emitted).toEqual([]);
      expect(cancelCalls).toBe(1);
      expect(releaseCalls).toBe(1);
    }
  });

  it("does not let a hung cancellation hook postpone the 8h cleanup fence", async () => {
    const clock = new FakeClock();
    let releaseCalls = 0;
    const running = runSubagentAttempt({
      attemptId: "attempt-hung-cancel",
      startedAt: new Date(START),
      clock,
      execute: () => new Promise(() => {}),
      hooks: {
        cancel: () => new Promise<void>(() => {}),
        releaseAttempt: async () => {
          releaseCalls += 1;
          return cleanup();
        },
      },
    });
    await clock.advanceTo(DEADLINE);
    let timer: NodeJS.Timeout | undefined;
    const result = await Promise.race([
      running,
      new Promise<"timed-out">((resolve) => {
        timer = setTimeout(() => resolve("timed-out"), 100);
      }),
    ]).finally(() => {
      if (timer !== undefined) clearTimeout(timer);
    });
    expect(result).not.toBe("timed-out");
    if (result === "timed-out") return;
    expect(result.outcome).toBe("timeout");
    expect(releaseCalls).toBe(1);
  });

  it("recomputes the remaining deadline after restart instead of granting a new eight hours", async () => {
    const clock = new FakeClock();
    clock.setNow(DEADLINE - 60_000);
    let executeCalls = 0;
    let checkpointCalls = 0;
    const running = runSubagentAttempt({
      attemptId: "attempt-restart",
      startedAt: new Date(START),
      clock,
      execute: () => {
        executeCalls += 1;
        return new Promise(() => {});
      },
      hooks: {
        checkpoint: async () => {
          checkpointCalls += 1;
          return null;
        },
        releaseAttempt: async () => cleanup(),
      },
    });
    await flush();
    expect(executeCalls).toBe(1);
    expect(checkpointCalls).toBe(1);
    await clock.advanceTo(DEADLINE - 1);
    expect(checkpointCalls).toBe(1);
    await clock.advanceTo(DEADLINE);
    expect((await running).outcome).toBe("timeout");
  });

  it("does not start execution for an attempt already beyond its persisted deadline", async () => {
    const clock = new FakeClock();
    clock.setNow(DEADLINE + 1_000);
    let executeCalls = 0;
    let releaseCalls = 0;
    const result = await runSubagentAttempt({
      attemptId: "attempt-expired",
      startedAt: new Date(START),
      clock,
      execute: () => {
        executeCalls += 1;
        return Promise.resolve("completed" as const);
      },
      hooks: {
        releaseAttempt: async () => {
          releaseCalls += 1;
          return cleanup();
        },
      },
    });
    expect(executeCalls).toBe(0);
    expect(result.outcome).toBe("timeout");
    expect(releaseCalls).toBe(1);
  });

  it("does not execute an attempt whose shutdown signal was already aborted", async () => {
    const clock = new FakeClock();
    const shutdown = new AbortController();
    shutdown.abort();
    let executeCalls = 0;
    let releaseCalls = 0;
    const result = await runSubagentAttempt({
      attemptId: "attempt-pre-cancelled",
      startedAt: new Date(START),
      clock,
      signal: shutdown.signal,
      execute: () => {
        executeCalls += 1;
        return new Promise(() => {});
      },
      hooks: {
        releaseAttempt: async () => {
          releaseCalls += 1;
          return cleanup();
        },
      },
    });
    expect(result.outcome).toBe("cancelled");
    expect(executeCalls).toBe(0);
    expect(releaseCalls).toBe(1);
  });

  it("cleans up after success, execution failure, admission failure, and shutdown", async () => {
    const cases = [
      { name: "success", execute: async () => "completed" as const, outcome: "completed", error: null },
      { name: "execution failure", execute: async () => { throw new Error("actual engine error"); }, outcome: "failed", error: "actual engine error" },
      { name: "admission failure", execute: async () => { throw new Error("admission failed before execution"); }, outcome: "failed", error: "admission failed before execution" },
    ] as const;
    for (const testCase of cases) {
      let releaseCalls = 0;
      const result = await runSubagentAttempt({
        attemptId: `attempt-${testCase.name}`,
        startedAt: new Date(START),
        clock: new FakeClock(),
        execute: testCase.execute,
        hooks: {
          releaseAttempt: async () => {
            releaseCalls += 1;
            return cleanup();
          },
        },
      });
      expect(result.outcome).toBe(testCase.outcome);
      expect(result.error).toBe(testCase.error);
      expect(releaseCalls).toBe(1);
    }

    const clock = new FakeClock();
    const shutdown = new AbortController();
    let releaseCalls = 0;
    const running = runSubagentAttempt({
      attemptId: "attempt-shutdown",
      startedAt: new Date(START),
      clock,
      signal: shutdown.signal,
      execute: () => new Promise(() => {}),
      hooks: {
        releaseAttempt: async () => {
          releaseCalls += 1;
          return cleanup();
        },
      },
    });
    shutdown.abort();
    expect((await running).outcome).toBe("cancelled");
    expect(releaseCalls).toBe(1);
  });

  it("reports cleanup failure without disguising the terminal outcome", async () => {
    const clock = new FakeClock();
    clock.setNow(DEADLINE);
    const result = await runSubagentAttempt({
      attemptId: "attempt-cleanup-failure",
      startedAt: new Date(START),
      clock,
      execute: () => new Promise(() => {}),
      hooks: {
        releaseAttempt: async () => ({
          released: true,
          cleanupError: "killJobs failed; retry required",
        }),
      },
    });
    expect(result.outcome).toBe("timeout");
    expect(result.cleanup).toEqual({
      released: true,
      cleanupError: "killJobs failed; retry required",
    });
  });
});
