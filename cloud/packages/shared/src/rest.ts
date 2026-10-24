import { z } from "zod";
import type { SessionEvent } from "./events.js";

// Re-export through the existing public rest entry so the package index stays
// unchanged while consumers share one attachment MIME normalizer.
export { normalizeAttachmentContentType } from "./attachments.js";

export interface SessionDto {
  id: string;
  title: string | null;
  /** Interaction mode. Spec D5: "safe" | "auto" | "drive" | "studio" — NO "control". */
  mode: "safe" | "auto" | "drive" | "studio";
  /** W1: the project this chat belongs to, or null for an ungrouped chat. */
  projectId: string | null;
  /** ISO instant when pinned, or null. Pinned chats sort first. */
  pinnedAt: string | null;
  createdAt: string;
  updatedAt: string;
}

/** W1 project row as the sidebar needs it (counts are computed live). */
export interface ProjectDto {
  id: string;
  name: string;
  createdAt: string;
  updatedAt: string;
  sessionCount: number;
  /** Total used slots: project memory + attachments + active artifacts. */
  fileCount: number;
  /** Per-project file cap for the caller's plan (80/100/150/250). */
  fileCap: number;
  /** Total bytes across memory, attachments and active artifacts. */
  fileBytes: number;
  /** Per-bucket used counts (sums to fileCount). */
  fileBreakdown: {
    memory: number;
    attachments: number;
    artifacts: number;
  };
}

/** `GET /projects` payload (W1 follow-up). */
export interface ProjectsResponse {
  items: ProjectDto[];
  /**
   * Server feature flags. `turnProjectRefs` is present (true) only once
   * `POST /sessions/:id/messages` accepts and validates `projectRefs`; a
   * client must not send the field until it has seen this.
   */
  capabilities: {
    turnProjectRefs: boolean;
  };
}

export interface MessageDto {
  id: string;
  sessionId: string;
  role: "user" | "assistant" | "system" | "tool";
  content: string;
  createdAt: string;
  /**
   * Wave 1b (additive, CH-006): the files sent with this (user) message.
   * Absent when there are none.
   */
  attachments?: MessageAttachmentDto[];
  /**
   * The model's reasoning ("thinking") for this assistant turn, when the
   * provider exposed it and the run captured it. Absent — not null — when the
   * row has none, so a client that does not know the field sees an unchanged
   * payload. Never part of `content`: it is display-only and the client
   * renders it behind the "Show reasoning" switch (UserPreferences.showReasoning).
   */
  reasoning?: string;
}

/** Wave 1b: one file sent with a message (metadata only — never a URL). */
export interface MessageAttachmentDto {
  id: string;
  name: string;
  sizeBytes: number;
}

export interface Page<T> {
  items: T[];
  nextCursor: string | null;
}

/**
 * Wave 1b (additive, CH-002/CH-003/CH-006): GET /sessions/:id/messages also
 * answers
 *  - `lastEventSeq`: the session's newest durable event seq at read time —
 *    the replay cursor a client subscribes from so the event log is never
 *    replayed on top of this snapshot (null = no events yet);
 *  - `activeRun`: the run still queued/running, so a chat reopened mid-run
 *    shows Stop and the live answer;
 *  - `events` (only with `?events=1`): this page's settled agent activity —
 *    the non-delta events in the page's time window up to `lastEventSeq`,
 *    plus ONE coalesced `message_delta` carrying the active run's
 *    in-progress text — so a reload renders tool rows, artifacts,
 *    intermediate text and errors exactly as they streamed.
 */
export interface MessagePage extends Page<MessageDto> {
  lastEventSeq?: string | null;
  activeRun?: { runId: string; status: "queued" | "running" } | null;
  events?: SessionEvent[];
}

/** Wave 1b: DELETE /sessions/:id/messages/:messageId answer (truncate from there). */
export interface TruncateMessagesResponse {
  deleted: number;
}

/**
 * Wave 1b: POST /sessions/:id/messages/:messageId/regenerate — the answer
 * (and everything after it) is removed and the prompt it replied to runs
 * again. `maxOutputTokens` mirrors the send body's cap.
 */
export const regenerateBodySchema = z
  .object({
    maxOutputTokens: z.number().int().min(1).max(8192).optional(),
  })
  .strict();

export interface RegenerateResponse {
  runId: string;
  /** The user message the new run answers (unchanged by the regenerate). */
  promptMessageId: string;
  status: "queued";
}

/**
 * Wave 1b: POST /sessions/:id/branch — a NEW session seeded with this
 * session's messages up to and including `messageId`. Answers 201 SessionDto.
 */
export const branchSessionBodySchema = z
  .object({
    messageId: z.string().uuid(),
    title: z.string().max(200).optional(),
  })
  .strict();

