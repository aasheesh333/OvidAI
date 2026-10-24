import { describe, expect, it } from "vitest";
import {
  DATA_SEARCH_BLOCKED,
  DATA_SEARCH_DESCRIPTORS,
  DATA_SEARCH_PROVIDERS,
} from "../../src/rest/descriptors/dataSearch.js";
import { CURATED_DESCRIPTORS } from "../../src/rest/descriptors/index.js";
import {
  CURATED_MANIFEST,
  DATA_SEARCH_CANDIDATE_MANIFEST,
} from "../../src/catalog.js";
import { restToolDefs } from "../../src/rest/engine.js";
import {
  validateProviderArgs,
  validateProviderDefinition,
  type ProviderDefinition,
} from "../../src/providers/types.js";

interface CandidateCase {
  id: string;
  supported: boolean;
  operation?: string;
  method?: "GET" | "POST";
  baseUrl?: string;
  path?: string;
  auth?: string;
  authProfileId?: string;
  scope?: string;
  doc?: string;
  blockReason?: string;
}

const CANDIDATES: readonly CandidateCase[] = [
  {
    id: "docusign",
    supported: false,
    blockReason: "OAuth/UserInfo discovery and rotating-token lifecycle",
    doc: "https://developers.docusign.com/platform/auth/reference/user-info/",
  },
  {
    id: "typeform",
    supported: true,
    operation: "list_forms",
    method: "GET",
    baseUrl: "https://api.typeform.com",
    path: "/forms",
    auth: "bearer",
    authProfileId: "typeform-us-forms-read",
    scope: "forms:read",
    doc: "https://www.typeform.com/developers/create/reference/retrieve-forms/",
  },
  {
    id: "calendly",
    supported: true,
    operation: "get_current_user",
    method: "GET",
    baseUrl: "https://api.calendly.com",
    path: "/users/me",
    auth: "bearer",
    authProfileId: "calendly-scoped-user-read",
    scope: "users:read",
    doc: "https://developer.calendly.com/docs/authentication/scopes",
  },
  {
    id: "miro",
    supported: true,
    operation: "list_boards",
    method: "GET",
    baseUrl: "https://api.miro.com",
    path: "/v2/boards",
    auth: "bearer",
    authProfileId: "miro-boards-read",
    scope: "boards:read",
    doc: "https://developers.miro.com/reference/get-boards-1",
  },
  {
    id: "canva",
    supported: true,
    operation: "list_designs",
    method: "GET",
    baseUrl: "https://api.canva.com",
    path: "/rest/v1/designs",
    auth: "bearer",
    authProfileId: "canva-design-meta-read",
    scope: "design:meta:read",
    doc: "https://www.canva.dev/docs/apps/rest-apis/reference/designs/list-designs/",
  },
  {
    id: "webflow",
    supported: true,
    operation: "list_sites",
    method: "GET",
    baseUrl: "https://api.webflow.com",
    path: "/v2/sites",
    auth: "bearer",
    authProfileId: "webflow-v2-sites-read",
    scope: "sites:read",
    doc: "https://developers.webflow.com/data/reference/sites/list",
  },
  {
    id: "snowflake",
    supported: false,
    blockReason: "single-statement SQL, bind, partition and warehouse-cost handler",
    doc: "https://docs.snowflake.com/en/developer-guide/sql-api/reference",
  },
  {
    id: "bigquery",
    supported: true,
    operation: "list_datasets",
    method: "GET",
    baseUrl: "https://bigquery.googleapis.com",
    path: "/bigquery/v2/projects/{project_id}/datasets",
    auth: "bearer",
    authProfileId: "bigquery-metadata-readonly",
    scope: "https://www.googleapis.com/auth/bigquery.readonly",
    doc: "https://docs.cloud.google.com/bigquery/docs/reference/rest/v2/datasets/list",
  },
  {
    id: "databricks",
    supported: false,
    blockReason: "OAuth/SQL policy, chunk and external-link handler",
    doc: "https://docs.databricks.com/api/statement-execution/v1/statement-execution",
  },
  {
    id: "pinecone",
    supported: true,
    operation: "list_indexes",
    method: "GET",
    baseUrl: "https://api.pinecone.io",
    path: "/indexes",
    auth: "apiKeyHeader",
    authProfileId: "pinecone-2026-07-control-plane-viewer",
    scope: "ControlPlaneViewer",
    doc: "https://docs.pinecone.io/reference/api/2026-07/control-plane/list_indexes",
  },
  {
    id: "elasticsearch",
    supported: false,
    blockReason: "deployment-pinned tenant origin and PIT-aware scoped-key handler",
    doc: "https://www.elastic.co/docs/api/doc/elasticsearch",
  },
  {
    id: "typesense",
    supported: false,
    blockReason: "tenant origin and collection-scoped HMAC key handler",
    doc: "https://typesense.org/docs/30.2/api/api-keys.html",
  },
  {
    id: "brave-search",
    supported: true,
    operation: "web_search",
    method: "GET",
    baseUrl: "https://api.search.brave.com/res",
    path: "/v1/web/search",
    auth: "apiKeyHeader",
    authProfileId: "brave-web-search-key",
    scope: "web-search",
    doc: "https://api-dashboard.search.brave.com/api-reference/web/search/get",
  },
  {
    id: "tavily",
    supported: true,
    operation: "search",
    method: "POST",
    baseUrl: "https://api.tavily.com",
    path: "/search",
    auth: "bearer",
    authProfileId: "tavily-basic-search-key",
    scope: "search:basic",
    doc: "https://docs.tavily.com/documentation/api-reference/endpoint/search",
  },
  {
    id: "serpapi",
    supported: false,
    blockReason: "secret-in-query handling; use brave-search or tavily",
    doc: "https://serpapi.com/search-api",
  },
  {
    id: "algolia",
    supported: false,
    blockReason: "secured-key derivation, dual-auth headers and fallback-host handler",
    doc: "https://www.algolia.com/doc/rest-api/search/search-single-index",
  },
  {
    id: "google-maps",
    supported: true,
    operation: "search_places",
    method: "POST",
    baseUrl: "https://places.googleapis.com",
    path: "/v1/places:searchText",
    auth: "apiKeyHeader",
    authProfileId: "google-places-new-id-only-key",
    scope: "Places API (New): Text Search Essentials ID Only",
    doc: "https://developers.google.com/maps/documentation/places/web-service/text-search",
  },
  {
    id: "mixpanel",
    supported: true,
    operation: "get_saved_insight",
    method: "GET",
    baseUrl: "https://mixpanel.com",
    path: "/api/query/insights?project_id={project_id}&bookmark_id={bookmark_id}",
    auth: "basic",
    authProfileId: "mixpanel-us-project-consumer",
    scope: "Consumer (project)",
    doc: "https://docs.mixpanel.com/reference/insights-query",
  },
  {
    id: "amplitude",
    supported: true,
    operation: "list_charts",
    method: "GET",
    baseUrl: "https://developer-api.amplitude.com",
    path: "/v1/projects/{project_id}/charts",
    auth: "bearer",
    authProfileId: "amplitude-us-analytics-read",
    scope: "analytics:read",
    doc: "https://amplitude.com/docs/apis/developer/analytics/list-charts",
  },
  {
    id: "posthog",
    supported: true,
    operation: "list_insights",
    method: "GET",
    baseUrl: "https://us.posthog.com",
    path: "/api/projects/{project_id}/insights/",
    auth: "bearer",
    authProfileId: "posthog-us-insight-read",
    scope: "insight:read",
    doc: "https://posthog.com/docs/api/insights",
  },
  {
    id: "segment",
    supported: true,
    operation: "list_sources",
    method: "GET",
    baseUrl: "https://api.segmentapis.com",
    path: "/sources",
    auth: "bearer",
    authProfileId: "segment-us-source-readonly",
    scope: "Source read-only",
    doc: "https://docs.segmentapis.com/tag/Sources#operation/listSources",
  },
  {
    id: "metabase",
    supported: false,
    blockReason: "versioned Agent semantic-query/session handler and tenant origin",
    doc: "https://www.metabase.com/docs/latest/api",
  },
  {
    id: "redash",
    supported: false,
    blockReason: "version-specific cached-result/Query API key handler and tenant origin",
    doc: "https://redash.io/help/user-guide/integrations-and-api/api/",
  },
  {
    id: "superset",
    supported: false,
    blockReason: "JWT/Rison/RBAC handler and tenant origin",
    doc: "https://superset.apache.org/developer-docs/6.1.0/api/",
  },
  {
    id: "stripe",
    supported: true,
    operation: "list_products",
    method: "GET",
    baseUrl: "https://api.stripe.com",
    path: "/v1/products",
    auth: "bearer",
    authProfileId: "stripe-restricted-products-read",
    scope: "Products: Read",
    doc: "https://docs.stripe.com/api/products/list",
  },
  {
    id: "paypal",
    supported: false,
    blockReason: "client-credentials token lifecycle without a granular read-only scope",
    doc: "https://developer.paypal.com/api/rest/authentication",
  },
];

