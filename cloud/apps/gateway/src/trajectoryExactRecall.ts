import { createHash } from "node:crypto";
import {
  readExactHistory,
  type CompactionExactObjectReader,
  type Db,
  type ExactHistoryEntry,
  type ExactHistoryPage,
} from "@ovid/db";
import { exactHistoryItemSchema, type ExactHistoryItem } from "@ovid/shared";
import { createEnvelopeCrypto, type EnvelopeCrypto } from "@ovid/escrow";
import {
  assertBoundedRawHistoryPage,
  exactRecallItemPage,
  RawHistoryContractError,
  RawHistoryCursorError,
  RAW_HISTORY_MAX_CHUNKS,
  RAW_HISTORY_MAX_CHUNK_BYTES,
  RAW_HISTORY_MAX_PAGE_DATA_BYTES,
  type BoundedRawHistoryRead,
  type BoundedRawHistoryRecall,
  type RawHistoryPage,
} from "./routes/trajectoryRecall.js";

export interface BoundedExactRecallRead extends BoundedRawHistoryRead {
  /** Optional canonical root scope. The DB validates this relationship; it is
   * never used to relabel an item whose stored root is null or different. */
  rootTaskRunId?: string;
  /** Omitted means owner-raw main-only. Worker recall requires an explicit root. */
  logicalWorkerId?: string | null;
  /** Optional exact attempt filter for worker recall; main recall normalizes to null. */
  attemptId?: string | null;
}

export interface BoundedExactRecall extends BoundedRawHistoryRecall {
  read(input: BoundedExactRecallRead): Promise<RawHistoryPage>;
}

export interface BoundedExactRecallDependencies {
  db: Db;
  /** Canonical/sealed exact-object reader owned by the eventual composition. */
  objects?: CompactionExactObjectReader;
  /** Dedicated 32-byte key (64 hex chars), shared by every gateway instance.
   * Missing/invalid configuration makes every recall read fail closed. */
  cursorSecret?: string;
}

export class RawHistoryCursorUnavailableError extends Error {
  readonly name = "RawHistoryCursorUnavailableError";

  constructor() {
    super("Exact-history cursor encryption is unavailable.");
  }
}

interface ExactRecallScope {
  rootTaskRunId?: string;
  logicalWorkerId: string | null;
  attemptId?: string | null;
}

interface ExactContentVersion {
  hash: string;
  bytes: number;
}

function exactRecallScope(input: BoundedExactRecallRead): ExactRecallScope {
  if (input.sessionId.length === 0 ||
    (input.rootTaskRunId !== undefined && input.rootTaskRunId.length === 0) ||
    (input.logicalWorkerId !== undefined && input.logicalWorkerId !== null &&
      input.logicalWorkerId.length === 0) ||
    (typeof input.attemptId === "string" && input.attemptId.length === 0)) {
    throw new RawHistoryContractError("exact-history scope IDs must be non-empty");
  }
  const logicalWorkerId = input.logicalWorkerId ?? null;
  if (logicalWorkerId === null && input.attemptId != null) {
    throw new RawHistoryContractError("attempt recall requires its logical worker");
  }
  if (logicalWorkerId !== null && input.rootTaskRunId === undefined) {
    throw new RawHistoryContractError("worker recall requires an explicit root");
  }
  return {
    ...(input.rootTaskRunId !== undefined ? { rootTaskRunId: input.rootTaskRunId } : {}),
    logicalWorkerId,
    attemptId: logicalWorkerId === null ? null : input.attemptId,
  };
}

function scopeCursorFields(scope: ExactRecallScope): Pick<RouteCursor,
  "rootTaskRunId" | "logicalWorkerId" | "attemptId" | "attemptIdSpecified"> {
  return {
    rootTaskRunId: scope.rootTaskRunId ?? null,
    logicalWorkerId: scope.logicalWorkerId,
    attemptId: scope.attemptId ?? null,
    attemptIdSpecified: scope.attemptId !== undefined,
  };
}

