// CURRENT REVISION UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25).
// Historical RED/GREEN logs predate these static edits and are not evidence
// that this revision passes, typechecks, or is ready for runtime composition.

import { describe, expect, it } from "vitest";

import {
  createActivationService,
  type ActivationConnection,
  type ActivationProvider,
} from "./activation.js";
import {
  CHILD_SCHEMA_BUDGET,
  ROOT_SCHEMA_BUDGET,
  discoverIntegrations,
  estimateSchemaTokens,
  loadIntegrationSchema,
  schemaBudgetFor,
  type SchemaBudget,
} from "./discovery.js";
import type { ActivatedOperation, RunMcpSnapshot } from "./activation.js";
import type { ProviderOperation } from "./providers/types.js";

const ROOT_BUDGET: SchemaBudget = {
  discoveryResults: 8,
  operationsPerProvider: 4,
  operationsPerRun: 12,
  schemaBytes: 24_576,
  schemaTokens: 8_192,
};

const CHILD_BUDGET: SchemaBudget = {
  discoveryResults: 4,
  operationsPerProvider: 2,
  operationsPerRun: 6,
  schemaBytes: 8_192,
  schemaTokens: 2_730,
};

function schema(description = "query input"): Record<string, unknown> {
  return {
    type: "object",
    description,
    properties: {
      query: { type: "string", minLength: 1, maxLength: 128 },
    },
    required: ["query"],
    additionalProperties: false,
    maxProperties: 1,
  };
}

function definition(
  operationId: string,
  patch: Partial<ProviderOperation> = {},
): ProviderOperation {
  return {
    name: operationId,
    description: `${operationId} summary`,
    effect: "read",
    approval: "mode",
    requiredScopes: [],
    inputSchema: schema(),
    outputPolicy: { kind: "redacted_json", maxBytes: 4096 },
    request: { originKey: "acme", method: "GET", pathTemplate: "/v1/items" },
    limits: { timeoutMs: 1000, responseBytes: 4096, frameBytes: 4096, pageBytes: 4096 },
    ...patch,
  };
}

function activated(
  providerId: string,
  connectionId: string,
  operationId: string,
  patch: Partial<ProviderOperation> = {},
): ActivatedOperation {
  return {
    providerId,
    connectionId,
    operationId,
    modelName: `mcp__${providerId}__${operationId}`,
    definition: definition(operationId, patch),
    configVersion: 7,
    disconnectGeneration: 3,
  };
}

function snapshot(operations: readonly ActivatedOperation[]): RunMcpSnapshot {
  return { generation: "run-local-generation", operations };
}

