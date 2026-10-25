/**
 * Verified development/work/communications expansion candidates.
 *
 * ProviderDefinition is the Task 3 production shape and readiness uses the
 * Task 6 registry. A candidate definition is never, by itself, production
 * evidence: DEV_WORK_PROVIDERS is derived only from rows with passing automated
 * evidence AND a real passing live read. Contract definitions/descriptors exist
 * for tests and the explicit live harness; only registry-approved exports
 * belong in the production catalog.
 */

import {
  createRestHandler,
  createSecretRedactor,
  type RestHandlerOptions,
  type RestServiceDescriptor,
  type RestToolDef,
  type SecretRedactor,
} from "../engine.js";
import {
  normalizeConnectionConfig,
  type ProviderDefinition,
  type ProviderOperation,
} from "../../providers/types.js";
import type { McpCallContext, NativeMcpHandler } from "../../transports/native.js";
import {
  createProviderEgress,
  type ProviderEgress,
} from "../../egress/providerEgress.js";
import {
  createProviderRegistry,
  type AuthProfile,
  type ProviderReadinessRow,
} from "../../providers/registry.js";

const VERIFIED_AT = "2026-10-24";
const DIRECT_REVIEWER = "OpenCode Task 7 official-doc review";
const BATCH_B_REVIEWER = "Official batch B first-party review + OpenCode Task 7";
const CATALOG_VERSION = "2026-10-24.1";
const CONTRACT_EVIDENCE_RUN_AT = "2026-10-24T18:05:22.000Z";
const RESPONSE_BYTES = 8_192;
const OUTPUT_BYTES = 8_192;

export const DEV_WORK_CANDIDATE_IDS = [
  "vercel",
  "cloudflare",
  "asana",
  "trello",
  "clickup",
  "shortcut",
  "confluence",
  "microsoft-teams",
  "zoom",
  "intercom",
  "zendesk",
  "freshdesk",
  "twilio",
  "whatsapp-business",
  "mailchimp",
  "sendgrid",
  "klaviyo",
] as const;

export interface DevWorkFixture {
  providerId: string;
  args: Record<string, unknown>;
  connection: Record<string, string>;
  response: unknown;
}

interface EvidenceDoc {
  url: string;
  apiVersion: string;
  verifiedAt: string;
  reviewer: string;
}

interface DevWorkOperation extends ProviderOperation {
  queryArgs?: string[];
  fixedQuery?: Record<string, string>;
  queryArgMap?: Record<string, string>;
}

interface DevWorkProviderSpec extends Omit<RestServiceDescriptor, "curatedId" | "tools" | "connectionSchema"> {
  providerId: string;
  connectionSchema: Record<string, unknown>;
  operation: DevWorkOperation;
  officialDocs: readonly EvidenceDoc[];
  authProfile: AuthProfile;
  fixture: Omit<DevWorkFixture, "providerId">;
  supersedes?: string;
}

function doc(url: string, apiVersion: string, reviewer = BATCH_B_REVIEWER): EvidenceDoc {
  return { url, apiVersion, verifiedAt: VERIFIED_AT, reviewer };
}

function auth(profile: Omit<AuthProfile, "disconnectBehavior">): AuthProfile {
  return {
    ...profile,
    disconnectBehavior: "Disconnect removes this connection's token/config and fences later calls; no global plaintext credential cache is used.",
  };
}

function secret(): Record<string, unknown> {
  return { type: "string", minLength: 1, maxLength: 16_384 };
}

function text(maxLength = 128): Record<string, unknown> {
  return { type: "string", minLength: 1, maxLength };
}

function integer(minimum: number, maximum: number): Record<string, unknown> {
  return { type: "integer", minimum, maximum };
}

function connection(properties: Record<string, unknown>): Record<string, unknown> {
  return {
    type: "object",
    properties,
    required: Object.keys(properties),
    additionalProperties: false,
    maxProperties: Object.keys(properties).length,
  };
}

function args(
  properties: Record<string, unknown> = {},
  required: readonly string[] = [],
): Record<string, unknown> {
  const withTimeout = {
    ...properties,
    timeout_seconds: {
      type: "number",
      minimum: 5,
      maximum: 300,
      description: "Request timeout in seconds (default 30, maximum 300).",
    },
  };
  return {
    type: "object",
    properties: withTimeout,
    required: [...required],
    additionalProperties: false,
    maxProperties: Object.keys(withTimeout).length,
  };
}

interface ReadRoute {
  properties?: Record<string, unknown>;
  required?: readonly string[];
  queryArgs?: string[];
  fixedQuery?: Record<string, string>;
  queryArgMap?: Record<string, string>;
}

function read(
  providerId: string,
  name: string,
  description: string,
  pathTemplate: string,
  scopes: readonly string[],
  route: ReadRoute = {},
): DevWorkOperation {
  return {
    name,
    description,
    effect: "read",
    approval: "mode",
    requiredScopes: [...scopes],
    inputSchema: args(route.properties, route.required),
    outputPolicy: { kind: "redacted_json", maxBytes: OUTPUT_BYTES },
    request: { originKey: providerId, method: "GET", pathTemplate },
    limits: {
      timeoutMs: 30_000,
      responseBytes: RESPONSE_BYTES,
      frameBytes: OUTPUT_BYTES,
      pageBytes: RESPONSE_BYTES,
    },
    ...(route.queryArgs === undefined ? {} : { queryArgs: route.queryArgs }),
    ...(route.fixedQuery === undefined ? {} : { fixedQuery: route.fixedQuery }),
    ...(route.queryArgMap === undefined ? {} : { queryArgMap: route.queryArgMap }),
  };
}

function publicOperation(operation: DevWorkOperation): ProviderOperation {
  return {
    name: operation.name,
    description: operation.description,
    effect: operation.effect,
    approval: operation.approval,
    requiredScopes: operation.requiredScopes,
    inputSchema: operation.inputSchema,
    outputPolicy: operation.outputPolicy,
    request: operation.request,
    limits: operation.limits,
    ...(operation.custom === undefined ? {} : { custom: operation.custom }),
  };
}

const JSON_HEADERS = { Accept: "application/json" };
const OAUTH_CONNECTION = () => connection({ access_token: secret() });

