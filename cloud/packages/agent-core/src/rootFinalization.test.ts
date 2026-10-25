// The new fix-round-1 ABA/CAS cases are UNEXECUTED while heavy verification is paused.
import {
  fingerprintRootFinalizationReports,
  type SubagentReportRecord,
} from "@ovid/db";
import { describe, expect, it } from "vitest";

import {
  createRootFinalizationGate,
  type RootFinalizationSnapshot,
  type RootFinalizationStore,
} from "./rootFinalization.js";

type Outcome = SubagentReportRecord["status"];
type CasMethod =
  | "beforeRootFinalResponse"
  | "settleAttemptAndMaybeWake"
  | "markRootFinalized";

interface FakeAttempt {
  attemptId: string;
  rootTaskRunId: string;
  executionEpoch: number;
  status: "running" | Outcome;
  report: SubagentReportRecord | null;
}

interface FakeRoot {
  rootTaskRunId: string;
  executionEpoch: number;
  parentActive: boolean;
  attemptIds: Set<string>;
  deferredRequestIds: Set<string>;
  finalizations: Map<number, { wakeRequested: boolean; finalized: boolean }>;
}

interface GateControl {
  entered: Promise<void>;
  released: Promise<void>;
  markEntered(): void;
  release(): void;
}

function controllableGate(): GateControl {
  let markEntered!: () => void;
  let release!: () => void;
  const entered = new Promise<void>((resolve) => { markEntered = resolve; });
  const released = new Promise<void>((resolve) => { release = resolve; });
  return { entered, released, markEntered, release };
}

/**
 * Deterministic model of Task 5's row-lock/CAS contract. Admission is serialized
 * with finalization and keeps the current epoch; the report-attempt fence
 * detects same-epoch admit -> settle ABA. Deferred requests are not attempts.
 */
class FakeRootFinalizationStore implements RootFinalizationStore {
  private readonly roots = new Map<string, FakeRoot>();
  private readonly attempts = new Map<string, FakeAttempt>();
  private readonly controls = new Map<CasMethod, GateControl>();
  private readonly failures = new Map<CasMethod, Error>();
  private reportClock = 0;
  private markCallCount = 0;

  addRoot(rootTaskRunId: string, parentActive = false): void {
    this.roots.set(rootTaskRunId, {
      rootTaskRunId,
      executionEpoch: 1,
      parentActive,
      attemptIds: new Set(),
      deferredRequestIds: new Set(),
      finalizations: new Map(),
    });
  }

  admit(
    rootTaskRunId: string,
    attemptId: string,
    expectedExecutionEpoch?: number,
  ): { admitted: true; executionEpoch: number } | {
    admitted: false;
    reason: "root_finalized" | "stale_epoch";
  } {
    const root = this.requireRoot(rootTaskRunId);
    if (root.finalizations.get(root.executionEpoch)?.finalized === true) {
      return { admitted: false, reason: "root_finalized" };
    }
    if (expectedExecutionEpoch !== undefined && expectedExecutionEpoch !== root.executionEpoch) {
      return { admitted: false, reason: "stale_epoch" };
    }
    if (this.attempts.has(attemptId)) throw new Error("duplicate attempt fixture");
    root.attemptIds.add(attemptId);
    this.attempts.set(attemptId, {
      attemptId,
      rootTaskRunId,
      executionEpoch: root.executionEpoch,
      status: "running",
      report: null,
    });
    return { admitted: true, executionEpoch: root.executionEpoch };
  }

  defer(rootTaskRunId: string, requestId: string): void {
    this.requireRoot(rootTaskRunId).deferredRequestIds.add(requestId);
  }

  pause(method: CasMethod): GateControl {
    if (this.controls.has(method)) throw new Error(`${method} is already paused`);
    const control = controllableGate();
    this.controls.set(method, control);
    return control;
  }

  failNext(method: CasMethod): void {
    this.failures.set(method, new Error(`crash before ${method} commit`));
  }

  reports(rootTaskRunId: string): RootFinalizationSnapshot["reports"] {
    return this.reportsFor(this.requireRoot(rootTaskRunId));
  }

  deferred(rootTaskRunId: string): string[] {
    return [...this.requireRoot(rootTaskRunId).deferredRequestIds].sort();
  }

