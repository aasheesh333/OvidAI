import { describe, expect, it } from "vitest";

import {
  COMMERCE_INFRA_MANIFEST,
  COMMERCE_INFRA_PROVIDER_IDS,
  CURATED_IDS,
  CURATED_MANIFEST,
} from "../../src/catalog.js";
import type { EgressRequest, ProviderEgress } from "../../src/egress/responseLimits.js";
import { validateProviderArgs, validateProviderDefinition } from "../../src/providers/types.js";
import {
  COMMERCE_INFRA_BLOCKED,
  COMMERCE_INFRA_DESCRIPTORS,
  COMMERCE_INFRA_PROVIDERS,
  createCommerceInfraHandler,
} from "../../src/rest/descriptors/commerceInfra.js";
import type { RestServiceDescriptor } from "../../src/rest/engine.js";
import type { McpCallContext } from "../../src/transports/native.js";

interface CandidateRow {
  candidate: string;
  providerId: string;
  blocked?: string;
  supersedes?: string;
  operation?: string;
  method?: "GET" | "POST";
  path?: string;
  scope?: string;
  scopes?: readonly string[];
  origin?: string;
  pathTemplate?: string;
  requestPath?: string;
  auth?: RestServiceDescriptor["auth"];
  authHeader?: string;
  authPrefix?: string;
  docsHost?: string;
  args?: Record<string, unknown>;
  config?: Record<string, string>;
  usernameKey?: string;
}

const token = (value: string) => `test-${value}-secret`;
const bearer = "bearer";

/**
 * Independent review expectations, not generated from production descriptors.
 * Every original candidate has exactly one row. A replacement is a new ID.
 */
