/** Per-user browser operation fencing. Observation producers are wrapped in Task 10. */

import { AsyncLocalStorage } from "node:async_hooks";

export type BrowserOperationKind = "shared" | "credential";
export const CREDENTIAL_OPERATION_REFUSAL = "error: credential_operation_in_progress";

export interface BrowserOperationOptions {
  kind: BrowserOperationKind;
  operationId: string;
  signal?: AbortSignal;
  /** Present for real credential work so close() can abort, then await its fenced cleanup. */
  abortController?: AbortController;
  /** Internal lifecycle cleanup only; ordinary tools never set this after engine/pool close begins. */
  allowAfterClose?: boolean;
}

export class BrowserOperationRefusal extends Error {
  readonly code: "credential_operation_in_progress" | "operation_aborted";

  constructor(code: BrowserOperationRefusal["code"]) {
    super(code);
    this.name = "BrowserOperationRefusal";
    this.code = code;
  }
}

interface OperationEntry {
  shared: number;
  sharedDrain: Promise<void> | null;
  resolveSharedDrain: (() => void) | null;
  credentialTail: Promise<void>;
  /** The operation currently executing fn; pending work alone is not a reentrancy owner. */
  activeCredentialOperationId: string | null;
  /** Queued + active exclusive work. New shared work must refuse for this whole interval. */
  credentialPending: number;
  /** Real broker controllers, aborted by close() before awaiting credentialTail. */
  credentialControllers: Set<AbortController>;
}

interface CredentialOperationContext {
  key: string;
  operationId: string;
  kind: BrowserOperationKind;
}

function abortError(): BrowserOperationRefusal {
  return new BrowserOperationRefusal("operation_aborted");
}

async function waitForAdmission(wait: Promise<unknown>, signal: AbortSignal | undefined): Promise<void> {
  if (signal?.aborted === true) throw abortError();
  if (signal === undefined) {
    await wait;
    return;
  }
  let onAbort: (() => void) | undefined;
  const aborted = new Promise<never>((_resolve, reject) => {
    onAbort = () => reject(abortError());
    signal.addEventListener("abort", onAbort, { once: true });
  });
  try {
    await Promise.race([wait, aborted]);
  } finally {
    if (onAbort !== undefined) signal.removeEventListener("abort", onAbort);
  }
}

export class BrowserOperationCoordinator {
  private readonly entries = new Map<string, OperationEntry>();
  private readonly credentialContext = new AsyncLocalStorage<CredentialOperationContext>();
  private readonly credentialListeners = new Set<(key: string, active: boolean) => void>();
  /** Monotonic per-key invalidation epochs; retained after entries prune so old completions never become fresh again. */
  private readonly credentialEpochs = new Map<string, number>();
  private closed = false;
  private closePromise: Promise<void> | null = null;

  isCredentialOperationActive(key: string): boolean {
    return (this.entries.get(key)?.credentialPending ?? 0) > 0;
  }

  credentialEpoch(key: string): number {
    return this.credentialEpochs.get(key) ?? 0;
  }

  /** True only inside the currently admitted owner callback, never for a detached old operation. */
  isCredentialOperationOwner(key: string): boolean {
    const nested = this.credentialContext.getStore();
    const active = this.entries.get(key)?.activeCredentialOperationId;
    return nested?.key === key && active !== null && nested.operationId === active;
  }

  addCredentialOperationListener(listener: (key: string, active: boolean) => void): () => void {
    this.credentialListeners.add(listener);
    return () => this.credentialListeners.delete(listener);
  }

  /** Abort every real broker, then wait for its exclusive cleanup before any context is released. */
  close(): Promise<void> {
    if (this.closePromise !== null) return this.closePromise;
    this.closed = true;
    const waits: Promise<unknown>[] = [];
    for (const entry of this.entries.values()) {
      for (const controller of entry.credentialControllers) controller.abort();
      waits.push(entry.credentialTail);
      if (entry.sharedDrain !== null) waits.push(entry.sharedDrain);
    }
    this.closePromise = Promise.all(waits).then(() => undefined);
    return this.closePromise;
  }

