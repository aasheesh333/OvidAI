/**
 * The REST descriptor engine — a port of the Dart app's
 * `lib/core/native_plugins/rest_engine.dart`, part A (declarative
 * descriptors) plus the S3 SigV4 helpers that lived in the same Dart file.
 *
 * Cloud adaptations (same seams the Task 5 native handlers use):
 *  - ALL egress goes through `ctx.fetchImpl` — the per-call SSRF-guarded
 *    fetch — and through `followGuardedRedirects` (redirect:"manual", one
 *    fetchImpl call per hop, max 5), so every Location hop is re-guarded
 *    (T3-review I1). The engine never constructs its own fetch.
 *  - per-request timeout via `AbortSignal.timeout`, applied across the whole
 *    redirect chain (the Dart timer covered the entire in-flight request).
 *  - the Dart engine threw ArgumentError/FormatException up to the JSON-RPC
 *    layer; the cloud handler contract returns `isError` tool results with
 *    the same message text, all passed through trimToolResult.
 *  - stored configuration comes from `ctx.secrets` (decrypted per call,
 *    Task 8/11) instead of NativePluginConfigStore — the engine never
 *    persists or logs a secret value.
 *
 * Documented supersets over the pinned interface (each is required by at
 * least one curated descriptor; without them the Dart special capabilities
 * could not be expressed declaratively):
 *  - `RestToolDef.required` — the Dart field the descriptor data carries.
 *  - `{name=default}` placeholder defaults (GitLab's optional host:
 *    empty config means gitlab.com).
 *  - baseUrl placeholder values are normalized like the Dart routing
 *    capabilities did: a whole-base placeholder (`{base_url}`) gains
 *    `https://` and loses trailing slashes; a host-position placeholder
 *    (`https://{host}/…`) has scheme/path stripped — so both a pasted URL
 *    and a bare hostname route to the same base.
 *  - a missing placeholder that names a declared config field yields the
 *    configure-first message (Jira's required host); anything else is the
 *    Dart "Missing required argument" error.
 *  - path substitutions percent-encode except `/` — multi-segment resource
 *    paths (Firestore documents, S3 keys) stay intact. The Dart engine
 *    encoded slashes and repaired Firebase per-call; the port fixes the
 *    encoder instead.
 *  - `staticHeaders` — verbatim headers on every request, `{secret}`
 *    resolving to the credential (Supabase's second `apikey` header,
 *    Notion's version pin).
 *  - `queryArgMap` + `fixedQuery` — arg→param renames with defaults
 *    (Google Drive `query`→`q`, `limit`→`pageSize=20`) and constant params
 *    (`fields=*`, `alt=media`).
 *  - a `queryArgs` entry whose value is a plain object expands to its
 *    entries (PostgREST passthrough, Supabase `query`).
 *  - `requireQueryArgs` — the unfiltered-write refusal Supabase's Dart
 *    capability enforced.
 *  - `bodyTemplate` — declarative body synthesis with dot-paths (nested
 *    objects/arrays) and `arg:`/`json:`/`config:`/`int:`/`const:`/`secret`/
 *    `when:ARG:<ref>` refs (Mongo Data-API envelopes, the Airtable/Firebase
 *    `{"fields":…}` wrap, the nested Notion create_page payload). Absent
 *    refs — and everything a `when:` guard fails on — omit the whole path.
 */

import { createHash, createHmac } from "node:crypto";
import { trimToolResult, type McpToolDef, type McpToolCallResult } from "../client.js";
import type { McpCallContext, NativeMcpHandler } from "../transports/native.js";
import {
  assertBoundedHeadersOrCancel,
  egressResponseFromDecodedFetch,
  readBoundedBody,
  type EgressLimits,
  type EgressResponse,
  type ProviderEgress,
  type StreamLimits,
} from "../egress/responseLimits.js";
import { createSecretRedactor, type SecretRedactor } from "../egress/redactor.js";
import {
  assertClosedProviderSchema,
  authorizeProviderOperation,
  normalizeConnectionConfig,
  snapshotProviderArgs,
  validateProviderArgs,
  type ApprovalPolicy,
  type Effect,
  type ProviderOperation,
  type ProviderOutputPolicy,
  type ToolContext,
} from "../providers/types.js";

export { authorizeProviderOperation } from "../providers/types.js";
export type {
  ApprovalPolicy,
  Effect,
  ProviderApproval,
  ProviderAuthorization,
  ProviderDefinition,
  ProviderOperation,
  ProviderOutputPolicy,
  RunPolicy,
  ToolContext,
} from "../providers/types.js";
export type {
  EgressLimits,
  EgressRequest,
  EgressResponse,
  ProviderEgress,
  StreamLimits,
} from "../egress/responseLimits.js";
export { createSecretRedactor } from "../egress/redactor.js";
export type { SecretRedactor } from "../egress/redactor.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type RestAuthKind = "none" | "bearer" | "apiKeyHeader" | "basic" | "queryKey";

export interface RestToolDef {
  name: string;
  description: string;
  method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD";
  path: string;
  inputSchema: Record<string, unknown>;
  queryArgs?: string[];
  jsonBodyArg?: string;
  formBodyArg?: string;
  /** Dart parity: required arg names — missing → "Missing required argument". */
  required?: string[];
  /** Declarative body synthesis (see the module header). */
  bodyTemplate?: Record<string, string>;
  /** Arg name → "paramName" or "paramName:defaultValue". */
  queryArgMap?: Record<string, string>;
  /** Constant query params added to every call of this tool. */
  fixedQuery?: Record<string, string>;
  /** Args that must resolve to a non-empty map (unfiltered-write refusal). */
  requireQueryArgs?: string[];
  /** Typed-provider metadata; legacy descriptors receive conservative defaults. */
  effect?: Effect;
  approval?: ApprovalPolicy;
  requiredScopes?: readonly string[];
  request?: ProviderOperation["request"];
  limits?: ProviderOperation["limits"];
  outputPolicy?: ProviderOutputPolicy;
  custom?: boolean;
}

export interface CredentialField {
  key: string;
  label: string;
  secret: boolean;
  hint?: string;
}

