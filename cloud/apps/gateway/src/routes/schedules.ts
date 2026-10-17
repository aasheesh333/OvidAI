import type { FastifyInstance, FastifyReply } from "fastify";
import {
  cancelSchedule,
  createSchedule,
  scheduleRuns,
  schedules,
  ScheduleError,
  updateSchedule,
  users,
  type ScheduleRow,
  type ScheduleRunRow,
} from "@ovid/db";
import {
  scheduleCreateRequestSchema,
  scheduleUpdateRequestSchema,
  type Page,
  type ScheduleDto,
  type ScheduleRunDto,
  type SystemEvent,
} from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import {
  badRequest,
  isUuid,
  notFound,
  parsePageLimit,
  queryValue,
  sendError,
  zodBadRequest,
} from "./http.js";

// Schedule REST routes (P4 Task 11) — all mounted inside the authenticated
// /cloud/v1 scope. Owner scoping lives in the service/repos: an unknown id and
// a wrong-owner id are indistinguishable (404, never 403). Every :id is
// shape-guarded first so client garbage never reaches a uuid column.

const SCHEDULE_NOT_FOUND = "Schedule not found.";

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
    nextRunAt: row.nextRunAt?.toISOString() ?? null,
    lastResult: row.lastResult ?? null,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

export function toScheduleRunDto(row: ScheduleRunRow): ScheduleRunDto {
  return {
    id: row.id,
    scheduleId: row.scheduleId,
    scheduledFor: row.scheduledFor.toISOString(),
    runId: row.runId,
    status: row.status,
    attempt: row.attempt,
    ranLate: row.ranLate,
    error: row.error,
    startedAt: row.startedAt?.toISOString() ?? null,
    finishedAt: row.finishedAt?.toISOString() ?? null,
  };
}

/** ScheduleError → the contracted HTTP envelope. */
function scheduleErrorReply(reply: FastifyReply, err: ScheduleError): FastifyReply {
  switch (err.code) {
    case "not_found":
      return notFound(reply, err.message);
    case "tier_required":
      return sendError(reply, 403, "tier_required", err.message);
    case "invalid_trigger":
    case "bad_request":
      return badRequest(reply, err.message);
  }
}

function isScheduleError(err: unknown): err is ScheduleError {
  return err instanceof ScheduleError;
}

/** Fire-and-report lifecycle event on the user's system channel. */
async function publish(deps: GatewayDeps, uid: string, event: SystemEvent): Promise<void> {
  await deps.system.publish(uid, event);
}

export function registerScheduleRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.post("/schedules", async (request, reply) => {
    const parsed = scheduleCreateRequestSchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);

    const { uid, email } = request.principal;
    // Provision the users row FIRST: schedules.userId has an FK here, and the
    // service's cron gate re-reads the stored tier (it never trusts the body).
    await users.ensure(deps.db, uid, email);

    let row: ScheduleRow;
    try {
      row = await createSchedule(deps.db, { userId: uid, ...parsed.data });
    } catch (err) {
      if (isScheduleError(err)) return scheduleErrorReply(reply, err);
      throw err;
    }

    const dto = toScheduleDto(row);
    await publish(deps, uid, {
      type: "schedule_created",
      scheduleId: dto.id,
      ts: new Date().toISOString(),
      payload: { schedule: dto },
    });
    return reply.code(201).send(dto);
  });

  app.get("/schedules", async (request): Promise<Page<ScheduleDto>> => {
    const query = request.query as Record<string, string | string[] | undefined>;
    const limit = parsePageLimit(query.limit);
    const cursor = queryValue(query.cursor);
    // Anything other than the literal "true" means false (contract).
    const includeCancelled = queryValue(query.includeCancelled) === "true";
    const { rows, nextCursor } = await schedules.list(deps.db, request.principal.uid, {
      limit,
      cursor,
      includeCancelled,
    });
    return { items: rows.map(toScheduleDto), nextCursor };
  });

  app.get("/schedules/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return notFound(reply, SCHEDULE_NOT_FOUND);
    const row = await schedules.get(deps.db, id, request.principal.uid);
    if (row === null) return notFound(reply, SCHEDULE_NOT_FOUND);
    return toScheduleDto(row);
  });

  app.get("/schedules/:id/runs", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return notFound(reply, SCHEDULE_NOT_FOUND);
    // Ownership check FIRST — a stranger gets 404, never an empty feed.
    const schedule = await schedules.get(deps.db, id, request.principal.uid);
    if (schedule === null) return notFound(reply, SCHEDULE_NOT_FOUND);

    const query = request.query as Record<string, string | string[] | undefined>;
    const limit = parsePageLimit(query.limit);
    // `before` is lenient (messages `beforeId` rule): malformed → first page.
    const rawBefore = queryValue(query.before);
    const beforeId = rawBefore !== null && isUuid(rawBefore) ? rawBefore : null;
    const { rows, nextCursor } = await scheduleRuns.listForSchedule(deps.db, id, {
      limit,
      beforeId,
    });
    return { items: rows.map(toScheduleRunDto), nextCursor };
  });

  app.patch("/schedules/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return notFound(reply, SCHEDULE_NOT_FOUND);
    const parsed = scheduleUpdateRequestSchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);

    let row: ScheduleRow;
    try {
      row = await updateSchedule(deps.db, {
        userId: request.principal.uid,
        scheduleId: id,
        patch: parsed.data,
      });
    } catch (err) {
      if (isScheduleError(err)) return scheduleErrorReply(reply, err);
      throw err;
    }

    const dto = toScheduleDto(row);
    await publish(deps, request.principal.uid, {
      type: "schedule_updated",
      scheduleId: dto.id,
      ts: new Date().toISOString(),
      payload: {
        schedule: dto,
        reason: parsed.data.status === "pending" ? "resumed" : "patched",
      },
    });
    return dto;
  });

  app.delete("/schedules/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return notFound(reply, SCHEDULE_NOT_FOUND);
    try {
      await cancelSchedule(deps.db, { userId: request.principal.uid, scheduleId: id });
    } catch (err) {
      if (isScheduleError(err)) return scheduleErrorReply(reply, err);
      throw err;
    }

    await publish(deps, request.principal.uid, {
      type: "schedule_deleted",
      scheduleId: id,
      ts: new Date().toISOString(),
      payload: { scheduleId: id },
    });
    return reply.code(204).send();
  });
}
