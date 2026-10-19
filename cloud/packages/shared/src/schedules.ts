import { z } from "zod";
import { scheduleTriggerSchema, type ScheduleTrigger } from "./triggers.js";

/**
 * Scheduler protocol (P4) — DTOs, request schemas, the system-event envelope
 * that rides the WS `system` op, and push device registration.
 *
 * `SystemEvent` here is the SCHEDULE system event (a flat `type` +
 * `scheduleId`); it is distinct from the P5 `SystemEventEnvelope` in
 * `system.ts` (correlation `id` + `kind`), which rides `system_event`.
 * Both are additive members of the shared barrel.
 */

/** safe = read-only roster projection (default); auto = stored grants,
 *  explicit opt-in. */
export type ScheduleAutonomy = "safe" | "auto";

export type ScheduleStatus = "pending" | "paused" | "completed" | "failed" | "cancelled";

export type ScheduleRunStatus = "running" | "retry_scheduled" | "succeeded" | "failed" | "skipped";

export interface ScheduleLastResult {
  status: "succeeded" | "failed" | "skipped";
  code: string | null;
  message: string | null;
  finishedAt: string;
  ranLate: boolean;
}

export interface ScheduleDto {
  id: string;
  sessionId: string;
  title: string;
  description: string;
  trigger: ScheduleTrigger;
  autonomy: ScheduleAutonomy;
  status: ScheduleStatus;
  pausedReason: string | null;
  maxRetries: number;
  nextRunAt: string | null;
  lastResult: ScheduleLastResult | null;
  createdAt: string;
  updatedAt: string;
}

export interface ScheduleRunDto {
  id: string;
  scheduleId: string;
  scheduledFor: string;
  runId: string | null;
  status: ScheduleRunStatus;
  attempt: number;
  ranLate: boolean;
  error: string | null;
  startedAt: string | null;
  finishedAt: string | null;
}

export interface ScheduleUpdate {
  title?: string;
  description?: string;
  trigger?: ScheduleTrigger;
  autonomy?: ScheduleAutonomy;
  maxRetries?: number;
  sessionId?: string;
  status?: "pending" | "paused";
}

/** A push token registered by the Android client. */
export interface DeviceDto {
  token: string;
  platform: "android";
}

export type ScheduleSystemEventType =
  | "schedule_created"
  | "schedule_updated"
  | "schedule_deleted"
  | "schedule_run_started"
  | "schedule_run_succeeded"
  | "schedule_run_failed"
  | "schedule_run_paused";

/** One scheduler event pushed on the WS system channel. */
export interface SystemEvent {
  type: ScheduleSystemEventType;
  scheduleId: string;
  ts: string;
  payload: Record<string, unknown>;
}

const scheduleAutonomySchema = z.enum(["safe", "auto"]);
const scheduleStatusSchema = z.enum(["pending", "paused", "completed", "failed", "cancelled"]);
const scheduleRunStatusSchema = z.enum([
  "running",
  "retry_scheduled",
  "succeeded",
  "failed",
  "skipped",
]);
const scheduleSystemEventTypeSchema = z.enum([
  "schedule_created",
  "schedule_updated",
  "schedule_deleted",
  "schedule_run_started",
  "schedule_run_succeeded",
  "schedule_run_failed",
  "schedule_run_paused",
]);

/** Title/description bounds shared by create/update/DTO. */
const title = z.string().min(1).max(200);
const description = z.string().min(1).max(4000);
const maxRetries = z.number().int().min(0).max(3);

export const scheduleLastResultSchema: z.ZodType<ScheduleLastResult> = z.object({
  status: z.enum(["succeeded", "failed", "skipped"]),
  code: z.string().nullable(),
  message: z.string().nullable(),
  finishedAt: z.string().min(1),
  ranLate: z.boolean(),
});

