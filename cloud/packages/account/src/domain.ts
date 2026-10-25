/**
 * Server-owned account deletion state machine — a verbatim port of
 * `server/account/domain.py`.
 *
 * All times are server Unix SECONDS (floats are allowed; the Python tests pin
 * fractional deadlines). The store's UID lock MUST span external effects and
 * checkpoint commits; a worker never trusts a stale due-list item.
 */

import type { Db } from "@ovid/db";

export const GRACE_SECONDS = 24 * 60 * 60;
export const RECENT_AUTH_SECONDS = 5 * 60;
export const FENCE_SETTLE_SECONDS = 60;
export const RETRY_SECONDS = 60;
export const MAX_RETRY_SECONDS = 60 * 60;

export const IDENTITY_PROVIDERS: ReadonlySet<string> = new Set([
  "google.com",
  "github.com",
  "apple.com",
  "microsoft.com",
  "facebook.com",
  "twitter.com",
  "yahoo.com",
  "phone",
]);

const UID_RE = /^[A-Za-z0-9_-]{1,128}$/;
const REQUEST_ID_RE = /^[A-Za-z0-9_-]{8,100}$/;

/** Firebase ID-token claims (the subset the lifecycle reads). */
export interface Claims {
  uid?: unknown;
  sub?: unknown;
  auth_time?: unknown;
  firebase?: unknown;
  _account_disabled?: unknown;
  [key: string]: unknown;
}

export class AccountError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, status = 409) {
    super(code);
    this.name = "AccountError";
    this.code = code;
    this.status = status;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * JS `RegExp.test` treats `$` as "before a trailing line terminator"; Python's
 * `fullmatch` does not. Compare the matched text to the input so a uid like
 * "alice\n" can never pass.
 */
function fullMatch(re: RegExp, value: string): boolean {
  const match = re.exec(value);
  return match !== null && match[0] === value;
}

/** Python `identity()`: validate the Firebase uid + provider allowlist. */
export function identity(claims: Claims, opts: { allowLegacyPassword?: boolean } = {}): string {
  const uid = claims.uid || claims.sub;
  if (typeof uid !== "string" || !fullMatch(UID_RE, uid)) {
    throw new AccountError("invalid_identity", 401);
  }
  const firebase = claims.firebase;
  const provider = isRecord(firebase) ? firebase.sign_in_provider : undefined;
  if (
    typeof provider !== "string" ||
    !(
      IDENTITY_PROVIDERS.has(provider) ||
      (opts.allowLegacyPassword === true && provider === "password")
    )
  ) {
    throw new AccountError("unsupported_identity", 403);
  }
  return uid;
}

/** Python `auth_time()`: a finite number, booleans rejected. */
export function authTime(claims: Claims): number {
  const value = claims.auth_time;
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new AccountError("reauthentication_required", 401);
  }
  return value;
}

export type DeletionState = "pending" | "cancelled" | "fenced" | "deleting" | "deleted";

/** Snake_case wire contract (`public()` in Python). */
export interface PublicState {
  state: "active" | DeletionState;
  delete_after: number | null;
  request_id: string | null;
}

/** The durable row, in the EXACT Python shape (snake_case). */
export interface DeletionRow {
  uid: string;
  request_id: string;
  state: DeletionState;
  requested_at: number;
  delete_after: number;
  baseline_login_ms: number;
  fence_at: number | null;
  fence_owned: boolean;
  completed: string[];
  request_aliases: string[];
  attempts: number;
  next_attempt: number;
  previous_requests: string[];
  cleanup_context?: CleanupContext;
  [key: string]: unknown;
}

export type CleanupContext = Record<string, unknown>;

export function publicState(row: DeletionRow | null | undefined): PublicState {
  if (row === null || row === undefined) {
    return { state: "active", delete_after: null, request_id: null };
  }
  return {
    state: row.state,
    delete_after: row.delete_after ?? null,
    request_id: row.request_id ?? null,
  };
}

export interface DeletionSession {
  /** The same reserved connection holding the UID advisory lock, when backed by Postgres. */
  readonly db?: Db;
  get(uid: string): Promise<DeletionRow | null>;
  save(row: DeletionRow): Promise<void>;
}

