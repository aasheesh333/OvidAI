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
import { followGuardedRedirects } from "../native/fetch.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type RestAuthKind = "none" | "bearer" | "apiKeyHeader" | "basic" | "queryKey";

export interface RestToolDef {
  name: string;
  description: string;
  method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
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

function substitute(
  template: string,
  args: Record<string, unknown>,
  stored: Record<string, string>,
  encode: (v: string) => string,
): string {
  return template.replace(/\{([^{}]+)\}/g, (_m, rawName: string) => {
    const eq = rawName.indexOf("=");
    const name = eq >= 0 ? rawName.slice(0, eq) : rawName;
    const fallback = eq >= 0 ? rawName.slice(eq + 1) : undefined;
    const fromArgs = args[name];
    if (fromArgs !== undefined && fromArgs !== null && String(fromArgs).trim() !== "") {
      return encode(String(fromArgs));
    }
    const fromStored = (stored[name] ?? "").trim();
    if (fromStored !== "") return encode(fromStored);
    if (fallback !== undefined) return encode(fallback);
    throw new MissingPlaceholderError(name);
  });
}

// ---------------------------------------------------------------------------
// Body building
// ---------------------------------------------------------------------------

/** Dart `_bodyJson`: map/array verbatim, JSON string parsed, null → {}. */
function bodyJson(raw: unknown, key: string): unknown {
  if (raw === undefined || raw === null) return {};
  if (isPlainObject(raw) || Array.isArray(raw)) return raw;
  if (typeof raw === "string") {
    if (raw.trim() === "") return {};
    try {
      return JSON.parse(raw) as unknown;
    } catch (err) {
      throw new RestFormatException(`Invalid ${key} JSON: ${messageOf(err)}`);
    }
  }
  throw new RestFormatException(`Invalid ${key}: expected a JSON object.`);
}

function bodyForm(raw: unknown, key: string): Record<string, unknown> {
  if (isPlainObject(raw)) return raw;
  throw new RestFormatException(`Invalid ${key}: expected an object of form fields.`);
}

/** Dart `_formEncode`: one-level bracket flattening (`metadata[k]`, `items[0]`). */
function formEncode(fields: Record<string, unknown>): string {
  const pairs: [string, string][] = [];
  const add = (prefix: string, value: unknown): void => {
    if (isPlainObject(value)) {
      for (const [k, v] of Object.entries(value)) add(`${prefix}[${k}]`, v);
    } else if (Array.isArray(value)) {
      value.forEach((v, i) => add(`${prefix}[${i}]`, v));
    } else {
      pairs.push([prefix, value?.toString() ?? ""]);
    }
  };
  for (const [k, v] of Object.entries(fields)) add(k, v);
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
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
  d: RestServiceDescriptor,
  def: RestToolDef,
  args: Record<string, unknown>,
  stored: Record<string, string>,
  secret: string,
  headers: Record<string, string>,
): BuiltBody {
  if (def.method === "GET") return {};
  if (def.jsonBodyArg !== undefined && def.formBodyArg !== undefined) {
    throw new RestArgumentError(`Tool "${def.name}" declares both jsonBodyArg and formBodyArg.`);
  }
  if (def.bodyTemplate !== undefined) {
    headers["content-type"] = "application/json";
    return { body: JSON.stringify(buildTemplatedBody(def.bodyTemplate, args, stored, secret)) };
  }
  if (def.jsonBodyArg !== undefined) {
    headers["content-type"] = "application/json";
    return { body: JSON.stringify(bodyJson(args[def.jsonBodyArg], def.jsonBodyArg)) };
  }
  if (def.formBodyArg !== undefined) {
    headers["content-type"] = "application/x-www-form-urlencoded";
    return { body: formEncode(bodyForm(args[def.formBodyArg], def.formBodyArg)) };
  }
  return {};
}

// ---------------------------------------------------------------------------
// Tool defs (pure — the catalog manifest builds from these without handlers)
// ---------------------------------------------------------------------------

const TIMEOUT_SCHEMA = {
  type: "number",
  description: "Request timeout in seconds (default 30, clamped 5..300).",
};

/** The engine-injected tool defs for one descriptor (Dart parity: the
 * `timeout_seconds` property is added on top of the declared schema). */
export function restToolDefs(d: RestServiceDescriptor): McpToolDef[] {
  return d.tools.map((t) => {
    const schema = { ...t.inputSchema } as Record<string, unknown>;
    const properties = {
      ...((t.inputSchema.properties as Record<string, unknown> | undefined) ?? {}),
      timeout_seconds: { ...TIMEOUT_SCHEMA },
    };
    return {
      name: t.name,
      description: t.description,
      inputSchema: { ...schema, properties },
    };
  });
}

// ---------------------------------------------------------------------------
// The handler
// ---------------------------------------------------------------------------

export function createRestHandler(d: RestServiceDescriptor): NativeMcpHandler {
  const labels = fieldLabels(d);

  async function send(
    ctx: McpCallContext,
    urlStr: string,
    init: RequestInit,
    timeoutSeconds: number,
  ): Promise<{ text: string; status: number }> {
    let res: Response;
    try {
      res = await followGuardedRedirects(ctx.fetchImpl, urlStr, init);
    } catch (err) {
      if (err instanceof Error && (err.name === "TimeoutError" || err.name === "AbortError")) {
        throw new RestFormatException(`Request to ${urlStr} timed out after ${timeoutSeconds} seconds.`);
      }
      throw new Error(`HTTP request failed: ${messageOf(err)}`);
    }
    try {
      return { text: await res.text(), status: res.status };
    } catch (err) {
      if (err instanceof Error && (err.name === "TimeoutError" || err.name === "AbortError")) {
        throw new RestFormatException(`Request to ${urlStr} timed out after ${timeoutSeconds} seconds.`);
      }
      throw new Error(`HTTP request failed: ${messageOf(err)}`);
    }
  }

  async function runTool(
    def: RestToolDef,
    args: Record<string, unknown>,
    ctx: McpCallContext,
  ): Promise<McpToolCallResult> {
    for (const key of def.required ?? []) {
      const value = args[key];
      if (value === undefined || value === null || String(value).trim() === "") {
        throw new RestArgumentError(`Missing required argument: ${key}`);
      }
    }
    for (const argName of def.requireQueryArgs ?? []) {
      const value = args[argName];
      const empty = !isPlainObject(value) || Object.keys(value).length === 0;
      if (empty) {
        throw new RestArgumentError(
          `Tool "${def.name}" requires a non-empty "${argName}" filter map (unfiltered writes are refused).`,
        );
      }
    }

    const timeoutSeconds = resolveTimeoutSeconds(args);
    const stored = ctx.secrets ?? {};
    const secret = (stored[d.credentialKey] ?? "").trim();

    // Configure-first gate: any declared credential must be present before
    // the tool runs. The message names the label but NEVER the value.
    if (d.credentialKey !== "" && secret === "") {
      return toolResult(configureFirstMessage(d.displayName, d.credentialLabel), true);
    }

    const usernameKey = d.authParam ?? "username";
    if (d.auth === "basic") {
      const username = (stored[usernameKey] ?? "").trim();
      if (username === "") {
        return toolResult(
          configureFirstMessage(d.displayName, labels.get(usernameKey) ?? usernameKey),
          true,
        );
      }
    }

    // URL: baseUrl (trailing slashes stripped, Dart parity) + path, then
    // query params merged in declared order (later wins).
    const baseUrlMode: SubstituteMode = /^\{[^{}]+\}$/.test(d.baseUrl)
      ? "wholeBase"
      : /^https?:\/\/\{[^{}]+\}/.test(d.baseUrl)
        ? "hostPart"
        : "path";
    const baseEncoder =
      baseUrlMode === "wholeBase" ? cleanBaseUrl : baseUrlMode === "hostPart" ? cleanHost : encodePathValue;
    const base = substitute(d.baseUrl, args, stored, baseEncoder).replace(/\/+$/, "");
    const path = substitute(def.path, args, stored, encodePathValue);
    const url = new URL(base + path);
    const params = new URLSearchParams(url.search);
    for (const [k, v] of Object.entries(def.fixedQuery ?? {})) params.set(k, v);
    if (d.auth === "queryKey") params.set(d.authParam ?? "api_key", secret);
    for (const name of def.queryArgs ?? []) {
      const value = args[name];
      if (value === undefined || value === null) continue;
      if (isPlainObject(value)) {
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

    // Headers: auth injection first, then static extras.
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

    const { body } = buildBody(d, def, args, stored, secret, headers);

    const urlStr = url.toString();
    const { text, status } = await send(ctx, urlStr, {
      method: def.method,
      headers,
      body,
      signal: AbortSignal.timeout(timeoutSeconds * 1000),
    }, timeoutSeconds);

    if (status >= 200 && status < 300) return toolResult(text);
    // Non-2xx bodies pass through verbatim (they carry the API's own error
    // payload); the status line keeps success/failure unambiguous.
    return toolResult(`HTTP ${status}\n${text}`, true);
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
      if (def === undefined) {
        return toolResult(`Unknown tool: ${name} for plugin "${d.displayName}".`, true);
      }
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
        return toolResult(messageOf(err), true);
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
