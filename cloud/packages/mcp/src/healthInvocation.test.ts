// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
import { describe, expect, it } from "vitest";

import type { RunMcpSnapshot } from "./activation.js";
import {
  createConnectionHealthInvocations,
  type AuthenticatedConnectionHealthRequest,
} from "./healthInvocation.js";
import type { ConnectionHealthLifecycle, HealthTransition } from "./health.js";
import type { ProviderOperation } from "./providers/types.js";

const operation: ProviderOperation = {
  name: "get_user",
  description: "Read the authenticated user",
  effect: "read",
  approval: "mode",
  requiredScopes: [],
  inputSchema: { type: "object", properties: {}, required: [], additionalProperties: false, maxProperties: 0 },
  outputPolicy: { kind: "redacted_json", maxBytes: 1024 },
  request: { originKey: "github", method: "GET", pathTemplate: "/user" },
  limits: { timeoutMs: 1000, responseBytes: 1024, frameBytes: 1024, pageBytes: 1024 },
};

const snapshot: RunMcpSnapshot = {
  generation: "run-snapshot",
  operations: [{
    connectionId: "connection-1",
    providerId: "github",
    operationId: "get_user",
    modelName: "mcp__github__get_user",
    definition: operation,
    configVersion: 4,
    disconnectGeneration: 2,
  }],
};

function transition(): HealthTransition {
  const connection = {
    connectionId: "connection-1",
    userId: "owner",
    providerId: "github",
    enabled: true,
    agentEnabled: true,
    authState: "authorized" as const,
    healthState: "healthy" as const,
    lastCheckedAt: "2026-10-25T00:00:00.000Z",
    lastSuccessAt: "2026-10-25T00:00:00.000Z",
    configVersion: 4,
    disconnectGeneration: 2,
    hasSecrets: true,
  };
  return {
    connection,
    from: "never_checked",
    to: "healthy",
    lastCheckedAt: connection.lastCheckedAt,
    lastSuccessAt: connection.lastSuccessAt,
    persisted: true,
    code: "checked",
  };
}

function harness(verdict: "current" | "stale" | "denied" = "current") {
  const calls: Array<[string, string, string]> = [];
  const lifecycle: ConnectionHealthLifecycle = {
    async checkConnectionHealth(connectionId, uid, operationId) {
      calls.push([connectionId, uid, operationId]);
      return transition();
    },
    async getConnectionHealth(connectionId, uid) {
      expect([connectionId, uid]).toEqual(["connection-1", "owner"]);
      return transition().connection;
    },
    async disconnectConnection(connectionId, uid) {
      expect([connectionId, uid]).toEqual(["connection-1", "owner"]);
      return {
        ...transition().connection,
        enabled: false,
        agentEnabled: false,
        authState: "revoked" as const,
        healthState: "revoked" as const,
        disconnectGeneration: 3,
      };
    },
  };
  const invocations = createConnectionHealthInvocations({
    lifecycle,
    revalidate: async () => verdict,
  });
  const request: AuthenticatedConnectionHealthRequest = {
    principal: { uid: "owner", authenticated: true },
    connectionId: "connection-1",
    operationId: "get_user",
  };
  return { invocations, calls, request };
}

describe("connection health invocation boundaries", () => {
  it("requires a verified principal for an explicit health check and preserves owner scoping", async () => {
    const { invocations, calls, request } = harness();

    await expect(invocations.checkAuthenticated(request)).resolves.toMatchObject({ to: "healthy" });
    expect(calls).toEqual([["connection-1", "owner", "get_user"]]);

    await expect(invocations.checkAuthenticated({
      ...request,
      principal: { uid: "owner", authenticated: false },
    })).rejects.toMatchObject({ code: "authentication_required" });
    await expect(invocations.checkAuthenticated({
      ...request,
      principal: { uid: "other-user", authenticated: true },
    })).resolves.toMatchObject({ to: "healthy" });
    expect(calls.at(-1)).toEqual(["connection-1", "other-user", "get_user"]);
  });

  it("exposes authenticated live projection and disconnect through the same verified-principal boundary", async () => {
    const { invocations, request } = harness();
    const identity = { principal: request.principal, connectionId: request.connectionId };

    await expect(invocations.getAuthenticated(identity)).resolves.toMatchObject({ healthState: "healthy" });
    await expect(invocations.disconnectAuthenticated(identity)).resolves.toMatchObject({
      healthState: "revoked",
      disconnectGeneration: 3,
    });
    await expect(invocations.disconnectAuthenticated({
      ...identity,
      principal: { uid: "owner", authenticated: false },
    })).rejects.toMatchObject({ code: "authentication_required" });
  });

  it("invokes lazy health only for an exact selected and currently revalidated operation", async () => {
    const { invocations, calls } = harness();

    await expect(invocations.checkSelectedOperation({
      snapshot,
      uid: "owner",
      connectionId: "connection-1",
      operationId: "get_user",
    })).resolves.toMatchObject({ to: "healthy" });
    expect(calls).toEqual([["connection-1", "owner", "get_user"]]);

    await expect(invocations.checkSelectedOperation({
      snapshot,
      uid: "owner",
      connectionId: "connection-1",
      operationId: "list_issues",
    })).rejects.toMatchObject({ code: "operation_not_selected" });
    expect(calls).toHaveLength(1);
  });

  it.each(["stale", "denied"] as const)("does not probe when selected-operation revalidation is %s", async (verdict) => {
    const { invocations, calls } = harness(verdict);

    await expect(invocations.checkSelectedOperation({
      snapshot,
      uid: "owner",
      connectionId: "connection-1",
      operationId: "get_user",
    })).rejects.toMatchObject({ code: verdict === "stale" ? "connection_changed" : "operation_not_selected" });
    expect(calls).toEqual([]);
  });

  it("constructing either invocation surface performs no roster, discovery, or provider work", () => {
    const { calls } = harness();
    expect(calls).toEqual([]);
  });
});
