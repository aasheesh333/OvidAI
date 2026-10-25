/**
 * Verified read-first expansion for commerce, observability, infrastructure,
 * media, and automation. This module is deliberately separate from the
 * original curated registry: live readiness is still required before these
 * entries can join a production run roster.
 *
 * Every request is constructed from a closed operation schema and
 * authenticated connection config. A request-scoped Task 2 ProviderEgress is
 * created for the one reviewed origin, including self-hosted origins, and is
 * closed after the call. No handler caches credentials, tenant URLs, or JWTs.
 */

import { isIP } from "node:net";

import { createProviderEgress, type ProviderEgress } from "../../egress/providerEgress.js";
import { createSecretRedactor, type SecretRedactor } from "../../egress/redactor.js";
import {
  assertBoundedHeadersOrCancel,
  readBoundedBody,
  type EgressLimits,
} from "../../egress/responseLimits.js";
import {
  normalizeConnectionConfig,
  snapshotProviderArgs,
  validateProviderArgs,
  type ProviderDefinition,
  type ProviderOperation,
} from "../../providers/types.js";
import type { McpCallContext, NativeMcpHandler } from "../../transports/native.js";
import type { McpToolCallResult, McpToolDef } from "../../client.js";
import {
  createRestHandler,
  restToolDefs,
  type CredentialField,
  type RestServiceDescriptor,
  type RestToolDef,
} from "../engine.js";

const VERIFIED_AT = "2026-10-24";
const CATALOG_VERSION = "2026-10-24.1";
const RESPONSE_BYTES = 262_144;
const OUTPUT_BYTES = 8_192;

const LIMITS: ProviderOperation["limits"] = {
  timeoutMs: 30_000,
  responseBytes: RESPONSE_BYTES,
  frameBytes: 65_536,
  pageBytes: RESPONSE_BYTES,
};
const OUTPUT: ProviderOperation["outputPolicy"] = { kind: "redacted_json", maxBytes: OUTPUT_BYTES };

const string = (maxLength = 256): Record<string, unknown> => ({ type: "string", minLength: 1, maxLength });
const integer = (minimum: number, maximum: number): Record<string, unknown> => ({
  type: "integer", minimum, maximum,
});
const object = (
  properties: Record<string, unknown> = {},
  required: readonly string[] = [],
): Record<string, unknown> => ({
  type: "object",
  properties,
  required: [...required],
  additionalProperties: false,
  maxProperties: Object.keys(properties).length,
});
const cursor = (name = "cursor"): Record<string, unknown> => ({ [name]: string(4_096) });
const pages = (): Record<string, unknown> => ({ page: integer(1, 10) });

interface ReadOptions {
  method?: "GET" | "POST";
  inputSchema?: Record<string, unknown>;
  required?: readonly string[];
  fixedQuery?: Record<string, string>;
  queryArgMap?: Record<string, string>;
  queryArgs?: string[];
  bodyTemplate?: Record<string, string>;
}

function read(
  name: string,
  description: string,
  path: string,
  scope: string | readonly string[],
  options: ReadOptions = {},
): RestToolDef {
  const scopes = typeof scope === "string" ? (scope === "" ? [] : [scope]) : scope;
  return {
    name,
    description,
    method: options.method ?? "GET",
    path,
    inputSchema: options.inputSchema ?? object(),
    ...(options.required === undefined ? {} : { required: [...options.required] }),
    ...(options.fixedQuery === undefined ? {} : { fixedQuery: options.fixedQuery }),
    ...(options.queryArgMap === undefined ? {} : { queryArgMap: options.queryArgMap }),
    ...(options.queryArgs === undefined ? {} : { queryArgs: options.queryArgs }),
    ...(options.bodyTemplate === undefined ? {} : { bodyTemplate: options.bodyTemplate }),
    effect: "read",
    approval: "mode",
    requiredScopes: scopes,
    limits: { ...LIMITS },
    outputPolicy: { ...OUTPUT },
  };
}

function field(key: string, label: string, secret: boolean, hint?: string): CredentialField {
  return { key, label, secret, ...(hint === undefined ? {} : { hint }) };
}

function connected(
  descriptor: RestServiceDescriptor,
  required: readonly string[],
  overrides: Record<string, Record<string, unknown>> = {},
): RestServiceDescriptor {
  const fields = [
    ...(descriptor.credentialKey === "" ? [] : [field(descriptor.credentialKey, descriptor.credentialLabel, true)]),
    ...(descriptor.extraConfig ?? []),
  ];
  const properties = Object.fromEntries(fields.map((entry) => [
    entry.key,
    overrides[entry.key] ?? string(entry.secret ? 16_384 : /url|host/i.test(entry.key) ? 2_048 : 1_024),
  ]));
  return {
    ...descriptor,
    connectionSchema: object(properties, required),
  };
}

function bearer(
  curatedId: string,
  displayName: string,
  description: string,
  baseUrl: string,
  credentialLabel: string,
  tools: RestToolDef[],
  extraConfig: CredentialField[] = [],
  staticHeaders?: Record<string, string>,
): RestServiceDescriptor {
  return {
    curatedId,
    displayName,
    description,
    baseUrl,
    auth: "bearer",
    authHeader: "Authorization",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel,
    extraConfig,
    tools,
    ...(staticHeaders === undefined ? {} : { staticHeaders }),
  };
}

const SHOPIFY_PRODUCTS_QUERY =
  "query OvidListProducts($first: Int!, $after: String) { products(first: $first, after: $after) { nodes { id title } pageInfo { hasNextPage endCursor } } }";
const NEWRELIC_ACCOUNT_QUERY =
  "query OvidReadAccount($id: Int!) { actor { account(id: $id) { id name } } }";

const RAZORPAY = connected(bearer(
  "razorpay", "Razorpay (read only)", "Read Razorpay payments with merchant-consented read_only OAuth; no financial writes.",
  "https://api.razorpay.com", "Razorpay partner OAuth access token",
  [read("list_payments", "List one bounded page of payments; capture, refund, order, payout and transfer actions are not available.",
    "/v1/payments", "read_only", {
      inputSchema: object({ skip: integer(0, 90) }),
      fixedQuery: { count: "10" }, queryArgMap: { skip: "skip:0" },
    })],
), []);