export interface DeletionStore {
  /** Runs `fn` under the per-uid advisory lock (dedicated connection). */
  locked<T>(uid: string, fn: (session: DeletionSession) => Promise<T>): Promise<T>;
  /** Uids the sweeper should finalize now, Python ordering. */
  due(now: number): Promise<string[]>;
}

export interface AdminUser {
  disabled: boolean;
  last_login_ms: number;
}

export interface AdminAdapter {
  user(uid: string): Promise<AdminUser | null>;
  disable(uid: string): Promise<void>;
  enable(uid: string): Promise<void>;
  delete(uid: string): Promise<void>;
}

export interface CleanupStep {
  name: string;
  /** Postgres cleanup receives the same reserved session holding the UID lock. */
  run(uid: string, ctx: CleanupContext, session?: DeletionSession): Promise<void>;
}

export interface DataAdapter {
  prepare(uid: string): Promise<CleanupContext>;
  validateContext?(ctx: CleanupContext): void;
  revokeKeys(uid: string, ctx: CleanupContext): Promise<void>;
  /** Mandatory stages that must run even when an old binary saved `data`. */
  requiredDeletionSteps?: CleanupStep[];
  deletionSteps(): CleanupStep[];
}

export interface Lifecycle {
  request(claims: Claims, requestId: string): Promise<PublicState>;
  status(claims: Claims): Promise<PublicState>;
  login(claims: Claims): Promise<PublicState>;
  cancel(claims: Claims): Promise<PublicState>;
  access<T>(claims: Claims, fn: (uid: string, session?: DeletionSession) => Promise<T>): Promise<T>;
  finalize(uid: string, opts?: { scheduled?: boolean }): Promise<PublicState>;
}

export interface LifecycleDeps {
  store: DeletionStore;
  admin: AdminAdapter;
  data: DataAdapter;
  clock?: () => number;
}

function asArray<T>(value: T[] | undefined | null): T[] {
  return Array.isArray(value) ? value : [];
}

class DeletionLifecycle implements Lifecycle {
  private readonly store: DeletionStore;
  private readonly admin: AdminAdapter;
  private readonly data: DataAdapter;
  private readonly clock: () => number;

  constructor(deps: LifecycleDeps) {
    this.store = deps.store;
    this.admin = deps.admin;
    this.data = deps.data;
    this.clock = deps.clock ?? (() => Date.now() / 1000);
  }

  async request(claims: Claims, requestId: string): Promise<PublicState> {
    const uid = identity(claims, { allowLegacyPassword: true });
    if (typeof requestId !== "string" || !fullMatch(REQUEST_ID_RE, requestId)) {
      throw new AccountError("invalid_request_id", 400);
    }
    return this.store.locked(uid, async (db) => {
      this.recentAuth(claims);
      const old = await db.get(uid);
      if (old && asArray(old.previous_requests).includes(requestId)) {
        throw new AccountError("request_already_completed");
      }
      if (
        old &&
        (requestId === old.request_id || asArray(old.request_aliases).includes(requestId))
      ) {
        return publicState(old);
      }
      // Password is retained only for existing receipts/status/cancellation.
      // Removing it at verification would strand legacy worker-fenced users.
      identity(claims);
      if (old && old.state === "pending") {
        old.request_aliases = [...asArray(old.request_aliases), requestId];
        await db.save(old);
        return publicState(old);
      }
      if (old && ["fenced", "deleting", "deleted"].includes(old.state)) {
        throw new AccountError("deletion_in_progress");
      }
      const user = await this.admin.user(uid);
      if (user === null || user.disabled) {
        throw new AccountError("account_unavailable", 403);
      }
      const now = this.recentAuth(claims);
      const row: DeletionRow = {
        uid,
        request_id: requestId,
        state: "pending",
        requested_at: now,
        delete_after: now + GRACE_SECONDS,
        baseline_login_ms: user.last_login_ms,
        fence_at: null,
        fence_owned: false,
        completed: [],
        request_aliases: [],
        attempts: 0,
        next_attempt: 0,
        previous_requests: old
          ? [
              ...asArray(old.previous_requests),
              old.request_id,
              ...asArray(old.request_aliases),
            ]
          : [],
      };
      await db.save(row);
      return publicState(row);
    });
  }

