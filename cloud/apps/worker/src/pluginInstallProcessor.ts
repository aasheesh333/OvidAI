/**
 * P5 Task 14 — plugin-installs worker processor.
 *
 * One BullMQ job = one install/uninstall transaction. The processor owns the
 * CLAIM and the terminal status mapping; the installer (packages/mcp
 * plugins/install.ts) owns the transaction and its rollback.
 *
 * Claim-by-status (brief Step 3): a replayed/duplicated job whose row is
 * already terminal (`active`/`degraded`/`failed`/`rolled_back`) is a no-op —
 * it never re-runs a transaction (and therefore never re-runs a rollback).
 * A live row is moved to `installing` (or `uninstalling`) before the
 * installer runs.
 *
 * Attempts: 1 (PLUGIN_INSTALL_JOB_DEFAULTS) — a thrown error is never
 * redelivered, so rethrowing cannot help; it would only mark the job failed
 * after the installer already rolled back. Errors are therefore logged and
 * the row is left in a terminal state (`failed` unless the installer already
 * wrote/restored one), and the job COMPLETES (the P1 ruling pattern: retry
 * ladders live in the processor layer, not in BullMQ).
 */

import { plugins, type Db } from "@ovid/db";
import type { PluginInstallJob } from "@ovid/queue";
import type { PluginInstallOutcome } from "@ovid/mcp";

/**
 * Terminal plugin statuses. `queued`/`installing`/`pending_grant`/
 * `uninstalling` are live states (see the status vocabulary in install.ts).
 */
export const TERMINAL_PLUGIN_STATUSES = [
  "active",
  "degraded",
  "failed",
  "rolled_back",
] as const;

const TERMINAL: ReadonlySet<string> = new Set(TERMINAL_PLUGIN_STATUSES);

/**
 * Outcome reason → terminal row status. Reasons emitted by the installer
 * before it writes a row (tier gate, invalid job/source, identity mismatch)
 * still need the gateway-created row terminalized; reasons emitted after a
 * rollback already wrote their status, but the mapping is the contract.
 *
 * `pro_required` is a failed install (no row/event from the installer —
 * report ruling); the processor terminalizes the row the gateway created.
 */
export const PLUGIN_INSTALL_OUTCOME_STATUS: Readonly<Record<string, string>> = {
  pro_required: "failed",
  missing_source: "failed",
  invalid_install_id: "failed",
  plugin_id_mismatch: "failed",
  invalid_plugin: "failed",
  grant_denied: "rolled_back",
  deps_failed: "failed",
  install_failed: "failed",
  rename_failed: "failed",
};

/** Minimal @ovid/db plugins repo surface (injectable for tests). */
export interface PluginInstallRepoPort {
  getByPluginId(
    db: Db,
    uid: string,
    pluginId: string,
  ): Promise<{ id: string; status: string } | null>;
  setStatus(db: Db, id: string, uid: string, status: string): Promise<void>;
}

export interface PluginInstallProcessorDeps {
  db: Db;
  installer: {
    install(job: PluginInstallJob): Promise<PluginInstallOutcome>;
    uninstall(job: PluginInstallJob): Promise<void>;
  };
  /** Defaults to the real @ovid/db `plugins` repo. */
  plugins?: PluginInstallRepoPort;
  /** Defaults to console.error; tests capture it. */
  logError?: (message: string, err: unknown) => void;
}

/** The BullMQ job shape this processor reads (structural — no bullmq dep). */
export interface PluginInstallJobLike {
  data: PluginInstallJob;
}

export function createPluginInstallProcessor(
  deps: PluginInstallProcessorDeps,
): (job: PluginInstallJobLike) => Promise<void> {
  const repo = deps.plugins ?? (plugins as PluginInstallRepoPort);
  const logError =
    deps.logError ??
    ((message: string, err: unknown) => console.error(message, err));

  /** Best-effort terminalization; a DB outage must not rethrow either. */
  async function terminalize(
    uid: string,
    pluginId: string,
    status: string,
  ): Promise<void> {
    try {
      const row = await repo.getByPluginId(deps.db, uid, pluginId);
      // Never clobber a terminal row: the installer may have restored the
      // PRIOR install's row (upgrade failures) or written active/degraded.
      if (row === null || TERMINAL.has(row.status)) return;
      await repo.setStatus(deps.db, row.id, uid, status);
    } catch (err) {
      logError(
        `[plugin-install] could not terminalize ${pluginId} for ${uid} as ${status}`,
        err,
      );
    }
  }

  return async function process(job: PluginInstallJobLike): Promise<void> {
    const data = job.data;
    try {
      const row = await repo.getByPluginId(deps.db, data.userId, data.pluginId);

      if (data.mode === "uninstall") {
        // Ownership check first (I3): a job for a row this user does not own
        // must not touch the shared registry/content. The installer repeats
        // the check; doing it here keeps a bogus job out of the claim path.
        // There is no "already terminal" no-op here: `active`/`degraded` are
        // exactly what a legitimate uninstall starts from, and the removal
        // steps are idempotent (a retried uninstall simply finishes).
        if (row === null) return;
        await repo.setStatus(deps.db, row.id, data.userId, "uninstalling");
        await deps.installer.uninstall(data);
        return;
      }

      // Install: a replayed/duplicate job against a terminal row is a no-op.
      if (row !== null && TERMINAL.has(row.status)) return;

      if (row !== null) {
        await repo.setStatus(deps.db, row.id, data.userId, "installing");
      }

      const outcome = await deps.installer.install(data);
      const mapped =
        outcome.reason !== undefined
          ? (PLUGIN_INSTALL_OUTCOME_STATUS[outcome.reason] ?? "failed")
          : outcome.status;
      await terminalize(data.userId, data.pluginId, mapped);
    } catch (err) {
      // Run-level failures are already an outcome; this is the infra path.
      // Log, terminalize what is still live, and COMPLETE the job — with
      // attempts: 1 a rethrow cannot retry, it would only re-run a rollback
      // on the next delivery in a different worker configuration.
      logError(
        `[plugin-install] job ${data.installId} (${data.mode} ${data.pluginId}) failed`,
        err,
      );
      await terminalize(data.userId, data.pluginId, "failed");
    }
  };
}