export interface SendMessageResponse {
  runId: string;
  userMessageId: string;
  status: "queued";
  /**
   * Wave 1a (additive): the session's requested model pin after this send —
   * the pin string, or "auto" when the server routes. Absent on a
   * clientMsgId replay of a pre-Wave-1a send.
   */
  model?: string;
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
  /** Additive: old servers omit these; new servers always emit both. */
  contentType?: string;
  uploadHeaders?: Record<string, string>;
}

export const attachmentUploadResponseSchema: z.ZodType<AttachmentUploadResponse> = z
  .object({
    attachmentId: z.string().min(1),
    uploadUrl: z.string().min(1),
    path: z.string().min(1),
    expiresAt: z.string().min(1),
    contentType: z.string().min(1).optional(),
    uploadHeaders: z.record(z.string(), z.string()).optional(),
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

/**
 * The send-message wire's output-length cap (the "Max output tokens"
 * setting). The Dart client mirrors it as
 * `CloudRestClient.maxOutputTokensWireCap` — keep the two in sync. Values
 * above the cap degrade client-side to the cap instead of failing the send.
 */
export const MAX_OUTPUT_TOKENS_CAP = 8192;

/**
 * POST /cloud/v1/sessions/:id/messages request body. Content required
 * non-empty string (the route 400s whitespace-only separately); .strict()
 * rejects unknown keys.
 *
 * attachmentIds (P8 Task 3, additive + optional): uuid-shaped ids of
 * attachments created via POST /sessions/:id/attachments; the route
 * validates them against the session's attachment rows (unknown or
 * cross-session id → 400).
 *
 * clientMsgId (P8 Task 4, additive + optional): caller-chosen idempotency
 * key (1–64 chars). A re-send with the same (session, clientMsgId) replays
 * the original answer instead of inserting a second message/run.
 *
 * maxOutputTokens (additive + optional): the user's max completion tokens
 * (the Settings "Max output tokens" pick; 0/auto never sends the key). The
 * gateway forwards it on the job payload and the worker maps it onto the
 * engine request's `maxTokens` — both transports already serialize it
 * (`max_tokens`). Older servers ignore the field.
 */
/** Session interaction mode (spec D5) — "control" was retired; never re-add it. */
export const sessionModeSchema = z.enum(["safe", "auto", "drive", "studio"]);

/**
 * Built-in agent preset ids the cloud honors (agent-core presets.ts
 * BUILT_IN_PRESETS — an agent-core test pins the two lists equal). Custom
 * client presets are not a cloud concept.
 */
export const CLOUD_PRESET_IDS = ["standard", "minimal", "studio", "code", "plan"] as const;
export type CloudPresetId = (typeof CLOUD_PRESET_IDS)[number];

/** Max sessions one send may reference for cross-session context (R1 @-tags). */
export const MAX_SESSION_REFS = 5;
/** W1 follow-up: explicit `@project:<id>` refs one send may carry. */
export const MAX_PROJECT_REFS = 5;

/** Model ids: printable, no control characters (the effort suffix " · high" is allowed). */
// eslint-disable-next-line no-control-regex
const MODEL_ID_RE = /^[^\u0000-\u001f\u007f]+$/;

/**
 * Wave 1a (CT-001 / CH-001 / CH-007 / CH-008, additive + optional) — the
 * per-turn settings the composer sends with EVERY message. The send body is
 * the single source of truth for the turn; the gateway persists each present
 * field into the session's agent state so the session remembers it (server
 * slash commands, scheduled runs, the next send without the field):
 *
 * - model: a catalog id (optionally with the effort suffix " · low|medium|high")
 *   or an AUTO alias ("auto" / "ovid-cloud/auto"). The gateway validates the
 *   base id against the model catalog (400 model_unavailable). Persisted as
 *   session_agent_state.modelPin (null for auto).
 * - mode: the access chip (Read-Only=safe, General=auto, Full Access=drive,
 *   Studio=studio). Persisted on sessions.mode + agent state, and rides the
 *   job (job wins).
 * - planMode: the Plan chip. A change becomes state.pendingPlanMode, applied
 *   at the run's first turn boundary.
 * - presetId: one of CLOUD_PRESET_IDS. Persisted as state.presetId.
 * - sessionRefs: sessions the user @-tagged (R1 — the ONLY way another
 *   session's context reaches this run unless "Share session memory" is on).
 *   Owner-checked; the gateway also resolves `@[Title]` tokens in content.
 * - projectRefs: projects the user @-tagged for THIS turn (W1). Every id must
 *   be an owned project; the gateway fails the WHOLE send (typed 400, no run)
 *   on a missing/foreign/malformed/duplicated/over-limit ref. Their memory is
 *   injected into the run and never persisted onto the session.
 */
export const sendMessageBodySchema = z
  .object({
    content: z.string(),
    attachmentIds: z.array(z.string().uuid()).optional(),
    clientMsgId: z.string().min(1).max(64).optional(),
    maxOutputTokens: z.number().int().min(1).max(MAX_OUTPUT_TOKENS_CAP).optional(),
    model: z.string().min(1).max(160).regex(MODEL_ID_RE).optional(),
    mode: sessionModeSchema.optional(),
    planMode: z.boolean().optional(),
    presetId: z.string().min(1).max(64).optional(),
    sessionRefs: z.array(z.string().uuid()).max(MAX_SESSION_REFS).optional(),
    projectRefs: z.array(z.string().uuid()).max(MAX_PROJECT_REFS).optional(),
  })
  .strict();

// ---------------------------------------------------------------------------
// Wave 1a (SE-005 / R1): per-user preferences the worker enforces.
// ---------------------------------------------------------------------------

/**
 * GET/PATCH /cloud/v1/preferences. memoryEnabled=false removes the memory_*
 * tools from every run; shareSessionMemory=false (the default) confines
 * session_search to the current session — no other session's context reaches
 * a run unless the user @-tags it. showReasoning is a DISPLAY preference: the
 * reasoning is always captured and stored, and this only says whether the
 * client shows it by default.
 */
export interface UserPreferences {
  memoryEnabled: boolean;
  shareSessionMemory: boolean;
  showReasoning: boolean;
}

export const DEFAULT_USER_PREFERENCES: UserPreferences = Object.freeze({
  memoryEnabled: true,
  shareSessionMemory: false,
  showReasoning: true,
}) as UserPreferences;

export const userPreferencesSchema: z.ZodType<UserPreferences> = z
  .object({
    memoryEnabled: z.boolean(),
    shareSessionMemory: z.boolean(),
    showReasoning: z.boolean(),
  })
  .strict();

export const userPreferencesPatchSchema = z
  .object({
    memoryEnabled: z.boolean().optional(),
    shareSessionMemory: z.boolean().optional(),
    showReasoning: z.boolean().optional(),
  })
  .strict()
  .refine(
    (b) =>
      b.memoryEnabled !== undefined ||
      b.shareSessionMemory !== undefined ||
      b.showReasoning !== undefined,
    {
      message:
        "At least one of 'memoryEnabled', 'shareSessionMemory' or 'showReasoning' is required.",
    },
  );

export type UserPreferencesPatch = Partial<UserPreferences>;

export const sessionDtoSchema: z.ZodType<SessionDto> = z.object({
  id: z.string().min(1),
  title: z.string().nullable(),
  mode: sessionModeSchema,
  projectId: z.string().min(1).nullable(),
  pinnedAt: z.string().min(1).nullable(),
  createdAt: z.string().min(1),
  updatedAt: z.string().min(1),
});

export const projectDtoSchema: z.ZodType<ProjectDto> = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  createdAt: z.string().min(1),
  updatedAt: z.string().min(1),
  sessionCount: z.number().int().nonnegative(),
  fileCount: z.number().int().nonnegative(),
  fileCap: z.number().int().positive(),
  fileBytes: z.number().int().nonnegative(),
  fileBreakdown: z.object({
    memory: z.number().int().nonnegative(),
    attachments: z.number().int().nonnegative(),
    artifacts: z.number().int().nonnegative(),
  }),
});

