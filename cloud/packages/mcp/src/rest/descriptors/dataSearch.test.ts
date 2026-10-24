import { describe, expect, it } from "vitest";
import {
  DATA_SEARCH_DESCRIPTORS,
  createDataSearchHandler,
} from "./dataSearch.js";
import type { RestServiceDescriptor } from "../engine.js";
import type { McpCallContext } from "../../transports/native.js";
import type { GuardedFetch } from "../../ssrf.js";

const TOKEN_A = "fixture-token-A";
const TOKEN_B = "other-user-token-B";

interface ExecutionCase {
  id: string;
  operation: string;
  credentialKey: string;
  secrets: Record<string, string>;
  args: Record<string, unknown>;
  originPath: string;
  query?: Record<string, string>;
  headers?: Record<string, string>;
  body?: Record<string, unknown>;
  response: Record<string, unknown>;
  expected: Record<string, unknown>;
  echoPath: readonly (string | number)[];
}

const CASES: readonly ExecutionCase[] = [
  {
    id: "typeform",
    operation: "list_forms",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A },
    args: { search: "road map", page: 2, page_size: 1 },
    originPath: "https://api.typeform.com/forms",
    query: { search: "road map", page: "2", page_size: "1" },
    headers: { Authorization: `Bearer ${TOKEN_A}` },
    response: {
      total_items: 2,
      page_count: 2,
      items: [{
        id: "form-1",
        title: "Fixture form",
        created_at: "2026-01-01T00:00:00Z",
        last_updated_at: "2026-01-02T00:00:00Z",
        settings: { is_public: false },
        _links: { responses: "https://api.typeform.eu/forms/form-1/responses" },
      }],
      access_token: "must-not-leak",
    },
    expected: {
      total_items: 2,
      page_count: 2,
      items: [{
        id: "form-1",
        title: "Fixture form",
        created_at: "2026-01-01T00:00:00Z",
        last_updated_at: "2026-01-02T00:00:00Z",
        settings: { is_public: false },
      }],
    },
    echoPath: ["items", 0, "title"],
  },
  {
    id: "calendly",
    operation: "get_current_user",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A },
    args: {},
    originPath: "https://api.calendly.com/users/me",
    headers: { Authorization: `Bearer ${TOKEN_A}` },
    response: {
      resource: {
        uri: "https://api.calendly.com/users/fixture-user",
        name: "Fixture User",
        slug: "fixture-user",
        email: "private@example.invalid",
        scheduling_url: "https://calendly.com/fixture-user",
        timezone: "Etc/UTC",
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-02T00:00:00Z",
      },
    },
    expected: {
      resource: {
        uri: "https://api.calendly.com/users/fixture-user",
        name: "Fixture User",
        slug: "fixture-user",
        timezone: "Etc/UTC",
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-02T00:00:00Z",
      },
    },
    echoPath: ["resource", "name"],
  },
  {
    id: "miro",
    operation: "list_boards",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A },
    args: { query: "planning", limit: 1, offset: 0 },
    originPath: "https://api.miro.com/v2/boards",
    query: { query: "planning", limit: "1", offset: "0" },
    headers: { Authorization: `Bearer ${TOKEN_A}` },
    response: {
      data: [{
        id: "board-1",
        name: "Fixture board",
        description: "private board notes",
        createdAt: "2026-01-01T00:00:00Z",
        modifiedAt: "2026-01-02T00:00:00Z",
        type: "board",
        viewLink: "https://miro.com/app/board/board-1/",
        policy: { permissionsPolicy: {} },
      }],
      total: 1,
      size: 1,
      offset: 0,
      limit: 1,
    },
    expected: {
      data: [{
        id: "board-1",
        name: "Fixture board",
        createdAt: "2026-01-01T00:00:00Z",
        modifiedAt: "2026-01-02T00:00:00Z",
        type: "board",
      }],
      total: 1,
      size: 1,
      offset: 0,
      limit: 1,
    },
    echoPath: ["data", 0, "name"],
  },
  {
    id: "canva",
    operation: "list_designs",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A },
    args: { query: "report", limit: 1, continuation: "cursor-1" },
    originPath: "https://api.canva.com/rest/v1/designs",
    query: { query: "report", limit: "1", continuation: "cursor-1" },
    headers: { Authorization: `Bearer ${TOKEN_A}` },
    response: {
      items: [{
        id: "design-1",
        title: "Fixture design",
        created_at: 1,
        updated_at: 2,
        page_count: 3,
        design_types: ["doc"],
        owner: { user_id: "private-user", team_id: "private-team" },
        thumbnail: { url: "https://document-export.canva.com/signed-thumbnail" },
        urls: { edit_url: "https://www.canva.com/api/design/signed-edit" },
      }],
      continuation: "next-cursor",
    },
    expected: {
      items: [{
        id: "design-1",
        title: "Fixture design",
        created_at: 1,
        updated_at: 2,
        page_count: 3,
        design_types: ["doc"],
      }],
      continuation: "next-cursor",
    },
    echoPath: ["items", 0, "title"],
  },
  {
    id: "webflow",
    operation: "list_sites",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A },
    args: {},
    originPath: "https://api.webflow.com/v2/sites",
    headers: { Authorization: `Bearer ${TOKEN_A}` },
    response: {
      sites: [{
        id: "site-1",
        workspaceId: "workspace-1",
        displayName: "Fixture site",
        shortName: "fixture-site",
        lastPublished: "2026-01-02T00:00:00Z",
        lastUpdated: "2026-01-03T00:00:00Z",
        previewUrl: "https://dev-assets.website-files.com/private-preview",
        customDomains: [{ url: "private.example" }],
      }],
    },
    expected: {
      sites: [{
        id: "site-1",
        workspaceId: "workspace-1",
        displayName: "Fixture site",
        shortName: "fixture-site",
        lastPublished: "2026-01-02T00:00:00Z",
        lastUpdated: "2026-01-03T00:00:00Z",
      }],
      total: 1,
      truncated: false,
    },
    echoPath: ["sites", 0, "displayName"],
  },
  {
    id: "pinecone",
    operation: "list_indexes",
    credentialKey: "api_key",
    secrets: { api_key: TOKEN_A },
    args: {},
    originPath: "https://api.pinecone.io/indexes",
    headers: { "Api-Key": TOKEN_A, "X-Pinecone-Api-Version": "2026-07" },
    response: {
      indexes: [{
        name: "fixture-index",
        host: "fixture-index.svc.us-east1-gcp.pinecone.io",
        status: { ready: true, state: "Ready" },
        deployment: { deployment_type: "managed", cloud: "gcp", region: "us-east1" },
        schema: { fields: { secret_schema: {} } },
        deletion_protection: "disabled",
      }],
    },
    expected: {
      indexes: [{
        name: "fixture-index",
        host: "fixture-index.svc.us-east1-gcp.pinecone.io",
        status: { ready: true, state: "Ready" },
        deployment: { deployment_type: "managed", cloud: "gcp", region: "us-east1" },
      }],
      total: 1,
      truncated: false,
    },
    echoPath: ["indexes", 0, "name"],
  },
  {
    id: "bigquery",
    operation: "list_datasets",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A, project_id: "fixture-project" },
    args: { maxResults: 1, pageToken: "page-1" },
    originPath: "https://bigquery.googleapis.com/bigquery/v2/projects/fixture-project/datasets",
    query: { maxResults: "1", pageToken: "page-1" },
    headers: { Authorization: `Bearer ${TOKEN_A}` },
    response: {
      datasets: [{
        datasetReference: { projectId: "fixture-project", datasetId: "fixture_dataset" },
        friendlyName: "Fixture dataset",
        location: "US",
        access: [{ role: "OWNER", userByEmail: "private@example.invalid" }],
      }],
      nextPageToken: "next-page",
    },
    expected: {
      datasets: [{
        datasetReference: { projectId: "[REDACTED]", datasetId: "fixture_dataset" },
        friendlyName: "Fixture dataset",
        location: "US",
      }],
      next_cursor: "next-page",
    },
    echoPath: ["datasets", 0, "friendlyName"],
  },
  {
    id: "brave-search",
    operation: "web_search",
    credentialKey: "api_key",
    secrets: { api_key: TOKEN_A },
    args: { query: "Ovid Si", count: 1, offset: 0 },
    originPath: "https://api.search.brave.com/res/v1/web/search",
    query: {
      q: "Ovid Si",
      count: "1",
      offset: "0",
      result_filter: "web",
      safesearch: "moderate",
      text_decorations: "false",
    },
    headers: { "X-Subscription-Token": TOKEN_A, Accept: "application/json" },
    response: {
      query: { original: "Ovid Si", altered: "Ovid Si", show_strict_warning: false },
      web: {
        results: [{
          title: "Fixture result",
          url: "https://example.invalid/result",
          description: "Fixture snippet",
          page_age: "2026-01-01",
          thumbnail: { src: "https://example.invalid/private-image" },
        }],
      },
      videos: { results: [{ title: "not requested" }] },
    },
    expected: {
      query: { original: "Ovid Si", altered: "Ovid Si", show_strict_warning: false },
      web: {
        results: [{
          title: "Fixture result",
          url: "https://example.invalid/result",
          description: "Fixture snippet",
          page_age: "2026-01-01",
        }],
      },
    },
    echoPath: ["web", "results", 0, "title"],
  },
  {
    id: "tavily",
    operation: "search",
    credentialKey: "api_key",
    secrets: { api_key: TOKEN_A },
    args: { query: "Ovid Si", max_results: 1 },
    originPath: "https://api.tavily.com/search",
    headers: { Authorization: `Bearer ${TOKEN_A}`, "content-type": "application/json" },
    body: {
      query: "Ovid Si",
      max_results: 1,
      search_depth: "basic",
      chunks_per_source: 1,
      include_answer: false,
      include_raw_content: false,
      include_images: false,
    },
    response: {
      query: "Ovid Si",
      results: [{
        title: "Fixture result",
        url: "https://example.invalid/result",
        content: "Fixture snippet",
        score: 0.5,
        raw_content: "large raw page",
      }],
      response_time: 0.25,
      request_id: "request-1",
      answer: "unrequested answer",
      images: ["https://example.invalid/unrequested-image"],
    },
    expected: {
      query: "Ovid Si",
      results: [{
        title: "Fixture result",
        url: "https://example.invalid/result",
        content: "Fixture snippet",
        score: 0.5,
      }],
      response_time: 0.25,
      request_id: "request-1",
    },
    echoPath: ["results", 0, "title"],
  },
  {
    id: "google-maps",
    operation: "search_places",
    credentialKey: "api_key",
    secrets: { api_key: TOKEN_A },
    args: { query: "Eiffel Tower", pageSize: 1, pageToken: "page-1" },
    originPath: "https://places.googleapis.com/v1/places:searchText",
    headers: {
      "X-Goog-Api-Key": TOKEN_A,
      "X-Goog-FieldMask": "places.id,nextPageToken",
      "content-type": "application/json",
    },
    body: { textQuery: "Eiffel Tower", pageSize: 1, pageToken: "page-1" },
    response: {
      places: [{
        id: "place-1",
        displayName: { text: "must not be requested" },
        formattedAddress: "must not be requested",
      }],
      nextPageToken: "next-page",
    },
    expected: { places: [{ id: "place-1" }], next_cursor: "next-page" },
    echoPath: ["places", 0, "id"],
  },
  {
    id: "mixpanel",
    operation: "get_saved_insight",
    credentialKey: "secret",
    secrets: {
      username: "fixture-service-account",
      secret: TOKEN_A,
      project_id: "12345",
      bookmark_id: "67890",
    },
    args: {},
    originPath: "https://mixpanel.com/api/query/insights",
    query: { project_id: "12345", bookmark_id: "67890" },
    headers: { Authorization: `Basic ${Buffer.from(`fixture-service-account:${TOKEN_A}`).toString("base64")}` },
    response: {
      computed_at: "2026-01-03T00:00:00Z",
      date_range: { from_date: "2026-01-01", to_date: "2026-01-02" },
      headers: ["$event"],
      series: {
        "Viewed page": { "2026-01-01": 10, "2026-01-02": 12 },
      },
    },
    expected: {
      computed_at: "2026-01-03T00:00:00Z",
      date_range: { from_date: "2026-01-01", to_date: "2026-01-02" },
      headers: ["$event"],
      series: { "Viewed page": { "2026-01-01": 10, "2026-01-02": 12 } },
      truncated: false,
    },
    echoPath: ["headers", 0],
  },
  {
    id: "amplitude",
    operation: "list_charts",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A, project_id: "12345" },
    args: { limit: 1, cursor: "0" },
    originPath: "https://developer-api.amplitude.com/v1/projects/12345/charts",
    query: { limit: "1", cursor: "0", sort: "-updated_at" },
    headers: { Authorization: `Bearer ${TOKEN_A}` },
    response: {
      data: [{
        id: "chart-1",
        object: "chart",
        project_id: "12345",
        name: "Fixture chart",
        chart_type: "event_segmentation",
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-02T00:00:00Z",
        archived: false,
        created_by: "private@example.invalid",
        url: "https://amplitude.com/private-chart",
      }],
      pagination: { next_cursor: "1", has_more: true },
    },
    expected: {
      data: [{
        id: "chart-1",
        object: "chart",
        project_id: "[REDACTED]",
        name: "Fixture chart",
        chart_type: "event_segmentation",
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-02T00:00:00Z",
        archived: false,
      }],
      pagination: { next_cursor: "1", has_more: true },
    },
    echoPath: ["data", 0, "name"],
  },
  {
    id: "posthog",
    operation: "list_insights",
    credentialKey: "personal_api_key",
    secrets: { personal_api_key: TOKEN_A, project_id: "12345" },
    args: { limit: 1, offset: 0 },
    originPath: "https://us.posthog.com/api/projects/12345/insights/",
    query: { limit: "1", offset: "0", basic: "true", refresh: "force_cache" },
    headers: { Authorization: `Bearer ${TOKEN_A}` },
    response: {
      count: 2,
      next: "https://us.posthog.com/api/projects/12345/insights/?offset=1&limit=1",
      results: [{
        id: 1,
        short_id: "insight-1",
        name: "Fixture insight",
        created_at: "2026-01-01T00:00:00Z",
        last_modified_at: "2026-01-02T00:00:00Z",
        created_by: { email: "private@example.invalid" },
        query: { source: { hogql: "SELECT private_query" } },
      }],
    },
    expected: {
      count: 2,
      has_next: true,
      results: [{
        id: 1,
        short_id: "insight-1",
        name: "Fixture insight",
        created_at: "2026-01-01T00:00:00Z",
        last_modified_at: "2026-01-02T00:00:00Z",
      }],
    },
    echoPath: ["results", 0, "name"],
  },
  {
    id: "segment",
    operation: "list_sources",
    credentialKey: "access_token",
    secrets: { access_token: TOKEN_A },
    args: { limit: 1, cursor: "cursor-1" },
    originPath: "https://api.segmentapis.com/sources",
    query: { "pagination.count": "1", "pagination.cursor": "cursor-1" },
    headers: { Authorization: `Bearer ${TOKEN_A}`, Accept: "application/vnd.segment.v1+json" },
    response: {
      data: {
        sources: [{
          id: "source-1",
          slug: "fixture-source",
          name: "Fixture source",
          workspaceId: "workspace-1",
          enabled: true,
          writeKeys: ["must-never-leak"],
          settings: { apiHost: "private.segment.build" },
        }],
        pagination: { current: "cursor-1", next: "cursor-2", previous: null, totalEntries: 2 },
      },
    },
    expected: {
      data: {
        sources: [{
          id: "source-1",
          slug: "fixture-source",
          name: "Fixture source",
          workspaceId: "workspace-1",
          enabled: true,
        }],
        pagination: { current: "cursor-1", next: "cursor-2", previous: null, totalEntries: 2 },
      },
    },
    echoPath: ["data", "sources", 0, "name"],
  },
  {
    id: "stripe",
    operation: "list_products",
    credentialKey: "restricted_key",
    secrets: { restricted_key: TOKEN_A },
    args: { limit: 1, starting_after: "prod_previous" },
    originPath: "https://api.stripe.com/v1/products",
    query: { limit: "1", starting_after: "prod_previous" },
    headers: { Authorization: `Bearer ${TOKEN_A}`, "Stripe-Version": "2026-09-30.endive" },
    response: {
      object: "list",
      has_more: true,
      data: [{
        id: "prod_1",
        object: "product",
        active: true,
        created: 1,
        updated: 2,
        name: "Fixture product",
        livemode: false,
        description: "private catalog notes",
        metadata: { private: "value" },
      }],
      url: "/v1/products",
    },
    expected: {
      object: "list",
      has_more: true,
      data: [{
        id: "prod_1",
        object: "product",
        active: true,
        created: 1,
        updated: 2,
        name: "Fixture product",
        livemode: false,
      }],
    },
    echoPath: ["data", 0, "name"],
  },
];