interface RouteCursor {
  sessionId: string;
  rootTaskRunId: string | null;
  logicalWorkerId: string | null;
  attemptId: string | null;
  attemptIdSpecified: boolean;
  /** DB cursor for the next one-item read. During item continuation this is
   * deliberately the cursor that re-reads the current item, not DB nextCursor. */
  dbCursor: string | null;
  /** Present only while an item's byte-offset continuation is in progress. */
  itemPosition: string | null;
  /** Actual stored stable ID, plus the redacted ID used by the inner slicer. */
  itemId: string | null;
  projectedItemId: string | null;
  itemOffset: number | null;
  contentHash: string | null;
  contentBytes: number | null;
}

const CURSOR_VERSION = 3;
const CURSOR_PREFIX = "v3.";
const CURSOR_AAD = "ovid:gateway:trajectory-exact-recall:cursor:v3";
const MAX_CURSOR_CHARS = 4096;

function invalidCursor(): never {
  throw new RawHistoryCursorError("invalid gateway raw-history cursor");
}

function cursorPosition(value: unknown): string | null {
  if (value === null) return null;
  if (typeof value !== "string" || !/^\d+$/.test(value)) invalidCursor();
  const numeric = Number(value);
  if (!Number.isSafeInteger(numeric) || numeric < 0) invalidCursor();
  return value;
}

function decodeRouteCursor(
  raw: string,
  input: BoundedExactRecallRead,
  scope: ExactRecallScope,
  crypto: EnvelopeCrypto,
): RouteCursor {
  if (raw.length === 0 || raw.length > MAX_CURSOR_CHARS || !raw.startsWith(CURSOR_PREFIX)) {
    invalidCursor();
  }
  try {
    const encoded = raw.slice(CURSOR_PREFIX.length);
    if (!/^[A-Za-z0-9_-]+$/.test(encoded)) invalidCursor();
    const serialized = Buffer.from(encoded, "base64url");
    if (serialized.toString("base64url") !== encoded) invalidCursor();
    const envelope = JSON.parse(serialized.toString("utf8")) as Parameters<EnvelopeCrypto["decrypt"]>[0];
    const plaintext = crypto.decrypt(envelope, CURSOR_AAD);
    const value = JSON.parse(plaintext) as Record<string, unknown>;
    if (value.v !== CURSOR_VERSION || value.sessionId !== input.sessionId ||
      value.rootTaskRunId !== (scope.rootTaskRunId ?? null) ||
      value.logicalWorkerId !== scope.logicalWorkerId ||
      value.attemptIdSpecified !== (scope.attemptId !== undefined) ||
      value.attemptId !== (scope.attemptId ?? null)) {
      invalidCursor();
    }
    const dbCursor = cursorPosition(value.dbCursor);
    const itemPosition = cursorPosition(value.itemPosition);
    const itemOffset = value.itemOffset;
    const itemId = value.itemId;
    const projectedItemId = value.projectedItemId;
    const contentHash = value.contentHash;
    const contentBytes = value.contentBytes;
    if (itemOffset === null) {
      if (itemPosition !== null || itemId !== null || projectedItemId !== null ||
        contentHash !== null || contentBytes !== null) {
        invalidCursor();
      }
    } else {
      const validId = (id: unknown): id is string => typeof id === "string" &&
        id.length > 0 && id.length <= 2048;
      if (!Number.isSafeInteger(itemOffset) || Number(itemOffset) <= 0 ||
        itemPosition === null || !validId(itemId) || !validId(projectedItemId) ||
        typeof contentHash !== "string" || !/^[a-f0-9]{64}$/.test(contentHash) ||
        !Number.isSafeInteger(contentBytes) || Number(contentBytes) < 0) {
        invalidCursor();
      }
    }
    return {
      sessionId: input.sessionId,
      ...scopeCursorFields(scope),
      dbCursor,
      itemPosition,
      itemId: itemId as string | null,
      projectedItemId: projectedItemId as string | null,
      itemOffset: itemOffset as number | null,
      contentHash: contentHash as string | null,
      contentBytes: contentBytes as number | null,
    };
  } catch (error) {
    if (error instanceof RawHistoryCursorError) throw error;
    invalidCursor();
  }
}