const SPECS: readonly DevWorkProviderSpec[] = [
  {
    providerId: "vercel",
    displayName: "Vercel Projects",
    description: "Read project metadata through Vercel's resource-versioned REST API. No deployment, DNS, environment, or cache writes.",
    baseUrl: "https://api.vercel.com",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "Vercel access token",
    connectionSchema: OAUTH_CONNECTION(),
    staticHeaders: JSON_HEADERS,
    operation: read("vercel", "list_projects", "List the first project page (one project) visible to the authenticated user or team.", "/v10/projects", [], {
      properties: { limit: integer(1, 1) },
      required: ["limit"],
      queryArgs: ["limit"],
    }),
    officialDocs: [
      doc("https://vercel.com/docs/rest-api/projects/retrieve-a-list-of-projects", "projects v10 (resource-specific)", DIRECT_REVIEWER),
      doc("https://vercel.com/docs/rest-api", "resource-specific REST versions", DIRECT_REVIEWER),
    ],
    authProfile: auth({
      profileId: "vercel-bearer-read-only-projects",
      tokenType: "Vercel access token; read-only project endpoint allowlist",
      authorizationPrefix: "Bearer ",
      minimumScopes: [],
      tenantOrigins: ["https://api.vercel.com"],
      refreshBehavior: "Reauthorize or replace the access token after expiry; no refresh token is assumed.",
      revokeBehavior: "Revoke the Vercel token on disconnect or compromise; local disconnect does not claim remote revocation.",
    }),
    fixture: {
      args: { limit: 1 },
      connection: { access_token: "tenant-a-vercel-secret" },
      response: {
        projects: [{ id: "prj_example", accountId: "team_example", name: "Example Project" }],
        pagination: { count: 1, next: null },
      },
    },
  },
  {
    providerId: "cloudflare",
    displayName: "Cloudflare Zones",
    description: "List DNS zone metadata with a Zone Read API token. DNS, cache, and zone mutations are absent.",
    baseUrl: "https://api.cloudflare.com",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "api_token",
    credentialLabel: "Cloudflare Zone Read API token",
    connectionSchema: connection({ api_token: secret() }),
    staticHeaders: JSON_HEADERS,
    operation: read("cloudflare", "list_zones", "List one bounded page of zones visible to the token.", "/client/v4/zones", ["Zone Zone Read"], {
      properties: { page: integer(1, 100), per_page: integer(5, 5) },
      required: ["page", "per_page"],
      queryArgs: ["page", "per_page"],
    }),
    officialDocs: [
      doc("https://developers.cloudflare.com/api/resources/zones/methods/list/", "client v4", DIRECT_REVIEWER),
      doc("https://developers.cloudflare.com/fundamentals/api/get-started/create-token/", "scoped API tokens", DIRECT_REVIEWER),
    ],
    authProfile: auth({
      profileId: "cloudflare-zone-read-token",
      tokenType: "Cloudflare API token with only Zone Zone Read",
      authorizationPrefix: "Bearer ",
      minimumScopes: ["Zone Zone Read"],
      tenantOrigins: ["https://api.cloudflare.com"],
      refreshBehavior: "Replace the scoped API token after expiry or rotation; no OAuth refresh flow or Global API key is used.",
      revokeBehavior: "Delete or roll the API token and remove its stored copy; never broaden it to Edit during recovery.",
    }),
    fixture: {
      args: { page: 1, per_page: 5 },
      connection: { api_token: "tenant-a-cloudflare-secret" },
      response: {
        success: true,
        result: [{ id: "zone_example", name: "example.com", status: "active" }],
        result_info: { page: 1, per_page: 5, count: 1, total_count: 1, total_pages: 1 },
        errors: [],
        messages: [],
      },
    },
  },
  {
    providerId: "asana",
    displayName: "Asana Workspaces",
    description: "List workspaces visible to a delegated Asana OAuth user with the narrow workspaces read scope.",
    baseUrl: "https://app.asana.com/api/1.0",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "Asana OAuth access token",
    connectionSchema: OAUTH_CONNECTION(),
    staticHeaders: JSON_HEADERS,
    operation: read("asana", "list_workspaces", "List compact workspace records visible to the authorized user.", "/workspaces", ["workspaces:read"], {
      properties: { limit: integer(1, 1) },
      required: ["limit"],
      queryArgs: ["limit"],
    }),
    officialDocs: [
      doc("https://developers.asana.com/reference/getworkspaces", "1.0", DIRECT_REVIEWER),
      doc("https://developers.asana.com/docs/oauth", "authorization code + scopes", DIRECT_REVIEWER),
      doc("https://developers.asana.com/docs/oauth-scopes", "workspaces:read", DIRECT_REVIEWER),
    ],
    authProfile: auth({
      profileId: "asana-oauth-authorization-code",
      tokenType: "Asana delegated OAuth access token",
      authorizationPrefix: "Bearer ",
      minimumScopes: ["workspaces:read"],
      tenantOrigins: ["https://app.asana.com"],
      refreshBehavior: "Refresh the one-hour access token with the Asana refresh-token grant before retrying; preserve workspaces:read only.",
      revokeBehavior: "POST the refresh token to Asana oauth_revoke, then discard local access/refresh tokens.",
    }),
    fixture: {
      args: { limit: 1 },
      connection: { access_token: "tenant-a-asana-secret" },
      response: {
        data: [{ gid: "workspace_example", resource_type: "workspace", name: "Example Workspace" }],
        next_page: null,
      },
    },
  },
  {
    providerId: "trello",
    displayName: "Trello Member",
    description: "Read the current Trello member through Atlassian OAuth. Legacy API-key/token query credentials are not used.",
    baseUrl: "https://api.trello.com",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "Trello OAuth access token",
    connectionSchema: OAUTH_CONNECTION(),
    staticHeaders: JSON_HEADERS,
    operation: read("trello", "get_current_member", "Read only the current member ID and username.", "/1/members/me", ["read:member:trello"], {
      fixedQuery: { fields: "id,username" },
    }),
    officialDocs: [
      doc("https://developer.atlassian.com/cloud/trello/rest/api-group-members/#api-members-id-get", "1", DIRECT_REVIEWER),
      doc("https://developer.atlassian.com/cloud/trello/guides/rest-api/oauth-2-client-configuration/", "OAuth 2 scopes", DIRECT_REVIEWER),
      doc("https://developer.atlassian.com/cloud/trello/guides/rest-api/api-introduction/", "REST 1", DIRECT_REVIEWER),
    ],
    authProfile: auth({
      profileId: "trello-atlassian-oauth-3lo",
      tokenType: "Trello Atlassian OAuth 3LO access token",
      authorizationPrefix: "Bearer ",
      minimumScopes: ["read:member:trello"],
      tenantOrigins: ["https://api.trello.com"],
      refreshBehavior: "Use Atlassian rotating refresh tokens when offline_access was granted; never fall back to key/token query credentials.",
      revokeBehavior: "Revoke the Atlassian OAuth grant and discard rotated tokens; local disconnect alone is not a remote-revocation claim.",
    }),
    fixture: {
      args: {},
      connection: { access_token: "tenant-a-trello-secret" },
      response: { id: "member_example", username: "example-user" },
    },
  },
  {
    providerId: "clickup",
    displayName: "ClickUp User",
    description: "Read the authorized ClickUp user through OAuth. Personal tokens are not the third-party auth model.",
    baseUrl: "https://api.clickup.com/api",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "ClickUp OAuth access token",
    connectionSchema: OAUTH_CONNECTION(),
    staticHeaders: JSON_HEADERS,
    operation: read("clickup", "get_authorized_user", "Read the authorized ClickUp user.", "/v2/user", []),
    officialDocs: [
      doc("https://developer.clickup.com/reference/getauthorizeduser", "2.0", DIRECT_REVIEWER),
      doc("https://developer.clickup.com/docs/authentication", "OAuth authorization code", DIRECT_REVIEWER),
    ],
    authProfile: auth({
      profileId: "clickup-oauth-workspace-selection",
      tokenType: "ClickUp OAuth access token with user-selected Workspaces",
      authorizationPrefix: "Bearer ",
      minimumScopes: [],
      tenantOrigins: ["https://api.clickup.com"],
      refreshBehavior: "Current OAuth tokens do not expire; reauthorize if that behavior changes or authorization is revoked.",
      revokeBehavior: "Remove the Workspace app authorization and discard the token; do not substitute a personal API token.",
    }),
    fixture: {
      args: {},
      connection: { access_token: "tenant-a-clickup-secret" },
      response: {
        user: { id: 123, username: "Example User", color: "#000000", initials: "EU", week_start_day: 0, global_font_support: false },
      },
    },
  },
  {
    providerId: "shortcut",
    displayName: "Shortcut Member",
    description: "Read the current Shortcut member through REST v3 header authentication and a one-endpoint read allowlist.",
    baseUrl: "https://api.app.shortcut.com",
    auth: "apiKeyHeader",
    authHeader: "Shortcut-Token",
    credentialKey: "api_token",
    credentialLabel: "Shortcut API token",
    connectionSchema: connection({ api_token: secret() }),
    staticHeaders: { ...JSON_HEADERS, "Content-Type": "application/json" },
    operation: read("shortcut", "get_current_member", "Read the member associated with the Shortcut token.", "/api/v3/member", []),
    officialDocs: [doc("https://developer.shortcut.com/api/rest/v3", "REST v3")],
    authProfile: auth({
      profileId: "shortcut-v3-header-token-read-allowlist",
      tokenType: "Shortcut-Token header credential; full-account token constrained by one-read allowlist",
      authorizationPrefix: "",
      minimumScopes: [],
      tenantOrigins: ["https://api.app.shortcut.com"],
      refreshBehavior: "Replace the Shortcut token after rotation; v2, query-token auth, and Bearer substitution remain disabled.",
      revokeBehavior: "Revoke/rotate the full-account token immediately on compromise and delete the isolated connection secret.",
    }),
    supersedes: "shortcut-v2-query-token",
    fixture: {
      args: {},
      connection: { api_token: "tenant-a-shortcut-secret" },
      response: {
        id: "member_example",
        entity_type: "member",
        profile: { name: "Example User" },
        role: "member",
        disabled: false,
      },
    },
  },
  {
    providerId: "confluence",
    displayName: "Confluence Spaces",
    description: "List Confluence Cloud spaces through OAuth 3LO and REST v2 using a connection-owned cloud ID.",
    baseUrl: "https://api.atlassian.com/ex/confluence/{cloud_id}/wiki",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "Confluence OAuth 3LO access token",
    extraConfig: [{ key: "cloud_id", label: "Confluence cloud ID from accessible-resources", secret: false }],
    connectionSchema: connection({ access_token: secret(), cloud_id: text(64) }),
    staticHeaders: JSON_HEADERS,
    operation: read("confluence", "list_spaces", "List one bounded page of spaces in the authorized Confluence site.", "/api/v2/spaces", ["read:space:confluence"], {
      properties: { limit: integer(1, 1) },
      required: ["limit"],
      queryArgs: ["limit"],
    }),
    officialDocs: [
      doc("https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-space/", "REST v2"),
      doc("https://developer.atlassian.com/cloud/confluence/rest/v2/intro/", "REST v2 cursor pagination"),
      doc("https://developer.atlassian.com/cloud/confluence/oauth-2-3lo-apps/", "OAuth 3LO"),
    ],
    authProfile: auth({
      profileId: "confluence-oauth-3lo-cloud-id",
      tokenType: "Confluence OAuth 3LO access token bound to a discovered cloud ID",
      authorizationPrefix: "Bearer ",
      minimumScopes: ["read:space:confluence"],
      tenantOrigins: ["https://api.atlassian.com"],
      refreshBehavior: "Use offline_access and Atlassian rotating refresh tokens with single-flight connection refresh for background reads.",
      revokeBehavior: "Revoke the Atlassian grant, discard rotated tokens, and remove the cloud-ID binding on disconnect.",
    }),
    fixture: {
      args: { limit: 1 },
      connection: { access_token: "tenant-a-confluence-secret", cloud_id: "cloud-a" },
      response: {
        results: [{ id: "space_example", key: "EX", name: "Example Space", type: "global", status: "current" }],
        _links: {},
      },
    },
  },
  {
    providerId: "microsoft-teams",
    displayName: "Microsoft Teams",
    description: "Read one configured team for the delegated work/school user through Microsoft Graph v1.0. Channel sends are absent.",
    baseUrl: "https://graph.microsoft.com",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "Entra delegated access token",
    extraConfig: [{ key: "team_id", label: "Team ID authorized to the delegated user", secret: false }],
    connectionSchema: connection({ access_token: secret(), team_id: text(36) }),
    staticHeaders: JSON_HEADERS,
    operation: read("microsoft-teams", "get_team", "Read the configured team visible to the delegated user.", "/v1.0/teams/{team_id}", ["Team.ReadBasic.All"]),
    officialDocs: [
      doc("https://learn.microsoft.com/en-us/graph/api/team-get?view=graph-rest-1.0", "Graph v1.0"),
      doc("https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow", "Entra delegated authorization code"),
      doc("https://learn.microsoft.com/en-us/graph/paging", "Graph paging"),
    ],
    authProfile: auth({
      profileId: "entra-delegated-work-school-teams",
      tokenType: "Entra delegated work/school Teams access token",
      authorizationPrefix: "Bearer ",
      minimumScopes: ["Team.ReadBasic.All"],
      tenantOrigins: ["https://graph.microsoft.com"],
      refreshBehavior: "Use Entra offline_access refresh tokens; re-consent on invalid_grant or scope changes and never substitute app-only/ROPC credentials.",
      revokeBehavior: "Revoke the delegated grant and delete access/refresh tokens without broadening to Group.Read.All or Directory.Read.All.",
    }),
    fixture: {
      args: {},
      connection: { access_token: "tenant-a-teams-secret", team_id: "00000000-0000-0000-0000-000000000001" },
      response: { id: "00000000-0000-0000-0000-000000000001", displayName: "Example Team", isArchived: false },
    },
  },
  {
    providerId: "zoom",
    displayName: "Zoom Meetings",
    description: "List scheduled meetings for the current OAuth user. Meeting creation and sensitive start URLs are not exposed.",
    baseUrl: "https://api.zoom.us",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "Zoom user OAuth access token",
    connectionSchema: OAUTH_CONNECTION(),
    staticHeaders: JSON_HEADERS,
    operation: read("zoom", "list_scheduled_meetings", "List one bounded page of scheduled meetings for the current user.", "/v2/users/me/meetings", ["meeting:read:list_meetings"], {
      fixedQuery: { type: "scheduled", page_size: "1" },
    }),
    officialDocs: [
      doc("https://developers.zoom.us/docs/api/meetings/", "v2"),
      doc("https://developers.zoom.us/docs/integrations/oauth/", "General user OAuth"),
      doc("https://developers.zoom.us/docs/api/rate-limits/", "API rate limits"),
    ],
    authProfile: auth({
      profileId: "zoom-general-user-oauth",
      tokenType: "Zoom General user-authorization OAuth access token",
      authorizationPrefix: "Bearer ",
      minimumScopes: ["meeting:read:list_meetings"],
      tenantOrigins: ["https://api.zoom.us"],
      refreshBehavior: "Refresh one-hour access tokens and always use the latest refresh token; reauthorize after refresh expiry or revocation.",
      revokeBehavior: "Revoke the Zoom OAuth grant and discard access/latest-refresh tokens; never substitute Server-to-Server account credentials.",
    }),
    fixture: {
      args: {},
      connection: { access_token: "tenant-a-zoom-secret" },
      response: {
        page_size: 1,
        next_page_token: "",
        meetings: [{ id: 123456789, topic: "Example Meeting", type: 2 }],
      },
    },
  },
  {
    providerId: "intercom",
    displayName: "Intercom Contacts",
    description: "List contacts through the region-bound Intercom OAuth workspace with API version 2.17 pinned.",
    baseUrl: "{api_origin}",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "Intercom OAuth access token",
    extraConfig: [{ key: "api_origin", label: "Intercom regional API origin", secret: false }],
    connectionSchema: connection({
      access_token: secret(),
      api_origin: {
        type: "string",
        maxLength: 64,
        enum: ["https://api.intercom.io", "https://api.eu.intercom.io", "https://api.au.intercom.io"],
      },
    }),
    staticHeaders: { ...JSON_HEADERS, "Intercom-Version": "2.17" },
    operation: read("intercom", "list_contacts", "List one bounded page of contacts in the authorized regional workspace.", "/contacts", ["read_users_companies"], {
      properties: { per_page: integer(1, 1) },
      required: ["per_page"],
      queryArgs: ["per_page"],
    }),
    officialDocs: [
      doc("https://developers.intercom.com/docs/references/rest-api/api.intercom.io/contacts/listcontacts", "2.17"),
      doc("https://developers.intercom.com/docs/build-an-integration/learn-more/authentication/", "public-app OAuth"),
      doc("https://developers.intercom.com/docs/build-an-integration/learn-more/authentication/oauth-scopes/", "read_users_companies"),
      doc("https://developers.intercom.com/docs/build-an-integration/learn-more/rest-apis/pagination-cursor", "cursor pagination"),
    ],
    authProfile: auth({
      profileId: "intercom-public-oauth-regional-v2-17",
      tokenType: "Intercom public-app OAuth access token bound to workspace region and version 2.17",
      authorizationPrefix: "Bearer ",
      minimumScopes: ["read_users_companies"],
      tenantOrigins: ["https://api.intercom.io", "https://api.eu.intercom.io", "https://api.au.intercom.io"],
      refreshBehavior: "Follow the OAuth grant's expiry/refresh behavior and reauthorize on invalid grant; never switch region or use a private workspace token as a fallback.",
      revokeBehavior: "Remove the workspace app authorization and delete tokens while preserving the same regional binding during any reauthorization.",
    }),
    fixture: {
      args: { per_page: 1 },
      connection: { access_token: "tenant-a-intercom-secret", api_origin: "https://api.intercom.io" },
      response: {
        type: "list",
        data: [{ type: "contact", id: "contact_example", role: "lead" }],
        pages: { page: 1, per_page: 1, total_pages: 1 },
      },
    },
  },
  {
    providerId: "zendesk",
    displayName: "Zendesk Tickets",
    description: "List tickets through a scoped Zendesk global OAuth client and an authenticated customer subdomain.",
    baseUrl: "https://{subdomain}.zendesk.com",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "Zendesk global OAuth access token",
    extraConfig: [{ key: "subdomain", label: "Zendesk customer subdomain", secret: false }],
    connectionSchema: connection({ access_token: secret(), subdomain: text(63) }),
    staticHeaders: JSON_HEADERS,
    operation: read("zendesk", "list_tickets", "List one bounded cursor page of tickets in the authorized Zendesk account.", "/api/v2/tickets.json", ["tickets:read"], {
      fixedQuery: { "page[size]": "1" },
    }),
    officialDocs: [
      doc("https://developer.zendesk.com/api-reference/ticketing/introduction/", "Ticketing v2"),
      doc("https://developer.zendesk.com/documentation/ticketing/working-with-oauth/creating-and-using-oauth-tokens-with-the-api/", "OAuth Bearer"),
      doc("https://developer.zendesk.com/documentation/marketplace/building-a-marketplace-app/set-up-a-global-oauth-client/", "global OAuth client"),
      doc("https://developer.zendesk.com/api-reference/introduction/pagination/", "cursor pagination"),
    ],
    authProfile: auth({
      profileId: "zendesk-global-oauth-subdomain",
      tokenType: "Zendesk-approved global OAuth client access token",
      authorizationPrefix: "Bearer ",
      minimumScopes: ["tickets:read"],
      tenantOrigins: ["https://{subdomain}.zendesk.com"],
      refreshBehavior: "Use the global-client refresh flow and honor access-token expiry, including 30-minute defaults for newer clients; retain tickets:read only.",
      revokeBehavior: "Revoke the global OAuth grant and discard refresh tokens; never collect instance-local OAuth or customer API tokens as a fallback.",
    }),
    fixture: {
      args: {},
      connection: { access_token: "tenant-a-zendesk-secret", subdomain: "tenant-a" },
      response: {
        tickets: [{ id: 1001, subject: "Example Ticket", status: "open" }],
        meta: { has_more: false },
        links: { next: null },
      },
    },
  },
  {
    providerId: "freshdesk",
    displayName: "Freshdesk Tickets",
    description: "List tickets through Freshdesk API v2 using a dedicated view-only agent on the actual Freshdesk domain.",
    baseUrl: "https://{subdomain}.freshdesk.com",
    // Execution requires createDevWorkHandler to derive Basic base64(api_key:X).
    auth: "none",
    credentialKey: "api_key",
    credentialLabel: "Freshdesk restricted-agent API key",
    extraConfig: [{ key: "subdomain", label: "Freshdesk account subdomain", secret: false }],
    connectionSchema: connection({ api_key: secret(), subdomain: text(63) }),
    staticHeaders: JSON_HEADERS,
    operation: read("freshdesk", "list_tickets", "List the first bounded page of tickets visible to the restricted agent.", "/api/v2/tickets", [], {
      fixedQuery: { per_page: "1", page: "1" },
    }),
    officialDocs: [doc("https://developers.freshdesk.com/api/", "v2")],
    authProfile: auth({
      profileId: "freshdesk-v2-restricted-view-agent-basic",
      tokenType: "Dedicated Freshdesk view-only agent API key encoded as Basic base64(api_key:X)",
      authorizationPrefix: "Basic ",
      minimumScopes: [],
      tenantOrigins: ["https://{subdomain}.freshdesk.com"],
      refreshBehavior: "Rotate the dedicated agent API key when required; no OAuth refresh, admin key, v1, XML, or custom CNAME fallback is used.",
      revokeBehavior: "Remove/rotate the restricted agent key and delete the stored secret while preserving view-only role permissions.",
    }),
    supersedes: "freshdesk-v1",
    fixture: {
      args: {},
      connection: { api_key: "tenant-a-freshdesk-secret", subdomain: "tenant-a" },
      response: [{ id: 1001, subject: "Example Ticket", status: 2, priority: 1 }],
    },
  },
  {
    providerId: "twilio",
    displayName: "Twilio Messages",
    description: "Read message metadata through a Restricted API key with only Messaging list/fetch GET permissions. Sending and calls are absent.",
    baseUrl: "https://api.twilio.com",
    auth: "basic",
    authParam: "api_key_sid",
    credentialKey: "api_key_secret",
    credentialLabel: "Twilio Restricted API key secret",
    extraConfig: [
      { key: "api_key_sid", label: "Twilio Restricted API key SID", secret: false },
      { key: "account_sid", label: "Twilio account or dedicated subaccount SID", secret: false },
    ],
    connectionSchema: connection({ api_key_sid: text(34), api_key_secret: secret(), account_sid: text(34) }),
    staticHeaders: JSON_HEADERS,
    operation: read("twilio", "list_messages", "List one bounded page of message resources for the configured account.", "/2010-04-01/Accounts/{account_sid}/Messages.json", [], {
      fixedQuery: { PageSize: "1" },
    }),
    officialDocs: [
      doc("https://www.twilio.com/docs/usage/api", "2010-04-01 Account API"),
      doc("https://www.twilio.com/docs/usage/requests-to-twilio", "Basic auth and pagination"),
      doc("https://www.twilio.com/docs/iam/api-keys/restricted-api-keys", "Restricted API key permissions"),
    ],
    authProfile: auth({
      profileId: "twilio-restricted-api-key-message-read",
      tokenType: "Twilio Restricted API key SID/secret with only Messaging GET Message list/fetch permissions",
      authorizationPrefix: "Basic ",
      minimumScopes: [],
      tenantOrigins: ["https://api.twilio.com"],
      refreshBehavior: "Rotate the Restricted API key when needed; no OAuth refresh, Main/Standard key, master Auth Token, Message create, or Voice grant is used.",
      revokeBehavior: "Delete/rotate the Restricted key and remove its SID/secret from the connection; prefer a dedicated subaccount for containment.",
    }),
    fixture: {
      args: {},
      connection: {
        api_key_sid: `SK${"0".repeat(32)}`,
        api_key_secret: "tenant-a-twilio-secret",
        account_sid: `AC${"0".repeat(32)}`,
      },
      response: {
        messages: [{ sid: "SM_example", status: "delivered", direction: "inbound", date_created: "2026-10-01T00:00:00Z" }],
        next_page_uri: null,
        page: 0,
        page_size: 1,
      },
    },
  },
  {
    providerId: "whatsapp-business",
    displayName: "WhatsApp Business Metadata",
    description: "Read Cloud API phone-number metadata only; this connector has no history feed and requires durable signed webhook ingestion for message history.",
    baseUrl: "https://graph.facebook.com",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "WhatsApp system-user access token",
    extraConfig: [
      { key: "graph_version", label: "Supported Meta Graph version", secret: false },
      { key: "waba_id", label: "WhatsApp Business Account ID", secret: false },
    ],
    connectionSchema: connection({ access_token: secret(), graph_version: text(8), waba_id: text(64) }),
    staticHeaders: JSON_HEADERS,
    operation: read("whatsapp-business", "list_phone_numbers", "List phone-number metadata for the configured WhatsApp Business Account.", "/{graph_version}/{waba_id}/phone_numbers", ["whatsapp_business_management"], {
      fixedQuery: { limit: "1" },
    }),
    officialDocs: [
      doc("https://developers.facebook.com/docs/whatsapp/cloud-api", "Cloud API (configured supported Graph version)"),
      doc("https://developers.facebook.com/docs/whatsapp/on-premises/sunset", "On-Premises sunset 2025-10-23"),
      doc("https://developers.facebook.com/documentation/business-messaging/whatsapp/access-tokens", "system-user access tokens"),
      doc("https://developers.facebook.com/documentation/business-messaging/whatsapp/permissions", "whatsapp_business_management"),
    ],
    authProfile: auth({
      profileId: "whatsapp-cloud-system-user-management-only",
      tokenType: "WhatsApp Cloud API system-user token limited to management metadata",
      authorizationPrefix: "Bearer ",
      minimumScopes: ["whatsapp_business_management"],
      tenantOrigins: ["https://graph.facebook.com"],
      refreshBehavior: "Reissue/rotate the system-user token according to its Meta lifecycle without adding messaging or broad business_management permissions.",
      revokeBehavior: "Revoke system-user token/asset access and remove the WABA binding; On-Premises credentials and history polling are never fallbacks.",
    }),
    supersedes: "whatsapp-business-on-premises",
    fixture: {
      args: {},
      connection: { access_token: "tenant-a-whatsapp-secret", graph_version: "v24.0", waba_id: "10001" },
      response: {
        data: [{
          id: "phone_example",
          display_phone_number: "+15550000000",
          verified_name: "Example Business",
          quality_rating: "GREEN",
          status: "CONNECTED",
        }],
        paging: { cursors: { before: "sanitized-before", after: "sanitized-after" } },
      },
    },
  },
  {
    providerId: "mailchimp",
    displayName: "Mailchimp Audiences",
    description: "List audience ID/name metadata through third-party OAuth and a read-only operation allowlist. Campaign creation and sends are absent.",
    baseUrl: "https://api.mailchimp.com",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "Mailchimp OAuth access token",
    connectionSchema: OAUTH_CONNECTION(),
    staticHeaders: JSON_HEADERS,
    operation: read("mailchimp", "list_audiences", "List a bounded page of audience IDs and names.", "/3.0/lists", [], {
      fixedQuery: { count: "1", offset: "0", fields: "lists.id,lists.name,total_items" },
    }),
    officialDocs: [
      doc("https://mailchimp.com/developer/marketing/api-concepts/authentication/", "Marketing 3.0"),
      doc("https://mailchimp.com/developer/marketing/api-concepts/authentication/oauth-2/", "third-party OAuth"),
      doc("https://mailchimp.com/developer/marketing/api-concepts/methods-and-parameters/", "3.0 pagination and field masks"),
    ],
    authProfile: auth({
      profileId: "mailchimp-third-party-oauth-least-role",
      tokenType: "Mailchimp third-party OAuth access token constrained by authorizing user role and read allowlist",
      authorizationPrefix: "Bearer ",
      minimumScopes: [],
      tenantOrigins: ["https://api.mailchimp.com"],
      refreshBehavior: "OAuth tokens do not expire and have no refresh token; revocation or app removal requires a new authorization.",
      revokeBehavior: "Handle revocation/removal by requiring OAuth reauthorization; never ask for a full-access customer API key as a fallback.",
    }),
    fixture: {
      args: {},
      connection: { access_token: "tenant-a-mailchimp-secret" },
      response: { lists: [{ id: "list_example", name: "Example Audience" }], total_items: 1 },
    },
  },
  {
    providerId: "sendgrid",
    displayName: "SendGrid Statistics",
    description: "Read bounded daily global email statistics with a genuinely read-only restricted API key. Mail Send and Marketing writes are absent.",
    baseUrl: "https://api.sendgrid.com",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "api_key",
    credentialLabel: "SendGrid restricted read-only API key",
    connectionSchema: connection({ api_key: secret() }),
    staticHeaders: JSON_HEADERS,
    operation: read("sendgrid", "get_global_stats", "Read global daily statistics for an explicit bounded date range.", "/v3/stats", ["stats.global.read"], {
      properties: { start_date: text(10), end_date: text(10) },
      required: ["start_date", "end_date"],
      queryArgs: ["start_date", "end_date"],
      fixedQuery: { aggregated_by: "day", limit: "1", offset: "0" },
    }),
    officialDocs: [
      doc("https://www.twilio.com/docs/sendgrid/api-reference/stats/retrieve-global-email-statistics", "Web API v3"),
      doc("https://www.twilio.com/docs/sendgrid/api-reference/how-to-use-the-sendgrid-v3-api/authentication", "restricted API key Bearer"),
      doc("https://www.twilio.com/docs/sendgrid/api-reference/api-key-permissions", "stats.global.read"),
    ],
    authProfile: auth({
      profileId: "sendgrid-restricted-key-stats-read-only",
      tokenType: "SendGrid restricted API key with only stats.global.read",
      authorizationPrefix: "Bearer ",
      minimumScopes: ["stats.global.read"],
      tenantOrigins: ["https://api.sendgrid.com"],
      refreshBehavior: "Rotate the restricted key after expiry or compromise; no OAuth refresh or Mail Send regional endpoint is used.",
      revokeBehavior: "Delete/rotate the restricted key without enabling mail.send, Full Access, or the read/write marketing.read permission.",
    }),
    fixture: {
      args: { start_date: "2026-10-01", end_date: "2026-10-02" },
      connection: { api_key: "tenant-a-sendgrid-secret" },
      response: [{ date: "2026-10-01", stats: [{ type: "day", metrics: { delivered: 0, opens: 0 } }] }],
    },
  },
  {
    providerId: "klaviyo",
    displayName: "Klaviyo Accounts",
    description: "Read account resources through revisioned JSON:API and scoped authorization-code OAuth with mandatory PKCE. Legacy v1/v2 APIs are not used.",
    baseUrl: "https://a.klaviyo.com",
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "access_token",
    credentialLabel: "Klaviyo scoped OAuth access token",
    connectionSchema: OAUTH_CONNECTION(),
    staticHeaders: { ...JSON_HEADERS, revision: "2026-10-15" },
    operation: read("klaviyo", "list_accounts", "List account resources using the pinned stable JSON:API revision.", "/api/accounts/", ["accounts:read"]),
    officialDocs: [
      doc("https://developers.klaviyo.com/en/reference/api_overview", "JSON:API revision 2026-10-15"),
      doc("https://developers.klaviyo.com/en/docs/set_up_oauth", "authorization code + mandatory PKCE S256"),
      doc("https://developers.klaviyo.com/en/docs/api_versioning_and_deprecation_policy", "stable revision 2026-10-15"),
      doc("https://developers.klaviyo.com/en/docs/migrating_from_v1v2_to_the_new_klaviyo_apis", "legacy retirement 2024-06-30"),
    ],
    authProfile: auth({
      profileId: "klaviyo-oauth-authorization-code-pkce-s256",
      tokenType: "Klaviyo scoped OAuth access token from authorization-code flow with mandatory PKCE S256/state",
      authorizationPrefix: "Bearer ",
      minimumScopes: ["accounts:read"],
      tenantOrigins: ["https://a.klaviyo.com"],
      refreshBehavior: "Cache approximately one-hour access tokens and single-flight refresh; restart PKCE authorization on invalid grant without legacy v1/v2 fallback.",
      revokeBehavior: "Use the a.klaviyo.com revoke lifecycle and discard cached access/refresh tokens; revision 2026-10-15 remains pinned.",
    }),
    supersedes: "klaviyo-v1-v2",
    fixture: {
      args: {},
      connection: { access_token: "tenant-a-klaviyo-secret" },
      response: {
        data: [{ type: "account", id: "account_example", attributes: { test_account: true } }],
        links: { self: "https://a.klaviyo.com/api/accounts/", next: null },
      },
    },
  },
];

