/**
 * Storage error hierarchy. Every error carries a stable `code` string that
 * goes into logs (never secrets).
 */

export class StorageError extends Error {
  readonly code: string;

  constructor(message: string, opts?: { code?: string; cause?: unknown }) {
    super(message, opts?.cause === undefined ? undefined : { cause: opts.cause });
    this.name = new.target.name;
    this.code = opts?.code ?? "storage";
  }
}

/** Malformed key / path / segment (code "key_layout"). */
export class KeyLayoutError extends StorageError {
  constructor(message: string, opts?: { cause?: unknown }) {
    super(message, { code: "key_layout", cause: opts?.cause });
  }
}

/** Object absent from the store (code "not_found"). */
export class NotFoundError extends StorageError {
  constructor(message: string, opts?: { cause?: unknown }) {
    super(message, { code: "not_found", cause: opts?.cause });
  }
}

/** Workspace-state persistence failure (code "workspace_state"). */
export class WorkspaceStateError extends StorageError {
  constructor(message: string, opts?: { cause?: unknown }) {
    super(message, { code: "workspace_state", cause: opts?.cause });
  }
}