function encodeRouteCursor(cursor: RouteCursor, crypto: EnvelopeCrypto): string {
  const plaintext = JSON.stringify({
    v: CURSOR_VERSION,
    sessionId: cursor.sessionId,
    rootTaskRunId: cursor.rootTaskRunId,
    logicalWorkerId: cursor.logicalWorkerId,
    attemptId: cursor.attemptId,
    attemptIdSpecified: cursor.attemptIdSpecified,
    dbCursor: cursor.dbCursor,
    itemPosition: cursor.itemPosition,
    itemId: cursor.itemId,
    projectedItemId: cursor.projectedItemId,
    itemOffset: cursor.itemOffset,
    contentHash: cursor.contentHash,
    contentBytes: cursor.contentBytes,
  });
  const envelope = crypto.encrypt(plaintext, CURSOR_AAD);
  const encoded = `${CURSOR_PREFIX}${Buffer.from(JSON.stringify(envelope), "utf8").toString("base64url")}`;
  if (encoded.length > MAX_CURSOR_CHARS) {
    throw new RawHistoryContractError("gateway raw-history cursor exceeds the response cap");
  }
  return encoded;
}

function nextCursor(
  input: BoundedExactRecallRead,
  scope: ExactRecallScope,
  dbCursor: string,
  crypto: EnvelopeCrypto,
): string {
  return encodeRouteCursor({
    sessionId: input.sessionId,
    ...scopeCursorFields(scope),
    dbCursor,
    itemPosition: null,
    itemId: null,
    projectedItemId: null,
    itemOffset: null,
    contentHash: null,
    contentBytes: null,
  }, crypto);
}

function continuationCursor(
  input: BoundedExactRecallRead,
  scope: ExactRecallScope,
  dbCursor: string | null,
  entry: ExactHistoryEntry,
  itemId: string,
  projectedItemId: string,
  itemOffset: number,
  version: ExactContentVersion,
  crypto: EnvelopeCrypto,
): string {
  if (itemId.length === 0 || itemId.length > 2048 ||
    projectedItemId.length === 0 || projectedItemId.length > 2048 ||
    !Number.isSafeInteger(itemOffset) || itemOffset <= 0) {
    throw new RawHistoryContractError("exact-history item continuation cannot be represented safely");
  }
  return encodeRouteCursor({
    sessionId: input.sessionId,
    ...scopeCursorFields(scope),
    dbCursor,
    itemPosition: entry.position,
    itemId,
    projectedItemId,
    itemOffset,
    contentHash: version.hash,
    contentBytes: version.bytes,
  }, crypto);
}

function itemOffsetCursor(itemId: string, nextOffset: number): string {
  // exactRecallItemPage owns this inner cursor contract. It is never exposed as
  // the gateway cursor, and a bare inner cursor is rejected by decodeRouteCursor.
  return Buffer.from(JSON.stringify({ id: itemId, nextOffset }), "utf8").toString("base64url");
}

function validDbCursor(value: string | null): string | null {
  if (value === null) return null;
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) {
    throw new RawHistoryContractError("DB exact-history cursor is invalid");
  }
  return value;
}

function sourceItem(entry: ExactHistoryEntry, scope: ExactRecallScope): ExactHistoryItem {
  if (entry.data === null || entry.data === undefined) {
    throw new RawHistoryContractError("exact-history object data is unavailable");
  }
  if (!/^\d+$/.test(entry.position) || !Number.isSafeInteger(Number(entry.position))) {
    throw new RawHistoryContractError("exact-history item position is invalid");
  }
  const stored = entry.item;
  // A current root is query evidence, never per-item lineage evidence. Null or
  // contradictory stored lineage stays unreadable rather than being rewritten.
  if (stored.rootTaskRunId === null ||
    (scope.rootTaskRunId !== undefined && stored.rootTaskRunId !== scope.rootTaskRunId) ||
    stored.logicalWorkerId !== scope.logicalWorkerId ||
    (scope.logicalWorkerId === null && stored.attemptId !== null) ||
    (scope.attemptId !== undefined && stored.attemptId !== scope.attemptId)) {
    throw new RawHistoryContractError("exact-history item lineage does not match the requested scope");
  }
  if (Object.hasOwn(stored, "inlinePayload")) {
    // The DB entry's resolved data is authoritative even for legacy inline rows.
    return { ...stored, rootTaskRunId: stored.rootTaskRunId, inlinePayload: entry.data };
  }
  return { ...stored, rootTaskRunId: stored.rootTaskRunId };
}

