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