const CANDIDATES: readonly CandidateRow[] = [
  {
    candidate: "razorpay", providerId: "razorpay", operation: "list_payments", method: "GET",
    path: "/v1/payments", scope: "read_only", origin: "https://api.razorpay.com", auth: bearer,
    authHeader: "Authorization", authPrefix: "Bearer ", docsHost: "razorpay.com",
    config: { access_token: token("razorpay") },
  },
  {
    candidate: "square", providerId: "square", operation: "list_payments", method: "GET",
    path: "/v2/payments", scope: "PAYMENTS_READ", origin: "https://connect.squareup.com", auth: bearer,
    authHeader: "Authorization", authPrefix: "Bearer ", docsHost: "squareup.com",
    config: { access_token: token("square") },
  },
  {
    candidate: "shopify", providerId: "shopify", operation: "list_products", method: "POST",
    path: "/graphql.json", requestPath: "/admin/api/2026-10/graphql.json", scope: "read_products", origin: "https://shop-one.myshopify.com",
    auth: "apiKeyHeader", authHeader: "X-Shopify-Access-Token", authPrefix: "", docsHost: "shopify.dev",
    config: { access_token: token("shopify"), shop: "shop-one" },
  },
  {
    candidate: "woocommerce", providerId: "woocommerce", operation: "list_products", method: "GET",
    path: "/wp-json/wc/v3/products", scope: "", origin: "https://store-one.example.com", auth: "basic",
    docsHost: "woocommerce.github.io", usernameKey: "consumer_key",
    config: { consumer_key: "ck_one", consumer_secret: token("woocommerce"), store_url: "https://store-one.example.com" },
  },
  {
    candidate: "hubspot", providerId: "hubspot", operation: "list_contacts", method: "GET",
    path: "/crm/v3/objects/contacts", scope: "crm.objects.contacts.read", origin: "https://api.hubapi.com",
    auth: bearer, authHeader: "Authorization", authPrefix: "Bearer ", docsHost: "hubspot.com",
    config: { access_token: token("hubspot") },
  },
  {
    candidate: "salesforce", providerId: "salesforce", operation: "list_accounts", method: "GET",
    path: "/services/data/v67.0/query", scope: "api", origin: "https://tenant-one.my.salesforce.com",
    auth: bearer, authHeader: "Authorization", authPrefix: "Bearer ", docsHost: "salesforce.com",
    config: { access_token: token("salesforce"), instance_url: "https://tenant-one.my.salesforce.com" },
  },
  {
    candidate: "pipedrive", providerId: "pipedrive", operation: "list_deals", method: "GET",
    path: "/api/v2/deals", scope: "deals:read", origin: "https://company-one.pipedrive.com", auth: bearer,
    authHeader: "Authorization", authPrefix: "Bearer ", docsHost: "readme.io",
    config: { access_token: token("pipedrive"), company: "company-one" },
  },
  {
    candidate: "datadog", providerId: "datadog", operation: "list_dashboards", method: "GET",
    path: "/api/v1/dashboard", scope: "dashboards_read", origin: "https://api.datadoghq.com", auth: bearer,
    authHeader: "Authorization", authPrefix: "Bearer ", docsHost: "datadoghq.com",
    config: { access_token: token("datadog"), site: "api.datadoghq.com" },
  },
  {
    candidate: "grafana", providerId: "grafana", operation: "list_folders", method: "GET",
    path: "/apis/folder.grafana.app/v1/namespaces/default/folders", scope: "folders:read",
    origin: "https://grafana-one.example.com", auth: bearer, authHeader: "Authorization", authPrefix: "Bearer ",
    docsHost: "grafana.com", config: { access_token: token("grafana"), instance_url: "https://grafana-one.example.com" },
  },
  {
    candidate: "pagerduty", providerId: "pagerduty", operation: "list_services", method: "GET",
    path: "/services", scope: "services.read", origin: "https://api.pagerduty.com", auth: bearer,
    authHeader: "Authorization", authPrefix: "Bearer ", docsHost: "pagerduty.com",
    config: { access_token: token("pagerduty") },
  },
  {
    candidate: "opsgenie", providerId: "jira-service-management", supersedes: "opsgenie",
    operation: "list_service_desks", method: "GET", path: "/rest/servicedeskapi/servicedesk",
    requestPath: "/ex/jira/cloud-one/rest/servicedeskapi/servicedesk",
    scope: "read:servicedesk-request", origin: "https://api.atlassian.com", auth: bearer,
    authHeader: "Authorization", authPrefix: "Bearer ", docsHost: "atlassian.com",
    config: { access_token: token("jira-service-management"), cloud_id: "cloud-one" },
  },
  {
    candidate: "newrelic", providerId: "newrelic", operation: "get_account", method: "POST", path: "/graphql",
    scope: "", origin: "https://api.newrelic.com", auth: "apiKeyHeader", authHeader: "API-Key", authPrefix: "",
    docsHost: "newrelic.com", args: { account_id: 123456 },
    config: { user_key: token("newrelic"), region_host: "api.newrelic.com", account_id: "123456" },
  },
  {
    candidate: "rollbar", providerId: "rollbar", operation: "get_item", method: "GET", path: "/api/1/item/{item_id}",
    pathTemplate: "/api/1/item/{item_id}?project_id={project_id}",
    scope: "read", origin: "https://api.rollbar.com", auth: "apiKeyHeader", authHeader: "X-Rollbar-Access-Token",
    authPrefix: "", docsHost: "rollbar.com", args: { item_id: 12345 },
    config: { access_token: token("rollbar"), project_id: "project-one" },
  },
  {
    candidate: "docker-hub", providerId: "docker-hub", operation: "list_repositories", method: "GET",
    path: "/v2/namespaces/{namespace}/repositories", scope: "repo:read", origin: "https://hub.docker.com",
    auth: "none", docsHost: "docker.com", config: { username: "user-one", secret: token("docker"), namespace: "namespace-one" },
  },
  {
    candidate: "kubernetes", providerId: "kubernetes", operation: "get_version", method: "GET",
    path: "/version", scope: "", origin: "https://cluster-one.example.com", auth: bearer,
    authHeader: "Authorization", authPrefix: "Bearer ", docsHost: "kubernetes.io",
    config: { access_token: token("kubernetes"), apiserver_url: "https://cluster-one.example.com" },
  },
  {
    candidate: "terraform-cloud", providerId: "terraform-cloud", operation: "list_workspaces", method: "GET",
    path: "/api/v2/organizations/{organization}/workspaces", scope: "Read permission for Terraform runs",
    origin: "https://app.terraform.io", auth: bearer, authHeader: "Authorization", authPrefix: "Bearer ",
    docsHost: "hashicorp.com", config: { access_token: token("terraform"), organization: "org-one" },
  },
  {
    candidate: "youtube", providerId: "youtube", operation: "list_channels", method: "GET",
    path: "/youtube/v3/channels", scope: "https://www.googleapis.com/auth/youtube.readonly",
    origin: "https://www.googleapis.com", auth: bearer, authHeader: "Authorization", authPrefix: "Bearer ",
    docsHost: "google.com", config: { access_token: token("youtube") },
  },
  {
    candidate: "vimeo", providerId: "vimeo", operation: "list_videos", method: "GET", path: "/me/videos",
    scopes: ["public", "private"], origin: "https://api.vimeo.com", auth: bearer, authHeader: "Authorization", authPrefix: "bearer ",
    docsHost: "vimeo.com", config: { access_token: token("vimeo") },
  },
  {
    candidate: "spotify", providerId: "spotify", operation: "list_playlists", method: "GET", path: "/v1/me/playlists",
    scope: "playlist-read-private", origin: "https://api.spotify.com", auth: bearer,
    authHeader: "Authorization", authPrefix: "Bearer ", docsHost: "spotify.com",
    config: { access_token: token("spotify") },
  },
  {
    candidate: "imgur", providerId: "imgur", operation: "get_image", method: "GET", path: "/3/image/{image_id}",
    scope: "", origin: "https://api.imgur.com", auth: "apiKeyHeader", authHeader: "Authorization",
    authPrefix: "Client-ID ", docsHost: "imgur.com", args: { image_id: "abc123" },
    config: { client_id: "public-client-one" },
  },
  {
    candidate: "cloudinary", providerId: "cloudinary", operation: "list_resources", method: "GET",
    path: "/resources/image/upload", requestPath: "/v1_1/cloud-one/resources/image/upload", scope: "", origin: "https://api.cloudinary.com", auth: "basic",
    docsHost: "cloudinary.com", usernameKey: "api_key",
    config: { api_key: "key-one", api_secret: token("cloudinary"), cloud_name: "cloud-one" },
  },
  {
    candidate: "mux", providerId: "mux", operation: "list_assets", method: "GET", path: "/video/v1/assets",
    scope: "Mux Video: Read only", origin: "https://api.mux.com", auth: "basic", docsHost: "mux.com",
    usernameKey: "token_id", config: { token_id: "id-one", token_secret: token("mux") },
  },
  {
    candidate: "cloudflare-images", providerId: "cloudflare-images", operation: "list_images", method: "GET",
    path: "/client/v4/accounts/{account_id}/images/v2", scope: "Cloudflare Images Read",
    origin: "https://api.cloudflare.com", auth: bearer, authHeader: "Authorization", authPrefix: "Bearer ",
    docsHost: "cloudflare.com", config: { access_token: token("cloudflare"), account_id: "account-one" },
  },
  {
    candidate: "zapier", providerId: "zapier", docsHost: "zapier.com",
    blocked: "Workflow API requires a publicly listed partner integration; generic workflow invocation is denied.",
  },
  {
    candidate: "make", providerId: "make", operation: "list_scenarios", method: "GET", path: "/api/v2/scenarios",
    pathTemplate: "/api/v2/scenarios?teamId={team_id}&cols[]=id&cols[]=name&cols[]=teamId&cols[]=isActive",
    scope: "scenarios:read", origin: "https://eu1.make.com", auth: "apiKeyHeader", authHeader: "Authorization",
    authPrefix: "Token ", docsHost: "make.com",
    config: { api_token: token("make"), zone: "eu1.make.com", team_id: "1001" },
  },
  {
    candidate: "n8n", providerId: "n8n", operation: "list_workflows", method: "GET", path: "/api/v1/workflows",
    scope: "workflow:list", origin: "https://n8n-one.example.com", auth: "apiKeyHeader", authHeader: "X-N8N-API-KEY",
    authPrefix: "", docsHost: "n8n.io",
    config: { api_key: token("n8n"), instance_url: "https://n8n-one.example.com", edition: "enterprise" },
  },
  {
    candidate: "stackexchange", providerId: "stackexchange", operation: "list_questions", method: "GET",
    path: "/2.3/questions", scope: "", origin: "https://api.stackexchange.com", auth: bearer,
    authHeader: "Authorization", authPrefix: "Bearer ", docsHost: "stackexchange.com",
    config: { api_key: token("stackexchange") },
  },
];

