/**
 * Verified-read candidates for documents, data, search, and finance.
 *
 * Only narrow, least-privilege reads are defined here. SQL/job endpoints,
 * mutable financial APIs, arbitrary request bodies, and unvalidated tenant
 * origins are never exported. Authenticated dynamic tenants receive one fresh
 * pinned egress per call. Every response is projected to a small allowlisted
 * shape before it can reach a model.
 *
 * These are contract candidates, not live-readiness evidence. catalog.ts keeps
 * them out of CURATED_IDS/CURATED_MANIFEST until explicit live reads pass.
 */

import { isIP } from "node:net";
import {
  authorizeProviderOperation,
  createRestHandler,
  createSecretRedactor,
  resolveTimeoutSeconds,
  restToolDefs,
  type ProviderDefinition,
  type ProviderOperation,
  type RestHandlerOptions,
  type RestServiceDescriptor,
  type RestToolDef,
  type PublishedRestToolDef,
  type SecretRedactor,
  type ToolContext,
} from "../engine.js";
import {
  normalizeConnectionConfig,
  snapshotProviderArgs,
  validateProviderArgs,
  validateProviderDefinition,
} from "../../providers/types.js";
import { createProviderEgress, type ProviderEgress } from "../../egress/providerEgress.js";
import {
  assertBoundedHeadersOrCancel,
  readBoundedBody,
  type EgressLimits,
} from "../../egress/responseLimits.js";
import type { McpCallContext } from "../../transports/native.js";

const VERIFIED_AT = "2026-10-24";
const CATALOG_VERSION = "2026-10-24.1";
const LIMITS = Object.freeze({
  timeoutMs: 30_000,
  responseBytes: 65_536,
  frameBytes: 65_536,
  pageBytes: 65_536,
});
// Raw provider pages are capped at 64 KiB; the engine separately enforces its
// 8 KiB final tool-result cap after the allowlisted projection below.
const OUTPUT_POLICY = Object.freeze({ kind: "redacted_json" as const, maxBytes: 65_536 });

type Docs = ProviderDefinition["officialDocs"];
type JsonObject = Record<string, unknown>;

interface DataSearchSpec {
  authProfileId: string;
  officialDocs: Docs;
  descriptor: RestServiceDescriptor;
}

export interface DataSearchBlockedCandidate {
  providerId: string;
  reason: string;
  officialDocs: Docs;
  replacements?: readonly string[];
}

function docs(...urls: readonly string[]): Docs {
  return urls.map((url) => ({ url, verifiedAt: VERIFIED_AT }));
}

function objectSchema(
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

function stringSchema(maxLength: number, minLength = 0): Record<string, unknown> {
  return { type: "string", minLength, maxLength };
}

function integerSchema(minimum: number, maximum: number, fallback?: number): Record<string, unknown> {
  return {
    type: "integer",
    minimum,
    maximum,
    ...(fallback === undefined ? {} : { default: fallback }),
  };
}

function connectionSchema(fields: Record<string, Record<string, unknown>>): Record<string, unknown> {
  return objectSchema(fields, Object.keys(fields));
}

function secretField(): Record<string, unknown> {
  return stringSchema(16_384, 1);
}

function idField(): Record<string, unknown> {
  return stringSchema(128, 1);
}

function constant(value: unknown): string {
  return `const:${JSON.stringify(value)}`;
}

interface ReadSpec {
  name: string;
  description: string;
  method: "GET" | "POST";
  path: string;
  scope: string;
  properties?: Record<string, unknown>;
  required?: readonly string[];
  queryArgMap?: Record<string, string>;
  fixedQuery?: Record<string, string>;
  bodyTemplate?: Record<string, string>;
}

function readOperation(spec: ReadSpec): RestToolDef {
  const required = [...(spec.required ?? [])];
  return {
    name: spec.name,
    description: spec.description,
    method: spec.method,
    path: spec.path,
    inputSchema: objectSchema(spec.properties ?? {}, required),
    required,
    ...(spec.queryArgMap === undefined ? {} : { queryArgMap: spec.queryArgMap }),
    ...(spec.fixedQuery === undefined ? {} : { fixedQuery: spec.fixedQuery }),
    ...(spec.bodyTemplate === undefined ? {} : { bodyTemplate: spec.bodyTemplate }),
    effect: "read",
    approval: "mode",
    requiredScopes: [spec.scope],
    limits: { ...LIMITS },
    outputPolicy: { ...OUTPUT_POLICY },
  };
}

function object(value: unknown): JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("Provider response has an invalid object shape.");
  }
  return value as JsonObject;
}

function array(value: unknown): unknown[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new Error("Provider response has an invalid list shape.");
  return value;
}

function pick(value: unknown, keys: readonly string[]): JsonObject {
  const source = object(value);
  const result: JsonObject = {};
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(source, key)) result[key] = source[key];
  }
  return result;
}

function capped(
  value: unknown,
  cap: number,
  project: (entry: unknown) => JsonObject,
): { items: JsonObject[]; total: number; truncated: boolean } {
  const source = array(value);
  return {
    items: source.slice(0, cap).map(project),
    total: source.length,
    truncated: source.length > cap,
  };
}

function withOptionalTruncation(
  target: JsonObject,
  projected: { items: JsonObject[]; total: number; truncated: boolean },
  key: string,
): void {
  target[key] = projected.items;
  if (projected.truncated) target.truncated = true;
}

function projectTypeform(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["total_items", "page_count"]);
  const forms = capped(root.items, 50, (entry) => {
    const form = object(entry);
    const projected = pick(form, ["id", "title", "created_at", "last_updated_at"]);
    if (Object.prototype.hasOwnProperty.call(form, "settings")) {
      projected.settings = pick(form.settings, ["is_public"]);
    }
    return projected;
  });
  withOptionalTruncation(result, forms, "items");
  return result;
}

function projectCalendly(value: unknown): JsonObject {
  const root = object(value);
  return {
    resource: pick(root.resource, [
      "uri", "name", "slug", "timezone", "created_at", "updated_at",
    ]),
  };
}

function projectMiro(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["total", "size", "offset", "limit"]);
  withOptionalTruncation(result, capped(root.data, 50, (entry) =>
    pick(entry, ["id", "name", "createdAt", "modifiedAt", "type"]),
  ), "data");
  return result;
}

function projectCanva(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["continuation"]);
  withOptionalTruncation(result, capped(root.items, 100, (entry) =>
    pick(entry, ["id", "title", "created_at", "updated_at", "page_count", "design_types"]),
  ), "items");
  return result;
}

function projectWebflow(value: unknown): JsonObject {
  const root = object(value);
  const sites = capped(root.sites, 20, (entry) =>
    pick(entry, ["id", "workspaceId", "displayName", "shortName", "lastPublished", "lastUpdated"]),
  );
  return {
    sites: sites.items,
    total: sites.total,
    truncated: sites.truncated,
  };
}

function projectPinecone(value: unknown): JsonObject {
  const root = object(value);
  const indexes = capped(root.indexes, 20, (entry) => {
    const index = object(entry);
    return {
      ...pick(index, ["name", "host"]),
      status: pick(index.status, ["ready", "state"]),
      deployment: pick(index.deployment, ["deployment_type", "cloud", "region"]),
    };
  });
  return {
    indexes: indexes.items,
    total: indexes.total,
    truncated: indexes.truncated,
  };
}

function nextCursor(root: JsonObject): JsonObject {
  return Object.prototype.hasOwnProperty.call(root, "nextPageToken")
    ? { next_cursor: root.nextPageToken }
    : {};
}

function projectBigQuery(value: unknown): JsonObject {
  const root = object(value);
  const result = nextCursor(root);
  withOptionalTruncation(result, capped(root.datasets, 50, (entry) => {
    const dataset = object(entry);
    return {
      datasetReference: pick(dataset.datasetReference, ["projectId", "datasetId"]),
      ...pick(dataset, ["friendlyName", "location"]),
    };
  }), "datasets");
  return result;
}

function projectBrave(value: unknown): JsonObject {
  const root = object(value);
  const web = object(root.web ?? {});
  const results = capped(web.results, 20, (entry) =>
    pick(entry, ["title", "url", "description", "page_age"]),
  );
  const projectedWeb: JsonObject = {};
  withOptionalTruncation(projectedWeb, results, "results");
  return {
    query: pick(root.query ?? {}, ["original", "altered", "show_strict_warning"]),
    web: projectedWeb,
  };
}