function descriptorFor(spec: DevWorkProviderSpec): RestServiceDescriptor {
  const operation = spec.operation;
  const tool: RestToolDef = {
    name: operation.name,
    description: operation.description,
    method: operation.request.method,
    path: operation.request.pathTemplate,
    inputSchema: operation.inputSchema,
    required: [...((operation.inputSchema.required as string[] | undefined) ?? [])],
    effect: operation.effect,
    approval: operation.approval,
    requiredScopes: operation.requiredScopes,
    request: operation.request,
    limits: operation.limits,
    outputPolicy: operation.outputPolicy,
    ...(operation.queryArgs === undefined ? {} : { queryArgs: operation.queryArgs }),
    ...(operation.fixedQuery === undefined ? {} : { fixedQuery: operation.fixedQuery }),
    ...(operation.queryArgMap === undefined ? {} : { queryArgMap: operation.queryArgMap }),
  };
  return {
    curatedId: spec.providerId,
    displayName: spec.displayName,
    description: spec.description,
    baseUrl: spec.baseUrl,
    auth: spec.auth,
    ...(spec.authHeader === undefined ? {} : { authHeader: spec.authHeader }),
    ...(spec.authPrefix === undefined ? {} : { authPrefix: spec.authPrefix }),
    ...(spec.authParam === undefined ? {} : { authParam: spec.authParam }),
    credentialKey: spec.credentialKey,
    credentialLabel: spec.credentialLabel,
    ...(spec.extraConfig === undefined ? {} : { extraConfig: spec.extraConfig }),
    tools: [tool],
    ...(spec.staticHeaders === undefined ? {} : { staticHeaders: spec.staticHeaders }),
    connectionSchema: spec.connectionSchema,
  };
}

