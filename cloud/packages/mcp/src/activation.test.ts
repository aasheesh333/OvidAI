import { describe, expect, it, vi } from "vitest";

import {
  createActivationService,
  createCuratedProviderSupport,
  type ActivationConnection,
  type ActivationRevalidation,
} from "./activation.js";
import type { ProviderDefinition, ProviderOperation } from "./providers/types.js";

const SECRET_CANARY = "plaintext-must-never-enter-a-snapshot";

function operation(name: string, patch: Partial<ProviderOperation> = {}): ProviderOperation {
  return {
    name,
    description: `${name} description`,
    effect: "read",
    approval: "mode",
    requiredScopes: [],
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", minLength: 1, maxLength: 128 },
      },
      required: ["query"],
      additionalProperties: false,
      maxProperties: 1,
    },
    outputPolicy: { kind: "redacted_json", maxBytes: 4096 },
    request: { originKey: "acme", method: "GET", pathTemplate: "/v1/items" },
    limits: { timeoutMs: 1000, responseBytes: 4096, frameBytes: 4096, pageBytes: 4096 },
    ...patch,
  };
}

function definition(operations: readonly ProviderOperation[] = [operation("list_items")]): ProviderDefinition {
  return {
    providerId: "acme",
    catalogVersion: "2026-10-24",
    displayName: "Acme",
    description: "Acme typed test provider",
    officialDocs: [{ url: "https://docs.acme.test/api", verifiedAt: "2026-10-24" }],
    authProfileId: "acme-key",
    connectionSchema: {
      type: "object",
      properties: { api_key: { type: "string", maxLength: 256 } },
      required: ["api_key"],
      additionalProperties: false,
      maxProperties: 1,
    },
    operations,
    readiness: "supported",
  };
}

function connection(patch: Partial<ActivationConnection> = {}): ActivationConnection {
  return {
    connectionId: "connection-1",
    userId: "user-1",
    providerId: "acme",
    enabled: true,
    agentEnabled: true,
    authState: "configured",
    configVersion: 7,
    disconnectGeneration: 3,
    ...patch,
  };
}

function harness(o: {
  definitions?: readonly ProviderDefinition[];
  connections?: readonly ActivationConnection[];
  revalidate?: (call: {
    connectionId: string;
    userId: string;
    configVersion: number;
    disconnectGeneration: number;
  }) => Promise<ActivationRevalidation>;
} = {}) {
  const listConnections = vi.fn(async (_userId: string) => o.connections ?? [connection()]);
  const revalidate = vi.fn(o.revalidate ?? (async (
    call: {
      connectionId: string;
      userId: string;
      configVersion: number;
      disconnectGeneration: number;
    },
  ): Promise<ActivationRevalidation> => {
    const current = (o.connections ?? [connection()]).find(
      (row) => row.connectionId === call.connectionId && row.userId === call.userId,
    );
    if (current === undefined || !current.enabled || !current.agentEnabled ||
        (current.authState !== "configured" && current.authState !== "authorized")) return "denied";
    return current.configVersion === call.configVersion &&
      current.disconnectGeneration === call.disconnectGeneration ? "current" : "stale";
  }));
  const closeRun = vi.fn(async (_runId: string) => {});
  const service = createActivationService({
    definitions: o.definitions ?? [definition()],
    listConnections,
    revalidateConnection: revalidate,
    closeRun,
  });
  return { service, listConnections, revalidate, closeRun };
}

const rootInput = {
  userId: "user-1",
  runId: "run-root",
  sessionId: "session-root",
  isSubagent: false,
  allow: [],
  deny: [],
  mode: "auto",
  planMode: false,
  unattended: false,
} as const;