const OUT_OF_BOUNDS: Readonly<Record<string, readonly Record<string, unknown>[]>> = {
  typeform: [{ page: 101 }, { page_size: 51 }],
  calendly: [],
  miro: [{ limit: 51 }, { offset: 9_951 }],
  canva: [{ limit: 101 }],
  webflow: [],
  pinecone: [],
  bigquery: [{ maxResults: 51 }],
  "brave-search": [{ count: 21 }, { offset: 3 }],
  tavily: [{ max_results: 11 }, { search_depth: "advanced" }],
  "google-maps": [{ pageSize: 21 }, { maxResultCount: 1 }],
  mixpanel: [],
  amplitude: [{ limit: 51 }],
  posthog: [{ limit: 51 }, { offset: 1_001 }],
  segment: [{ limit: 26 }],
  stripe: [{ limit: 101 }],
};

function provider(id: string): ProviderDefinition {
  const found = DATA_SEARCH_PROVIDERS.find((candidate) => candidate.providerId === id);
  if (found === undefined) throw new Error(`missing provider: ${id}`);
  return found;
}

describe("data/search per-candidate admission contract", () => {
  it("covers every assigned candidate exactly once", () => {
    expect(CANDIDATES.map((candidate) => candidate.id)).toEqual([
      "docusign", "typeform", "calendly", "miro", "canva", "webflow",
      "snowflake", "bigquery", "databricks", "pinecone", "elasticsearch", "typesense",
      "brave-search", "tavily", "serpapi", "algolia", "google-maps", "mixpanel",
      "amplitude", "posthog", "segment", "metabase", "redash", "superset", "stripe", "paypal",
    ]);
    expect(new Set(CANDIDATES.map((candidate) => candidate.id)).size).toBe(26);
  });

  it.each(CANDIDATES)("$id has the official operation/auth or an explicit block", (candidate) => {
    const definition = DATA_SEARCH_PROVIDERS.find((entry) => entry.providerId === candidate.id);
    const descriptor = DATA_SEARCH_DESCRIPTORS.find((entry) => entry.curatedId === candidate.id);
    const blocked = DATA_SEARCH_BLOCKED.find((entry) => entry.providerId === candidate.id);
    if (!candidate.supported) {
      expect(definition).toBeUndefined();
      expect(descriptor).toBeUndefined();
      expect(blocked?.reason).toContain(candidate.blockReason);
      expect(blocked?.officialDocs.some((doc) => doc.url === candidate.doc)).toBe(true);
      expect(blocked?.officialDocs.every((doc) => doc.verifiedAt === "2026-10-24")).toBe(true);
      return;
    }

    expect(blocked).toBeUndefined();
    expect(definition).toBeDefined();
    expect(descriptor).toBeDefined();
    expect(() => validateProviderDefinition(definition!)).not.toThrow();
    expect(definition!.catalogVersion).toBe("2026-10-24.1");
    expect(definition!.authProfileId).toBe(candidate.authProfileId);
    expect(definition!.officialDocs.some((doc) => doc.url === candidate.doc)).toBe(true);
    expect(definition!.officialDocs.every((doc) => doc.verifiedAt === "2026-10-24")).toBe(true);
    expect(definition!.readiness).toBe("supported");
    expect(definition!.connectionSchema.additionalProperties).toBe(false);
    expect(descriptor!.baseUrl).toBe(candidate.baseUrl);
    expect(descriptor!.baseUrl.startsWith("https://")).toBe(true);
    expect(descriptor!.baseUrl).not.toContain("{host");
    expect(descriptor!.baseUrl).not.toContain("{base");
    expect(descriptor!.auth).toBe(candidate.auth);

    expect(definition!.operations).toHaveLength(1);
    const operation = definition!.operations[0];
    expect(operation.name).toBe(candidate.operation);
    expect(operation.name).not.toMatch(/ping|health|validate|check/i);
    expect(operation.request).toEqual({
      originKey: candidate.id,
      method: candidate.method,
      pathTemplate: candidate.path,
    });
    expect(operation.requiredScopes).toEqual([candidate.scope]);
    expect(operation.effect).toBe("read");
    expect(operation.approval).toBe("mode");
    expect(operation.outputPolicy.kind).toBe("redacted_json");
    expect(operation.outputPolicy.maxBytes).toBe(65_536);
    expect(operation.limits.timeoutMs).toBeLessThanOrEqual(30_000);
    expect(operation.limits.responseBytes).toBeLessThanOrEqual(65_536);
    expect(operation.limits.frameBytes).toBeLessThanOrEqual(65_536);
    expect(operation.limits.pageBytes).toBeLessThanOrEqual(65_536);
    expect(operation.inputSchema.additionalProperties).toBe(false);
    expect(restToolDefs(descriptor!)).toEqual([expect.objectContaining(operation)]);
  });

  it.each(CANDIDATES.filter((candidate) => candidate.supported))(
    "$id closes query/job/body inputs and bounds timeout cost",
    (candidate) => {
      const operation = provider(candidate.id).operations[0];
      for (const args of [
        { unexpected: true },
        { sql: "SELECT 1" },
        { query: { arbitrary: true } },
        { body: {} },
        { job: {} },
        { webhook: "https://evil.invalid" },
        { timeout_seconds: 301 },
        ...(OUT_OF_BOUNDS[candidate.id] ?? []),
      ]) {
        expect(validateProviderArgs(operation.inputSchema, args).ok, JSON.stringify(args)).toBe(false);
      }
    },
  );

  it("pins the exact reviewed dated Stripe-Version and official versioning evidence", () => {
    const descriptor = DATA_SEARCH_DESCRIPTORS.find((entry) => entry.curatedId === "stripe")!;
    expect(descriptor.staticHeaders?.["Stripe-Version"]).toBe("2026-09-30.endive");
    expect(provider("stripe").officialDocs.map((doc) => doc.url)).toContain(
      "https://docs.stripe.com/api/versioning",
    );
  });

  it("keeps contract candidates out of the production catalog until live evidence exists", () => {
    const candidateIds = new Set(CANDIDATES.map((candidate) => candidate.id));
    const supportedIds = CANDIDATES.filter((candidate) => candidate.supported).map((candidate) => candidate.id);
    expect(DATA_SEARCH_CANDIDATE_MANIFEST.map((entry) => entry.curatedId)).toEqual(supportedIds);
    expect(DATA_SEARCH_PROVIDERS.map((entry) => entry.providerId)).toEqual(supportedIds);
    expect(CURATED_MANIFEST.some((entry) => candidateIds.has(entry.curatedId))).toBe(false);
    expect(CURATED_DESCRIPTORS.some((entry) => candidateIds.has(entry.curatedId))).toBe(false);
  });
});