  enrich(attemptId: string, summary: string): void {
    const attempt = this.attempts.get(attemptId);
    if (attempt?.report !== null && attempt?.report !== undefined) {
      attempt.report.summary = summary;
    }
  }

  markCalls(): number {
    return this.markCallCount;
  }

  wakeEpochs(rootTaskRunId: string): number[] {
    return [...this.requireRoot(rootTaskRunId).finalizations.entries()]
      .filter(([, record]) => record.wakeRequested)
      .map(([epoch]) => epoch)
      .sort((a, b) => a - b);
  }

  finalizedEpochs(rootTaskRunId: string): number[] {
    return [...this.requireRoot(rootTaskRunId).finalizations.entries()]
      .filter(([, record]) => record.finalized)
      .map(([epoch]) => epoch)
      .sort((a, b) => a - b);
  }

  async snapshotRoot(rootTaskRunId: string): Promise<RootFinalizationSnapshot | null> {
    const root = this.roots.get(rootTaskRunId);
    if (root === undefined) return null;
    return {
      rootTaskRunId,
      executionEpoch: root.executionEpoch,
      activeAttemptIds: this.activeAttempts(root).map((attempt) => attempt.attemptId),
      finalized: root.finalizations.get(root.executionEpoch)?.finalized === true,
      reports: this.reportsFor(root),
    };
  }

  async beforeRootFinalResponse(input: {
    rootTaskRunId: string;
    executionEpoch: number;
    expectedReportAttemptIds?: readonly string[];
    expectedReportFingerprint?: string;
  }): Promise<"allow" | "wait"> {
    await this.interleave("beforeRootFinalResponse");
    const root = this.roots.get(input.rootTaskRunId);
    if (root === undefined || root.executionEpoch !== input.executionEpoch) return "wait";
    if (root.finalizations.get(input.executionEpoch)?.finalized === true) return "wait";
    if (this.activeAttempts(root).length !== 0) return "wait";
    if (input.expectedReportFingerprint !== undefined) {
      const current = fingerprintRootFinalizationReports(this.reportsFor(root));
      const expectedIds = [...(input.expectedReportAttemptIds ?? [])].sort();
      const currentIds = this.reportsFor(root).map((report) => report.attemptId);
      if (current !== input.expectedReportFingerprint ||
          currentIds.length !== expectedIds.length ||
          currentIds.some((id, index) => id !== expectedIds[index])) return "wait";
    }
    return "allow";
  }

  async settleAttemptAndMaybeWake(input: {
    attemptId: string;
    outcome: Outcome;
  }): Promise<{ rootTaskRunId: string; shouldWake: boolean }> {
    await this.interleave("settleAttemptAndMaybeWake");
    const attempt = this.attempts.get(input.attemptId);
    if (attempt === undefined) throw new Error("Unknown subagent attempt");
    if (attempt.status !== "running") {
      return { rootTaskRunId: attempt.rootTaskRunId, shouldWake: false };
    }
    const root = this.requireRoot(attempt.rootTaskRunId);
    attempt.status = input.outcome;
    attempt.report = this.report(attempt, input.outcome);
    const remaining = this.activeAttempts(root)
      .filter((candidate) => candidate.executionEpoch === attempt.executionEpoch);
    let shouldWake = false;
    if (remaining.length === 0 && !root.parentActive) {
      const existing = root.finalizations.get(attempt.executionEpoch);
      if (existing === undefined) {
        root.finalizations.set(attempt.executionEpoch, {
          wakeRequested: true,
          finalized: false,
        });
        shouldWake = true;
      }
    }
    return { rootTaskRunId: attempt.rootTaskRunId, shouldWake };
  }