export const DEV_WORK_CONTRACT_DEFINITIONS: readonly ProviderDefinition[] = SPECS.map((spec) => ({
  providerId: spec.providerId,
  catalogVersion: CATALOG_VERSION,
  displayName: spec.displayName,
  description: spec.description,
  officialDocs: spec.officialDocs.map(({ url, verifiedAt }) => ({ url, verifiedAt })),
  authProfileId: spec.authProfile.profileId,
  connectionSchema: spec.connectionSchema,
  operations: [publicOperation(spec.operation)],
  readiness: "supported",
}));

export const DEV_WORK_CONTRACT_DESCRIPTORS: readonly RestServiceDescriptor[] = SPECS.map(descriptorFor);

export const DEV_WORK_FIXTURES: readonly DevWorkFixture[] = SPECS.map((spec) => ({
  providerId: spec.providerId,
  args: spec.fixture.args,
  connection: spec.fixture.connection,
  response: spec.fixture.response,
}));

export const DEV_WORK_READINESS_ROWS: readonly ProviderReadinessRow[] = SPECS.map((spec, index) => ({
  providerId: spec.providerId,
  ...(spec.supersedes === undefined ? {} : { supersedes: spec.supersedes }),
  catalogOwner: "task-7-dev-work",
  officialDocs: spec.officialDocs.map((entry) => ({ ...entry })),
  operations: [publicOperation(spec.operation)],
  auth: spec.authProfile,
  effects: {
    [spec.operation.name]: { effect: spec.operation.effect, approval: spec.operation.approval },
  },
  isolationEvidence: [`test/providers/devWork.contract.test.ts::${spec.providerId} tenant A/B pinned-egress isolation`],
  fixtures: [
    `DEV_WORK_FIXTURES[${index}] sanitized request/connection fixture`,
    `DEV_WORK_FIXTURES[${index}] sanitized JSON response fixture`,
  ],
  automatedEvidence: {
    test: "./node_modules/.bin/vitest run src/rest/descriptors/devWork.test.ts test/providers/devWork.contract.test.ts",
    result: "passed",
    runAt: CONTRACT_EVIDENCE_RUN_AT,
  },
  liveReadEvidence: null,
  liveWriteEvidence: [],
  credentials: "not provided",
  releaseState: "candidate",
}));

