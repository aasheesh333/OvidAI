import { describe, expect, it } from "vitest";

import type {
  EgressRequest,
  EgressResponse,
  ProviderEgress,
} from "../../src/egress/providerEgress.js";
import {
  createDevWorkHandler,
  executeDevWorkLiveAttempt,
  DEV_WORK_CANDIDATE_IDS,
  DEV_WORK_CONTRACT_DEFINITIONS,
  DEV_WORK_FIXTURES,
  type DevWorkFixture,
} from "../../src/rest/descriptors/devWork.js";
import type { McpCallContext } from "../../src/transports/native.js";

class FakeProviderEgress implements ProviderEgress {
  readonly requests: EgressRequest[] = [];

  constructor(private readonly respond: (request: EgressRequest, index: number) => unknown) {}

  async request(request: EgressRequest): Promise<EgressResponse> {
    this.requests.push(request);
    const body = JSON.stringify(this.respond(request, this.requests.length - 1));
    return {
      status: 200,
      headers: new Headers({ "content-type": "application/json" }),
      body: new Response(body).body as ReadableStream<Uint8Array>,
      origin: new URL(request.url.origin),
      remoteAddress: "192.0.2.10",
    };
  }

  async close(): Promise<void> {}
}

function fixtureFor(id: string): DevWorkFixture {
  const fixture = DEV_WORK_FIXTURES.find((entry) => entry.providerId === id);
  if (fixture === undefined) throw new Error(`Missing fixture for ${id}`);
  return fixture;
}

function definitionFor(id: string) {
  const definition = DEV_WORK_CONTRACT_DEFINITIONS.find((entry) => entry.providerId === id);
  if (definition === undefined) throw new Error(`Missing definition for ${id}`);
  return definition;
}

function context(fixture: DevWorkFixture, onLegacyFetch: () => void, uid = "user-fixture-a"): McpCallContext {
  return {
    uid,
    secrets: { ...fixture.connection },
    workspace: {},
    fetchImpl: async () => {
      onLegacyFetch();
      throw new Error("generic Fetch delegation is forbidden");
    },
  };
}

function expectedUrl(id: string, fixture: DevWorkFixture): string {
  const c = fixture.connection;
  switch (id) {
    case "vercel": return "https://api.vercel.com/v10/projects?limit=1";
    case "cloudflare": return "https://api.cloudflare.com/client/v4/zones?page=1&per_page=5";
    case "asana": return "https://app.asana.com/api/1.0/workspaces?limit=1";
    case "trello": return "https://api.trello.com/1/members/me?fields=id%2Cusername";
    case "clickup": return "https://api.clickup.com/api/v2/user";
    case "shortcut": return "https://api.app.shortcut.com/api/v3/member";
    case "confluence": return `https://api.atlassian.com/ex/confluence/${c.cloud_id}/wiki/api/v2/spaces?limit=1`;
    case "microsoft-teams": return `https://graph.microsoft.com/v1.0/teams/${c.team_id}`;
    case "zoom": return "https://api.zoom.us/v2/users/me/meetings?type=scheduled&page_size=1";
    case "intercom": return `${c.api_origin}/contacts?per_page=1`;
    case "zendesk": return `https://${c.subdomain}.zendesk.com/api/v2/tickets.json?page%5Bsize%5D=1`;
    case "freshdesk": return `https://${c.subdomain}.freshdesk.com/api/v2/tickets?per_page=1&page=1`;
    case "twilio": return `https://api.twilio.com/2010-04-01/Accounts/${c.account_sid}/Messages.json?PageSize=1`;
    case "whatsapp-business": return `https://graph.facebook.com/${c.graph_version}/${c.waba_id}/phone_numbers?limit=1`;
    case "mailchimp": return "https://api.mailchimp.com/3.0/lists?count=1&offset=0&fields=lists.id%2Clists.name%2Ctotal_items";
    case "sendgrid": return "https://api.sendgrid.com/v3/stats?aggregated_by=day&limit=1&offset=0&start_date=2026-10-01&end_date=2026-10-02";
    case "klaviyo": return "https://a.klaviyo.com/api/accounts/";
    default: throw new Error(`Missing expected URL for ${id}`);
  }
}