const SQUARE = connected(bearer(
  "square", "Square (read only)", "Read Square payments with seller-consented OAuth and a pinned API version; no payment or refund writes.",
  "https://connect.squareup.com", "Square seller OAuth access token",
  [read("list_payments", "List one bounded page of payments; payment creation, completion, cancellation and refunds are not available.",
    "/v2/payments", "PAYMENTS_READ", {
      inputSchema: object(cursor()), fixedQuery: { limit: "10" }, queryArgs: ["cursor"],
    })],
  [], { "Square-Version": "2026-09-16" },
), []);

const SHOPIFY = connected({
  curatedId: "shopify",
  displayName: "Shopify (read only)",
  description: "Read products through a fixed Shopify Admin GraphQL document on a pinned quarterly API version.",
  baseUrl: "https://{shop}.myshopify.com/admin/api/2026-10",
  auth: "apiKeyHeader",
  authHeader: "X-Shopify-Access-Token",
  authPrefix: "",
  credentialKey: "access_token",
  credentialLabel: "Shopify merchant app access token",
  extraConfig: [field("shop", "Shopify shop label", false, "Only the shop label, not a URL or hostname.")],
  tools: [read("list_products", "List products using the server-owned GraphQL document and typed cursor variables.",
    "/graphql.json", "read_products", {
      method: "POST",
      inputSchema: object({ first: integer(1, 10), after: string(4_096) }),
      bodyTemplate: {
        query: `const:${JSON.stringify(SHOPIFY_PRODUCTS_QUERY)}`,
        "variables.first": "int:first:10",
        "variables.after": "arg:after",
      },
    })],
}, ["shop"]);

const WOOCOMMERCE = connected({
  curatedId: "woocommerce",
  displayName: "WooCommerce (read only)",
  description: "Read products from an authenticated HTTPS WooCommerce store with a Read consumer key; no order or refund writes.",
  baseUrl: "{store_url}",
  auth: "basic",
  authParam: "consumer_key",
  credentialKey: "consumer_secret",
  credentialLabel: "WooCommerce Read consumer secret",
  extraConfig: [
    field("consumer_key", "WooCommerce Read consumer key", false),
    field("store_url", "WooCommerce store HTTPS origin", false, "Origin only; no path, userinfo, query or nonstandard port."),
  ],
  tools: [read("list_products", "List one bounded page of store products with the wc/v3 API.",
    "/wp-json/wc/v3/products", "", {
      inputSchema: object(pages()), fixedQuery: { per_page: "10" }, queryArgMap: { page: "page:1" },
    })],
}, ["consumer_key", "store_url"]);

const HUBSPOT = connected(bearer(
  "hubspot", "HubSpot (read only)", "Read a bounded contact page with only the contacts-read scope and minimal properties.",
  "https://api.hubapi.com", "HubSpot private-app or OAuth access token",
  [read("list_contacts", "List contacts with bounded paging and no sensitive-property scopes.",
    "/crm/v3/objects/contacts", "crm.objects.contacts.read", {
      inputSchema: object({ after: string(4_096) }),
      fixedQuery: { limit: "10", properties: "createdate", archived: "false" }, queryArgs: ["after"],
    })],
), []);

const SALESFORCE = connected(bearer(
  "salesforce", "Salesforce (read only)", "Read Accounts with fixed SOQL on the OAuth instance origin and pinned REST API v67.0.",
  "{instance_url}", "Salesforce OAuth access token",
  [read("list_accounts", "Read up to ten Accounts with a fixed reviewed SOQL statement; arbitrary SOQL and next-record URLs are denied.",
    "/services/data/v67.0/query", "api", {
      fixedQuery: { q: "SELECT Id,Name FROM Account LIMIT 10" },
    })],
  [field("instance_url", "Salesforce OAuth My Domain origin", false, "The exact instance_url origin returned by OAuth; no path.")],
), ["instance_url"]);

const PIPEDRIVE = connected(bearer(
  "pipedrive", "Pipedrive (read only)", "Read deals through Pipedrive API v2 on the OAuth company origin.",
  "https://{company}.pipedrive.com", "Pipedrive OAuth access token",
  [read("list_deals", "List one bounded v2 deals page with cursor pagination.",
    "/api/v2/deals", "deals:read", {
      inputSchema: object(cursor()), fixedQuery: { limit: "10" }, queryArgs: ["cursor"],
    })],
  [field("company", "Pipedrive company label", false, "Only the company label from the OAuth api_domain.")],
), ["company"]);

const DATADOG_SITES = [
  "api.datadoghq.com", "api.us3.datadoghq.com", "api.us5.datadoghq.com",
  "api.datadoghq.eu", "api.ap1.datadoghq.com", "api.ap2.datadoghq.com",
  "api.uk1.datadoghq.com", "api.ddog-gov.com", "api.us2.ddog-gov.com",
] as const;
const DATADOG = connected(bearer(
  "datadog", "Datadog (read only)", "Read dashboards with a scoped PAT/SAT on one documented Datadog API site.",
  "https://{site}", "Datadog scoped personal or service access token",
  [read("list_dashboards", "List one bounded dashboard page; monitor mute and all alert actions are absent.",
    "/api/v1/dashboard", "dashboards_read", {
      inputSchema: object({ start: integer(0, 90) }), fixedQuery: { count: "10" }, queryArgMap: { start: "start:0" },
    })],
  [field("site", "Datadog API site host", false, "Select only a documented Datadog API host.")],
), ["site"], { site: { type: "string", enum: DATADOG_SITES, maxLength: 64 } });

const GRAFANA = connected(bearer(
  "grafana", "Grafana (read only)", "Read Grafana 12+ folders through a service-account token on an authenticated HTTPS instance origin.",
  "{instance_url}", "Grafana service-account token",
  [read("list_folders", "List one bounded page of folders in the fixed default namespace.",
    "/apis/folder.grafana.app/v1/namespaces/default/folders", "folders:read", {
      inputSchema: object({ continue: string(4_096) }), fixedQuery: { limit: "10" }, queryArgs: ["continue"],
    })],
  [field("instance_url", "Grafana HTTPS origin", false, "Publicly trusted HTTPS origin only; custom CA/private-cluster trust is not supported.")],
), ["instance_url"]);

