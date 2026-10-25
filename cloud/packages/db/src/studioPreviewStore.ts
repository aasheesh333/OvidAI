/**
 * Storage contract for worker-managed Studio previews.
 *
 * This module deliberately contains no table definition or SQL. A Drizzle
 * adapter implements StudioPreviewStorePort once the separately-owned schema
 * exists. The factory below supplies the lifecycle invariants; the adapter
 * supplies durable queries, one real DB transaction, and its advisory lock.
 */

export type StudioPreviewKind = "static" | "dev_server";
export type StudioPreviewScript = "dev" | "start" | "preview";
export type StudioPreviewLiveStatus = "starting" | "running" | "stopping";
export type StudioPreviewTerminalStatus = "stopped" | "failed" | "expired";
export type StudioPreviewStatus = StudioPreviewLiveStatus | StudioPreviewTerminalStatus;

/** Statuses which consume process capacity and require lifecycle recovery. */
export const STUDIO_PREVIEW_LIVE_STATUSES = [
  "starting",
  "running",
  "stopping",
] as const satisfies readonly StudioPreviewLiveStatus[];

/**
 * Exact manager-facing registration shape. Timestamps are ISO-8601 strings,
 * matching the worker contract; adapters must convert DB Date values at its
 * boundary. Nullable runtime/terminal fields remain null when unknown.
 *
 * There are intentionally no command, URL, ticket, cookie, token, or secret
 * fields. Package-manager argv and log paths are reconstructed by the worker.
 */
export interface StudioPreviewRecord {
  id: string;
  sessionId: string;
  userId: string;
  generation: number;
  kind: StudioPreviewKind;
  workspacePath: string;
  projectDir: string | null;
  startScript: StudioPreviewScript | null;
  processId: number | null;
  processGroupId: string | null;
  workerEpoch: string | null;
  bindHost: string | null;
  port: number | null;
  status: StudioPreviewStatus;
  createdAt: string;
  lastAccessAt: string | null;
  expiresAt: string;
  endedAt: string | null;
  exitCode: number | null;
  failureCode: string | null;
  logBytes: number | null;
}

/** Positive process limits supplied by the manager (normally 2 and 32). */
export interface StudioPreviewCapacityLimits {
  perUser: number;
  global: number;
}

/** Mutable registration fields; identity, ownership, and launch definition are immutable. */
export type StudioPreviewStorePatch = Partial<Pick<StudioPreviewRecord,
  | "status"
  | "processId"
  | "processGroupId"
  | "workerEpoch"
  | "bindHost"
  | "port"
  | "lastAccessAt"
  | "expiresAt"
  | "endedAt"
  | "exitCode"
  | "failureCode"
  | "logBytes"
>>;

/** The factory adds the next generation before calling the port's atomic CAS. */
export type StudioPreviewCasUpdate = StudioPreviewStorePatch &
  Pick<StudioPreviewRecord, "generation">;

/** Worker-issued access timestamp and the generation it was authorized against. */
export interface StudioPreviewTouchInput {
  id: string;
  generation: number;
  /** ISO-8601 timestamp used for the write, expiry check, and throttle window. */
  now: string;
}

export type StudioPreviewCapacityErrorCode = "per_user_capacity" | "global_capacity";

/** Typed, non-sensitive admission refusal. No row is inserted when thrown. */
export class StudioPreviewCapacityError extends Error {
  readonly name = "StudioPreviewCapacityError";

  constructor(readonly code: StudioPreviewCapacityErrorCode) {
    super(code === "per_user_capacity"
      ? "This account has reached its preview process limit."
      : "Preview capacity is full. Retry shortly.");
  }
}

/**
 * Operations which must run on the same Drizzle transaction as admission.
 * Implementations must not substitute process-local maps or locks.
 */
export interface StudioPreviewAdmissionTransaction {
  /**
   * Acquire one fixed, database-wide, transaction-scoped advisory lock before
   * either capacity count. Postgres implementations use pg_advisory_xact_lock
   * (not a session-scoped lock) with a key dedicated to preview admission.
   * Every dev-server admission must use the same key, including other workers.
   */
  lockCapacity(): Promise<void>;

  /**
   * Count live dev_server rows after lockCapacity(). stopping remains live
   * until terminal cleanup commits. Static and terminal rows consume no slots.
   * perUser is filtered by userId; global spans every user and session.
   */
  liveDevServerCounts(userId: string): Promise<{
    perUser: number;
    global: number;
  }>;

  /** Insert and return the complete persisted record in this transaction. */
  insert(record: StudioPreviewRecord): Promise<StudioPreviewRecord>;
}

/**
 * Narrow Drizzle-ready persistence port. This is not itself a Postgres
 * implementation and makes no claim that a concrete adapter has been proven.
 *
 * The separately-owned durable schema must enforce unique preview ids and
 * provide the required user/status, session/status, expiry-sweep, and
 * (id, generation) CAS indexes. None of those schema/index artifacts are
 * defined or modified by this contract module.
 */
