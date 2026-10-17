import { afterEach, describe, expect, it, vi } from "vitest";
import type { DeletionStore, Lifecycle, PublicState } from "@ovid/account";
import { startAccountDeletionSweeper } from "./accountSweep.js";

// Port of server/account/tests/test_worker.py — a durable sweep that re-reads
// due rows every pass, never lets a poison row starve later rows, and retries
// failures through the lifecycle's persisted backoff.

class FakeStore implements DeletionStore {
  dueQueue: Array<string[] | Error> = [];
  dueCalls = 0;
  async due(_now: number): Promise<string[]> {
    const next = this.dueQueue[Math.min(this.dueCalls, this.dueQueue.length - 1)];
    this.dueCalls += 1;
    if (next instanceof Error) throw next;
    return next ?? [];
  }
  locked<T>(): Promise<T> {
    throw new Error("not used");
  }
}

class FakeLifecycle {
  finalized: string[] = [];
  failFor = new Set<string>();
  async finalize(uid: string): Promise<PublicState> {
    this.finalized.push(uid);
    if (this.failFor.has(uid)) throw new Error("cleanup failed for a secret-adjacent uid");
    return { state: "deleted", delete_after: null, request_id: null };
  }
}

describe("startAccountDeletionSweeper", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("runs once at boot and finalizes every due row", async () => {
    const store = new FakeStore();
    store.dueQueue = [["alice", "bob"]];
    const lifecycle = new FakeLifecycle();
    const sweeper = startAccountDeletionSweeper({
      lifecycle: lifecycle as unknown as Lifecycle,
      store,
      intervalMs: 30_000,
    });
    await sweeper.stop();
    expect(lifecycle.finalized).toEqual(["alice", "bob"]);
  });

  it("one throwing row never stops the others and is retried on the next pass", async () => {
    vi.useFakeTimers();
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const store = new FakeStore();
    store.dueQueue = [["alice", "poison", "carol"], ["poison"]];
    const lifecycle = new FakeLifecycle();
    lifecycle.failFor.add("poison");
    const sweeper = startAccountDeletionSweeper({
      lifecycle: lifecycle as unknown as Lifecycle,
      store,
      intervalMs: 30_000,
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(lifecycle.finalized).toEqual(["alice", "poison", "carol"]);
    // No uid/credential content in the log line.
    expect(errorSpy).toHaveBeenCalled();
    for (const call of errorSpy.mock.calls) {
      expect(JSON.stringify(call)).not.toContain("poison");
    }

    await vi.advanceTimersByTimeAsync(30_000);
    expect(lifecycle.finalized).toEqual(["alice", "poison", "carol", "poison"]);
    await sweeper.stop();
  });

  it("survives a due() failure and retries on the next interval", async () => {
    vi.useFakeTimers();
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const store = new FakeStore();
    store.dueQueue = [new Error("postgres down"), ["alice"]];
    const lifecycle = new FakeLifecycle();
    const sweeper = startAccountDeletionSweeper({
      lifecycle: lifecycle as unknown as Lifecycle,
      store,
      intervalMs: 30_000,
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(lifecycle.finalized).toEqual([]);
    expect(errorSpy).toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(30_000);
    expect(lifecycle.finalized).toEqual(["alice"]);
    await sweeper.stop();
  });

  it("stop() clears the interval and awaits the in-flight pass", async () => {
    vi.useFakeTimers();
    const store = new FakeStore();
    store.dueQueue = [["alice"], ["bob"]];
    const lifecycle = new FakeLifecycle();
    const sweeper = startAccountDeletionSweeper({
      lifecycle: lifecycle as unknown as Lifecycle,
      store,
      intervalMs: 30_000,
    });
    await sweeper.stop();
    expect(lifecycle.finalized).toEqual(["alice"]);
    await vi.advanceTimersByTimeAsync(90_000);
    expect(lifecycle.finalized).toEqual(["alice"]);
  });
});