function projectTavily(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["query", "response_time", "request_id"]);
  withOptionalTruncation(result, capped(root.results, 10, (entry) =>
    pick(entry, ["title", "url", "content", "score"]),
  ), "results");
  return result;
}

function projectGoogleMaps(value: unknown): JsonObject {
  const root = object(value);
  const result = nextCursor(root);
  withOptionalTruncation(result, capped(root.places, 20, (entry) => pick(entry, ["id"])), "places");
  return result;
}

function projectMixpanel(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["computed_at", "date_range", "headers"]);
  const series = object(root.series);
  const projectedSeries: JsonObject = {};
  const events = Object.entries(series);
  let truncated = events.length > 10;
  for (const [event, rawDates] of events.slice(0, 10)) {
    const dates = Object.entries(object(rawDates));
    if (dates.length > 31) truncated = true;
    projectedSeries[event] = Object.fromEntries(dates.slice(0, 31));
  }
  result.series = projectedSeries;
  result.truncated = truncated;
  return result;
}

function projectAmplitude(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["pagination"]);
  withOptionalTruncation(result, capped(root.data, 50, (entry) =>
    pick(entry, [
      "id", "object", "project_id", "name", "chart_type", "created_at", "updated_at", "archived",
    ]),
  ), "data");
  return result;
}

function projectPostHog(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["count"]);
  result.has_next = typeof root.next === "string" && root.next.length > 0;
  withOptionalTruncation(result, capped(root.results, 50, (entry) =>
    pick(entry, ["id", "short_id", "name", "created_at", "last_modified_at"]),
  ), "results");
  return result;
}

function projectSegment(value: unknown): JsonObject {
  const root = object(value);
  const data = object(root.data);
  const projectedData = pick(data, ["pagination"]);
  withOptionalTruncation(projectedData, capped(data.sources, 25, (entry) =>
    pick(entry, ["id", "slug", "name", "workspaceId", "enabled"]),
  ), "sources");
  return { data: projectedData };
}

function projectStripe(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["object", "has_more"]);
  withOptionalTruncation(result, capped(root.data, 100, (entry) =>
    pick(entry, ["id", "object", "active", "created", "updated", "name", "livemode"]),
  ), "data");
  return result;
}

function projectDocuSign(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["resultSetSize", "totalSetSize", "startPosition", "endPosition"]);
  withOptionalTruncation(result, capped(root.envelopes, 100, (entry) =>
    pick(entry, ["envelopeId", "status", "emailSubject", "createdDateTime", "sentDateTime", "statusChangedDateTime"]),
  ), "envelopes");
  return result;
}

function projectSnowflake(value: unknown): JsonObject {
  const databases = capped(Array.isArray(value) ? value : object(value).databases, 50, (entry) =>
    pick(entry, ["name", "kind", "created_on", "retention_time"]),
  );
  return { databases: databases.items, total: databases.total, truncated: databases.truncated };
}

function projectDatabricks(value: unknown): JsonObject {
  const root = object(value);
  const result = nextCursor(root.next_page_token === undefined ? root : { nextPageToken: root.next_page_token });
  withOptionalTruncation(result, capped(root.warehouses, 50, (entry) =>
    pick(entry, ["id", "name", "cluster_size", "warehouse_type", "state", "num_clusters"]),
  ), "warehouses");
  return result;
}

function projectElastic(value: unknown): JsonObject {
  const root = object(value);
  return {
    ...pick(root, ["_index", "_id", "found", "_version", "_seq_no", "_primary_term"]),
    _source: boundedRecord(root._source, 20),
  };
}

function projectTypesense(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["name", "num_documents", "enable_nested_fields"]);
  withOptionalTruncation(result, capped(root.fields, 50, (entry) =>
    pick(entry, ["name", "type", "facet", "index", "sort", "optional"]),
  ), "fields");
  return result;
}

function projectSerpApi(value: unknown): JsonObject {
  const root = object(value);
  return {
    search_metadata: pick(root.search_metadata, ["id", "status", "created_at", "processed_at", "total_time_taken"]),
    organic_results: capped(root.organic_results, 10, (entry) =>
      pick(entry, ["position", "title", "link", "snippet", "date"]),
    ).items,
  };
}

function projectAlgolia(value: unknown): JsonObject {
  return boundedRecord(value, 20);
}

function projectMetabase(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["total_count"]);
  withOptionalTruncation(result, capped(root.data, 25, (entry) =>
    pick(entry, ["type", "id", "name", "display_name", "description", "database_id", "database_schema", "verified"]),
  ), "data");
  return result;
}

function projectSuperset(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["count"]);
  const ids = array(root.ids);
  result.ids = ids.slice(0, 25);
  if (ids.length > 25) result.ids_truncated = true;
  withOptionalTruncation(result, capped(root.result, 25, (entry) =>
    pick(entry, ["id", "dashboard_title", "slug", "status", "changed_on"]),
  ), "result");
  return result;
}

function projectPayPal(value: unknown): JsonObject {
  const root = object(value);
  const result = pick(root, ["id", "intent", "status", "create_time", "update_time"]);
  withOptionalTruncation(result, capped(root.purchase_units, 10, (entry) => {
    const unit = object(entry);
    return {
      ...pick(unit, ["reference_id"]),
      amount: pick(unit.amount, ["currency_code", "value"]),
    };
  }), "purchase_units");
  return result;
}

function boundedScalar(value: unknown): unknown {
  if (value === null || typeof value === "boolean" || typeof value === "number") return value;
  if (typeof value === "string") return value.length > 512 ? value.slice(0, 512) : value;
  return undefined;
}

const SENSITIVE_RECORD_KEYS = new Set([
  "authorization", "proxy-authorization", "cookie", "set-cookie", "api_key", "apikey",
  "access_token", "refresh_token", "client_secret", "password", "secret", "token", "jwt",
]);

function boundedRecord(value: unknown, cap: number): JsonObject {
  const result: JsonObject = {};
  for (const [key, entry] of Object.entries(object(value)).slice(0, cap)) {
    const normalizedKey = key.toLowerCase();
    if (SENSITIVE_RECORD_KEYS.has(normalizedKey) || normalizedKey === "private" || normalizedKey.startsWith("private_")) continue;
    const scalar = boundedScalar(entry);
    if (scalar !== undefined) result[key] = scalar;
    else if (Array.isArray(entry)) {
      result[key] = entry.slice(0, 10).map(boundedScalar).filter((item) => item !== undefined);
    }
  }
  return result;
}

const PROJECTORS: Readonly<Record<string, (value: unknown) => JsonObject>> = {
  typeform: projectTypeform,
  calendly: projectCalendly,
  miro: projectMiro,
  canva: projectCanva,
  webflow: projectWebflow,
  pinecone: projectPinecone,
  bigquery: projectBigQuery,
  "brave-search": projectBrave,
  tavily: projectTavily,
  "google-maps": projectGoogleMaps,
  mixpanel: projectMixpanel,
  amplitude: projectAmplitude,
  posthog: projectPostHog,
  segment: projectSegment,
  stripe: projectStripe,
  docusign: projectDocuSign,
  snowflake: projectSnowflake,
  databricks: projectDatabricks,
  elasticsearch: projectElastic,
  typesense: projectTypesense,
  serpapi: projectSerpApi,
  algolia: projectAlgolia,
  metabase: projectMetabase,
  superset: projectSuperset,
  paypal: projectPayPal,
};