export interface StudioPreviewStorePort {
  /**
   * Run callback once in one DB transaction: commit on success and roll back
   * on any capacity refusal or query error. The transaction must expose the
   * same connection/snapshot semantics as the real Drizzle transaction.
   */
  transaction<T>(
    callback: (tx: StudioPreviewAdmissionTransaction) => Promise<T>,
  ): Promise<T>;

  /** Owner-and-session scoped; an unknown/foreign id is an empty array. */
  getForUser(
    userId: string,
    sessionId: string,
    id?: string,
  ): Promise<StudioPreviewRecord[]>;

  /** All starting/running/stopping rows, including stopping recovery claims. */
  getLive(): Promise<StudioPreviewRecord[]>;

  /**
   * One atomic conditional update, equivalent to
   * UPDATE ... SET update WHERE id = id AND generation = generation RETURNING ...
   * with no unlocked read-then-write. update.generation is expected + 1.
   * Return null without mutation when the row or expected generation is absent.
   */
  compareAndSwap(
    id: string,
    generation: number,
    update: StudioPreviewCasUpdate,
  ): Promise<StudioPreviewRecord | null>;

  /**
   * One atomic conditional access write, equivalent to updating only
   * lastAccessAt = now WHERE id and generation match, status is starting or
   * running, expiresAt > now, and lastAccessAt is null or at least one second
   * before now. The persisted row supplies the throttle/expiry inputs; do not
   * substitute an unlocked read-then-write. Return true only when a row was
   * actually updated, and false for stale, missing, denied, or throttled calls.
   * Generation, status, expiry, and every other field must remain unchanged.
   */
  touch(input: StudioPreviewTouchInput): Promise<boolean>;

  /**
   * Read at most limit live rows with expiresAt <= now, ordered by
   * (expiresAt, id). Do not mark rows expired here: the manager must CAS-claim,
   * clean up the real process/cgroup, and only then persist a terminal status.
   */
  sweepExpired(now: string, limit: number): Promise<StudioPreviewRecord[]>;
}

/** Exact store surface consumed by createStudioPreviewManager. */
export interface StudioPreviewStore {
  /**
   * Insert a registration. Dev-server counting, both cap checks, and insertion
   * share one transaction/advisory lock, so racing workers cannot oversubscribe.
   * Static previews use the same durable insertion path but consume no process
   * slots. Capacity errors carry per_user_capacity or global_capacity.
   */
  start(
    record: StudioPreviewRecord,
    caps: StudioPreviewCapacityLimits,
  ): Promise<StudioPreviewRecord>;

  getForUser(
    userId: string,
    sessionId: string,
    id?: string,
  ): Promise<StudioPreviewRecord[]>;

  getLive(): Promise<StudioPreviewRecord[]>;

  /** Atomically apply patch and increment generation, or return null on a stale CAS. */
  update(
    id: string,
    generation: number,
    patch: StudioPreviewStorePatch,
  ): Promise<StudioPreviewRecord | null>;

  /**
   * Throttled, generation-preserving lastAccessAt write for the current live
   * generation. Returns false when no real row write occurred.
   */
  touch(input: StudioPreviewTouchInput): Promise<boolean>;

  sweepExpired(now: string, limit: number): Promise<StudioPreviewRecord[]>;
}

function assertPositiveCap(value: number, name: string): void {
  if (!Number.isInteger(value) || value <= 0) {
    throw new RangeError(`${name} preview capacity must be a positive integer`);
  }
}

/**
 * Compose lifecycle semantics over the narrow persistence port.
 *
 * The all-admissions lock is intentionally coarse: one fixed key closes both
 * same-user and global races. Capacity is evaluated only for dev_server rows;
 * stopping still counts because its process cleanup is not yet durable.
 */
export function createStudioPreviewStore(
  port: StudioPreviewStorePort,
): StudioPreviewStore {
  return {
    async start(record, caps) {
      assertPositiveCap(caps.perUser, "Per-user");
      assertPositiveCap(caps.global, "Global");
      return port.transaction(async (tx) => {
        await tx.lockCapacity();
        if (record.kind === "dev_server") {
          const counts = await tx.liveDevServerCounts(record.userId);
          if (counts.perUser >= caps.perUser) {
            throw new StudioPreviewCapacityError("per_user_capacity");
          }
          if (counts.global >= caps.global) {
            throw new StudioPreviewCapacityError("global_capacity");
          }
        }
        return tx.insert(record);
      });
    },

    getForUser(userId, sessionId, id) {
      return port.getForUser(userId, sessionId, id);
    },

    getLive() {
      return port.getLive();
    },

    update(id, generation, patch) {
      return port.compareAndSwap(id, generation, {
        ...patch,
        generation: generation + 1,
      });
    },

    touch(input) {
      return port.touch(input);
    },

    sweepExpired(now, limit) {
      return port.sweepExpired(now, limit);
    },
  };
}