const PAGERDUTY = connected(bearer(
  "pagerduty", "PagerDuty (read only)", "Read services with Scoped OAuth; incident, escalation, note and external alert actions are absent.",
  "https://api.pagerduty.com", "PagerDuty Scoped OAuth access token",
  [read("list_services", "List one bounded services page.", "/services", "services.read", {
    inputSchema: object({ offset: integer(0, 90) }), fixedQuery: { limit: "10" }, queryArgMap: { offset: "offset:0" },
  })],
  [], { Accept: "application/vnd.pagerduty+json;version=2" },
), []);

const JIRA_SERVICE_MANAGEMENT = connected(bearer(
  "jira-service-management", "Jira Service Management (read only)",
  "Opsgenie replacement: read service desks from the authenticated Atlassian tenant with Jira Service Management OAuth.",
  "https://api.atlassian.com/ex/jira/{cloud_id}", "Jira Service Management OAuth 3LO access token",
  [read("list_service_desks", "List one bounded page of service desks; customer requests and alert/notification writes are absent.",
    "/rest/servicedeskapi/servicedesk", "read:servicedesk-request", {
      inputSchema: object({ start: integer(0, 90) }), fixedQuery: { limit: "10" }, queryArgMap: { start: "start:0" },
    })],
  [field("cloud_id", "Atlassian cloud ID", false, "Bound from OAuth accessible-resources discovery; never a model argument or tenant URL.")],
), ["cloud_id"]);

const NEWRELIC = connected({
  curatedId: "newrelic",
  displayName: "New Relic (read only)",
  description: "Read exactly the New Relic account bound to authenticated config through a fixed NerdGraph document.",
  baseUrl: "https://{region_host}",
  auth: "apiKeyHeader",
  authHeader: "API-Key",
  authPrefix: "",
  credentialKey: "user_key",
  credentialLabel: "New Relic read-only user key",
  extraConfig: [
    field("region_host", "New Relic regional API host", false),
    field("account_id", "Allowed New Relic account ID", false),
  ],
  tools: [read("get_account", "Read the single account allowlisted by this connection; caller-supplied GraphQL and NRQL are denied.",
    "/graphql", "", {
      method: "POST",
      inputSchema: object({ account_id: integer(1, 2_147_483_647) }, ["account_id"]),
      required: ["account_id"],
      bodyTemplate: {
        query: `const:${JSON.stringify(NEWRELIC_ACCOUNT_QUERY)}`,
        "variables.id": "int:account_id",
      },
    })],
}, ["region_host", "account_id"], {
  region_host: { type: "string", enum: ["api.newrelic.com", "api.eu.newrelic.com", "api.jp.newrelic.com"], maxLength: 64 },
  // The local schema subset has no pattern validator. Keep the account ID as a
  // string in config and validate its numeric value again before every request.
  account_id: string(10),
});

const ROLLBAR = connected({
  curatedId: "rollbar",
  displayName: "Rollbar (read only)",
  description: "Read one item with a read-scoped Rollbar token and a connection-bound project.",
  baseUrl: "https://api.rollbar.com",
  auth: "apiKeyHeader",
  authHeader: "X-Rollbar-Access-Token",
  authPrefix: "",
  credentialKey: "access_token",
  credentialLabel: "Rollbar read-scoped access token",
  extraConfig: [field("project_id", "Rollbar project ID", false)],
  tools: [read("get_item", "Read one Rollbar item; status, assignment and resolution writes are absent.",
    "/api/1/item/{item_id}?project_id={project_id}", "read", {
      inputSchema: object({ item_id: integer(1, 2_147_483_647) }, ["item_id"]), required: ["item_id"],
    })],
}, ["project_id"]);

const DOCKER_HUB = connected({
  curatedId: "docker-hub",
  displayName: "Docker Hub (read only)",
  description: "Exchange a PAT for a request-scoped JWT and read repositories on modern namespace routes; tokens are never cached.",
  baseUrl: "https://hub.docker.com",
  auth: "none",
  credentialKey: "secret",
  credentialLabel: "Docker Hub personal access token",
  extraConfig: [
    field("username", "Docker Hub username", false),
    field("namespace", "Docker Hub namespace", false),
  ],
  tools: [read("list_repositories", "List one bounded namespace repository page using a freshly exchanged short-lived JWT.",
    "/v2/namespaces/{namespace}/repositories", "repo:read", {
      inputSchema: object(pages()), fixedQuery: { page_size: "10" }, queryArgMap: { page: "page:1" },
    })],
}, ["secret", "username", "namespace"]);

const KUBERNETES = connected(bearer(
  "kubernetes", "Kubernetes server version (read only)",
  "Read only the fixed /version document with a dedicated read-only service-account token and public system TLS trust.",
  "{apiserver_url}", "Kubernetes read-only service-account bearer token",
  [read("get_version", "Read structured server major/minor/gitVersion metadata; no resource discovery or cluster object access.",
    "/version", "")],
  [field("apiserver_url", "Kubernetes API server HTTPS origin", false, "Origin only; public DNS and public-CA TLS required. No path, custom CA, proxy or client certificate.")],
  { Accept: "application/json" },
), ["apiserver_url"]);

const TERRAFORM_CLOUD = connected(bearer(
  "terraform-cloud", "HCP Terraform (read only)", "Read workspaces with a narrowly permissioned team token; runs, plans, applies and destroys are absent.",
  "https://app.terraform.io", "HCP Terraform read-only team token",
  [read("list_workspaces", "List one bounded workspace page for the connection-bound organization.",
    "/api/v2/organizations/{organization}/workspaces", "Read permission for Terraform runs", {
      inputSchema: object({ page: integer(1, 10) }),
      fixedQuery: { "page[size]": "10" }, queryArgMap: { page: "page[number]:1" },
    })],
  [field("organization", "HCP Terraform organization", false)],
  { Accept: "application/vnd.api+json", "Content-Type": "application/vnd.api+json" },
), ["organization"]);