  private recentAuth(claims: Claims): number {
    const now = this.clock();
    const signedAt = authTime(claims);
    if (!(now - signedAt >= 0 && now - signedAt <= RECENT_AUTH_SECONDS)) {
      throw new AccountError("reauthentication_required", 401);
    }
    return now;
  }

  async status(claims: Claims): Promise<PublicState> {
    const uid = identity(claims, { allowLegacyPassword: true });
    return this.store.locked(uid, async (db) => {
      const row = await db.get(uid);
      if (row === null) identity(claims);
      return publicState(row);
    });
  }

  private async cancelRow(db: DeletionSession, row: DeletionRow): Promise<PublicState> {
    // Persist cancellation intent BEFORE undoing the fence. A crash while
    // enabling is retried by login or the worker; data deletion is barred.
    row.state = "cancelled";
    await db.save(row);
    if (row.fence_owned) {
      if ((await this.admin.user(row.uid)) !== null) {
        await this.admin.enable(row.uid);
      }
      row.fence_owned = false;
      await db.save(row);
    }
    return publicState(row);
  }

  async login(claims: Claims): Promise<PublicState> {
    const uid = identity(claims, { allowLegacyPassword: true });
    const signedAt = authTime(claims);
    return this.store.locked(uid, async (db) => {
      if (signedAt > this.clock()) {
        throw new AccountError("invalid_auth_time", 401);
      }
      const row = await db.get(uid);
      if (
        claims._account_disabled &&
        !(
          row &&
          row.fence_owned &&
          (row.state === "fenced" || row.state === "cancelled")
        )
      ) {
        throw new AccountError("account_unavailable", 403);
      }
      if (row === null) {
        identity(claims);
        return publicState(null);
      }
      if (row.state === "fenced" && !row.fence_owned) {
        throw new AccountError("account_unavailable", 403);
      }
      if (row.state === "deleting" || row.state === "deleted") {
        throw new AccountError("deletion_in_progress");
      }
      // Login acknowledgement is observational. Restoration requires the
      // explicit cancellation operation; auth callbacks/token refreshes must
      // never mutate deletion state.
      return publicState(row);
    });
  }

  async cancel(claims: Claims): Promise<PublicState> {
    const uid = identity(claims, { allowLegacyPassword: true });
    return this.store.locked(uid, async (db) => {
      const acceptedAt = this.recentAuth(claims);
      const row = await db.get(uid);
      if (row === null) {
        identity(claims);
        return publicState(null);
      }
      if (row.state === "cancelled") {
        return this.cancelRow(db, row);
      }
      if (row.state === "deleting" || row.state === "deleted") {
        throw new AccountError("deletion_in_progress");
      }
      if (row.state === "fenced" && !row.fence_owned) {
        throw new AccountError("account_unavailable", 403);
      }
      const settlement =
        row.state === "fenced" &&
        row.fence_at !== null &&
        acceptedAt < row.fence_at + FENCE_SETTLE_SECONDS;
      if (acceptedAt > row.delete_after && !settlement) {
        throw new AccountError("deletion_in_progress");
      }
      return this.cancelRow(db, row);
    });
  }

  async access<T>(claims: Claims, fn: (uid: string, session?: DeletionSession) => Promise<T>): Promise<T> {
    // Quota/mint integration: hold the lock across the ENTIRE uid-owned
    // mutation. Background usage/token refresh must never cancel deletion.
    const uid = identity(claims);
    return this.store.locked(uid, async (db) => {
      const row = await db.get(uid);
      if (
        row &&
        (row.state as string) !== "cancelled" &&
        (row.state as string) !== "active"
      ) {
        throw new AccountError("account_deletion_pending", 403);
      }
      return fn(uid, db);
    });
  }