export interface RestServiceDescriptor {
  curatedId: string;
  displayName: string;
  description: string;
  /** May contain `{placeholders}` filled from args/config (e.g. Jira `https://{host}`). */
  baseUrl: string;
  auth: RestAuthKind;
  authHeader?: string;
  authPrefix?: string;
  /** queryKey: the query param name. basic: the config key holding the username. */
  authParam?: string;
  credentialKey: string;
  credentialLabel: string;
  /** Non-secret extras (hosts, regions…) + secret siblings. */
  extraConfig?: CredentialField[];
  tools: RestToolDef[];
  /** Verbatim headers on every request; `{secret}` resolves to the credential. */
  staticHeaders?: Record<string, string>;
  /** Authenticated config is validated separately from model operation args. */
  connectionSchema?: Record<string, unknown>;
}

export interface RestHandlerOptions {
  /** Task 2 supplies this pinned implementation; no DNS claims are made here. */
  providerEgress?: ProviderEgress;
  resolveConnectionConfig?: (ctx: McpCallContext) => Promise<Record<string, unknown>>;
  redactor?: SecretRedactor;
}

export interface PublishedRestToolDef extends McpToolDef {
  effect: Effect;
  approval: ApprovalPolicy;
  requiredScopes: readonly string[];
  request: ProviderOperation["request"];
  limits: ProviderOperation["limits"];
  outputPolicy: ProviderOutputPolicy;
}

export const REST_DEFAULT_TIMEOUT_S = 30;
export const REST_MIN_TIMEOUT_S = 5;
export const REST_MAX_TIMEOUT_S = 300;

// ---------------------------------------------------------------------------
// Errors (Dart ArgumentError / FormatException surfaced as isError results)
// ---------------------------------------------------------------------------

/** Dart parity: FormatException — invalid user-supplied input shapes. */
export class RestFormatException extends Error {
  constructor(message: string) {
    super(message);
    this.name = "FormatException";
  }
}

/** Dart parity: ArgumentError — missing/invalid arguments. */
export class RestArgumentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ArgumentError";
  }
}

/** A `{placeholder}` that no arg, config value or default could fill. */
class MissingPlaceholderError extends Error {
  constructor(readonly placeholderName: string) {
    super(placeholderName);
    this.name = "MissingPlaceholderError";
  }
}

/** A `config:` body ref that names an unconfigured field. */
class MissingConfigError extends Error {
  constructor(readonly key: string) {
    super(key);
    this.name = "MissingConfigError";
  }
}

function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

// ---------------------------------------------------------------------------
// Shared result/config helpers
// ---------------------------------------------------------------------------

/** The exact configure-first text (the secret value is NEVER in it). */
export function configureFirstMessage(displayName: string, label: string): string {
  return `Configure ${label} first: open the MCP settings for ${displayName}.`;
}

function toolResult(text: string, isError = false): McpToolCallResult {
  const trimmed = trimToolResult(text);
  return { text: trimmed, isError, content: [{ type: "text", text: trimmed }] };
}

/** credential + extraConfig, keyed by config key. */
function fieldLabels(d: RestServiceDescriptor): Map<string, string> {
  const labels = new Map<string, string>();
  if (d.credentialKey !== "") labels.set(d.credentialKey, d.credentialLabel);
  for (const f of d.extraConfig ?? []) labels.set(f.key, f.label);
  return labels;
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function connectionSchemaFor(d: RestServiceDescriptor): Record<string, unknown> {
  if (d.connectionSchema !== undefined) {
    assertClosedProviderSchema(d.connectionSchema);
    return d.connectionSchema;
  }
  const properties: Record<string, unknown> = {};
  const fields = [
    ...(d.credentialKey === "" ? [] : [{ key: d.credentialKey, secret: true }]),
    ...(d.extraConfig ?? []),
  ];
  for (const field of fields) {
    properties[field.key] = {
      type: "string",
      maxLength: field.secret ? 16_384 : /url|host|base/i.test(field.key) ? 2_048 : 1_024,
    };
  }
  return {
    type: "object",
    properties,
    required: [],
    additionalProperties: false,
    maxProperties: Object.keys(properties).length,
  };
}

function allSecretValues(stored: Record<string, string>, base?: string): string[] {
  return [...Object.values(stored), ...(base === undefined ? [] : [base])].filter((value) => value !== "");
}

// ---------------------------------------------------------------------------
// Timeout (Dart parity: tolerant parse, default 30, clamped 5..300)
// ---------------------------------------------------------------------------

export function resolveTimeoutSeconds(args: Record<string, unknown>): number {
  const raw = args.timeout_seconds;
  let value: number;
  if (raw === undefined || raw === null) {
    value = REST_DEFAULT_TIMEOUT_S;
  } else if (typeof raw === "number") {
    value = raw;
  } else {
    const text = String(raw).trim();
    if (text === "") {
      throw new RestFormatException(`Invalid timeout_seconds "${String(raw)}": expected a number.`);
    }
    const parsed = Number(text);
    if (Number.isNaN(parsed)) {
      throw new RestFormatException(`Invalid timeout_seconds "${String(raw)}": expected a number.`);
    }
    value = parsed;
  }
  if (!Number.isFinite(value)) {
    throw new RestFormatException(`Invalid timeout_seconds "${String(raw)}": expected a finite number.`);
  }
  return Math.min(REST_MAX_TIMEOUT_S, Math.max(REST_MIN_TIMEOUT_S, Math.round(value)));
}

// ---------------------------------------------------------------------------
// Placeholder substitution
// ---------------------------------------------------------------------------

/** encodeURIComponent, but `/` survives (multi-segment resource paths). */
function encodePathValue(v: string): string {
  return encodeURIComponent(v).replace(/%2F/g, "/");
}

/** Dart `_cleanHost`: strip scheme, path and whitespace from a pasted host. */
function cleanHost(raw: string): string {
  let host = raw.trim().replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "");
  const slash = host.indexOf("/");
  if (slash >= 0) host = host.slice(0, slash);
  return host.trim();
}

