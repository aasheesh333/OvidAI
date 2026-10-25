// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
import { afterEach, describe, expect, it, vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import type { ConnectionHealthInvocations, HealthConnection, HealthTransition } from "@ovid/mcp";

import { registerConnectionHealthRoutes } from "./connectionHealthRoutes.js";
import { createInternalServiceAuth } from "./internalServiceAuth.js";

const TOKEN = "internal-test-token";
const UID = "gateway-verified-user";
const ID = "11111111-1111-4111-8111-111111111111";

function connection(): HealthConnection {
  return {
    connectionId: ID,
    userId: UID,
    providerId: "github",
    enabled: true,
    agentEnabled: true,
    authState: "authorized",
    healthState: "checking",
    lastCheckedAt: null,
    lastSuccessAt: null,
    configVersion: 2,
    disconnectGeneration: 1,
    hasSecrets: true,
  };
}

function transition(): HealthTransition {
  const current = connection();
  return {
    connection: current,
    from: "never_checked",
    to: current.healthState,
    lastCheckedAt: current.lastCheckedAt,
    lastSuccessAt: current.lastSuccessAt,
    persisted: true,
    code: "checked",
  };
}

describe("worker connection health internal routes", () => {
  let app: FastifyInstance | undefined;
  afterEach(async () => {
    await app?.close();
    app = undefined;
  });

  function setup() {
    const invocations: ConnectionHealthInvocations = {
      checkAuthenticated: vi.fn(async () => transition()),
      getAuthenticated: vi.fn(async () => connection()),
      disconnectAuthenticated: vi.fn(async () => ({
        ...connection(),
        enabled: false,
        agentEnabled: false,
        authState: "revoked",
        healthState: "revoked",
        disconnectGeneration: 2,
      })),
      checkSelectedOperation: vi.fn(async () => {
        throw new Error("internal explicit routes must not use lazy invocation");
      }),
    };
    app = Fastify();
    app.addHook("preHandler", createInternalServiceAuth(TOKEN));
    registerConnectionHealthRoutes(app, { invocations });
    return invocations;
  }

  it("passes operationId to the real explicit surface and returns live GET projection", async () => {
    const invocations = setup();
    const headers = { "x-ovid-internal-token": TOKEN, "x-ovid-user-id": UID };

    const checked = await app!.inject({
      method: "POST",
      url: `/internal/mcp/connections/${ID}/health`,
      headers,
      payload: { operationId: "get_user" },
    });
    expect(checked.statusCode).toBe(200);
    expect(checked.json()).toMatchObject({ to: "checking" });
    expect(invocations.checkAuthenticated).toHaveBeenCalledWith({
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
      operationId: "get_user",
    });

    const read = await app!.inject({
      method: "GET",
      url: `/internal/mcp/connections/${ID}/health`,
      headers,
    });
    expect(read.statusCode).toBe(200);
    expect(read.json()).toMatchObject({ healthState: "checking" });
    expect(invocations.getAuthenticated).toHaveBeenCalledWith({
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
    });
  });

  it("uses disconnectAuthenticated rather than a direct DB disconnect", async () => {
    const invocations = setup();
    const removed = await app!.inject({
      method: "DELETE",
      url: `/internal/mcp/connections/${ID}`,
      headers: { "x-ovid-internal-token": TOKEN, "x-ovid-user-id": UID },
    });

    expect(removed.statusCode).toBe(200);
    expect(removed.json()).toMatchObject({ healthState: "revoked", disconnectGeneration: 2 });
    expect(invocations.disconnectAuthenticated).toHaveBeenCalledWith({
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
    });
  });

  it("rejects missing internal auth and non-strict health bodies before lifecycle invocation", async () => {
    const invocations = setup();
    const unauthorized = await app!.inject({
      method: "POST",
      url: `/internal/mcp/connections/${ID}/health`,
      payload: { operationId: "get_user" },
    });
    expect(unauthorized.statusCode).toBe(401);
    const invalid = await app!.inject({
      method: "POST",
      url: `/internal/mcp/connections/${ID}/health`,
      headers: { "x-ovid-internal-token": TOKEN, "x-ovid-user-id": UID },
      payload: { operationId: "get_user", extra: true },
    });
    expect(invalid.statusCode).toBe(400);
    expect(invocations.checkAuthenticated).not.toHaveBeenCalled();
  });
});