const supported = CANDIDATES.filter((row) => row.blocked === undefined);

/** Sanitized shapes from each named official read, including empty-page forms. */
const RESPONSES: Readonly<Record<string, unknown>> = {
  razorpay: { entity: "collection", count: 0, items: [] },
  square: { payments: [] },
  shopify: { data: { products: { nodes: [], pageInfo: { hasNextPage: false, endCursor: null } } } },
  woocommerce: [],
  hubspot: { results: [] },
  salesforce: { totalSize: 0, done: true, records: [] },
  pipedrive: { data: [], additional_data: {} },
  datadog: { dashboards: [] },
  grafana: { kind: "FolderList", apiVersion: "folder.grafana.app/v1", metadata: {}, items: [] },
  pagerduty: { services: [], limit: 10, offset: 0, more: false },
  "jira-service-management": { size: 0, start: 0, limit: 10, isLastPage: true, values: [] },
  newrelic: { data: { actor: { account: { id: 123456, name: "sanitized" } } } },
  rollbar: { err: 0, result: { id: 12345, title: "sanitized" } },
  "docker-hub": { count: 0, next: null, previous: null, results: [] },
  kubernetes: { major: "1", minor: "37", gitVersion: "v1.37.0", platform: "linux/amd64" },
  "terraform-cloud": { data: [], links: {}, meta: { pagination: {} } },
  youtube: { kind: "youtube#channelListResponse", pageInfo: {}, items: [] },
  vimeo: { data: [], page: 1, per_page: 10, paging: {} },
  spotify: { href: "https://api.spotify.com/v1/me/playlists", limit: 10, offset: 0, items: [] },
  imgur: { data: { id: "abc123", type: "image/png" }, success: true, status: 200 },
  cloudinary: { resources: [] },
  mux: { data: [] },
  "cloudflare-images": { result: { images: [] }, success: true, errors: [], messages: [] },
  make: { scenarios: [], pg: { limit: 10, offset: 0 } },
  n8n: { data: [], nextCursor: null },
  stackexchange: { items: [], has_more: false, quota_remaining: 100 },
};

