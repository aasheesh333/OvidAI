import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import {
  ConnectionHealthError,
  ConnectionHealthInvocationError,
  type ConnectionHealthInvocations,
} from "@ovid/mcp";

const healthBody = z.object({ operationId: z.string().trim().min(1).max(128) }).strict();

export interface ConnectionHealthRoutesDeps {
  invocations?: ConnectionHealthInvocations;
}

function unavailable(reply: FastifyReply): FastifyReply {
  return reply.code(503).send({ error: { code: "unavailable", message: "Connection health is unavailable." } });
}

function failure(reply: FastifyReply, error: unknown): FastifyReply {
  const code = error instanceof ConnectionHealthError || error instanceof ConnectionHealthInvocationError
    ? error.code
    : "unavailable";
  if (code === "not_found") {
    return reply.code(404).send({ error: { code, message: "Connection not found." } });
  }
  if (code === "connection_changed") {
    return reply.code(409).send({ error: { code: "connection_changed", message: "The connection changed." } });
  }
  if (code === "authentication_required" || code === "operation_not_selected") {
    return reply.code(403).send({ error: { code, message: "Connection operation is not authorized." } });
  }
  return unavailable(reply);
}

/** Internal-token + gateway-verified UID boundary; owns no separate auth cache. */
export function registerConnectionHealthRoutes(
  app: FastifyInstance,
  deps: ConnectionHealthRoutesDeps,
): void {
  app.post<{ Params: { id: string }; Body: unknown }>(
    "/internal/mcp/connections/:id/health",
    { bodyLimit: 4_096 },
    async (request, reply) => {
      if (deps.invocations === undefined) return unavailable(reply);
      const parsed = healthBody.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(400).send({ error: { code: "bad_request", message: "Expected {operationId}." } });
      }
      try {
        return await deps.invocations.checkAuthenticated({
          principal: { uid: String(request.headers["x-ovid-user-id"]), authenticated: true },
          connectionId: request.params.id,
          operationId: parsed.data.operationId,
        });
      } catch (error) {
        return failure(reply, error);
      }
    },
  );

  app.get<{ Params: { id: string }>(
    "/internal/mcp/connections/:id/health",
    async (request, reply) => {
      if (deps.invocations === undefined) return unavailable(reply);
      try {
        return await deps.invocations.getAuthenticated({
          principal: { uid: String(request.headers["x-ovid-user-id"]), authenticated: true },
          connectionId: request.params.id,
        });
      } catch (error) {
        return failure(reply, error);
      }
    },
  );

  app.delete<{ Params: { id: string }>(
    "/internal/mcp/connections/:id",
    async (request, reply) => {
      if (deps.invocations === undefined) return unavailable(reply);
      try {
        return await deps.invocations.disconnectAuthenticated({
          principal: { uid: String(request.headers["x-ovid-user-id"]), authenticated: true },
          connectionId: request.params.id,
        });
      } catch (error) {
        return failure(reply, error);
      }
    },
  );
}
