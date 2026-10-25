import { describe, expect, it, vi } from "vitest";

import { validateProviderArgs, validateProviderDefinition } from "../../providers/types.js";
import { createProviderRegistry } from "../../providers/registry.js";
import { createCuratedCatalog, CURATED_IDS, CURATED_MANIFEST } from "../../catalog.js";
import type { EgressRequest, ProviderEgress } from "../../egress/providerEgress.js";
import type { McpCallContext } from "../../transports/native.js";
import type { WorkspaceFiles } from "../../workspace.js";
import {
  DEV_WORK_CANDIDATE_IDS,
  DEV_WORK_CONTRACT_DEFINITIONS,
  DEV_WORK_CONTRACT_DESCRIPTORS,
  DEV_WORK_FIXTURES,
  DEV_WORK_PROVIDERS,
  DEV_WORK_READINESS_ROWS,
} from "./devWork.js";

// The catalog's original-provider evidence belongs to Task 6 and is not the
// behavior under test. Isolate it while that separate batch is being built.
vi.mock("../../providerEvidence.js", async () => {
  const { createProviderRegistry } = await import("../../providers/registry.js");
  return { ORIGINAL_PROVIDER_REGISTRY: createProviderRegistry() };
});

interface ExpectedRow {
  operationId: string;
  apiVersion: string;
  doc: string;
  baseUrl: string;
  path: string;
  scopes: readonly string[];
  authProfileId: string;
}

