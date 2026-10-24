import { describe, expect, it } from "vitest";
import {
  authorizeProviderOperation,
  assertClosedProviderSchema,
  normalizeConnectionConfig,
  validateProviderArgs,
  validateProviderDefinition,
  type ProviderApproval,
  type ProviderDefinition,
  type ProviderOperation,
  type ToolContext,
} from "./types.js";

const INPUT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  maxProperties: 2,
  properties: {
    id: { type: "string", minLength: 1, maxLength: 32 },
    labels: {
      type: "array",
      maxItems: 2,
      items: { type: "string", maxLength: 8 },
    },
  },
  required: ["id"],
} as const;

function operation(patch: Partial<ProviderOperation> = {}): ProviderOperation {
  return {
    name: "send_message",
    description: "Send one message.",
    effect: "external_communication",
    approval: "per_action",
    requiredScopes: ["messages:write"],
    inputSchema: INPUT_SCHEMA,
    outputPolicy: { kind: "redacted_json", maxBytes: 1_024 },
    request: { originKey: "comms", method: "POST", pathTemplate: "/messages" },
    limits: { timeoutMs: 1_000, responseBytes: 1_024, frameBytes: 1_024, pageBytes: 1_024 },
    ...patch,
  };
}

function definition(): ProviderDefinition {
  return {
    providerId: "comms",
    catalogVersion: "1",
    displayName: "Comms",
    description: "Typed communications provider.",
    officialDocs: [{ url: "https://docs.example/api", verifiedAt: "2026-10-24" }],
    authProfileId: "comms-bot",
    connectionSchema: {
      type: "object",
      additionalProperties: false,
      maxProperties: 1,
      properties: { token: { type: "string", minLength: 1, maxLength: 128 } },
      required: ["token"],
    },
    operations: [operation()],
    readiness: "supported",
  };
}

function context(
  approve?: (approval: ProviderApproval) => Promise<{
    decision: "allow" | "deny" | "always";
    approval?: ProviderApproval;
  }>,
): ToolContext {
  return {
    sessionId: "session-1",
    runId: "run-1",
    userId: "user-1",
    connectionId: "connection-1",
    providerId: "comms",
    mode: "auto",
    planMode: false,
    unattended: false,
    isSubagent: false,
    depth: 0,
    callKey: "call-1",
    signal: new AbortController().signal,
    now: () => new Date("2026-10-24T00:00:00.000Z"),
    approveProvider: approve ?? (async () => ({ decision: "deny" })),
  };
}

describe("closed provider schemas", () => {
  it("accepts a spec-shaped definition with recursively closed and bounded schemas", () => {
    expect(() => validateProviderDefinition(definition())).not.toThrow();
    expect(normalizeConnectionConfig(definition().connectionSchema, { token: " secret " })).toEqual({
      token: "secret",
    });
  });

  it("rejects open, unbounded, or unsupported schemas recursively", () => {
    const invalid: Array<{ name: string; schema: Record<string, unknown> }> = [
      {
        name: "open nested object",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: { nested: { type: "object", properties: {} } },
        },
      },
      {
        name: "unbounded string",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: { value: { type: "string" } },
        },
      },
      {
        name: "unbounded array",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: { value: { type: "array", items: { type: "string", maxLength: 4 } } },
        },
      },
      {
        name: "unsupported reference",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: { value: { $ref: "#/definitions/value" } },
        },
      },
    ];
    for (const { name, schema } of invalid) {
      expect(() => assertClosedProviderSchema(schema), name).toThrow(/schema/i);
    }
  });

  it("rejects unknown, wrong-type, missing, and oversized operation arguments", () => {
    for (const args of [
      { id: "ok", extra: true },
      { id: 7 },
      {},
      { id: "x".repeat(33) },
      { id: "ok", labels: ["a", "b", "c"] },
      { id: "ok", labels: ["too-long-value"] },
    ]) {
      expect(validateProviderArgs(INPUT_SCHEMA, args).ok).toBe(false);
    }
    expect(validateProviderArgs(INPUT_SCHEMA, { id: "ok", labels: ["a"] })).toEqual({ ok: true });
  });

  it("rejects inherited Object prototype names as properties and required fields", () => {
    for (const name of ["constructor", "toString", "__proto__"]) {
      const args = JSON.parse(`{"id":"ok","${name}":"polluted"}`) as Record<string, unknown>;
      expect(validateProviderArgs(INPUT_SCHEMA, args).ok, name).toBe(false);
      expect(
        () => assertClosedProviderSchema({ ...INPUT_SCHEMA, required: [name] }),
        name,
      ).toThrow(/schema/i);
    }
  });

  it("rejects connection values that are not declared by connectionSchema", () => {
    expect(() => normalizeConnectionConfig(definition().connectionSchema, { token: "t", host: "evil" })).toThrow(
      /connection config/i,
    );
  });

  it("rejects unsupported methods and high-risk metadata downgrades", () => {
    expect(() =>
      validateProviderDefinition({
        ...definition(),
        operations: [operation({ request: { originKey: "comms", method: "CONNECT" as "POST", pathTemplate: "/" } })],
      }),
    ).toThrow(/method/i);
    expect(() =>
      validateProviderDefinition({ ...definition(), operations: [operation({ approval: "mode" })] }),
    ).toThrow(/approval/i);
  });
});