function expectedAuth(id: string, fixture: DevWorkFixture): Record<string, string> {
  const c = fixture.connection;
  switch (id) {
    case "shortcut": return { "Shortcut-Token": c.api_token };
    case "freshdesk": return { Authorization: `Basic ${Buffer.from(`${c.api_key}:X`).toString("base64")}` };
    case "twilio": return { Authorization: `Basic ${Buffer.from(`${c.api_key_sid}:${c.api_key_secret}`).toString("base64")}` };
    case "cloudflare": return { Authorization: `Bearer ${c.api_token}` };
    case "sendgrid": return { Authorization: `Bearer ${c.api_key}` };
    default: return { Authorization: `Bearer ${c.access_token}` };
  }
}

function secretFor(id: string, fixture: DevWorkFixture): string {
  if (id === "cloudflare" || id === "shortcut") return fixture.connection.api_token;
  if (id === "freshdesk" || id === "sendgrid") return fixture.connection.api_key;
  if (id === "twilio") return fixture.connection.api_key_secret;
  return fixture.connection.access_token;
}

function successfulResponseFor(id: string, payload: unknown): unknown {
  return id === "cloudflare"
    ? { success: true, errors: [], messages: [], result: [payload] }
    : payload;
}

function secondTenantFixture(fixture: DevWorkFixture): DevWorkFixture {
  const connection = Object.fromEntries(Object.entries(fixture.connection).map(([key, value]) => [
    key,
    value.replaceAll("tenant-a", "tenant-b").replaceAll("cloud-a", "cloud-b"),
  ]));
  if (fixture.providerId === "intercom") connection.api_origin = "https://api.eu.intercom.io";
  if (fixture.providerId === "microsoft-teams") connection.team_id = "00000000-0000-0000-0000-000000000002";
  if (fixture.providerId === "twilio") {
    connection.account_sid = `AC${"1".repeat(32)}`;
    connection.api_key_sid = `SK${"1".repeat(32)}`;
  }
  if (fixture.providerId === "whatsapp-business") connection.waba_id = "20002";
  return { ...fixture, connection };
}