// One explicit evidence row per candidate. This is deliberately not a
// count-only roster: an ID without current official evidence fails its own test.
const EXPECTED_ROWS = {
  vercel: {
    operationId: "list_projects",
    apiVersion: "projects v10 (resource-specific)",
    doc: "https://vercel.com/docs/rest-api/projects/retrieve-a-list-of-projects",
    baseUrl: "https://api.vercel.com",
    path: "/v10/projects",
    scopes: [],
    authProfileId: "vercel-bearer-read-only-projects",
  },
  cloudflare: {
    operationId: "list_zones",
    apiVersion: "client v4",
    doc: "https://developers.cloudflare.com/api/resources/zones/methods/list/",
    baseUrl: "https://api.cloudflare.com",
    path: "/client/v4/zones",
    scopes: ["Zone Zone Read"],
    authProfileId: "cloudflare-zone-read-token",
  },
  asana: {
    operationId: "list_workspaces",
    apiVersion: "1.0",
    doc: "https://developers.asana.com/reference/getworkspaces",
    baseUrl: "https://app.asana.com/api/1.0",
    path: "/workspaces",
    scopes: ["workspaces:read"],
    authProfileId: "asana-oauth-authorization-code",
  },
  trello: {
    operationId: "get_current_member",
    apiVersion: "1",
    doc: "https://developer.atlassian.com/cloud/trello/rest/api-group-members/#api-members-id-get",
    baseUrl: "https://api.trello.com",
    path: "/1/members/me",
    scopes: ["read:member:trello"],
    authProfileId: "trello-atlassian-oauth-3lo",
  },
  clickup: {
    operationId: "get_authorized_user",
    apiVersion: "2.0",
    doc: "https://developer.clickup.com/reference/getauthorizeduser",
    baseUrl: "https://api.clickup.com/api",
    path: "/v2/user",
    scopes: [],
    authProfileId: "clickup-oauth-workspace-selection",
  },
  shortcut: {
    operationId: "get_current_member",
    apiVersion: "REST v3",
    doc: "https://developer.shortcut.com/api/rest/v3",
    baseUrl: "https://api.app.shortcut.com",
    path: "/api/v3/member",
    scopes: [],
    authProfileId: "shortcut-v3-header-token-read-allowlist",
  },
  confluence: {
    operationId: "list_spaces",
    apiVersion: "REST v2",
    doc: "https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-space/",
    baseUrl: "https://api.atlassian.com/ex/confluence/{cloud_id}/wiki",
    path: "/api/v2/spaces",
    scopes: ["read:space:confluence"],
    authProfileId: "confluence-oauth-3lo-cloud-id",
  },
  "microsoft-teams": {
    operationId: "get_team",
    apiVersion: "Graph v1.0",
    doc: "https://learn.microsoft.com/en-us/graph/api/team-get?view=graph-rest-1.0",
    baseUrl: "https://graph.microsoft.com",
    path: "/v1.0/teams/{team_id}",
    scopes: ["Team.ReadBasic.All"],
    authProfileId: "entra-delegated-work-school-teams",
  },
  zoom: {
    operationId: "list_scheduled_meetings",
    apiVersion: "v2",
    doc: "https://developers.zoom.us/docs/api/meetings/",
    baseUrl: "https://api.zoom.us",
    path: "/v2/users/me/meetings",
    scopes: ["meeting:read:list_meetings"],
    authProfileId: "zoom-general-user-oauth",
  },
  intercom: {
    operationId: "list_contacts",
    apiVersion: "2.17",
    doc: "https://developers.intercom.com/docs/references/rest-api/api.intercom.io/contacts/listcontacts",
    baseUrl: "{api_origin}",
    path: "/contacts",
    scopes: ["read_users_companies"],
    authProfileId: "intercom-public-oauth-regional-v2-17",
  },
  zendesk: {
    operationId: "list_tickets",
    apiVersion: "Ticketing v2",
    doc: "https://developer.zendesk.com/api-reference/ticketing/introduction/",
    baseUrl: "https://{subdomain}.zendesk.com",
    path: "/api/v2/tickets.json",
    scopes: ["tickets:read"],
    authProfileId: "zendesk-global-oauth-subdomain",
  },
  freshdesk: {
    operationId: "list_tickets",
    apiVersion: "v2",
    doc: "https://developers.freshdesk.com/api/",
    baseUrl: "https://{subdomain}.freshdesk.com",
    path: "/api/v2/tickets",
    scopes: [],
    authProfileId: "freshdesk-v2-restricted-view-agent-basic",
  },
  twilio: {
    operationId: "list_messages",
    apiVersion: "2010-04-01 Account API",
    doc: "https://www.twilio.com/docs/usage/api",
    baseUrl: "https://api.twilio.com",
    path: "/2010-04-01/Accounts/{account_sid}/Messages.json",
    scopes: [],
    authProfileId: "twilio-restricted-api-key-message-read",
  },
  "whatsapp-business": {
    operationId: "list_phone_numbers",
    apiVersion: "Cloud API (configured supported Graph version)",
    doc: "https://developers.facebook.com/docs/whatsapp/cloud-api",
    baseUrl: "https://graph.facebook.com",
    path: "/{graph_version}/{waba_id}/phone_numbers",
    scopes: ["whatsapp_business_management"],
    authProfileId: "whatsapp-cloud-system-user-management-only",
  },
  mailchimp: {
    operationId: "list_audiences",
    apiVersion: "Marketing 3.0",
    doc: "https://mailchimp.com/developer/marketing/api-concepts/authentication/",
    baseUrl: "https://api.mailchimp.com",
    path: "/3.0/lists",
    scopes: [],
    authProfileId: "mailchimp-third-party-oauth-least-role",
  },
  sendgrid: {
    operationId: "get_global_stats",
    apiVersion: "Web API v3",
    doc: "https://www.twilio.com/docs/sendgrid/api-reference/stats/retrieve-global-email-statistics",
    baseUrl: "https://api.sendgrid.com",
    path: "/v3/stats",
    scopes: ["stats.global.read"],
    authProfileId: "sendgrid-restricted-key-stats-read-only",
  },
  klaviyo: {
    operationId: "list_accounts",
    apiVersion: "JSON:API revision 2026-10-15",
    doc: "https://developers.klaviyo.com/en/reference/api_overview",
    baseUrl: "https://a.klaviyo.com",
    path: "/api/accounts/",
    scopes: ["accounts:read"],
    authProfileId: "klaviyo-oauth-authorization-code-pkce-s256",
  },
} as const satisfies Record<string, ExpectedRow>;

