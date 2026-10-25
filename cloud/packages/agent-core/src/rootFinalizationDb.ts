import {
  beforeRootFinalResponse,
  markRootFinalized,
  settleAttemptAndMaybeWake,
  snapshotRootFinalization,
  type Db,
} from "@ovid/db";

import type {
  RootFinalizationSnapshot,
  RootFinalizationStore,
} from "./rootFinalization.js";

/**
 * Production Task 5 adapter. It owns no root state: snapshots, admission CAS,
 * settlement, report pages, and final CAS all use the durable DB primitives.
 * The gate supplies the snapshot's report-attempt IDs to the final CAS so a
 * same-epoch admit -> settle -> empty-running-set interleaving is fenced.
 */
export function createRootFinalizationDbStore(db: Db): RootFinalizationStore {
  return {
    async snapshotRoot(rootTaskRunId): Promise<RootFinalizationSnapshot | null> {
      const snapshot = await snapshotRootFinalization(db, { rootTaskRunId });
      if (snapshot === null) return null;
      return {
        rootTaskRunId: snapshot.rootTaskRunId,
        executionEpoch: snapshot.executionEpoch,
        activeAttemptIds: snapshot.activeAttemptIds,
        finalized: snapshot.finalized,
        reports: snapshot.reports,
      };
    },
    beforeRootFinalResponse(input) {
      return beforeRootFinalResponse(db, input);
    },
    settleAttemptAndMaybeWake(input) {
      return settleAttemptAndMaybeWake(db, input);
    },
    markRootFinalized(input) {
      return markRootFinalized(db, input);
    },
  };
}
