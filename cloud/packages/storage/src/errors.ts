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

/**
 * Workspace-state failure (default code "workspace_state"). Callers may pin a
 * more specific code — Task 9's pinned surfaces are "not_warm" (a write
 * against a cold workspace) and "hydrate_timeout" (awaitWarm gave up).
 */
export class WorkspaceStateError extends StorageError {
  constructor(message: string, opts?: { cause?: unknown; code?: string }) {
    super(message, { code: opts?.code ?? "workspace_state", cause: opts?.cause });
  }
}

/** Archive bytes fail a structural check (code "archive_corrupt"). */
export class ArchiveCorruptError extends StorageError {
  constructor(message: string, opts?: { cause?: unknown }) {
    super(message, { code: "archive_corrupt", cause: opts?.cause });
  }
}

/** Archive is shorter than its own footer (code "archive_truncated"). */
export class ArchiveTruncatedError extends StorageError {
  constructor(message: string, opts?: { cause?: unknown }) {
    super(message, { code: "archive_truncated", cause: opts?.cause });
  }
}

/** Content hash disagrees with the index (code "hash_mismatch"). */
export class HashMismatchError extends StorageError {
  constructor(message: string, opts?: { cause?: unknown }) {
    super(message, { code: "hash_mismatch", cause: opts?.cause });
  }
}

/** Path absent from the archive index (code "file_not_in_archive"). */
export class FileNotInArchiveError extends StorageError {
  constructor(message: string, opts?: { cause?: unknown }) {
    super(message, { code: "file_not_in_archive", cause: opts?.cause });
  }
}

/** Member exceeds the v1 size ceiling (code "file_too_large"). */
export class FileTooLargeError extends StorageError {
  /** The offending size in bytes. */
  readonly sizeBytes: number;

  constructor(message: string, opts: { sizeBytes: number; cause?: unknown }) {
    super(message, { code: "file_too_large", cause: opts.cause });
    this.sizeBytes = opts.sizeBytes;
  }
}
