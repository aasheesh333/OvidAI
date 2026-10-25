// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
import { describe, expect, it } from "vitest";
import type { HealthConnection, HealthTransition } from "@ovid/mcp";

import { createConnectionHealthClient } from "./connectionHealthClient.js";

const ID = "11111111-1111-4111-8111-111111111111";
const UID = "health-client-user";

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
    hasSecrets: false,
  };
}

function transition(): HealthTransition {
  const current = connection();
  return {
    connection: current,
    from: "never_checked",
    to: current.healthState,
    lastCheckedAt: null,
    lastSuccessAt: null,
    persisted: true,
    code: "checked",
  };
}

function setup(response: () => Response | Promise<Response>) {
  const requests: Array<{ url: string; init?: RequestInit }> = [];
  const client = createConnectionHealthClient({
    baseUrl: "http://worker.internal",
    token: "internal-secret",
    fetchImpl: async (url, init) => {
      requests.push({ url: String(url), init: init as RequestInit | undefined });
      return response();
    },
  });
  return { client, requests };
}

describe("gateway connection health worker client", () => {
  it("passes operationId and verified UID to POST, and reads live GET projection", async () => {
    const { client, requests } = setup(async () => new Response(JSON.stringify(transition()), { status: 200 }));
    await client.checkAuthenticated({
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
      operationId: "get_user",
    });

    expect(requests[0]?.url).toBe(`http://worker.internal/internal/mcp/connections/${ID}/health`);
    expect(requests[0]?.init?.method).toBe("POST");
    expect(JSON.parse(String(requests[0]?.init?.body))).toEqual({ operationId: "get_user" });
    expect(requests[0]?.init?.headers).toMatchObject({
      "x-ovid-internal-token": "internal-secret",
      "x-ovid-user-id": UID,
    });

    const live = setup(async () => new Response(JSON.stringify(connection()), { status: 200 }));
    await expect(live.client.getAuthenticated({
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
    })).resolves.toMatchObject({ healthState: "checking" });
    expect(live.requests[0]?.init?.method).toBe("GET");
  });

  it("calls the worker disconnect endpoint and refuses unauthenticated direct calls", async () => {
    const { client, requests } = setup(async () => new Response(JSON.stringify(connection()), { status: 200 }));
    await client.disconnectAuthenticated({
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
    });
    expect(requests[0]?.url).toBe(`http://worker.internal/internal/mcp/connections/${ID}`);
    expect(requests[0]?.init?.method).toBe("DELETE");

    await expect(client.disconnectAuthenticated({
      principal: { uid: UID, authenticated: false },
      connectionId: ID,
    })).rejects.toMatchObject({ code: "authentication_required" });
    expect(requests).toHaveLength(1);
  });

  it("rejects oversized or secret-bearing projection responses without returning them", async () => {
    const oversized = setup(async () => new Response("x".repeat(65_537), { status: 200 }));
    await expect(oversized.client.getAuthenticated({
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
    })).rejects.toMatchObject({ code: "unavailable" });

    const secret = setup(async () => new Response(JSON.stringify({
      ...connection(),
      secretsSealed: { ciphertext: "must-not-be-projected" },
    }), { status: 200 }));
    await expect(secret.client.getAuthenticated({
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
    })).rejects.toMatchObject({ code: "unavailable" });
  });
});