const EXPECTED_QUERY: Readonly<Record<string, Readonly<Record<string, string | readonly string[]>>>> = {
  razorpay: { count: "10", skip: "0" },
  square: { limit: "10" },
  shopify: {},
  woocommerce: { per_page: "10", page: "1" },
  hubspot: { limit: "10", properties: "createdate", archived: "false" },
  salesforce: { q: "SELECT Id,Name FROM Account LIMIT 10" },
  pipedrive: { limit: "10" },
  datadog: { count: "10", start: "0" },
  grafana: { limit: "10" },
  pagerduty: { limit: "10", offset: "0" },
  "jira-service-management": { limit: "10", start: "0" },
  newrelic: {},
  rollbar: { project_id: "project-one" },
  "docker-hub": { page_size: "10", page: "1" },
  kubernetes: {},
  "terraform-cloud": { "page[size]": "10", "page[number]": "1" },
  youtube: { part: "id,snippet", mine: "true", maxResults: "10" },
  vimeo: { per_page: "10", page: "1", fields: "uri,name" },
  spotify: { limit: "10", offset: "0" },
  imgur: {},
  cloudinary: { max_results: "10" },
  mux: { limit: "10", page: "1" },
  "cloudflare-images": { per_page: "10" },
  make: {
    teamId: "1001",
    "cols[]": ["id", "name", "teamId", "isActive"],
    "pg[limit]": "10",
    "pg[offset]": "0",
  },
  n8n: { limit: "10" },
  stackexchange: { site: "stackoverflow", pagesize: "10", page: "1" },
};