/** Dart `_cleanBaseUrl`: bare hostnames gain `https://`, trailing `/` stripped. */
function cleanBaseUrl(raw: string): string {
  let base = raw.trim();
  while (base.endsWith("/")) base = base.slice(0, -1);
  if (base === "") return "";
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(base)) base = `https://${base}`;
  return base;
}

type SubstituteMode = "wholeBase" | "hostPart" | "path";

function substituteConnection(
  template: string,
  stored: Record<string, string>,
  encode: (v: string) => string,
): string {
  return template.replace(/\{([^{}]+)\}/g, (_m, rawName: string) => {
    const eq = rawName.indexOf("=");
    const name = eq >= 0 ? rawName.slice(0, eq) : rawName;
    const fallback = eq >= 0 ? rawName.slice(eq + 1) : undefined;
    const fromStored = (stored[name] ?? "").trim();
    if (fromStored !== "") return encode(fromStored);
    if (fallback !== undefined) return encode(fallback);
    throw new MissingPlaceholderError(name);
  });
}

function substituteOperation(
  template: string,
  args: Record<string, unknown>,
  stored: Record<string, string>,
  connectionKeys: ReadonlySet<string>,
  encode: (v: string) => string,
): string {
  return template.replace(/\{([^{}]+)\}/g, (_m, rawName: string) => {
    const eq = rawName.indexOf("=");
    const name = eq >= 0 ? rawName.slice(0, eq) : rawName;
    const fallback = eq >= 0 ? rawName.slice(eq + 1) : undefined;
    if (connectionKeys.has(name)) {
      const fromStored = (stored[name] ?? "").trim();
      if (fromStored !== "") return encode(fromStored);
    } else {
      const fromArgs = args[name];
      if (fromArgs !== undefined && fromArgs !== null && String(fromArgs).trim() !== "") {
        return encode(String(fromArgs));
      }
    }
    if (fallback !== undefined) return encode(fallback);
    throw new MissingPlaceholderError(name);
  });
}

// ---------------------------------------------------------------------------
// Body building
// ---------------------------------------------------------------------------

/** Typed object/array fields only; raw JSON documents are never parsed from model text. */
function bodyJson(raw: unknown, key: string): unknown {
  if (raw === undefined || raw === null) return {};
  if (isPlainObject(raw) || Array.isArray(raw)) return raw;
  throw new RestFormatException(`Invalid ${key}: expected a typed JSON value.`);
}

/** Dart `_asInt`: tolerant integer parse with a fallback. */
function asInt(raw: unknown, key: string, fallback: number): number {
  if (raw === undefined || raw === null) return fallback;
  if (typeof raw === "number") {
    if (!Number.isFinite(raw)) {
      throw new RestFormatException(`Invalid ${key} "${String(raw)}": expected a number.`);
    }
    return Math.round(raw);
  }
  const text = String(raw).trim();
  if (text === "") return fallback;
  const parsed = Number(text);
  if (Number.isNaN(parsed)) {
    throw new RestFormatException(`Invalid ${key} "${String(raw)}": expected a number.`);
  }
  return Math.round(parsed);
}

interface RefValue {
  present: boolean;
  value: unknown;
}

function resolveRef(
  ref: string,
  key: string,
  args: Record<string, unknown>,
  stored: Record<string, string>,
  secret: string,
): RefValue {
  // `when:ARG:<ref>` — resolve the inner ref only when ARG is present;
  // lets an arg-optional subtree (Notion's children) disappear entirely.
  if (ref.startsWith("when:")) {
    const rest = ref.slice("when:".length);
    const colon = rest.indexOf(":");
    if (colon < 0) throw new RestArgumentError(`Invalid bodyTemplate ref "${ref}" for "${key}".`);
    const guardArg = rest.slice(0, colon);
    const guard = args[guardArg];
    if (guard === undefined || guard === null || String(guard).trim() === "") {
      return { present: false, value: undefined };
    }
    return resolveRef(rest.slice(colon + 1), key, args, stored, secret);
  }
  if (ref === "secret") return { present: secret !== "", value: secret };
  if (ref.startsWith("config:")) {
    const configKey = ref.slice("config:".length);
    const v = (stored[configKey] ?? "").trim();
    if (v === "") throw new MissingConfigError(configKey);
    return { present: true, value: v };
  }
  if (ref.startsWith("arg:")) {
    const argKey = ref.slice("arg:".length);
    const raw = args[argKey];
    if (raw === undefined || raw === null || String(raw).trim() === "") return { present: false, value: undefined };
    return { present: true, value: raw };
  }
  if (ref.startsWith("json:")) {
    const argKey = ref.slice("json:".length);
    const raw = args[argKey];
    if (raw === undefined || raw === null || (typeof raw === "string" && raw.trim() === "")) {
      return { present: false, value: undefined };
    }
    return { present: true, value: bodyJson(raw, argKey) };
  }
  if (ref.startsWith("int:")) {
    const rest = ref.slice("int:".length);
    const lastColon = rest.lastIndexOf(":");
    const argKey = lastColon >= 0 ? rest.slice(0, lastColon) : rest;
    const hasDefault = lastColon >= 0;
    const raw = args[argKey];
    if (raw === undefined || raw === null || (typeof raw !== "number" && String(raw).trim() === "")) {
      if (hasDefault) return { present: true, value: Number(rest.slice(lastColon + 1)) };
      return { present: false, value: undefined };
    }
    return { present: true, value: asInt(raw, argKey, 0) };
  }
  if (ref.startsWith("const:")) {
    try {
      return { present: true, value: JSON.parse(ref.slice("const:".length)) as unknown };
    } catch (err) {
      throw new RestFormatException(`Invalid bodyTemplate const for "${key}": ${messageOf(err)}`);
    }
  }
  return { present: true, value: ref }; // bare literal
}

type Container = Record<string, unknown> | unknown[];

function slotGet(container: Container, key: string): unknown {
  if (/^\d+$/.test(key) && Array.isArray(container)) return container[Number(key)];
  return (container as Record<string, unknown>)[key];
}