const YOUTUBE = connected(bearer(
  "youtube", "YouTube (read only)", "Read the authorized user's channels with youtube.readonly; upload and publishing are absent.",
  "https://www.googleapis.com", "YouTube OAuth access token",
  [read("list_channels", "List one bounded page of the authorized user's channels.",
    "/youtube/v3/channels", "https://www.googleapis.com/auth/youtube.readonly", {
      inputSchema: object({ pageToken: string(4_096) }),
      fixedQuery: { part: "id,snippet", mine: "true", maxResults: "10" }, queryArgs: ["pageToken"],
    })],
), []);

const VIMEO = connected(bearer(
  "vimeo", "Vimeo (read only)", "Read the authorized user's video metadata with field filtering; upload and metadata writes are absent.",
  "https://api.vimeo.com", "Vimeo OAuth access token",
  [read("list_videos", "List one bounded page of video URI/name metadata.",
    "/me/videos", ["public", "private"], {
      inputSchema: object(pages()),
      fixedQuery: { per_page: "10", fields: "uri,name" }, queryArgMap: { page: "page:1" },
    })],
  [], { Accept: "application/vnd.vimeo.*+json;version=3.4" },
), []);
VIMEO.authPrefix = "bearer ";

const SPOTIFY = connected(bearer(
  "spotify", "Spotify (read only)", "Read current-user playlists with the current Web API; playback and playlist writes are absent.",
  "https://api.spotify.com", "Spotify user OAuth access token",
  [read("list_playlists", "List one bounded current-user playlist page.",
    "/v1/me/playlists", "playlist-read-private", {
      inputSchema: object({ offset: integer(0, 90) }), fixedQuery: { limit: "10" }, queryArgMap: { offset: "offset:0" },
    })],
), []);

const IMGUR = connected({
  curatedId: "imgur",
  displayName: "Imgur (public metadata only)",
  description: "Read public image metadata with a Client-ID; account libraries, remote-URL ingestion and uploads are absent.",
  baseUrl: "https://api.imgur.com",
  auth: "apiKeyHeader",
  authHeader: "Authorization",
  authPrefix: "Client-ID ",
  credentialKey: "client_id",
  credentialLabel: "Imgur API Client-ID",
  tools: [read("get_image", "Read one public image's metadata; no upload or account-library operation is available.",
    "/3/image/{image_id}", "", {
      inputSchema: object({ image_id: string(128) }, ["image_id"]), required: ["image_id"],
    })],
}, []);

const CLOUDINARY = connected({
  curatedId: "cloudinary",
  displayName: "Cloudinary (read only)",
  description: "Read image resource metadata with a read-only Media Library identity; uploads and signed delivery are absent.",
  baseUrl: "https://api.cloudinary.com/v1_1/{cloud_name}",
  auth: "basic",
  authParam: "api_key",
  credentialKey: "api_secret",
  credentialLabel: "Cloudinary read-only API secret",
  extraConfig: [
    field("api_key", "Cloudinary read-only API key", false),
    field("cloud_name", "Cloudinary product environment", false),
  ],
  tools: [read("list_resources", "List one bounded image/upload resource page.",
    "/resources/image/upload", "", {
      inputSchema: object({ next_cursor: string(4_096) }), fixedQuery: { max_results: "10" }, queryArgs: ["next_cursor"],
    })],
}, ["api_key", "cloud_name"]);

const MUX = connected({
  curatedId: "mux",
  displayName: "Mux (read only)",
  description: "Read Video assets with a Mux Video Read-only environment token; uploads and playback signing are absent.",
  baseUrl: "https://api.mux.com",
  auth: "basic",
  authParam: "token_id",
  credentialKey: "token_secret",
  credentialLabel: "Mux Video Read-only token secret",
  extraConfig: [field("token_id", "Mux Video Read-only token ID", false)],
  tools: [read("list_assets", "List one bounded Video asset page.", "/video/v1/assets", "Mux Video: Read only", {
    inputSchema: object(pages()), fixedQuery: { limit: "10" }, queryArgMap: { page: "page:1" },
  })],
}, ["token_id"]);

const CLOUDFLARE_IMAGES = connected(bearer(
  "cloudflare-images", "Cloudflare Images (read only)", "Read image metadata with an account-scoped Cloudflare Images Read token; direct upload is absent.",
  "https://api.cloudflare.com", "Cloudflare Images Read account API token",
  [read("list_images", "List one bounded Images v2 page with continuation-token pagination.",
    "/client/v4/accounts/{account_id}/images/v2", "Cloudflare Images Read", {
      inputSchema: object({ continuation_token: string(4_096) }),
      fixedQuery: { per_page: "10" }, queryArgs: ["continuation_token"],
    })],
  [field("account_id", "Cloudflare account ID", false)],
), ["account_id"]);

const MAKE = connected({
  curatedId: "make",
  displayName: "Make (read only)",
  description: "Read scenario metadata on a documented Make zone; run, start, activate, webhook and workflow invocation are denied.",
  baseUrl: "https://{zone}",
  auth: "apiKeyHeader",
  authHeader: "Authorization",
  authPrefix: "Token ",
  credentialKey: "api_token",
  credentialLabel: "Make scenarios:read API token",
  extraConfig: [
    field("zone", "Make API zone host", false),
    field("team_id", "Make team ID", false),
  ],
  tools: [read("list_scenarios", "List bounded id/name/team/status metadata for the connection-bound team.",
    "/api/v2/scenarios?teamId={team_id}&cols[]=id&cols[]=name&cols[]=teamId&cols[]=isActive", "scenarios:read", {
      inputSchema: object({ offset: integer(0, 90) }), fixedQuery: { "pg[limit]": "10" }, queryArgMap: { offset: "pg[offset]:0" },
    })],
}, ["zone", "team_id"], {
  zone: { type: "string", enum: ["eu1.make.com", "eu2.make.com", "us1.make.com", "us2.make.com"], maxLength: 64 },
});