const byId = <T extends { providerId: string }>(values: readonly T[], id: string) =>
  values.find((value) => value.providerId === id);
const byCuratedId = <T extends { curatedId: string }>(values: readonly T[], id: string) =>
  values.find((value) => value.curatedId === id);

function response(body: unknown): Awaited<ReturnType<ProviderEgress["request"]>> {
  return {
    status: 200,
    headers: new Headers({ "content-type": "application/json" }),
    body: new Response(JSON.stringify(body)).body!,
    origin: new URL("https://provider.invalid"),
    remoteAddress: "192.0.2.1",
  };
}

function context(uid: string, onFetch: () => void): McpCallContext {
  return {
    uid,
    secrets: {},
    workspace: {},
    fetchImpl: async () => { onFetch(); throw new Error("legacy fetch is denied"); },
  };
}

describe("commerce/observability/infrastructure/media/automation candidate contracts", () => {
  it("has one independently reviewed row for each of the 27 candidate IDs", () => {
    expect(CANDIDATES.map((row) => row.candidate)).toEqual([
      "razorpay", "square", "shopify", "woocommerce", "hubspot", "salesforce", "pipedrive",
      "datadog", "grafana", "pagerduty", "opsgenie", "newrelic", "rollbar", "docker-hub",
      "kubernetes", "terraform-cloud", "youtube", "vimeo", "spotify", "imgur", "cloudinary",
      "mux", "cloudflare-images", "zapier", "make", "n8n", "stackexchange",
    ]);
    expect(new Set(CANDIDATES.map((row) => row.candidate)).size).toBe(27);
    expect(supported).toHaveLength(26);
    expect(COMMERCE_INFRA_PROVIDERS).toHaveLength(26);
    expect(COMMERCE_INFRA_PROVIDER_IDS).toHaveLength(26);
  });

  it.each(CANDIDATES)("$candidate has the reviewed official read/auth/origin contract or is blocked", (row) => {
    const definition = byId(COMMERCE_INFRA_PROVIDERS, row.providerId);
    const descriptor = byCuratedId(COMMERCE_INFRA_DESCRIPTORS, row.providerId);
    if (row.blocked !== undefined) {
      expect(definition).toBeUndefined();
      expect(descriptor).toBeUndefined();
      expect(COMMERCE_INFRA_PROVIDER_IDS).not.toContain(row.providerId);
      expect(COMMERCE_INFRA_MANIFEST.some((entry) => entry.curatedId === row.providerId)).toBe(false);
      const blocked = COMMERCE_INFRA_BLOCKED.find((entry) => entry.providerId === row.providerId);
      expect(blocked).toBeDefined();
      expect(blocked?.blockerKind).toBe("external_approval");
      expect(blocked?.safePath).toContain("publicly listed Ovid integration");
      expect(blocked?.safePath).toContain("GET https://api.zapier.com/v2/zaps");
      expect(blocked?.safePath).toContain("OAuth scope `zap`");
      expect(blocked?.officialDocs.some((doc) => new URL(doc.url).hostname.endsWith(row.docsHost!))).toBe(true);
      expect(blocked?.officialDocs.every((doc) => doc.verifiedAt === "2026-10-24")).toBe(true);
      return;
    }

    expect(definition).toBeDefined();
    expect(descriptor).toBeDefined();
    expect(definition?.providerId).toBe(row.providerId);
    expect(definition?.officialDocs.some((doc) => new URL(doc.url).hostname.endsWith(row.docsHost!))).toBe(true);
    expect(definition?.officialDocs.every((doc) => doc.verifiedAt === "2026-10-24")).toBe(true);
    expect(definition?.operations[0]?.name).toBe(row.operation);
    const expectedScopes = row.scopes ?? (row.scope === "" ? [] : [row.scope!]);
    expect(definition?.operations[0]?.requiredScopes).toEqual(expectedScopes);
    expect(definition?.operations[0]?.request).toMatchObject({
      originKey: row.providerId,
      method: row.method,
      pathTemplate: row.pathTemplate ?? row.path,
    });
    expect(descriptor?.auth).toBe(row.auth);
    expect(descriptor?.authHeader).toBe(row.authHeader);
    expect(descriptor?.authPrefix).toBe(row.authPrefix);
    expect(descriptor?.tools[0]?.method).toBe(row.method);
    expect(descriptor?.tools[0]?.path).toBe(row.pathTemplate ?? row.path);
    expect(descriptor?.tools[0]?.effect).toBe("read");
    expect(descriptor?.tools[0]?.approval).toBe("mode");
    expect(() => validateProviderDefinition(definition!)).not.toThrow();
    expect(COMMERCE_INFRA_PROVIDER_IDS).toContain(row.providerId);
    expect(COMMERCE_INFRA_MANIFEST.some((entry) => entry.curatedId === row.providerId)).toBe(true);
  });

  it("does not promote contract candidates into the production catalog without live evidence", () => {
    for (const row of supported) {
      expect(CURATED_IDS).not.toContain(row.providerId);
      expect(CURATED_MANIFEST.some((entry) => entry.curatedId === row.providerId)).toBe(false);
    }
  });

  it("supersedes Opsgenie instead of reusing its candidate ID", () => {
    expect(byId(COMMERCE_INFRA_PROVIDERS, "opsgenie")).toBeUndefined();
    expect(byCuratedId(COMMERCE_INFRA_DESCRIPTORS, "opsgenie")).toBeUndefined();
    expect(byId(COMMERCE_INFRA_PROVIDERS, "jira-service-management")).toBeDefined();
    const blocked = COMMERCE_INFRA_BLOCKED.find((entry) => entry.providerId === "opsgenie");
    expect(blocked?.supersededBy).toBe("jira-service-management");
    expect(blocked?.officialDocs.some((doc) => new URL(doc.url).hostname.endsWith("atlassian.com"))).toBe(true);
    expect(supported.find((row) => row.candidate === "opsgenie")?.supersedes).toBe("opsgenie");
  });

  it.each(supported)("$providerId publishes only bounded typed reads with no high-risk action", (row) => {
    const definition = byId(COMMERCE_INFRA_PROVIDERS, row.providerId)!;
    const descriptor = byCuratedId(COMMERCE_INFRA_DESCRIPTORS, row.providerId)!;
    for (const operation of definition.operations) {
      expect(operation.effect).toBe("read");
      expect(operation.approval).toBe("mode");
      expect(operation.name).not.toMatch(/^(create|update|delete|remove|capture|charge|refund|payout|transfer|deploy|restart|publish|upload|invoke|run|activate|deactivate|mute|unmute|send|post|patch|put)/);
      expect(["financial", "deployment", "destructive", "external_communication", "credential_use"]).not.toContain(operation.effect);
      expect(operation.limits.responseBytes).toBeLessThanOrEqual(262_144);
      expect(operation.limits.pageBytes).toBeLessThanOrEqual(262_144);
      expect(operation.limits.frameBytes).toBeLessThanOrEqual(65_536);
      expect(operation.outputPolicy.maxBytes).toBeLessThanOrEqual(8_192);
      expect(operation.outputPolicy.maxBytes).toBeLessThanOrEqual(operation.limits.responseBytes);
      expect(operation.inputSchema).toMatchObject({ additionalProperties: false });
      for (const denied of [
        "baseUrl", "url", "host", "proxy", "headers", "body", "query", "graphql", "soql",
        "webhook_url", "workflow_id", "cluster", "namespace", "cloud_id", "credential", "token", "next_url",
      ]) {
        expect(validateProviderArgs(operation.inputSchema, { [denied]: "https://attacker.invalid" }).ok).toBe(false);
      }
    }
    for (const tool of descriptor.tools) {
      expect(tool.jsonBodyArg).toBeUndefined();
      expect(tool.formBodyArg).toBeUndefined();
      expect(tool.effect).toBe("read");
      if (tool.method !== "GET") {
        expect(tool.method).toBe("POST");
        expect(tool.bodyTemplate?.query).toMatch(/^const:/);
        expect(tool.bodyTemplate?.query).not.toContain("mutation");
      }
    }
  });

  it.each(supported)("$providerId rejects an upstream error envelope instead of claiming read evidence", async (row) => {
    const handler = createCommerceInfraHandler(row.providerId, {
      resolveConnectionConfig: async () => row.config!,
      egressFactory: () => ({
        async request(request) {
          if (row.providerId === "docker-hub" && request.url.pathname === "/v2/auth/token") {
            return response({ access_token: "short-lived-jwt" });
          }
          return response({ errors: [{ message: "sanitized upstream rejection" }] });
        },
        async close() {},
      }),
    });
    const result = await handler.callTool(row.operation!, row.args ?? {}, context("user-one", () => {}));
    expect(result.isError).toBe(true);
    expect(result.text).not.toContain("sanitized upstream rejection");
  });

  it.each(supported)("$providerId redacts exact credential and derived JWT echoes while preserving valid JSON", async (row) => {
    const descriptor = byCuratedId(COMMERCE_INFRA_DESCRIPTORS, row.providerId)!;
    const credential = row.config![descriptor.credentialKey];
    const derivedJwt = row.providerId === "docker-hub" ? `jwt-for-${credential}` : undefined;
    const handler = createCommerceInfraHandler(row.providerId, {
      resolveConnectionConfig: async () => row.config!,
      egressFactory: () => ({
        async request(request) {
          if (row.providerId === "docker-hub" && request.url.pathname === "/v2/auth/token") {
            return response({ access_token: derivedJwt });
          }
          const canaries = {
            credential_echo: credential,
            ...(derivedJwt === undefined ? {} : { jwt_echo: derivedJwt }),
          };
          const fixture = RESPONSES[row.providerId];
          return response(Array.isArray(fixture) ? [...fixture, canaries] : {
            ...(fixture as Record<string, unknown>),
            ...canaries,
          });
        },
        async close() {},
      }),
    });
    const result = await handler.callTool(row.operation!, row.args ?? {}, context("user-one", () => {}));
    expect(result.isError, result.text).toBe(false);
    expect(result.text).not.toContain(credential);
    if (derivedJwt !== undefined) expect(result.text).not.toContain(derivedJwt);
    const projected = JSON.parse(result.text) as unknown;
    expect(projected).not.toBeNull();
    expect(result.text).toContain("[REDACTED]");
  });

  it.each(supported)("$providerId executes through request-scoped ProviderEgress with its own tenant credentials", async (row) => {
    const descriptor = byCuratedId(COMMERCE_INFRA_DESCRIPTORS, row.providerId)!;
    const requests: EgressRequest[] = [];
    const allowedOrigins: string[] = [];
    let legacyFetches = 0;
    let closes = 0;
    const egressFactory = (origins: Readonly<Record<string, readonly URL[]>>): ProviderEgress => {
      allowedOrigins.push(origins[row.providerId]?.[0]?.origin ?? "missing");
      return {
        async request(request) {
          requests.push(request);
          if (row.providerId === "docker-hub" && request.url.pathname === "/v2/auth/token") {
            const body = JSON.parse(new TextDecoder().decode(request.body)) as { secret: string };
            return response({ access_token: `jwt-for-${body.secret}` });
          }
          return response(RESPONSES[row.providerId]);
        },
        async close() { closes += 1; },
      };
    };
    const handler = createCommerceInfraHandler(row.providerId, {
      egressFactory,
      resolveConnectionConfig: async () => row.config!,
    });
    const result = await handler.callTool(row.operation!, row.args ?? {}, context("user-one", () => { legacyFetches += 1; }));
    expect(result.isError).toBe(false);
    expect(result.text).not.toContain(token(row.candidate));
    expect(legacyFetches).toBe(0);
    expect(closes).toBe(1);
    expect(allowedOrigins).toEqual([row.origin]);
    const final = requests.at(-1)!;
    expect(final.originKey).toBe(row.providerId);
    expect(final.url.origin).toBe(row.origin);
    expect(final.url.pathname).toBe((row.requestPath ?? row.path)!.replace(/\{[^}]+\}/g, (placeholder) => {
      const key = placeholder.slice(1, -1);
      return encodeURIComponent(String(row.args?.[key] ?? row.config?.[key] ?? "missing"));
    }));
    expect(final.method).toBe(row.method);
    expect(final.redirect).toBe("deny");
    expect(final.limits.responseBytes).toBeLessThanOrEqual(262_144);
    const expectedQuery = EXPECTED_QUERY[row.providerId];
    expect(expectedQuery).toBeDefined();
    expect([...new Set(final.url.searchParams.keys())].sort()).toEqual(Object.keys(expectedQuery).sort());
    for (const [key, expected] of Object.entries(expectedQuery)) {
      expect(final.url.searchParams.getAll(key)).toEqual(Array.isArray(expected) ? expected : [expected]);
    }
    if (row.providerId === "shopify") {
      const body = JSON.parse(new TextDecoder().decode(final.body)) as { query: string; variables: unknown };
      expect(body.query).toContain("products(first: $first, after: $after)");
      expect(body.variables).toEqual({ first: 10 });
    }
    if (row.providerId === "newrelic") {
      const body = JSON.parse(new TextDecoder().decode(final.body)) as { query: string; variables: unknown };
      expect(body.query).toContain("account(id: $id)");
      expect(body.variables).toEqual({ id: 123456 });
    }
    if (row.providerId === "docker-hub") {
      expect(requests).toHaveLength(2);
      expect(requests[0].method).toBe("POST");
      expect(requests[0].url.pathname).toBe("/v2/auth/token");
      expect(JSON.parse(new TextDecoder().decode(requests[0].body))).toEqual({
        identifier: "user-one", secret: token("docker"),
      });
      expect(final.headers.Authorization).toBe(`Bearer jwt-for-${token("docker")}`);
    } else if (row.auth === "basic") {
      const username = row.config![row.usernameKey!];
      const credential = row.config![descriptor.credentialKey];
      expect(final.headers.Authorization).toBe(`Basic ${Buffer.from(`${username}:${credential}`).toString("base64")}`);
    } else if (row.auth !== "none") {
      expect(final.headers[row.authHeader!]).toBe(`${row.authPrefix ?? ""}${row.config![descriptor.credentialKey]}`);
    }

    const otherConfig = { ...row.config!, [descriptor.credentialKey]: `other-${row.providerId}-credential` };
    const otherHandler = createCommerceInfraHandler(row.providerId, {
      egressFactory,
      resolveConnectionConfig: async () => otherConfig,
    });
    const before = requests.length;
    const other = await otherHandler.callTool(row.operation!, row.args ?? {}, context("user-two", () => { legacyFetches += 1; }));
    expect(other.isError).toBe(false);
    const otherRequest = requests.at(-1)!;
    expect(requests.length).toBeGreaterThan(before);
    expect(otherRequest.secretValues).not.toContain(row.config![descriptor.credentialKey]);
    expect(otherRequest.secretValues).toContain(`other-${row.providerId}-credential`);
    if (row.providerId === "docker-hub") {
      expect(otherRequest.headers.Authorization).toBe(`Bearer jwt-for-other-${row.providerId}-credential`);
    }
  });
});
