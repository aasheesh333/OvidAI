import { z } from "zod";

export interface SessionDto {
  id: string;
  title: string | null;
  /** Interaction mode. Spec D5: "safe" | "auto" | "drive" | "studio" — NO "control". */
  mode: "safe" | "auto" | "drive" | "studio";
  createdAt: string;
  updatedAt: string;
}

export interface MessageDto {
  id: string;
  sessionId: string;
  role: "user" | "assistant" | "system" | "tool";
  content: string;
  createdAt: string;
}

export interface Page<T> {
  items: T[];
  nextCursor: string | null;
}

export interface SendMessageResponse {
  runId: string;
  userMessageId: string;
  status: "queued";
}

/**
 * POST /cloud/v1/runs/:id/cancel answer (P8 Task 1). "cancelled" = the run was
 * still queued and the gateway terminalized it inline (BullMQ job removed,
 * run_failed{code:"cancelled"} emitted); "cancelling" = the run was already
 * claimed by a worker — the cancelRequested flag is set and the worker's
 * throttled cancel check terminalizes it as it streams.
 */
export interface RunCancelResponse {
  runId: string;
  status: "cancelling" | "cancelled";
}

export interface ApiError {
  error: { code: string; message: string };
}

// ---------------------------------------------------------------------------
// P8 Task 3: attachment upload wire contract (presigned R2 PUT)
// ---------------------------------------------------------------------------

/**
 * POST /cloud/v1/sessions/:id/attachments answer. `uploadUrl` is a presigned
 * R2 PUT for the object key `users/{uid}/sessions/{sessionId}/uploads/{attachmentId}`
 * (the client uploads the raw bytes there); `path` is the workspace-relative
 * path the worker materializes the file at (`uploads/{sanitizedName}`) — also
 * the path the client should show to the agent; `expiresAt` is when the
 * presigned URL stops working (ISO timestamp).
 */
export interface AttachmentUploadResponse {
  attachmentId: string;
  uploadUrl: string;
  path: string;
  expiresAt: string;
}

export const attachmentUploadResponseSchema: z.ZodType<AttachmentUploadResponse> = z
  .object({
    attachmentId: z.string().min(1),
    uploadUrl: z.string().min(1),
    path: z.string().min(1),
    expiresAt: z.string().min(1),
  })
  .strict();

/** A stored attachment as it appears on the wire (Tasks 5/8 consume this). */
export interface AttachmentDto {
  id: string;
  sessionId: string;
  /** Raw display name exactly as the client sent it (never rewritten). */
  name: string;
  size: number;
  createdAt: string;
}

export const attachmentDtoSchema: z.ZodType<AttachmentDto> = z.object({
  id: z.string().min(1),
  sessionId: z.string().min(1),
  name: z.string().min(1),
  size: z.number().int().positive(),
  createdAt: z.string().min(1),
});

/**
 * Attachment display name → safe workspace filename piece for `uploads/`:
 * [^A-Za-z0-9._-] → "_", leading dots stripped, dot-runs ("..") collapsed to
 * "_", truncated to 80 chars, "" → "attachment". The result is always a safe
 * single path segment — never empty, never a traversal — so the worker can
 * join it under uploads/ without further checks.
 *
 * NOTE (kept in sync deliberately): these are the same rules as
 * @ovid/storage's sanitizeArtifactName — EXCEPT the empty-input fallback
 * token: "attachment" here vs "artifact" there. The difference is deliberate
 * (each helper names its own domain's fallback) and must SURVIVE the
 * LOCKFILE-WAVE retirement of this copy: when @ovid/storage becomes the
 * single source, keep this function's "attachment" fallback (a wrapper, not a
 * deletion) — otherwise every previously-served uploads/ path with the
 * "attachment" token would silently rename at materialization time.
 */
export function sanitizeAttachmentName(name: string): string {
  let out = name.replace(/[^A-Za-z0-9._-]+/g, "_");
  out = out.replace(/^\.+/, "");
  // Dots are allowed characters, so a hostile name can still smuggle a ".."
  // run — neutralize it (the result is a filename piece, never a path).
  out = out.replace(/\.{2,}/g, "_");
  if (out.length > 80) out = out.slice(0, 80);
  return out === "" ? "attachment" : out;
}

/** Session interaction mode (spec D5) — "control" was retired; never re-add it. */
export const sessionModeSchema = z.enum(["safe", "auto", "drive", "studio"]);

export const sessionDtoSchema: z.ZodType<SessionDto> = z.object({
  id: z.string().min(1),
  title: z.string().nullable(),
  mode: sessionModeSchema,
  createdAt: z.string().min(1),
  updatedAt: z.string().min(1),
});

/** PATCH /cloud/v1/sessions/:id body — at least one field required, unknown keys rejected. */
export const sessionPatchSchema = z
  .object({
    title: z.string().nullable().optional(),
    mode: sessionModeSchema.optional(),
  })
  .strict()
  .refine((body) => body.title !== undefined || body.mode !== undefined, {
    message: "At least one of 'title' or 'mode' is required.",
  });

export type SessionPatch = { title?: string | null; mode?: SessionDto["mode"] };

export const messageDtoSchema: z.ZodType<MessageDto> = z.object({
  id: z.string().min(1),
  sessionId: z.string().min(1),
  role: z.enum(["user", "assistant", "system", "tool"]),
  content: z.string(),
  createdAt: z.string().min(1),
});

export function pageSchema<T>(inner: z.ZodType<T>): z.ZodType<Page<T>> {
  return z.object({
    items: z.array(inner),
    nextCursor: z.string().min(1).nullable(),
  });
}

export const runCancelResponseSchema: z.ZodType<RunCancelResponse> = z.object({
  runId: z.string().min(1),
  status: z.enum(["cancelling", "cancelled"]),
});

// ---------------------------------------------------------------------------
// P8 Task 4: bulk history import (Android thin-client transcripts+sessions)
// ---------------------------------------------------------------------------

/**
 * POST /cloud/v1/import/sessions answer. `sessionId` is the imported-into
 * session — freshly created when the request omitted `sessionId`, otherwise
 * the continuation id the caller passed (re-sends return the SAME id).
 * `imported` = rows this call inserted; `skipped` = messages whose
 * (session, clientMsgId) already existed — duplicates are skipped, never
 * duplicated or rewritten.
 */
export interface ImportReport {
  sessionId: string;
  imported: number;
  skipped: number;
}

export const importReportSchema: z.ZodType<ImportReport> = z
  .object({
    sessionId: z.string().min(1),
    imported: z.number().int().min(0),
    skipped: z.number().int().min(0),
  })
  .strict();
