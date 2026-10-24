import type { FastifyInstance, FastifyReply } from "fastify";
import {
  createSystemRequestStore,
  sessions,
  SystemRequestError,
  type SystemRequestErrorCode,
} from "@ovid/db";
import {
  systemRequestDtoSchema,
  systemResponseAttemptSchema,
  systemResponseDtoSchema,
} from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, sendError, zodBadRequest } from "./http.js";

const respondBodySchema = systemResponseAttemptSchema.omit({ requestId: true });

const ERROR_STATUS: Record<SystemRequestErrorCode, number> = {
  invalid_request: 400,
  not_found: 404,
  version_conflict: 409,
  response_conflict: 409,
  client_response_conflict: 409,
  request_expired: 410,
  request_not_pending: 409,
  request_not_expired: 409,
  sensitive_delivery_unavailable: 503,
};

function mapSystemRequestError(reply: FastifyReply, error: unknown): FastifyReply {
  if (!(error instanceof SystemRequestError)) throw error;
  if (error.code === "not_found") return notFound(reply, "System request not found.");
  return sendError(reply, ERROR_STATUS[error.code], error.code, error.message);
}

/** Authenticated, owner-scoped HTTP access to migration 0033's durable requests. */
export function registerSystemRequestRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  const store = createSystemRequestStore(
    deps.db,
    deps.clock === undefined ? {} : { clock: deps.clock },
  );

  app.get("/sessions/:id/system-requests", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);
    const pending = await store.listPending({ userId: uid, sessionId });
    return systemRequestDtoSchema.array().parse(pending);
  });

  app.post("/system-requests/:requestId/respond", async (request, reply) => {
    const parsed = respondBodySchema.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const { requestId } = request.params as { requestId: string };
    try {
      const receipt = await store.respond({
        userId: request.principal.uid,
        requestId,
        ...parsed.data,
      });
      if (receipt === null) return notFound(reply, "System request not found.");
      return systemResponseDtoSchema.parse(receipt);
    } catch (error) {
      return mapSystemRequestError(reply, error);
    }
  });
}