export const scheduleDtoSchema: z.ZodType<ScheduleDto> = z.object({
  id: z.string().min(1),
  sessionId: z.string().min(1),
  title,
  description,
  trigger: scheduleTriggerSchema,
  autonomy: scheduleAutonomySchema,
  status: scheduleStatusSchema,
  pausedReason: z.string().nullable(),
  maxRetries,
  nextRunAt: z.string().min(1).nullable(),
  lastResult: scheduleLastResultSchema.nullable(),
  createdAt: z.string().min(1),
  updatedAt: z.string().min(1),
});

export const scheduleRunDtoSchema: z.ZodType<ScheduleRunDto> = z.object({
  id: z.string().min(1),
  scheduleId: z.string().min(1),
  scheduledFor: z.string().min(1),
  runId: z.string().min(1).nullable(),
  status: scheduleRunStatusSchema,
  attempt: z.number().int().positive(),
  ranLate: z.boolean(),
  error: z.string().nullable(),
  startedAt: z.string().min(1).nullable(),
  finishedAt: z.string().min(1).nullable(),
});

/**
 * Wave 5 FE-012: `POST /cloud/v1/schedules/:id/run` → 202. One immediate
 * occurrence was claimed and its run enqueued; the schedule's own
 * `nextRunAt`/status are untouched.
 */
export interface ScheduleRunNowResponse {
  runId: string;
  scheduleRun: ScheduleRunDto;
}

export const scheduleRunNowResponseSchema: z.ZodType<ScheduleRunNowResponse> = z.object({
  runId: z.string().min(1),
  scheduleRun: scheduleRunDtoSchema,
});

/**
 * POST /cloud/v1/schedules body. Strict: an unknown key is a client bug, not
 * forward compatibility. `autonomy` defaults to "safe" and `maxRetries` to 0
 * in the service layer (absent here keeps the wire contract explicit).
 */
export const scheduleCreateRequestSchema: z.ZodType<{
  title: string;
  description: string;
  trigger: ScheduleTrigger;
  autonomy?: ScheduleAutonomy;
  maxRetries?: number;
  sessionId?: string;
}> = z
  .object({
    title,
    description,
    trigger: scheduleTriggerSchema,
    autonomy: scheduleAutonomySchema.optional(),
    maxRetries: maxRetries.optional(),
    sessionId: z.string().min(1).optional(),
  })
  .strict();

/** PATCH body: at least one known field, never an empty object. Status is
 *  limited to the user-settable pending/paused pair. */
export const scheduleUpdateRequestSchema: z.ZodType<ScheduleUpdate> = z
  .object({
    title: title.optional(),
    description: description.optional(),
    trigger: scheduleTriggerSchema.optional(),
    autonomy: scheduleAutonomySchema.optional(),
    maxRetries: maxRetries.optional(),
    sessionId: z.string().min(1).optional(),
    status: z.enum(["pending", "paused"]).optional(),
  })
  .strict()
  .refine((update) => Object.keys(update).length > 0, {
    message: "at least one field must be present",
  });

export const systemEventSchema: z.ZodType<SystemEvent> = z.object({
  type: scheduleSystemEventTypeSchema,
  scheduleId: z.string().min(1),
  ts: z.string().min(1),
  payload: z.record(z.string(), z.unknown()),
});

/** Parses and validates one scheduler system event; THROWS off-contract. */
export function systemEvent(input: unknown): SystemEvent {
  return systemEventSchema.parse(input);
}

/** POST /cloud/v1/devices body. Strict; token is an FCM registration token. */
export const deviceRegisterRequestSchema: z.ZodType<{ token: string; platform: "android" }> = z
  .object({
    token: z.string().min(1).max(4096),
    platform: z.literal("android"),
  })
  .strict();

/**
 * The message the scheduler appends to a session's transcript when a fire
 * occurs (Dart schedule coordinator's prompt shape).
 */
export function schedulePrompt(title: string, description: string): string {
  return `[schedule: ${title}] ${description}`;
}