describe("per-run activation snapshots", () => {
  it("composes only supported, explicitly activated, auth-ready current-user operations without secrets", async () => {
    const otherDefinition = { ...definition(), providerId: "other" };
    const rows = [
      { ...connection(), secrets: { api_key: SECRET_CANARY }, config: { api_key: SECRET_CANARY } },
      connection({ connectionId: "disabled", enabled: false }),
      connection({ connectionId: "agent-off", agentEnabled: false }),
      connection({ connectionId: "needs-auth", authState: "needs_auth" }),
      connection({ connectionId: "missing-auth", authState: "missing" }),
      connection({ connectionId: "revoked", authState: "revoked" }),
      connection({ connectionId: "unsupported", providerId: "not-registered" }),
      connection({ connectionId: "other-user", userId: "user-2" }),
      connection({ connectionId: "other-provider", providerId: "other" }),
    ];
    const { service, listConnections } = harness({
      definitions: [definition(), otherDefinition],
      connections: rows,
    });

    const snapshot = await service.snapshotForRun(rootInput);

    expect(listConnections).toHaveBeenCalledTimes(1);
    expect(listConnections).toHaveBeenCalledWith("user-1");
    expect(snapshot.operations.map((op) => [op.connectionId, op.operationId])).toEqual([
      ["connection-1", "list_items"],
      ["other-provider", "list_items"],
    ]);
    expect(snapshot.operations[0]).toMatchObject({
      providerId: "acme",
      modelName: "mcp__acme__list_items",
      configVersion: 7,
      disconnectGeneration: 3,
    });
    expect(JSON.stringify(snapshot)).not.toContain(SECRET_CANARY);
    expect(JSON.stringify(snapshot)).not.toContain("secretsSealed");
  });

  it("intersects the parent's exact activated pairs with child policy without loading connections", async () => {
    const { service, listConnections } = harness({
      definitions: [definition([operation("list_items"), operation("get_item")])],
    });
    const parent = await service.snapshotForRun({
      ...rootInput,
      deny: ["mcp__acme__get_item"],
    });
    expect(parent.operations.map((op) => op.operationId)).toEqual(["list_items"]);
    listConnections.mockClear();

    const child = await service.snapshotForRun({
      ...rootInput,
      runId: "run-child",
      sessionId: "session-child",
      isSubagent: true,
      parent,
      allow: ["*"],
    });

    expect(child.operations.map((op) => [op.connectionId, op.operationId])).toEqual([
      ["connection-1", "list_items"],
    ]);
    expect(child.operations.some((op) => op.operationId === "get_item")).toBe(false);
    expect(listConnections).not.toHaveBeenCalled();
    expect(JSON.stringify(child)).not.toContain(SECRET_CANARY);

    const noParent = await service.snapshotForRun({
      ...rootInput,
      runId: "run-orphan",
      isSubagent: true,
      allow: ["*"],
    });
    expect(noParent.operations).toEqual([]);
  });

  it("keeps the exact parent object available for later child turns after root close without reviving root calls", async () => {
    const { service } = harness();
    const parent = await service.snapshotForRun(rootInput);
    const forged = { ...parent };
    expect(await service.revalidate(forged, {
      connectionId: "connection-1",
      operationId: "list_items",
    })).toBe("denied");

    await service.closeRun("run-root");
    expect(await service.revalidate(parent, {
      connectionId: "connection-1",
      operationId: "list_items",
    })).toBe("denied");
    const laterChild = await service.snapshotForRun({
      ...rootInput,
      runId: "run-child-later",
      sessionId: "session-child",
      isSubagent: true,
      parent,
      allow: ["*"],
    });
    expect(laterChild.operations.map((op) => op.operationId)).toEqual(["list_items"]);
  });

  it("revalidates activation and both generations at every call and denies unrostered direct calls", async () => {
    const rows = [connection()];
    const { service, revalidate, closeRun } = harness({ connections: rows });
    const snapshot = await service.snapshotForRun(rootInput);

    expect(await service.revalidate(snapshot, {
      connectionId: "connection-1",
      operationId: "list_items",
    })).toBe("current");
    expect(revalidate).toHaveBeenLastCalledWith({
      connectionId: "connection-1",
      userId: "user-1",
      configVersion: 7,
      disconnectGeneration: 3,
    });
    expect(await service.revalidate(snapshot, {
      connectionId: "connection-1",
      operationId: "not_in_parent_roster",
    })).toBe("denied");
    expect(revalidate).toHaveBeenCalledTimes(1);

    rows[0] = connection({ configVersion: 8 });
    expect(await service.revalidate(snapshot, {
      connectionId: "connection-1",
      operationId: "list_items",
    })).toBe("stale");
    rows[0] = connection({ agentEnabled: false });
    expect(await service.revalidate(snapshot, {
      connectionId: "connection-1",
      operationId: "list_items",
    })).toBe("denied");

    await service.closeRun("run-root");
    expect(closeRun).toHaveBeenCalledTimes(1);
    expect(closeRun).toHaveBeenCalledWith("run-root");
    expect(await service.revalidate(snapshot, {
      connectionId: "connection-1",
      operationId: "list_items",
    })).toBe("denied");
  });

  it("withholds operations that the run policy cannot execute and detects model-name collisions", async () => {
    const write = operation("write_item", {
      effect: "write",
      request: { originKey: "acme", method: "POST", pathTemplate: "/v1/items" },
    });
    const destructive = operation("delete_item", {
      effect: "destructive",
      approval: "per_action",
      request: { originKey: "acme", method: "DELETE", pathTemplate: "/v1/items/{id}" },
    });
    const { service } = harness({ definitions: [definition([operation("list_items"), write, destructive])] });
    const planned = await service.snapshotForRun({
      ...rootInput,
      runId: "run-plan",
      planMode: true,
      allow: ["*"],
    });
    expect(planned.operations.map((op) => op.operationId)).toEqual(["list_items"]);

    const unattended = await service.snapshotForRun({
      ...rootInput,
      runId: "run-unattended",
      unattended: true,
      allow: ["*"],
    });
    expect(unattended.operations.map((op) => op.operationId)).toEqual(["list_items", "write_item"]);

    const collision = harness({
      connections: [connection(), connection({ connectionId: "connection-2" })],
    });
    await expect(collision.service.snapshotForRun(rootInput)).rejects.toThrow("model_name_collision");
  });

  it("builds pinned generic REST support while leaving special, dynamic and unreviewed handlers unrostered", () => {
    const support = createCuratedProviderSupport();
    const ids = support.definitions.map((provider) => provider.providerId);
    expect(ids).toContain("exa");
    for (const excluded of [
      "linear",
      "firebase",
      "mongodb",
      "s3",
      "google-drive",
      "gitlab",
      "jira",
      "supabase",
    ]) {
      expect(ids).not.toContain(excluded);
    }
    expect(support.origins.exa?.map((url) => url.origin)).toEqual(["https://api.exa.ai"]);
    const exa = support.definitions.find((provider) => provider.providerId === "exa");
    expect(exa?.operations.some((operation) => operation.name === "search")).toBe(true);
    expect(exa?.operations.every((operation) =>
      operation.inputSchema.additionalProperties === false &&
      operation.request.originKey === "exa"
    )).toBe(true);
  });
});