const TENANT_ID_RULES: Readonly<Record<string, Readonly<Record<string, RegExp>>>> = {
  bigquery: { project_id: /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/ },
  amplitude: { project_id: /^\d{1,20}$/ },
  posthog: { project_id: /^\d{1,20}$/ },
  mixpanel: { project_id: /^\d{1,20}$/, bookmark_id: /^\d{1,20}$/ },
  docusign: { account_id: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/ },
  elasticsearch: { index: /^[a-z0-9][a-z0-9._-]{0,127}$/ },
  typesense: { collection: /^(?!\.{1,2}$)[^\\/?#\s]{1,255}$/ },
  algolia: { index_name: /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/ },
};

function validateTenantConfig(providerId: string, config: Record<string, unknown>): void {
  for (const [key, rule] of Object.entries(TENANT_ID_RULES[providerId] ?? {})) {
    const value = config[key];
    if (value !== undefined && (typeof value !== "string" || !rule.test(value))) {
      throw new Error("Invalid tenant configuration.");
    }
  }
}

const DYNAMIC_TENANT_PROVIDERS = new Set([
  "docusign", "snowflake", "databricks", "elasticsearch", "typesense", "serpapi",
  "algolia", "metabase", "superset", "paypal",
]);

export interface DataSearchHandlerOptions extends RestHandlerOptions {
  /** Test seam only; production constructs a fresh pinned egress per call. */
  egressFactory?: (origins: Readonly<Record<string, readonly URL[]>>) => ProviderEgress;
}

function strictTenantOrigin(raw: string): URL {
  const url = new URL(raw);
  const hostname = url.hostname.replace(/^\[|\]$/g, "");
  if (url.protocol !== "https:" || url.username !== "" || url.password !== "" ||
      (url.pathname !== "/" && url.pathname !== "") || url.search !== "" || url.hash !== "" ||
      (url.port !== "" && url.port !== "443") || isIP(hostname) !== 0 ||
      hostname === "localhost" || hostname.endsWith(".localhost") || hostname.endsWith(".local")) {
    throw new Error("Invalid authenticated tenant origin.");
  }
  return new URL(url.origin);
}

function safeTenantLabel(raw: string | undefined): string {
  if (raw === undefined || !/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,62})$/.test(raw)) {
    throw new Error("Invalid tenant label.");
  }
  return raw;
}

function hostHasSuffix(hostname: string, suffix: string): boolean {
  return hostname.length > suffix.length && hostname.endsWith(suffix);
}

function tenantOriginFor(descriptor: RestServiceDescriptor, config: Record<string, string>): URL {
  switch (descriptor.curatedId) {
    case "docusign":
      return new URL("https://account.docusign.com");
    case "snowflake": {
      const origin = strictTenantOrigin(config.account_url ?? "");
      if (!hostHasSuffix(origin.hostname, ".snowflakecomputing.com")) throw new Error("Invalid Snowflake account origin.");
      return origin;
    }
    case "databricks": {
      const origin = strictTenantOrigin(config.workspace_url ?? "");
      if (![".cloud.databricks.com", ".azuredatabricks.net", ".gcp.databricks.com"].some(
        (suffix) => hostHasSuffix(origin.hostname, suffix),
      )) throw new Error("Invalid Databricks workspace origin.");
      return origin;
    }
    case "algolia":
      return new URL(`https://${safeTenantLabel(config.app_id)}-dsn.algolia.net`);
    case "elasticsearch":
    case "typesense":
    case "metabase":
    case "superset":
      return strictTenantOrigin(config.instance_url ?? "");
    default:
      return strictTenantOrigin(descriptor.baseUrl);
  }
}

function safeResourceSegment(value: unknown): boolean {
  return typeof value === "string" && value.trim().length > 0 && value !== "." && value !== ".." &&
    !/[\\/?#]/.test(value);
}

function gapArgsValid(providerId: string, args: Record<string, unknown>): boolean {
  if (providerId === "serpapi") return /^[a-f0-9]{24}$/.test(String(args.search_id ?? ""));
  if (providerId === "elasticsearch") return safeResourceSegment(args.document_id);
  if (providerId === "algolia") return safeResourceSegment(args.object_id);
  if (providerId === "paypal") return safeResourceSegment(args.order_id);
  if (providerId === "docusign") {
    return typeof args.from_date === "string" &&
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(args.from_date) &&
      !Number.isNaN(Date.parse(args.from_date));
  }
  return true;
}

const AUTH_JSON_LIMITS: EgressLimits = {
  connectMs: 10_000,
  headersMs: 15_000,
  idleMs: 30_000,
  totalMs: 30_000,
  maxRedirects: 0,
  headerBytes: 8_192,
  responseBytes: 16_384,
  decompressedBytes: 65_536,
};

function auxiliarySignal(caller?: AbortSignal): { signal: AbortSignal; dispose: () => void } {
  const controller = new AbortController();
  const timeout = AbortSignal.timeout(AUTH_JSON_LIMITS.totalMs);
  const abort = () => controller.abort(caller?.aborted ? caller.reason : timeout.reason);
  if (caller?.aborted === true) abort();
  caller?.addEventListener("abort", abort, { once: true });
  timeout.addEventListener("abort", abort, { once: true });
  return {
    signal: controller.signal,
    dispose() {
      caller?.removeEventListener("abort", abort);
      timeout.removeEventListener("abort", abort);
    },
  };
}

async function authJson(
  egress: ProviderEgress,
  originKey: string,
  url: string,
  init: { method: "GET" | "POST"; headers: Record<string, string>; body?: string; secrets: string[] },
  caller?: AbortSignal,
): Promise<JsonObject> {
  const linked = auxiliarySignal(caller);
  try {
    const response = await egress.request({
      originKey,
      url: new URL(url),
      method: init.method,
      headers: init.headers,
      ...(init.body === undefined ? {} : { body: new TextEncoder().encode(init.body) }),
      secretValues: init.secrets,
      privileged: true,
      redirect: "deny",
      limits: AUTH_JSON_LIMITS,
      signal: linked.signal,
    });
    await assertBoundedHeadersOrCancel(response, AUTH_JSON_LIMITS);
    if (response.status < 200 || response.status >= 300) {
      await response.body.cancel().catch(() => {});
      throw new Error("Provider authentication or discovery failed.");
    }
    const bytes = await readBoundedBody(response, AUTH_JSON_LIMITS);
    return object(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)));
  } finally {
    linked.dispose();
  }
}

async function docusignApiBase(
  descriptor: RestServiceDescriptor,
  config: Record<string, string>,
  egressFactory: NonNullable<DataSearchHandlerOptions["egressFactory"]>,
  caller?: AbortSignal,
): Promise<URL> {
  const discoveryOrigin = new URL("https://account.docusign.com");
  const egress = egressFactory({ [descriptor.curatedId]: Object.freeze([discoveryOrigin]) });
  try {
    const userinfo = await authJson(egress, descriptor.curatedId, "https://account.docusign.com/oauth/userinfo", {
      method: "GET",
      headers: { Authorization: `Bearer ${config.access_token}`, Accept: "application/json" },
      secrets: [config.access_token ?? ""],
    }, caller);
    const account = array(userinfo.accounts).map(object).find(
      (candidate) => candidate.account_id === config.account_id,
    );
    if (account === undefined) throw new Error("DocuSign account binding was not present in UserInfo.");
    const origin = strictTenantOrigin(String(account.base_uri ?? ""));
    if (!hostHasSuffix(origin.hostname, ".docusign.net")) throw new Error("Unexpected DocuSign account origin.");
    return origin;
  } finally {
    await egress.close().catch(() => {});
  }
}

async function paypalAccessToken(
  descriptor: RestServiceDescriptor,
  config: Record<string, string>,
  egress: ProviderEgress,
  caller?: AbortSignal,
): Promise<string> {
  const basic = Buffer.from(`${config.client_id}:${config.client_secret}`, "utf8").toString("base64");
  const token = await authJson(egress, descriptor.curatedId, "https://api-m.paypal.com/v1/oauth2/token", {
    method: "POST",
    headers: {
      Authorization: `Basic ${basic}`,
      "content-type": "application/x-www-form-urlencoded",
      Accept: "application/json",
    },
    body: "grant_type=client_credentials",
    secrets: [config.client_id ?? "", config.client_secret ?? ""],
  }, caller);
  if (typeof token.access_token !== "string" || token.access_token.length < 1 || token.access_token.length > 16_384) {
    throw new Error("Invalid PayPal token response.");
  }
  return token.access_token;
}

function providerAuthorizationContext(ctx: McpCallContext, descriptor: RestServiceDescriptor): ToolContext {
  const candidate = ctx as unknown as Partial<ToolContext>;
  return {
    ...candidate,
    sessionId: candidate.sessionId ?? "",
    runId: candidate.runId ?? "",
    userId: candidate.userId ?? ctx.uid,
    connectionId: candidate.connectionId ?? "",
    providerId: descriptor.curatedId,
    mode: candidate.mode ?? "safe",
    planMode: candidate.planMode ?? false,
    unattended: candidate.unattended ?? true,
    isSubagent: candidate.isSubagent ?? false,
    depth: candidate.depth ?? 0,
    callKey: candidate.callKey ?? "",
    signal: candidate.signal ?? new AbortController().signal,
  } as ToolContext;
}

