import type { Transform } from "node:stream";
import { createBrotliDecompress, createGunzip, createInflate } from "node:zlib";

import type { EgressLimits, EgressResponse } from "./providerEgress.js";

// Task 2 owns the pinned transport and these request/response contracts.
// This module only consumes them; it is not a second egress implementation.
export type {
  EgressLimits,
  EgressRequest,
  EgressResponse,
  ProviderEgress,
} from "./providerEgress.js";

export interface StreamLimits extends EgressLimits {
  sseEventBytes: number;
  sseEventCount: number;
  jsonRpcFrameBytes: number;
  aggregateStreamBytes: number;
  toolResultBytes: number;
}

export const DEFAULT_STREAM_LIMITS: StreamLimits = {
  connectMs: 5_000,
  headersMs: 15_000,
  idleMs: 30_000,
  totalMs: 120_000,
  maxRedirects: 0,
  headerBytes: 16_384,
  responseBytes: 1_048_576,
  decompressedBytes: 4_194_304,
  sseEventBytes: 1_048_576,
  sseEventCount: 10_000,
  jsonRpcFrameBytes: 1_048_576,
  aggregateStreamBytes: 4_194_304,
  toolResultBytes: 8_192,
};

export const DEFAULT_EGRESS_LIMITS: EgressLimits = {
  connectMs: DEFAULT_STREAM_LIMITS.connectMs,
  headersMs: DEFAULT_STREAM_LIMITS.headersMs,
  idleMs: DEFAULT_STREAM_LIMITS.idleMs,
  totalMs: DEFAULT_STREAM_LIMITS.totalMs,
  maxRedirects: 0,
  headerBytes: DEFAULT_STREAM_LIMITS.headerBytes,
  responseBytes: DEFAULT_STREAM_LIMITS.responseBytes,
  decompressedBytes: DEFAULT_STREAM_LIMITS.decompressedBytes,
};

export class EgressLimitError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "EgressLimitError";
  }
}

const encoder = new TextEncoder();
const utf8Bytes = (value: string): number => encoder.encode(value).byteLength;

/** Header bytes are checked before any body/frame parser consumes the stream. */
export function assertBoundedHeaders(response: EgressResponse, limits: EgressLimits): void {
  let bytes = 0;
  response.headers.forEach((value, name) => {
    bytes += utf8Bytes(name) + utf8Bytes(value) + 4;
  });
  if (bytes > limits.headerBytes) throw new EgressLimitError("header_bytes_exceeded");
}

/** Validate before handoff and deterministically cancel an unused body on failure. */
export async function assertBoundedHeadersOrCancel(
  response: EgressResponse,
  limits: EgressLimits,
): Promise<void> {
  try {
    assertBoundedHeaders(response, limits);
  } catch (error) {
    await response.body.cancel().catch(() => {});
    throw error;
  }
}

function declaredLength(response: EgressResponse): number | null {
  const raw = response.headers.get("content-length");
  if (raw === null) return null;
  if (!/^\d{1,15}$/.test(raw.trim())) throw new EgressLimitError("content_length_invalid");
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed)) throw new EgressLimitError("content_length_invalid");
  return parsed;
}

function contentEncoding(response: EgressResponse): "identity" | "gzip" | "deflate" | "br" {
  const value = (response.headers.get("content-encoding") ?? "identity").trim().toLowerCase();
  if (value === "" || value === "identity") return "identity";
  if (value === "gzip" || value === "x-gzip") return "gzip";
  if (value === "deflate") return "deflate";
  if (value === "br") return "br";
  throw new EgressLimitError("content_encoding_unsupported");
}

interface ChunkCaps {
  compressedBytes: number;
  decompressedBytes: number;
  compressedCode: "response_bytes_exceeded" | "aggregate_stream_bytes_exceeded";
  idleMs: number;
  totalMs: number;
}

