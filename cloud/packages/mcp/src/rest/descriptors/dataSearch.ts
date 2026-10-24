/**
 * Verified-read candidates for documents, data, search, and finance.
 *
 * Only fixed-origin, least-privilege reads are defined here. SQL/job endpoints,
 * mutable financial APIs, arbitrary request bodies, dynamic tenant hosts, and
 * incomplete OAuth/token lifecycle profiles stay blocked below. Every response
 * is projected to a small allowlisted shape before it can reach a model.
 *
 * These are contract candidates, not live-readiness evidence. catalog.ts keeps
 * them out of CURATED_IDS/CURATED_MANIFEST until explicit live reads pass.
 */

import {
  createRestHandler,
  createSecretRedactor,
  restToolDefs,
  type ProviderDefinition,
  type ProviderOperation,
  type RestHandlerOptions,
  type RestServiceDescriptor,
  type RestToolDef,
  type SecretRedactor,
} from "../engine.js";
import { validateProviderDefinition } from "../../providers/types.js";

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
};

const TENANT_ID_RULES: Readonly<Record<string, Readonly<Record<string, RegExp>>>> = {
  bigquery: { project_id: /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/ },
  amplitude: { project_id: /^\d{1,20}$/ },
  posthog: { project_id: /^\d{1,20}$/ },
  mixpanel: { project_id: /^\d{1,20}$/, bookmark_id: /^\d{1,20}$/ },
};

function validateTenantConfig(providerId: string, config: Record<string, unknown>): void {
  for (const [key, rule] of Object.entries(TENANT_ID_RULES[providerId] ?? {})) {
    const value = config[key];
    if (value !== undefined && (typeof value !== "string" || !rule.test(value))) {
      throw new Error("Invalid tenant configuration.");
    }
  }
}

/** Uses the normal typed engine and adds only provider-specific output projection. */
export function createDataSearchHandler(
  descriptor: RestServiceDescriptor,
  options: RestHandlerOptions = {},
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
  const rest = createRestHandler(descriptor, { ...options, resolveConnectionConfig, redactor });
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
];

const PROVIDER_ORDER = [
  "typeform", "calendly", "miro", "canva", "webflow", "bigquery", "pinecone",
  "brave-search", "tavily", "google-maps", "mixpanel", "amplitude", "posthog", "segment", "stripe",
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
    providerId: "docusign",
    reason: "Blocked: requires OAuth/UserInfo discovery and rotating-token lifecycle plus a discovered per-account base URI; pasted tokens and a hardcoded demo host are not a production connector.",
    officialDocs: docs(
      "https://developers.docusign.com/platform/auth/reference/user-info/",
      "https://developers.docusign.com/docs/esign-rest-api/reference/envelopes/envelopes/liststatuschanges/",
    ),
  },
  {
    providerId: "snowflake",
    reason: "Blocked: a safe connector needs a single-statement SQL, bind, partition and warehouse-cost handler plus per-user OAuth/JWT and read-only role enforcement; arbitrary SQL and no-cost SELECT probes are not exported.",
    officialDocs: docs("https://docs.snowflake.com/en/developer-guide/sql-api/reference"),
  },
  {
    providerId: "databricks",
    reason: "Blocked: requires an OAuth/SQL policy, chunk and external-link handler with warehouse-cost controls and a restricted workspace origin; no generic statement endpoint is exposed.",
    officialDocs: docs("https://docs.databricks.com/api/statement-execution/v1/statement-execution"),
  },
  {
    providerId: "elasticsearch",
    reason: "Blocked: requires a deployment-pinned tenant origin and PIT-aware scoped-key handler with named-index privileges; generic cluster search and arbitrary hosts are not exposed.",
    officialDocs: docs("https://www.elastic.co/docs/api/doc/elasticsearch"),
  },
  {
    providerId: "typesense",
    reason: "Blocked: requires a restricted tenant origin and collection-scoped HMAC key handler with enforced tenant filters; admin keys and arbitrary cluster hosts are not accepted.",
    officialDocs: docs("https://typesense.org/docs/30.2/api/api-keys.html"),
  },
  {
    providerId: "serpapi",
    reason: "Blocked: secret-in-query handling; use brave-search or tavily for the supported web-search profile instead. The private key otherwise enters request URLs and needs engine-specific archive/redaction handling.",
    officialDocs: docs("https://serpapi.com/search-api"),
    replacements: ["brave-search", "tavily"],
  },
  {
    providerId: "algolia",
    reason: "Blocked: requires secured-key derivation, dual-auth headers and fallback-host handler with restrictIndices/tenant filters; an admin key or single generic POST is not exported.",
    officialDocs: docs("https://www.algolia.com/doc/rest-api/search/search-single-index"),
  },
  {
    providerId: "metabase",
    reason: "Blocked: requires a versioned Agent semantic-query/session handler and tenant origin with native SQL disabled; group-wide keys and arbitrary /api/dataset or execute-sql calls are not exported.",
    officialDocs: docs("https://www.metabase.com/docs/latest/api"),
  },
  {
    providerId: "redash",
    reason: "Blocked: requires a version-specific cached-result/Query API key handler and tenant origin; the official endpoint list remains incomplete and fresh query execution/arbitrary SQL is not exposed.",
    officialDocs: docs("https://redash.io/help/user-guide/integrations-and-api/api/"),
  },
  {
    providerId: "superset",
    reason: "Blocked: requires a JWT/Rison/RBAC handler and tenant origin pinned to a reviewed deployment; SQL Lab, arbitrary queries, and password login passthrough are not exported.",
    officialDocs: docs("https://superset.apache.org/developer-docs/6.1.0/api/"),
  },
  {
    providerId: "paypal",
    reason: "Blocked: client-credentials token lifecycle without a granular read-only scope is merchant/server-app rather than per-buyer auth; no shared-secret token cache or payment read is substituted.",
    officialDocs: docs("https://developer.paypal.com/api/rest/authentication"),
  },
]);
