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
import {
  adaptPlugin,
  isSafePluginId,
  isSafePluginVersion,
  type PluginInstallOutcome,
  type PluginSourceInput,
} from "@ovid/mcp";

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
  /** HIGH-3: re-key the provisional row onto the worker-derived id. */
  adopt(
    db: Db,
    input: { id: string; userId: string; pluginId: string },
  ): Promise<{ id: string; status: string } | null>;
}

/** The resolver surface the identity step needs (mcpRuntime.resolver). */
export interface PluginIdentityResolver {
  resolve(input: PluginSourceInput): Promise<{
    stagingDir: string;
    discard(): Promise<void>;
  }>;
}

export interface PluginInstallProcessorDeps {
  db: Db;
  installer: {
    install(job: PluginInstallJob): Promise<PluginInstallOutcome>;
    uninstall(job: PluginInstallJob): Promise<void>;
  };
  /**
   * HIGH-3: the source resolver used to derive the canonical id/version for
   * jobs the gateway enqueued with `needsIdentity: true`. The gateway never
   * touches untrusted sources; this worker-side step does.
   */
  resolver?: PluginIdentityResolver;
  /** Defaults to the real @ovid/db `plugins` repo. */
  plugins?: PluginInstallRepoPort;
  /** Defaults to console.error; tests capture it. */
  logError?: (message: string, err: unknown) => void;
}

/** Resolve a source once, read its canonical identity, discard the staging. */
async function resolveIdentity(
  resolver: PluginIdentityResolver,
  source: PluginSourceInput,
): Promise<{ pluginId: string; version: string }> {
  const resolved = await resolver.resolve(source);
  try {
    const manifest = await adaptPlugin(resolved.stagingDir);
    return { pluginId: manifest.pluginId, version: manifest.version };
  } finally {
    await resolved.discard().catch(() => {
      // discard is idempotent/best-effort; identity was already read.
    });
  }
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
    let pluginId = data.pluginId;
    try {
      if (data.mode === "uninstall") {
        // Ownership check first (I3): a job for a row this user does not own
        // must not touch the shared registry/content. The installer repeats
        // the check; doing it here keeps a bogus job out of the claim path.
        // There is no "already terminal" no-op here: `active`/`degraded` are
        // exactly what a legitimate uninstall starts from, and the removal
        // steps are idempotent (a retried uninstall simply finishes).
        const row = await repo.getByPluginId(deps.db, data.userId, data.pluginId);
        if (row === null) return;
        await repo.setStatus(deps.db, row.id, data.userId, "uninstalling");
        await deps.installer.uninstall(data);
        return;
      }

      if (data.needsIdentity === true) {
        // HIGH-3: the gateway created a provisional `pending/<installId>`
        // row and never resolved the source. The provisional row's presence
        // is the freshness signal: a replayed job after adoption finds no
        // such row and no-ops.
        const provisional = await repo.getByPluginId(deps.db, data.userId, data.pluginId);
        if (provisional === null) return;

        if (data.source === undefined) {
          await repo.setStatus(deps.db, provisional.id, data.userId, "failed");
          return;
        }
        if (deps.resolver === undefined) {
          logError(
            `[plugin-install] no source resolver configured for ${data.installId}`,
            new Error("identity resolver unavailable"),
          );
          await repo.setStatus(deps.db, provisional.id, data.userId, "failed");
          return;
        }

        let identity: { pluginId: string; version: string };
        try {
          identity = await resolveIdentity(deps.resolver, data.source);
        } catch (err) {
          logError(
            `[plugin-install] source resolution failed for ${data.installId}`,
            err,
          );
          await repo.setStatus(deps.db, provisional.id, data.userId, "failed");
          return;
        }
        // HIGH-1: the same gate the installer applies. Reject a version the
        // installer would refuse (`invalid_plugin`) while the row is still
        // ours, rather than enqueueing/claiming a doomed transaction.
        if (
          !isSafePluginId(identity.pluginId) ||
          !isSafePluginVersion(identity.version)
        ) {
          await repo.setStatus(deps.db, provisional.id, data.userId, "failed");
          return;
        }

        const adopted = await repo.adopt(deps.db, {
          id: provisional.id,
          userId: data.userId,
          pluginId: identity.pluginId,
        });
        if (adopted === null) return;
        pluginId = identity.pluginId;
      } else {
        // Install: a replayed/duplicate job against a terminal row is a no-op.
        const existing = await repo.getByPluginId(deps.db, data.userId, data.pluginId);
        if (existing !== null && TERMINAL.has(existing.status)) return;
      }

      const row = await repo.getByPluginId(deps.db, data.userId, pluginId);
      if (row !== null) {
        await repo.setStatus(deps.db, row.id, data.userId, "installing");
      }

      const outcome = await deps.installer.install({ ...data, pluginId });
      const mapped =
        outcome.reason !== undefined
          ? (PLUGIN_INSTALL_OUTCOME_STATUS[outcome.reason] ?? "failed")
          : outcome.status;
      await terminalize(data.userId, pluginId, mapped);
    } catch (err) {
      // Run-level failures are already an outcome; this is the infra path.
      // Log, terminalize what is still live, and COMPLETE the job — with
      // attempts: 1 a rethrow cannot retry, it would only re-run a rollback
      // on the next delivery in a different worker configuration.
      logError(
        `[plugin-install] job ${data.installId} (${data.mode} ${pluginId}) failed`,
        err,
      );
      await terminalize(data.userId, pluginId, "failed");
    }
  };
}