describe("development/work/communications typed execution contracts", () => {
  for (const id of DEV_WORK_CANDIDATE_IDS) {
    it(`${id} executes its named read through pinned provider egress without generic Fetch`, async () => {
      const fixture = fixtureFor(id);
      const definition = definitionFor(id);
      const operation = definition.operations[0];
      const egress = new FakeProviderEgress(() => fixture.response);
      let legacyFetchCalls = 0;
      const handler = createDevWorkHandler(id, { providerEgress: egress });

      expect((await handler.listTools()).map((tool) => tool.name)).toEqual([operation.name]);
      const result = await handler.callTool(operation.name, fixture.args, context(fixture, () => legacyFetchCalls++));
      expect(result.isError).toBe(false);
      expect(legacyFetchCalls).toBe(0);
      expect(egress.requests).toHaveLength(1);
      const request = egress.requests[0];
      expect(request.originKey).toBe(id);
      expect(request.url.toString()).toBe(expectedUrl(id, fixture));
      expect(request.method).toBe("GET");
      expect(request.body).toBeUndefined();
      expect(request.privileged).toBe(true);
      expect(request.redirect).toBe("deny");
      expect(request.headers).toEqual({ Accept: "application/json", ...expectedAuth(id, fixture),
        ...(id === "shortcut" ? { "Content-Type": "application/json" } : {}),
        ...(id === "intercom" ? { "Intercom-Version": "2.17" } : {}),
        ...(id === "klaviyo" ? { revision: "2026-10-15" } : {}),
      });
      expect(operation.limits.responseBytes).toBe(8_192);
      expect(operation.limits.pageBytes).toBe(8_192);
      expect(operation.outputPolicy.maxBytes).toBe(8_192);
      expect(request.limits.responseBytes).toBe(8_192);
      expect(request.limits.decompressedBytes).toBe(32_768);

      const beforeInvalid = egress.requests.length;
      const invalid = await handler.callTool(operation.name, {
        ...fixture.args,
        url: "https://evil.example",
        body: { arbitrary: true },
      }, context(fixture, () => legacyFetchCalls++));
      expect(invalid.isError).toBe(true);
      expect(egress.requests).toHaveLength(beforeInvalid);
      expect(legacyFetchCalls).toBe(0);
    });

    it(`${id} isolates tenant A/B credentials and redacts echoed secrets`, async () => {
      const first = fixtureFor(id);
      const second = secondTenantFixture(first);
      const firstSecret = secretFor(id, first);
      const secondSecret = secretFor(id, second);
      expect(secondSecret).not.toBe(firstSecret);
      const egress = new FakeProviderEgress((_request, index) => successfulResponseFor(id, {
        secret_echo: index === 0 ? firstSecret : secondSecret,
      }));
      let legacyFetchCalls = 0;
      const handler = createDevWorkHandler(id, { providerEgress: egress });
      const operation = definitionFor(id).operations[0];

      const firstResult = await handler.callTool(operation.name, first.args, context(first, () => legacyFetchCalls++));
      const secondResult = await handler.callTool(
        operation.name,
        second.args,
        context(second, () => legacyFetchCalls++, "user-fixture-b"),
      );
      expect(firstResult.isError).toBe(false);
      expect(secondResult.isError).toBe(false);
      expect(egress.requests).toHaveLength(2);
      expect(egress.requests[0].headers).toMatchObject(expectedAuth(id, first));
      expect(egress.requests[1].headers).toMatchObject(expectedAuth(id, second));
      expect(egress.requests[0].headers).not.toEqual(egress.requests[1].headers);
      for (const result of [firstResult, secondResult]) {
        expect(result.text).not.toContain(firstSecret);
        expect(result.text).not.toContain(secondSecret);
        expect(result.text).toContain("[REDACTED]");
      }
      expect(legacyFetchCalls).toBe(0);
    });
  }

  for (const testCase of [
    { id: "vercel", keys: ["env", "deployHooks"] },
    { id: "cloudflare", keys: ["verification_key"] },
    { id: "clickup", keys: ["members"] },
    { id: "shortcut", keys: ["profile"] },
    { id: "zoom", keys: ["join_url", "start_url", "agenda", "settings"] },
    { id: "intercom", keys: ["external_id", "email", "phone", "name", "avatar", "custom_attributes", "social_profiles", "location", "companies", "notes"] },
    { id: "zendesk", keys: ["subject", "raw_subject", "description", "recipient", "requester_id", "submitter_id", "assignee_id", "collaborator_ids", "follower_ids", "email_cc_ids", "custom_fields", "satisfaction_rating", "via"] },
    { id: "freshdesk", keys: ["subject", "description", "description_text", "requester_id", "responder_id", "to_emails", "cc_emails", "fwd_emails", "reply_cc_emails", "custom_fields", "source_additional_info"] },
    { id: "twilio", keys: ["body", "to", "from"] },
    { id: "whatsapp-business", keys: ["display_phone_number"] },
  ]) {
    it(`${testCase.id} projects provider-sensitive response fields before returning JSON`, async () => {
      const fixture = fixtureFor(testCase.id);
      const canaries = Object.fromEntries(testCase.keys.map((key) => [key, `${testCase.id}-${key}-sensitive-canary`]));
      const egress = new FakeProviderEgress(() => successfulResponseFor(testCase.id, { id: "example", nested: canaries }));
      const handler = createDevWorkHandler(testCase.id, { providerEgress: egress });
      const operation = definitionFor(testCase.id).operations[0];
      const result = await handler.callTool(operation.name, fixture.args, context(fixture, () => {
        throw new Error("generic Fetch delegation is forbidden");
      }));
      expect(result.isError).toBe(false);
      for (const canary of Object.values(canaries)) expect(result.text).not.toContain(canary);
    });
  }

  it("accepts exactly 8,192 response bytes and rejects 8,193 before returning content", async () => {
    const fixture = fixtureFor("vercel");
    const overhead = Buffer.byteLength(JSON.stringify({ value: "" }));
    for (const size of [8_192, 8_193]) {
      const response = { value: "x".repeat(size - overhead) };
      expect(Buffer.byteLength(JSON.stringify(response))).toBe(size);
      const egress = new FakeProviderEgress(() => response);
      const handler = createDevWorkHandler("vercel", { providerEgress: egress });
      const result = await handler.callTool("list_projects", fixture.args, context(fixture, () => {
        throw new Error("generic Fetch delegation is forbidden");
      }));
      expect(result.isError, `response size ${size}`).toBe(size === 8_193);
      if (size === 8_192) expect(Buffer.byteLength(result.text)).toBe(8_192);
      expect(egress.requests[0].limits.responseBytes).toBe(8_192);
    }
  });

  it("accepts a realistic five-zone Cloudflare page and projects its sensitive field", async () => {
    const fixture = { ...fixtureFor("cloudflare"), args: { page: 1, per_page: 5 } };
    const zones = Array.from({ length: 5 }, (_, index) => ({
      id: `zone-${index}`,
      account: { id: "account-example", name: "Example Account" },
      activated_on: "2026-01-02T00:01:00.000Z",
      created_on: "2026-01-01T05:20:00.000Z",
      development_mode: 0,
      meta: { cdn_only: false, custom_certificate_quota: 0, dns_only: false, page_rule_quota: 0, step: 2 },
      modified_on: "2026-10-01T05:20:00.000Z",
      name: `example-${index}.test`,
      name_servers: ["a.ns.cloudflare.com", "b.ns.cloudflare.com"],
      original_dnshost: "Example Registrar",
      original_name_servers: ["ns1.example.test", "ns2.example.test"],
      original_registrar: "Example Registrar",
      owner: { id: "owner-example", name: "Example Owner", type: "organization" },
      plan: { id: "free", can_subscribe: true, currency: "USD", frequency: "monthly", is_subscribed: false, price: 0 },
      paused: false,
      status: "active",
      tenant: { id: "tenant-example", name: "Example Tenant" },
      tenant_unit: { id: "unit-example" },
      type: "full",
      vanity_name_servers: [],
      verification_key: `zone-${index}-sensitive-verification-key`,
    }));
    const response = {
      success: true,
      errors: [],
      messages: [],
      result: zones,
      result_info: { count: 5, page: 1, per_page: 5, total_count: 5, total_pages: 1 },
    };
    expect(Buffer.byteLength(JSON.stringify(response))).toBeLessThanOrEqual(8_192);
    const egress = new FakeProviderEgress(() => response);
    const handler = createDevWorkHandler("cloudflare", { providerEgress: egress });
    const result = await handler.callTool("list_zones", fixture.args, context(fixture, () => {
      throw new Error("generic Fetch delegation is forbidden");
    }));
    expect(result.isError).toBe(false);
    expect(result.text).not.toContain("sensitive-verification-key");
    expect(egress.requests[0].url.toString()).toContain("per_page=5");
  });

  it("rejects Cloudflare HTTP 200 failure or error-bearing envelopes instead of returning success", async () => {
    const fixture = fixtureFor("cloudflare");
    const responses = [
      { success: false, errors: [{ code: 10000, message: "upstream-error-canary" }], messages: [], result: null },
      { success: true, errors: [{ code: 10001, message: "partial-error-canary" }], messages: [], result: [] },
    ];
    for (const response of responses) {
      const egress = new FakeProviderEgress(() => response);
      const handler = createDevWorkHandler("cloudflare", { providerEgress: egress });
      const result = await handler.callTool("list_zones", fixture.args, context(fixture, () => {
        throw new Error("generic Fetch delegation is forbidden");
      }));
      expect(result.isError).toBe(true);
      expect(result.text).toBe("Provider returned an unsuccessful response.");
      expect(result.text).not.toMatch(/upstream-error-canary|partial-error-canary/);
    }
  });

  it("captures malformed tenant config and egress construction exceptions as failed live outcomes", async () => {
    const intercom = fixtureFor("intercom");
    const attempts = [
      {
        id: "intercom",
        config: { ...intercom.connection, api_origin: "https://%" },
        gate: "OVID_LIVE_PROVIDER_INTERCOM=1",
      },
      {
        id: "cloudflare",
        config: fixtureFor("cloudflare").connection,
        gate: "OVID_LIVE_PROVIDER_CLOUDFLARE=1",
      },
    ];
    for (const attempt of attempts) {
      const outcome = await executeDevWorkLiveAttempt({
        providerId: attempt.id,
        config: attempt.config,
        now: () => new Date("2026-10-24T17:50:00.000Z"),
        createEgress: () => { throw new Error("egress-construction-canary"); },
      });
      expect(outcome.credentials).toBe("failed");
      expect(outcome.result).toBe("sanitized exception: Error");
      expect(outcome.result).not.toContain("egress-construction-canary");
      expect(outcome.command).toContain("OVID_LIVE_PROVIDER_TESTS=1");
      expect(outcome.command).toContain(attempt.gate);
      expect(outcome.executedAt).toBe("2026-10-24T17:50:00.000Z");
    }
  });

  it("records a Cloudflare HTTP 200 failure envelope as a failed live outcome", async () => {
    const fixture = fixtureFor("cloudflare");
    const egress = new FakeProviderEgress(() => ({
      success: false,
      errors: [{ code: 10000, message: "live-upstream-error-canary" }],
      messages: [],
      result: null,
    }));
    const outcome = await executeDevWorkLiveAttempt({
      providerId: "cloudflare",
      config: fixture.connection,
      createEgress: () => egress,
      now: () => new Date("2026-10-24T17:50:00.000Z"),
    });
    expect(outcome.credentials).toBe("failed");
    expect(outcome.result).toBe("Provider returned an unsuccessful response.");
    expect(outcome.result).not.toContain("live-upstream-error-canary");
    expect(outcome.command).toContain("OVID_LIVE_PROVIDER_CLOUDFLARE=1");
  });

  it("refuses the legacy fetch fallback when pinned provider egress is not configured", async () => {
    const fixture = fixtureFor("vercel");
    let legacyFetchCalls = 0;
    const handler = createDevWorkHandler("vercel");
    const result = await handler.callTool("list_projects", fixture.args, context(fixture, () => legacyFetchCalls++));
    expect(result.isError).toBe(true);
    expect(result.text).toMatch(/pinned egress/i);
    expect(legacyFetchCalls).toBe(0);
  });

  for (const testCase of [
    { id: "confluence", key: "cloud_id", value: "../other-tenant" },
    { id: "intercom", key: "api_origin", value: "https://evil.example" },
    { id: "zendesk", key: "subdomain", value: "tenant.evil.example" },
    { id: "freshdesk", key: "subdomain", value: "tenant@evil.example" },
    { id: "twilio", key: "account_sid", value: "../other-account" },
    { id: "whatsapp-business", key: "graph_version", value: "https://evil.example" },
    { id: "whatsapp-business", key: "waba_id", value: "../other-waba" },
  ]) {
    it(`rejects invalid connection-owned tenant ${testCase.id}.${testCase.key} before egress`, async () => {
      const baseFixture = fixtureFor(testCase.id);
      const fixture = {
        ...baseFixture,
        connection: { ...baseFixture.connection, [testCase.key]: testCase.value },
      };
      const egress = new FakeProviderEgress(() => fixture.response);
      const handler = createDevWorkHandler(testCase.id, { providerEgress: egress });
      const operation = definitionFor(testCase.id).operations[0];
      const result = await handler.callTool(operation.name, fixture.args, context(fixture, () => {
        throw new Error("generic Fetch delegation is forbidden");
      }));
      expect(result.isError).toBe(true);
      expect(result.text).toMatch(/invalid connection configuration/i);
      expect(result.text).not.toContain(testCase.value);
      expect(egress.requests).toHaveLength(0);
    });
  }
});
