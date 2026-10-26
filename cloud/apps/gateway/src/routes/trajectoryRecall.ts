import type { ExactHistoryItem, ExactRecallChunk } from "@ovid/shared";

/** Read-side exact recall only; no history writer or all-history fallback. */
export const RAW_HISTORY_MAX_CHUNKS = 50;
export const RAW_HISTORY_MAX_CHUNK_BYTES = 16 * 1024;
export const RAW_HISTORY_MAX_PAGE_DATA_BYTES = 256 * 1024;
export const RAW_HISTORY_MAX_ITEM_METADATA_BYTES = 4 * 1024;

export interface RawHistoryPage {
  chunks: ExactRecallChunk[];
  nextCursor: string | null;
}

export type RawProjectionRedactor = (value: unknown) => unknown;

export interface BoundedRawHistoryRead {
  sessionId: string;
  cursor: string | null;
  limit: number;
  chunkBytes: number;
  redact: RawProjectionRedactor;
}

/**
 * Production composition is supplied only by the approved bounded recall lane.
 * The adapter must scope its DB query by cursor/session, resolve object refs,
 * apply [redact] before chunking, and never reload all history.
 */
export interface BoundedRawHistoryRecall {
  read(input: BoundedRawHistoryRead): Promise<RawHistoryPage>;
}

export interface ExactHistoryObjectResolver {
  (objectRef: string): Promise<unknown>;
}

export class RawHistoryCursorError extends Error {}
export class RawHistoryContractError extends Error {}

function encodeCursor(id: string, nextOffset: number | null): string {
  return Buffer.from(JSON.stringify({ id, nextOffset }), "utf8").toString("base64url");
}

function decodeCursor(raw: string): { id: string; nextOffset: number | null } {
  try {
    const value = JSON.parse(Buffer.from(raw, "base64url").toString("utf8")) as Record<string, unknown>;
    if (typeof value.id !== "string" || value.id.length === 0 || value.id.length > 2048) {
      throw new RawHistoryCursorError("invalid raw cursor");
    }
    if (value.nextOffset !== null &&
      (!Number.isSafeInteger(value.nextOffset) || Number(value.nextOffset) < 0)) {
      throw new RawHistoryCursorError("invalid raw cursor");
    }
    return { id: value.id, nextOffset: value.nextOffset as number | null };
  } catch (error) {
    if (error instanceof RawHistoryCursorError) throw error;
    throw new RawHistoryCursorError("invalid raw cursor");
  }
}

function sliceUtf8(bytes: Buffer, start: number, maxBytes: number): {
  data: string;
  nextOffset: number | null;
} {
  let end = Math.min(bytes.length, start + maxBytes);
  if (end < bytes.length) {
    while (end > start && (bytes[end]! & 0xc0) === 0x80) end -= 1;
    // A leading four-byte sequence may straddle the cap. Move to its end;
    // the cap is enforced on the returned chunk by asserting maxBytes >= 4.
    if (end === start) end = Math.min(bytes.length, start + 4);
  }
  return {
    data: bytes.subarray(start, end).toString("utf8"),
    nextOffset: end < bytes.length ? end : null,
  };
}

/**
 * Pure single-item composition used by fixtures and by a future Task 10
 * adapter. Inline payloads are projected once, then only `data` slices carry
 * content. `inlinePayload:null` retains the schema's payload-form discriminator
 * without repeating the full payload in every chunk.
 */