function exactContentVersion(source: ExactHistoryItem, data: unknown): ExactContentVersion {
  let serialized: string | undefined;
  try {
    // Include every identity/lineage/reference field as well as the currently
    // resolved canonical value. Any canonical mutation invalidates continuation.
    serialized = JSON.stringify({ item: source, data });
  } catch {
    throw new RawHistoryContractError("exact-history content cannot be versioned safely");
  }
  if (serialized === undefined) {
    throw new RawHistoryContractError("exact-history content cannot be versioned safely");
  }
  const bytes = Buffer.from(serialized, "utf8");
  return { hash: createHash("sha256").update(bytes).digest("hex"), bytes: bytes.length };
}

function assertProjectedItems(page: RawHistoryPage): void {
  for (const chunk of page.chunks) {
    if (!exactHistoryItemSchema.safeParse(chunk.item).success) {
      throw new RawHistoryContractError("redacted exact-history metadata violates the shared contract");
    }
  }
}

/**
 * Gateway-local read adapter only. It is intentionally not composed into the
 * application: the route remains unavailable until an authorized object reader
 * and server-derived root scope are supplied by a later integration lane.
 */
export function createBoundedExactRecall({
  db,
  objects,
  cursorSecret,
}: BoundedExactRecallDependencies): BoundedExactRecall {
  let configuredCrypto: EnvelopeCrypto | null = null;
  if (cursorSecret !== undefined) {
    try {
      configuredCrypto = createEnvelopeCrypto(cursorSecret);
    } catch {
      configuredCrypto = null;
    }
  }
  function requireCursorCrypto(): EnvelopeCrypto {
    if (configuredCrypto === null) throw new RawHistoryCursorUnavailableError();
    return configuredCrypto;
  }

  async function readOne(
    input: BoundedExactRecallRead,
    scope: ExactRecallScope,
    cursor: string | null,
  ): Promise<ExactHistoryPage> {
    const page = await readExactHistory(db, {
      sessionId: input.sessionId,
      ...(scope.rootTaskRunId !== undefined ? { rootTaskRunId: scope.rootTaskRunId } : {}),
      logicalWorkerId: scope.logicalWorkerId,
      ...(scope.attemptId !== undefined ? { attemptId: scope.attemptId } : {}),
      cursor: cursor ?? undefined,
      limit: 1,
    }, objects);
    if (page.items.length > 1 || (page.items.length === 0 && page.nextCursor !== null)) {
      throw new RawHistoryContractError("DB exact-history page exceeds its one-item contract");
    }
    validDbCursor(page.nextCursor);
    return page;
  }

  return {
    async read(input: BoundedExactRecallRead): Promise<RawHistoryPage> {
      const cursorCrypto = requireCursorCrypto();
      const scope = exactRecallScope(input);
      const limit = Math.min(RAW_HISTORY_MAX_CHUNKS, Math.max(1, Math.floor(input.limit)));
      const chunkBytes = Math.min(
        RAW_HISTORY_MAX_CHUNK_BYTES,
        Math.max(4, Math.floor(input.chunkBytes)),
      );
      if (!Number.isSafeInteger(limit) || !Number.isSafeInteger(chunkBytes)) {
        throw new RawHistoryContractError("raw-history bounds must be finite numbers");
      }
      const finish = (page: RawHistoryPage): RawHistoryPage => {
        assertBoundedRawHistoryPage(page, { limit, chunkBytes });
        return page;
      };

      const resumed = input.cursor === null ? null : decodeRouteCursor(input.cursor, input, scope, cursorCrypto);
      let dbCursor = resumed?.dbCursor ?? null;
      let continuation = resumed !== null && resumed.itemOffset !== null ? resumed : null;
      const chunks: RawHistoryPage["chunks"] = [];
      let dataBytes = 0;

      while (chunks.length < limit && dataBytes < RAW_HISTORY_MAX_PAGE_DATA_BYTES) {
        const remainingBytes = RAW_HISTORY_MAX_PAGE_DATA_BYTES - dataBytes;
        if (remainingBytes < 4) {
          return finish({ chunks, nextCursor: dbCursor === null ? null : nextCursor(input, scope, dbCursor, cursorCrypto) });
        }

        const page = await readOne(input, scope, dbCursor);
        const entry = page.items[0];
        if (!entry) {
          if (continuation !== null) invalidCursor();
          return finish({ chunks, nextCursor: null });
        }
        if (continuation !== null && entry.position !== continuation.itemPosition) {
          invalidCursor();
        }

        const source = sourceItem(entry, scope);
        const version = exactContentVersion(source, entry.data);
        if (continuation !== null &&
          (source.stableId !== continuation.itemId ||
            version.hash !== continuation.contentHash ||
            version.bytes !== continuation.contentBytes)) {
          invalidCursor();
        }
        const hasReference = Object.hasOwn(source, "objectRef");
        const actualObjectRef = source.objectRef;
        const itemChunkBytes = Math.min(chunkBytes, remainingBytes);
        const itemLimit = Math.min(
          limit - chunks.length,
          Math.max(1, Math.floor(remainingBytes / itemChunkBytes)),
        );
        const projected = await exactRecallItemPage(source, {
          cursor: continuation === null
            ? null
            : itemOffsetCursor(continuation.projectedItemId!, continuation.itemOffset!),
          limit: itemLimit,
          chunkBytes: itemChunkBytes,
          redact: input.redact,
          resolveObjectRef: async (reference) => {
            if (!hasReference || reference !== actualObjectRef) {
              throw new RawHistoryContractError("exact-history object reference changed during recall");
            }
            // readExactHistory has already used the injected canonical reader.
            // Returning that resolved value avoids any path/secret/file fallback.
            return entry.data;
          },
        });
        assertBoundedRawHistoryPage(projected, { limit: itemLimit, chunkBytes: itemChunkBytes });
        assertProjectedItems(projected);
        if (projected.chunks.length === 0) {
          throw new RawHistoryContractError("exact-history item produced no recoverable data");
        }

        chunks.push(...projected.chunks);
        dataBytes += projected.chunks.reduce(
          (sum, chunk) => sum + Buffer.byteLength(chunk.data, "utf8"),
          0,
        );
        if (projected.nextCursor !== null) {
          const last = projected.chunks[projected.chunks.length - 1]!;
          if (last.nextOffset === null) {
            throw new RawHistoryContractError("exact-history continuation has no byte offset");
          }
          return finish({
            chunks,
            nextCursor: continuationCursor(
              input,
              scope,
              dbCursor,
              entry,
              source.stableId,
              last.item.stableId,
              last.nextOffset,
              version,
              cursorCrypto,
            ),
          });
        }

        continuation = null;
        if (page.nextCursor === null) return finish({ chunks, nextCursor: null });
        dbCursor = page.nextCursor;
        if (chunks.length >= limit || dataBytes >= RAW_HISTORY_MAX_PAGE_DATA_BYTES ||
          RAW_HISTORY_MAX_PAGE_DATA_BYTES - dataBytes < 4) {
          return finish({ chunks, nextCursor: nextCursor(input, scope, dbCursor, cursorCrypto) });
        }
      }

      return finish({
        chunks,
        nextCursor: dbCursor === null ? null : nextCursor(input, scope, dbCursor, cursorCrypto),
      });
    },
  };
}
