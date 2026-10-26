import { describe, expect, it, vi } from "vitest";
import { createCollabHeartbeatController } from "./collabRunLifecycle.js";

/**
 * Losing the sender lease must STOP the work, not keep writing.
 *
 * The heartbeat tick is the only signal that the lease is still ours. Once a
 * tick reports the lease is gone the controller must (a) stop ticking, (b)
 * refuse to be restarted for the same execution, and (c) never queue a
 * duplicate in-flight tick — so a second holder can never be double-written.
 * (The settlement side — a stale lease refusing `run_completed` — is covered
 * by the real-Postgres cases in collabRunLifecycle.test.ts.)
 */

function deferred<T = void>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

describe("worker losing its Collab lease stops cleanly", () => {
  it("stops ticking the moment a heartbeat reports the lease is gone", async () => {
    vi.useFakeTimers();
    try {
      let calls = 0;
      const heartbeat = vi.fn(async () => {
        calls += 1;
        return calls === 1; // first tick proves the lease, second loses it
      });
      const controller = createCollabHeartbeatController({ heartbeat });

      expect(await controller.start()).toBe(true);
      expect(controller.active).toBe(true);

      await vi.advanceTimersByTimeAsync(10_000);
      expect(heartbeat).toHaveBeenCalledTimes(2);
      expect(controller.active).toBe(false);

      // No further lease extension is attempted for a lease we no longer hold.
      await vi.advanceTimersByTimeAsync(60_000);
      expect(heartbeat).toHaveBeenCalledTimes(2);
      // And the lost execution cannot silently resume.
      expect(await controller.start()).toBe(false);
      await controller.close();
    } finally {
      vi.useRealTimers();
    }
  });

  it("never runs a duplicate in-flight tick while one heartbeat is pending", async () => {
    vi.useFakeTimers();
    try {
      const pending = deferred<boolean>();
      let calls = 0;
      const heartbeat = vi.fn(() => {
        calls += 1;
        return calls === 1 ? Promise.resolve(true) : pending.promise;
      });
      const controller = createCollabHeartbeatController({ heartbeat });
      expect(await controller.start()).toBe(true);

      await vi.advanceTimersByTimeAsync(10_000); // second tick starts, hangs
      await vi.advanceTimersByTimeAsync(30_000); // three cadences pass
      expect(heartbeat).toHaveBeenCalledTimes(2);

      // The lease is lost while the tick is in flight; stop() must drain it
      // before the caller settles, and no third tick may be queued.
      const stopped = controller.stop();
      pending.resolve(false);
      await stopped;
      await vi.advanceTimersByTimeAsync(60_000);
      expect(heartbeat).toHaveBeenCalledTimes(2);
      expect(controller.active).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps retrying cadence after a transient DB error, but never after a lost lease", async () => {
    vi.useFakeTimers();
    try {
      let calls = 0;
      const heartbeat = vi.fn(async () => {
        calls += 1;
        if (calls === 2) throw new Error("db blip");
        return true;
      });
      const onError = vi.fn();
      const controller = createCollabHeartbeatController({ heartbeat, onError });
      expect(await controller.start()).toBe(true);

      await vi.advanceTimersByTimeAsync(10_000); // throws once
      expect(onError).toHaveBeenCalledTimes(1);
      expect(controller.active).toBe(true); // a blip is not a lost lease

      await vi.advanceTimersByTimeAsync(10_000); // recovers
      expect(controller.active).toBe(true);
      expect(heartbeat).toHaveBeenCalledTimes(3);
      await controller.close();
    } finally {
      vi.useRealTimers();
    }
  });
});