describe("authorizeProviderOperation", () => {
  const args = { id: "target-1" };

  it("requires per-action approval for high-risk effects even in Full Access/drive mode", async () => {
    let prompts = 0;
    const fullAccess = context(async (approval) => {
      prompts++;
      expect(approval.connectionId).toBe("connection-1");
      expect(approval.providerId).toBe("comms");
      expect(approval.operationId).toBe("send_message");
      expect(approval.argsDigest).toMatch(/^[a-f0-9]{64}$/);
      expect(approval.safeTargetSummary).not.toContain("target-1");
      expect(approval.expiresAt).toBe("2026-10-24T00:02:00.000Z");
      return { decision: "allow", approval };
    });
    fullAccess.mode = "drive";
    const result = await authorizeProviderOperation(fullAccess, operation(), args);
    expect(result.kind).toBe("allow");
    expect(prompts).toBe(1);
    if (result.kind === "allow") expect(result.approval?.operationId).toBe("send_message");
  });

  it("rejects every changed per-action binding and an always grant", async () => {
    const mutations: Array<(approval: ProviderApproval) => void> = [
      (a) => { a.connectionId = "other-connection"; },
      (a) => { a.providerId = "other-provider"; },
      (a) => { a.operationId = "other-operation"; },
      (a) => { a.argsDigest = "0".repeat(64); },
      (a) => { a.runId = "other-run"; },
      (a) => { a.userId = "other-user"; },
      (a) => { a.expiresAt = "2027-01-01T00:00:00.000Z"; },
      (a) => { a.safeTargetSummary = "attacker-controlled target"; },
    ];
    for (const mutate of mutations) {
      const result = await authorizeProviderOperation(
        context(async (approval) => {
          const changed = { ...approval };
          mutate(changed);
          return { decision: "allow", approval: changed };
        }),
        operation(),
        args,
      );
      expect(result).toEqual({ kind: "deny", code: "approval_binding_mismatch" });
    }
    expect(
      await authorizeProviderOperation(
        context(async (approval) => ({ decision: "always", approval })),
        operation(),
        args,
      ),
    ).toEqual({ kind: "deny", code: "approval_required" });
  });

  it("uses one deep immutable args snapshot for validation and approval binding", async () => {
    const mutable = { id: "target-1", labels: ["original"] };
    let originalDigest = "";
    const result = await authorizeProviderOperation(
      context(async (approval) => {
        originalDigest = approval.argsDigest;
        mutable.id = "changed-target";
        mutable.labels[0] = "changed";
        mutable.labels.push("also-changed");
        return { decision: "allow", approval };
      }),
      operation(),
      mutable,
    );
    expect(mutable).toEqual({ id: "changed-target", labels: ["changed", "also-changed"] });
    expect(result.kind).toBe("allow");
    if (result.kind === "allow") expect(result.approval?.argsDigest).toBe(originalDigest);
  });

  it("denies high-risk operations in plan/unattended runs without prompting", async () => {
    for (const patch of [{ planMode: true }, { unattended: true }]) {
      let prompts = 0;
      const ctx = context(async () => {
        prompts++;
        return { decision: "deny" };
      });
      Object.assign(ctx, patch);
      const result = await authorizeProviderOperation(ctx, operation(), args);
      expect(result.kind).toBe("deny");
      expect(prompts).toBe(0);
    }
  });

  it("default-denies unknown custom operations in plan and unattended runs", async () => {
    for (const patch of [{ planMode: true }, { unattended: true }]) {
      const ctx = context();
      Object.assign(ctx, patch);
      const result = await authorizeProviderOperation(
        ctx,
        operation({ effect: "read", approval: "mode", custom: true }),
        args,
      );
      expect(result).toEqual({ kind: "deny", code: "custom_operation_denied" });
    }
  });

  it("allows a known read in plan mode and a mode-gated write in auto without a prompt", async () => {
    expect(
      await authorizeProviderOperation(
        context(),
        operation({ effect: "read", approval: "mode" }),
        args,
      ),
    ).toEqual({ kind: "allow" });
    const planCtx = context();
    planCtx.planMode = true;
    expect(
      await authorizeProviderOperation(planCtx, operation({ effect: "read", approval: "mode" }), args),
    ).toEqual({ kind: "allow" });
    expect(
      await authorizeProviderOperation(context(), operation({ effect: "write", approval: "mode" }), args),
    ).toEqual({ kind: "allow" });
  });

  it("validates arguments before invoking the approval transport", async () => {
    let prompts = 0;
    const result = await authorizeProviderOperation(
      context(async () => {
        prompts++;
        return { decision: "deny" };
      }),
      operation(),
      { id: "ok", baseUrl: "https://evil.example" },
    );
    expect(result).toEqual({ kind: "deny", code: "invalid_arguments" });
    expect(prompts).toBe(0);
  });
});