/** Converts only fields declared by PublishedRestToolDef; no optional custom is invented. */
export function dataSearchProviderOperation(
  descriptor: RestServiceDescriptor,
  published: PublishedRestToolDef,
): ProviderOperation {
  return {
    name: published.name,
    description: published.description ?? published.name,
    effect: published.effect,
    approval: published.approval,
    requiredScopes: published.requiredScopes,
    inputSchema: published.inputSchema ?? objectSchema({}),
    outputPolicy: published.outputPolicy,
    request: published.request,
    limits: published.limits,
  };
}

function requiredStringsBlank(
  descriptor: RestServiceDescriptor,
  operation: ProviderOperation,
  args: Record<string, unknown>,
): boolean {
  const required = new Set<string>([
    ...(descriptor.tools.find((tool) => tool.name === operation.name)?.required ?? []),
    ...((operation.inputSchema.required as string[] | undefined) ?? []),
  ]);
  return [...required].some((key) => typeof args[key] === "string" && (args[key] as string).trim() === "");
}

/** Uses the normal typed engine and adds only provider-specific output projection. */
export function createDataSearchHandler(
  descriptor: RestServiceDescriptor,
  options: DataSearchHandlerOptions = {},
): ReturnType<typeof createRestHandler> {
  const projector = PROJECTORS[descriptor.curatedId];
  const canonical = DATA_SEARCH_DESCRIPTORS.find((entry) => entry.curatedId === descriptor.curatedId);
  if (projector === undefined || canonical !== descriptor) {
    throw new Error(`Expected the canonical descriptor for ${descriptor.curatedId}.`);
  }
  const baseRedactor = options.redactor ?? createSecretRedactor();
  const redactor: SecretRedactor = {
    text: (value, secrets) => baseRedactor.text(value, secrets),
    error: (error, secrets) => baseRedactor.error(error, secrets),
    json: <T>(value: T, secrets: readonly string[] = []): T => {
      // Project first so sensitive fields are discarded and pagination tokens
      // can use a non-secret cursor name before the shared redactor runs.
      return baseRedactor.json(projector(value), secrets) as T;
    },
  };
  const resolveConnectionConfig = async (ctx: Parameters<NonNullable<RestHandlerOptions["resolveConnectionConfig"]>>[0]) => {
    const unresolved = options.resolveConnectionConfig !== undefined
      ? await options.resolveConnectionConfig(ctx)
      : ctx.secrets ?? {};
    validateTenantConfig(descriptor.curatedId, unresolved);
    return unresolved;
  };
  const runtimeRedactor = (runtimeConfig: Record<string, unknown>): SecretRedactor => {
    const sensitiveKeys = new Set([
      descriptor.credentialKey,
      ...(descriptor.extraConfig ?? []).filter((field) => field.secret).map((field) => field.key),
      "access_token",
    ]);
    const sensitiveValues = new Set(
      [...sensitiveKeys].flatMap((key) => {
        const value = runtimeConfig[key];
        return typeof value === "string" && value !== "" ? [value] : [];
      }),
    );
    const onlySecrets = (values: readonly string[]) => values.filter((value) => sensitiveValues.has(value));
    return {
      text: (value, secrets) => baseRedactor.text(value, onlySecrets(secrets ?? [])),
      error: (error, secrets) => baseRedactor.error(error, onlySecrets(secrets ?? [])),
      json: <T>(value: T, secrets: readonly string[] = []): T =>
        baseRedactor.json(projector(value), onlySecrets(secrets)) as T,
    };
  };
  const rest = createRestHandler(descriptor, { ...options, resolveConnectionConfig, redactor });
  if (DYNAMIC_TENANT_PROVIDERS.has(descriptor.curatedId)) {
    const published = restToolDefs(descriptor);
    return {
      ...rest,
      async callTool(name, input, ctx) {
        const fail = (text: string) => ({ text, isError: true, content: [{ type: "text" as const, text }] });
        const operation = published.find((candidate) => candidate.name === name);
        if (operation === undefined) return rest.callTool(name, input, ctx);
        // Construct-only context shared by preflight and execution; no config,
        // discovery, token exchange, or other side effect occurs at this point.
        const authorizationContext = providerAuthorizationContext(ctx, descriptor);
        let args: Record<string, unknown>;
        // Published tool defs keep MCP's optional description/inputSchema;
        // authorization requires a complete ProviderOperation with both fields.
        const authorizationOperation = dataSearchProviderOperation(descriptor, operation);
        try {
          args = snapshotProviderArgs(input ?? {});
          if (!validateProviderArgs(authorizationOperation.inputSchema, args).ok ||
              !gapArgsValid(descriptor.curatedId, args) ||
              requiredStringsBlank(descriptor, authorizationOperation, args)) return fail("Invalid operation arguments.");
          resolveTimeoutSeconds(args);
          const authorization = await authorizeProviderOperation(
            authorizationContext,
            authorizationOperation,
            args,
          );
          if (authorization.kind === "deny") return fail(`Operation denied (${authorization.code}).`);
        } catch {
          return fail("Invalid operation arguments.");
        }

        let egress: ProviderEgress | undefined;
        try {
          const unresolved = await resolveConnectionConfig(ctx);
          const config = normalizeConnectionConfig(
            descriptor.connectionSchema ?? objectSchema({}),
            unresolved,
          );
          if (authorizationContext.signal.aborted) return fail("Operation denied (cancelled).");
          const egressFactory = options.egressFactory ?? ((origins: Readonly<Record<string, readonly URL[]>>) =>
            createProviderEgress({ origins, production: true, redactor: baseRedactor }));
          let origin = tenantOriginFor(descriptor, config);
          let runtimeDescriptor = descriptor;
          let runtimeConfig: Record<string, unknown> = config;
          if (descriptor.curatedId === "docusign") {
            origin = await docusignApiBase(descriptor, config, egressFactory, authorizationContext.signal);
            runtimeDescriptor = { ...descriptor, baseUrl: origin.origin };
          }
          if (authorizationContext.signal.aborted) return fail("Operation denied (cancelled).");
          egress = egressFactory({ [descriptor.curatedId]: Object.freeze([origin]) });
          if (descriptor.curatedId === "algolia") {
            runtimeDescriptor = {
              ...descriptor,
              staticHeaders: { ...descriptor.staticHeaders, "X-Algolia-Application-Id": config.app_id },
            };
          }
          if (descriptor.curatedId === "superset") {
            const page = typeof args.page === "number" ? args.page : 0;
            const pageSize = typeof args.page_size === "number" ? args.page_size : 10;
            runtimeDescriptor = {
              ...descriptor,
              tools: descriptor.tools.map((tool) => tool.name === name ? {
                ...tool,
                fixedQuery: {
                  q: `(columns:!(id,dashboard_title,slug,status,changed_on),page:${page},page_size:${pageSize})`,
                },
              } : tool),
            };
          }
          if (descriptor.curatedId === "paypal") {
            if (authorizationContext.signal.aborted) return fail("Operation denied (cancelled).");
            const accessToken = await paypalAccessToken(descriptor, config, egress, authorizationContext.signal);
            runtimeDescriptor = {
              ...descriptor,
              auth: "bearer",
              authPrefix: "Bearer ",
              credentialKey: "access_token",
              credentialLabel: "PayPal request-scoped access token",
              connectionSchema: connectionSchema({
                client_id: secretField(),
                client_secret: secretField(),
                access_token: secretField(),
              }),
            };
            runtimeConfig = { ...config, access_token: accessToken };
          }
          return await createRestHandler(runtimeDescriptor, {
            providerEgress: egress,
            resolveConnectionConfig: async () => runtimeConfig,
            redactor: runtimeRedactor(runtimeConfig),
          }).callTool(name, args, ctx);
        } catch {
          return fail("Provider operation failed or connection configuration was invalid.");
        } finally {
          if (egress !== undefined) await egress.close().catch(() => {});
        }
      },
    };
  }
  if (descriptor.curatedId !== "brave-search") return rest;
  return {
    ...rest,
    async callTool(name, args, ctx) {
      // Brave independently limits q to 75 words in addition to 600 characters.
      // Splitting a <=600-codepoint string is bounded; whitespace-only runs do
      // not create words. This check precedes the engine's config resolution.
      if (name === "web_search" && typeof args.query === "string" &&
          args.query.split(/\s+/u).filter((word) => word.length > 0).length > 75) {
        const text = "Invalid operation arguments.";
        return { text, isError: true, content: [{ type: "text" as const, text }] };
      }
      return rest.callTool(name, args, ctx);
    },
  };
}