function slotSet(container: Container, key: string, value: unknown): void {
  if (/^\d+$/.test(key) && Array.isArray(container)) {
    const index = Number(key);
    while (container.length <= index) container.push({});
    container[index] = value;
    return;
  }
  (container as Record<string, unknown>)[key] = value;
}

/** Nested assignment through dot-paths; numeric segments are array indices. */
function setDeep(root: Record<string, unknown>, pathExpr: string, value: unknown): void {
  const segs = pathExpr.split(".");
  let container: Container = root;
  for (let i = 0; i < segs.length - 1; i++) {
    const nextWantsArray = /^\d+$/.test(segs[i + 1] ?? "");
    const existing = slotGet(container, segs[i]);
    if (nextWantsArray ? Array.isArray(existing) : isPlainObject(existing)) {
      container = existing as Container;
    } else {
      const fresh: Container = nextWantsArray ? [] : {};
      slotSet(container, segs[i], fresh);
      container = fresh;
    }
  }
  slotSet(container, segs[segs.length - 1], value);
}

function buildTemplatedBody(
  template: Record<string, string>,
  args: Record<string, unknown>,
  stored: Record<string, string>,
  secret: string,
): Record<string, unknown> {
  const body: Record<string, unknown> = {};
  for (const [pathExpr, ref] of Object.entries(template)) {
    const resolved = resolveRef(ref, pathExpr, args, stored, secret);
    if (!resolved.present) continue; // absent ref → the whole path is omitted
    setDeep(body, pathExpr, resolved.value);
  }
  return body;
}

interface BuiltBody {
  body?: string;
}

function buildBody(
  def: RestToolDef,
  args: Record<string, unknown>,
  stored: Record<string, string>,
  secret: string,
  headers: Record<string, string>,
): BuiltBody {
  if (def.method === "GET" || def.method === "HEAD") return {};
  if (def.bodyTemplate !== undefined) {
    headers["content-type"] = "application/json";
    return { body: JSON.stringify(buildTemplatedBody(def.bodyTemplate, args, stored, secret)) };
  }
  return {};
}

// ---------------------------------------------------------------------------
// Tool defs (pure — the catalog manifest builds from these without handlers)
// ---------------------------------------------------------------------------

const TIMEOUT_SCHEMA = {
  type: "number",
  minimum: 5,
  maximum: 300,
  description: "Request timeout in seconds (default 30, maximum 300).",
};

const DEFAULT_OPERATION_LIMITS: ProviderOperation["limits"] = {
  timeoutMs: 30_000,
  responseBytes: 65_536,
  frameBytes: 65_536,
  pageBytes: 65_536,
};

const LEGACY_SCHEMA_KEYS = new Set([
  "type", "description", "title", "default", "examples", "properties", "required",
  "additionalProperties", "maxProperties", "minProperties", "items", "maxItems", "minItems",
  "minLength", "maxLength", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "enum", "const",
]);

function normalizeLegacySchema(raw: unknown): Record<string, unknown> {
  if (!isPlainObject(raw)) throw new RestArgumentError("Invalid provider schema.");
  for (const key of Object.keys(raw)) {
    if (!LEGACY_SCHEMA_KEYS.has(key)) throw new RestArgumentError("Unsupported provider schema.");
  }
  const schema: Record<string, unknown> = { ...raw };
  const type = raw.type;
  if (type === "object") {
    const rawProperties = raw.properties ?? {};
    if (!isPlainObject(rawProperties)) throw new RestArgumentError("Invalid provider schema properties.");
    const properties = Object.fromEntries(
      Object.entries(rawProperties).map(([key, value]) => [key, normalizeLegacySchema(value)]),
    );
    schema.properties = properties;
    schema.additionalProperties = false;
    schema.maxProperties = raw.maxProperties ?? Object.keys(properties).length;
  } else if (type === "array") {
    if (raw.items === undefined) throw new RestArgumentError("Provider arrays must declare typed items.");
    schema.items = normalizeLegacySchema(raw.items);
    schema.maxItems = raw.maxItems ?? 100;
  } else if (type === "string") {
    schema.maxLength = raw.maxLength ?? 8_192;
  } else if (type === "number" || type === "integer") {
    schema.minimum = raw.minimum ?? -1_000_000_000;
    schema.maximum = raw.maximum ?? 1_000_000_000;
  }
  return schema;
}

interface RestOperation {
  legacy: RestToolDef;
  definition: ProviderOperation;
  schema: Record<string, unknown>;
  streamLimits: StreamLimits;
}

const LINEAR_LIST_ISSUES_QUERY =
  "query OvidListIssues($first: Int) { issues(first: $first) { nodes { id identifier title state { name } } } }";
const LINEAR_LIST_TEAMS_QUERY =
  "query OvidListTeams { teams { nodes { id key name } } }";

function typedObject(
  properties: Record<string, unknown>,
  required: readonly string[] = [],
): Record<string, unknown> {
  return {
    type: "object",
    properties,
    required: [...required],
    additionalProperties: false,
    maxProperties: Object.keys(properties).length,
  };
}

/** Convert the small set of official legacy reads whose bodies are known. */
function typedLegacyOperation(d: RestServiceDescriptor, def: RestToolDef): RestToolDef {
  const shared = { ...def, jsonBodyArg: undefined, formBodyArg: undefined };
  if (d.curatedId === "linear" && def.name === "list_issues") {
    return {
      ...shared,
      description: "List issues with a server-owned GraphQL document and typed pagination.",
      inputSchema: typedObject({
        first: { type: "integer", minimum: 1, maximum: 100, default: 20 },
      }),
      required: [],
      bodyTemplate: {
        query: `const:${JSON.stringify(LINEAR_LIST_ISSUES_QUERY)}`,
        "variables.first": "int:first:20",
      },
    };
  }
  if (d.curatedId === "linear" && def.name === "list_teams") {
    return {
      ...shared,
      description: "List teams with a server-owned GraphQL document.",
      inputSchema: typedObject({}),
      required: [],
      bodyTemplate: { query: `const:${JSON.stringify(LINEAR_LIST_TEAMS_QUERY)}` },
    };
  }
  if (d.curatedId === "exa" && def.name === "search") {
    return {
      ...shared,
      description: "Search with typed query and result-count fields.",
      inputSchema: typedObject({
        query: { type: "string", minLength: 1, maxLength: 2_048 },
        numResults: { type: "integer", minimum: 1, maximum: 20, default: 5 },
      }, ["query"]),
      required: ["query"],
      bodyTemplate: { query: "arg:query", numResults: "int:numResults:5" },
    };
  }
  if (d.curatedId === "exa" && def.name === "contents") {
    return {
      ...shared,
      description: "Fetch contents for a bounded list of typed document identifiers.",
      inputSchema: typedObject({
        ids: {
          type: "array",
          minItems: 1,
          maxItems: 20,
          items: { type: "string", minLength: 1, maxLength: 2_048 },
        },
        text: { type: "boolean" },
      }, ["ids"]),
      required: ["ids"],
      bodyTemplate: { ids: "arg:ids", text: "arg:text" },
    };
  }
  return shared;
}