function descriptor(id: string): RestServiceDescriptor {
  const found = DATA_SEARCH_DESCRIPTORS.find((candidate) => candidate.curatedId === id);
  if (found === undefined) throw new Error(`missing descriptor: ${id}`);
  return found;
}

function context(
  secrets: Record<string, string>,
  fetchImpl: GuardedFetch,
): McpCallContext {
  return {
    uid: "fixture-user",
    secrets,
    workspace: {},
    fetchImpl,
    mode: "auto",
    planMode: false,
    unattended: false,
  } as McpCallContext;
}

function setPath(root: Record<string, unknown>, path: readonly (string | number)[], value: string): void {
  let current: unknown = root;
  for (let index = 0; index < path.length - 1; index++) {
    const key = path[index];
    current = (current as Record<string | number, unknown>)[key];
  }
  const leaf = path[path.length - 1];
  (current as Record<string | number, unknown>)[leaf] = value;
}

describe("data/search official request and sanitized response fixtures", () => {
  it.each(CASES)("$id executes the documented read and isolates per-user secrets", async (fixture) => {
    const calls: Array<{ url: string; init?: RequestInit }> = [];
    let currentResponse = fixture.response;
    const fetchImpl: GuardedFetch = async (url, init) => {
      calls.push({ url, init });
      return new Response(JSON.stringify(currentResponse), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };
    const handler = createDataSearchHandler(descriptor(fixture.id));
    const first = await handler.callTool(
      fixture.operation,
      fixture.args,
      context(fixture.secrets, fetchImpl),
    );
    expect(first.isError, first.text).toBe(false);
    expect(JSON.parse(first.text)).toEqual(fixture.expected);
    expect(calls).toHaveLength(1);
    const url = new URL(calls[0].url);
    expect(url.origin + url.pathname).toBe(fixture.originPath);
    expect(Object.fromEntries(url.searchParams)).toEqual(fixture.query ?? {});
    expect(calls[0].init?.method).toBe(fixture.id === "tavily" || fixture.id === "google-maps" ? "POST" : "GET");
    expect(calls[0].init?.headers ?? {}).toMatchObject(fixture.headers ?? {});
    if (fixture.body === undefined) expect(calls[0].init?.body).toBeUndefined();
    else expect(JSON.parse(calls[0].init?.body as string)).toEqual(fixture.body);

    const leaked = structuredClone(fixture.response);
    setPath(leaked, fixture.echoPath, TOKEN_B);
    currentResponse = leaked;
    const secondSecrets = { ...fixture.secrets, [fixture.credentialKey]: TOKEN_B };
    const second = await handler.callTool(
      fixture.operation,
      fixture.args,
      context(secondSecrets, fetchImpl),
    );
    expect(second.isError, second.text).toBe(false);
    expect(second.text).not.toContain(TOKEN_A);
    expect(second.text).not.toContain(TOKEN_B);
    expect(second.text).toContain("[REDACTED]");
    expect(calls).toHaveLength(2);
  });

  it.each(CASES)("$id rejects SQL, GraphQL, body, webhook, transport and tenant overrides before config resolution", async (fixture) => {
    const attempts: Record<string, unknown>[] = [
      { sql: "SELECT * FROM private_table" },
      { query: { sql: "SELECT * FROM private_table" } },
      { graphql: "query { viewer { id } }" },
      { body: { arbitrary: true } },
      { webhook: "https://evil.invalid" },
      { job: { arbitrary: true } },
      { baseUrl: "https://evil.invalid" },
      { host: "evil.invalid" },
      { url: "https://evil.invalid" },
      { headers: { authorization: "attacker" } },
    ];
    for (const args of attempts) {
      let resolutions = 0;
      let fetches = 0;
      const result = await createDataSearchHandler(descriptor(fixture.id), {
        resolveConnectionConfig: async () => {
          resolutions++;
          return fixture.secrets;
        },
      }).callTool(fixture.operation, args, context(fixture.secrets, async () => {
        fetches++;
        return new Response("{}", { status: 200 });
      }));
      expect(result.isError, `${fixture.id}: ${JSON.stringify(args)}`).toBe(true);
      expect(resolutions, `${fixture.id}: ${JSON.stringify(args)}`).toBe(0);
      expect(fetches, `${fixture.id}: ${JSON.stringify(args)}`).toBe(0);
    }
  });

  it.each([
    { name: "75 words", query: Array.from({ length: 75 }, (_, index) => `w${index}`).join(" "), accepted: true },
    { name: "76 words", query: Array.from({ length: 76 }, (_, index) => `w${index}`).join(" "), accepted: false },
    {
      name: "75 words with bounded mixed whitespace",
      query: ` \t${Array.from({ length: 75 }, (_, index) => `w${index}`).join(" \n\t")} \n`,
      accepted: true,
    },
    {
      name: "76 words with bounded mixed whitespace",
      query: ` \t${Array.from({ length: 76 }, (_, index) => `w${index}`).join(" \n\t")} \n`,
      accepted: false,
    },
    { name: "600 characters", query: "a".repeat(600), accepted: true },
    { name: "601 characters", query: "a".repeat(601), accepted: false },
  ])("enforces Brave character and word bounds before credentials: $name", async ({ query, accepted }) => {
    const fixture = CASES.find((candidate) => candidate.id === "brave-search")!;
    let resolutions = 0;
    const calls: string[] = [];
    const result = await createDataSearchHandler(descriptor("brave-search"), {
      resolveConnectionConfig: async () => {
        resolutions++;
        return { api_key: TOKEN_A };
      },
    }).callTool("web_search", { query }, context({ api_key: TOKEN_A }, async (url) => {
      calls.push(url);
      return new Response(JSON.stringify(fixture.response), { status: 200 });
    }));
    expect(result.isError, result.text).toBe(!accepted);
    expect(resolutions).toBe(accepted ? 1 : 0);
    expect(calls).toHaveLength(accepted ? 1 : 0);
    if (accepted) expect(new URL(calls[0]).searchParams.get("q")).toBe(query);
  });

  it("rejects a lookalike descriptor that reuses a canonical id with a different origin", () => {
    const forged: RestServiceDescriptor = {
      ...descriptor("stripe"),
      baseUrl: "https://evil.invalid",
    };
    expect(() => createDataSearchHandler(forged)).toThrow(/canonical descriptor/i);
  });

  it("accepts a large official page when its allowlisted projection fits the final tool cap", async () => {
    const response = {
      total_items: 20,
      page_count: 1,
      items: Array.from({ length: 20 }, (_, index) => ({
        id: `form-${index}`,
        title: `Form ${index}`,
        settings: { is_public: false },
        private_notes: `private-${index}-${"x".repeat(1_000)}`,
      })),
    };
    expect(Buffer.byteLength(JSON.stringify(response), "utf8")).toBeGreaterThan(8_192);
    const result = await createDataSearchHandler(descriptor("typeform")).callTool(
      "list_forms",
      { page: 1, page_size: 20 },
      context({ access_token: TOKEN_A }, async () => new Response(JSON.stringify(response), { status: 200 })),
    );
    expect(result.isError, result.text).toBe(false);
    const projected = JSON.parse(result.text) as { items: Array<Record<string, unknown>> };
    expect(projected.items).toHaveLength(20);
    expect(projected.items.every((item) => item.private_notes === undefined)).toBe(true);
    expect(Buffer.byteLength(result.text, "utf8")).toBeLessThan(8_192);
  });

  it.each([
    { id: "bigquery", patch: { project_id: "../other-project" } },
    { id: "amplitude", patch: { project_id: "123/other" } },
    { id: "posthog", patch: { project_id: "123/other" } },
    { id: "mixpanel", patch: { project_id: "12345&admin=true" } },
    { id: "mixpanel", patch: { bookmark_id: "67890&admin=true" } },
  ] as Array<{ id: string; patch: Record<string, string> }>)("rejects malformed authenticated tenant config for $id before fetching", async ({ id, patch }) => {
    const fixture = CASES.find((candidate) => candidate.id === id)!;
    let fetches = 0;
    const result = await createDataSearchHandler(descriptor(id)).callTool(
      fixture.operation,
      fixture.args,
      context({ ...fixture.secrets, ...patch }, async () => {
        fetches++;
        return new Response(JSON.stringify(fixture.response), { status: 200 });
      }),
    );
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Invalid connection configuration.");
    expect(fetches).toBe(0);
  });
});