/** POST /cloud/v1/projects — name only, unknown keys rejected. */
export const createProjectBodySchema = z
  .object({ name: z.string().trim().min(1).max(80) })
  .strict();

/** PATCH /cloud/v1/projects/:id — rename only. */
export const renameProjectBodySchema = z
  .object({ name: z.string().trim().min(1).max(80) })
  .strict();

/** POST /cloud/v1/sessions/:id/project — move into a project or out (null). */
export const moveSessionProjectBodySchema = z
  .object({ projectId: z.string().min(1).nullable() })
  .strict();

/** PATCH /cloud/v1/sessions/:id body — at least one field required, unknown keys rejected. */
export const sessionPatchSchema = z
  .object({
    title: z.string().nullable().optional(),
    mode: sessionModeSchema.optional(),
    pinned: z.boolean().optional(),
  })
  .strict()
  .refine(
    (body) =>
      body.title !== undefined || body.mode !== undefined || body.pinned !== undefined,
    {
      message: "At least one of 'title', 'mode' or 'pinned' is required.",
    },
  );

export type SessionPatch = {
  title?: string | null;
  mode?: SessionDto["mode"];
  pinned?: boolean;
};

export const messageDtoSchema: z.ZodType<MessageDto> = z.object({
  id: z.string().min(1),
  sessionId: z.string().min(1),
  role: z.enum(["user", "assistant", "system", "tool"]),
  content: z.string(),
  createdAt: z.string().min(1),
  attachments: z
    .array(z.object({ id: z.string().min(1), name: z.string(), sizeBytes: z.number().int().nonnegative() }))
    .optional(),
  reasoning: z.string().optional(),
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