const DEV_WORK_REGISTRY = createProviderRegistry();
for (const definition of DEV_WORK_CONTRACT_DEFINITIONS) {
  const row = DEV_WORK_READINESS_ROWS.find((candidate) => candidate.providerId === definition.providerId);
  if (row === undefined) throw new Error(`Missing development/work readiness row: ${definition.providerId}`);
  DEV_WORK_REGISTRY.registerProvider(definition, row);
}

/** Production definitions come from Task 6's evidence-enforcing registry. */
export const DEV_WORK_PROVIDERS: readonly ProviderDefinition[] = DEV_WORK_REGISTRY.catalogDefinitions();

const SUPPORTED_IDS = new Set(DEV_WORK_PROVIDERS.map((definition) => definition.providerId));

/** Only these descriptors may be appended to the production curated catalog. */
export const DEV_WORK_DESCRIPTORS: readonly RestServiceDescriptor[] = DEV_WORK_CONTRACT_DESCRIPTORS.filter((descriptor) =>
  SUPPORTED_IDS.has(descriptor.curatedId)
);

function assertSubdomain(value: string): void {
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(value)) throw new Error("Invalid tenant subdomain.");
}

function validateTenantConfig(providerId: string, config: Record<string, string>): void {
  switch (providerId) {
    case "microsoft-teams":
      if (!/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(config.team_id)) {
        throw new Error("Invalid Teams team ID.");
      }
      break;
    case "confluence":
      if (!/^[A-Za-z0-9-]{1,64}$/.test(config.cloud_id)) throw new Error("Invalid Confluence cloud ID.");
      break;
    case "zendesk":
    case "freshdesk":
      assertSubdomain(config.subdomain);
      break;
    case "twilio":
      if (!/^AC[a-f0-9]{32}$/.test(config.account_sid) || !/^SK[a-f0-9]{32}$/.test(config.api_key_sid)) {
        throw new Error("Invalid Twilio account or API key SID.");
      }
      break;
    case "whatsapp-business":
      if (!/^v\d{1,3}\.\d$/.test(config.graph_version) || !/^\d{1,64}$/.test(config.waba_id)) {
        throw new Error("Invalid WhatsApp Graph version or WABA ID.");
      }
      break;
  }
}

