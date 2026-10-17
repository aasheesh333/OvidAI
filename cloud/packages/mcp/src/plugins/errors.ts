// Failure families for plugin ingestion. They surface as WS system-event
// outcome reasons / PluginDto status text, never as REST response codes
// (see the P5 plan's error-envelope ruling).

/** The source descriptor or downloaded source is invalid (`invalid_source`). */
export class PluginSourceError extends Error {
  readonly code = "invalid_source";
  constructor(message: string) {
    super(message);
    this.name = "PluginSourceError";
  }
}

/** The archive is unsafe to extract (`archive_unsafe`). */
export class ArchiveUnsafeError extends Error {
  readonly code = "archive_unsafe";
  constructor(message: string) {
    super(message);
    this.name = "ArchiveUnsafeError";
  }
}
