import { z } from "zod";
import {
  cancelSchedule,
  createSchedule,
  schedules,
  ScheduleError,
  updateSchedule,
  users,
  type Db,
  type ScheduleRow,
} from "@ovid/db";
import type { Tool as CoreTool } from "@ovid/agent-core";
import type { SystemBus } from "@ovid/events";
import {
  ONE_OFF_GRACE_MS,
  describeTrigger,
  nextFireAfter,
  scheduleTriggerSchema,
  scheduleUpdateRequestSchema,
  type ScheduleDto,
  type ScheduleTrigger,
  type ScheduleUpdate,
  type SystemEvent,
} from "@ovid/shared";

/**
 * P4 Task 13 — agent schedule tools (spec §8 creation path (b)).
 *
 * Natural-language parsing is the MODEL's job: it turns "remind me every
 * morning" into a structured trigger, calls `schedule_create`, and then relays
 * the returned `needs_confirmation` echo to the user VERBATIM. The tool
 * persists nothing until the user confirms (`confirmed: true`) — the preview
 * runs the SAME tier gate and next-fire computation as `scheduleService`, so a
 * Free-tier cron fails in preview exactly as it would at creation.
 *
 * The plan pins the `ScheduleTool` shape below. P3's actual roster consumes
 * the canonical agent-core `Tool` seam, so `toCoreTools()` adapts these
 * (`parameters` is the additive JSON Schema field the model wire needs);
 * `FullRunDeps.extraTools` then feeds them into the per-run registry (see
 * runProcessor.ts).
 */

export interface ScheduleToolContext {
  userId: string;
  sessionId: string;
}

export interface ScheduleToolResult {
  content: string;
  structured?: unknown;
  isError?: boolean;
}

export interface ScheduleTool {
  name: "schedule_create" | "schedule_list" | "schedule_update" | "schedule_delete";
  description: string;
  inputSchema: z.ZodTypeAny;
  /** P3 adaptation: the JSON Schema the model wire consumes. */
  parameters: Record<string, unknown>;
  execute(input: unknown, ctx: ScheduleToolContext): Promise<ScheduleToolResult>;
}

export interface ScheduleToolDeps {
  db: Db;
  system: SystemBus;
  /** Injectable for tests; production omits it (wall clock). */
  clock?: () => Date;
}

// ---------------------------------------------------------------------------
// Input schemas
// ---------------------------------------------------------------------------

const createInputSchema = z
  .object({
    title: z.string().min(1).max(200),
    description: z.string().min(1).max(4000),
    trigger: scheduleTriggerSchema,
    autonomy: z.enum(["safe", "auto"]).optional(),
    maxRetries: z.number().int().min(0).max(3).optional(),
    /**
     * Explicit binding only. ABSENT means a DEDICATED session (the service
     * materializes one titled after the schedule) — deliberately NOT
     * ctx.sessionId: a schedule must not hijack the conversation that created
     * it (spec §8 / plan Task 13).
     */
    sessionId: z.string().min(1).optional(),
    confirmed: z.boolean().optional(),
  })
  .strict();

const listInputSchema = z.object({}).strict();

const updateInputSchema = z
  .object({
    scheduleId: z.string().min(1),
    patch: scheduleUpdateRequestSchema,
  })
  .strict();

const deleteInputSchema = z.object({ scheduleId: z.string().min(1) }).strict();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function nowOf(deps: ScheduleToolDeps): Date {
  return deps.clock !== undefined ? deps.clock() : new Date();
}

function zodSummary(err: z.ZodError): string {
  return err.issues
    .map((issue) => `${issue.path.length > 0 ? issue.path.join(".") : "(root)"}: ${issue.message}`)
    .join("; ");
}