  /**
   * Checkpoint retry intent before effects, under the same UID lock. A crash
   * also backs off. An exception updates the deadline from the END of the
   * attempt so slow failing dependencies cannot monopolize a sweep.
   */
  private async attempt(
    uid: string,
    scheduled: boolean,
    body: (db: DeletionSession, row: DeletionRow | null) => Promise<PublicState>,
  ): Promise<PublicState> {
    return this.store.locked(uid, async (db) => {
      let row = await db.get(uid);
      const now = this.clock();
      const eligible =
        row !== null &&
        (((["pending", "fenced", "deleting"] as string[]).includes(row.state) &&
          row.delete_after <= now) ||
          (row.state === "cancelled" && row.fence_owned));
      if (!eligible || (scheduled && (row?.next_attempt ?? 0) > now)) {
        return publicState(row);
      }
      row = row as DeletionRow;
      row.attempts = (row.attempts ?? 0) + 1;
      const delay = Math.min(
        MAX_RETRY_SECONDS,
        RETRY_SECONDS * 2 ** Math.min(row.attempts - 1, 6),
      );
      row.next_attempt = now + delay;
      await db.save(row);
      let result: PublicState;
      try {
        result = await body(db, row);
      } catch (err) {
        // Read committed checkpoints, not potentially mutated local data.
        const fresh = await db.get(uid);
        if (fresh) {
          fresh.next_attempt = this.clock() + delay;
          await db.save(fresh);
        }
        throw err;
      }
      const fresh = await db.get(uid);
      if (fresh) {
        fresh.next_attempt =
          fresh.state === "fenced" ? (fresh.fence_at ?? 0) + FENCE_SETTLE_SECONDS : 0;
        await db.save(fresh);
      }
      return result;
    });
  }

  private async deleteData(
    db: DeletionSession,
    row: DeletionRow,
    steps?: CleanupStep[],
  ): Promise<void> {
    const actions = steps ?? this.data.deletionSteps();
    for (const step of actions) {
      const checkpoint = `data:${step.name}`;
      if (!asArray(row.completed).includes(checkpoint)) {
        await step.run(row.uid, row.cleanup_context ?? {}, db);
        row.completed = [...asArray(row.completed), checkpoint];
        await db.save(row);
      }
    }
  }

  async finalize(uid: string, opts: { scheduled?: boolean } = {}): Promise<PublicState> {
    return this.attempt(uid, opts.scheduled === true, async (db, row) => {
      if (row === null) {
        // Unreachable: `attempt` only calls the body when eligible.
        return publicState(row);
      }
      if (row.state === "cancelled") {
        return this.cancelRow(db, row);
      }
      const now = this.clock();
      if (now < row.delete_after) {
        return publicState(row);
      }
      if (row.state === "pending") {
        const user = await this.admin.user(uid);
        row.state = "fenced";
        row.fence_at = null;
        row.fence_owned = user !== null && !user.disabled;
        await db.save(row);
      }
      if (row.state === "fenced") {
        const user = await this.admin.user(uid);
        if (user !== null && row.fence_owned) {
          await this.admin.disable(uid);
        }
        if (row.fence_at === null) {
          // Only start settlement after the disable has succeeded.
          row.fence_at = this.clock();
          await db.save(row);
        }
        // Authentication metadata is not consent. Only a durable cancellation
        // committed under this lock can stop cleanup.
        if (this.clock() < row.fence_at + FENCE_SETTLE_SECONDS) {
          return publicState(row);
        }
        row.state = "deleting";
        await db.save(row);
      }
      if (row.cleanup_context === undefined) {
        row.cleanup_context = await this.data.prepare(uid);
        await db.save(row);
      }
      if (this.data.validateContext !== undefined) {
        this.data.validateContext(row.cleanup_context);
        await db.save(row);
      }
      const required = this.data.requiredDeletionSteps;
      if (asArray(row.completed).includes("data") && required !== undefined) {
        await this.deleteData(db, row, required);
      }
      const stages: Array<[string, (id: string, ctx: CleanupContext) => Promise<void>]> = [
        ["keys", (id, ctx) => this.data.revokeKeys(id, ctx)],
        ["data", (id, ctx) => this.deleteData(db, row, undefined)],
        ["auth", (id) => this.admin.delete(id)],
      ];
      for (const [name, action] of stages) {
        if (!asArray(row.completed).includes(name)) {
          await action(uid, row.cleanup_context ?? {});
          row.completed = [...asArray(row.completed), name];
          await db.save(row);
        }
      }
      row.state = "deleted";
      delete row.cleanup_context;
      await db.save(row);
      return publicState(row);
    });
  }
}

export function createLifecycle(deps: LifecycleDeps): Lifecycle {
  return new DeletionLifecycle(deps);
}
