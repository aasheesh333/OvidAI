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
  | "workspace_hydrated"
  // P3 Task 12 additions — the remaining nine P3-Q5 members (ruling R5:
  // P2's Task 12 already landed tool_started/tool_completed above; P3
  // appends only these). Additive ONLY: never reorder, never remove.
  | "approval_requested"
  | "approval_resolved"
  | "todo_updated"
  | "goal_updated"
  | "plan_mode_changed"
  | "run_cancelled"
  | "subagent_started"
  | "subagent_completed"
  | "compaction_completed";

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
    "approval_requested",
    "approval_resolved",
    "todo_updated",
    "goal_updated",
    "plan_mode_changed",
    "run_cancelled",
    "subagent_started",
    "subagent_completed",
    "compaction_completed",
  ]),
  payload: z.record(z.string(), z.unknown()),
  ts: z.string().min(1),
});

export function sessionEvent(input: unknown): SessionEvent {
  return sessionEventSchema.parse(input);
}
