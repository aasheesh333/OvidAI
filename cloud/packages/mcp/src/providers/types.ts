import { createHash } from "node:crypto";

export type Effect =
  | "read"
  | "write"
  | "external_communication"
  | "financial"
  | "deployment"
  | "destructive"
  | "credential_use";

export type ApprovalPolicy = "mode" | "per_action" | "unattended_deny";

export type ProviderOutputPolicy = {
  kind: "redacted_text" | "redacted_json" | "status_only" | "binary_metadata";
  maxBytes: number;
};

export interface ProviderOperation {
  name: string;
  description: string;
  effect: Effect;
  approval: ApprovalPolicy;
  requiredScopes: readonly string[];
  inputSchema: Record<string, unknown>;
  outputPolicy: ProviderOutputPolicy;
  request: {
    originKey: string;
    method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD";
    pathTemplate: string;
  };
  limits: {
    timeoutMs: number;
    responseBytes: number;
    frameBytes: number;
    pageBytes: number;
  };
  custom?: boolean;
}

export interface ProviderDefinition {
  providerId: string;
  catalogVersion: string;
  displayName: string;
  description: string;
  officialDocs: readonly { url: string; verifiedAt: string }[];
  authProfileId: string;
  connectionSchema: Record<string, unknown>;
  operations: readonly ProviderOperation[];
  readiness: "supported";
}

export interface RunPolicy {
  mode: "safe" | "auto" | "drive" | "studio";
  planMode: boolean;
  unattended: boolean;
}

export interface ProviderApproval {
  connectionId: string;
  providerId: string;
  operationId: string;
  argsDigest: string;
  safeTargetSummary: string;
  runId: string;
  userId: string;
  expiresAt: string;
}

export interface ToolContext extends RunPolicy {
  sessionId: string;
  runId: string;
  userId: string;
  connectionId: string;
  providerId: string;
  isSubagent: boolean;
  depth: number;
  callKey: string;
  signal: AbortSignal;
  now?: () => Date;
  approveProvider?: (approval: ProviderApproval) => Promise<{
    decision: "allow" | "deny" | "always";
    approval?: ProviderApproval;
  }>;
}

export type ProviderAuthorization =
  | { kind: "allow"; approval?: ProviderApproval }
  | { kind: "deny"; code: string };

const SCHEMA_ANNOTATIONS = new Set(["description", "title", "default", "examples"]);
const SCHEMA_KEYS = new Set([
  ...SCHEMA_ANNOTATIONS,
  "type",
  "properties",
  "required",
  "additionalProperties",
  "maxProperties",
  "minProperties",
  "items",
  "maxItems",
  "minItems",
  "minLength",
  "maxLength",
  "minimum",
  "maximum",
  "exclusiveMinimum",
  "exclusiveMaximum",
  "enum",
  "const",
]);
const TYPES = new Set(["object", "array", "string", "number", "integer", "boolean", "null"]);
const METHODS = new Set(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]);
const EFFECTS = new Set<Effect>([
  "read",
  "write",
  "external_communication",
  "financial",
  "deployment",
  "destructive",
  "credential_use",
]);
const APPROVALS = new Set<ApprovalPolicy>(["mode", "per_action", "unattended_deny"]);
const HIGH_RISK = new Set<Effect>(["external_communication", "financial", "deployment", "destructive"]);
const MAX_SCHEMA_DEPTH = 16;

function isRecord(value: unknown): value is Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value) as object | null;
  return prototype === Object.prototype || prototype === null;
}

