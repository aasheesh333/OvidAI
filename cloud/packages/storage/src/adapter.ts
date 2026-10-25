/**
 * The storage seam: one interface, two adapters (fs for tests/dev, R2 for
 * prod — Task 2). Keys are R2-layout strings (keys.ts); the fs adapter maps
 * them onto a local directory with per-segment safety asserts.
 */

export interface PutResult {
  key: string;
  bytes: number;
}

export interface HeadResult {
  bytes: number;
  sha256Hex: string | null;
  etag: string | null;
  metadata: Record<string, string>;
  /** Actual stored type, or null when the backend has none. */
  contentType?: string | null;
}

export interface PresignPutInput {
  key: string;
  ttlSeconds: number;
  /** Declared canonical type to bind into the PUT signature. */
  contentType?: string;
}

export interface PresignGetOptions {
  /** Active user content is always downloaded, never rendered in the Ovid origin. */
  disposition: "attachment";
  filename?: string;
  contentType?: string;
}

export function attachmentContentDisposition(filename: string | undefined): string {
  const safe = (filename ?? "download")
    .split(/[\\/]/).pop()!
    .replace(/[\r\n"]/g, "")
    .replace(/[^A-Za-z0-9._ -]+/g, "_")
    .trim()
    .slice(0, 120) || "download";
  return `attachment; filename="${safe}"`;
}

export interface PutOpts {
  contentType?: string;
  sha256Hex?: string;
  metadata?: Record<string, string>;
}

export interface StorageAdapter {
  readonly kind: "fs" | "r2";
  put(
    key: string,
    body: NodeJS.ReadableStream | Buffer | Uint8Array,
    opts?: PutOpts,
  ): Promise<PutResult>;
  /** null = missing. */
  get(key: string): Promise<NodeJS.ReadableStream | null>;
  getBuffer(key: string): Promise<Buffer | null>;
  head(key: string): Promise<HeadResult | null>;
  /** Idempotent. */
  delete(key: string): Promise<void>;
  /** Server-side frozen copy; legacy adapters may use the streaming fallback. */
  copy?(sourceKey: string, destinationKey: string): Promise<PutResult>;
  presignGet(key: string, ttlSeconds: number, options?: PresignGetOptions): Promise<string>;
  /** Ruling R3: powers P8-T3 attachment uploads (contract 6). */
  presignPut(input: PresignPutInput): Promise<string>;
  /** Range-read handle spec; null = missing. */
  readerSpec(key: string): Promise<ReaderSpec | null>;
}

import type { ReaderSpec } from "./rangeReader.js";
