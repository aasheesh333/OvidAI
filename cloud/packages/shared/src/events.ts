import { z } from "zod";

export type SessionEventType =
  | "run_started"
  | "message_delta"
  | "message_completed"
  | "run_started_retry"
  | "run_failed"
  | "run_completed"
  | "system_note"
  | "tool_started"
  | "tool_completed"
  // P7 Task 3 additions (workspace/artifact protocol) — keep the union and
  // the zod enum array below in the same order.
  | "artifact_created"
  | "workspace_hibernated"
  | "workspace_hydrated";

export interface SessionEvent {
  sessionId: string;
  seq: string;
  type: SessionEventType;
  payload: Record<string, unknown>;
  ts: string;
}

// Wire-format ids are plain nonempty strings; UUIDv7 shape is validated at the
// DB boundary, not here.
export const sessionEventSchema: z.ZodType<SessionEvent> = z.object({
  sessionId: z.string().min(1),
  seq: z.string().min(1),
  type: z.enum([
    "run_started",
    "message_delta",
    "message_completed",
    "run_started_retry",
    "run_failed",
    "run_completed",
    "system_note",
    "tool_started",
    "tool_completed",
    "artifact_created",
    "workspace_hibernated",
    "workspace_hydrated",
  ]),
  payload: z.record(z.string(), z.unknown()),
  ts: z.string().min(1),
});

export function sessionEvent(input: unknown): SessionEvent {
  return sessionEventSchema.parse(input);
}
