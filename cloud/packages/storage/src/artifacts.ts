/**
 * Artifacts pipeline (P7 Task 9) — one call turns a workspace file (or a
 * Buffer) into a durable R2 object + a `workspace_objects` row + an
 * `artifact_created` event carrying a presigned download URL.
 *
 * The digest is computed HERE and supplied to `storage.put`: R2's HEAD never
 * returns an object hash (multipart ETags are not hashes — the Task-2 carry),
 * so the uploader is the only source of truth for the ledger row. For a
 * `sourcePath` the file is hashed in one streaming pass and uploaded in a
 * second streaming pass — no whole-file buffering.
 *
 * The URL is deliberately never logged: it is a bearer capability for the
 * artifact until `expiresAt`.
 */

import { createHash, randomBytes } from "node:crypto";
import { createReadStream } from "node:fs";
import { DEFAULT_PRESIGN_TTL_SECONDS } from "@ovid/shared";

import type { StorageAdapter } from "./adapter.js";
import { StorageError } from "./errors.js";
import { contentTypeFor, type HydrateDbLike, type HydrateEventLog } from "./hydrate.js";
import { r2Keys } from "./keys.js";

// ---------------------------------------------------------------------------
// Structural mirrors of the @ovid/db surface (exact signatures)
// ---------------------------------------------------------------------------

/** Mirror of @ovid/db's `workspaceObjects.registerArtifact`. */
export interface ArtifactWorkspaceObjectsRepo {
  registerArtifact(
    db: HydrateDbLike,
    i: {
      id: string;
      userId: string;
      sessionId: string;
      r2Key: string;
      bytes: number;
      sha256: string;
      contentType: string;
      meta: { name: string };
    },
  ): Promise<unknown>;
}

/** Mirror of @ovid/db's `eventMirror.put`. */
export interface ArtifactEventMirror {
  put(db: HydrateDbLike, e: Awaited<ReturnType<HydrateEventLog["append"]>>): Promise<void>;
}

export interface ArtifactDeps {
  db: HydrateDbLike;
  events: HydrateEventLog;
  storage: StorageAdapter;
  /** Default DEFAULT_PRESIGN_TTL_SECONDS (3600). */
  presignTtlSeconds?: number;
  clock?: () => Date;
  /** The real @ovid/db repo namespaces, injected by the wiring layer. */
  workspaceObjects: ArtifactWorkspaceObjectsRepo;
  eventMirror: ArtifactEventMirror;
}

export interface ArtifactInput {
  userId: string;
  sessionId: string;
  name: string;
  contentType?: string;
  /** Exactly one of sourcePath | content. */
  sourcePath?: string;
  content?: Buffer;
}

export interface ArtifactRecord {
  id: string;
  key: string;
  sizeBytes: number;
  sha256Hex: string;
  contentType: string;
  url: string;
  expiresAt: string;
}

// ---------------------------------------------------------------------------
// UUIDv7 — the artifact id IS the keyset cursor, so ids must be time-ordered.
// A local implementation keeps @ovid/storage free of a uuid dependency; the
// 12-bit rand_a field is a monotonic counter within one millisecond so ids
// created in the same tick still sort in creation order.
// ---------------------------------------------------------------------------

let lastMs = -1;
let seq = 0;

function newArtifactId(nowMs: number): string {
  const ms = Math.floor(nowMs);
  if (ms === lastMs) {
    seq = (seq + 1) & 0x0fff;
  } else {
    lastMs = ms;
    // randomInt's max is exclusive: 0..0x0fff
    seq = randomBytes(2).readUInt16BE(0) & 0x0fff;
  }
  const b = Buffer.alloc(16);
  b.writeUIntBE(ms % 0x1000000000000, 0, 6); // 48-bit unix ms, big-endian
  b[6] = 0x70 | ((seq >> 8) & 0x0f); // version 7 + rand_a high nibble
  b[7] = seq & 0xff; // rand_a low byte
  const rest = randomBytes(8);
  b[8] = 0x80 | (rest[0]! & 0x3f); // RFC 4122 variant + rand_b
  rest.copy(b, 9, 1, 8);
  const hex = b.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function sha256Hex(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

/** One streaming pass over a file: exact byte count + sha256. */
async function hashFile(path: string): Promise<{ sizeBytes: number; sha256Hex: string }> {
  const hash = createHash("sha256");
  let sizeBytes = 0;
  for await (const chunk of createReadStream(path)) {
    const buf = chunk as Buffer;
    hash.update(buf);
    sizeBytes += buf.length;
  }
  return { sizeBytes, sha256Hex: hash.digest("hex") };
}

// ---------------------------------------------------------------------------
// registerArtifact
// ---------------------------------------------------------------------------

export async function registerArtifact(
  deps: ArtifactDeps,
  input: ArtifactInput,
): Promise<ArtifactRecord> {
  const hasSource = input.sourcePath !== undefined;
  const hasContent = input.content !== undefined;
  if (hasSource === hasContent) {
    throw new StorageError(
      "registerArtifact requires exactly one of sourcePath | content",
      { code: "invalid_arg" },
    );
  }

  const clock = deps.clock ?? (() => new Date());
  const at = clock();
  const ttlSeconds = deps.presignTtlSeconds ?? DEFAULT_PRESIGN_TTL_SECONDS;
  const contentType = input.contentType ?? contentTypeFor(input.name);

  const id = newArtifactId(at.getTime());
  const key = r2Keys.artifact(input.userId, input.sessionId, id, input.name);

  let sizeBytes: number;
  let sha256: string;
  if (hasContent) {
    const content = input.content!;
    sizeBytes = content.length;
    sha256 = sha256Hex(content);
    const put = await deps.storage.put(key, content, { contentType, sha256Hex: sha256 });
    if (put.bytes !== sizeBytes) {
      throw new StorageError(
        `storage.put counted ${put.bytes} bytes for ${key} but the content is ${sizeBytes}`,
        { code: "artifact_length_mismatch" },
      );
    }
  } else {
    const sourcePath = input.sourcePath!;
    ({ sizeBytes, sha256Hex: sha256 } = await hashFile(sourcePath));
    const put = await deps.storage.put(key, createReadStream(sourcePath), {
      contentType,
      sha256Hex: sha256,
    });
    if (put.bytes !== sizeBytes) {
      throw new StorageError(
        `storage.put counted ${put.bytes} bytes for ${key} but the file is ${sizeBytes}`,
        { code: "artifact_length_mismatch" },
      );
    }
  }

  await deps.workspaceObjects.registerArtifact(deps.db, {
    id,
    userId: input.userId,
    sessionId: input.sessionId,
    r2Key: key,
    bytes: sizeBytes,
    sha256,
    contentType,
    meta: { name: input.name },
  });

  const url = await deps.storage.presignGet(key, ttlSeconds);
  const expiresAt = new Date(at.getTime() + ttlSeconds * 1000).toISOString();

  const event = await deps.events.append(input.sessionId, "artifact_created", {
    artifactId: id,
    name: input.name,
    sessionId: input.sessionId,
    sizeBytes,
    contentType,
    url,
    expiresAt,
  });
  await deps.eventMirror.put(deps.db, event);

  // NEVER log `url` — it is a bearer capability until expiresAt.
  return { id, key, sizeBytes, sha256Hex: sha256, contentType, url, expiresAt };
}
