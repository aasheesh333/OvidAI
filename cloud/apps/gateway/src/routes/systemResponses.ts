import type { FastifyInstance } from "fastify";
import { systemResponseBodySchema } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { sendError, zodBadRequest } from "./http.js";

/**
 * POST /system/responses (P5 Task 15) — the REST answer path for ANY pending
 * system-channel request (spec §6.2; the WS `system_response` frame is the
 * twin). The payload is forwarded opaquely: the worker's pending request owns
 * its shape (approval cards answer `{approve, allowDependencyScripts?}`,
 * sampling/elicitation their own). The caller's authenticated uid scopes the
 * answer — never a body field.
 */
export function registerSystemResponseRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.post("/system/responses", async (request, reply) => {
    if (deps.systemHub === undefined) {
      return sendError(reply, 503, "unavailable", "System channel is not configured.");
    }
    const parsed = systemResponseBodySchema.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);

    await deps.systemHub.respond(
      request.principal.uid,
      parsed.data.id,
      parsed.data.payload,
    );
    return reply.code(204).send();
  });
}