const VALIDATED_TENANTS = new Set(["microsoft-teams", "confluence", "zendesk", "twilio", "whatsapp-business"]);

function freshdeskExecutionDescriptor(descriptor: RestServiceDescriptor): RestServiceDescriptor {
  const properties = {
    ...(descriptor.connectionSchema?.properties as Record<string, unknown>),
    derived_basic_token: secret(),
  };
  return {
    ...descriptor,
    auth: "bearer",
    authPrefix: "Basic ",
    credentialKey: "derived_basic_token",
    credentialLabel: "Derived Freshdesk Basic credential",
    connectionSchema: {
      ...(descriptor.connectionSchema ?? {}),
      properties,
      maxProperties: Object.keys(properties).length,
    },
  };
}

const PROVIDER_SENSITIVE_FIELDS: Readonly<Record<string, ReadonlySet<string>>> = {
  vercel: new Set(["env", "deployhooks", "passwordprotection", "oidctokenclaims"]),
  cloudflare: new Set(["verification_key"]),
  clickup: new Set(["members"]),
  shortcut: new Set(["profile"]),
  zoom: new Set(["join_url", "start_url", "passcode", "agenda", "settings"]),
  intercom: new Set([
    "external_id", "email", "phone", "name", "avatar", "custom_attributes",
    "social_profiles", "location", "companies", "notes",
  ]),
  zendesk: new Set([
    "subject", "raw_subject", "description", "recipient", "requester_id", "submitter_id",
    "assignee_id", "collaborator_ids", "follower_ids", "email_cc_ids", "custom_fields",
    "satisfaction_rating", "via",
  ]),
  freshdesk: new Set([
    "subject", "description", "description_text", "requester_id", "responder_id",
    "to_emails", "cc_emails", "fwd_emails", "reply_cc_emails", "custom_fields",
    "source_additional_info",
  ]),
  twilio: new Set(["body", "to", "from", "to_formatted", "from_formatted"]),
  "whatsapp-business": new Set(["display_phone_number"]),
};

