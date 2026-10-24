import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  connectionEnvelopeSchema,
  mcpConnectionDtoSchema,
  providerConnectionStateSchema,
} from "./mcpRest.js";

function fixture(): unknown {
  return JSON.parse(
    readFileSync(new URL("../contracts/fixtures/mcp-connections-v1.json", import.meta.url), "utf8"),
  );
}

describe("MCP connection v1 contracts", () => {
  it("parses the checked-in versioned envelope without secret or config fields", () => {
    const raw = fixture();
    const parsed = connectionEnvelopeSchema.parse(raw);
    expect(parsed).toEqual(raw);
    expect(parsed.contractVersion).toBe(1);
    expect(parsed.items).toHaveLength(2);
    expect(parsed.items[0]).toMatchObject({
      providerId: "google-drive",
      agentEnabled: false,
      authState: "configured",
      healthState: "never_checked",
      configVersion: 1,
      disconnectGeneration: 0,
    });
    expect(parsed.items[1]).toMatchObject({
      approvedSourceId: "source-fixture",
      approvedDigest: "sha256:approved-fixture",
      authState: "revoked",
      healthState: "revoked",
    });
    for (const item of parsed.items) {
      expect(item).not.toHaveProperty("id");
      expect(item).not.toHaveProperty("curatedId");
      expect(item).not.toHaveProperty("config");
      expect(item).not.toHaveProperty("secrets");
      expect(item).not.toHaveProperty("secretsSealed");
      expect(item).not.toHaveProperty("secrets_sealed");
    }
  });

  it("is strict at both DTO and envelope boundaries", () => {
    const raw = fixture() as { items: Record<string, unknown>[] };
    for (const leakedField of ["config", "secrets", "secretsSealed", "secrets_sealed", "id", "curatedId"]) {
      expect(() =>
        mcpConnectionDtoSchema.parse({ ...raw.items[0], [leakedField]: { attack: true } }),
      ).toThrow();
    }
    expect(() =>
      connectionEnvelopeSchema.parse({ contractVersion: 1, items: raw.items, extra: true }),
    ).toThrow();
    expect(() => connectionEnvelopeSchema.parse({ items: raw.items })).toThrow();
    expect(() => connectionEnvelopeSchema.parse({ contractVersion: 2, items: raw.items })).toThrow();
    const { name: _name, transport: _transport, hasSecrets: _hasSecrets, createdAt: _createdAt, updatedAt: _updatedAt, ...state } = raw.items[0];
    expect(providerConnectionStateSchema.parse(state)).toEqual(state);
  });

  it("pins the complete auth and health state vocabularies", () => {
    const raw = fixture() as { items: Record<string, unknown>[] };
    const authStates = ["missing", "configured", "needs_auth", "authorized", "revoked"];
    const healthStates = [
      "never_checked",
      "checking",
      "healthy",
      "degraded",
      "needs_auth",
      "refreshing",
      "revoked",
      "unavailable",
      "disabled",
    ];
    for (const authState of authStates) {
      expect(mcpConnectionDtoSchema.parse({ ...raw.items[0], authState }).authState).toBe(authState);
    }
    for (const healthState of healthStates) {
      expect(mcpConnectionDtoSchema.parse({ ...raw.items[0], healthState }).healthState).toBe(healthState);
    }
    expect(() => mcpConnectionDtoSchema.parse({ ...raw.items[0], authState: "connected" })).toThrow();
    expect(() => mcpConnectionDtoSchema.parse({ ...raw.items[0], healthState: "connected" })).toThrow();
  });
});
