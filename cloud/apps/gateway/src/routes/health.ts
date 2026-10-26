import type { FastifyInstance } from "fastify";
import type { ServiceCheckState, ServiceStatusDto } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import type { GatewayOperationalHealthChecks } from "../observabilityComposition.js";

// GET /cloud/v1/health — the ONLY unauthenticated route. Liveness view for
// orchestrators: 200 when every check passes, 503 when any degrades.

const CHECK_TIMEOUT_MS = 1_000;

/**
 * Runs a probe against a ~1s deadline: true when it settles successfully,
 * false when it rejects, throws synchronously, or times out. NEVER throws and
 * never leaves a pending timer behind (unref + clearTimeout), so a hung
 * backend degrades the response instead of stalling it.
 */
async function probe(work: () => Promise<unknown>, timeoutMs = CHECK_TIMEOUT_MS): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const timeout = new Promise<boolean>((resolve) => {
      timer = setTimeout(() => resolve(false), timeoutMs);
      timer.unref();
    });
    const done = (async () => {
      await work();
      return true;
    })().catch(() => false);
    return await Promise.race([done, timeout]);
  } catch {
    return false;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

export interface HealthChecks {
  db: boolean;
  redisQ: boolean;
  anomaly: boolean;
  mail: boolean;
  reservation: boolean;
  notification: boolean;
}

export interface HealthResponse {
  status: "ok" | "degraded";
  checks: HealthChecks;
}

export function registerHealthRoutes(
  app: FastifyInstance,
  deps: Pick<GatewayDeps, "db" | "queues" | "modelCatalog" | "observability">,
): void {
  app.get("/health", async (_request, reply): Promise<HealthResponse> => {
    const [db, redisQ, operational] = await Promise.all([
      probe(() => deps.db.$client.unsafe("SELECT 1")),
      probe(async () => {
        // QueueBase exposes the underlying (ioredis) client; ping proves the
        // queue's redis connection actually round-trips.
        const client = await deps.queues.agentRuns.client;
        await (client as unknown as { ping(): Promise<unknown> }).ping();
      }),
      // Operational health facts: never block the response; missing/throwing
      // probes report false (degraded) rather than unknown.
      deps.observability?.healthChecks().catch(() => ({})) ?? {},
    ]) as [boolean, boolean, GatewayOperationalHealthChecks];
    const checks: HealthChecks = {
      db,
      redisQ,
      anomaly: operational.anomaly ?? false,
      mail: operational.mail ?? false,
      reservation: operational.reservation ?? false,
      notification: operational.notification ?? false,
    };
    const ok = db && redisQ;
    reply.code(ok ? 200 : 503);
    return { status: ok ? "ok" : "degraded", checks };
  });

  // Wave 4 (SE-014): GET /cloud/v1/health/status — the app's Service status
  // screen. Unauthenticated, so it is deliberately coarse: one state per
  // capability a user notices, never hostnames, versions, counts or errors.
  // Always 200 (the body carries the verdict); orchestrators keep /health.
  app.get("/health/status", async (): Promise<ServiceStatusDto> => {
    const [storage, queue, agents, models] = await Promise.all([
      probe(() => deps.db.$client.unsafe("SELECT 1")).then(okOrDown),
      probe(async () => {
        const client = await deps.queues.agentRuns.client;
        await (client as unknown as { ping(): Promise<unknown> }).ping();
      }).then(okOrDown),
      agentsState(deps),
      modelsState(deps),
    ]);
    const checks = { api: "ok" as const, storage, queue, agents, models };
    const status: ServiceStatusDto["status"] =
      storage === "down" || queue === "down" || agents === "down"
        ? "down"
        : models === "ok" && agents === "ok"
          ? "ok"
          : "degraded";
    return { status, checks, checkedAt: new Date().toISOString() };
  });
}

function okOrDown(ok: boolean): ServiceCheckState {
  return ok ? "ok" : "down";
}

/**
 * Queue-consumer liveness: BullMQ lists the workers connected to the run
 * queue (CLIENT LIST). Zero consumers = runs would sit queued ("down"); a
 * redis that refuses CLIENT LIST, or a queue double without the method, is
 * "unknown" rather than a guess.
 */
async function agentsState(deps: Pick<GatewayDeps, "queues">): Promise<ServiceCheckState> {
  const q = deps.queues.agentRuns as unknown as { getWorkersCount?: () => Promise<number> };
  if (typeof q.getWorkersCount !== "function") return "unknown";
  let count: number | null = null;
  const ok = await probe(async () => {
    count = await q.getWorkersCount!();
  });
  if (!ok || count === null) return "unknown";
  return count > 0 ? "ok" : "down";
}

/** Model route: the mint's model catalog is readable and non-empty. */
async function modelsState(deps: Pick<GatewayDeps, "modelCatalog">): Promise<ServiceCheckState> {
  if (deps.modelCatalog === undefined) return "unknown";
  let list: readonly string[] | null = null;
  const ok = await probe(async () => {
    list = await deps.modelCatalog!();
  });
  if (!ok) return "degraded";
  const got = list as readonly string[] | null;
  return got !== null && got.length > 0 ? "ok" : "degraded";
}
