import { z } from "zod";

export type SessionEventType =
  | "run_started"
  | "message_delta"
  | "message_completed"
  | "run_started_retry"
  | "run_failed"
  | "run_completed"
  | "system_note";

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
  ]),
  payload: z.record(z.string(), z.unknown()),
  ts: z.string().min(1),
});

export function sessionEvent(input: unknown): SessionEvent {
  return sessionEventSchema.parse(input);
}
