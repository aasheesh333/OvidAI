import { describe, expect, it } from "vitest";
import { DATA_SEARCH_DESCRIPTORS, createDataSearchHandler } from "./dataSearch.js";
import type { EgressRequest, ProviderEgress } from "../../egress/responseLimits.js";
import type { RestServiceDescriptor } from "../engine.js";
import type { McpCallContext } from "../../transports/native.js";

const TOKEN_A = "fixture-gap-token-A";
const TOKEN_B = "other-tenant-token-B";

interface ExpectedRequest {
  originPath: string;
  method: "GET" | "POST";
  query?: Record<string, string>;
  headers?: Record<string, string>;
  body?: unknown;
}

interface GapCase {
  id: string;
  operation: string;
  credentialKey: string;
  secrets: Record<string, string>;
  args: Record<string, unknown>;
  origins: string[];
  requests: ExpectedRequest[];
  responses: unknown[];
  expected: unknown;
  echoPath: (string | number)[];
}

const DOCUSIGN_ACCOUNT = "11111111-1111-1111-1111-111111111111";
const SERPAPI_SEARCH_ID = "5b50d58a304bda2fca30bac9";

const ALL_GAP_CASES: GapCase[] = [
  {
    id: "docusign",
    operation: "list_envelopes",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A, account_id: DOCUSIGN_ACCOUNT },
    args: { from_date: "2026-01-01T00:00:00Z", count: 1, start_position: 0 },
    origins: ["https://account.docusign.com", "https://na4.docusign.net"],
    requests: [
      {
        originPath: "https://account.docusign.com/oauth/userinfo",
        method: "GET",
        headers: { Authorization: `Bearer ${TOKEN_A}` },
      },
      {
        originPath: `https://na4.docusign.net/restapi/v2.1/accounts/${DOCUSIGN_ACCOUNT}/envelopes`,
        method: "GET",
        query: { from_date: "2026-01-01T00:00:00Z", count: "1", start_position: "0" },
        headers: { Authorization: `Bearer ${TOKEN_A}` },
      },
    ],
    responses: [
      {
        sub: "user-1",
        email: "private@example.invalid",
        accounts: [{ account_id: DOCUSIGN_ACCOUNT, is_default: true, account_name: "Fixture", base_uri: "https://na4.docusign.net" }],
      },
      {
        resultSetSize: "1", totalSetSize: "2", startPosition: "0", endPosition: "0",
        envelopes: [{ envelopeId: "env-1", status: "sent", emailSubject: "Fixture envelope", createdDateTime: "2026-01-01T00:00:00Z", sentDateTime: "2026-01-02T00:00:00Z", statusChangedDateTime: "2026-01-02T00:00:00Z", recipients: { signers: [{ email: "private@example.invalid" }] } }],
        nextUri: "/private-next-link",
      },
    ],
    expected: {
      resultSetSize: "1", totalSetSize: "2", startPosition: "0", endPosition: "0",
      envelopes: [{ envelopeId: "env-1", status: "sent", emailSubject: "Fixture envelope", createdDateTime: "2026-01-01T00:00:00Z", sentDateTime: "2026-01-02T00:00:00Z", statusChangedDateTime: "2026-01-02T00:00:00Z" }],
    },
    echoPath: ["envelopes", 0, "emailSubject"],
  },
  {
    id: "snowflake",
    operation: "list_databases",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A, account_url: "https://acct-1.snowflakecomputing.com" },
    args: { showLimit: 1, fromName: "A" },
    origins: ["https://acct-1.snowflakecomputing.com"],
    requests: [{
      originPath: "https://acct-1.snowflakecomputing.com/api/v2/databases",
      method: "GET",
      query: { showLimit: "1", fromName: "A", history: "false" },
      headers: {
        Authorization: `Bearer ${TOKEN_A}`,
        "X-Snowflake-Authorization-Token-Type": "OAUTH",
        Accept: "application/json",
        "User-Agent": "OvidSi/1.0 (data-search connector)",
      },
    }],
    responses: [[{ name: "DB1", kind: "STANDARD", created_on: "2026-01-01T00:00:00Z", retention_time: 1, owner: "PRIVATE_ROLE" }]],
    expected: { databases: [{ name: "DB1", kind: "STANDARD", created_on: "2026-01-01T00:00:00Z", retention_time: 1 }], total: 1, truncated: false },
    echoPath: [0, "name"],
  },
  {
    id: "databricks",
    operation: "list_warehouses",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A, workspace_url: "https://workspace.cloud.databricks.com" },
    args: { page_size: 1, page_token: "cursor-1" },
    origins: ["https://workspace.cloud.databricks.com"],
    requests: [{
      originPath: "https://workspace.cloud.databricks.com/api/2.0/sql/warehouses",
      method: "GET",
      query: { page_size: "1", page_token: "cursor-1" },
      headers: { Authorization: `Bearer ${TOKEN_A}` },
    }],
    responses: [{ warehouses: [{ id: "wh1", name: "Fixture warehouse", cluster_size: "2X-Small", warehouse_type: "PRO", state: "STOPPED", num_clusters: 0, jdbc_url: "private" }], next_page_token: "next-cursor" }],
    expected: { warehouses: [{ id: "wh1", name: "Fixture warehouse", cluster_size: "2X-Small", warehouse_type: "PRO", state: "STOPPED", num_clusters: 0 }], next_cursor: "next-cursor" },
    echoPath: ["warehouses", 0, "name"],
  },
  {
    id: "elasticsearch",
    operation: "get_document",
    credentialKey: "api_key",
    secrets: { api_key: TOKEN_A, instance_url: "https://search.example.com", index: "fixture-index" },
    args: { document_id: "doc1" },
    origins: ["https://search.example.com"],
    requests: [{
      originPath: "https://search.example.com/fixture-index/_doc/doc1",
      method: "GET",
      headers: { Authorization: `ApiKey ${TOKEN_A}` },
    }],
    responses: [{ _index: "fixture-index", _id: "doc1", found: true, _version: 1, _seq_no: 2, _primary_term: 1, _source: { title: "Fixture document", count: 2, private_notes: "drop", nested: { secret: "drop" } } }],
    expected: { _index: "fixture-index", _id: "doc1", found: true, _version: 1, _seq_no: 2, _primary_term: 1, _source: { title: "Fixture document", count: 2 } },
    echoPath: ["_source", "title"],
  },
  {
    id: "typesense",
    operation: "get_collection",
    credentialKey: "api_key",
    secrets: { api_key: TOKEN_A, instance_url: "https://search.example.com", collection: "fixture-collection" },
    args: {},
    origins: ["https://search.example.com"],
    requests: [{
      originPath: "https://search.example.com/collections/fixture-collection",
      method: "GET",
      headers: { "X-TYPESENSE-API-KEY": TOKEN_A },
    }],
    responses: [{ name: "fixture-collection", num_documents: 1, fields: [{ name: "title", type: "string", facet: false, index: true, sort: false, optional: true, reference: "drop" }], enable_nested_fields: false, default_sorting_field: "private" }],
    expected: { name: "fixture-collection", num_documents: 1, fields: [{ name: "title", type: "string", facet: false, index: true, sort: false, optional: true }], enable_nested_fields: false },
    echoPath: ["name"],
  },
  {
    id: "serpapi",
    operation: "get_archived_search",
    credentialKey: "api_key",
    secrets: { api_key: TOKEN_A },
    args: { search_id: SERPAPI_SEARCH_ID },
    origins: ["https://serpapi.com"],
    requests: [{
      originPath: `https://serpapi.com/searches/${SERPAPI_SEARCH_ID}.json`,
      method: "GET",
      query: { api_key: TOKEN_A },
    }],
    responses: [{
      search_metadata: { id: SERPAPI_SEARCH_ID, status: "Success", created_at: "2026-01-01T00:00:00Z", processed_at: "2026-01-02T00:00:00Z", total_time_taken: 1.2, raw_json_url: `https://serpapi.com/searches/${SERPAPI_SEARCH_ID}.json?api_key=secret` },
      search_parameters: { engine: "google", q: "private query" },
      organic_results: [{ position: 1, title: "Fixture result", link: "https://example.invalid/result", snippet: "Fixture snippet", date: "2026-01-01" }],
      related_questions: [{ question: "drop" }],
    }],
    expected: {
      search_metadata: { id: SERPAPI_SEARCH_ID, status: "Success", created_at: "2026-01-01T00:00:00Z", processed_at: "2026-01-02T00:00:00Z", total_time_taken: 1.2 },
      organic_results: [{ position: 1, title: "Fixture result", link: "https://example.invalid/result", snippet: "Fixture snippet", date: "2026-01-01" }],
    },
    echoPath: ["organic_results", 0, "title"],
  },
  {
    id: "algolia",
    operation: "get_object",
    credentialKey: "api_key",
    secrets: { api_key: TOKEN_A, app_id: "fixture-app", index_name: "fixture-index" },
    args: { object_id: "obj1" },
    origins: ["https://fixture-app-dsn.algolia.net"],
    requests: [{
      originPath: "https://fixture-app-dsn.algolia.net/1/indexes/fixture-index/obj1",
      method: "GET",
      headers: { "X-Algolia-API-Key": TOKEN_A, "X-Algolia-Application-Id": "fixture-app" },
    }],
    responses: [{ objectID: "obj1", title: "Fixture record", price: 10, nested: { private: "drop" }, api_key: "drop" }],
    expected: { objectID: "obj1", title: "Fixture record", price: 10 },
    echoPath: ["title"],
  },
  {
    id: "metabase",
    operation: "search_semantic_resources",
    credentialKey: "jwt",
    secrets: { jwt: TOKEN_A, instance_url: "https://bi.example.com" },
    args: { query: "orders" },
    origins: ["https://bi.example.com"],
    requests: [{
      originPath: "https://bi.example.com/api/agent/v1/search",
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN_A}`, "content-type": "application/json" },
      body: { term_queries: ["orders"] },
    }],
    responses: [{ data: [{ type: "table", id: 42, name: "ORDERS", display_name: "Orders", description: "Fixture table", database_id: 1, database_schema: "PUBLIC", verified: true, query: "DROP TABLE" }], total_count: 1 }],
    expected: { data: [{ type: "table", id: 42, name: "ORDERS", display_name: "Orders", description: "Fixture table", database_id: 1, database_schema: "PUBLIC", verified: true }], total_count: 1 },
    echoPath: ["data", 0, "display_name"],
  },
  {
    id: "redash",
    operation: "get_cached_query_result",
    credentialKey: "api_key",
    secrets: { api_key: TOKEN_A, instance_url: "https://bi.example.com", query_id: "7" },
    args: {},
    origins: ["https://bi.example.com"],
    requests: [{
      originPath: "https://bi.example.com/api/queries/7/results",
      method: "GET",
      headers: { Authorization: `Key ${TOKEN_A}` },
    }],
    responses: [{ query_result: { id: 7, retrieved_at: "2026-01-02T00:00:00Z", query: "SELECT private", data: { columns: [{ name: "title", type: "string", friendly_name: "Title" }], rows: [{ title: "Fixture row", count: 2, private: "drop" }] } } }],
    expected: { query_result: { id: 7, retrieved_at: "2026-01-02T00:00:00Z", data: { columns: [{ name: "title", type: "string" }], rows: [{ title: "Fixture row", count: 2 }] } } },
    echoPath: ["query_result", "data", "rows", 0, "title"],
  },
  {
    id: "superset",
    operation: "list_dashboards",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A, instance_url: "https://bi.example.com" },
    args: { page: 0, page_size: 1 },
    origins: ["https://bi.example.com"],
    requests: [{
      originPath: "https://bi.example.com/api/v1/dashboard/",
      method: "GET",
      query: { q: "(columns:!(id,dashboard_title,slug,status,changed_on),page:0,page_size:1)" },
      headers: { Authorization: `Bearer ${TOKEN_A}` },
    }],
    responses: [{ count: 1, ids: [1], result: [{ id: 1, dashboard_title: "Fixture dashboard", slug: "fixture", status: "published", changed_on: "2026-01-02T00:00:00Z", json_metadata: "private" }] }],
    expected: { count: 1, ids: [1], result: [{ id: 1, dashboard_title: "Fixture dashboard", slug: "fixture", status: "published", changed_on: "2026-01-02T00:00:00Z" }] },
    echoPath: ["result", 0, "dashboard_title"],
  },
  {
    id: "paypal",
    operation: "get_order",
    credentialKey: "client_secret",
    secrets: { client_id: "fixture-client", client_secret: TOKEN_A },
    args: { order_id: "ORDER-123" },
    origins: ["https://api-m.paypal.com"],
    requests: [
      {
        originPath: "https://api-m.paypal.com/v1/oauth2/token",
        method: "POST",
        headers: { Authorization: `Basic ${Buffer.from(`fixture-client:${TOKEN_A}`).toString("base64")}`, "content-type": "application/x-www-form-urlencoded", Accept: "application/json" },
        body: "grant_type=client_credentials",
      },
      {
        originPath: "https://api-m.paypal.com/v2/checkout/orders/ORDER-123",
        method: "GET",
        headers: { Authorization: "Bearer paypal-request-token", Accept: "application/json" },
      },
    ],
    responses: [
      { access_token: "paypal-request-token", token_type: "Bearer", expires_in: 300, scope: "https://uri.paypal.com/services/payments/payment" },
      { id: "ORDER-123", intent: "CAPTURE", status: "COMPLETED", create_time: "2026-01-01T00:00:00Z", update_time: "2026-01-02T00:00:00Z", purchase_units: [{ reference_id: "ref1", amount: { currency_code: "USD", value: "1.00" }, payee: { email_address: "private@example.invalid" } }], payer: { email_address: "private@example.invalid" }, links: [{ href: "private" }] },
    ],
    expected: { id: "ORDER-123", intent: "CAPTURE", status: "COMPLETED", create_time: "2026-01-01T00:00:00Z", update_time: "2026-01-02T00:00:00Z", purchase_units: [{ reference_id: "ref1", amount: { currency_code: "USD", value: "1.00" } }] },
    echoPath: ["purchase_units", 0, "amount", "value"],
  },
];

// Redash remains blocked until a current complete version-specific contract
// and deployed-version compatibility review exists; no descriptor is callable.
const CASES = ALL_GAP_CASES.filter((candidate) => candidate.id !== "redash");

function descriptor(id: string): RestServiceDescriptor {
  const found = DATA_SEARCH_DESCRIPTORS.find((candidate) => candidate.curatedId === id);
  if (found === undefined) throw new Error(`Missing descriptor: ${id}`);
  return found;
}

function ctx(secrets: Record<string, string>, signal?: AbortSignal): McpCallContext {
  return {
    uid: "gap-fixture-user",
    secrets,
    workspace: {},
    fetchImpl: async () => { throw new Error("legacy fetch is forbidden"); },
    mode: "auto",
    planMode: false,
    unattended: false,
    ...(signal === undefined ? {} : { signal }),
  } as McpCallContext;
}

function setPath(root: any, path: (string | number)[], value: string): void {
  let current = root;
  for (const key of path.slice(0, -1)) current = current[key];
  current[path[path.length - 1]] = value;
}

function jsonResponse(payload: unknown, origin: string) {
  return {
    status: 200,
    headers: new Headers({ "content-type": "application/json" }),
    body: new Response(JSON.stringify(payload)).body!,
    origin: new URL(origin),
    remoteAddress: "192.0.2.20",
  };
}

describe("descriptor gap official reads, output projection, and tenant isolation", () => {
  it.each(CASES)(
    "UNEXECUTED (heavy pause): valid $id uses a complete ProviderOperation and shared context to reach its intended read",
    async (fixture) => {
      const requests: EgressRequest[] = [];
      let resolutions = 0;
      let responseIndex = 0;
      const result = await createDataSearchHandler(descriptor(fixture.id), {
        resolveConnectionConfig: async () => { resolutions++; return fixture.secrets; },
        egressFactory: () => ({
          async request(request) {
            requests.push(request);
            const response = fixture.responses[responseIndex] ?? fixture.responses[fixture.responses.length - 1];
            responseIndex++;
            return jsonResponse(response, request.url.origin);
          },
          async close() {},
        }),
      }).callTool(fixture.operation, fixture.args, ctx(fixture.secrets));
      expect(result.isError, result.text).toBe(false);
      expect(result.text).not.toBe("Provider operation failed or connection configuration was invalid.");
      expect(JSON.parse(result.text)).toEqual(fixture.expected);
      expect(resolutions).toBe(1);
      expect(requests.map((request) => request.url.origin + request.url.pathname)).toEqual(
        fixture.requests.map((request) => request.originPath),
      );
    },
  );

  it.each(CASES)("$id executes only its reviewed request chain", async (fixture) => {
    const requests: EgressRequest[] = [];
    const allowedOrigins: string[] = [];
    let closes = 0;
    let responseIndex = 0;
    let currentResponses = fixture.responses;
    const egressFactory = (origins: Readonly<Record<string, readonly URL[]>>): ProviderEgress => {
      for (const urls of Object.values(origins)) for (const url of urls) allowedOrigins.push(url.origin);
      return {
        async request(request) {
          requests.push(request);
          const response = currentResponses[responseIndex] ?? currentResponses[currentResponses.length - 1];
          responseIndex++;
          return jsonResponse(response, request.url.origin);
        },
        async close() { closes++; },
      };
    };
    const handler = createDataSearchHandler(descriptor(fixture.id), { egressFactory });
    const first = await handler.callTool(fixture.operation, fixture.args, ctx(fixture.secrets));
    expect(first.isError, first.text).toBe(false);
    expect(JSON.parse(first.text)).toEqual(fixture.expected);
    expect(allowedOrigins).toEqual(fixture.origins);
    expect(requests).toHaveLength(fixture.requests.length);
    fixture.requests.forEach((expected, index) => {
      const actual = requests[index];
      expect(actual.url.origin + actual.url.pathname).toBe(expected.originPath);
      expect(actual.method).toBe(expected.method);
      expect(Object.fromEntries(actual.url.searchParams)).toEqual(expected.query ?? {});
      expect(actual.headers).toMatchObject(expected.headers ?? {});
      if (expected.body === undefined) expect(actual.body).toBeUndefined();
      else if (typeof expected.body === "string") expect(new TextDecoder().decode(actual.body)).toBe(expected.body);
      else expect(JSON.parse(new TextDecoder().decode(actual.body))).toEqual(expected.body);
    });

    const leaked = structuredClone(fixture.responses);
    setPath(leaked[leaked.length - 1], fixture.echoPath, TOKEN_B);
    responseIndex = 0;
    currentResponses = leaked;
    const secondSecrets = { ...fixture.secrets, [fixture.credentialKey]: TOKEN_B };
    const second = await handler.callTool(fixture.operation, fixture.args, ctx(secondSecrets));
    expect(second.isError, second.text).toBe(false);
    expect(second.text).not.toContain(TOKEN_A);
    expect(second.text).not.toContain(TOKEN_B);
    expect(second.text).toContain("[REDACTED]");
    expect(requests.slice(-fixture.requests.length).every((request) => !request.secretValues?.includes(TOKEN_A))).toBe(true);
    expect(closes).toBeGreaterThanOrEqual(fixture.origins.length * 2);
  });

  it.each(CASES)("$id rejects arbitrary SQL/GraphQL/body/job/webhook and transport overrides before config", async (fixture) => {
    for (const args of [
      { sql: "SELECT * FROM private_table" },
      { query: { sql: "SELECT * FROM private_table" } },
      { graphql: "query { viewer { id } }" },
      { body: { arbitrary: true } },
      { job: { arbitrary: true } },
      { webhook: "https://evil.invalid" },
      { baseUrl: "https://evil.invalid" },
      { host: "evil.invalid" },
      { url: "https://evil.invalid" },
      { headers: { authorization: "attacker" } },
    ]) {
      let resolutions = 0;
      let factories = 0;
      const result = await createDataSearchHandler(descriptor(fixture.id), {
        resolveConnectionConfig: async () => { resolutions++; return fixture.secrets; },
        egressFactory: () => { factories++; throw new Error("must not create egress"); },
      }).callTool(fixture.operation, args, ctx({}));
      expect(result.isError, `${fixture.id}: ${JSON.stringify(args)}`).toBe(true);
      expect(resolutions, `${fixture.id}: ${JSON.stringify(args)}`).toBe(0);
      expect(factories, `${fixture.id}: ${JSON.stringify(args)}`).toBe(0);
    }
  });

  it.each([
    ["snowflake", { account_url: "https://evil.invalid" }],
    ["databricks", { workspace_url: "http://workspace.cloud.databricks.com" }],
    ["elasticsearch", { instance_url: "https://127.0.0.1" }],
    ["typesense", { instance_url: "https://localhost" }],
    ["algolia", { app_id: "fixture-app.algolia.net.attacker.invalid" }],
    ["metabase", { instance_url: "https://user:pass@bi.example.com" }],
    ["superset", { instance_url: "http://bi.example.com" }],
  ] as const)("rejects a bad tenant binding before egress: %s", async (id, patch) => {
    const fixture = CASES.find((candidate) => candidate.id === id)!;
    let factories = 0;
    const result = await createDataSearchHandler(descriptor(id), {
      egressFactory: () => { factories++; throw new Error("must not create egress"); },
    }).callTool(fixture.operation, fixture.args, ctx({ ...fixture.secrets, ...patch }));
    expect(result.isError).toBe(true);
    expect(factories).toBe(0);
  });

  it.each([
    ["serpapi", { search_id: "../admin" }],
    ["algolia", { object_id: "../settings" }],
    ["elasticsearch", { document_id: "../_cluster/state" }],
    ["paypal", { order_id: "../captures" }],
  ] as const)("rejects path traversal before credential resolution: %s", async (id, args) => {
    const fixture = CASES.find((candidate) => candidate.id === id)!;
    let resolutions = 0;
    const result = await createDataSearchHandler(descriptor(id), {
      resolveConnectionConfig: async () => { resolutions++; return fixture.secrets; },
      egressFactory: () => { throw new Error("must not create egress"); },
    }).callTool(fixture.operation, args, ctx({}));
    expect(result.isError).toBe(true);
    expect(resolutions).toBe(0);
  });

  it.each([
    ["docusign", { account_id: "../other-account" }],
    ["elasticsearch", { index: "../_cluster" }],
    ["typesense", { collection: "../documents" }],
    ["algolia", { index_name: "../settings" }],
  ] as const)("rejects a malicious configured resource before any egress: %s", async (id, patch) => {
    const fixture = CASES.find((candidate) => candidate.id === id)!;
    let factories = 0;
    const result = await createDataSearchHandler(descriptor(id), {
      egressFactory: () => { factories++; throw new Error("must not create egress"); },
    }).callTool(fixture.operation, fixture.args, ctx({ ...fixture.secrets, ...patch }));
    expect(result.isError).toBe(true);
    expect(factories).toBe(0);
  });

  it("accepts an official uppercase Algolia application ID while normalizing only the DNS host", async () => {
    const fixture = CASES.find((candidate) => candidate.id === "algolia")!;
    const requests: EgressRequest[] = [];
    const result = await createDataSearchHandler(descriptor("algolia"), {
      egressFactory: () => ({
        async request(request) {
          requests.push(request);
          return jsonResponse(fixture.responses[0], request.url.origin);
        },
        async close() {},
      }),
    }).callTool(fixture.operation, fixture.args, ctx({ ...fixture.secrets, app_id: "ABC123XYZ" }));
    expect(result.isError, result.text).toBe(false);
    expect(requests).toHaveLength(1);
    expect(requests[0].url.origin).toBe("https://abc123xyz-dsn.algolia.net");
    expect(requests[0].headers["X-Algolia-Application-Id"]).toBe("ABC123XYZ");
  });

  it.each([
    ["elasticsearch", { document_id: " " }],
    ["algolia", { object_id: " " }],
    ["metabase", { query: " " }],
    ["paypal", { order_id: " " }],
    ["docusign", { from_date: " ", count: 1, start_position: 0 }],
  ] as const)("UNEXECUTED (heavy pause): rejects blank required input before any config or auth work: %s", async (id, args) => {
    const fixture = CASES.find((candidate) => candidate.id === id)!;
    let resolutions = 0;
    let factories = 0;
    let requests = 0;
    const result = await createDataSearchHandler(descriptor(id), {
      resolveConnectionConfig: async () => { resolutions++; return fixture.secrets; },
      egressFactory: () => { factories++; throw new Error("must not create egress"); },
    }).callTool(fixture.operation, args, {
      ...ctx({}),
      fetchImpl: async () => { requests++; throw new Error("must not fetch"); },
    });
    expect(result.isError).toBe(true);
    expect(resolutions).toBe(0);
    expect(factories).toBe(0);
    expect(requests).toBe(0);
  });

  it.each(["elasticsearch", "algolia", "metabase", "paypal", "docusign"] as const)(
    "UNEXECUTED (heavy pause): pre-cancelled %s performs no config, discovery, exchange, or read",
    async (id) => {
      const fixture = CASES.find((candidate) => candidate.id === id)!;
      const controller = new AbortController();
      controller.abort("fixture-cancelled");
      let resolutions = 0;
      let factories = 0;
      let requests = 0;
      const result = await createDataSearchHandler(descriptor(id), {
        resolveConnectionConfig: async () => { resolutions++; return fixture.secrets; },
        egressFactory: () => { factories++; throw new Error("must not create egress"); },
      }).callTool(fixture.operation, fixture.args, {
        ...ctx({}, controller.signal),
        fetchImpl: async () => { requests++; throw new Error("must not fetch"); },
      });
      expect(result.isError).toBe(true);
      expect(result.text).toBe("Operation denied (cancelled).");
      expect(resolutions).toBe(0);
      expect(factories).toBe(0);
      expect(requests).toBe(0);
    },
  );

  it.each(CASES)(
    "UNEXECUTED (heavy pause): pre-cancelled valid $id performs no config or auxiliary auth/read",
    async (fixture) => {
      const controller = new AbortController();
      controller.abort("fixture-cancelled-before-preflight");
      let resolutions = 0;
      let factories = 0;
      let requests = 0;
      const result = await createDataSearchHandler(descriptor(fixture.id), {
        resolveConnectionConfig: async () => { resolutions++; return fixture.secrets; },
        egressFactory: () => { factories++; throw new Error("must not create egress"); },
      }).callTool(fixture.operation, fixture.args, {
        ...ctx({}, controller.signal),
        fetchImpl: async () => { requests++; throw new Error("must not fetch"); },
      });
      expect(result.isError).toBe(true);
      expect(result.text).toBe("Operation denied (cancelled).");
      expect(resolutions).toBe(0);
      expect(factories).toBe(0);
      expect(requests).toBe(0);
    },
  );

  it.each(CASES)(
    "UNEXECUTED (heavy pause): invalid $id arguments perform no config or auxiliary auth/read",
    async (fixture) => {
      let resolutions = 0;
      let factories = 0;
      let requests = 0;
      const result = await createDataSearchHandler(descriptor(fixture.id), {
        resolveConnectionConfig: async () => { resolutions++; return fixture.secrets; },
        egressFactory: () => { factories++; throw new Error("must not create egress"); },
      }).callTool(fixture.operation, { sql: "SELECT * FROM private_table" }, {
        ...ctx({}),
        fetchImpl: async () => { requests++; throw new Error("must not fetch"); },
      });
      expect(result.isError).toBe(true);
      expect(resolutions).toBe(0);
      expect(factories).toBe(0);
      expect(requests).toBe(0);
    },
  );

  it.each(["docusign", "paypal"] as const)(
    "UNEXECUTED (heavy pause): cancellation during config resolution prevents %s auxiliary authentication",
    async (id) => {
      const fixture = CASES.find((candidate) => candidate.id === id)!;
      const controller = new AbortController();
      let factories = 0;
      let requests = 0;
      const result = await createDataSearchHandler(descriptor(id), {
        resolveConnectionConfig: async () => {
          controller.abort("fixture-cancelled-during-config");
          return fixture.secrets;
        },
        egressFactory: () => { factories++; throw new Error("must not create egress"); },
      }).callTool(fixture.operation, fixture.args, {
        ...ctx({}, controller.signal),
        fetchImpl: async () => { requests++; throw new Error("must not fetch"); },
      });
      expect(result.isError).toBe(true);
      expect(result.text).toBe("Operation denied (cancelled).");
      expect(factories).toBe(0);
      expect(requests).toBe(0);
    },
  );

  it("UNEXECUTED (heavy pause): DocuSign abort during UserInfo prevents a second tenant egress and account read", async () => {
    const fixture = CASES.find((candidate) => candidate.id === "docusign")!;
    const controller = new AbortController();
    let factories = 0;
    const requests: EgressRequest[] = [];
    const result = await createDataSearchHandler(descriptor("docusign"), {
      egressFactory: () => {
        factories++;
        return {
          async request(request) {
            requests.push(request);
            controller.abort("fixture-cancelled-in-userinfo");
            expect(request.signal?.aborted).toBe(true);
            return jsonResponse(fixture.responses[0], request.url.origin);
          },
          async close() {},
        };
      },
    }).callTool(fixture.operation, fixture.args, ctx(fixture.secrets, controller.signal));
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Operation denied (cancelled).");
    expect(requests).toHaveLength(1);
    expect(requests[0].url.pathname).toBe("/oauth/userinfo");
    expect(factories).toBe(1);
  });

  it("UNEXECUTED (heavy pause): PayPal abort during token exchange prevents the order read", async () => {
    const fixture = CASES.find((candidate) => candidate.id === "paypal")!;
    const controller = new AbortController();
    const requests: EgressRequest[] = [];
    const result = await createDataSearchHandler(descriptor("paypal"), {
      egressFactory: () => ({
        async request(request) {
          requests.push(request);
          controller.abort("fixture-cancelled-in-token-exchange");
          expect(request.signal?.aborted).toBe(true);
          return jsonResponse(fixture.responses[0], request.url.origin);
        },
        async close() {},
      }),
    }).callTool(fixture.operation, fixture.args, ctx(fixture.secrets, controller.signal));
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Operation denied (cancelled).");
    expect(requests).toHaveLength(1);
    expect(requests[0].url.pathname).toBe("/v1/oauth2/token");
  });

  it("UNEXECUTED (heavy pause): Superset caps both ids and dashboard projections at 25", async () => {
    const fixture = CASES.find((candidate) => candidate.id === "superset")!;
    const response = {
      count: 40,
      ids: Array.from({ length: 40 }, (_, index) => index + 1),
      result: Array.from({ length: 40 }, (_, index) => ({
        id: index + 1,
        dashboard_title: `Dashboard ${index + 1}`,
        slug: `dashboard-${index + 1}`,
        status: "published",
        changed_on: "2026-01-02T00:00:00Z",
      })),
    };
    const result = await createDataSearchHandler(descriptor("superset"), {
      egressFactory: () => ({
        async request(request) {
          return jsonResponse(response, request.url.origin);
        },
        async close() {},
      }),
    }).callTool(fixture.operation, fixture.args, ctx(fixture.secrets));
    expect(result.isError, result.text).toBe(false);
    const projected = JSON.parse(result.text) as { ids: number[]; result: unknown[]; ids_truncated?: boolean; truncated?: boolean };
    expect(projected.ids).toHaveLength(25);
    expect(projected.result).toHaveLength(25);
    expect(projected.ids_truncated).toBe(true);
    expect(projected.truncated).toBe(true);
  });

  it("rejects an unexpected DocuSign UserInfo base URI before the account API call", async () => {
    const fixture = CASES.find((candidate) => candidate.id === "docusign")!;
    const requests: EgressRequest[] = [];
    const result = await createDataSearchHandler(descriptor("docusign"), {
      egressFactory: () => ({
        async request(request) {
          requests.push(request);
          return jsonResponse({ accounts: [{ account_id: DOCUSIGN_ACCOUNT, base_uri: "https://evil.invalid" }] }, request.url.origin);
        },
        async close() {},
      }),
    }).callTool(fixture.operation, fixture.args, ctx(fixture.secrets));
    expect(result.isError).toBe(true);
    expect(requests).toHaveLength(1);
    expect(requests[0].url.origin).toBe("https://account.docusign.com");
  });
});