function effectFor(def: RestToolDef): Effect {
  if (def.effect !== undefined) return def.effect;
  const name = def.name.toLowerCase();
  if (/^(list|get|search|history|download|query|find|contents)(_|$)/.test(name)) return "read";
  if (/(^|_)(delete|destroy|remove)(_|$)/.test(name)) return "destructive";
  if (/(^|_)(deploy|deployment|release|restart)(_|$)/.test(name)) return "deployment";
  if (/(^|_)(invoice|payment|charge|refund|billing)(_|$)/.test(name)) return "financial";
  if (/(^|_)(send|send_message|message|comment|notify|campaign)(_|$)/.test(name) || name.includes("comment")) {
    return "external_communication";
  }
  if (/(^|_)(presign|credential)(_|$)/.test(name)) return "credential_use";
  return def.method === "GET" || def.method === "HEAD" ? "read" : "write";
}

function approvalFor(def: RestToolDef, effect: Effect): ApprovalPolicy {
  if (effect === "external_communication" || effect === "financial" || effect === "deployment" ||
      effect === "destructive" || effect === "credential_use") {
    return "per_action";
  }
  return def.approval ?? "mode";
}

function operationLimitsValid(limits: ProviderOperation["limits"]): boolean {
  return Number.isInteger(limits.timeoutMs) && limits.timeoutMs > 0 && limits.timeoutMs <= 300_000 &&
    Number.isInteger(limits.responseBytes) && limits.responseBytes > 0 && limits.responseBytes <= 16_777_216 &&
    Number.isInteger(limits.frameBytes) && limits.frameBytes > 0 && limits.frameBytes <= 16_777_216 &&
    Number.isInteger(limits.pageBytes) && limits.pageBytes > 0 && limits.pageBytes <= 16_777_216;
}

function streamLimitsFor(operation: ProviderOperation, timeoutMs = operation.limits.timeoutMs): StreamLimits {
  const totalMs = Math.max(1, Math.min(operation.limits.timeoutMs, timeoutMs));
  return {
    connectMs: totalMs,
    headersMs: totalMs,
    idleMs: totalMs,
    totalMs,
    maxRedirects: 0,
    headerBytes: 8_192,
    responseBytes: Math.min(operation.limits.responseBytes, operation.outputPolicy.maxBytes),
    decompressedBytes: Math.min(operation.limits.responseBytes * 4, 16_777_216),
    sseEventBytes: operation.limits.frameBytes,
    sseEventCount: 1_000,
    jsonRpcFrameBytes: operation.limits.frameBytes,
    aggregateStreamBytes: operation.limits.pageBytes,
    toolResultBytes: 8_192,
  };
}

