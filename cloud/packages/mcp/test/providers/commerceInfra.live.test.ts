import { describe, expect, it } from "vitest";

import type { McpCallContext } from "../../src/transports/native.js";
import {
  COMMERCE_INFRA_DESCRIPTORS,
  COMMERCE_INFRA_PROVIDERS,
  createCommerceInfraHandler,
} from "../../src/rest/descriptors/commerceInfra.js";

const GLOBAL_OPT_IN = "OVID_LIVE_PROVIDER_TESTS";
const envName = (providerId: string, key: string) =>
  `OVID_${providerId}_${key}`.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
const optInName = (providerId: string) => envName("LIVE", providerId);

function parseArg(value: string, schema: Record<string, unknown>): unknown {
  if (schema.type === "integer" || schema.type === "number") return Number(value);
  if (schema.type === "boolean") return value === "true";
  return value;
}

/**
 * No test is skipped. With live testing enabled, every contract-supported row
 * must be explicitly selected and produce a real bounded read or a hard
 * not-provided/failed outcome. No write opt-in can enable anything here.
 */
describe("commerceInfra actual provider reads", () => {
  for (const definition of COMMERCE_INFRA_PROVIDERS) {
    const descriptor = COMMERCE_INFRA_DESCRIPTORS.find((entry) => entry.curatedId === definition.providerId);
    const operation = definition.operations[0];
    it(`${definition.providerId}/${operation.name}: actual evidence or blocking not-provided outcome`, async () => {
      const optIn = optInName(definition.providerId);
      if (process.env[GLOBAL_OPT_IN] !== "1") {
        console.log(JSON.stringify({ providerId: definition.providerId, operationId: operation.name, outcome: "not provided", missing: [`${GLOBAL_OPT_IN}=1`] }));
        expect(process.env[GLOBAL_OPT_IN]).not.toBe("1");
        return;
      }
      if (process.env[optIn] !== "1") {
        console.log(JSON.stringify({ providerId: definition.providerId, operationId: operation.name, outcome: "not provided", missing: [`${optIn}=1`] }));
        throw new Error(`not provided: ${optIn}=1`);
      }
      expect(operation.effect).toBe("read");
      expect(descriptor).toBeDefined();

      const requiredConfig = new Set<string>([
        ...(descriptor!.credentialKey === "" ? [] : [descriptor!.credentialKey]),
        ...(((descriptor!.connectionSchema?.required ?? []) as string[])),
        ...(descriptor!.auth === "basic" ? [descriptor!.authParam ?? "username"] : []),
      ]);
      const config: Record<string, string> = {};
      const missing: string[] = [];
      for (const key of requiredConfig) {
        const name = envName(definition.providerId, key);
        const value = process.env[name];
        if (value === undefined || value.trim() === "") missing.push(name);
        else config[key] = value;
      }

      const args: Record<string, unknown> = {};
      const properties = (operation.inputSchema.properties ?? {}) as Record<string, Record<string, unknown>>;
      for (const key of (operation.inputSchema.required ?? []) as string[]) {
        if (key === "timeout_seconds") continue;
        if (definition.providerId === "newrelic" && key === "account_id" && config.account_id !== undefined) {
          args[key] = Number(config.account_id);
          continue;
        }
        const name = envName(definition.providerId, `ARG_${key}`);
        const value = process.env[name];
        if (value === undefined || value.trim() === "") missing.push(name);
        else args[key] = parseArg(value, properties[key] ?? {});
      }
      if (missing.length > 0) {
        console.log(JSON.stringify({ providerId: definition.providerId, operationId: operation.name, outcome: "not provided", missing }));
        throw new Error(`not provided: ${missing.join(", ")}`);
      }

      const ctx: McpCallContext = {
        uid: "explicit-live-provider-test",
        secrets: config,
        workspace: {},
        fetchImpl: async () => { throw new Error("legacy fetch is forbidden in live provider tests"); },
      };
      const result = await createCommerceInfraHandler(definition.providerId).callTool(operation.name, args, ctx);
      if (result.isError) {
        console.log(JSON.stringify({ providerId: definition.providerId, operationId: operation.name, outcome: "failed", result: result.text }));
      } else {
        const parsed = JSON.parse(result.text) as unknown;
        expect(parsed).not.toBeNull();
        console.log(JSON.stringify({
          providerId: definition.providerId,
          operationId: operation.name,
          outcome: "passed",
          resultBytes: Buffer.byteLength(result.text, "utf8"),
          evidence: "real bounded redacted JSON response; body deliberately not logged",
        }));
      }
      expect(result.isError).toBe(false);
    });
  }
});
