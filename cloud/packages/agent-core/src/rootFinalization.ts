import {
  fingerprintRootFinalizationReports,
  type DurableSubagentReportRecord,
  type SubagentReportRecord,
} from "@ovid/db";

export type RootTerminalOutcome = SubagentReportRecord["status"];

/** An immutable pre-response view of one root's current execution epoch. */
export interface RootFinalizationSnapshot {
  rootTaskRunId: string;
  executionEpoch: number;
  activeAttemptIds: readonly string[];
  finalized: boolean;
  /** Every retained report for this root, including earlier fenced epochs; also the ABA fence input. */
  reports: readonly DurableSubagentReportRecord[];
}

/**
 * Narrow adapter over Task 5's CAS functions, plus an atomic root/report read.
 * Admission must serialize with these operations and a finalized epoch never
 * admits new activity. The report-attempt fence closes the same-epoch ABA where
 * an attempt is admitted and settled before the final commit. Deferred work is
 * not an attempt.
 */
export interface RootFinalizationStore {
  snapshotRoot(rootTaskRunId: string): Promise<RootFinalizationSnapshot | null>;
  beforeRootFinalResponse(input: {
    rootTaskRunId: string;
    executionEpoch: number;
    expectedReportAttemptIds?: readonly string[];
    expectedReportFingerprint?: string;
  }): Promise<"allow" | "wait">;
  settleAttemptAndMaybeWake(input: {
    attemptId: string;
    outcome: RootTerminalOutcome;
  }): Promise<{ rootTaskRunId: string; shouldWake: boolean }>;
  markRootFinalized(input: {
    rootTaskRunId: string;
    executionEpoch: number;
    activeAttemptIds: readonly string[];
    /** Exact root-scoped report set captured with the active/epoch snapshot. */
    expectedReportAttemptIds: readonly string[];
    /** Summary/structured-content fence; legacy adapters may still refuse it. */
    expectedReportFingerprint: string;
  }): Promise<"committed" | "fenced">;
}

export interface RootSettlementInput {
  attemptId: string;
  outcome: RootTerminalOutcome;
}

export interface ParentWakeDecision {
  trigger: "parent_wake";
  rootTaskRunId: string;
}

export interface RootSettlementDecision {
  rootTaskRunId: string;
  wake: ParentWakeDecision | null;
}

export type RootFinalizationDecision =
  | { status: "not_found"; rootTaskRunId: string }
  | {
      status: "wait" | "fenced" | "committed";
      snapshot: RootFinalizationSnapshot;
    };

export interface RootFinalizationGate {
  /** Settles through the durable CAS; only a true CAS wake becomes a wake decision. */
  settle(input: RootSettlementInput): Promise<RootSettlementDecision>;
  /**
   * Authorizes a final response only after its zero-active epoch commits.
   * Callers may synthesize/respond only for "committed". No wake, response,
   * admission, deferred reconsideration, or report deletion is performed here.
   */
  finalize(rootTaskRunId: string): Promise<RootFinalizationDecision>;
}

/** Pure orchestration: all race authority and idempotency remain in the store CAS. */
export function createRootFinalizationGate(
  store: RootFinalizationStore,
): RootFinalizationGate {
  return {
    async settle(input) {
      const settled = await store.settleAttemptAndMaybeWake(input);
      return {
        rootTaskRunId: settled.rootTaskRunId,
        wake: settled.shouldWake
          ? { trigger: "parent_wake", rootTaskRunId: settled.rootTaskRunId }
          : null,
      };
    },

    async finalize(rootTaskRunId) {
      let snapshot: RootFinalizationSnapshot | null = null;
      // A fenced snapshot is never synthesis input. Retry only from a fresh
      // root/report read; production callers still require durable delivery.
      for (let attempt = 0; attempt < 16; attempt += 1) {
        snapshot = await store.snapshotRoot(rootTaskRunId);
        if (snapshot === null) return { status: "not_found", rootTaskRunId };
        if (snapshot.finalized) return { status: "fenced", snapshot };
        if (snapshot.activeAttemptIds.length > 0) return { status: "wait", snapshot };

        const allowed = await store.beforeRootFinalResponse({
          rootTaskRunId,
          executionEpoch: snapshot.executionEpoch,
          expectedReportAttemptIds: snapshot.reports.map((report) => report.attemptId),
          expectedReportFingerprint: fingerprintRootFinalizationReports(snapshot.reports),
        });
        if (allowed === "wait") return { status: "wait", snapshot };

        const committed = await store.markRootFinalized({
          rootTaskRunId,
          executionEpoch: snapshot.executionEpoch,
          activeAttemptIds: snapshot.activeAttemptIds,
          expectedReportAttemptIds: snapshot.reports.map((report) => report.attemptId),
          expectedReportFingerprint: fingerprintRootFinalizationReports(snapshot.reports),
        });
        if (committed === "committed") return { status: "committed", snapshot };
      }
      if (snapshot === null) return { status: "not_found", rootTaskRunId };
      return { status: "fenced", snapshot };
    },
  };
}