const SPECS: readonly DataSearchSpec[] = [
  {
    authProfileId: "typeform-us-forms-read",
    officialDocs: docs(
      "https://www.typeform.com/developers/create/reference/retrieve-forms/",
      "https://www.typeform.com/developers/get-started/scopes/",
    ),
    descriptor: {
      curatedId: "typeform",
      displayName: "Typeform Forms (US)",
      description: "List form metadata for a US-region OAuth user with forms:read only.",
      baseUrl: "https://api.typeform.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "Typeform US OAuth access token (forms:read)",
      connectionSchema: connectionSchema({ access_token: secretField() }),
      tools: [readOperation({
        name: "list_forms",
        description: "List one bounded page of Typeform form metadata; response links are not followed.",
        method: "GET",
        path: "/forms",
        scope: "forms:read",
        properties: {
          search: stringSchema(200),
          page: integerSchema(1, 100, 1),
          page_size: integerSchema(1, 50, 20),
        },
        queryArgMap: { search: "search", page: "page:1", page_size: "page_size:20" },
      })],
    },
  },
  {
    authProfileId: "calendly-scoped-user-read",
    officialDocs: docs(
      "https://developer.calendly.com/docs/authentication/scopes",
      "https://developer.calendly.com/api-docs/overview/api/api-conventions",
    ),
    descriptor: {
      curatedId: "calendly",
      displayName: "Calendly User",
      description: "Read the current Calendly user with a scoped users:read OAuth token or PAT.",
      baseUrl: "https://api.calendly.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "Calendly scoped access token (users:read)",
      connectionSchema: connectionSchema({ access_token: secretField() }),
      tools: [readOperation({
        name: "get_current_user",
        description: "Read non-email profile metadata for the authenticated Calendly user.",
        method: "GET",
        path: "/users/me",
        scope: "users:read",
      })],
    },
  },
  {
    authProfileId: "miro-boards-read",
    officialDocs: docs(
      "https://developers.miro.com/reference/get-boards-1",
      "https://developers.miro.com/docs/getting-started-with-oauth",
    ),
    descriptor: {
      curatedId: "miro",
      displayName: "Miro Boards",
      description: "List board metadata available to the OAuth user with boards:read only.",
      baseUrl: "https://api.miro.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "Miro OAuth access token (boards:read)",
      connectionSchema: connectionSchema({ access_token: secretField() }),
      tools: [readOperation({
        name: "list_boards",
        description: "List one bounded offset page of Miro board metadata without policies or user details.",
        method: "GET",
        path: "/v2/boards",
        scope: "boards:read",
        properties: {
          query: stringSchema(500),
          limit: integerSchema(1, 50, 20),
          offset: integerSchema(0, 9_950, 0),
        },
        queryArgMap: { query: "query", limit: "limit:20", offset: "offset:0" },
      })],
    },
  },
  {
    authProfileId: "canva-design-meta-read",
    officialDocs: docs(
      "https://www.canva.dev/docs/apps/rest-apis/reference/designs/list-designs/",
      "https://www.canva.dev/docs/apps/rest-apis/scopes/",
    ),
    descriptor: {
      curatedId: "canva",
      displayName: "Canva Designs",
      description: "List design metadata with design:meta:read; temporary edit/view/thumbnail URLs are discarded.",
      baseUrl: "https://api.canva.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "Canva OAuth access token (design:meta:read)",
      connectionSchema: connectionSchema({ access_token: secretField() }),
      tools: [readOperation({
        name: "list_designs",
        description: "List one bounded page of Canva design metadata without temporary URLs or owner details.",
        method: "GET",
        path: "/rest/v1/designs",
        scope: "design:meta:read",
        properties: {
          query: stringSchema(255),
          limit: integerSchema(1, 100, 20),
          continuation: stringSchema(2_048),
        },
        queryArgMap: { query: "query", limit: "limit:20", continuation: "continuation" },
      })],
    },
  },
  {
    authProfileId: "webflow-v2-sites-read",
    officialDocs: docs(
      "https://developers.webflow.com/data/reference/sites/list",
      "https://developers.webflow.com/data/reference/authentication",
    ),
    descriptor: {
      curatedId: "webflow",
      displayName: "Webflow Sites",
      description: "List accessible Webflow v2 site metadata with sites:read only.",
      baseUrl: "https://api.webflow.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "Webflow OAuth or site token (sites:read)",
      connectionSchema: connectionSchema({ access_token: secretField() }),
      tools: [readOperation({
        name: "list_sites",
        description: "List a bounded projection of Webflow site metadata without domains or preview URLs.",
        method: "GET",
        path: "/v2/sites",
        scope: "sites:read",
      })],
    },
  },
  {
    authProfileId: "pinecone-2026-07-control-plane-viewer",
    officialDocs: docs(
      "https://docs.pinecone.io/reference/api/2026-07/control-plane/list_indexes",
      "https://docs.pinecone.io/guides/projects/manage-api-keys",
    ),
    descriptor: {
      curatedId: "pinecone",
      displayName: "Pinecone Indexes",
      description: "List index metadata using a serverless project ControlPlaneViewer key and API 2026-07.",
      baseUrl: "https://api.pinecone.io",
      auth: "apiKeyHeader",
      authHeader: "Api-Key",
      credentialKey: "api_key",
      credentialLabel: "Pinecone ControlPlaneViewer API key",
      staticHeaders: { "X-Pinecone-Api-Version": "2026-07" },
      connectionSchema: connectionSchema({ api_key: secretField() }),
      tools: [readOperation({
        name: "list_indexes",
        description: "List a bounded projection of Pinecone index metadata; no index host is contacted.",
        method: "GET",
        path: "/indexes",
        scope: "ControlPlaneViewer",
      })],
    },
  },
  {
    authProfileId: "bigquery-metadata-readonly",
    officialDocs: docs(
      "https://docs.cloud.google.com/bigquery/docs/reference/rest/v2/datasets/list",
      "https://cloud.google.com/bigquery/docs/access-control",
    ),
    descriptor: {
      curatedId: "bigquery",
      displayName: "BigQuery Metadata",
      description: "List BigQuery dataset metadata only; SQL and query-job endpoints are not exposed.",
      baseUrl: "https://bigquery.googleapis.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "Google OAuth access token (bigquery.readonly)",
      extraConfig: [{
        key: "project_id",
        label: "BigQuery project ID",
        secret: false,
        hint: "The project authorized for metadata reads.",
      }],
      connectionSchema: connectionSchema({ access_token: secretField(), project_id: idField() }),
      tools: [readOperation({
        name: "list_datasets",
        description: "List one bounded page of BigQuery dataset metadata for the configured project.",
        method: "GET",
        path: "/bigquery/v2/projects/{project_id}/datasets",
        scope: "https://www.googleapis.com/auth/bigquery.readonly",
        properties: {
          maxResults: integerSchema(1, 50, 20),
          pageToken: stringSchema(2_048),
        },
        queryArgMap: { maxResults: "maxResults:20", pageToken: "pageToken" },
      })],
    },
  },
  {
    authProfileId: "brave-web-search-key",
    officialDocs: docs(
      "https://api-dashboard.search.brave.com/api-reference/web/search/get",
      "https://api-dashboard.search.brave.com/documentation/guides/authentication",
    ),
    descriptor: {
      curatedId: "brave-search",
      displayName: "Brave Web Search",
      description: "Search the web with a dedicated per-user web-search subscription key and capped results.",
      baseUrl: "https://api.search.brave.com/res",
      auth: "apiKeyHeader",
      authHeader: "X-Subscription-Token",
      credentialKey: "api_key",
      credentialLabel: "Brave web-search subscription token",
      staticHeaders: { Accept: "application/json" },
      connectionSchema: connectionSchema({ api_key: secretField() }),
      tools: [readOperation({
        name: "web_search",
        description: "Run one Brave web search bounded to 600 characters, 75 words, and 20 results; no callbacks or expansions.",
        method: "GET",
        path: "/v1/web/search",
        scope: "web-search",
        properties: {
          query: stringSchema(600, 1),
          count: integerSchema(1, 20, 5),
          offset: integerSchema(0, 2, 0),
        },
        required: ["query"],
        queryArgMap: { query: "q", count: "count:5", offset: "offset:0" },
        fixedQuery: { result_filter: "web", safesearch: "moderate", text_decorations: "false" },
      })],
    },
  },
  {
    authProfileId: "tavily-basic-search-key",
    officialDocs: docs(
      "https://docs.tavily.com/documentation/api-reference/endpoint/search",
      "https://docs.tavily.com/documentation/api-reference/endpoint/usage",
    ),
    descriptor: {
      curatedId: "tavily",
      displayName: "Tavily Search",
      description: "Run a basic one-credit search with a dedicated key and no answer, image, or raw-content expansion.",
      baseUrl: "https://api.tavily.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "api_key",
      credentialLabel: "Tavily project API key",
      connectionSchema: connectionSchema({ api_key: secretField() }),
      tools: [readOperation({
        name: "search",
        description: "Run one basic Tavily search with typed query/results and fixed low-cost options.",
        method: "POST",
        path: "/search",
        scope: "search:basic",
        properties: {
          query: stringSchema(2_048, 1),
          max_results: integerSchema(1, 10, 5),
        },
        required: ["query"],
        bodyTemplate: {
          query: "arg:query",
          max_results: "int:max_results:5",
          search_depth: constant("basic"),
          chunks_per_source: constant(1),
          include_answer: constant(false),
          include_raw_content: constant(false),
          include_images: constant(false),
        },
      })],
    },
  },
  {
    authProfileId: "google-places-new-id-only-key",
    officialDocs: docs(
      "https://developers.google.com/maps/documentation/places/web-service/text-search",
      "https://developers.google.com/maps/documentation/places/web-service/get-api-key",
    ),
    descriptor: {
      curatedId: "google-maps",
      displayName: "Google Places (New)",
      description: "Search Places API (New) for place IDs with a Places-only key and Essentials ID Only field mask.",
      baseUrl: "https://places.googleapis.com",
      auth: "apiKeyHeader",
      authHeader: "X-Goog-Api-Key",
      credentialKey: "api_key",
      credentialLabel: "Google Places API (New) restricted key",
      staticHeaders: { "X-Goog-FieldMask": "places.id,nextPageToken" },
      connectionSchema: connectionSchema({ api_key: secretField() }),
      tools: [readOperation({
        name: "search_places",
        description: "Run one Places Text Search for IDs only; no legacy Places or higher-cost fields are exposed.",
        method: "POST",
        path: "/v1/places:searchText",
        scope: "Places API (New): Text Search Essentials ID Only",
        properties: {
          query: stringSchema(1_024, 1),
          pageSize: integerSchema(1, 20, 5),
          pageToken: stringSchema(2_048),
        },
        required: ["query"],
        bodyTemplate: {
          textQuery: "arg:query",
          pageSize: "int:pageSize:5",
          pageToken: "arg:pageToken",
        },
      })],
    },
  },
  {
    authProfileId: "mixpanel-us-project-consumer",
    officialDocs: docs(
      "https://docs.mixpanel.com/reference/insights-query",
      "https://docs.mixpanel.com/reference/service-accounts",
    ),
    descriptor: {
      curatedId: "mixpanel",
      displayName: "Mixpanel Saved Insight (US)",
      description: "Read one configured saved Insights report with a project-scoped Consumer service account.",
      baseUrl: "https://mixpanel.com",
      auth: "basic",
      authParam: "username",
      credentialKey: "secret",
      credentialLabel: "Mixpanel service-account secret",
      extraConfig: [
        { key: "username", label: "Mixpanel service-account username", secret: true },
        { key: "project_id", label: "Mixpanel project ID", secret: false },
        { key: "bookmark_id", label: "Saved Insights report ID", secret: false },
      ],
      connectionSchema: connectionSchema({
        username: secretField(),
        secret: secretField(),
        project_id: idField(),
        bookmark_id: idField(),
      }),
      tools: [readOperation({
        name: "get_saved_insight",
        description: "Read a bounded projection of the configured saved Mixpanel Insights report; no custom JQL or filters.",
        method: "GET",
        path: "/api/query/insights?project_id={project_id}&bookmark_id={bookmark_id}",
        scope: "Consumer (project)",
      })],
    },
  },
  {
    authProfileId: "amplitude-us-analytics-read",
    officialDocs: docs(
      "https://amplitude.com/docs/apis/developer/analytics/list-charts",
      "https://amplitude.com/docs/developers/cli/authentication",
    ),
    descriptor: {
      curatedId: "amplitude",
      displayName: "Amplitude Charts (US)",
      description: "List saved chart metadata with an analytics:read PAT or OAuth token bound to the US region.",
      baseUrl: "https://developer-api.amplitude.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "Amplitude US PAT or OAuth token (analytics:read)",
      extraConfig: [{ key: "project_id", label: "Amplitude project ID", secret: false }],
      connectionSchema: connectionSchema({ access_token: secretField(), project_id: idField() }),
      tools: [readOperation({
        name: "list_charts",
        description: "List one bounded cursor page of saved Amplitude chart metadata without definitions or user details.",
        method: "GET",
        path: "/v1/projects/{project_id}/charts",
        scope: "analytics:read",
        properties: {
          limit: integerSchema(1, 50, 20),
          cursor: stringSchema(512),
        },
        queryArgMap: { limit: "limit:20", cursor: "cursor" },
        fixedQuery: { sort: "-updated_at" },
      })],
    },
  },
  {
    authProfileId: "posthog-us-insight-read",
    officialDocs: docs(
      "https://posthog.com/docs/api/insights",
      "https://posthog.com/docs/api/personal-api-keys",
    ),
    descriptor: {
      curatedId: "posthog",
      displayName: "PostHog Insights (US)",
      description: "List saved insight metadata with a project-scoped insight:read personal key on US Cloud.",
      baseUrl: "https://us.posthog.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "personal_api_key",
      credentialLabel: "PostHog personal API key (insight:read)",
      extraConfig: [{ key: "project_id", label: "PostHog project ID", secret: false }],
      connectionSchema: connectionSchema({ personal_api_key: secretField(), project_id: idField() }),
      tools: [readOperation({
        name: "list_insights",
        description: "List one bounded offset page of basic cached PostHog insight metadata without queries or user details.",
        method: "GET",
        path: "/api/projects/{project_id}/insights/",
        scope: "insight:read",
        properties: {
          limit: integerSchema(1, 50, 20),
          offset: integerSchema(0, 1_000, 0),
        },
        queryArgMap: { limit: "limit:20", offset: "offset:0" },
        fixedQuery: { basic: "true", refresh: "force_cache" },
      })],
    },
  },
  {
    authProfileId: "segment-us-source-readonly",
    officialDocs: docs(
      "https://docs.segmentapis.com/tag/Sources#operation/listSources",
      "https://segment.com/docs/segment-app/iam/roles",
      "https://docs.segmentapis.com/tag/Pagination",
    ),
    descriptor: {
      curatedId: "segment",
      displayName: "Segment Sources (US)",
      description: "List source metadata with a Business-plan Source read-only role; write keys are discarded.",
      baseUrl: "https://api.segmentapis.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "Segment US workspace token (Source read-only)",
      staticHeaders: { Accept: "application/vnd.segment.v1+json" },
      connectionSchema: connectionSchema({ access_token: secretField() }),
      tools: [readOperation({
        name: "list_sources",
        description: "List one bounded Segment source page without write keys, settings, or ingestion credentials.",
        method: "GET",
        path: "/sources",
        scope: "Source read-only",
        properties: {
          limit: integerSchema(1, 25, 10),
          cursor: stringSchema(2_048),
        },
        queryArgMap: { limit: "pagination.count:10", cursor: "pagination.cursor" },
      })],
    },
  },
  {
    authProfileId: "stripe-restricted-products-read",
    officialDocs: docs(
      "https://docs.stripe.com/api/products/list",
      "https://docs.stripe.com/api/versioning",
      "https://docs.stripe.com/keys/restricted-api-keys",
    ),
    descriptor: {
      curatedId: "stripe",
      displayName: "Stripe Products",
      description: "List product metadata with a Products:Read restricted key; no payment or financial writes exist.",
      baseUrl: "https://api.stripe.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "restricted_key",
      credentialLabel: "Stripe restricted key (Products: Read only)",
      staticHeaders: { "Stripe-Version": "2026-09-30.endive" },
      connectionSchema: connectionSchema({ restricted_key: secretField() }),
      tools: [readOperation({
        name: "list_products",
        description: "List one bounded cursor page of Stripe product metadata without catalog metadata or payment operations.",
        method: "GET",
        path: "/v1/products",
        scope: "Products: Read",
        properties: {
          limit: integerSchema(1, 100, 10),
          starting_after: stringSchema(255),
        },
        queryArgMap: { limit: "limit:10", starting_after: "starting_after" },
      })],
    },
  },
  {
    authProfileId: "docusign-esignature-userinfo-read",
    officialDocs: docs(
      "https://developers.docusign.com/platform/auth/reference/user-info/",
      "https://developers.docusign.com/docs/esign-rest-api/reference/envelopes/envelopes/liststatuschanges/",
    ),
    descriptor: {
      curatedId: "docusign",
      displayName: "DocuSign Envelopes",
      description: "List eSignature envelopes using OAuth UserInfo account discovery and a validated per-account API base URI.",
      baseUrl: "https://account.docusign.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "DocuSign OAuth access token (signature)",
      extraConfig: [{ key: "account_id", label: "DocuSign account ID from UserInfo", secret: false }],
      connectionSchema: connectionSchema({ access_token: secretField(), account_id: idField() }),
      tools: [readOperation({
        name: "list_envelopes",
        description: "List one bounded page of envelope metadata; no recipients, documents, sends, or drafts are exposed.",
        method: "GET",
        path: "/restapi/v2.1/accounts/{account_id}/envelopes",
        scope: "signature",
        properties: {
          from_date: stringSchema(40, 1),
          count: integerSchema(1, 100, 20),
          start_position: integerSchema(0, 10_000, 0),
        },
        required: ["from_date"],
        queryArgMap: { from_date: "from_date", count: "count:20", start_position: "start_position:0" },
      })],
    },
  },
  {
    authProfileId: "snowflake-rest-database-usage",
    officialDocs: docs(
      "https://docs.snowflake.com/en/developer-guide/snowflake-rest-api/reference/database",
      "https://docs.snowflake.com/en/developer-guide/snowflake-rest-api/authentication",
    ),
    descriptor: {
      curatedId: "snowflake",
      displayName: "Snowflake Databases",
      description: "List accessible database metadata through Snowflake REST API v2 without SQL execution or warehouse compute.",
      baseUrl: "{account_url}",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "Snowflake OAuth access token",
      extraConfig: [{ key: "account_url", label: "Snowflake account HTTPS origin", secret: false }],
      staticHeaders: {
        "X-Snowflake-Authorization-Token-Type": "OAUTH",
        Accept: "application/json",
        "User-Agent": "OvidSi/1.0 (data-search connector)",
      },
      connectionSchema: connectionSchema({ access_token: secretField(), account_url: stringSchema(2_048, 1) }),
      tools: [readOperation({
        name: "list_databases",
        description: "List accessible databases with showLimit and fromName only; history and SQL statements are not exposed.",
        method: "GET",
        path: "/api/v2/databases",
        scope: "USAGE (database)",
        properties: {
          showLimit: integerSchema(1, 50, 20),
          fromName: stringSchema(255),
        },
        queryArgMap: { showLimit: "showLimit:20", fromName: "fromName" },
        fixedQuery: { history: "false" },
      })],
    },
  },
  {
    authProfileId: "databricks-warehouse-read-scoped-pat-or-u2m",
    officialDocs: docs(
      "https://docs.databricks.com/api/workspace/warehouses/list",
      "https://docs.databricks.com/aws/en/dev-tools/auth/pat",
      "https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m",
    ),
    descriptor: {
      curatedId: "databricks",
      displayName: "Databricks SQL Warehouses",
      description: "List SQL warehouse metadata with a scoped PAT/workspace identity; U2M uses all-apis offline_access and needs separate least-privilege workspace permissions.",
      baseUrl: "{workspace_url}",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "Databricks scoped PAT (sql) or U2M token with equivalent warehouse-only permissions",
      extraConfig: [{ key: "workspace_url", label: "Databricks workspace HTTPS origin", secret: false }],
      connectionSchema: connectionSchema({ access_token: secretField(), workspace_url: stringSchema(2_048, 1) }),
      tools: [readOperation({
        name: "list_warehouses",
        description: "List one bounded page of accessible SQL warehouses; no start, stop, create, edit, or statement calls.",
        method: "GET",
        path: "/api/2.0/sql/warehouses",
        scope: "Scoped PAT: sql; U2M: all-apis offline_access plus warehouse-only workspace permissions",
        properties: {
          page_size: integerSchema(1, 50, 20),
          page_token: stringSchema(2_048),
        },
        queryArgMap: { page_size: "page_size:20", page_token: "page_token" },
      })],
    },
  },
  {
    authProfileId: "elasticsearch-named-index-read",
    officialDocs: docs(
      "https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-get",
      "https://www.elastic.co/docs/reference/elasticsearch/security-privileges",
    ),
    descriptor: {
      curatedId: "elasticsearch",
      displayName: "Elasticsearch Document",
      description: "Get one document from a configured named index using an expiring read-only ApiKey; no cluster search or writes.",
      baseUrl: "{instance_url}",
      auth: "apiKeyHeader",
      authHeader: "Authorization",
      authPrefix: "ApiKey ",
      credentialKey: "api_key",
      credentialLabel: "Elasticsearch read-only named-index ApiKey",
      extraConfig: [
        { key: "instance_url", label: "Elasticsearch HTTPS origin", secret: false },
        { key: "index", label: "Allowed index name", secret: false },
      ],
      connectionSchema: connectionSchema({
        api_key: secretField(), instance_url: stringSchema(2_048, 1), index: stringSchema(255, 1),
      }),
      tools: [readOperation({
        name: "get_document",
        description: "Get one document by ID from the authenticated named index; _source is bounded to 20 primitive fields.",
        method: "GET",
        path: "/{index}/_doc/{document_id}",
        scope: "read (named index)",
        properties: { document_id: stringSchema(256, 1) },
        required: ["document_id"],
      })],
    },
  },
  {
    authProfileId: "typesense-collection-get",
    officialDocs: docs(
      "https://typesense.org/docs/30.2/api/collections.html",
      "https://typesense.org/docs/30.2/api/api-keys.html",
    ),
    descriptor: {
      curatedId: "typesense",
      displayName: "Typesense Collection",
      description: "Read one named collection schema using a collections:get scoped key; no admin key, search body, or document writes.",
      baseUrl: "{instance_url}",
      auth: "apiKeyHeader",
      authHeader: "X-TYPESENSE-API-KEY",
      credentialKey: "api_key",
      credentialLabel: "Typesense collections:get scoped key",
      extraConfig: [
        { key: "instance_url", label: "Typesense HTTPS origin", secret: false },
        { key: "collection", label: "Allowed collection name", secret: false },
      ],
      connectionSchema: connectionSchema({
        api_key: secretField(), instance_url: stringSchema(2_048, 1), collection: stringSchema(255, 1),
      }),
      tools: [readOperation({
        name: "get_collection",
        description: "Read one configured collection schema with a bounded field projection.",
        method: "GET",
        path: "/collections/{collection}",
        scope: "collections:get (named collection)",
      })],
    },
  },
  {
    authProfileId: "serpapi-archive-endpoint-allowlisted-account-key",
    officialDocs: docs("https://serpapi.com/search-archive-api"),
    descriptor: {
      curatedId: "serpapi",
      displayName: "SerpApi Search Archive",
      description: "Retrieve an existing archived search with a separate full account key; only the connector archive endpoint is allowed, never fresh search.",
      baseUrl: "https://serpapi.com",
      auth: "queryKey",
      authParam: "api_key",
      credentialKey: "api_key",
      credentialLabel: "SerpApi separate account key (archive-only connector endpoint allowlist)",
      connectionSchema: connectionSchema({ api_key: secretField() }),
      tools: [readOperation({
        name: "get_archived_search",
        description: "Retrieve one archived result by its 24-character ID; required query-string auth stays in memory and is never emitted in results or errors.",
        method: "GET",
        path: "/searches/{search_id}.json",
        scope: "Dedicated full account key; archive-only connector endpoint allowlist",
        properties: { search_id: stringSchema(24, 24) },
        required: ["search_id"],
      })],
    },
  },
  {
    authProfileId: "algolia-secured-search-record-read",
    officialDocs: docs(
      "https://www.algolia.com/doc/rest-api/search/get-object",
      "https://www.algolia.com/doc/guides/security/api-keys/in-depth/api-key-restrictions",
    ),
    descriptor: {
      curatedId: "algolia",
      displayName: "Algolia Record",
      description: "Get one record using a secured search-only key restricted to the configured index; no Admin key or search writes.",
      baseUrl: "https://{app_id}-dsn.algolia.net",
      auth: "apiKeyHeader",
      authHeader: "X-Algolia-API-Key",
      credentialKey: "api_key",
      credentialLabel: "Algolia secured search-only API key",
      extraConfig: [
        { key: "app_id", label: "Algolia application ID", secret: false },
        { key: "index_name", label: "Allowed index name", secret: false },
      ],
      connectionSchema: connectionSchema({
        api_key: secretField(), app_id: stringSchema(63, 1), index_name: stringSchema(255, 1),
      }),
      tools: [readOperation({
        name: "get_object",
        description: "Get one object by ID with search ACL and a bounded primitive-field projection.",
        method: "GET",
        path: "/1/indexes/{index_name}/{object_id}",
        scope: "search",
        properties: { object_id: stringSchema(256, 1) },
        required: ["object_id"],
      })],
    },
  },
  {
    authProfileId: "metabase-agent-user-jwt-read",
    officialDocs: docs(
      "https://github.com/metabase/metabase/blob/master/src/metabase/agent_api/reference.md",
      "https://github.com/metabase/metabase/blob/master/src/metabase/agent_api/reference.md#authentication",
    ),
    descriptor: {
      curatedId: "metabase",
      displayName: "Metabase Semantic Discovery",
      description: "Search tables and metrics through Agent API v1 with a fresh user JWT and view-only permissions; native SQL is absent.",
      baseUrl: "{instance_url}",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "jwt",
      credentialLabel: "Metabase fresh user JWT (iat under 180 seconds)",
      extraConfig: [{ key: "instance_url", label: "Metabase HTTPS origin", secret: false }],
      connectionSchema: connectionSchema({ jwt: secretField(), instance_url: stringSchema(2_048, 1) }),
      tools: [readOperation({
        name: "search_semantic_resources",
        description: "Search semantic tables and metrics with one typed term query; no semantic execution, SQL, saved questions, or dashboards writes.",
        method: "POST",
        path: "/api/agent/v1/search",
        scope: "Agent API resource discovery (view-only user)",
        properties: { query: stringSchema(200, 1) },
        required: ["query"],
        bodyTemplate: { "term_queries.0": "arg:query" },
      })],
    },
  },
  {
    authProfileId: "superset-6-1-dashboard-read",
    officialDocs: docs(
      "https://superset.apache.org/developer-docs/6.1.0/api/get-a-list-of-dashboards",
      "https://superset.apache.org/admin-docs/security/",
    ),
    descriptor: {
      curatedId: "superset",
      displayName: "Superset Dashboards",
      description: "List dashboard metadata on Superset 6.1.0 using a user JWT/API key with Gamma and dashboard-only RBAC; SQL Lab is absent.",
      baseUrl: "{instance_url}",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "access_token",
      credentialLabel: "Superset user JWT or restricted API key",
      extraConfig: [{ key: "instance_url", label: "Superset HTTPS origin", secret: false }],
      connectionSchema: connectionSchema({ access_token: secretField(), instance_url: stringSchema(2_048, 1) }),
      tools: [readOperation({
        name: "list_dashboards",
        description: "List one bounded dashboard metadata page with a server-constructed Rison column/page query; no filters or SQL Lab.",
        method: "GET",
        path: "/api/v1/dashboard/",
        scope: "Dashboard read (Gamma + dashboard RBAC)",
        properties: {
          page: integerSchema(0, 100, 0),
          page_size: integerSchema(1, 25, 10),
        },
      })],
    },
  },
  {
    authProfileId: "paypal-orders-v2-dedicated-merchant-app",
    officialDocs: docs(
      "https://developer.paypal.com/api/rest/authentication",
      "https://developer.paypal.com/api/orders/v2/",
    ),
    descriptor: {
      curatedId: "paypal",
      displayName: "PayPal Order",
      description: "Read one Orders v2 resource with a request-scoped token from a dedicated per-connection merchant app; the token is not intrinsically read-only, so the connector allows only this GET.",
      baseUrl: "https://api-m.paypal.com",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "client_secret",
      credentialLabel: "PayPal dedicated merchant-app client secret",
      extraConfig: [{ key: "client_id", label: "PayPal dedicated merchant-app client ID", secret: true }],
      staticHeaders: { Accept: "application/json" },
      connectionSchema: connectionSchema({ client_id: secretField(), client_secret: secretField() }),
      tools: [readOperation({
        name: "get_order",
        description: "Get one order by ID with bounded amount/status fields; no capture, authorize, refund, payout, transfer, or invoice actions.",
        method: "GET",
        path: "/v2/checkout/orders/{order_id}",
        scope: "Orders v2 app/product entitlement plus connector GET-only allowlist",
        properties: { order_id: stringSchema(128, 1) },
        required: ["order_id"],
      })],
    },
  },
];

