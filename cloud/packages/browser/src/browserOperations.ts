/** Per-user browser operation fencing. Observation producers are wrapped in Task 10. */

import { AsyncLocalStorage } from "node:async_hooks";

export type BrowserOperationKind = "shared" | "credential";

export interface BrowserOperationOptions {
  kind: BrowserOperationKind;
  operationId: string;
  signal?: AbortSignal;
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
}

interface CredentialOperationContext {
  key: string;
  operationId: string;
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

  isCredentialOperationActive(key: string): boolean {
    return (this.entries.get(key)?.credentialPending ?? 0) > 0;
  }

  async withOperation<T>(
    key: string,
    options: BrowserOperationOptions,
    fn: () => Promise<T> | T,
  ): Promise<T> {
    // Cancellation always wins, including for a nested call on the live owner.
    if (options.signal?.aborted === true) throw abortError();
    const nested = this.credentialContext.getStore();
    if (nested?.key === key) {
      const active = this.entries.get(key)?.activeCredentialOperationId;
      if (nested.operationId === options.operationId && active === nested.operationId) {
        // Only the ACTIVE owner may reenter withSession. Detached descendants
        // retaining an old AsyncLocalStorage id never bypass the current fence.
        return await fn();
      }
      throw new BrowserOperationRefusal("credential_operation_in_progress");
    }
    return options.kind === "shared"
      ? await this.withShared(key, options.signal, fn)
      : await this.withCredential(key, options, fn);
  }

  private async withShared<T>(
    key: string,
    signal: AbortSignal | undefined,
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
      if (signal?.aborted === true) throw abortError();
      return await fn();
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
          { key, operationId: options.operationId },
          async () => await fn(),
        );
      } finally {
        if (entry.activeCredentialOperationId === options.operationId) {
          entry.activeCredentialOperationId = null;
        }
      }
    } finally {
      entry.credentialPending -= 1;
      release();
      this.prune(key, entry);
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
