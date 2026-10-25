import { describe, expect, it, vi } from "vitest";

import {
  CURATED_IDS,
  CURATED_MANIFEST,
  KNOWN_PROVIDER_IDS,
  PRODUCTION_PROVIDER_REGISTRY,
  RESERVED_PROVIDER_NAMESPACES,
  createCuratedCatalog,
  createCuratedCatalogProjection,
  createCuratedManifest,
} from "./catalog.js";
import {
  createActivationService,
  createCuratedProviderSupport,
  type ActivationConnection,
} from "./activation.js";
import { createTestProviderRegistry } from "./__fixtures__/providerRegistry.js";
import {
  APPROVED_PROVIDER_IDENTITY_ADDITIONS,
  PROVIDER_DISPOSITION_MIGRATIONS,
  PROVIDER_FORMAL_IDENTITY_IDS,
  PROVIDER_RESERVED_ONLY_IDS,
  expectedFormalProviderIdentityIds,
  expectedReservedProviderIdentityIds,
} from "./__fixtures__/providerIdentityLedger.js";
import type { ProviderReadinessRow, ProviderRegistry } from "./providers/registry.js";
import type { ProviderDefinition } from "./providers/types.js";
import type { EgressRequest, ProviderEgress } from "./egress/providerEgress.js";
import type { McpCallContext } from "./transports/native.js";
import type { GuardedFetch } from "./ssrf.js";
import type { WorkspaceFiles } from "./workspace.js";
import { safeServerName } from "./toolNames.js";
import { DATA_SEARCH_PROVIDERS } from "./rest/descriptors/dataSearch.js";
import { COMMERCE_INFRA_PROVIDERS } from "./rest/descriptors/commerceInfra.js";
import { createFilesSuitesHandler } from "./rest/descriptors/filesSuites.js";

// Future dev/work support must exercise the same generic-override path as a
// real promotion. Production DEV_WORK_DESCRIPTORS remains evidence-filtered;
// only this isolated test adds the contract descriptors to that composition.
vi.mock("./rest/descriptors/index.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./rest/descriptors/index.js")>();
  const { DEV_WORK_CONTRACT_DESCRIPTORS } = await import("./rest/descriptors/devWork.js");
  return {
    ...actual,
    CURATED_DESCRIPTORS: [...actual.CURATED_DESCRIPTORS, ...DEV_WORK_CONTRACT_DESCRIPTORS],
  };
});

const workspace: WorkspaceFiles = {
  async read() { return null; },
  async write() {},
  async list() { return []; },
  async stat() { return null; },
  async remove() {},
};
const fetchImpl: GuardedFetch = async () => new Response("ok");

function connection(providerId: string): ActivationConnection {
  return {
    connectionId: `${providerId}-connection`,
    userId: "catalog-integration-user",
    providerId,
    enabled: true,
    agentEnabled: true,
    authState: "configured",
    configVersion: 1,
    disconnectGeneration: 0,
  };
}

async function activatedProviderIds(definitions: Parameters<typeof createActivationService>[0]["definitions"], providerIds: readonly string[]) {
  const activation = createActivationService({
    definitions,
    listConnections: async () => providerIds.map(connection),
    revalidateConnection: async () => "current",
  });
  const snapshot = await activation.snapshotForRun({
    userId: "catalog-integration-user",
    runId: "catalog-integration-run",
    sessionId: "catalog-integration-session",
    isSubagent: false,
    allow: [],
    deny: [],
    mode: "auto",
    planMode: false,
    unattended: false,
  });
  return [...new Set(snapshot.operations.map((operation) => operation.providerId))];
}