  async markRootFinalized(input: {
    rootTaskRunId: string;
    executionEpoch: number;
    activeAttemptIds: readonly string[];
    expectedReportAttemptIds: readonly string[];
    expectedReportFingerprint: string;
  }): Promise<"committed" | "fenced"> {
    this.markCallCount += 1;
    await this.interleave("markRootFinalized");
    const root = this.roots.get(input.rootTaskRunId);
    if (root === undefined || root.executionEpoch !== input.executionEpoch) return "fenced";
    const currentIds = this.activeAttempts(root).map((attempt) => attempt.attemptId);
    const suppliedIds = [...input.activeAttemptIds].sort();
    if (
      currentIds.length !== 0 ||
      currentIds.length !== suppliedIds.length ||
      currentIds.some((id, index) => id !== suppliedIds[index])
    ) {
      return "fenced";
    }
    const currentReportIds = this.reportsFor(root)
      .map((report) => report.attemptId)
      .sort();
    const expectedReportIds = [...input.expectedReportAttemptIds].sort();
    if (
      currentReportIds.length !== expectedReportIds.length ||
      currentReportIds.some((id, index) => id !== expectedReportIds[index])
    ) {
      return "fenced";
    }
    const currentFingerprint = fingerprintRootFinalizationReports(this.reportsFor(root));
    if (currentFingerprint !== input.expectedReportFingerprint) return "fenced";
    const existing = root.finalizations.get(input.executionEpoch);
    if (existing?.finalized === true) return "fenced";
    root.finalizations.set(input.executionEpoch, {
      wakeRequested: existing?.wakeRequested ?? false,
      finalized: true,
    });
    return "committed";
  }

  private async interleave(method: CasMethod): Promise<void> {
    const failure = this.failures.get(method);
    if (failure !== undefined) {
      this.failures.delete(method);
      throw failure;
    }
    const control = this.controls.get(method);
    if (control === undefined) return;
    this.controls.delete(method);
    control.markEntered();
    await control.released;
  }

  private requireRoot(rootTaskRunId: string): FakeRoot {
    const root = this.roots.get(rootTaskRunId);
    if (root === undefined) throw new Error("unknown root fixture");
    return root;
  }

  private activeAttempts(root: FakeRoot): FakeAttempt[] {
    return [...root.attemptIds]
      .map((id) => this.attempts.get(id)!)
      .filter((attempt) =>
        attempt.status === "running" && attempt.executionEpoch === root.executionEpoch)
      .sort((a, b) => a.attemptId.localeCompare(b.attemptId));
  }

  private reportsFor(root: FakeRoot): RootFinalizationSnapshot["reports"] {
    return [...root.attemptIds]
      .sort()
      .map((id) => this.attempts.get(id)!)
      .filter((attempt) => attempt.report !== null)
      .map((attempt) => ({
        ...attempt.report!,
        rootTaskRunId: attempt.rootTaskRunId,
        executionEpoch: attempt.executionEpoch,
      }));
  }

  private report(attempt: FakeAttempt, outcome: Outcome): SubagentReportRecord {
    const summary = outcome === "completed"
      ? "Completed the assigned work."
      : outcome === "failed"
        ? "Failed: canonical provider failure"
        : outcome === "cancelled"
          ? "Cancelled before finishing."
          : "Timed out before finishing.";
    this.reportClock += 1;
    return {
      logicalWorkerId: `worker-${attempt.attemptId}`,
      attemptId: attempt.attemptId,
      childSessionId: `child-session-${attempt.attemptId}`,
      childRunId: `child-run-${attempt.attemptId}`,
      agentType: "general-purpose",
      status: outcome,
      summary,
      task: `task-${attempt.attemptId}`,
      at: this.reportClock,
    };
  }
}

function fixture(rootTaskRunId = "root", parentActive = false) {
  const store = new FakeRootFinalizationStore();
  store.addRoot(rootTaskRunId, parentActive);
  const gate = createRootFinalizationGate(store);
  return { store, gate };
}

