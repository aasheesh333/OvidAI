import type { FastifyInstance, FastifyReply } from "fastify";
import {
  cancelSchedule,
  createSchedule,
  runScheduleNow,
  scheduleRuns,
  schedules,
  ScheduleError,
  sessionState,
  sessions,
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
  type ScheduleRunNowResponse,
  type SystemEvent,
} from "@ovid/shared";
import { AGENT_RUN_JOB_NAME } from "@ovid/queue";
import type { GatewayDeps } from "../app.js";
import { assertModelAllowed, PlanGateError } from "../planGate.js";
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
    case "busy":
      return sendError(reply, 409, "session_busy", err.message);
  }
}

function isScheduleError(err: unknown): err is ScheduleError {
  return err instanceof ScheduleError;
}

/** Fire-and-report lifecycle event on the user's system channel. */
async function publish(deps: GatewayDeps, uid: string, event: SystemEvent): Promise<void> {
  await deps.system.publish(uid, event);
}

/**
 * P3 plan gate for scheduled runs. An occurrence executes the target
 * session's model pin, so a Free/Go account must never schedule (or fire) a
 * run pinned to a manual model — including an old pin left on the session by
 * a downgraded plan. Auto always passes. Returns the typed refusal, or null.
 */
async function sessionModelDenial(
  deps: GatewayDeps,
  uid: string,
  tier: string,
  sessionId: string,
): Promise<PlanGateError | null> {
  const session = await sessions.get(deps.db, sessionId, uid);
  if (session === null) return null; // ownership/404 is the service's job
  const pin = (await sessionState.get(deps.db, sessionId)).modelPin;
  try {
    assertModelAllowed(tier, pin);
    return null;
  } catch (err) {
    if (err instanceof PlanGateError) return err;
    throw err;
  }
}

export function registerScheduleRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.post("/schedules", async (request, reply) => {
    const parsed = scheduleCreateRequestSchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);

    const { uid, email } = request.principal;
    // Provision the users row FIRST: schedules.userId has an FK here, and the
    // service's cron gate re-reads the stored tier (it never trusts the body).
    const user = await users.ensure(deps.db, uid, email);

    // P3 plan gate: scheduling an existing chat must not smuggle its manual
    // model pin past the send-time entitlement (Free/Go are Auto-only).
    if (parsed.data.sessionId !== undefined) {
      const denial = await sessionModelDenial(deps, uid, user.tier, parsed.data.sessionId);
      if (denial !== null) return sendError(reply, denial.status, denial.code, denial.message);
    }

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

  // Wave 5 FE-012: run one occurrence NOW. The occurrence is claimed exactly
  // like a due tick (message + run + ledger, scheduledFor = now) without
  // moving the schedule's own nextRunAt/status; the run is enqueued with the
  // schedule's autonomy projected onto the run mode (the tick's H1 rule) and
  // settles like any other occurrence.
  app.post("/schedules/:id/run", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return notFound(reply, SCHEDULE_NOT_FOUND);
    const { uid } = request.principal;

    // P3 plan gate BEFORE the occurrence is claimed: the run executes the
    // session's model pin, and a Free/Go account may not run a manual model.
    const owned = await schedules.get(deps.db, id, uid);
    if (owned === null) return notFound(reply, SCHEDULE_NOT_FOUND);
    const user = await users.ensure(deps.db, uid, null);
    const denial = await sessionModelDenial(deps, uid, user.tier, owned.sessionId);
    if (denial !== null) return sendError(reply, denial.status, denial.code, denial.message);

    let fired: Awaited<ReturnType<typeof runScheduleNow>>;
    try {
      fired = await runScheduleNow(deps.db, { userId: uid, scheduleId: id });
    } catch (err) {
      if (isScheduleError(err)) return scheduleErrorReply(reply, err);
      throw err;
    }

    const { schedule, runId, scheduleRun, prompt } = fired;
    const autonomy = schedule.autonomy as "safe" | "auto";
    const tier = user.tier;
    try {
      await deps.queues.agentRuns.add(
        AGENT_RUN_JOB_NAME,
        {
          runId,
          sessionId: schedule.sessionId,
          userId: uid,
          prompt,
          tier,
          autonomy,
          mode: autonomy === "safe" ? "safe" : "auto",
          schedule: { scheduleId: schedule.id, scheduleRunId: scheduleRun.id, autonomy },
        },
        { jobId: runId, priority: tier === "free" ? 2 : 1 },
      );
    } catch (err) {
      // The occurrence is committed; settle's stale arm recovers a lost
      // enqueue (run_lost → retry ladder). The client may simply refresh.
      request.log.error({ err, runId, scheduleId: id }, "run-now enqueue failed; settle will recover");
      return sendError(
        reply,
        503,
        "unavailable",
        "Run queue is temporarily unavailable; the run will be retried.",
      );
    }

    await publish(deps, uid, {
      type: "schedule_run_started",
      scheduleId: schedule.id,
      ts: new Date().toISOString(),
      payload: {
        scheduleRunId: scheduleRun.id,
        runId,
        scheduledFor: scheduleRun.scheduledFor.toISOString(),
        ranLate: false,
        attempt: scheduleRun.attempt,
        manual: true,
      },
    });
    const body: ScheduleRunNowResponse = { runId, scheduleRun: toScheduleRunDto(scheduleRun) };
    return reply.code(202).send(body);
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