const N8N = connected({
  curatedId: "n8n",
  displayName: "n8n Enterprise (read only)",
  description: "Read workflow metadata only with an Enterprise granularly scoped key; workflow execution and activation are denied.",
  baseUrl: "{instance_url}",
  auth: "apiKeyHeader",
  authHeader: "X-N8N-API-KEY",
  authPrefix: "",
  credentialKey: "api_key",
  credentialLabel: "n8n Enterprise workflow:list scoped API key",
  extraConfig: [
    field("instance_url", "n8n HTTPS origin", false, "Origin only; public TLS and public DNS are required."),
    field("edition", "n8n edition", false, "Only Enterprise supports the required granular key scopes."),
  ],
  tools: [read("list_workflows", "List one bounded workflow metadata page; execution data, activation and invocation are absent.",
    "/api/v1/workflows", "workflow:list", {
      inputSchema: object(cursor()), fixedQuery: { limit: "10" }, queryArgs: ["cursor"],
    })],
}, ["instance_url", "edition"], {
  edition: { type: "string", enum: ["enterprise"], maxLength: 16 },
});

const STACKEXCHANGE = connected({
  curatedId: "stackexchange",
  displayName: "Stack Exchange (read only)",
  description: "Read public Stack Overflow questions with the current Bearer API-key guidance; user writes are absent.",
  baseUrl: "https://api.stackexchange.com",
  auth: "bearer",
  authHeader: "Authorization",
  authPrefix: "Bearer ",
  credentialKey: "api_key",
  credentialLabel: "Stack Exchange API key",
  tools: [read("list_questions", "List one bounded public Stack Overflow question page; site is a fixed value, not a proxy host.",
    "/2.3/questions", "", {
      inputSchema: object(pages()),
      fixedQuery: { site: "stackoverflow", pagesize: "10" }, queryArgMap: { page: "page:1" },
    })],
}, []);

export const COMMERCE_INFRA_DESCRIPTORS: readonly RestServiceDescriptor[] = [
  RAZORPAY, SQUARE, SHOPIFY, WOOCOMMERCE, HUBSPOT, SALESFORCE, PIPEDRIVE,
  DATADOG, GRAFANA, PAGERDUTY, JIRA_SERVICE_MANAGEMENT, NEWRELIC, ROLLBAR,
  DOCKER_HUB, KUBERNETES, TERRAFORM_CLOUD, YOUTUBE, VIMEO, SPOTIFY, IMGUR, CLOUDINARY,
  MUX, CLOUDFLARE_IMAGES, MAKE, N8N, STACKEXCHANGE,
];

const AUTH_PROFILES: Readonly<Record<string, string>> = {
  razorpay: "razorpay-partner-oauth-read-only",
  square: "square-seller-oauth-read-only-2026-09-16",
  shopify: "shopify-merchant-token-read-products-2026-10",
  woocommerce: "woocommerce-read-consumer-basic-https-wc-v3",
  hubspot: "hubspot-private-or-oauth-contacts-read-v3",
  salesforce: "salesforce-oauth-api-my-domain-v67",
  pipedrive: "pipedrive-oauth-deals-read-v2",
  datadog: "datadog-scoped-pat-sat-dashboards-read-v1",
  grafana: "grafana-service-account-folders-read-v1",
  pagerduty: "pagerduty-scoped-oauth-services-read-v2",
  "jira-service-management": "atlassian-oauth-service-desk-read",
  newrelic: "newrelic-read-only-user-key-fixed-nerdgraph",
  rollbar: "rollbar-read-project-token-v1",
  "docker-hub": "docker-hub-pat-jwt-namespace-read-2-beta",
  kubernetes: "kubernetes-read-only-service-account-public-ca-version-only",
  "terraform-cloud": "hcp-terraform-team-read-v2",
  youtube: "youtube-oauth-readonly-v3",
  vimeo: "vimeo-oauth-public-private-3-4",
  spotify: "spotify-user-oauth-playlist-read-v1",
  imgur: "imgur-client-id-public-v3",
  cloudinary: "cloudinary-read-only-media-library-basic-v1",
  mux: "mux-video-read-only-basic-v1",
  "cloudflare-images": "cloudflare-account-images-read-v2",
  make: "make-scenarios-read-token-v2",
  n8n: "n8n-enterprise-workflow-list-key-v1",
  stackexchange: "stackexchange-bearer-key-v2-3",
};

