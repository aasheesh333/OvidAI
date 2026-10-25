import { describe, expect, it } from "vitest";
import {
  createProviderRegistry,
  type AuthProfile,
  type LiveEvidence,
  type ProviderReadinessRow,
} from "./registry.js";
import type { ProviderDefinition, ProviderOperation } from "./types.js";

const LIMITS = { timeoutMs: 5_000, responseBytes: 4_096, frameBytes: 4_096, pageBytes: 4_096 };
const INPUT_SCHEMA = {
  type: "object",
  properties: {},
  required: [],
  additionalProperties: false,
  maxProperties: 0,
};

function operation(patch: Partial<ProviderOperation> = {}): ProviderOperation {
  return {
    name: "get_current_user",
    description: "Read the authenticated user through the official provider endpoint.",
    effect: "read",
    approval: "mode",
    requiredScopes: ["user:read"],
    inputSchema: INPUT_SCHEMA,
    outputPolicy: { kind: "redacted_json", maxBytes: 4_096 },
    request: { originKey: "acme", method: "GET", pathTemplate: "/v1/user" },
    limits: LIMITS,
    ...patch,
  };
}

function definition(patch: Partial<ProviderDefinition> = {}): ProviderDefinition {
  return {
    providerId: "acme",
    catalogVersion: "1",
    displayName: "Acme",
    description: "Acme's documented current-user read.",
    officialDocs: [{ url: "https://docs.acme.test/api", verifiedAt: "2026-10-24" }],
    authProfileId: "acme-user-token",
    connectionSchema: {
      type: "object",
      properties: { token: { type: "string", minLength: 1, maxLength: 256 } },
      required: ["token"],
      additionalProperties: false,
      maxProperties: 1,
    },
    operations: [operation()],
    readiness: "supported",
    ...patch,
  };
}

function auth(): AuthProfile {
  return {
    profileId: "acme-user-token",
    tokenType: "OAuth user access token",
    authorizationPrefix: "Bearer ",
    minimumScopes: ["user:read"],
    tenantOrigins: ["https://api.acme.test"],
    refreshBehavior: "Refresh only through the connection-bound OAuth grant.",
    revokeBehavior: "Revoke the provider grant when supported.",
    disconnectBehavior: "Delete sealed connection configuration and prevent later calls.",
  };
}

function live(patch: Partial<LiveEvidence> = {}): LiveEvidence {
  return {
    command: "OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_ACME=1 vitest run test/liveProvider.test.ts",
    operationId: "get_current_user",
    runAt: "2026-10-24T12:00:00.000Z",
    evidence: "sanitized-result: HTTP 200; user id present; secrets omitted",
    ...patch,
  };
}

function row(patch: Partial<ProviderReadinessRow> = {}): ProviderReadinessRow {
  return {
    providerId: "acme",
    catalogOwner: "connectors-originals",
    officialDocs: [{
      url: "https://docs.acme.test/api",
      apiVersion: "v1",
      verifiedAt: "2026-10-24",
      reviewer: "official-doc-review",
    }],
    operations: [operation()],
    auth: auth(),
    effects: { get_current_user: { effect: "read", approval: "mode" } },
    isolationEvidence: ["src/providers/registry.test.ts#cross-tenant"],
    fixtures: ["test/providers/originals.contract.test.ts#acme-sanitized"],
    automatedEvidence: {
      test: "test/providers/originals.contract.test.ts",
      result: "passed",
      runAt: "2026-10-24T11:59:00.000Z",
    },
    liveReadEvidence: live(),
    liveWriteEvidence: [],
    credentials: "passed",
    releaseState: "supported",
    ...patch,
  };
}