function operationFor(d: RestServiceDescriptor, input: RestToolDef): RestOperation {
  const def = typedLegacyOperation(d, input);
  if (def.jsonBodyArg !== undefined || def.formBodyArg !== undefined) {
    throw new RestArgumentError("Provider operation is unavailable: arbitrary request bodies are disabled.");
  }
  const request = def.request ?? { originKey: d.curatedId, method: def.method, pathTemplate: def.path };
  if (!["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].includes(request.method) || request.method !== def.method) {
    throw new RestArgumentError("Provider operation uses an unsupported method.");
  }
  const schema = normalizeLegacySchema(def.inputSchema);
  const properties = {
    ...((schema.properties as Record<string, unknown> | undefined) ?? {}),
    timeout_seconds: { ...TIMEOUT_SCHEMA },
  };
  const required = [...new Set([...((schema.required as string[] | undefined) ?? []), ...(def.required ?? [])])];
  schema.properties = properties;
  schema.required = required;
  schema.additionalProperties = false;
  schema.maxProperties = Object.keys(properties).length;
  assertClosedProviderSchema(schema);

  const limits = def.limits ?? { ...DEFAULT_OPERATION_LIMITS };
  if (!operationLimitsValid(limits)) throw new RestArgumentError("Provider operation has invalid limits.");
  const effect = effectFor(def);
  const approval = approvalFor(def, effect);
  const outputPolicy = def.outputPolicy ?? { kind: "redacted_text", maxBytes: limits.responseBytes };
  if (outputPolicy.maxBytes <= 0 || outputPolicy.maxBytes > limits.responseBytes) {
    throw new RestArgumentError("Provider operation has an invalid output policy.");
  }
  const definition: ProviderOperation = {
    name: def.name,
    description: def.description,
    effect,
    approval,
    requiredScopes: def.requiredScopes ?? [],
    inputSchema: schema,
    outputPolicy,
    request,
    limits,
    ...(def.custom !== undefined ? { custom: def.custom } : {}),
  };
  return { legacy: def, definition, schema, streamLimits: streamLimitsFor(definition) };
}

/** Published operations always carry closed schemas and execution metadata. */
export function restToolDefs(d: RestServiceDescriptor): PublishedRestToolDef[] {
  const published: PublishedRestToolDef[] = [];
  for (const legacy of d.tools) {
    try {
      const operation = operationFor(d, legacy);
      published.push({
        name: operation.definition.name,
        description: operation.definition.description,
        inputSchema: operation.schema,
        effect: operation.definition.effect,
        approval: operation.definition.approval,
        requiredScopes: operation.definition.requiredScopes,
        request: operation.definition.request,
        limits: operation.definition.limits,
        outputPolicy: operation.definition.outputPolicy,
      });
    } catch {
      // Unsafe legacy operations are quarantined, never published as callable.
    }
  }
  return published;
}

// ---------------------------------------------------------------------------
// The handler
// ---------------------------------------------------------------------------

export function createRestHandler(d: RestServiceDescriptor, options: RestHandlerOptions = {}): NativeMcpHandler {
  const labels = fieldLabels(d);
  const redactor = options.redactor ?? createSecretRedactor();
  const connectionSchema = connectionSchemaFor(d);

  async function send(
    ctx: McpCallContext,
    operation: RestOperation,
    url: URL,
    headers: Record<string, string>,
    body: string | undefined,
    stored: Record<string, string>,
    base: string,
    timeoutSeconds: number,
  ): Promise<{ body: Uint8Array; status: number }> {
    const limits = streamLimitsFor(operation.definition, timeoutSeconds * 1_000);
    const secretValues = allSecretValues(stored, base);
    try {
      const response = options.providerEgress !== undefined
        ? await options.providerEgress.request({
            originKey: operation.definition.request.originKey,
            url,
            method: operation.definition.request.method,
            headers,
            ...(body === undefined ? {} : { body: new TextEncoder().encode(body) }),
            secretValues,
            privileged: true,
            redirect: "deny",
            limits,
            signal: AbortSignal.timeout(limits.totalMs),
          })
        : await (async (): Promise<EgressResponse> => {
            if (typeof ctx.fetchImpl !== "function") {
              throw new Error("ProviderEgress or guarded fetchImpl is required.");
            }
            const legacy = await ctx.fetchImpl(url.toString(), {
              method: operation.definition.request.method,
              headers,
              ...(body === undefined ? {} : { body }),
              redirect: "manual",
              signal: AbortSignal.timeout(limits.totalMs),
            });
            return egressResponseFromDecodedFetch(legacy, url);
          })();
      await assertBoundedHeadersOrCancel(response, limits);
      if (response.status < 200 || response.status >= 300) {
        await response.body.cancel().catch(() => {});
        return { body: new Uint8Array(), status: response.status };
      }
      return { body: await readBoundedBody(response, limits), status: response.status };
    } catch (error) {
      if (error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError")) {
        throw new RestFormatException("Provider request timed out.");
      }
      if (error instanceof RestFormatException) throw error;
      throw new RestFormatException("Provider request failed or exceeded its safety limits.");
    }
  }

  async function runTool(
    def: RestToolDef,
    args: Record<string, unknown>,
    ctx: McpCallContext,
  ): Promise<McpToolCallResult> {
    // One frozen snapshot is authoritative across every await and all request
    // construction; later caller mutations cannot change what was approved.
    try {
      args = snapshotProviderArgs(args);
    } catch {
      throw new RestArgumentError("Invalid operation arguments.");
    }
    // Definition and model-input validation precede config resolution,
    // decryption, approval prompts, DNS, and every other side effect.
    const operation = operationFor(d, def);
    def = operation.legacy;
    if (!validateProviderArgs(operation.schema, args).ok) {
      throw new RestArgumentError("Invalid operation arguments.");
    }
    for (const key of def.required ?? []) {
      const value = args[key];
      if (typeof value === "string" && value.trim() === "") {
        throw new RestArgumentError(`Missing required argument: ${key}`);
      }
    }
    for (const argName of def.requireQueryArgs ?? []) {
      const value = args[argName];
      if (!isPlainObject(value) || Object.keys(value).length === 0) {
        throw new RestArgumentError("A non-empty typed filter is required for this operation.");
      }
    }
    const timeoutSeconds = resolveTimeoutSeconds(args);
    const candidate = ctx as unknown as Partial<ToolContext>;
    const authorizationContext = {
      ...candidate,
      sessionId: candidate.sessionId ?? "",
      runId: candidate.runId ?? "",
      userId: candidate.userId ?? ctx.uid,
      connectionId: candidate.connectionId ?? "",
      providerId: d.curatedId,
      mode: candidate.mode ?? "safe",
      planMode: candidate.planMode ?? false,
      unattended: candidate.unattended ?? true,
      isSubagent: candidate.isSubagent ?? false,
      depth: candidate.depth ?? 0,
      callKey: candidate.callKey ?? "",
      signal: candidate.signal ?? new AbortController().signal,
    } as ToolContext;
    const authorization = await authorizeProviderOperation(authorizationContext, operation.definition, args);
    if (authorization.kind === "deny") return toolResult(`Operation denied (${authorization.code}).`, true);

    let stored: Record<string, string>;
    try {
      const unresolved = options.resolveConnectionConfig !== undefined
        ? await options.resolveConnectionConfig(ctx)
        : ctx.secrets ?? {};
      stored = normalizeConnectionConfig(connectionSchema, unresolved);
    } catch {
      return toolResult("Invalid connection configuration.", true);
    }
    const secrets = allSecretValues(stored);
    const finish = (value: string, isError = false, trim = true): McpToolCallResult => {
      const projected = redactor.text(value, secrets);
      const bounded = trim ? trimToolResult(projected) : projected;
      if (Buffer.byteLength(bounded, "utf8") > operation.streamLimits.toolResultBytes) {
        return toolResult("Provider result exceeded the tool output limit.", true);
      }
      return { text: bounded, isError, content: [{ type: "text", text: bounded }] };
    };

    const secret = (stored[d.credentialKey] ?? "").trim();
    if (d.credentialKey !== "" && secret === "") {
      return finish(configureFirstMessage(d.displayName, d.credentialLabel), true);
    }
    const usernameKey = d.authParam ?? "username";
    if (d.auth === "basic" && (stored[usernameKey] ?? "").trim() === "") {
      return finish(configureFirstMessage(d.displayName, labels.get(usernameKey) ?? usernameKey), true);
    }

    const baseUrlMode: SubstituteMode = /^\{[^{}]+\}$/.test(d.baseUrl)
      ? "wholeBase"
      : /^https?:\/\/\{[^{}]+\}/.test(d.baseUrl)
        ? "hostPart"
        : "path";
    const baseEncoder =
      baseUrlMode === "wholeBase" ? cleanBaseUrl : baseUrlMode === "hostPart" ? cleanHost : encodePathValue;
    const base = substituteConnection(d.baseUrl, stored, baseEncoder).replace(/\/+$/, "");
    const connectionKeys = new Set([
      ...(d.credentialKey === "" ? [] : [d.credentialKey]),
      ...(d.extraConfig ?? []).map((field) => field.key),
    ]);
    const path = substituteOperation(
      operation.definition.request.pathTemplate,
      args,
      stored,
      connectionKeys,
      encodePathValue,
    );
    let url: URL;
    try {
      url = new URL(base + path);
    } catch {
      return finish("Invalid connection configuration.", true);
    }
    const loopback = ["127.0.0.1", "::1", "localhost"].includes(url.hostname.replace(/^\[|\]$/g, ""));
    if (url.username !== "" || url.password !== "" || url.hash !== "" ||
        (url.protocol !== "https:" && !(url.protocol === "http:" && loopback))) {
      return finish("Invalid connection configuration.", true);
    }

    const params = new URLSearchParams(url.search);
    for (const [k, v] of Object.entries(def.fixedQuery ?? {})) params.set(k, v);
    if (d.auth === "queryKey") params.set(d.authParam ?? "api_key", secret);
    for (const name of def.queryArgs ?? []) {
      const value = args[name];
      if (value === undefined || value === null) continue;
      if (isPlainObject(value)) {
        // The strict schema has already closed this object; only its declared
        // typed keys can become query parameters.
        for (const [entryKey, entryValue] of Object.entries(value)) {
          if (entryValue === undefined || entryValue === null) continue;
          params.set(entryKey, flattenQueryValue(entryValue));
        }
      } else if (String(value) !== "") {
        params.set(name, String(value));
      }
    }
    for (const [argName, spec] of Object.entries(def.queryArgMap ?? {})) {
      const colon = spec.indexOf(":");
      const param = colon >= 0 ? spec.slice(0, colon) : spec;
      const fallback = colon >= 0 ? spec.slice(colon + 1) : undefined;
      const value = args[argName];
      if (value !== undefined && value !== null && String(value).trim() !== "") {
        params.set(param, String(value));
      } else if (fallback !== undefined) {
        params.set(param, fallback);
      }
    }
    url.search = params.toString();

    const headers: Record<string, string> = {};
    switch (d.auth) {
      case "none":
      case "queryKey":
        break;
      case "bearer":
        headers[d.authHeader ?? "Authorization"] = `${d.authPrefix ?? ""}${secret}`;
        break;
      case "apiKeyHeader":
        headers[d.authHeader ?? "X-Api-Key"] = `${d.authPrefix ?? ""}${secret}`;
        break;
      case "basic": {
        const username = (stored[usernameKey] ?? "").trim();
        headers.Authorization = `Basic ${Buffer.from(`${username}:${secret}`).toString("base64")}`;
        break;
      }
    }
    for (const [k, v] of Object.entries(d.staticHeaders ?? {})) {
      headers[k] = v.replace(/\{secret\}/g, secret);
    }
    const { body } = buildBody(def, args, stored, secret, headers);
    const response = await send(ctx, operation, url, headers, body, stored, base, timeoutSeconds);
    if (response.status < 200 || response.status >= 300) {
      return finish(`Provider request failed (HTTP ${response.status}).`, true);
    }

    const policy = operation.definition.outputPolicy;
    if (policy.kind === "status_only") return finish(`Provider request succeeded (HTTP ${response.status}).`);
    if (policy.kind === "binary_metadata") return finish(`Provider returned ${response.body.byteLength} bytes.`);
    if (policy.kind === "redacted_json") {
      try {
        const parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(response.body)) as unknown;
        return finish(JSON.stringify(redactor.json(parsed, secrets)), false, false);
      } catch {
        return finish("Provider returned an invalid JSON response.", true);
      }
    }
    try {
      return finish(new TextDecoder("utf-8", { fatal: true }).decode(response.body));
    } catch {
      return finish("Provider returned a non-text response.", true);
    }
  }

  return {
    async initialize(): Promise<Record<string, unknown>> {
      return {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: d.curatedId, version: "1.0.0" },
      };
    },

    async listTools(): Promise<McpToolDef[]> {
      return restToolDefs(d).map((t) => ({ ...t, inputSchema: { ...t.inputSchema } }));
    },

    async callTool(
      name: string,
      args: Record<string, unknown>,
      ctx: McpCallContext,
    ): Promise<McpToolCallResult> {
      const def = d.tools.find((t) => t.name === name);
      if (def === undefined) return toolResult("Unknown provider operation.", true);
      try {
        return await runTool(def, args ?? {}, ctx);
      } catch (err) {
        if (err instanceof MissingPlaceholderError) {
          const label = labels.get(err.placeholderName);
          if (label !== undefined) {
            return toolResult(configureFirstMessage(d.displayName, label), true);
          }
          return toolResult(`Missing required argument: ${err.placeholderName}`, true);
        }
        if (err instanceof MissingConfigError) {
          return toolResult(configureFirstMessage(d.displayName, labels.get(err.key) ?? err.key), true);
        }
        if (err instanceof RestArgumentError) return toolResult(err.message, true);
        if (err instanceof RestFormatException) {
          return toolResult("Invalid operation arguments or provider response.", true);
        }
        return toolResult("Provider operation failed.", true);
      }
    },
  };
}