const OFFICIAL_DOCS: Readonly<Record<string, readonly string[]>> = {
  razorpay: [
    "https://razorpay.com/docs/api/authentication",
    "https://razorpay.com/docs/build/llm-docs/api/payments/fetch-all-payments.md",
  ],
  square: [
    "https://developer.squareup.com/docs/oauth-api/square-permissions",
    "https://developer.squareup.com/reference/square/payments-api/list-payments",
  ],
  shopify: [
    "https://shopify.dev/docs/api/admin-graphql/2026-10",
    "https://shopify.dev/docs/api/usage/access-scopes",
  ],
  woocommerce: ["https://woocommerce.github.io/woocommerce-rest-api-docs/"],
  hubspot: [
    "https://developers.hubspot.com/docs/apps/legacy-apps/authentication/scopes",
    "https://developers.hubspot.com/docs/api-reference/latest/crm/objects/contacts/guide",
  ],
  salesforce: [
    "https://developer.salesforce.com/docs/atlas.en-us.api_rest.meta/api_rest/resources_query.htm",
    "https://developer.salesforce.com/docs/platform/api-rest/guide/intro-oauth-and-connected-apps.html",
  ],
  pipedrive: [
    "https://pipedrive.readme.io/docs/marketplace-scopes-and-permissions-explanations",
    "https://pipedrive.readme.io/docs/pipedrive-api-v2",
  ],
  datadog: [
    "https://docs.datadoghq.com/account_management/service-access-tokens/",
    "https://docs.datadoghq.com/api/latest/dashboards/get-all-dashboards/",
  ],
  grafana: [
    "https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/authentication/",
    "https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/folder/",
  ],
  pagerduty: [
    "https://developer.pagerduty.com/developer/private-apps",
    "https://developer.pagerduty.com/developer/api/reference/rest/services/list-services",
  ],
  "jira-service-management": [
    "https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/",
    "https://developer.atlassian.com/cloud/jira/service-desk/rest/api-group-servicedesk/#api-rest-servicedeskapi-servicedesk-get",
  ],
  newrelic: [
    "https://docs.newrelic.com/docs/apis/intro-apis/new-relic-api-keys/",
    "https://docs.newrelic.com/docs/apis/nerdgraph/get-started/nerdgraph-explorer/",
  ],
  rollbar: [
    "https://docs.rollbar.com/reference/getting-started-1",
    "https://docs.rollbar.com/reference/get-an-item-by-id",
  ],
  "docker-hub": [
    "https://docs.docker.com/reference/api/hub/latest/operations/AuthCreateAccessToken/",
    "https://docs.docker.com/reference/api/hub/latest/operations/listNamespaceRepositories/",
  ],
  kubernetes: [
    "https://kubernetes.io/docs/reference/access-authn-authz/authentication/",
    "https://github.com/kubernetes/client-go/blob/master/discovery/discovery_client.go",
    "https://kubernetes.io/docs/reference/kubectl/generated/kubectl_version",
  ],
  "terraform-cloud": [
    "https://developer.hashicorp.com/terraform/cloud-docs/api-docs",
    "https://developer.hashicorp.com/terraform/cloud-docs/api-docs/workspaces",
  ],
  youtube: [
    "https://developers.google.com/youtube/data/guides/authentication",
    "https://developers.google.com/youtube/v3/docs/channels/list",
  ],
  vimeo: [
    "https://developer.vimeo.com/api/authentication",
    "https://developer.vimeo.com/api/common-formats",
  ],
  spotify: [
    "https://developer.spotify.com/documentation/web-api/concepts/scopes",
    "https://developer.spotify.com/documentation/web-api/reference/get-a-list-of-current-users-playlists",
  ],
  imgur: ["https://apidocs.imgur.com/"],
  cloudinary: [
    "https://cloudinary.com/documentation/admin_api_overview",
    "https://cloudinary.com/documentation/admin_api_resources_get_resources",
  ],
  mux: [
    "https://www.mux.com/docs/core/make-api-requests",
    "https://www.mux.com/docs/api-reference/video/assets/list-assets",
  ],
  "cloudflare-images": [
    "https://developers.cloudflare.com/api/resources/images/subresources/v2/methods/list/",
    "https://developers.cloudflare.com/fundamentals/api/reference/permissions/",
  ],
  make: [
    "https://developers.make.com/api-documentation/authentication/api-scopes-overview",
    "https://developers.make.com/api-documentation/api-reference/scenarios",
  ],
  n8n: [
    "https://docs.n8n.io/connect/n8n-api/authentication/",
    "https://docs.n8n.io/connect/n8n-api/workflow/",
  ],
  stackexchange: [
    "https://api.stackexchange.com/docs/authentication",
    "https://api.stackexchange.com/docs/questions",
  ],
};

function providerDefinition(descriptor: RestServiceDescriptor): ProviderDefinition {
  const operations: ProviderOperation[] = restToolDefs(descriptor).map((operation) => ({
    name: operation.name,
    description: operation.description ?? operation.name,
    effect: operation.effect,
    approval: operation.approval,
    requiredScopes: operation.requiredScopes,
    inputSchema: operation.inputSchema!,
    outputPolicy: operation.outputPolicy,
    request: operation.request,
    limits: operation.limits,
  }));
  return {
    providerId: descriptor.curatedId,
    catalogVersion: CATALOG_VERSION,
    displayName: descriptor.displayName,
    description: descriptor.description,
    officialDocs: (OFFICIAL_DOCS[descriptor.curatedId] ?? []).map((url) => ({ url, verifiedAt: VERIFIED_AT })),
    authProfileId: AUTH_PROFILES[descriptor.curatedId],
    connectionSchema: descriptor.connectionSchema!,
    operations,
    readiness: "supported",
  };
}

export const COMMERCE_INFRA_PROVIDERS: readonly ProviderDefinition[] =
  COMMERCE_INFRA_DESCRIPTORS.map(providerDefinition);

export const COMMERCE_INFRA_SUPERSESSIONS: Readonly<Record<string, string>> = Object.freeze({
  "jira-service-management": "opsgenie",
});

export const COMMERCE_INFRA_BLOCKED = Object.freeze([
  Object.freeze({
    providerId: "opsgenie",
    reason: "Atlassian has announced the Opsgenie REST shutdown horizon; new durable support uses Jira Service Management.",
    supersededBy: "jira-service-management",
    officialDocs: [
      "https://support.atlassian.com/opsgenie/docs/what-happens-when-opsgenie-is-turned-off/",
      "https://www.atlassian.com/software/opsgenie/migration",
    ].map((url) => ({ url, verifiedAt: VERIFIED_AT })),
  }),
  Object.freeze({
    providerId: "zapier",
    blockerKind: "external_approval",
    reason: "Workflow API requires a publicly listed partner integration; generic workflow/action invocation is denied.",
    safePath: "Publish and obtain approval for a publicly listed Ovid integration, then bind approved user OAuth scope `zap` before implementing only GET https://api.zapier.com/v2/zaps with bounded offset/limit reads. Until then the original zapier ID remains reserved and uncallable; personal workflow/action/webhook invocation is not a safe substitute.",
    officialDocs: [
      "https://docs.zapier.com/api-reference/workflow",
      "https://docs.zapier.com/powered-by-zapier/api-reference/zaps/get-zaps-v2",
    ].map((url) => ({ url, verifiedAt: VERIFIED_AT })),
  }),
]);

function redactNumericJsonSecrets(value: unknown, secrets: readonly string[], depth = 0): unknown {
  if (typeof value === "number") return secrets.includes(String(value)) ? "[REDACTED]" : value;
  if (value === null || typeof value !== "object") return value;
  if (depth > 32) return "[REDACTED]";
  if (Array.isArray(value)) return value.map((entry) => redactNumericJsonSecrets(entry, secrets, depth + 1));
  return Object.fromEntries(Object.entries(value).map(([key, entry]) => [
    key,
    redactNumericJsonSecrets(entry, secrets, depth + 1),
  ]));
}