function hasOwn(value: object, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function boundedInteger(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;
}

function jsonBytes(value: unknown): number {
  try {
    return Buffer.byteLength(JSON.stringify(value) ?? "", "utf8");
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

function schemaError(): Error {
  return new Error("Invalid closed provider schema.");
}

function assertSchemaNode(schema: unknown, path: string, depth: number, root: boolean): void {
  if (!isRecord(schema) || depth > MAX_SCHEMA_DEPTH) throw schemaError();
  for (const key of Object.keys(schema)) {
    if (!SCHEMA_KEYS.has(key)) throw schemaError();
  }
  const type = schema.type;
  if (type !== undefined && (typeof type !== "string" || !TYPES.has(type))) throw schemaError();
  if (root && type !== "object") throw schemaError();
  if (type === undefined && schema.enum === undefined && schema.const === undefined) throw schemaError();

  if (type === "object") {
    if (schema.additionalProperties !== false) throw schemaError();
    if (!boundedInteger(schema.maxProperties, 0, 256)) throw schemaError();
    if (schema.minProperties !== undefined &&
        (!boundedInteger(schema.minProperties, 0, 256) || schema.minProperties > schema.maxProperties)) {
      throw schemaError();
    }
    if (schema.properties !== undefined && !isRecord(schema.properties)) throw schemaError();
    const properties = (schema.properties ?? {}) as Record<string, unknown>;
    const entries = Object.entries(properties);
    if (entries.length > schema.maxProperties) throw schemaError();
    for (const [key, child] of entries) {
      if (key.length === 0 || key.length > 128) throw schemaError();
      assertSchemaNode(child, `${path}.${key}`, depth + 1, false);
    }
    if (schema.required !== undefined) {
      if (!Array.isArray(schema.required) || schema.required.length > entries.length) throw schemaError();
      const required = new Set<string>();
      for (const key of schema.required) {
        if (typeof key !== "string" || !hasOwn(properties, key) || required.has(key)) throw schemaError();
        required.add(key);
      }
    }
  } else if (schema.properties !== undefined || schema.required !== undefined || schema.additionalProperties !== undefined) {
    throw schemaError();
  }

  if (type === "array") {
    if (!boundedInteger(schema.maxItems, 0, 1_000) || schema.items === undefined) throw schemaError();
    if (schema.minItems !== undefined &&
        (!boundedInteger(schema.minItems, 0, 1_000) || schema.minItems > schema.maxItems)) {
      throw schemaError();
    }
    assertSchemaNode(schema.items, `${path}[]`, depth + 1, false);
  } else if (schema.items !== undefined || schema.maxItems !== undefined || schema.minItems !== undefined) {
    throw schemaError();
  }

  if (type === "string") {
    if (!boundedInteger(schema.maxLength, 0, 1_000_000)) throw schemaError();
    if (schema.minLength !== undefined &&
        (!boundedInteger(schema.minLength, 0, 1_000_000) || schema.minLength > schema.maxLength)) {
      throw schemaError();
    }
  } else if (schema.maxLength !== undefined || schema.minLength !== undefined) {
    throw schemaError();
  }

  if (type === "number" || type === "integer") {
    if (typeof schema.minimum !== "number" || !Number.isFinite(schema.minimum) ||
        typeof schema.maximum !== "number" || !Number.isFinite(schema.maximum) ||
        schema.minimum > schema.maximum) {
      throw schemaError();
    }
    if (schema.exclusiveMinimum !== undefined &&
        (typeof schema.exclusiveMinimum !== "number" || !Number.isFinite(schema.exclusiveMinimum))) {
      throw schemaError();
    }
    if (schema.exclusiveMaximum !== undefined &&
        (typeof schema.exclusiveMaximum !== "number" || !Number.isFinite(schema.exclusiveMaximum))) {
      throw schemaError();
    }
  } else if (["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"].some((key) => hasOwn(schema, key))) {
    throw schemaError();
  }

  if (schema.enum !== undefined) {
    if (!Array.isArray(schema.enum) || schema.enum.length === 0 || schema.enum.length > 128 || jsonBytes(schema.enum) > 16_384) {
      throw schemaError();
    }
  }
  if (hasOwn(schema, "const") && jsonBytes(schema.const) > 16_384) throw schemaError();
  if (hasOwn(schema, "default") && !valueMatches(schema.default, schema)) throw schemaError();
}

export function assertClosedProviderSchema(schema: Record<string, unknown>): void {
  assertSchemaNode(schema, "$", 0, true);
}

function canonical(value: unknown): string {
  if (value === null || typeof value === "string" || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("Invalid JSON number.");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (isRecord(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  }
  throw new Error("Invalid JSON value.");
}

const MAX_SNAPSHOT_DEPTH = 32;
const MAX_SNAPSHOT_NODES = 10_000;

/** Clone JSON-shaped model input once and freeze every object/array recursively. */
export function snapshotProviderArgs(args: Record<string, unknown>): Record<string, unknown> {
  const visiting = new WeakSet<object>();
  let nodes = 0;

  const clone = (value: unknown, depth: number): unknown => {
    if (value === null || typeof value === "string" || typeof value === "boolean") return value;
    if (typeof value === "number") {
      if (Number.isFinite(value)) return value;
      throw new Error("Invalid JSON number.");
    }
    if (typeof value !== "object") throw new Error("Invalid JSON value.");
    if (depth > MAX_SNAPSHOT_DEPTH || ++nodes > MAX_SNAPSHOT_NODES || visiting.has(value)) {
      throw new Error("Invalid or cyclic operation arguments.");
    }
    visiting.add(value);
    try {
      if (Array.isArray(value)) {
        if (value.length > MAX_SNAPSHOT_NODES) throw new Error("Operation array is too large.");
        const output: unknown[] = [];
        for (let index = 0; index < value.length; index++) {
          if (!hasOwn(value, String(index))) throw new Error("Sparse operation arrays are invalid.");
          const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
          if (descriptor === undefined || !("value" in descriptor)) {
            throw new Error("Operation accessors are invalid.");
          }
          output.push(clone(descriptor.value, depth + 1));
        }
        return Object.freeze(output);
      }
      if (!isRecord(value)) throw new Error("Invalid operation object.");
      const output: Record<string, unknown> = {};
      for (const key of Object.keys(value)) {
        const descriptor = Object.getOwnPropertyDescriptor(value, key);
        if (descriptor === undefined || !descriptor.enumerable || !("value" in descriptor)) {
          throw new Error("Operation accessors are invalid.");
        }
        Object.defineProperty(output, key, {
          value: clone(descriptor.value, depth + 1),
          enumerable: true,
          configurable: false,
          writable: false,
        });
      }
      return Object.freeze(output);
    } finally {
      visiting.delete(value);
    }
  };

  return clone(args, 0) as Record<string, unknown>;
}

function valueMatches(value: unknown, schema: Record<string, unknown>): boolean {
  if (hasOwn(schema, "const") && canonical(value) !== canonical(schema.const)) return false;
  if (Array.isArray(schema.enum) && !schema.enum.some((candidate) => canonical(value) === canonical(candidate))) {
    return false;
  }
  const type = schema.type;
  if (type === undefined) return true;
  if (type === "null") return value === null;
  if (type === "boolean") return typeof value === "boolean";
  if (type === "string") {
    if (typeof value !== "string") return false;
    const length = [...value].length;
    return length >= (schema.minLength as number | undefined ?? 0) && length <= (schema.maxLength as number);
  }
  if (type === "number" || type === "integer") {
    if (typeof value !== "number" || !Number.isFinite(value) || (type === "integer" && !Number.isInteger(value))) {
      return false;
    }
    return value >= (schema.minimum as number) && value <= (schema.maximum as number) &&
      (schema.exclusiveMinimum === undefined || value > (schema.exclusiveMinimum as number)) &&
      (schema.exclusiveMaximum === undefined || value < (schema.exclusiveMaximum as number));
  }
  if (type === "array") {
    if (!Array.isArray(value) || value.length > (schema.maxItems as number) ||
        value.length < (schema.minItems as number | undefined ?? 0)) {
      return false;
    }
    return value.every((entry) => valueMatches(entry, schema.items as Record<string, unknown>));
  }
  if (type === "object") {
    if (!isRecord(value)) return false;
    const keys = Object.keys(value);
    if (keys.length > (schema.maxProperties as number) || keys.length < (schema.minProperties as number | undefined ?? 0)) {
      return false;
    }
    const properties = (schema.properties ?? {}) as Record<string, Record<string, unknown>>;
    for (const key of keys) if (!hasOwn(properties, key)) return false;
    for (const key of (schema.required as string[] | undefined) ?? []) {
      if (!Object.prototype.hasOwnProperty.call(value, key) || value[key] === undefined) return false;
    }
    return Object.entries(value).every(([key, entry]) => valueMatches(entry, properties[key]));
  }
  return false;
}

export function validateProviderArgs(
  schema: Record<string, unknown>,
  args: Record<string, unknown>,
): { ok: boolean; code?: string } {
  try {
    assertClosedProviderSchema(schema);
    return valueMatches(args, schema) ? { ok: true } : { ok: false, code: "invalid_arguments" };
  } catch {
    return { ok: false, code: "invalid_arguments" };
  }
}

export function normalizeConnectionConfig(
  schema: Record<string, unknown>,
  config: Record<string, unknown>,
): Record<string, string> {
  try {
    if (!isRecord(config) || Object.values(config).some((value) => typeof value !== "string")) {
      throw new Error("not flat");
    }
    const trimmed = Object.fromEntries(Object.entries(config).map(([key, value]) => [key, (value as string).trim()]));
    assertClosedProviderSchema(schema);
    if (!valueMatches(trimmed, schema)) throw new Error("mismatch");
    return trimmed;
  } catch {
    throw new Error("Invalid connection config.");
  }
}

function nonEmptyString(value: unknown, max = 512): value is string {
  return typeof value === "string" && value.trim() !== "" && value.length <= max;
}

export function validateProviderDefinition(definition: ProviderDefinition): void {
  if (!nonEmptyString(definition.providerId, 128) || !nonEmptyString(definition.catalogVersion, 64) ||
      !nonEmptyString(definition.displayName, 256) || !nonEmptyString(definition.description, 2_048) ||
      !nonEmptyString(definition.authProfileId, 128) || definition.readiness !== "supported" ||
      !Array.isArray(definition.officialDocs) || definition.officialDocs.length === 0 ||
      !Array.isArray(definition.operations) || definition.operations.length === 0) {
    throw new Error("Invalid provider definition metadata.");
  }
  for (const doc of definition.officialDocs) {
    let url: URL;
    try {
      url = new URL(doc.url);
    } catch {
      throw new Error("Invalid provider officialDocs URL.");
    }
    if (url.protocol !== "https:" || url.username !== "" || url.password !== "" ||
        !/^\d{4}-\d{2}-\d{2}$/.test(doc.verifiedAt) || Number.isNaN(Date.parse(doc.verifiedAt))) {
      throw new Error("Invalid provider officialDocs metadata.");
    }
  }
  assertClosedProviderSchema(definition.connectionSchema);
  const names = new Set<string>();
  for (const operation of definition.operations) {
    if (!nonEmptyString(operation.name, 128) || names.has(operation.name) ||
        !nonEmptyString(operation.description, 2_048) || !EFFECTS.has(operation.effect) ||
        !APPROVALS.has(operation.approval) || !METHODS.has(operation.request?.method) ||
        !nonEmptyString(operation.request?.originKey, 128) ||
        typeof operation.request?.pathTemplate !== "string" || operation.request.pathTemplate.length > 2_048 ||
        (operation.request.pathTemplate !== "" && !operation.request.pathTemplate.startsWith("/"))) {
      throw new Error("Invalid provider operation method or metadata.");
    }
    names.add(operation.name);
    if ((HIGH_RISK.has(operation.effect) || operation.effect === "credential_use") && operation.approval !== "per_action") {
      throw new Error("Invalid high-risk provider approval policy.");
    }
    assertClosedProviderSchema(operation.inputSchema);
    if (!Array.isArray(operation.requiredScopes) || operation.requiredScopes.some((scope: string) => !nonEmptyString(scope, 256))) {
      throw new Error("Invalid provider operation scopes.");
    }
    const { timeoutMs, responseBytes, frameBytes, pageBytes } = operation.limits ?? {};
    if (!boundedInteger(timeoutMs, 1, 300_000) || !boundedInteger(responseBytes, 1, 16_777_216) ||
        !boundedInteger(frameBytes, 1, 16_777_216) || !boundedInteger(pageBytes, 1, 16_777_216)) {
      throw new Error("Invalid provider operation limits.");
    }
    if (!["redacted_text", "redacted_json", "status_only", "binary_metadata"].includes(operation.outputPolicy?.kind) ||
        !boundedInteger(operation.outputPolicy?.maxBytes, 1, responseBytes)) {
      throw new Error("Invalid provider output policy.");
    }
  }
}

function digest(args: Record<string, unknown>): string {
  return createHash("sha256").update(canonical(args)).digest("hex");
}

function sameApproval(a: ProviderApproval, b: ProviderApproval): boolean {
  return a.connectionId === b.connectionId && a.providerId === b.providerId &&
    a.operationId === b.operationId && a.argsDigest === b.argsDigest &&
    a.safeTargetSummary === b.safeTargetSummary && a.runId === b.runId &&
    a.userId === b.userId && a.expiresAt === b.expiresAt;
}

export async function authorizeProviderOperation(
  ctx: ToolContext & RunPolicy,
  operation: ProviderOperation,
  args: Record<string, unknown>,
): Promise<ProviderAuthorization> {
  let operationArgs: Record<string, unknown>;
  try {
    operationArgs = snapshotProviderArgs(args);
  } catch {
    return { kind: "deny", code: "invalid_arguments" };
  }
  if (!EFFECTS.has(operation.effect) || !APPROVALS.has(operation.approval) || !METHODS.has(operation.request?.method)) {
    return { kind: "deny", code: "invalid_operation" };
  }
  if ((HIGH_RISK.has(operation.effect) || operation.effect === "credential_use") && operation.approval !== "per_action") {
    return { kind: "deny", code: "invalid_operation" };
  }
  if (!validateProviderArgs(operation.inputSchema, operationArgs).ok) {
    return { kind: "deny", code: "invalid_arguments" };
  }
  if (ctx.signal.aborted) return { kind: "deny", code: "cancelled" };
  if (operation.custom === true && (ctx.planMode || ctx.unattended)) {
    return { kind: "deny", code: "custom_operation_denied" };
  }
  if (HIGH_RISK.has(operation.effect) && (ctx.planMode || ctx.unattended)) {
    return { kind: "deny", code: "high_risk_denied" };
  }
  if (ctx.planMode && operation.effect !== "read") return { kind: "deny", code: "plan_mode_denied" };
  if (ctx.unattended && (operation.approval !== "mode" || operation.effect === "credential_use")) {
    return { kind: "deny", code: "unattended_denied" };
  }

  const needsApproval = operation.approval === "per_action" || (ctx.mode === "safe" && operation.effect !== "read");
  if (!needsApproval) return { kind: "allow" };
  if (ctx.approveProvider === undefined || !nonEmptyString(ctx.connectionId, 256) ||
      !nonEmptyString(ctx.providerId, 128) || !nonEmptyString(ctx.runId, 256) || !nonEmptyString(ctx.userId, 256)) {
    return { kind: "deny", code: "approval_required" };
  }

  let argsDigest: string;
  try {
    argsDigest = digest(operationArgs);
  } catch {
    return { kind: "deny", code: "invalid_arguments" };
  }
  const now = ctx.now?.() ?? new Date();
  if (Number.isNaN(now.valueOf())) return { kind: "deny", code: "approval_unavailable" };
  const approval: ProviderApproval = Object.freeze({
    connectionId: ctx.connectionId,
    providerId: ctx.providerId,
    operationId: operation.name,
    argsDigest,
    safeTargetSummary: `${operation.request.method} ${operation.request.originKey}${operation.request.pathTemplate}`.slice(0, 512),
    runId: ctx.runId,
    userId: ctx.userId,
    expiresAt: new Date(now.valueOf() + 120_000).toISOString(),
  });

  try {
    const decision = await ctx.approveProvider(approval);
    if (decision.decision !== "allow") return { kind: "deny", code: "approval_required" };
    if (decision.approval === undefined || !sameApproval(approval, decision.approval) || digest(operationArgs) !== argsDigest) {
      return { kind: "deny", code: "approval_binding_mismatch" };
    }
    const after = ctx.now?.() ?? new Date();
    if (ctx.signal.aborted) return { kind: "deny", code: "cancelled" };
    if (after.valueOf() > Date.parse(approval.expiresAt)) return { kind: "deny", code: "approval_expired" };
    return { kind: "allow", approval: decision.approval };
  } catch {
    return { kind: "deny", code: "approval_unavailable" };
  }
}