function definitionFor(id: string) {
  const definition = DEV_WORK_CONTRACT_DEFINITIONS.find((entry) => entry.providerId === id);
  if (definition === undefined) throw new Error(`Missing contract definition for ${id}`);
  return definition;
}

function descriptorFor(id: string) {
  const descriptor = DEV_WORK_CONTRACT_DESCRIPTORS.find((entry) => entry.curatedId === id);
  if (descriptor === undefined) throw new Error(`Missing contract descriptor for ${id}`);
  return descriptor;
}

describe("development/work/communications official evidence rows", () => {
  for (const id of DEV_WORK_CANDIDATE_IDS) {
    it(`${id} has one current official typed read with closed bounded metadata`, () => {
      const expected: ExpectedRow = EXPECTED_ROWS[id as keyof typeof EXPECTED_ROWS];
      expect(expected, `explicit evidence expectation for ${id}`).toBeDefined();
      const definition = definitionFor(id);
      const descriptor = descriptorFor(id);
      const row = DEV_WORK_READINESS_ROWS.find((entry) => entry.providerId === id);
      const fixture = DEV_WORK_FIXTURES.find((entry) => entry.providerId === id);

      expect(row, `readiness row for ${id}`).toBeDefined();
      expect(fixture, `sanitized fixture for ${id}`).toBeDefined();
      expect(definition.providerId).toBe(id);
      expect(definition.catalogVersion).toBe("2026-10-24.1");
      expect(definition.operations).toHaveLength(1);
      expect(() => validateProviderDefinition(definition)).not.toThrow();

      const operation = definition.operations[0];
      expect(operation.name).toBe(expected.operationId);
      expect(operation.effect).toBe("read");
      expect(operation.approval).toBe("mode");
      expect(operation.request).toEqual({ originKey: id, method: "GET", pathTemplate: expected.path });
      expect(operation.requiredScopes).toEqual(expected.scopes);
      expect(operation.outputPolicy.kind).toBe("redacted_json");
      expect(operation.outputPolicy.maxBytes).toBeLessThanOrEqual(operation.limits.responseBytes);
      expect(operation.outputPolicy.maxBytes).toBeLessThanOrEqual(8_192);
      expect(operation.limits.responseBytes).toBe(8_192);
      expect(operation.limits.pageBytes).toBe(8_192);
      expect(operation.limits.timeoutMs).toBeLessThanOrEqual(30_000);

      expect(descriptor.baseUrl).toBe(expected.baseUrl);
      expect(descriptor.baseUrl === "{api_origin}" || descriptor.baseUrl.startsWith("https://")).toBe(true);
      expect(descriptor.baseUrl).not.toContain("http://");
      expect(definition.authProfileId).toBe(expected.authProfileId);
      expect(row?.auth.profileId).toBe(expected.authProfileId);
      expect(row?.auth.minimumScopes).toEqual(expected.scopes);
      expect(row?.operations).toEqual(definition.operations);
      expect(row?.effects[operation.name]).toEqual({ effect: "read", approval: "mode" });
      expect(row?.catalogOwner).toBe("task-7-dev-work");
      expect(row?.isolationEvidence.length).toBeGreaterThan(0);
      expect(row?.fixtures.length).toBeGreaterThanOrEqual(2);

      const docs = row?.officialDocs ?? [];
      expect(docs.some((doc) =>
        doc.url === expected.doc && doc.apiVersion === expected.apiVersion &&
        doc.verifiedAt === "2026-10-24" && doc.reviewer.length > 0
      )).toBe(true);
      expect(definition.officialDocs.some((doc) => doc.url === expected.doc && doc.verifiedAt === "2026-10-24")).toBe(true);

      for (const key of ["unknown", "base", "baseUrl", "url", "host", "proxy", "headers", "body", "query", "graphql"]) {
        expect(validateProviderArgs(operation.inputSchema, { ...fixture?.args, [key]: "https://evil.example" }).ok, key).toBe(false);
      }
      expect(validateProviderArgs(operation.inputSchema, fixture?.args ?? {}).ok).toBe(true);
      expect(JSON.stringify(fixture)).not.toMatch(/start_url|join_url|refresh_token|client_secret/);
    });
  }

  it("derives production exports only from complete supported evidence rows, never candidates", () => {
    const evidencedIds = DEV_WORK_READINESS_ROWS.filter((row) =>
      row.releaseState === "supported" && row.automatedEvidence.result === "passed" &&
      row.automatedEvidence.runAt !== null && row.liveReadEvidence !== null && row.credentials === "passed"
    ).map((row) => row.providerId);
    expect(DEV_WORK_PROVIDERS.map((entry) => entry.providerId)).toEqual(evidencedIds);
    for (const row of DEV_WORK_READINESS_ROWS) {
      if (row.releaseState !== "supported" || row.liveReadEvidence === null || row.credentials !== "passed") {
        expect(DEV_WORK_PROVIDERS.some((entry) => entry.providerId === row.providerId)).toBe(false);
        expect(CURATED_IDS).not.toContain(row.providerId);
        expect(CURATED_MANIFEST.some((entry) => entry.curatedId === row.providerId)).toBe(false);
      }
    }
  });

  it("executes a synthetically promoted devWork row through the registry catalog with pinned egress", async () => {
    const definition = definitionFor("vercel");
    const readiness = DEV_WORK_READINESS_ROWS.find((row) => row.providerId === "vercel");
    if (readiness === undefined) throw new Error("Missing Vercel readiness fixture");
    const registry = createProviderRegistry();
    registry.registerProvider(definition, {
      ...readiness,
      releaseState: "supported",
      credentials: "passed",
      liveReadEvidence: {
        command: "OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_VERCEL=1 <synthetic catalog wiring test>",
        operationId: "list_projects",
        runAt: "2026-10-24T16:20:53.000Z",
        evidence: "sanitized-result: synthetic catalog wiring fixture only; not a live-read claim",
      },
    });

    const requests: EgressRequest[] = [];
    const providerEgress: ProviderEgress = {
      async request(request) {
        requests.push(request);
        return {
          status: 200,
          headers: new Headers({ "content-type": "application/json" }),
          body: new Response(JSON.stringify({
            projects: [{ id: "prj_synthetic", name: "Synthetic", env: [{ value: "synthetic-env-secret" }] }],
            pagination: { count: 1, next: null },
          })).body as ReadableStream<Uint8Array>,
          origin: new URL(request.url.origin),
          remoteAddress: "192.0.2.20",
        };
      },
      async close() {},
    };
    const workspace: WorkspaceFiles = {
      async read() { return null; },
      async write() {},
      async list() { return []; },
      async stat() { return null; },
      async remove() {},
    };
    const catalog = createCuratedCatalog({
      registry,
      providerEgress,
      workspace,
      fetchImpl: async () => { throw new Error("generic Fetch delegation is forbidden"); },
    });
    const entry = catalog.get("vercel");
    expect(entry).toBeDefined();
    const ctx: McpCallContext = {
      uid: "synthetic-catalog-user",
      secrets: { access_token: "synthetic-access-token" },
      workspace: {},
      fetchImpl: async () => { throw new Error("generic Fetch delegation is forbidden"); },
    };
    const result = await entry!.handler.callTool("list_projects", { limit: 1 }, ctx);
    expect(result.isError).toBe(false);
    expect(result.text).not.toContain("synthetic-env-secret");
    expect(requests).toHaveLength(1);
    expect(requests[0].originKey).toBe("vercel");
    expect(entry?.credentialFields).toEqual([
      { key: "access_token", label: "Vercel access token", secret: true },
    ]);
    expect(entry?.tools).toHaveLength(1);
    for (const routeOnlyKey of ["queryArgs", "fixedQuery", "queryArgMap"]) {
      expect(entry?.tools[0]).not.toHaveProperty(routeOnlyKey);
    }
  });
});

