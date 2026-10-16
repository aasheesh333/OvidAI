import Fastify, {
  type FastifyError,
  type FastifyInstance,
  type FastifyServerOptions,
} from "fastify";
import websocket from "@fastify/websocket";
import type { Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import type { QueueServices } from "@ovid/queue";
import type { KeyProvider, MintProvisioner } from "@ovid/shared";
import type { ApiError } from "@ovid/shared";
import { authHook, type Verifier } from "./auth.js";
import { registerHealthRoutes } from "./routes/health.js";
import { registerMessageRoutes } from "./routes/messages.js";
import { registerSessionRoutes } from "./routes/sessions.js";
import { registerWsRoute } from "./routes/wsRoute.js";
import type { TicketStore } from "./tickets.js";

export interface GatewayDeps {
  db: Db;
  queues: QueueServices;
  verifier: Verifier;
  tickets: TicketStore;
  keys: KeyProvider;
  mint: MintProvisioner;
  /** Session event log (Task 4) — the WS channel's replay + live source. */
  events: EventLog;
  /**
   * Reserved for time-sensitive logic (Task 8 WS heartbeats, TTL math); the
   * REST routes deliberately use DB time (repos) so pagination and ordering
   * never depend on gateway clocks.
   */
  clock?: () => Date;
}

export interface BuildGatewayOptions {
  /** Fastify logger option; defaults to false so inject() tests stay silent. */
  logger?: FastifyServerOptions["logger"];
}

export const API_PREFIX = "/cloud/v1";

/**
 * Capped WS frame size (I2): 256 KiB per frame. The @fastify/websocket (ws)
 * default is 100 MiB per frame — with 32 pre-auth frames bufferable per
 * connection that is a trivial pre-auth OOM vector. 256 KiB is orders above
 * any legitimate client frame (subscribe/ping are < 200 bytes).
 */
export const WS_MAX_PAYLOAD_BYTES = 262_144;

/**
 * Builds the gateway HTTP app: routes under /cloud/v1, everything except
 * /health behind the Task 6 authHook, one ApiError envelope for every
 * failure. Returns an unlistened instance — inject()-testable as-is.
 */
export function buildGateway(
  deps: GatewayDeps,
  opts: BuildGatewayOptions = {},
): FastifyInstance {
  const app = Fastify({
    logger: opts.logger ?? false,
  });

  // Anything that THROWS (route bug, Fastify body-parse rejection) is mapped
  // to the shared envelope here. 4xx keep Fastify's own message (e.g. the
  // JSON parse complaint); 5xx are logged with the real error server-side and
  // collapsed to a generic message for the client.
  app.setErrorHandler((error: FastifyError, request, reply) => {
    const status = typeof error.statusCode === "number" ? error.statusCode : 500;
    if (status < 400 || status >= 500) {
      request.log.error({ err: error }, "unhandled error in route");
      const body: ApiError = {
        error: { code: "internal", message: "Internal server error." },
      };
      return reply.code(500).send(body);
    }
    const body: ApiError = {
      error: {
        code: status === 404 ? "not_found" : "bad_request",
        message: error.message,
      },
    };
    return reply.code(status).send(body);
  });

  // Same envelope for unknown routes (default Fastify 404s would leak a
  // different shape).
  app.setNotFoundHandler((_request, reply) => {
    const body: ApiError = { error: { code: "not_found", message: "Route not found." } };
    return reply.code(404).send(body);
  });

  // Public scope: health only (explicitly NO auth — orchestrator probes).
  app.register(
    async (scope) => {
      registerHealthRoutes(scope, deps);
    },
    { prefix: API_PREFIX },
  );

  // Authenticated scope: the hook is encapsulated here, so it can never leak
  // onto /health above.
  app.register(
    async (scope) => {
      scope.addHook("preHandler", authHook(deps.verifier));

      // Single-use WS ticket for Task 8's handshake.
      scope.post("/auth/ticket", async (request) => ({
        ticket: await deps.tickets.mint(request.principal.uid),
      }));

      registerSessionRoutes(scope, deps);
      registerMessageRoutes(scope, deps);
    },
    { prefix: API_PREFIX },
  );

  // WS scope: GET /cloud/ws, public by design — no authHook here, the
  // single-use ?ticket= query param IS the auth (verified in the handshake).
  // The websocket plugin must be loaded in the same scope before the route.
  // maxPayload caps every inbound frame BEFORE any handler sees it (I2).
  app.register(async (scope) => {
    await scope.register(websocket, { options: { maxPayload: WS_MAX_PAYLOAD_BYTES } });
    registerWsRoute(scope, deps);
  });

  return app;
}
