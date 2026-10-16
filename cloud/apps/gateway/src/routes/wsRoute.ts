import type { FastifyInstance } from "fastify";
import type { GatewayDeps } from "../app.js";
import { handleWsConnection, type WsConnectionOptions } from "../ws.js";

/** Contract path — deliberately NOT under the /cloud/v1 REST prefix. */
export const WS_PATH = "/cloud/ws";

/**
 * Registers GET /cloud/ws on a scope whose @fastify/websocket plugin is
 * already loaded. Public by design: no authHook here — the single-use
 * ?ticket= query param IS the auth, verified inside handleWsConnection
 * (invalid/missing/reused → error frame + close 4401).
 */
export function registerWsRoute(
  app: FastifyInstance,
  deps: GatewayDeps,
  opts: WsConnectionOptions = {},
): void {
  app.get(WS_PATH, { websocket: true }, (socket, request) => {
    // Route is mounted at the app root, so request.url is path + query.
    const url = new URL(request.url, "http://gateway.invalid");
    // handleWsConnection guards its own async work (handshake, frame chain);
    // the catch only keeps a hypothetical rejection out of the plugin.
    void handleWsConnection(socket, url, deps, opts).catch(() => {});
  });
}