function connection(
  connectionId: string,
  patch: Partial<ActivationConnection> = {},
): ActivationConnection {
  return {
    connectionId,
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

function activationProvider(operations: readonly ProviderOperation[]): ActivationProvider {
  return { providerId: "acme", operations, readiness: "supported" };
}

async function activatedSnapshot(
  definitions: readonly ActivationProvider[],
  connections: readonly ActivationConnection[],
): Promise<RunMcpSnapshot> {
  const activation = createActivationService({
    definitions,
    listConnections: async () => connections,
    revalidateConnection: async () => "current",
  });
  return activation.snapshotForRun({
    userId: "user-1",
    runId: "run-root",
    sessionId: "session-root",
    isSubagent: false,
    allow: [],
    deny: [],
    mode: "auto",
    planMode: false,
    unattended: false,
  });
}

function ids(result: { results: readonly { providerId: string; connectionId: string; operationId: string }[] }) {
  return result.results.map((entry) => [entry.providerId, entry.connectionId, entry.operationId]);
}

describe("lazy integration discovery", () => {
  it("exposes the exact independent root and child schema budgets", () => {
    expect(ROOT_SCHEMA_BUDGET).toEqual(ROOT_BUDGET);
    expect(CHILD_SCHEMA_BUDGET).toEqual(CHILD_BUDGET);
    expect(schemaBudgetFor(false)).toEqual(ROOT_BUDGET);
    expect(schemaBudgetFor(true)).toEqual(CHILD_BUDGET);
  });

  it("uses a deterministic ceil(UTF-8 bytes / 3) planning estimate", () => {
    expect(estimateSchemaTokens("")).toBe(0);
    expect(estimateSchemaTokens("a")).toBe(1);
    expect(estimateSchemaTokens("ab")).toBe(1);
    expect(estimateSchemaTokens("abc")).toBe(1);
    expect(estimateSchemaTokens("abcd")).toBe(2);
    expect(estimateSchemaTokens("é")).toBe(1);
    expect(estimateSchemaTokens("🙂")).toBe(2);
  });

  it("keeps bounded summary selection stable across calls and shuffled cache reloads", () => {
    const operations = [
      activated("zeta", "connection-z", "read_zeta"),
      activated("alpha", "connection-2", "read_shared"),
      activated("beta", "connection-b", "read_beta"),
      activated("alpha", "connection-1", "read_shared"),
      activated("alpha", "connection-1", "read_alpha"),
    ];
    const budget = { ...ROOT_SCHEMA_BUDGET, discoveryResults: 4 };
    const query = {};

    const first = discoverIntegrations(snapshot(operations), query, budget);
    const second = discoverIntegrations(snapshot(operations), query, budget);
    const reloaded = discoverIntegrations(snapshot([...operations].reverse()), query, budget);

    expect(first).toEqual(second);
    expect(reloaded).toEqual(first);
    expect(ids(first)).toEqual([
      ["alpha", "connection-1", "read_alpha"],
      ["alpha", "connection-1", "read_shared"],
      ["alpha", "connection-2", "read_shared"],
      ["beta", "connection-b", "read_beta"],
    ]);
    expect(first.hasMore).toBe(true);
    expect(JSON.stringify(first)).not.toContain("inputSchema");
    expect(JSON.stringify(first)).not.toContain("pathTemplate");

    const narrowed = discoverIntegrations(
      snapshot([...operations].reverse()),
      { providerId: "zeta" },
      budget,
    );
    expect(ids(narrowed)).toEqual([["zeta", "connection-z", "read_zeta"]]);
    expect(narrowed.hasMore).toBe(false);

    const textNarrowed = discoverIntegrations(
      snapshot(operations),
      { query: "ALPHA read_alpha" },
      budget,
    );
    expect(ids(textNarrowed)).toEqual([["alpha", "connection-1", "read_alpha"]]);
  });

  it("describes the exact activated operation set as metadata", () => {
    const read = activated("acme", "connection-1", "read_item");
    const write = activated("acme", "connection-1", "write_item", {
      effect: "write",
      request: { originKey: "acme", method: "POST", pathTemplate: "/v1/items" },
    });
    const destroy = activated("acme", "connection-1", "delete_item", {
      effect: "destructive",
      approval: "per_action",
      request: { originKey: "acme", method: "DELETE", pathTemplate: "/v1/items/{id}" },
    });
    const current = snapshot([write, read, destroy]);

    const discovered = discoverIntegrations(current, {}, ROOT_SCHEMA_BUDGET);
    expect(ids(discovered)).toEqual([
      ["acme", "connection-1", "delete_item"],
      ["acme", "connection-1", "read_item"],
      ["acme", "connection-1", "write_item"],
    ]);
    const loaded = loadIntegrationSchema(current, {
      connectionId: "connection-1",
      operationIds: ["write_item"],
    }, ROOT_SCHEMA_BUDGET);
    expect(loaded.code).toBe("ok");
    expect(loaded.loaded.map((entry) => entry.operationId)).toEqual(["write_item"]);
    expect(loaded.loaded[0]?.inputSchema).toEqual(write.definition.inputSchema);
  });

  it("denies schema for a connection withheld by the production agentEnabled gate", async () => {
    const read = definition("read_item");
    const current = await activatedSnapshot(
      [activationProvider([read])],
      [
        connection("agent-enabled"),
        connection("agent-disabled", { agentEnabled: false }),
      ],
    );

    expect(current.operations.map((entry) => entry.connectionId)).toEqual(["agent-enabled"]);
    expect(loadIntegrationSchema(current, {
      connectionId: "agent-disabled",
      operationIds: ["read_item"],
    }, ROOT_SCHEMA_BUDGET)).toEqual({ code: "denied", loaded: [] });
    expect(loadIntegrationSchema(current, {
      connectionId: "agent-enabled",
      operationIds: ["read_item", "not-activated"],
    }, ROOT_SCHEMA_BUDGET)).toEqual({ code: "denied", loaded: [] });
  });
});

describe("run-local schema budgets", () => {
  it("enforces provider/run counters independently for root and child with atomic narrowing", () => {
    const operations = [
      ...["a", "b", "c"].flatMap((provider) =>
        [1, 2, 3, 4, 5].map((index) => activated(provider, `connection-${provider}`, `read_${index}`))
      ),
      activated("d", "connection-d", "read_1"),
    ];
    // Deliberately share one snapshot and its operation objects: usage must not
    // leak through a process-global operation/descriptor cache.
    const current = snapshot(operations);

    const rootBroad = loadIntegrationSchema(current, {
      connectionId: "connection-a",
      operationIds: ["read_5", "read_4", "read_3", "read_2", "read_1"],
    }, ROOT_SCHEMA_BUDGET);
    expect(rootBroad).toEqual({ code: "narrow_query", loaded: [] });

    const rootA = loadIntegrationSchema(current, {
      connectionId: "connection-a",
      operationIds: ["read_4", "read_2", "read_1", "read_3"],
    }, ROOT_SCHEMA_BUDGET);
    expect(rootA.code).toBe("ok");
    expect(rootA.loaded.map((entry) => entry.operationId)).toEqual([
      "read_1",
      "read_2",
      "read_3",
      "read_4",
    ]);
    // A cache-safe repeat returns the same whole schemas without consuming the
    // per-run allowance a second time.
    expect(loadIntegrationSchema(current, {
      connectionId: "connection-a",
      operationIds: ["read_1", "read_2", "read_3", "read_4", "read_1"],
    }, ROOT_SCHEMA_BUDGET)).toEqual(rootA);

    for (const provider of ["b", "c"]) {
      const result = loadIntegrationSchema(current, {
        connectionId: `connection-${provider}`,
        operationIds: ["read_1", "read_2", "read_3", "read_4"],
      }, ROOT_SCHEMA_BUDGET);
      expect(result.code).toBe("ok");
      expect(result.loaded).toHaveLength(4);
    }
    expect(loadIntegrationSchema(current, {
      connectionId: "connection-d",
      operationIds: ["read_1"],
    }, ROOT_SCHEMA_BUDGET)).toEqual({ code: "narrow_query", loaded: [] });

    expect(loadIntegrationSchema(current, {
      connectionId: "connection-a",
      operationIds: ["read_1", "read_2", "read_3"],
    }, CHILD_SCHEMA_BUDGET)).toEqual({ code: "narrow_query", loaded: [] });
    for (const provider of ["a", "b", "c"]) {
      const result = loadIntegrationSchema(current, {
        connectionId: `connection-${provider}`,
        operationIds: ["read_2", "read_1"],
      }, CHILD_SCHEMA_BUDGET);
      expect(result.code).toBe("ok");
      expect(result.loaded).toHaveLength(2);
    }
    expect(loadIntegrationSchema(current, {
      connectionId: "connection-d",
      operationIds: ["read_1"],
    }, CHILD_SCHEMA_BUDGET)).toEqual({ code: "narrow_query", loaded: [] });
  });

  it("shares usage across equivalent budget clones without sharing root/child or snapshots", () => {
    const current = snapshot([1, 2, 3, 4, 5].map((index) =>
      activated("acme", "connection-1", `read_${index}`)
    ));
    const first = loadIntegrationSchema(current, {
      connectionId: "connection-1",
      operationIds: ["read_1", "read_2", "read_3", "read_4"],
    }, { ...ROOT_SCHEMA_BUDGET });
    expect(first.code).toBe("ok");

    // A wrapper may deserialize/clone an equivalent budget on every call. It
    // must not reset the same snapshot's provider/run/byte/token ledger.
    expect(loadIntegrationSchema(current, {
      connectionId: "connection-1",
      operationIds: ["read_5"],
    }, { ...ROOT_SCHEMA_BUDGET })).toEqual({ code: "narrow_query", loaded: [] });

    const child = loadIntegrationSchema(current, {
      connectionId: "connection-1",
      operationIds: ["read_5"],
    }, { ...CHILD_SCHEMA_BUDGET });
    expect(child.code).toBe("ok");
    const separateSnapshot = loadIntegrationSchema(snapshot([...current.operations]), {
      connectionId: "connection-1",
      operationIds: ["read_5"],
    }, { ...ROOT_SCHEMA_BUDGET });
    expect(separateSnapshot.code).toBe("ok");
  });

  it("counts provider operations across connections and isolates a reloaded run", () => {
    const current = snapshot([
      ...[1, 2, 3, 4].map((index) =>
        activated("acme", "connection-1", `read_${index}`)
      ),
      activated("acme", "connection-2", "read_5"),
    ]);
    const first = loadIntegrationSchema(current, {
      connectionId: "connection-1",
      operationIds: ["read_1", "read_2", "read_3", "read_4"],
    }, ROOT_SCHEMA_BUDGET);
    expect(first.code).toBe("ok");
    expect(first.loaded).toHaveLength(4);

    // The fifth operation is on another connection, but still belongs to the
    // same provider and the same run's four-operation provider allowance.
    expect(loadIntegrationSchema(current, {
      connectionId: "connection-2",
      operationIds: ["read_5"],
    }, ROOT_SCHEMA_BUDGET)).toEqual({ code: "narrow_query", loaded: [] });

    // A cache reload is a new run-local snapshot, not authority to share usage
    // with the old run even when IDs and definitions are otherwise identical.
    const reloaded = snapshot([...current.operations].reverse());
    const afterReload = loadIntegrationSchema(reloaded, {
      connectionId: "connection-2",
      operationIds: ["read_5"],
    }, ROOT_SCHEMA_BUDGET);
    expect(afterReload.code).toBe("ok");
    expect(afterReload.loaded.map((entry) => entry.operationId)).toEqual(["read_5"]);
  });

  it("fails schema-byte overflow atomically and returns only complete valid JSON schemas", () => {
    const first = activated("acme", "connection-1", "read_1", {
      inputSchema: schema("first schema with a deterministic size"),
    });
    const second = activated("acme", "connection-1", "read_2", {
      inputSchema: schema("second schema with another deterministic size"),
    });
    const current = snapshot([second, first]);
    const firstBytes = Buffer.byteLength(JSON.stringify(first.definition.inputSchema), "utf8");
    const secondBytes = Buffer.byteLength(JSON.stringify(second.definition.inputSchema), "utf8");
    const budget = {
      ...ROOT_SCHEMA_BUDGET,
      schemaBytes: firstBytes + secondBytes - 1,
    };

    expect(loadIntegrationSchema(current, {
      connectionId: "connection-1",
      operationIds: ["read_1", "read_2"],
    }, budget)).toEqual({ code: "narrow_query", loaded: [] });

    const narrowed = loadIntegrationSchema(current, {
      connectionId: "connection-1",
      operationIds: ["read_1"],
    }, budget);
    expect(narrowed.code).toBe("ok");
    expect(narrowed.loaded[0]?.inputSchema).toEqual(first.definition.inputSchema);
    expect(JSON.parse(JSON.stringify(narrowed))).toEqual(narrowed);

    expect(loadIntegrationSchema(current, {
      connectionId: "connection-1",
      operationIds: ["read_2"],
    }, { ...budget })).toEqual({ code: "narrow_query", loaded: [] });
  });

  it("enforces the estimated-token ceiling independently of the byte ceiling", () => {
    const first = activated("acme", "connection-1", "read_1", {
      inputSchema: schema("é🙂 first"),
    });
    const second = activated("acme", "connection-1", "read_2", {
      inputSchema: schema("second"),
    });
    const current = snapshot([first, second]);
    const firstTokens = Math.ceil(
      Buffer.byteLength(JSON.stringify(first.definition.inputSchema), "utf8") / 3,
    );
    const secondTokens = Math.ceil(
      Buffer.byteLength(JSON.stringify(second.definition.inputSchema), "utf8") / 3,
    );
    const budget = {
      ...ROOT_SCHEMA_BUDGET,
      schemaBytes: 100_000,
      schemaTokens: firstTokens + secondTokens - 1,
    };

    expect(loadIntegrationSchema(current, {
      connectionId: "connection-1",
      operationIds: ["read_1", "read_2"],
    }, budget)).toEqual({ code: "narrow_query", loaded: [] });
    const narrowed = loadIntegrationSchema(current, {
      connectionId: "connection-1",
      operationIds: ["read_1"],
    }, budget);
    expect(narrowed.code).toBe("ok");
    expect(narrowed.loaded).toHaveLength(1);
    expect(narrowed.loaded[0]?.inputSchema).toEqual(first.definition.inputSchema);
    expect(loadIntegrationSchema(current, {
      connectionId: "connection-1",
      operationIds: ["read_2"],
    }, { ...budget })).toEqual({ code: "narrow_query", loaded: [] });
  });
});