/** Data/commerce have no production readiness rows; build explicit test-only rows. */
function registerContractDefinition(
  registry: ProviderRegistry,
  definition: ProviderDefinition,
  origin: string,
  releaseState: "supported" | "candidate" | "blocked",
): void {
  const read = definition.operations.find((operation) => operation.effect === "read");
  if (read === undefined) throw new Error(`Missing typed read for ${definition.providerId}`);
  const supported = releaseState === "supported";
  const suffix = definition.providerId.toUpperCase().replaceAll("-", "_");
  const row: ProviderReadinessRow = {
    providerId: definition.providerId,
    catalogOwner: "catalog-integration-test",
    officialDocs: definition.officialDocs.map((doc) => ({
      ...doc,
      apiVersion: definition.catalogVersion,
      reviewer: "catalog-integration-test",
    })),
    operations: definition.operations.map((operation) => ({ ...operation })),
    auth: {
      profileId: definition.authProfileId,
      tokenType: "Isolated test credential profile",
      authorizationPrefix: "Bearer ",
      minimumScopes: read.requiredScopes,
      tenantOrigins: [origin],
      refreshBehavior: "Isolated test refresh behavior; no production claim.",
      revokeBehavior: "Isolated test revoke behavior; no production claim.",
      disconnectBehavior: "Isolated test disconnect behavior; no production claim.",
    },
    effects: Object.fromEntries(definition.operations.map((operation) => [operation.name, {
      effect: operation.effect,
      approval: operation.approval,
    }])),
    isolationEvidence: ["src/catalogIntegration.test.ts#isolated-test-only-composition"],
    fixtures: ["src/catalogIntegration.test.ts#sanitized-test-fixture"],
    automatedEvidence: {
      test: "src/catalogIntegration.test.ts",
      result: "passed",
      runAt: "2026-10-24T20:00:00.000Z",
    },
    liveReadEvidence: supported ? {
      command: `OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_${suffix}=1 isolated-test-only-composition`,
      operationId: read.name,
      runAt: "2026-10-24T20:01:00.000Z",
      evidence: "sanitized-result: isolated test-only composition; not live provider evidence",
    } : null,
    liveWriteEvidence: [],
    credentials: supported ? "passed" : "not provided",
    releaseState,
  };
  registry.registerProvider(definition, row);
}

function definitionFor(definitions: readonly ProviderDefinition[], providerId: string): ProviderDefinition {
  const definition = definitions.find((candidate) => candidate.providerId === providerId);
  if (definition === undefined) throw new Error(`Missing test contract definition ${providerId}`);
  return definition;
}

function jsonEgress(payload: unknown, requests: EgressRequest[] = []): ProviderEgress {
  return {
    async request(request) {
      requests.push(request);
      return {
        status: 200,
        headers: new Headers({ "content-type": "application/json" }),
        body: new Response(JSON.stringify(payload)).body as ReadableStream<Uint8Array>,
        origin: new URL(request.url.origin),
        remoteAddress: "192.0.2.10",
      };
    },
    async close() {},
  };
}

function callContext(secrets: Record<string, string>): McpCallContext {
  return {
    uid: "catalog-integration-user",
    secrets,
    workspace,
    fetchImpl,
    mode: "auto",
    planMode: false,
    unattended: false,
  } as unknown as McpCallContext;
}

const expectedProductionReadinessIds = expectedFormalProviderIdentityIds();
const expectedKnownIds = expectedReservedProviderIdentityIds();