/** ScheduleRow → the shared wire DTO (same shape the REST routes emit). */
export function toScheduleDto(row: ScheduleRow): ScheduleDto {
  return {
    id: row.id,
    sessionId: row.sessionId,
    title: row.title,
    description: row.description,
    trigger: row.trigger,
    autonomy: row.autonomy,
    status: row.status,
    pausedReason: row.pausedReason,
    maxRetries: row.maxRetries,
    nextRunAt: row.nextRunAt !== null ? row.nextRunAt.toISOString() : null,
    lastResult: row.lastResult,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

/**
 * The creation-time next-fire rule, mirrored from `scheduleService` so the
 * preview and the persisted row can never disagree (one-offs keep their
 * instant inside the 24 h grace; recurring triggers ask the engine).
 */
function previewNextRunAt(trigger: ScheduleTrigger, at: Date): Date {
  if (trigger.kind === "at") {
    const instant = new Date(trigger.at);
    if (Number.isNaN(instant.getTime())) {
      throw new ScheduleError("invalid_trigger", "at must be a valid ISO-8601 instant.");
    }
    if (instant.getTime() <= at.getTime() - ONE_OFF_GRACE_MS) {
      throw new ScheduleError("invalid_trigger", "at is more than 24 h in the past.");
    }
    return instant;
  }
  const next = nextFireAfter(trigger, at);
  if (next === null) {
    throw new ScheduleError("invalid_trigger", "Trigger does not produce a future occurrence.");
  }
  return next;
}

/** Preview validation: the cron tier gate runs here too (Review Focus 4). */
async function previewCreate(
  deps: ScheduleToolDeps,
  userId: string,
  trigger: ScheduleTrigger,
  at: Date,
): Promise<Date> {
  if (trigger.kind === "cron") {
    const user = await users.ensure(deps.db, userId, null);
    if (user.tier === "free") {
      throw new ScheduleError("tier_required", "Cron schedules require Ovid Pro.");
    }
  }
  return previewNextRunAt(trigger, at);
}

/** Shared error mapping: user errors are results; infrastructure errors throw. */
async function runGuarded<T>(
  parse: () => T,
  body: (args: T) => Promise<ScheduleToolResult>,
): Promise<ScheduleToolResult> {
  let args: T;
  try {
    args = parse();
  } catch (err) {
    if (err instanceof z.ZodError) {
      return { content: `Invalid arguments: ${zodSummary(err)}`, isError: true };
    }
    throw err;
  }
  try {
    return await body(args);
  } catch (err) {
    if (err instanceof ScheduleError) {
      // The service's messages are the wire contract shared with REST:
      // tier_required → "Cron schedules require Ovid Pro.";
      // wrong owner / unknown id → "Schedule not found." (no existence leak).
      return { content: err.message, isError: true };
    }
    throw err;
  }
}

// ---------------------------------------------------------------------------
// JSON Schema fragments (model wire)
// ---------------------------------------------------------------------------

const triggerParameters: Record<string, unknown> = {
  type: "object",
  description:
    "Structured trigger. Parse the user's natural language into exactly one variant.",
  oneOf: [
    {
      type: "object",
      properties: {
        kind: { const: "at" },
        at: { type: "string", description: "ISO-8601 instant, e.g. 2026-10-20T09:00:00.000Z" },
      },
      required: ["kind", "at"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: {
        kind: { const: "every" },
        seconds: { type: "integer", minimum: 300, description: "Interval in seconds (min 300)." },
      },
      required: ["kind", "seconds"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: {
        kind: { const: "daily_at" },
        time: { type: "string", description: "Local wall time HH:mm." },
        tz: { type: "string", description: "IANA timezone, e.g. Europe/Berlin." },
      },
      required: ["kind", "time", "tz"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: {
        kind: { const: "cron" },
        expr: { type: "string", description: "5-field cron expression." },
        tz: { type: "string", description: "IANA timezone." },
      },
      required: ["kind", "expr", "tz"],
      additionalProperties: false,
    },
  ],
};

const patchParameters: Record<string, unknown> = {
  type: "object",
  properties: {
    title: { type: "string", minLength: 1, maxLength: 200 },
    description: { type: "string", minLength: 1, maxLength: 4000 },
    trigger: triggerParameters,
    autonomy: { type: "string", enum: ["safe", "auto"] },
    maxRetries: { type: "integer", minimum: 0, maximum: 3 },
    sessionId: { type: "string", minLength: 1 },
    status: { type: "string", enum: ["pending", "paused"] },
  },
  additionalProperties: false,
  minProperties: 1,
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export function createScheduleTools(deps: ScheduleToolDeps): ScheduleTool[] {
  const create: ScheduleTool = {
    name: "schedule_create",
    description:
      "Create a scheduled task that runs autonomously later. You MUST parse the user's " +
      "natural-language request into the structured `trigger` JSON yourself (at / every / " +
      "daily_at / cron) and call this tool. On the first call omit `confirmed`: the tool " +
      "persists NOTHING and returns a confirmation preview. Relay that preview text to the " +
      "user VERBATIM, and call again with `confirmed: true` only after they say confirm. " +
      "Unless `sessionId` is given, a dedicated session is created for the schedule.",
    inputSchema: createInputSchema,
    parameters: {
      type: "object",
      properties: {
        title: { type: "string", minLength: 1, maxLength: 200 },
        description: {
          type: "string",
          minLength: 1,
          maxLength: 4000,
          description: "The instruction the scheduled agent run will execute.",
        },
        trigger: triggerParameters,
        autonomy: {
          type: "string",
          enum: ["safe", "auto"],
          description: "safe (read-only, default) or auto (stored grants, explicit opt-in).",
        },
        maxRetries: { type: "integer", minimum: 0, maximum: 3 },
        sessionId: {
          type: "string",
          description: "Existing session to bind; omit for a dedicated session.",
        },
        confirmed: {
          type: "boolean",
          description: "True only after the user explicitly confirms the preview.",
        },
      },
      required: ["title", "description", "trigger"],
      additionalProperties: false,
    },
    async execute(input, ctx) {
      return runGuarded(
        () => createInputSchema.parse(input),
        async (args) => {
          const at = nowOf(deps);
          const autonomy = args.autonomy ?? "safe";
          const maxRetries = args.maxRetries ?? 0;

          if (args.confirmed !== true) {
            // Preview: validation only — NOTHING is persisted.
            const nextRunAt = await previewCreate(deps, ctx.userId, args.trigger, at);
            return {
              content:
                `Please confirm: I will run "${args.description}" ` +
                `${describeTrigger(args.trigger)} (autonomy: ${autonomy}, ` +
                `retries: ${maxRetries}). First run: ${nextRunAt.toISOString()}. ` +
                `Say "confirm" to create it.`,
              structured: {
                status: "needs_confirmation",
                parsed: {
                  title: args.title,
                  description: args.description,
                  trigger: args.trigger,
                  autonomy,
                  maxRetries,
                  nextRunAt: nextRunAt.toISOString(),
                },
              },
            };
          }

          const row = await createSchedule(deps.db, {
            userId: ctx.userId,
            title: args.title,
            description: args.description,
            trigger: args.trigger,
            autonomy,
            maxRetries,
            // Explicit binding only — absent = dedicated session.
            sessionId: args.sessionId ?? null,
            clock: deps.clock,
          });
          const dto = toScheduleDto(row);
          await deps.system.publish(ctx.userId, {
            type: "schedule_created",
            scheduleId: dto.id,
            ts: nowOf(deps).toISOString(),
            payload: { schedule: dto },
          });
          return {
            content: `Schedule created: "${dto.title}" ${describeTrigger(dto.trigger)}.`,
            structured: { status: "created", schedule: dto },
          };
        },
      );
    },
  };

  const list: ScheduleTool = {
    name: "schedule_list",
    description:
      "List the user's scheduled tasks (cancelled ones are excluded). Returns one line " +
      "per schedule plus the structured DTOs.",
    inputSchema: listInputSchema,
    parameters: { type: "object", properties: {}, additionalProperties: false },
    async execute(input, ctx) {
      return runGuarded(
        () => listInputSchema.parse(input),
        async () => {
          const { rows } = await schedules.list(deps.db, ctx.userId, { limit: 100 });
          const dtos = rows.map(toScheduleDto);
          const content =
            dtos.length === 0
              ? "No schedules."
              : dtos
                  .map(
                    (s) =>
                      `- ${s.title} — ${describeTrigger(s.trigger)} — ${s.status}, ` +
                      `next ${s.nextRunAt ?? "—"}`,
                  )
                  .join("\n");
          return { content, structured: { schedules: dtos } };
        },
      );
    },
  };

  const update: ScheduleTool = {
    name: "schedule_update",
    description:
      "Update one of the user's scheduled tasks. `patch` must contain at least one of " +
      "title, description, trigger, autonomy, maxRetries, sessionId, or status " +
      "(pending = resume, paused = pause). Confirm with the user in conversation first; " +
      "this tool persists immediately.",
    inputSchema: updateInputSchema,
    parameters: {
      type: "object",
      properties: {
        scheduleId: { type: "string", minLength: 1 },
        patch: patchParameters,
      },
      required: ["scheduleId", "patch"],
      additionalProperties: false,
    },
    async execute(input, ctx) {
      return runGuarded(
        () => updateInputSchema.parse(input),
        async (args) => {
          const patch = args.patch as ScheduleUpdate;
          const row = await updateSchedule(deps.db, {
            userId: ctx.userId,
            scheduleId: args.scheduleId,
            patch,
            clock: deps.clock,
          });
          const dto = toScheduleDto(row);
          await deps.system.publish(ctx.userId, {
            type: "schedule_updated",
            scheduleId: dto.id,
            ts: nowOf(deps).toISOString(),
            payload: {
              schedule: dto,
              reason: patch.status === "pending" ? "resumed" : "patched",
            },
          });
          return {
            content: `Schedule updated: "${dto.title}".`,
            structured: { status: "updated", schedule: dto },
          };
        },
      );
    },
  };

  const remove: ScheduleTool = {
    name: "schedule_delete",
    description:
      "Delete (cancel) one of the user's scheduled tasks. Confirm with the user in " +
      "conversation first; this tool persists immediately.",
    inputSchema: deleteInputSchema,
    parameters: {
      type: "object",
      properties: { scheduleId: { type: "string", minLength: 1 } },
      required: ["scheduleId"],
      additionalProperties: false,
    },
    async execute(input, ctx) {
      return runGuarded(
        () => deleteInputSchema.parse(input),
        async (args) => {
          // Owner-scoped read first: wrong owner == unknown == "Schedule not
          // found." (same wording as REST, no existence leak).
          const existing = await schedules.get(deps.db, args.scheduleId, ctx.userId);
          if (existing === null) {
            throw new ScheduleError("not_found", "Schedule not found.");
          }
          await cancelSchedule(deps.db, {
            userId: ctx.userId,
            scheduleId: args.scheduleId,
          });
          await deps.system.publish(ctx.userId, {
            type: "schedule_deleted",
            scheduleId: args.scheduleId,
            ts: nowOf(deps).toISOString(),
            payload: { scheduleId: args.scheduleId },
          });
          return {
            content: `Schedule deleted: "${existing.title}".`,
            structured: { status: "deleted", scheduleId: args.scheduleId },
          };
        },
      );
    },
  };

  return [create, list, update, remove];
}

// ---------------------------------------------------------------------------
// P3 roster adaptation
// ---------------------------------------------------------------------------

/**
 * Adapt the plan-pinned `ScheduleTool` shape onto the canonical agent-core
 * `Tool` seam (`spec` + `execute`). `FullRunDeps.extraTools` accepts these and
 * spreads them into the per-run registry. No sandbox handle is needed: the
 * schedule tools only touch Postgres and the system bus.
 */
export function toCoreTools(tools: readonly ScheduleTool[]): CoreTool[] {
  return tools.map((tool) => ({
    spec: {
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters,
    },
    timeoutMs: 120_000,
    async execute(args, ctx) {
      const result = await tool.execute(args, {
        userId: ctx.userId,
        sessionId: ctx.sessionId,
      });
      return { content: result.content, isError: result.isError === true };
    },
  }));
}