function projectProviderFields(value: unknown, sensitive: ReadonlySet<string>, depth = 0): unknown {
  if (depth > 32) return "[REDACTED]";
  if (Array.isArray(value)) return value.map((entry) => projectProviderFields(entry, sensitive, depth + 1));
  if (typeof value !== "object" || value === null) return value;
  const output: Record<string, unknown> = {};
  for (const [key, entry] of Object.entries(value)) {
    output[key] = sensitive.has(key.toLowerCase())
      ? "[REDACTED]"
      : projectProviderFields(entry, sensitive, depth + 1);
  }
  return output;
}

function withProviderOutputRedaction(providerId: string, options: RestHandlerOptions): RestHandlerOptions {
  const sensitive = PROVIDER_SENSITIVE_FIELDS[providerId];
  if (sensitive === undefined) return options;
  const base: SecretRedactor = options.redactor ?? createSecretRedactor();
  return {
    ...options,
    redactor: {
      text: (value, secrets) => base.text(value, secrets),
      error: (error, secrets) => base.error(error, secrets),
      json: <T>(value: T, secrets?: readonly string[]): T =>
        base.json(projectProviderFields(value, sensitive) as T, secrets),
    },
  };
}

function createHandlerWithTenantValidation(
  descriptor: RestServiceDescriptor,
  options: RestHandlerOptions,
): NativeMcpHandler {
  const resolve = options.resolveConnectionConfig ?? (async (ctx: McpCallContext) => ctx.secrets ?? {});
  return createRestHandler(descriptor, {
    ...options,
    resolveConnectionConfig: async (ctx) => {
      const config = normalizeConnectionConfig(descriptor.connectionSchema ?? {}, await resolve(ctx));
      validateTenantConfig(descriptor.curatedId, config);
      return config;
    },
  });
}

function createFreshdeskHandler(
  descriptor: RestServiceDescriptor,
  options: RestHandlerOptions,
): NativeMcpHandler {
  const execution = freshdeskExecutionDescriptor(descriptor);
  const resolve = options.resolveConnectionConfig ?? (async (ctx: McpCallContext) => ctx.secrets ?? {});
  return createRestHandler(execution, {
    ...options,
    resolveConnectionConfig: async (ctx) => {
      const config = normalizeConnectionConfig(descriptor.connectionSchema ?? {}, await resolve(ctx));
      assertSubdomain(config.subdomain);
      return {
        ...config,
        derived_basic_token: Buffer.from(`${config.api_key}:X`, "utf8").toString("base64"),
      };
    },
  });
}

function cloudflareUnsuccessful() {
  const text = "Provider returned an unsuccessful response.";
  return { text, isError: true, content: [{ type: "text" as const, text }] };
}