describe("RootFinalizationGate", () => {
  it("snapshots active attempts, coalesces simultaneous terminal wake, and admits one final response", async () => {
    const { store, gate } = fixture();
    store.admit("root", "attempt-a");
    store.admit("root", "attempt-b");

    const waiting = await gate.finalize("root");
    expect(waiting).toMatchObject({
      status: "wait",
      snapshot: {
        rootTaskRunId: "root",
        executionEpoch: 1,
        activeAttemptIds: ["attempt-a", "attempt-b"],
        finalized: false,
      },
    });

    const paused = store.pause("settleAttemptAndMaybeWake");
    const firstSettlement = gate.settle({ attemptId: "attempt-a", outcome: "completed" });
    await paused.entered;
    const secondSettlement = await gate.settle({ attemptId: "attempt-b", outcome: "failed" });
    expect(secondSettlement).toEqual({ rootTaskRunId: "root", wake: null });
    paused.release();
    expect(await firstSettlement).toEqual({
      rootTaskRunId: "root",
      wake: { trigger: "parent_wake", rootTaskRunId: "root" },
    });
    expect(store.wakeEpochs("root")).toEqual([1]);
    expect(store.reports("root").map((report) => report.attemptId)).toEqual([
      "attempt-a", "attempt-b",
    ]);

    const finals = await Promise.all([gate.finalize("root"), gate.finalize("root")]);
    expect(finals.map((result) => result.status).sort()).toEqual(["committed", "fenced"]);
    const responsePermits = finals.filter((result) => result.status === "committed");
    expect(responsePermits).toHaveLength(1);
    expect(responsePermits[0]).toMatchObject({
      snapshot: { executionEpoch: 1, activeAttemptIds: [], finalized: false },
    });
    expect(store.finalizedEpochs("root")).toEqual([1]);
  });

  it("waits on a fresh active attempt after rejecting the stale final fence", async () => {
    const { store, gate } = fixture();
    store.admit("root", "attempt-old");
    await gate.settle({ attemptId: "attempt-old", outcome: "failed" });

    const paused = store.pause("markRootFinalized");
    const staleFinal = gate.finalize("root");
    await paused.entered;
    const resumed = store.admit("root", "attempt-new", 1);
    expect(resumed).toEqual({ admitted: true, executionEpoch: 1 });
    paused.release();
    const waiting = await staleFinal;
    expect(waiting).toMatchObject({
      status: "wait",
      snapshot: { executionEpoch: 1, activeAttemptIds: ["attempt-new"] },
    });
    expect(store.finalizedEpochs("root")).toEqual([]);

    await gate.settle({ attemptId: "attempt-new", outcome: "completed" });
    const committed = await gate.finalize("root");
    expect(committed).toMatchObject({
      status: "committed",
      snapshot: { executionEpoch: 1, activeAttemptIds: [] },
    });
    expect(store.finalizedEpochs("root")).toEqual([1]);
    expect(store.wakeEpochs("root")).toEqual([1]);
    expect(store.reports("root").map((report) => report.attemptId)).toEqual([
      "attempt-new", "attempt-old",
    ]);
  });

  it("fences same-attempt report enrichment and retries from a fresh snapshot", async () => {
    const { store, gate } = fixture();
    store.admit("root", "attempt-old");
    await gate.settle({ attemptId: "attempt-old", outcome: "completed" });
    const paused = store.pause("markRootFinalized");
    const finalized = gate.finalize("root");
    await paused.entered;
    store.enrich("attempt-old", "enriched findings and checkpoint disclosure");
    paused.release();
    const committed = await finalized;
    expect(committed.status).toBe("committed");
    expect(store.markCalls()).toBe(2);
    if (committed.status === "committed") {
      expect(committed.snapshot.reports[0]?.summary)
        .toBe("enriched findings and checkpoint disclosure");
    }
  });

  it("rejects stale ABA input and recovers with a fresh both-report snapshot", async () => {
    const { store, gate } = fixture();
    store.admit("root", "attempt-old");
    await gate.settle({ attemptId: "attempt-old", outcome: "completed" });

    const paused = store.pause("markRootFinalized");
    const staleFinal = gate.finalize("root");
    await paused.entered;
    expect(store.admit("root", "attempt-new", 1)).toEqual({
      admitted: true,
      executionEpoch: 1,
    });
    await gate.settle({ attemptId: "attempt-new", outcome: "failed" });
    paused.release();
    const legitimate = await staleFinal;
    expect(legitimate.status).toBe("committed");
    expect(store.markCalls()).toBe(2);
    if (legitimate.status !== "committed") throw new Error("expected fresh final permit");
    expect(legitimate.snapshot.executionEpoch).toBe(1);
    expect(legitimate.snapshot.activeAttemptIds).toEqual([]);
    expect(legitimate.snapshot.reports.map((report) => report.attemptId)).toEqual([
      "attempt-new", "attempt-old",
    ]);
    expect((await gate.finalize("root")).status).toBe("fenced");
    expect(store.finalizedEpochs("root")).toEqual([1]);
  });

  it("rechecks the pre-response CAS after activity arrives and does not call final CAS on wait", async () => {
    const { store, gate } = fixture();
    store.admit("root", "attempt-old");
    await gate.settle({ attemptId: "attempt-old", outcome: "completed" });

    const paused = store.pause("beforeRootFinalResponse");
    const pending = gate.finalize("root");
    await paused.entered;
    store.admit("root", "attempt-new", 1);
    paused.release();
    expect((await pending).status).toBe("wait");
    expect(store.markCalls()).toBe(0);
    expect(store.finalizedEpochs("root")).toEqual([]);

    await gate.settle({ attemptId: "attempt-new", outcome: "completed" });
    expect((await gate.finalize("root")).status).toBe("committed");
  });

  it("propagates pre-response CAS failure without authorizing a final response", async () => {
    const { store, gate } = fixture();
    store.admit("root", "attempt-a");
    await gate.settle({ attemptId: "attempt-a", outcome: "completed" });
    store.failNext("beforeRootFinalResponse");

    await expect(gate.finalize("root"))
      .rejects.toThrow("crash before beforeRootFinalResponse commit");
    expect(store.markCalls()).toBe(0);
    expect(store.finalizedEpochs("root")).toEqual([]);
    expect((await gate.finalize("root")).status).toBe("committed");
  });

  it("fences post-final resume and stale retries without reopening the epoch or duplicating a response", async () => {
    const { store, gate } = fixture();
    store.admit("root", "attempt-a");
    await gate.settle({ attemptId: "attempt-a", outcome: "completed" });
    const first = await gate.finalize("root");
    expect(first.status).toBe("committed");
    const responses = first.status === "committed" ? [first.snapshot] : [];

    const resumed = store.admit("root", "attempt-late", 1);
    expect(resumed).toEqual({ admitted: false, reason: "root_finalized" });
    const retried = await gate.finalize("root");
    expect(retried).toMatchObject({
      status: "fenced",
      snapshot: { executionEpoch: 1, finalized: true },
    });
    if (retried.status === "committed") responses.push(retried.snapshot);
    expect(responses).toHaveLength(1);
    expect(store.finalizedEpochs("root")).toEqual([1]);
    expect(store.reports("root").map((report) => report.attemptId)).toEqual(["attempt-a"]);
  });

  it("isolates concurrent roots' active sets, wakes, reports, and final commits", async () => {
    const store = new FakeRootFinalizationStore();
    store.addRoot("root-a");
    store.addRoot("root-b");
    store.admit("root-a", "attempt-a");
    store.admit("root-b", "attempt-b");
    const gate = createRootFinalizationGate(store);

    const [settledA, settledB] = await Promise.all([
      gate.settle({ attemptId: "attempt-a", outcome: "completed" }),
      gate.settle({ attemptId: "attempt-b", outcome: "timeout" }),
    ]);
    expect(settledA.wake).toEqual({ trigger: "parent_wake", rootTaskRunId: "root-a" });
    expect(settledB.wake).toEqual({ trigger: "parent_wake", rootTaskRunId: "root-b" });
    const [finalA, finalB] = await Promise.all([gate.finalize("root-a"), gate.finalize("root-b")]);
    expect(finalA.status).toBe("committed");
    expect(finalB.status).toBe("committed");
    expect(finalA.status === "committed" && finalA.snapshot.reports.map((r) => r.attemptId))
      .toEqual(["attempt-a"]);
    expect(finalB.status === "committed" && finalB.snapshot.reports.map((r) => r.attemptId))
      .toEqual(["attempt-b"]);
    expect(store.finalizedEpochs("root-a")).toEqual([1]);
    expect(store.finalizedEpochs("root-b")).toEqual([1]);
  });

  it("gives a zero-admitted deferred batch no worker wake and never auto-starts it", async () => {
    const { store, gate } = fixture();
    store.defer("root", "deferred-a");
    store.defer("root", "deferred-b");

    const result = await gate.finalize("root");
    expect(result).toMatchObject({
      status: "committed",
      snapshot: { activeAttemptIds: [], reports: [] },
    });
    expect(store.wakeEpochs("root")).toEqual([]);
    expect(store.deferred("root")).toEqual(["deferred-a", "deferred-b"]);
    expect(store.admit("root", "must-not-auto-start")).toEqual({
      admitted: false,
      reason: "root_finalized",
    });
  });

  it("does not let deferred work block or restart after an admitted root finalizes", async () => {
    const { store, gate } = fixture();
    store.defer("root", "deferred-a");
    store.admit("root", "attempt-a");
    await gate.settle({ attemptId: "attempt-a", outcome: "completed" });

    const result = await gate.finalize("root");
    expect(result.status).toBe("committed");
    expect(store.deferred("root")).toEqual(["deferred-a"]);
    expect(store.reports("root").map((report) => report.attemptId)).toEqual(["attempt-a"]);
    expect(store.wakeEpochs("root")).toEqual([1]);
    expect(store.admit("root", "deferred-a-attempt")).toEqual({
      admitted: false,
      reason: "root_finalized",
    });
  });

  it("retains every individual report and preserves failed, stopped, and timeout truth in the final snapshot", async () => {
    const { store, gate } = fixture();
    const outcomes: Record<string, Outcome> = {
      "attempt-done": "completed",
      "attempt-failed": "failed",
      "attempt-stopped": "cancelled",
      "attempt-timeout": "timeout",
    };
    for (const attemptId of Object.keys(outcomes)) store.admit("root", attemptId);
    await Promise.all(Object.entries(outcomes).map(([attemptId, outcome]) =>
      gate.settle({ attemptId, outcome })));

    const result = await gate.finalize("root");
    expect(result.status).toBe("committed");
    if (result.status !== "committed") throw new Error("expected final response permit");
    expect(result.snapshot.reports.map((report) => [report.attemptId, report.status])).toEqual([
      ["attempt-done", "completed"],
      ["attempt-failed", "failed"],
      ["attempt-stopped", "cancelled"],
      ["attempt-timeout", "timeout"],
    ]);
    expect(result.snapshot.reports.map((report) => report.summary)).toEqual([
      "Completed the assigned work.",
      "Failed: canonical provider failure",
      "Cancelled before finishing.",
      "Timed out before finishing.",
    ]);
    const synthesisInput = result.snapshot.reports
      .map((report) => `${report.attemptId}:${report.status}:${report.summary}`)
      .join("\n");
    expect(synthesisInput).toContain("Failed: canonical provider failure");
    expect(synthesisInput).toContain("Cancelled before finishing.");
    expect(synthesisInput).toContain("Timed out before finishing.");
    expect(synthesisInput).not.toContain("all workers succeeded");

    await gate.settle({ attemptId: "attempt-failed", outcome: "completed" });
    expect(store.reports("root")).toHaveLength(4);
    expect(store.reports("root").find((report) => report.attemptId === "attempt-failed"))
      .toMatchObject({ status: "failed", summary: "Failed: canonical provider failure" });
  });

  it("is retry-idempotent across pre-CAS crashes and post-delivery retries", async () => {
    const { store, gate } = fixture();
    store.admit("root", "attempt-a");
    store.failNext("settleAttemptAndMaybeWake");
    await expect(gate.settle({ attemptId: "attempt-a", outcome: "failed" }))
      .rejects.toThrow("crash before settleAttemptAndMaybeWake commit");
    expect(store.reports("root")).toEqual([]);

    const settled = await gate.settle({ attemptId: "attempt-a", outcome: "failed" });
    const wakes = settled.wake === null ? [] : [settled.wake];
    // Simulate a consumer crash after durable wake delivery, then retry the same terminal event.
    const retriedSettlement = await gate.settle({ attemptId: "attempt-a", outcome: "failed" });
    if (retriedSettlement.wake !== null) wakes.push(retriedSettlement.wake);
    expect(wakes).toEqual([{ trigger: "parent_wake", rootTaskRunId: "root" }]);
    expect(store.reports("root")).toHaveLength(1);

    store.failNext("markRootFinalized");
    await expect(gate.finalize("root")).rejects.toThrow("crash before markRootFinalized commit");
    expect(store.finalizedEpochs("root")).toEqual([]);
    const committed = await gate.finalize("root");
    const responses = committed.status === "committed" ? [committed.snapshot] : [];
    // Simulate a consumer crash after its response commit, then retry finalization.
    const retriedFinal = await gate.finalize("root");
    if (retriedFinal.status === "committed") responses.push(retriedFinal.snapshot);
    expect(responses).toHaveLength(1);
    expect(store.finalizedEpochs("root")).toEqual([1]);
    expect(store.reports("root")).toHaveLength(1);
  });

  it("returns not_found without manufacturing a root, wake, or report", async () => {
    const { store, gate } = fixture("known-root");
    expect(await gate.finalize("missing-root")).toEqual({
      status: "not_found",
      rootTaskRunId: "missing-root",
    });
    expect(store.wakeEpochs("known-root")).toEqual([]);
    expect(store.reports("known-root")).toEqual([]);
  });
});