  async withOperation<T>(
    key: string,
    options: BrowserOperationOptions,
    fn: () => Promise<T> | T,
  ): Promise<T> {
    // Cancellation/close always wins, including for a nested call on the live owner.
    if ((this.closed && options.allowAfterClose !== true) || options.signal?.aborted === true) {
      throw abortError();
    }
    const nested = this.credentialContext.getStore();
    if (nested?.key === key) {
      const entry = this.entries.get(key);
      const active = entry?.activeCredentialOperationId;
      if (nested.operationId === options.operationId && active === nested.operationId) {
        // Only the ACTIVE credential owner may reenter withSession. Detached
        // descendants retaining an old id never bypass the current fence.
        return await fn();
      }
      if (nested.kind === "shared" && options.kind === "shared") {
        if (nested.operationId === options.operationId && (entry?.shared ?? 0) > 0) {
          // A lifecycle operation may nest its pool/session half under the SAME
          // shared id; a detached old shared id cannot reenter after it drains.
          return await fn();
        }
        // Ordinary tools legitimately nest pool/session shared work. Count it
        // against the same shared drain; withShared still refuses if an
        // exclusive operation became pending in the meantime.
        return await this.withShared(key, options, fn);
      }
      throw new BrowserOperationRefusal("credential_operation_in_progress");
    }
    return options.kind === "shared"
      ? await this.withShared(key, options, fn)
      : await this.withCredential(key, options, fn);
  }

  private async withShared<T>(
    key: string,
    options: BrowserOperationOptions,
    fn: () => Promise<T> | T,
  ): Promise<T> {
    const existing = this.entries.get(key);
    if (existing !== undefined && existing.credentialPending > 0) {
      throw new BrowserOperationRefusal("credential_operation_in_progress");
    }
    const entry = existing ?? this.createEntry(key);
    if (entry.shared === 0) {
      let resolve!: () => void;
      entry.sharedDrain = new Promise<void>((res) => {
        resolve = res;
      });
      entry.resolveSharedDrain = resolve;
    }
    entry.shared += 1;
    try {
      if (options.signal?.aborted === true) throw abortError();
      return await this.credentialContext.run(
        { key, operationId: options.operationId, kind: "shared" },
        async () => await fn(),
      );
    } finally {
      entry.shared -= 1;
      if (entry.shared === 0) {
        entry.resolveSharedDrain?.();
        entry.sharedDrain = null;
        entry.resolveSharedDrain = null;
        this.prune(key, entry);
      }
    }
  }

  private async withCredential<T>(
    key: string,
    options: BrowserOperationOptions,
    fn: () => Promise<T> | T,
  ): Promise<T> {
    const entry = this.entries.get(key) ?? this.createEntry(key);
    entry.credentialPending += 1;
    if (entry.credentialPending === 1) {
      this.credentialEpochs.set(key, this.credentialEpoch(key) + 1);
      this.notifyCredentialChange(key, true);
    }
    if (options.abortController !== undefined) entry.credentialControllers.add(options.abortController);

    // Mark pending BEFORE capturing the drain. Every shared operation already
    // present is in this drain; every later one refuses instead of queueing.
    const previousCredential = entry.credentialTail;
    const sharedDrain = entry.sharedDrain ?? Promise.resolve();
    let release!: () => void;
    const ownTail = new Promise<void>((res) => {
      release = res;
    });
    entry.credentialTail = ownTail;
    try {
      await waitForAdmission(
        Promise.all([previousCredential, sharedDrain]),
        options.signal,
      );
      if (options.signal?.aborted === true) throw abortError();
      entry.activeCredentialOperationId = options.operationId;
      try {
        return await this.credentialContext.run(
          { key, operationId: options.operationId, kind: "credential" },
          async () => await fn(),
        );
      } finally {
        if (entry.activeCredentialOperationId === options.operationId) {
          entry.activeCredentialOperationId = null;
        }
      }
    } finally {
      if (options.abortController !== undefined) entry.credentialControllers.delete(options.abortController);
      entry.credentialPending -= 1;
      release();
      if (entry.credentialPending === 0) this.notifyCredentialChange(key, false);
      this.prune(key, entry);
    }
  }

  private notifyCredentialChange(key: string, active: boolean): void {
    for (const listener of this.credentialListeners) {
      try {
        listener(key, active);
      } catch {
        // Observation fencing must not depend on a consumer notification hook.
      }
    }
  }

  private createEntry(key: string): OperationEntry {
    const entry: OperationEntry = {
      shared: 0,
      sharedDrain: null,
      resolveSharedDrain: null,
      credentialTail: Promise.resolve(),
      activeCredentialOperationId: null,
      credentialPending: 0,
      credentialControllers: new Set(),
    };
    this.entries.set(key, entry);
    return entry;
  }

  private prune(key: string, entry: OperationEntry): void {
    if (entry.shared === 0 && entry.credentialPending === 0 && this.entries.get(key) === entry) {
      this.entries.delete(key);
    }
  }
}
