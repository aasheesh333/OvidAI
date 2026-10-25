import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { mcpServers as mcpServersRepo } from "@ovid/db";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, queryValue, sendError, zodBadRequest } from "./http.js";

/**
 * MCP OAuth endpoints (P5 Task 15).
 *
 *  - GET  /mcp/oauth/start?serverId=…  (authenticated) — discovery + DCR +
 *    a one-use PKCE flow row, returning the authorize URL.
 *  - GET  /mcp/oauth/callback          (PUBLIC) — the authorization server's
 *    redirect target. The `state` is the bearer; the Task-9 flow consumes it
 *    atomically. This route only renders HTML — flow.ts already publishes the
 *    mcp_oauth_completed / mcp_oauth_failed system event through its injected
 *    SystemEventPublisher (main wires that publisher to the systemHub).
 *  - POST /mcp/oauth/disconnect        (authenticated) — forget token material.
 *
 * Failure HTML never carries token material, query echoes or error details.
 */

const MCP_SERVER_NOT_FOUND = "MCP server not found.";

const disconnectBodySchema = z
  .object({
    serverId: z.string().min(1),
  })
  .strict();

function unavailable(reply: FastifyReply): FastifyReply {
  return sendError(reply, 503, "unavailable", "MCP OAuth is not configured.");
}

function html(reply: FastifyReply, status: number, body: string): FastifyReply {
  return reply.code(status).type("text/html; charset=utf-8").send(body);
}

const SUCCESS_HTML = [
  "<!doctype html>",
  "<html><head><meta charset=\"utf-8\"><title>Authorization complete</title></head>",
  "<body><h1>Authorization complete</h1>",
  "<p>Authorization complete — you can close this window.</p></body></html>",
].join("");

const FAILURE_HTML = [
  "<!doctype html>",
  "<html><head><meta charset=\"utf-8\"><title>Authorization failed</title></head>",
  "<body><h1>Authorization failed</h1>",
  "<p>Authorization failed. Return to Ovid and try connecting the server again.</p>",
  "</body></html>",
].join("");

export function registerMcpOauthRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/mcp/oauth/start", async (request, reply) => {
    if (deps.oauth === undefined) return unavailable(reply);
    const { uid } = request.principal;
    const query = request.query as Record<string, string | string[] | undefined>;
    const serverId = queryValue(query.serverId);
    if (serverId === null || !isUuid(serverId)) {
      return notFound(reply, MCP_SERVER_NOT_FOUND);
    }
    const row = await mcpServersRepo.get(deps.db, serverId, uid);
    if (row === null) return notFound(reply, MCP_SERVER_NOT_FOUND);

    try {
      const { authorizeUrl } = await deps.oauth.start(uid, serverId);
      return { authorizeUrl };
    } catch {
      // Flow errors carry provider details — never echo them.
      return sendError(
        reply,
        400,
        "oauth_failed",
        "Could not start MCP authorization for this server.",
      );
    }
  });

  app.post("/mcp/oauth/disconnect", async (request, reply) => {
    if (deps.oauth === undefined) return unavailable(reply);
    const { uid } = request.principal;
    const parsed = disconnectBodySchema.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const { serverId } = parsed.data;
    if (!isUuid(serverId)) return notFound(reply, MCP_SERVER_NOT_FOUND);
    const row = await mcpServersRepo.get(deps.db, serverId, uid);
    if (row === null) return notFound(reply, MCP_SERVER_NOT_FOUND);

    // Cancel this gateway process's token calls as well as the worker-owned
    // lifecycle below; the DB generation fence covers every other process.
    deps.oauth.cancelRefreshes(uid, serverId);
    if (deps.connectionHealthInvocations !== undefined) {
      try {
        await deps.connectionHealthInvocations.disconnectAuthenticated({
          principal: { uid, authenticated: true },
          connectionId: serverId,
        });
      } catch {
        return sendError(reply, 503, "unavailable", "Connection disconnect is temporarily unavailable.");
      }
    } else {
      // Legacy isolated compositions still get the flow's fenced generation
      // bump and local refresh cancellation, but not a worker router close.
      await deps.oauth.disconnect(uid, serverId);
    }
    return reply.code(204).send();
  });
}

/**
 * PUBLIC callback scope (registered next to /health, explicitly WITHOUT the
 * auth hook). The authorization server redirects the browser here with no
 * Ovid credentials; `state` is the one-use bearer the flow validates.
 */
export function registerMcpOauthCallbackRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/mcp/oauth/callback", (request, reply) =>
    handleOauthCallback(deps, request, reply),
  );
}

/**
 * The canonical PUBLIC redirect path pinned by OVID_MCP_REDIRECT_URI's
 * default (`https://ovidsi.com/oauth/callback`). It is registered at the
 * gateway ROOT so Caddy can proxy that exact path verbatim (no rewrite);
 * same no-auth handler as the API-prefixed route above.
 */
export function registerMcpOauthPublicCallbackRoute(
  app: FastifyInstance,
  deps: GatewayDeps,
): void {
  app.get("/oauth/callback", (request, reply) =>
    handleOauthCallback(deps, request, reply),
  );
}

async function handleOauthCallback(
  deps: GatewayDeps,
  request: FastifyRequest,
  reply: FastifyReply,
): Promise<FastifyReply> {
  if (deps.oauth === undefined) {
    return html(
      reply,
      503,
      "<!doctype html><html><body><p>MCP OAuth is not configured.</p></body></html>",
    );
  }

  const query = request.query as Record<string, string | string[] | undefined>;
  const state = queryValue(query.state) ?? "";
  const code = queryValue(query.code);
  const error = queryValue(query.error);
  const iss = queryValue(query.iss);

  let ok = false;
  try {
    const result = await deps.oauth.handleCallback({
      state,
      ...(code !== null ? { code } : {}),
      ...(error !== null ? { error } : {}),
      ...(iss !== null ? { iss } : {}),
    });
    ok = result.ok;
  } catch {
    ok = false;
  }

  return ok ? html(reply, 200, SUCCESS_HTML) : html(reply, 400, FAILURE_HTML);
}