function flattenQueryValue(value: unknown): string {
  if (Array.isArray(value)) return value.map((v) => String(v)).join(",");
  if (isPlainObject(value)) return JSON.stringify(value);
  return String(value);
}

// ---------------------------------------------------------------------------
// SigV4 (S3 + generic AWS services) — a 1:1 port of the Dart s3Authorization
// and the presign helper that lived in the same rest_engine.dart.
// ---------------------------------------------------------------------------

export function sha256Hex(data: string | Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}

/** RFC 3986 percent-encoding for SigV4 (unreserved marks stay bare). */
export function sigV4Encode(input: string): string {
  const bytes = Buffer.from(input, "utf8");
  let out = "";
  for (const byte of bytes) {
    const c = byte as number;
    const unreserved =
      (c >= 0x41 && c <= 0x5a) || // A-Z
      (c >= 0x61 && c <= 0x7a) || // a-z
      (c >= 0x30 && c <= 0x39) || // 0-9
      c === 0x2d || // -
      c === 0x5f || // _
      c === 0x2e || // .
      c === 0x7e; // ~
    out += unreserved ? String.fromCharCode(c) : `%${c.toString(16).toUpperCase().padStart(2, "0")}`;
  }
  return out;
}

function two(n: number): string {
  return String(n).padStart(2, "0");
}

