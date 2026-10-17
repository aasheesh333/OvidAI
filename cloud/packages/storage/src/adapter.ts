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
  presignGet(key: string, ttlSeconds: number): Promise<string>;
  /** Ruling R3: powers P8-T3 attachment uploads (contract 6). */
  presignPut(key: string, ttlSeconds: number): Promise<string>;
  /** Range-read handle spec; null = missing. */
  readerSpec(key: string): Promise<ReaderSpec | null>;
}

import type { ReaderSpec } from "./rangeReader.js";