const PROVIDER_ORDER = [
  "docusign", "typeform", "calendly", "miro", "canva", "webflow",
  "snowflake", "bigquery", "databricks", "pinecone", "elasticsearch", "typesense",
  "brave-search", "tavily", "serpapi", "algolia", "google-maps", "mixpanel",
  "amplitude", "posthog", "segment", "metabase", "redash", "superset", "stripe", "paypal",
] as const;
const ORDERED_SPECS = [...SPECS].sort(
  (left, right) =>
    PROVIDER_ORDER.indexOf(left.descriptor.curatedId as typeof PROVIDER_ORDER[number]) -
    PROVIDER_ORDER.indexOf(right.descriptor.curatedId as typeof PROVIDER_ORDER[number]),
);

export const DATA_SEARCH_DESCRIPTORS: readonly RestServiceDescriptor[] = Object.freeze(
  ORDERED_SPECS.map((spec) => spec.descriptor),
);

function toProviderDefinition(spec: DataSearchSpec): ProviderDefinition {
  const operations: ProviderOperation[] = restToolDefs(spec.descriptor).map((operation) => ({
    name: operation.name,
    description: operation.description ?? operation.name,
    effect: operation.effect,
    approval: operation.approval,
    requiredScopes: operation.requiredScopes,
    inputSchema: operation.inputSchema ?? objectSchema({}),
    outputPolicy: operation.outputPolicy,
    request: operation.request,
    limits: operation.limits,
  }));
  const definition: ProviderDefinition = {
    providerId: spec.descriptor.curatedId,
    catalogVersion: CATALOG_VERSION,
    displayName: spec.descriptor.displayName,
    description: spec.descriptor.description,
    officialDocs: spec.officialDocs,
    authProfileId: spec.authProfileId,
    connectionSchema: spec.descriptor.connectionSchema ?? objectSchema({}),
    operations,
    readiness: "supported",
  };
  validateProviderDefinition(definition);
  return definition;
}

export const DATA_SEARCH_PROVIDERS: readonly ProviderDefinition[] = Object.freeze(
  ORDERED_SPECS.map(toProviderDefinition),
);

export const DATA_SEARCH_BLOCKED: readonly DataSearchBlockedCandidate[] = Object.freeze([
  {
    providerId: "redash",
    reason: "Blocked: the official endpoint list is incomplete V9-era material. A current complete version-specific cached-result API/auth contract and deployed-version compatibility review are still required; no descriptor is admitted.",
    officialDocs: docs(
      "https://redash.io/help/user-guide/integrations-and-api/api/",
      "https://redash.io/help/open-source/admin-guide/how-to-upgrade",
    ),
  },
]);