export async function exactRecallItemPage(
  source: ExactHistoryItem,
  input: Omit<BoundedRawHistoryRead, "sessionId"> & {
    resolveObjectRef: ExactHistoryObjectResolver;
  },
): Promise<RawHistoryPage> {
  const limit = Math.min(RAW_HISTORY_MAX_CHUNKS, Math.max(1, Math.floor(input.limit)));
  const chunkBytes = Math.min(
    RAW_HISTORY_MAX_CHUNK_BYTES,
    Math.max(4, Math.floor(input.chunkBytes)),
  );
  const hasInline = Object.hasOwn(source, "inlinePayload");
  const hasReference = Object.hasOwn(source, "objectRef");
  if (hasInline === hasReference) throw new RawHistoryContractError("exact item payload form is ambiguous");

  const payload = hasInline
    ? source.inlinePayload
    : await input.resolveObjectRef(source.objectRef!);
  const projectedPayload = input.redact(payload);
  const data = JSON.stringify(projectedPayload ?? null);
  const bytes = Buffer.from(data, "utf8");

  const { inlinePayload: _inline, ...sourceMetadata } = source;
  const projectedMetadata = input.redact(sourceMetadata) as Record<string, unknown>;
  // Preserve the actual reference before redacting it. Destructuring objectRef
  // out of sourceMetadata made this undefined in the round-1 helper.
  const actualObjectRef = hasReference ? input.redact(source.objectRef!) : null;
  if (hasReference && typeof actualObjectRef !== "string") {
    throw new RawHistoryContractError("object ref projection is not a string");
  }
  const item = {
    ...projectedMetadata,
    byteLength: bytes.length,
    ...(hasInline
      ? { inlinePayload: null }
      : { objectRef: actualObjectRef }),
  } as ExactHistoryItem;
  if (Buffer.byteLength(JSON.stringify(item), "utf8") > RAW_HISTORY_MAX_ITEM_METADATA_BYTES) {
    throw new RawHistoryContractError("raw item metadata exceeds the response cap");
  }

  let offset = 0;
  if (input.cursor !== null) {
    const cursor = decodeCursor(input.cursor);
    if (cursor.id !== item.stableId) throw new RawHistoryCursorError("raw cursor does not match the item");
    if (cursor.nextOffset === null) return { chunks: [], nextCursor: null };
    offset = cursor.nextOffset;
    if (offset <= 0 || offset >= bytes.length) throw new RawHistoryCursorError("raw cursor offset is out of range");
  }

  const chunks: ExactRecallChunk[] = [];
  let nextCursor: string | null = null;
  let dataBytes = 0;
  while (offset < bytes.length && chunks.length < limit && dataBytes < RAW_HISTORY_MAX_PAGE_DATA_BYTES) {
    const budget = Math.min(chunkBytes, RAW_HISTORY_MAX_PAGE_DATA_BYTES - dataBytes);
    const part = sliceUtf8(bytes, offset, budget);
    if (Buffer.byteLength(part.data, "utf8") > chunkBytes) {
      throw new RawHistoryContractError("raw chunk exceeds the byte cap");
    }
    chunks.push({ item, offset, data: part.data, nextOffset: part.nextOffset });
    dataBytes += Buffer.byteLength(part.data, "utf8");
    if (part.nextOffset === null) {
      offset = bytes.length;
      break;
    }
    offset = part.nextOffset;
    if (chunks.length === limit || dataBytes >= RAW_HISTORY_MAX_PAGE_DATA_BYTES) {
      nextCursor = encodeCursor(item.stableId, part.nextOffset);
      break;
    }
  }
  return { chunks, nextCursor };
}

/** Reject an over-broad adapter response instead of silently re-chunking it. */
export function assertBoundedRawHistoryPage(
  page: RawHistoryPage,
  input: { limit: number; chunkBytes: number },
): void {
  if (page.chunks.length > input.limit || page.chunks.length > RAW_HISTORY_MAX_CHUNKS) {
    throw new RawHistoryContractError("too many raw chunks");
  }
  if (page.nextCursor !== null &&
    (typeof page.nextCursor !== "string" || page.nextCursor.length === 0 || page.nextCursor.length > 4096)) {
    throw new RawHistoryContractError("invalid raw next cursor");
  }
  let total = 0;
  for (const chunk of page.chunks) {
    if (!Number.isSafeInteger(chunk.offset) || chunk.offset < 0 ||
      (chunk.nextOffset !== null &&
        (!Number.isSafeInteger(chunk.nextOffset) || chunk.nextOffset <= chunk.offset))) {
      throw new RawHistoryContractError("invalid raw byte offsets");
    }
    if (Buffer.byteLength(JSON.stringify(chunk.item), "utf8") > RAW_HISTORY_MAX_ITEM_METADATA_BYTES) {
      throw new RawHistoryContractError("raw item metadata exceeds the response cap");
    }
    const hasInline = Object.hasOwn(chunk.item, "inlinePayload");
    const hasReference = Object.hasOwn(chunk.item, "objectRef");
    if (hasInline === hasReference ||
      (hasInline && chunk.item.inlinePayload !== null) ||
      (hasReference && typeof chunk.item.objectRef !== "string")) {
      throw new RawHistoryContractError("raw chunk repeats inline content or has an invalid object ref");
    }
    const bytes = Buffer.byteLength(chunk.data, "utf8");
    if (bytes > input.chunkBytes || bytes > RAW_HISTORY_MAX_CHUNK_BYTES) {
      throw new RawHistoryContractError("raw chunk exceeds the byte cap");
    }
    total += bytes;
    if (total > RAW_HISTORY_MAX_PAGE_DATA_BYTES) {
      throw new RawHistoryContractError("raw page exceeds the data cap");
    }
  }
}