function withCloudflareEnvelopeValidation(handler: NativeMcpHandler): NativeMcpHandler {
  return {
    initialize: (params) => handler.initialize(params),
    listTools: () => handler.listTools(),
    async callTool(name, args, ctx) {
      const result = await handler.callTool(name, args, ctx);
      if (result.isError) return result;
      let payload: unknown;
      try {
        payload = JSON.parse(result.text);
      } catch {
        return cloudflareUnsuccessful();
      }
      if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
        return cloudflareUnsuccessful();
      }
      const envelope = payload as Record<string, unknown>;
      if (envelope.success !== true || !Array.isArray(envelope.errors) || envelope.errors.length !== 0 ||
          !Array.isArray(envelope.result)) {
        return cloudflareUnsuccessful();
      }
      return result;
    },
    ...(handler.dispose === undefined ? {} : { dispose: () => handler.dispose!() }),
  };
}

/**
 * Build a candidate handler for contract/live execution. Pinned ProviderEgress
 * is mandatory: the legacy generic fetch fallback is never used for this batch.
 */
export function createDevWorkHandler(providerId: string, options: RestHandlerOptions = {}): NativeMcpHandler {
  const descriptor = DEV_WORK_CONTRACT_DESCRIPTORS.find((entry) => entry.curatedId === providerId);
  if (descriptor === undefined) throw new Error(`Unknown development/work provider: ${providerId}`);
  const safeOptions = withProviderOutputRedaction(providerId, options);
  const handler = providerId === "freshdesk"
    ? createFreshdeskHandler(descriptor, safeOptions)
    : VALIDATED_TENANTS.has(providerId)
      ? createHandlerWithTenantValidation(descriptor, safeOptions)
      : createRestHandler(descriptor, safeOptions);
  const validatedHandler = providerId === "cloudflare" ? withCloudflareEnvelopeValidation(handler) : handler;
  if (options.providerEgress !== undefined) return validatedHandler;

  return {
    initialize: (params) => validatedHandler.initialize(params),
    listTools: () => validatedHandler.listTools(),
    async callTool() {
      const text = "Provider execution unavailable: pinned egress is not configured.";
      return { text, isError: true, content: [{ type: "text" as const, text }] };
    },
  };
}

export interface DevWorkLiveOutcome {
  providerId: string;
  operationId: string;
  command: string;
  executedAt: string;
  credentials: "not provided" | "configured" | "passed" | "failed";
  result: string;
}

export interface DevWorkLiveAttemptOptions {
  providerId: string;
  config: Record<string, string>;
  args?: Record<string, unknown>;
  now?: () => Date;
  createEgress?: (originKey: string, origins: readonly URL[]) => ProviderEgress;
}

function liveOptIn(providerId: string): string {
  return `OVID_LIVE_PROVIDER_${providerId.toUpperCase().replace(/[^A-Z0-9]/g, "_")}`;
}

export function devWorkLiveCommand(providerId: string): string {
  return `OVID_LIVE_PROVIDER_TESTS=1 ${liveOptIn(providerId)}=1 OVID_DEV_WORK_LIVE_REPORT=<report-path> ./node_modules/.bin/vitest run test/providers/devWork.live.test.ts`;
}

function liveOrigins(providerId: string, config: Record<string, string>): URL[] {
  switch (providerId) {
    case "vercel": return [new URL("https://api.vercel.com")];
    case "cloudflare": return [new URL("https://api.cloudflare.com")];
    case "asana": return [new URL("https://app.asana.com")];
    case "trello": return [new URL("https://api.trello.com")];
    case "clickup": return [new URL("https://api.clickup.com")];
    case "shortcut": return [new URL("https://api.app.shortcut.com")];
    case "confluence": return [new URL("https://api.atlassian.com")];
    case "microsoft-teams": return [new URL("https://graph.microsoft.com")];
    case "zoom": return [new URL("https://api.zoom.us")];
    case "intercom": return [new URL(config.api_origin)];
    case "zendesk": return [new URL(`https://${config.subdomain}.zendesk.com`)];
    case "freshdesk": return [new URL(`https://${config.subdomain}.freshdesk.com`)];
    case "twilio": return [new URL("https://api.twilio.com")];
    case "whatsapp-business": return [new URL("https://graph.facebook.com")];
    case "mailchimp": return [new URL("https://api.mailchimp.com")];
    case "sendgrid": return [new URL("https://api.sendgrid.com")];
    case "klaviyo": return [new URL("https://a.klaviyo.com")];
    default: throw new Error("Missing live origin allowlist.");
  }
}

function defaultLiveEgress(originKey: string, origins: readonly URL[]): ProviderEgress {
  return createProviderEgress({
    origins: { [originKey]: origins },
    redactor: createSecretRedactor(),
    production: true,
  });
}

/** Execute one configured live read; every construction/close failure becomes a row. */
export async function executeDevWorkLiveAttempt(options: DevWorkLiveAttemptOptions): Promise<DevWorkLiveOutcome> {
  const definition = DEV_WORK_CONTRACT_DEFINITIONS.find((entry) => entry.providerId === options.providerId);
  const operation = definition?.operations[0];
  const now = options.now ?? (() => new Date());
  const base = {
    providerId: options.providerId,
    operationId: operation?.name ?? "unknown",
    command: devWorkLiveCommand(options.providerId),
  };
  let outcome: DevWorkLiveOutcome = {
    ...base,
    executedAt: now().toISOString(),
    credentials: "failed",
    result: "sanitized exception: Error",
  };
  let egress: ProviderEgress | undefined;

  try {
    if (definition === undefined || operation === undefined) throw new Error("Missing live provider definition.");
    const fixture = DEV_WORK_FIXTURES.find((entry) => entry.providerId === options.providerId);
    if (fixture === undefined) throw new Error("Missing live provider fixture.");
    const config = normalizeConnectionConfig(definition.connectionSchema, options.config);
    validateTenantConfig(options.providerId, config);
    const origins = liveOrigins(options.providerId, config);
    egress = (options.createEgress ?? defaultLiveEgress)(operation.request.originKey, origins);
    const handler = createDevWorkHandler(options.providerId, { providerEgress: egress });
    const ctx: McpCallContext = {
      uid: "explicit-live-test-user",
      secrets: config,
      workspace: {},
      fetchImpl: async () => {
        throw new Error("generic Fetch delegation is forbidden in live provider tests");
      },
    };
    const result = await handler.callTool(operation.name, options.args ?? fixture.args, ctx);
    outcome = {
      ...base,
      executedAt: now().toISOString(),
      credentials: result.isError ? "failed" : "passed",
      result: result.isError
        ? result.text
        : "named HTTPS read succeeded; response body intentionally not recorded",
    };
  } catch (error) {
    outcome = {
      ...base,
      executedAt: now().toISOString(),
      credentials: "failed",
      result: `sanitized exception: ${error instanceof Error ? error.name : "UnknownError"}`,
    };
  } finally {
    if (egress !== undefined) {
      try {
        await egress.close();
      } catch {
        if (outcome.credentials !== "failed") {
          outcome = {
            ...outcome,
            executedAt: now().toISOString(),
            credentials: "failed",
            result: "sanitized exception: EgressCloseError",
          };
        }
      }
    }
  }
  return outcome;
}