async function nextChunk(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  startedAt: number,
  limits: ChunkCaps,
): Promise<ReadableStreamReadResult<Uint8Array>> {
  const remaining = limits.totalMs - (Date.now() - startedAt);
  if (remaining <= 0) throw new EgressLimitError("total_timeout");
  const waitMs = Math.max(1, Math.min(limits.idleMs, remaining));
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      reject(new EgressLimitError(waitMs === remaining ? "total_timeout" : "idle_timeout"));
    }, waitMs);
    timer.unref?.();
  });
  try {
    return await Promise.race([reader.read(), timeout]);
  } catch (error) {
    if (error instanceof EgressLimitError) throw error;
    throw new EgressLimitError("response_read_failed");
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

async function* compressedChunks(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  declared: number | null,
  limits: ChunkCaps,
): AsyncGenerator<Uint8Array> {
  const startedAt = Date.now();
  let total = 0;
  while (true) {
    const { done, value } = await nextChunk(reader, startedAt, limits);
    if (done) break;
    if (value.byteLength === 0) continue;
    total += value.byteLength;
    if (total > limits.compressedBytes) throw new EgressLimitError(limits.compressedCode);
    yield value;
  }
  if (declared !== null && total !== declared) throw new EgressLimitError("content_length_mismatch");
}

function decompressorFor(encoding: "gzip" | "deflate" | "br", maxOutputBytes: number): Transform {
  const options = { chunkSize: Math.max(64, Math.min(16_384, maxOutputBytes)) };
  if (encoding === "gzip") return createGunzip(options);
  if (encoding === "deflate") return createInflate(options);
  return createBrotliDecompress(options);
}

/**
 * Stream output through Transform's async iterator, whose read side applies
 * backpressure to zlib and the input writer. The byte cap is checked inside
 * this decompression loop BEFORE any output reaches the body/SSE consumer;
 * overflow destroys the transform immediately and fails the input writer.
 */
async function* inflateChunks(
  source: AsyncIterable<Uint8Array>,
  encoding: "gzip" | "deflate" | "br",
  maxOutputBytes: number,
): AsyncGenerator<Uint8Array> {
  const transform = decompressorFor(encoding, maxOutputBytes);
  const outputChunks: AsyncIterable<Buffer> = transform;
  let writerError: unknown;
  const writing = (async (): Promise<void> => {
    try {
      for await (const chunk of source) {
        await new Promise<void>((resolve, reject) => {
          transform.write(chunk, (error: Error | null | undefined) => {
            if (error === null || error === undefined) resolve();
            else reject(error);
          });
        });
      }
      await new Promise<void>((resolve, reject) => {
        transform.end((error: Error | null | undefined) => {
          if (error === null || error === undefined) resolve();
          else reject(error);
        });
      });
    } catch (error) {
      writerError = error;
      transform.destroy();
      throw error;
    }
  })();
  // The consumer below always awaits this promise; this handler only prevents
  // an early writer rejection from becoming an unhandled rejection first.
  void writing.catch(() => {});

  let outputBytes = 0;
  try {
    for await (const chunk of outputChunks) {
      outputBytes += chunk.byteLength;
      if (outputBytes > maxOutputBytes) throw new EgressLimitError("decompressed_bytes_exceeded");
      yield chunk;
    }
    await writing;
  } catch (error) {
    transform.destroy();
    if (error instanceof EgressLimitError) throw error;
    if (writerError instanceof EgressLimitError) throw writerError;
    throw new EgressLimitError("decompression_failed");
  } finally {
    // Do not await the writer here: it may be blocked on the next source
    // chunk. The outer bounded reader cancels that reader immediately.
    transform.destroy();
  }
}

interface DecodedStream {
  reader: ReadableStreamDefaultReader<Uint8Array>;
  chunks: AsyncIterable<Uint8Array>;
}

function decodedStream(
  response: EgressResponse,
  limits: EgressLimits,
  streamLimits?: StreamLimits,
): DecodedStream {
  assertBoundedHeaders(response, limits);
  const declared = declaredLength(response);
  const encoding = contentEncoding(response);
  const compressedCap = streamLimits?.aggregateStreamBytes ?? limits.responseBytes;
  if (declared !== null && declared > compressedCap) {
    throw new EgressLimitError(streamLimits === undefined ? "response_bytes_exceeded" : "aggregate_stream_bytes_exceeded");
  }
  if (encoding === "identity" && declared !== null && streamLimits === undefined && declared > limits.decompressedBytes) {
    throw new EgressLimitError("decompressed_bytes_exceeded");
  }
  const caps: ChunkCaps = {
    compressedBytes: encoding === "identity" && streamLimits === undefined
      ? Math.min(compressedCap, limits.decompressedBytes)
      : compressedCap,
    decompressedBytes: streamLimits === undefined
      ? limits.decompressedBytes
      : Math.min(limits.decompressedBytes, streamLimits.aggregateStreamBytes),
    compressedCode: streamLimits === undefined ? "response_bytes_exceeded" : "aggregate_stream_bytes_exceeded",
    idleMs: limits.idleMs,
    totalMs: limits.totalMs,
  };
  const reader = response.body.getReader();
  const raw = compressedChunks(reader, declared, caps);
  return {
    reader,
    chunks: encoding === "identity" ? raw : inflateChunks(raw, encoding, caps.decompressedBytes),
  };
}

async function cancel(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<void> {
  await reader.cancel().catch(() => {});
}

export async function readBoundedBody(
  response: EgressResponse,
  limits: EgressLimits,
): Promise<Uint8Array> {
  let stream: DecodedStream | undefined;
  try {
    stream = decodedStream(response, limits);
    const parts: Uint8Array[] = [];
    let total = 0;
    for await (const chunk of stream.chunks) {
      total += chunk.byteLength;
      if (total > limits.decompressedBytes) throw new EgressLimitError("decompressed_bytes_exceeded");
      parts.push(chunk);
    }
    const result = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      result.set(part, offset);
      offset += part.byteLength;
    }
    return result;
  } catch (error) {
    if (stream !== undefined) await cancel(stream.reader);
    else await response.body.cancel().catch(() => {});
    throw error;
  }
}

export async function readBoundedSse(
  response: EgressResponse,
  limits: StreamLimits,
  onEvent: (data: string) => void,
): Promise<void> {
  let stream: DecodedStream | undefined;
  try {
    stream = decodedStream(response, limits, limits);
    const decoder = new TextDecoder();
    let buffer = "";
    let dataLines: string[] = [];
    let eventBytes = 0;
    let eventCount = 0;
    let decodedBytes = 0;

    const flushEvent = (): void => {
      if (dataLines.length === 0) {
        eventBytes = 0;
        return;
      }
      eventCount++;
      if (eventCount > limits.sseEventCount) throw new EgressLimitError("sse_event_count_exceeded");
      const data = dataLines.join("\n");
      if (utf8Bytes(data) > limits.jsonRpcFrameBytes) {
        throw new EgressLimitError("jsonrpc_frame_bytes_exceeded");
      }
      dataLines = [];
      eventBytes = 0;
      onEvent(data);
    };

    const handleLine = (line: string): void => {
      eventBytes += utf8Bytes(line) + 1;
      if (eventBytes > limits.sseEventBytes) throw new EgressLimitError("sse_event_bytes_exceeded");
      if (line === "") {
        flushEvent();
        return;
      }
      if (line.startsWith(":")) return;
      const colon = line.indexOf(":");
      const field = colon < 0 ? line : line.slice(0, colon);
      let value = colon < 0 ? "" : line.slice(colon + 1);
      if (value.startsWith(" ")) value = value.slice(1);
      if (field === "data") dataLines.push(value);
    };

    for await (const chunk of stream.chunks) {
      decodedBytes += chunk.byteLength;
      if (decodedBytes > limits.aggregateStreamBytes) {
        throw new EgressLimitError("aggregate_stream_bytes_exceeded");
      }
      if (decodedBytes > limits.decompressedBytes) {
        throw new EgressLimitError("decompressed_bytes_exceeded");
      }
      buffer += decoder.decode(chunk, { stream: true });
      let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const raw = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        handleLine(raw.endsWith("\r") ? raw.slice(0, -1) : raw);
      }
      if (utf8Bytes(buffer) > limits.sseEventBytes) {
        throw new EgressLimitError("sse_event_bytes_exceeded");
      }
    }
    buffer += decoder.decode();
    if (buffer !== "") handleLine(buffer.replace(/\r$/, ""));
    handleLine("");
  } catch (error) {
    if (stream !== undefined) await cancel(stream.reader);
    else await response.body.cancel().catch(() => {});
    throw error;
  }
}

/** Adapt an already-decoded legacy Fetch response without another network path. */
export function egressResponseFromDecodedFetch(response: Response, url: URL): EgressResponse {
  const headers = new Headers(response.headers);
  headers.delete("content-encoding");
  headers.delete("content-length");
  return {
    status: response.status,
    headers,
    body: response.body ?? emptyEgressBody(),
    origin: new URL(response.url || url),
    remoteAddress: "legacy-fetch-unverified",
  };
}

/** Used only to construct a legacy Response adapter; no body is read here. */
export function emptyEgressBody(): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>({
    start(controller) {
      controller.close();
    },
  });
}