/** The legacy engine applies text redaction after JSON projection; keep that pass JSON-safe. */
function createJsonSafeRedactor(): SecretRedactor {
  const base = createSecretRedactor();
  return {
    json: base.json,
    error: base.error,
    text(value, secrets = []) {
      try {
        const parsed = JSON.parse(value) as unknown;
        return JSON.stringify(redactNumericJsonSecrets(base.json(parsed, secrets), secrets));
      } catch {
        return base.text(value, secrets);
      }
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nested(value: unknown, ...keys: string[]): unknown {
  let current = value;
  for (const key of keys) {
    if (!isRecord(current)) return undefined;
    current = current[key];
  }
  return current;
}

/** Reject HTTP-200 error envelopes and require the named read's actual shape. */
function validReadPayload(providerId: string, payload: unknown): boolean {
  if (providerId === "woocommerce") return Array.isArray(payload);
  if (!isRecord(payload)) return false;
  if (Array.isArray(payload.errors) && payload.errors.length > 0) return false;
  switch (providerId) {
    case "razorpay":
      return Array.isArray(payload.items);
    case "docker-hub":
      return Array.isArray(payload.results);
    case "kubernetes":
      return typeof payload.major === "string" && typeof payload.minor === "string" &&
        typeof payload.gitVersion === "string";
    case "square":
      return Array.isArray(payload.payments) || typeof payload.cursor === "string" || Object.keys(payload).length === 0;
    case "shopify":
      return Array.isArray(nested(payload, "data", "products", "nodes"));
    case "hubspot":
      return Array.isArray(payload.results);
    case "salesforce":
      return Array.isArray(payload.records);
    case "pipedrive":
    case "terraform-cloud":
    case "vimeo":
    case "mux":
    case "n8n":
      return Array.isArray(payload.data);
    case "datadog":
      return Array.isArray(payload.dashboards);
    case "grafana":
      return Array.isArray(payload.items);
    case "pagerduty":
      return Array.isArray(payload.services);
    case "jira-service-management":
      return Array.isArray(payload.values);
    case "newrelic": {
      const account = nested(payload, "data", "actor", "account");
      return isRecord(account) && (typeof account.id === "string" || typeof account.id === "number");
    }
    case "rollbar":
      return payload.err === 0 && isRecord(payload.result);
    case "youtube":
    case "spotify":
    case "stackexchange":
      return Array.isArray(payload.items);
    case "imgur":
      return payload.success === true && isRecord(payload.data);
    case "cloudinary":
      return Array.isArray(payload.resources);
    case "cloudflare-images":
      return payload.success === true && Array.isArray(payload.errors) && payload.errors.length === 0 &&
        Array.isArray(nested(payload, "result", "images"));
    case "make":
      return Array.isArray(payload.scenarios);
    default:
      return false;
  }
}

export interface CommerceInfraHandlerOptions {
  resolveConnectionConfig?: (ctx: McpCallContext) => Promise<Record<string, unknown>>;
  /** Per-call construction of the reviewed egress, bound to exactly one origin. */
  egressFactory?: (origins: Readonly<Record<string, readonly URL[]>>) => ProviderEgress;
}

function result(text: string): McpToolCallResult {
  return { text, isError: true, content: [{ type: "text", text }] };
}

function safeLabel(value: string | undefined): string {
  if (value === undefined || !/^[a-z0-9](?:[a-z0-9-]{0,62})$/.test(value)) {
    throw new Error("Invalid tenant label.");
  }
  return value;
}

function strictOrigin(raw: string): URL {
  // Validate raw delimiters/encoding before WHATWG normalization can erase an
  // empty ?/# or an encoded dot-segment. Only an optional single root slash is
  // an origin form; anything else is tenant path material, not an origin.
  if (/[?#]/.test(raw) || !/^https:\/\/[^\/?#]+\/?$/i.test(raw)) {
    throw new Error("Invalid authenticated tenant origin.");
  }
  const authorityAndPath = raw.slice("https://".length);
  const slash = authorityAndPath.indexOf("/");
  const authority = (slash < 0 ? authorityAndPath : authorityAndPath.slice(0, slash)).toLowerCase();
  if (authority.includes("@") || authority.includes("%")) {
    throw new Error("Invalid authenticated tenant origin.");
  }
  const url = new URL(raw);
  const hostname = url.hostname.replace(/^\[|\]$/g, "");
  if (url.protocol !== "https:" || url.username !== "" || url.password !== "" ||
      (url.pathname !== "/" && url.pathname !== "") || url.search !== "" || url.hash !== "" ||
      (url.port !== "" && url.port !== "443") || isIP(hostname) !== 0 ||
      hostname === "localhost" || hostname.endsWith(".localhost")) {
    throw new Error("Invalid authenticated tenant origin.");
  }
  return new URL(url.origin);
}

function originFor(descriptor: RestServiceDescriptor, config: Record<string, string>): URL {
  switch (descriptor.curatedId) {
    case "shopify":
      return new URL(`https://${safeLabel(config.shop)}.myshopify.com`);
    case "pipedrive":
      return new URL(`https://${safeLabel(config.company)}.pipedrive.com`);
    case "jira-service-management":
      if (!/^[a-z0-9][a-z0-9-]{0,127}$/i.test(config.cloud_id ?? "")) {
        throw new Error("Invalid Atlassian cloud ID binding.");
      }
      return new URL("https://api.atlassian.com");
    case "woocommerce":
      return strictOrigin(config.store_url ?? "");
    case "grafana":
    case "n8n":
      return strictOrigin(config.instance_url ?? "");
    case "kubernetes":
      return strictOrigin(config.apiserver_url ?? "");
    case "salesforce": {
      const origin = strictOrigin(config.instance_url ?? "");
      if (!origin.hostname.endsWith(".my.salesforce.com")) throw new Error("Invalid Salesforce instance origin.");
      return origin;
    }
    case "datadog":
      if (!DATADOG_SITES.includes(config.site as (typeof DATADOG_SITES)[number])) throw new Error("Invalid Datadog site.");
      return new URL(`https://${config.site}`);
    case "newrelic":
      if (!["api.newrelic.com", "api.eu.newrelic.com", "api.jp.newrelic.com"].includes(config.region_host ?? "")) {
        throw new Error("Invalid New Relic region.");
      }
      return new URL(`https://${config.region_host}`);
    case "make":
      if (!["eu1.make.com", "eu2.make.com", "us1.make.com", "us2.make.com"].includes(config.zone ?? "")) {
        throw new Error("Invalid Make zone.");
      }
      return new URL(`https://${config.zone}`);
    default: {
      const origin = new URL(descriptor.baseUrl).origin;
      return strictOrigin(origin);
    }
  }
}

const DOCKER_AUTH_LIMITS: EgressLimits = {
  connectMs: 10_000,
  headersMs: 15_000,
  idleMs: 30_000,
  totalMs: 30_000,
  maxRedirects: 0,
  headerBytes: 8_192,
  responseBytes: 16_384,
  decompressedBytes: 65_536,
};

async function dockerAccessToken(config: Record<string, string>, egress: ProviderEgress): Promise<string> {
  const body = new TextEncoder().encode(JSON.stringify({ identifier: config.username, secret: config.secret }));
  const response = await egress.request({
    originKey: "docker-hub",
    url: new URL("https://hub.docker.com/v2/auth/token"),
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body,
    secretValues: [config.secret ?? ""],
    privileged: true,
    redirect: "deny",
    limits: DOCKER_AUTH_LIMITS,
    signal: AbortSignal.timeout(DOCKER_AUTH_LIMITS.totalMs),
  });
  await assertBoundedHeadersOrCancel(response, DOCKER_AUTH_LIMITS);
  if (response.status < 200 || response.status >= 300) {
    await response.body.cancel().catch(() => {});
    throw new Error("Docker Hub token exchange failed.");
  }
  const bytes = await readBoundedBody(response, DOCKER_AUTH_LIMITS);
  const parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as unknown;
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("Invalid token response.");
  const token = (parsed as Record<string, unknown>).access_token;
  if (typeof token !== "string" || token.trim() === "" || token.length > 16_384) throw new Error("Invalid token response.");
  return token;
}

function dockerRuntimeDescriptor(descriptor: RestServiceDescriptor): RestServiceDescriptor {
  const schema = descriptor.connectionSchema!;
  return {
    ...descriptor,
    auth: "bearer",
    authHeader: "Authorization",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "Docker Hub request-scoped JWT",
    connectionSchema: {
      ...schema,
      properties: {
        ...(schema.properties as Record<string, unknown>),
        access_token: string(16_384),
      },
      maxProperties: (schema.maxProperties as number) + 1,
    },
  };
}

export function createCommerceInfraHandler(
  providerId: string,
  options: CommerceInfraHandlerOptions = {},
): NativeMcpHandler {
  const descriptor = COMMERCE_INFRA_DESCRIPTORS.find((entry) => entry.curatedId === providerId);
  if (descriptor === undefined) throw new Error(`Unknown commerceInfra provider: ${providerId}`);
  const published = restToolDefs(descriptor);
  const egressFactory = options.egressFactory ?? ((origins: Readonly<Record<string, readonly URL[]>>) =>
    createProviderEgress({ origins, production: true, redactor: createSecretRedactor() }));
  const redactor = createJsonSafeRedactor();

  return {
    async initialize(): Promise<Record<string, unknown>> {
      return {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: providerId, version: CATALOG_VERSION },
      };
    },

    async listTools(): Promise<McpToolDef[]> {
      return published.map((tool) => ({ ...tool, inputSchema: { ...tool.inputSchema } }));
    },

    async callTool(name: string, input: Record<string, unknown>, ctx: McpCallContext): Promise<McpToolCallResult> {
      const operation = published.find((candidate) => candidate.name === name);
      if (operation === undefined) return result("Unknown provider operation.");
      let args: Record<string, unknown>;
      try {
        args = snapshotProviderArgs(input ?? {});
        if (operation.inputSchema === undefined ||
            !validateProviderArgs(operation.inputSchema, args).ok) return result("Invalid operation arguments.");
      } catch {
        return result("Invalid operation arguments.");
      }

      let egress: ProviderEgress | undefined;
      try {
        const unresolved = options.resolveConnectionConfig !== undefined
          ? await options.resolveConnectionConfig(ctx)
          : ctx.secrets ?? {};
        const config = normalizeConnectionConfig(descriptor.connectionSchema!, unresolved);
        if (providerId === "n8n" && config.edition !== "enterprise") return result("Invalid connection configuration.");
        if (providerId === "newrelic") {
          const accountId = Number(config.account_id);
          if (!/^\d{1,10}$/.test(config.account_id ?? "") || !Number.isSafeInteger(accountId) ||
              accountId < 1 || accountId > 2_147_483_647 || args.account_id !== accountId) {
            return result("Operation denied (account_binding_mismatch).");
          }
        }
        const origin = originFor(descriptor, config);
        egress = egressFactory({ [providerId]: Object.freeze([origin]) });

        let runtimeDescriptor = descriptor;
        // Kubernetes request construction uses the canonical origin validated
        // for egress, never raw tenant text. Raw ?/# forms fail before this
        // point, so `/version` cannot be reparsed as a query or fragment.
        let runtimeConfig: Record<string, unknown> = providerId === "kubernetes"
          ? { ...config, apiserver_url: origin.origin }
          : config;
        if (providerId === "docker-hub") {
          const accessToken = await dockerAccessToken(config, egress);
          runtimeDescriptor = dockerRuntimeDescriptor(descriptor);
          runtimeConfig = { ...config, access_token: accessToken };
        }
        const executed = await createRestHandler(runtimeDescriptor, {
          providerEgress: egress,
          resolveConnectionConfig: async () => runtimeConfig,
          redactor,
        }).callTool(name, args, ctx);
        if (executed.isError) return executed;
        let payload: unknown;
        try {
          payload = JSON.parse(executed.text) as unknown;
        } catch {
          return result("Provider returned an invalid read response.");
        }
        return validReadPayload(providerId, payload)
          ? executed
          : result("Provider returned an unexpected read response.");
      } catch {
        return result("Provider operation failed or connection configuration was invalid.");
      } finally {
        if (egress !== undefined) await egress.close().catch(() => {});
      }
    },
  };
}