function utcDateStamp(date: Date): string {
  const y = date.getUTCFullYear();
  const m = two(date.getUTCMonth() + 1);
  const day = two(date.getUTCDate());
  return `${y}${m}${day}`;
}

function amzDateStrOf(date: Date): string {
  const dateStamp = utcDateStamp(date);
  const h = two(date.getUTCHours());
  const min = two(date.getUTCMinutes());
  const s = two(date.getUTCSeconds());
  return `${dateStamp}T${h}${min}${s}Z`;
}

export interface S3AuthorizationParams {
  accessKeyId: string;
  secretAccessKey: string;
  region: string;
  service?: string;
  method: string;
  canonicalUri: string;
  queryParameters?: Record<string, string>;
  headers?: Record<string, string>;
  payloadHash: string;
  amzDate: Date;
}

/** Builds an AWS Signature Version 4 `Authorization` header value. */
export function s3Authorization(params: S3AuthorizationParams): string {
  const service = params.service ?? "s3";
  const dateStamp = utcDateStamp(params.amzDate);
  const amzDateStr = amzDateStrOf(params.amzDate);

  const path = params.canonicalUri === "" ? "/" : params.canonicalUri;
  const encodedPath = path.split("/").map(sigV4Encode).join("/");

  const sortedQuery = Object.entries(params.queryParameters ?? {})
    .map(([k, v]) => [sigV4Encode(k), sigV4Encode(v)] as const)
    .sort((a, b) => {
      const byKey = a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0;
      return byKey !== 0 ? byKey : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0;
    });
  const canonicalQuery = sortedQuery.map(([k, v]) => `${k}=${v}`).join("&");

  const normalized = Object.entries(params.headers ?? {})
    .map(([k, v]) => [k.trim().toLowerCase(), v.trim().replace(/\s+/g, " ")] as const)
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  const canonicalHeaders = normalized.map(([k, v]) => `${k}:${v}\n`).join("");
  const signedHeaders = normalized.map(([k]) => k).join(";");

  const canonicalRequest =
    `${params.method.trim().toUpperCase()}\n${encodedPath}\n${canonicalQuery}\n` +
    `${canonicalHeaders}\n${signedHeaders}\n${params.payloadHash}`;
  const scope = `${dateStamp}/${params.region}/${service}/aws4_request`;
  const stringToSign =
    `AWS4-HMAC-SHA256\n${amzDateStr}\n${scope}\n${sha256Hex(Buffer.from(canonicalRequest, "utf8"))}`;

  let key: Uint8Array = Buffer.from(`AWS4${params.secretAccessKey}`, "utf8");
  for (const data of [dateStamp, params.region, service, "aws4_request"]) {
    key = createHmac("sha256", key).update(data, "utf8").digest();
  }
  const signature = createHmac("sha256", key).update(stringToSign, "utf8").digest("hex");
  return (
    `AWS4-HMAC-SHA256 Credential=${params.accessKeyId}/${scope}, ` +
    `SignedHeaders=${signedHeaders}, Signature=${signature}`
  );
}

/** Presigned URLs live 1s..7d per AWS (clamped into range). */
function clampExpires(seconds: number): number {
  return Math.min(604800, Math.max(1, seconds));
}

export interface S3PresignParams {
  accessKeyId: string;
  secretAccessKey: string;
  region: string;
  bucket: string;
  key: string;
  expiresSeconds?: number;
  amzDate: Date;
}

/** Builds a presigned S3 GET URL (SigV4 query-string auth — pure signing, no network). */
export function s3PresignedGetUrl(params: S3PresignParams): string {
  const expires = clampExpires(params.expiresSeconds ?? 3600);
  const amzDateStr = amzDateStrOf(params.amzDate);
  const dateStamp = utcDateStamp(params.amzDate);
  const host = `${params.bucket}.s3.${params.region}.amazonaws.com`;
  const encodedPath = `/${params.key.split("/").map(sigV4Encode).join("/")}`;
  const scope = `${dateStamp}/${params.region}/s3/aws4_request`;
  const query: Record<string, string> = {
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": `${params.accessKeyId}/${scope}`,
    "X-Amz-Date": amzDateStr,
    "X-Amz-Expires": String(expires),
    "X-Amz-SignedHeaders": "host",
  };
  const sorted = Object.entries(query)
    .map(([k, v]) => [sigV4Encode(k), sigV4Encode(v)] as const)
    .sort((a, b) => {
      const byKey = a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0;
      return byKey !== 0 ? byKey : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0;
    });
  const canonicalQuery = sorted.map(([k, v]) => `${k}=${v}`).join("&");
  const canonicalRequest = `GET\n${encodedPath}\n${canonicalQuery}\nhost:${host}\n\nhost\nUNSIGNED-PAYLOAD`;
  const stringToSign =
    `AWS4-HMAC-SHA256\n${amzDateStr}\n${scope}\n` +
    `${sha256Hex(Buffer.from(canonicalRequest, "utf8"))}`;
  let signingKey: Uint8Array = Buffer.from(`AWS4${params.secretAccessKey}`, "utf8");
  for (const data of [dateStamp, params.region, "s3", "aws4_request"]) {
    signingKey = createHmac("sha256", signingKey).update(data, "utf8").digest();
  }
  const signature = createHmac("sha256", signingKey).update(stringToSign, "utf8").digest("hex");
  return `https://${host}${encodedPath}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}
