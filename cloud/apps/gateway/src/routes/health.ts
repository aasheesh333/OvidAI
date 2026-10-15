import type { FastifyInstance } from "fastify";
import type { GatewayDeps } from "../app.js";

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
}

export interface HealthResponse {
  status: "ok" | "degraded";
  checks: HealthChecks;
}

export function registerHealthRoutes(
  app: FastifyInstance,
  deps: Pick<GatewayDeps, "db" | "queues">,
): void {
  app.get("/health", async (_request, reply): Promise<HealthResponse> => {
    const [db, redisQ] = await Promise.all([
      probe(() => deps.db.$client.unsafe("SELECT 1")),
      probe(async () => {
        // QueueBase exposes the underlying (ioredis) client; ping proves the
        // queue's redis connection actually round-trips.
        const client = await deps.queues.agentRuns.client;
        await (client as unknown as { ping(): Promise<unknown> }).ping();
      }),
    ]);
    const ok = db && redisQ;
    reply.code(ok ? 200 : 503);
    return { status: ok ? "ok" : "degraded", checks: { db, redisQ } };
  });
}