describe("production provider inventory and support projection", () => {
  it("reserves every original, candidate, blocked, deprecated, and superseded ID without publishing it", async () => {
    expect(PROVIDER_FORMAL_IDENTITY_IDS).toHaveLength(101);
    expect([...PROVIDER_FORMAL_IDENTITY_IDS, ...PROVIDER_RESERVED_ONLY_IDS]).toHaveLength(105);
    expect(expectedProductionReadinessIds).toHaveLength(
      101 + APPROVED_PROVIDER_IDENTITY_ADDITIONS.filter((addition) => addition.formal).length,
    );
    expect(expectedKnownIds).toHaveLength(105 + APPROVED_PROVIDER_IDENTITY_ADDITIONS.length);
    expect(new Set(expectedProductionReadinessIds).size).toBe(expectedProductionReadinessIds.length);
    expect(new Set(expectedKnownIds).size).toBe(expectedKnownIds.length);
    expect(expectedKnownIds).toEqual(expect.arrayContaining(expectedProductionReadinessIds));
    expect(expectedKnownIds).toEqual(expect.arrayContaining(PROVIDER_RESERVED_ONLY_IDS));
    expect([...KNOWN_PROVIDER_IDS].sort()).toEqual([...expectedKnownIds].sort());
    expect(RESERVED_PROVIDER_NAMESPACES.size).toBe(KNOWN_PROVIDER_IDS.length);
    for (const providerId of KNOWN_PROVIDER_IDS) {
      expect(RESERVED_PROVIDER_NAMESPACES.has(safeServerName(providerId))).toBe(true);
    }

    expect(PRODUCTION_PROVIDER_REGISTRY.catalogDefinitions()).toEqual([]);
    expect(CURATED_IDS).toEqual([]);
    expect(CURATED_MANIFEST).toEqual([]);
    const catalog = createCuratedCatalog({ fetchImpl, workspace });
    const support = createCuratedProviderSupport();
    const projection = createCuratedCatalogProjection();
    expect(projection.definitions).toEqual([]);
    expect(projection.origins).toEqual({});
    expect(createCuratedManifest()).toEqual([]);
    expect(support.definitions).toEqual([]);
    expect(support.origins).toEqual({});
    for (const providerId of KNOWN_PROVIDER_IDS) expect(catalog.get(providerId)).toBeUndefined();
    expect(await activatedProviderIds(support.definitions, KNOWN_PROVIDER_IDS)).toEqual([]);
  });

  it("registers every current batch readiness row in the default registry without live support evidence", () => {
    const rows = PRODUCTION_PROVIDER_REGISTRY.rows();
    expect(rows.map((row) => row.providerId).sort()).toEqual([...expectedProductionReadinessIds].sort());
    expect(new Set(expectedProductionReadinessIds).size).toBe(expectedProductionReadinessIds.length);
    for (const row of rows) {
      expect(row.releaseState, row.providerId).not.toBe("supported");
      expect(row.liveReadEvidence, row.providerId).toBeNull();
      expect(row.liveWriteEvidence, row.providerId).toEqual([]);
      expect(row.credentials, row.providerId).not.toBe("passed");
    }
    for (const providerId of ["typeform", "docusign", "razorpay", "kubernetes", "opsgenie", "zapier"]) {
      expect(PRODUCTION_PROVIDER_REGISTRY.get(providerId)?.row.releaseState, providerId)
        .toMatch(/^(candidate|blocked|deprecated)$/);
    }
    for (const row of rows.filter((candidate) =>
      DATA_SEARCH_PROVIDERS.some((definition) => definition.providerId === candidate.providerId) ||
      COMMERCE_INFRA_PROVIDERS.some((definition) => definition.providerId === candidate.providerId)
    )) {
      expect(row.releaseState).toBe("candidate");
      expect(row.credentials).toBe("not provided");
    }
    expect(PRODUCTION_PROVIDER_REGISTRY.get("jira-service-management")?.row.supersedes).toBe("opsgenie");
    expect(PRODUCTION_PROVIDER_REGISTRY.get("kubernetes")?.row.releaseState).toBe("candidate");
    expect(PRODUCTION_PROVIDER_REGISTRY.get("opsgenie")?.row.releaseState).toBe("deprecated");
    expect(PRODUCTION_PROVIDER_REGISTRY.get("zapier")?.row.releaseState).toBe("blocked");
    for (const migration of PROVIDER_DISPOSITION_MIGRATIONS) {
      for (const providerId of migration.ids) {
        expect(expectedKnownIds, `${migration.from} must preserve ${providerId}`).toContain(providerId);
        expect(PRODUCTION_PROVIDER_REGISTRY.get(providerId)?.row.releaseState, providerId)
          .toBe(migration.expectedReleaseState);
        if (providerId === "redash") {
          expect(PRODUCTION_PROVIDER_REGISTRY.get(providerId)?.definition.operations).toEqual([]);
          expect(PRODUCTION_PROVIDER_REGISTRY.get(providerId)?.row.operations).toEqual([]);
        }
      }
    }
  });

  it("projects exactly the same mixed supported IDs to manifest, catalog, origins, and activation", async () => {
    const supported = [
      "github",
      "cloudflare",
      "freshdesk",
      "dropbox",
      "google-drive",
      "discord",
      "figma",
    ] as const;
    const registry = createTestProviderRegistry({
      supported,
      internal: ["exa", "vercel", "box", "mongodb"],
      concreteOrigins: { freshdesk: ["https://tenant-a.freshdesk.com"] },
    });
    registerContractDefinition(
      registry,
      definitionFor(DATA_SEARCH_PROVIDERS, "typeform"),
      "https://api.typeform.com",
      "supported",
    );
    registerContractDefinition(
      registry,
      definitionFor(DATA_SEARCH_PROVIDERS, "stripe"),
      "https://api.stripe.com",
      "candidate",
    );
    registerContractDefinition(
      registry,
      definitionFor(COMMERCE_INFRA_PROVIDERS, "razorpay"),
      "https://api.razorpay.com",
      "supported",
    );
    registerContractDefinition(
      registry,
      definitionFor(COMMERCE_INFRA_PROVIDERS, "square"),
      "https://connect.squareup.com",
      "blocked",
    );
    const expected = [...supported, "typeform", "razorpay"];

    const projection = createCuratedCatalogProjection(registry);
    const manifest = createCuratedManifest(registry);
    const support = createCuratedProviderSupport(registry);
    expect(projection.definitions.map((definition) => definition.providerId)).toEqual(expected);
    expect(manifest.map((entry) => entry.curatedId)).toEqual(expected);
    expect(support.definitions.map((definition) => definition.providerId)).toEqual(expected);
    expect(Object.keys(support.origins)).toEqual(expected);

    const providerEgress = jsonEgress({ success: true, errors: [], result: [] });
    const overrides = support.handlerOverrides(providerEgress);
    expect(Object.keys(overrides ?? {})).toEqual(["figma"]);
    const catalog = createCuratedCatalog({
      registry,
      fetchImpl,
      workspace,
      providerEgress,
      // Test-only custom-handler composition for the isolated synthetic registry.
      // Production remains blocked 0/10; no catalog defaultFactory branch exists.
      handlerOverrides: {
        ...overrides,
        dropbox: () => createFilesSuitesHandler("dropbox", { providerEgress }),
      },
    });
    expect(catalog.entries().map((entry) => entry.curatedId)).toEqual(expected);
    expect(await activatedProviderIds(support.definitions, registry.definitions().map((row) => row.providerId)))
      .toEqual(expected);
  });

  it("preserves the Cloudflare envelope validator instead of installing a generic REST override", async () => {
    const registry = createTestProviderRegistry({ supported: ["cloudflare"] });
    const support = createCuratedProviderSupport(registry);
    const providerEgress = jsonEgress({ success: false, errors: [{ message: "invalid" }], result: [] });
    const catalog = createCuratedCatalog({
      registry,
      fetchImpl,
      workspace,
      providerEgress,
      handlerOverrides: support.handlerOverrides(providerEgress),
    });
    const result = await catalog.get("cloudflare")!.handler.callTool(
      "list_zones",
      { page: 1, per_page: 5 },
      callContext({ api_token: "cloudflare-test-secret" }),
    );
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Provider returned an unsuccessful response.");
  });

  it("preserves Freshdesk tenant validation and derived Basic credentials", async () => {
    const registry = createTestProviderRegistry({
      supported: ["freshdesk"],
      concreteOrigins: { freshdesk: ["https://tenant-a.freshdesk.com"] },
    });
    const support = createCuratedProviderSupport(registry);
    const requests: EgressRequest[] = [];
    const providerEgress = jsonEgress([], requests);
    const catalog = createCuratedCatalog({
      registry,
      fetchImpl,
      workspace,
      providerEgress,
      handlerOverrides: support.handlerOverrides(providerEgress),
    });
    const result = await catalog.get("freshdesk")!.handler.callTool(
      "list_tickets",
      {},
      callContext({ api_key: "freshdesk-test-secret", subdomain: "tenant-a" }),
    );
    expect(result.isError).toBe(false);
    expect(requests).toHaveLength(1);
    expect(requests[0]?.headers.Authorization).toBe(
      `Basic ${Buffer.from("freshdesk-test-secret:X", "utf8").toString("base64")}`,
    );
  });
});