describe("provider readiness registry", () => {
  it("admits a fully evidenced supported row and rejects a colliding provider ID", () => {
    const registry = createProviderRegistry({ now: () => new Date("2026-10-24T13:00:00.000Z") });
    registry.registerProvider(definition(), row());
    expect(registry.catalogDefinitions().map((item) => item.providerId)).toEqual(["acme"]);
    expect(() => registry.registerProvider(definition(), row())).toThrow(/collid|already|duplicate/i);
  });

  it("keeps candidate, blocked, deprecated, and descriptor-only rows out of the catalog", () => {
    const registry = createProviderRegistry();
    for (const releaseState of ["candidate", "blocked", "deprecated"] as const) {
      const id = `acme-${releaseState}`;
      registry.registerProvider(
        definition({ providerId: id, operations: [operation({ request: { ...operation().request, originKey: id } })] }),
        row({
          providerId: id,
          operations: [operation({ request: { ...operation().request, originKey: id } })],
          releaseState,
          credentials: "not provided",
          liveReadEvidence: null,
          automatedEvidence: { test: "test/providers/originals.contract.test.ts", result: "not_run", runAt: null },
        }),
      );
    }
    expect(registry.rows()).toHaveLength(3);
    expect(registry.catalogDefinitions()).toEqual([]);
    expect(() => registry.assertCatalogCallable("acme-candidate")).toThrow(/not supported|unavailable|blocked/i);
  });

  it("registers descriptor-absent blocked IDs without inventing callable operations", () => {
    const registry = createProviderRegistry();
    registry.registerProvider(
      definition({ operations: [] }),
      row({
        releaseState: "blocked",
        operations: [],
        effects: {},
        credentials: "not provided",
        liveReadEvidence: null,
        automatedEvidence: { test: "src/providers/registry.test.ts#descriptor-absent-blocked", result: "not_run", runAt: null },
      }),
    );
    expect(registry.get("acme")?.row.releaseState).toBe("blocked");
    expect(registry.catalogDefinitions()).toEqual([]);
    expect(() => registry.assertCatalogCallable("acme")).toThrow(/not supported|unavailable|blocked/i);
  });

  it("deeply freezes, defensively copies, and revalidates every readiness read", () => {
    const inputDefinition = definition();
    const inputRow = row({
      releaseState: "blocked",
      credentials: "not provided",
      liveReadEvidence: null,
    });
    const registry = createProviderRegistry();
    const registration = registry.registerProvider(inputDefinition, inputRow);

    inputRow.releaseState = "supported";
    inputRow.credentials = "passed";
    inputRow.auth.minimumScopes = [...inputRow.auth.minimumScopes, "admin:write"];
    inputDefinition.operations[0].description = "caller-mutated";
    expect(registry.catalogDefinitions()).toEqual([]);
    expect(registration.row.releaseState).toBe("blocked");

    const first = registry.get("acme");
    const second = registry.get("acme");
    expect(first).not.toBe(second);
    expect(first?.row).not.toBe(second?.row);
    expect(first?.row.auth).not.toBe(second?.row.auth);
    expect(first?.row.operations[0]).not.toBe(second?.row.operations[0]);
    expect(Object.isFrozen(first?.row)).toBe(true);
    expect(Object.isFrozen(first?.row.auth)).toBe(true);
    expect(Object.isFrozen(first?.row.operations)).toBe(true);
    expect(Object.isFrozen(first?.row.operations[0])).toBe(true);
    expect(() => { first!.row.releaseState = "supported"; }).toThrow(TypeError);
    expect(() => { first!.row.auth.minimumScopes = [...first!.row.auth.minimumScopes, "admin:write"]; }).toThrow(TypeError);
    expect(() => { first!.row.operations[0].description = "mutated"; }).toThrow(TypeError);
    expect(() => { first!.definition.displayName = "mutated"; }).toThrow(TypeError);
    expect(registry.rows()[0].releaseState).toBe("blocked");
    expect(registry.assertCatalogCallable).toThrow(/not supported|unavailable|blocked/i);
  });

  it("rejects fake ping operations even when other evidence looks complete", () => {
    const registry = createProviderRegistry();
    const ping = operation({ name: "ping", description: "Ping.", request: { originKey: "acme", method: "GET", pathTemplate: "/ping" } });
    expect(() => registry.registerProvider(
      definition({ operations: [ping] }),
      row({ operations: [ping], effects: { ping: { effect: "read", approval: "mode" } }, liveReadEvidence: live({ operationId: "ping" }) }),
    )).toThrow(/ping|real typed read|operation/i);
  });

  it("rejects ping and noop even in the narrow native fetch composition", () => {
    for (const name of ["ping", "noop"] as const) {
      const fake = operation({
        name,
        description: `${name} is not a typed provider read.`,
        request: { originKey: "public-web", method: "GET", pathTemplate: `/${name}` },
      });
      expect(() => createProviderRegistry().registerProvider(
        definition({ providerId: "fetch", operations: [fake] }),
        row({
          providerId: "fetch",
          operations: [fake],
          effects: { [name]: { effect: "read", approval: "mode" } },
          liveReadEvidence: live({ operationId: name }),
        }),
      ), name).toThrow(/fake ping|real typed operation|operation/i);
    }
  });

  it("does not leak the narrow native exception to a non-native provider", () => {
    const nearMiss = operation({
      name: "fetch",
      request: { originKey: "public-web", method: "GET", pathTemplate: "/{url}" },
      inputSchema: {
        type: "object",
        properties: { url: { type: "string", minLength: 1, maxLength: 2_048 } },
        required: ["url"],
        additionalProperties: false,
        maxProperties: 1,
      },
    });
    expect(() => createProviderRegistry().registerProvider(
      definition({ operations: [nearMiss] }),
      row({ operations: [nearMiss], effects: { fetch: { effect: "read", approval: "mode" } } }),
    )).toThrow(/generic fetch|model-controlled URL|arbitrary request/i);
  });

  it("rejects generic-fetch aliases and arbitrary request operations", () => {
    const aliases = [
      "target", "uri", "endpoint", "requestUrl", "request_url", "targetUrl", "target_url",
      "endpointUrl", "endpoint_url", "baseUrl", "base_url", "proxy", "method", "headers",
    ];
    for (const alias of aliases) {
      const generic = operation({
        inputSchema: {
          type: "object",
          properties: { [alias]: { type: "string", minLength: 1, maxLength: 2_048 } },
          required: [alias],
          additionalProperties: false,
          maxProperties: 1,
        },
      });
      expect(() => createProviderRegistry().registerProvider(
        definition({ operations: [generic] }),
        row({ operations: [generic] }),
      ), alias).toThrow(/generic fetch|arbitrary request|url|implementation/i);
    }
    for (const [name, originKey, pathTemplate] of [
      ["request", "generic", "/v1/items"],
      ["http_request", "acme", "/{target}"],
      ["get_current_user", "generic-fetch", "/v1/items"],
      ["get_current_user", "public_web", "/v1/items"],
      ["get_current_user", "target", "/v1/items"],
      ["get_current_user", "endpoint", "/v1/items"],
      ["fetch", "acme", "/v1/items"],
    ] as const) {
      const generic = operation({
        name,
        request: { originKey, method: "GET", pathTemplate },
      });
      expect(() => createProviderRegistry().registerProvider(
        definition({ operations: [generic] }),
        row({ operations: [generic] }),
      ), `${name}/${originKey}/${pathTemplate}`).toThrow(/generic fetch|arbitrary request|implementation/i);
    }
  });

  it("rejects incomplete official metadata and impossible or future verification dates", () => {
    const registry = createProviderRegistry({ now: () => new Date("2026-10-24T13:00:00.000Z") });
    for (const officialDocs of [
      [],
      [{ url: "http://docs.acme.test/api", apiVersion: "v1", verifiedAt: "2026-10-24", reviewer: "reviewer" }],
      [{ url: "https://docs.acme.test/api", apiVersion: "", verifiedAt: "2026-10-24", reviewer: "reviewer" }],
      [{ url: "https://docs.acme.test/api", apiVersion: "v1", verifiedAt: "2026-02-30", reviewer: "reviewer" }],
      [{ url: "https://docs.acme.test/api", apiVersion: "v1", verifiedAt: "2026-10-25", reviewer: "reviewer" }],
      [{ url: "https://docs.acme.test/api", apiVersion: "v1", verifiedAt: "2026-10-24", reviewer: "" }],
    ]) {
      expect(() => registry.registerProvider(definition(), row({ officialDocs }))).toThrow(/docs|date|reviewer|version/i);
    }
  });

  it("rejects operation, effect, approval, and auth-profile mismatches", () => {
    const cases: ProviderReadinessRow[] = [
      row({ operations: [] }),
      row({ effects: {} }),
      row({ effects: { get_current_user: { effect: "write", approval: "mode" } } }),
      row({ effects: { get_current_user: { effect: "read", approval: "per_action" } } }),
      row({ auth: { ...auth(), profileId: "different-profile" } }),
    ];
    for (const candidate of cases) {
      const registry = createProviderRegistry();
      expect(() => registry.registerProvider(definition(), candidate)).toThrow(/mismatch|operation|effect|approval|auth/i);
    }
  });

  it("rejects a generic fetch implementation and model-controlled provider URLs", () => {
    const generic = operation({
      inputSchema: {
        type: "object",
        properties: { url: { type: "string", minLength: 1, maxLength: 2_048 } },
        required: ["url"],
        additionalProperties: false,
        maxProperties: 1,
      },
      request: { originKey: "fetch", method: "GET", pathTemplate: "/{url}" },
    });
    const registry = createProviderRegistry();
    expect(() => registry.registerProvider(
      definition({ operations: [generic] }),
      row({ operations: [generic], liveReadEvidence: live() }),
    )).toThrow(/generic fetch|url|implementation/i);
  });

  it("requires actual contract, isolation, fixtures, and live-read evidence for support", () => {
    const incomplete: Partial<ProviderReadinessRow>[] = [
      { liveReadEvidence: null },
      { credentials: "configured" },
      { automatedEvidence: { test: "test/providers/originals.contract.test.ts", result: "not_run", runAt: null } },
      { isolationEvidence: [] },
      { fixtures: [] },
      { liveReadEvidence: live({ evidence: "TODO" }) },
      { liveReadEvidence: live({ evidence: "not-run" }) },
      { liveReadEvidence: live({ runAt: "2026-10-24" }) },
      { liveReadEvidence: live({ operationId: "missing" }) },
    ];
    for (const patch of incomplete) {
      const registry = createProviderRegistry({ now: () => new Date("2026-10-24T13:00:00.000Z") });
      expect(() => registry.registerProvider(definition(), row(patch))).toThrow(/evidence|credential|live|operation|date|isolation|fixture/i);
    }
  });

  it("rejects live evidence without provider opt-in, disposable write declaration, or cleanup proof", () => {
    const missingProviderOptIn = live({
      command: "OVID_LIVE_PROVIDER_TESTS=1 vitest run test/liveProvider.test.ts",
    });
    expect(() => createProviderRegistry().registerProvider(definition(), row({
      liveReadEvidence: missingProviderOptIn,
    }))).toThrow(/OVID_LIVE_PROVIDER_ACME/);

    const write = operation({
      name: "send_message",
      effect: "external_communication",
      approval: "per_action",
      request: { originKey: "acme", method: "POST", pathTemplate: "/v1/messages" },
    });
    const def = definition({ operations: [operation(), write] });
    const base = row({
      operations: [operation(), write],
      effects: {
        get_current_user: { effect: "read", approval: "mode" },
        send_message: { effect: "external_communication", approval: "per_action" },
      },
      liveReadEvidence: live({ command: "OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_ACME=1 vitest run test/liveProvider.test.ts" }),
    });
    expect(() => createProviderRegistry().registerProvider(def, {
      ...base,
      liveWriteEvidence: [live({
        command: "OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_WRITE_TESTS=1 OVID_LIVE_PROVIDER_ACME=1 vitest run test/liveProvider.test.ts",
        operationId: "send_message",
        evidence: "sanitized-result: disposable message created",
      })],
    })).toThrow(/disposable|cleanup/i);
  });

  it("requires separate write evidence for every advertised non-read operation", () => {
    const write = operation({
      name: "send_message",
      effect: "external_communication",
      approval: "per_action",
      request: { originKey: "acme", method: "POST", pathTemplate: "/v1/messages" },
    });
    const def = definition({ operations: [operation(), write] });
    const withoutWrite = row({
      operations: [operation(), write],
      effects: {
        get_current_user: { effect: "read", approval: "mode" },
        send_message: { effect: "external_communication", approval: "per_action" },
      },
    });
    expect(() => createProviderRegistry().registerProvider(def, withoutWrite)).toThrow(/write evidence/i);

    const withWrite = row({
      operations: [operation(), write],
      effects: withoutWrite.effects,
      liveWriteEvidence: [live({
        command: "OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_WRITE_TESTS=1 OVID_LIVE_PROVIDER_ACME=1 OVID_LIVE_PROVIDER_ACME_DISPOSABLE_RESOURCE=declared vitest run test/liveProvider.test.ts",
        operationId: "send_message",
        evidence: "sanitized-result: disposable message created and cleanup verified",
      })],
    });
    const registry = createProviderRegistry({ now: () => new Date("2026-10-24T13:00:00.000Z") });
    expect(() => registry.registerProvider(def, withWrite)).not.toThrow();
  });
});
