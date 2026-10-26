import type { FastifyInstance, FastifyReply } from "fastify";
import {
  accountSettings,
  cancelSchedule,
  createSchedule,
  customPresets,
  runScheduleNow,
  RunQuotaService,
  runs,
  scheduleRuns,
  schedules,
  ScheduleError,
  sessionState,
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
import { AGENT_RUN_JOB_NAME, type AgentRunModelContext } from "@ovid/queue";
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
 * R2 run-now model/billing snapshot. Captured ONCE per accepted occurrence and
 * used for BOTH the canonical admission and the nested queue `modelContext`, so
 * the worker cannot see a different actor/model/key than the one admitted.
 *
 * The raw pin keeps its effort suffix ("gpt-5.2 · high"); the router parses it
 * downstream. Only custom presets carry a model/temperature pin — every
 * built-in preset is model:null, temperature:null (agent-core presets.ts), so
 * the client's preset list is the whole pin source the gateway needs.
 */
async function runNowModelContext(
  deps: GatewayDeps,
  uid: string,
  sessionId: string,
): Promise<AgentRunModelContext> {
  const [account, state, custom] = await Promise.all([
    accountSettings.get(deps.db, uid),
    sessionState.get(deps.db, sessionId),
    customPresets.list(deps.db, uid),
  ]);
  const preset =
    state.presetId === null ? null : (custom.find((p) => p.id === state.presetId) ?? null);
  const presetModel = preset?.model ?? null;
  const sessionPin = state.modelPin ?? null;
  const requestedModel =
    presetModel !== null && presetModel.trim() !== ""
      ? presetModel
      : sessionPin !== null && sessionPin.trim() !== ""
        ? sessionPin
        : null;
  return {
    requestedModel,
    // Non-secret identity only: the key id and its provider model, never the
    // credential. Null means Ovid's allowance bills this run.
    byokKeyId: account.byokDefault?.keyId ?? null,
    ...(account.byokDefault !== null ? { byokModel: account.byokDefault.model } : {}),
    ...(preset?.temperature != null ? { temperature: preset.temperature } : {}),
    actorUserId: uid,
  };
}

/**
 * The one Ovid-refusal envelope the clients already map: 402
 * `daily_limit_reached` plus the epoch-ms `x-ovid-resets-at` countdown (the
 * same shape `tokenCapRefusal` in messages.ts answers with).
 */
function quotaRefusalReply(
  reply: FastifyReply,
  verdict: { window: "day" | "month"; resetsAt: Date },
): FastifyReply {
  const window = verdict.window === "day" ? "daily" : "monthly";
  const response = reply.code(402);
  response.header("x-ovid-resets-at", String(verdict.resetsAt.getTime()));
  return response.send({
    error: {
      code: "daily_limit_reached",
      message:
        `You have used your plan's ${window} token allowance for scheduled runs. ` +
        `It resets at ${verdict.resetsAt.toISOString()}.`,
    },
  });
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

  // Wave 5 FE-012: run one occurrence NOW. The occurrence is claimed exactly
  // like a due tick (message + run + ledger, scheduledFor = now) without
  // moving the schedule's own nextRunAt/status; the run is enqueued with the
  // schedule's autonomy projected onto the run mode (the tick's H1 rule) and
  // settles like any other occurrence.
  app.post("/schedules/:id/run", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return notFound(reply, SCHEDULE_NOT_FOUND);
    const { uid } = request.principal;

    let fired: Awaited<ReturnType<typeof runScheduleNow>>;
    try {
      fired = await runScheduleNow(deps.db, { userId: uid, scheduleId: id });
    } catch (err) {
      if (isScheduleError(err)) return scheduleErrorReply(reply, err);
      throw err;
    }

    const { schedule, runId, scheduleRun, prompt } = fired;
    const autonomy = schedule.autonomy as "safe" | "auto";
    const tier = (await users.ensure(deps.db, uid, null)).tier;
    // One capture, two consumers: canonical admission and the nested queue
    // snapshot below. The run-now payload deliberately carries NO top-level
    // byokKeyId/byokModel/requestedModel duplicates — the snapshot is the only
    // model/billing authority the worker reads.
    const modelContext = await runNowModelContext(deps, uid, schedule.sessionId);
    const billingClass = modelContext.byokKeyId === null ? "ovid_allowance" : "byok";
    const quota = new RunQuotaService(
      deps.db,
      deps.clock === undefined ? {} : { now: deps.clock },
    );
    const admitted = await quota.admitRun({
      actorUserId: uid,
      source: "schedule_run_now",
      runId,
      idempotencyKey: `run:${runId}:schedule_run_now`,
      billingClass,
    });
    if (!admitted.ok) {
      // The occurrence exists but the allowance does not: terminalize both
      // rows truthfully and answer the existing 402/reset shape. Nothing is
      // enqueued and no start event is published.
      await runs.finish(deps.db, runId, "failed", "quota_exceeded");
      await scheduleRuns.finish(deps.db, scheduleRun.id, "failed", "quota_exceeded");
      return quotaRefusalReply(reply, admitted);
    }
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
          source: "schedule_run_now",
          actorUserId: uid,
          modelContext,
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
