import { describe, expect, it } from "vitest";
import {
  liveProviderOptIn,
  ORIGINAL_PROVIDER_DEFINITIONS,
  ORIGINAL_PROVIDER_REGISTRY,
  ORIGINAL_READINESS_ROWS,
} from "./providerEvidence.js";

describe("original provider evidence", () => {
  it("contains the twenty original identities without claiming live support", () => {
    expect(ORIGINAL_READINESS_ROWS.map((row) => row.providerId)).toEqual([
      "github", "filesystem", "fetch", "memory", "gitlab", "jira", "linear", "figma",
      "sentry", "exa", "notion", "google-drive", "airtable", "supabase", "firebase",
      "mongodb", "s3", "slack", "discord", "telegram",
    ]);
    expect(ORIGINAL_PROVIDER_DEFINITIONS).toHaveLength(20);
    expect(ORIGINAL_READINESS_ROWS.filter((row) => row.releaseState === "supported")).toHaveLength(0);
    expect(ORIGINAL_READINESS_ROWS.filter((row) => row.releaseState === "blocked")).toHaveLength(19);
    expect(ORIGINAL_READINESS_ROWS.filter((row) => row.releaseState === "deprecated").map((row) => row.providerId)).toEqual(["mongodb"]);
    expect(ORIGINAL_PROVIDER_REGISTRY.catalogDefinitions()).toEqual([]);
    for (const row of ORIGINAL_READINESS_ROWS) {
      expect(row.credentials).toBe("not provided");
      expect(row.liveReadEvidence).toBeNull();
      expect(row.liveWriteEvidence).toEqual([]);
      expect(row.officialDocs.length).toBeGreaterThan(0);
      expect(row.catalogOwner).toBe("connectors-originals");
      expect(row.automatedEvidence.test).toBe("test/providers/originals.contract.test.ts");
      if (row.automatedEvidence.result === "passed") expect(row.automatedEvidence.runAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    }
  });

  it("admits genuine typed native fetch while keeping its real readiness row blocked", () => {
    const registration = ORIGINAL_PROVIDER_REGISTRY.get("fetch");
    expect(registration).toBeDefined();
    expect(registration?.definition.operations).toHaveLength(1);
    expect(registration?.definition.operations[0]).toMatchObject({
      name: "fetch",
      effect: "read",
      request: { originKey: "public-web", method: "GET", pathTemplate: "/{url}" },
      inputSchema: { required: ["url"], additionalProperties: false },
    });
    expect(registration?.row).toMatchObject({
      releaseState: "blocked",
      credentials: "not provided",
      liveReadEvidence: null,
    });
    expect(ORIGINAL_PROVIDER_REGISTRY.catalogDefinitions()).toEqual([]);
  });

  it("keeps each definition connection schema aligned with its actual credential/config boundary", () => {
    const definitions = new Map(ORIGINAL_PROVIDER_DEFINITIONS.map((definition) => [definition.providerId, definition]));
    const properties = (id: string): Record<string, unknown> =>
      (definitions.get(id)?.connectionSchema.properties ?? {}) as Record<string, unknown>;
    expect(properties("github")).toHaveProperty("GITHUB_TOKEN");
    expect(properties("linear")).toHaveProperty("personal_api_key");
    expect(properties("linear")).toHaveProperty("oauth_access_token");
    expect(properties("firebase")).toHaveProperty("access_token");
    expect(properties("firebase")).not.toHaveProperty("api_key");
    expect(properties("supabase")).toHaveProperty("publishable_key");
    expect(properties("supabase")).toHaveProperty("user_jwt");
    expect(properties("supabase")).toHaveProperty("base_url");
    expect(properties("supabase")).toHaveProperty("allowed_tables");
    expect(properties("supabase")).not.toHaveProperty("service_key");
    expect(properties("mongodb")).toEqual({});
  });

  it("pins the reviewed current API versions and read-first operations", () => {
    const byId = new Map(ORIGINAL_READINESS_ROWS.map((row) => [row.providerId, row]));
    expect(byId.get("github")?.officialDocs.some((doc) => doc.apiVersion === "2026-03-10")).toBe(true);
    expect(byId.get("notion")?.officialDocs.some((doc) => doc.apiVersion === "2026-03-11")).toBe(true);
    expect(byId.get("jira")?.officialDocs.some((doc) => doc.apiVersion === "v3 enhanced JQL")).toBe(true);
    expect(byId.get("discord")?.officialDocs.some((doc) => doc.apiVersion === "v10")).toBe(true);
    expect(byId.get("mongodb")?.releaseState).toBe("deprecated");
    for (const row of ORIGINAL_READINESS_ROWS) {
      if (["filesystem", "memory", "mongodb"].includes(row.providerId)) continue;
      expect(row.operations.length, row.providerId).toBeGreaterThan(0);
      expect(row.operations.every((operation) => operation.effect === "read"), row.providerId).toBe(true);
      expect(row.operations.some((operation) => !/^ping$|^health(?:_check)?$/i.test(operation.name)), row.providerId).toBe(true);
    }
  });
});

describe("liveProviderOptIn", () => {
  it("requires both global and provider-specific read opt-ins", () => {
    expect(() => liveProviderOptIn("linear", false, { env: {} })).toThrow(/OVID_LIVE_PROVIDER_TESTS/);
    expect(() => liveProviderOptIn("linear", false, {
      env: { OVID_LIVE_PROVIDER_TESTS: "1" },
    })).toThrow(/OVID_LIVE_PROVIDER_LINEAR/);
    expect(liveProviderOptIn("linear", false, {
      env: { OVID_LIVE_PROVIDER_TESTS: "1", OVID_LIVE_PROVIDER_LINEAR: "1" },
    })).toMatchObject({ providerId: "linear", write: false });
  });

  it("requires the separate write gate and a disposable-resource declaration", () => {
    const readEnv = { OVID_LIVE_PROVIDER_TESTS: "1", OVID_LIVE_PROVIDER_MEMORY: "1" };
    expect(() => liveProviderOptIn("memory", true, { env: readEnv })).toThrow(/OVID_LIVE_PROVIDER_WRITE_TESTS/);
    expect(() => liveProviderOptIn("memory", true, {
      env: { ...readEnv, OVID_LIVE_PROVIDER_WRITE_TESTS: "1" },
    })).toThrow(/DISPOSABLE_RESOURCE/);
    expect(liveProviderOptIn("memory", true, {
      env: {
        ...readEnv,
        OVID_LIVE_PROVIDER_WRITE_TESTS: "1",
        OVID_LIVE_PROVIDER_MEMORY_DISPOSABLE_RESOURCE: "disposable-test-resource",
      },
    })).toMatchObject({ providerId: "memory", write: true });
  });

  it("refuses deprecated providers and writes that are not advertised", () => {
    const env = {
      OVID_LIVE_PROVIDER_TESTS: "1",
      OVID_LIVE_PROVIDER_WRITE_TESTS: "1",
      OVID_LIVE_PROVIDER_MONGODB: "1",
      OVID_LIVE_PROVIDER_LINEAR: "1",
      OVID_LIVE_PROVIDER_LINEAR_DISPOSABLE_RESOURCE: "disposable-resource",
    };
    expect(() => liveProviderOptIn("mongodb", false, { env })).toThrow(/deprecated|unavailable/i);
    expect(() => liveProviderOptIn("linear", true, { env })).toThrow(/write|operation|unavailable/i);
  });
});