describe("current-provider corrections and effect boundaries", () => {
  it("pins Vercel to the resource-specific projects v10 read, not a blanket API version", () => {
    const definition = definitionFor("vercel");
    expect(definition.operations[0].request.pathTemplate).toBe("/v10/projects");
    expect(definition.operations.every((operation) => !/deploy|domain|dns|cache|env/i.test(operation.name))).toBe(true);
  });

  it("binds Teams to delegated work/school OAuth and Confluence to a connection-owned cloud ID", () => {
    const teams = definitionFor("microsoft-teams");
    expect(teams.authProfileId).toContain("delegated-work-school");
    expect(teams.operations[0].requiredScopes).toEqual(["Team.ReadBasic.All"]);
    expect(teams.operations[0].request.pathTemplate).toBe("/v1.0/teams/{team_id}");

    const confluence = definitionFor("confluence");
    const properties = confluence.connectionSchema.properties as Record<string, unknown>;
    expect(confluence.connectionSchema.required).toContain("cloud_id");
    expect(properties.cloud_id).toBeDefined();
    expect(validateProviderArgs(confluence.operations[0].inputSchema, { cloud_id: "model-selected", limit: 50 }).ok).toBe(false);
    expect(confluence.operations[0].requiredScopes).toEqual(["read:space:confluence"]);
    expect(confluence.authProfileId).toContain("3lo");
  });

  it("keeps Twilio and WhatsApp sends/calls out instead of mislabeling external effects", () => {
    for (const id of ["twilio", "whatsapp-business"]) {
      const definition = definitionFor(id);
      expect(definition.operations.every((operation) => operation.effect === "read" && operation.request.method === "GET")).toBe(true);
      expect(definition.operations.some((operation) => /send|create|call|campaign|history/i.test(operation.name))).toBe(false);
      expect(definition.operations.every((operation) => operation.approval === "mode")).toBe(true);
    }
    expect(definitionFor("twilio").operations[0].name).toBe("list_messages");
    expect(definitionFor("whatsapp-business").operations[0].name).toBe("list_phone_numbers");
  });

  it("uses Shortcut v3 header auth and Freshdesk v2 with a restricted-agent profile", () => {
    expect(descriptorFor("shortcut").authHeader).toBe("Shortcut-Token");
    expect(descriptorFor("shortcut").auth).toBe("apiKeyHeader");
    expect(descriptorFor("shortcut").baseUrl).not.toContain("v2");
    expect(JSON.stringify(descriptorFor("shortcut"))).not.toContain("queryKey");

    const freshdesk = definitionFor("freshdesk");
    expect(freshdesk.operations[0].request.pathTemplate).toBe("/api/v2/tickets");
    expect(freshdesk.authProfileId).toContain("restricted-view-agent");
    expect(freshdesk.operations[0].request.pathTemplate).not.toContain("/api/v1/");
  });

  it("pins Intercom, WhatsApp, and Klaviyo to their current regional/revisioned profiles", () => {
    expect(descriptorFor("intercom").staticHeaders?.["Intercom-Version"]).toBe("2.17");
    const intercomOrigins = definitionFor("intercom").connectionSchema.properties as Record<string, { enum?: readonly string[] }>;
    expect(intercomOrigins.api_origin.enum).toEqual([
      "https://api.intercom.io",
      "https://api.eu.intercom.io",
      "https://api.au.intercom.io",
    ]);

    const whatsapp = definitionFor("whatsapp-business");
    expect(whatsapp.operations[0].requiredScopes).toEqual(["whatsapp_business_management"]);
    expect(whatsapp.operations[0].requiredScopes).not.toContain("whatsapp_business_messaging");
    expect(whatsapp.description).toMatch(/webhook/i);
    expect(whatsapp.description).toMatch(/no history|not.*history/i);

    const klaviyo = definitionFor("klaviyo");
    expect(klaviyo.authProfileId).toContain("pkce-s256");
    expect(descriptorFor("klaviyo").staticHeaders?.revision).toBe("2026-10-15");
    expect(klaviyo.operations[0].request.pathTemplate).not.toMatch(/\/v[12]\//);
  });
});
