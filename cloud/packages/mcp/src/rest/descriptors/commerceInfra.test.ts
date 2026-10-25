import { describe, expect, it } from "vitest";

import { COMMERCE_INFRA_PROVIDER_IDS } from "../../catalog.js";
import type { EgressRequest, ProviderEgress } from "../../egress/responseLimits.js";
import type { McpCallContext } from "../../transports/native.js";
import {
  COMMERCE_INFRA_DESCRIPTORS,
  createCommerceInfraHandler,
} from "./commerceInfra.js";

function descriptor(id: string) {
  const value = COMMERCE_INFRA_DESCRIPTORS.find((entry) => entry.curatedId === id);
  if (value === undefined) throw new Error(`missing test descriptor ${id}`);
  return value;
}

function json(body: unknown, origin = "https://provider.invalid") {
  return {
    status: 200,
    headers: new Headers({ "content-type": "application/json" }),
    body: new Response(JSON.stringify(body)).body!,
    origin: new URL(origin),
    remoteAddress: "192.0.2.2",
  };
}

function ctx(secrets: Record<string, string>, onLegacy = () => {}): McpCallContext {
  return {
    uid: "user-one",
    secrets,
    workspace: {},
    fetchImpl: async () => { onLegacy(); throw new Error("legacy fetch denied"); },
  };
}

function recordingEgress(requests: EgressRequest[], body: unknown = { ok: true }) {
  return (origins: Readonly<Record<string, readonly URL[]>>): ProviderEgress => {
    expect(Object.values(origins)).toHaveLength(1);
    return {
      async request(request) {
        requests.push(request);
        if (request.url.pathname === "/v2/auth/token") return json({ access_token: "short-lived-jwt" });
        return json(body, request.url.origin);
      },
      async close() {},
    };
  };
}

describe("commerceInfra request construction and tenant boundaries", () => {
  it("includes only the narrow Kubernetes read and never the blocked original IDs", () => {
    expect(COMMERCE_INFRA_PROVIDER_IDS).toContain("kubernetes");
    expect(COMMERCE_INFRA_PROVIDER_IDS).not.toContain("zapier");
    expect(COMMERCE_INFRA_PROVIDER_IDS).not.toContain("opsgenie");
    expect(new Set(COMMERCE_INFRA_PROVIDER_IDS).size).toBe(COMMERCE_INFRA_PROVIDER_IDS.length);
  });

  it.each([
    ["woocommerce", "list_products", { consumer_key: "ck", consumer_secret: "cs", store_url: "http://store.example.com" }],
    ["woocommerce", "list_products", { consumer_key: "ck", consumer_secret: "cs", store_url: "https://127.0.0.1" }],
    ["woocommerce", "list_products", { consumer_key: "ck", consumer_secret: "cs", store_url: "https://user:pass@store.example.com" }],
    ["woocommerce", "list_products", { consumer_key: "ck", consumer_secret: "cs", store_url: "https://store.example.com/base" }],
    ["grafana", "list_folders", { access_token: "gt", instance_url: "https://localhost" }],
    ["n8n", "list_workflows", { api_key: "nk", instance_url: "https://n8n.example.com:8443", edition: "enterprise" }],
    ["n8n", "list_workflows", { api_key: "nk", instance_url: "https://n8n.example.com", edition: "community" }],
    ["shopify", "list_products", { access_token: "st", shop: "victim.myshopify.com.attacker.invalid" }],
    ["salesforce", "list_accounts", { access_token: "sf", instance_url: "https://my.salesforce.com.attacker.invalid" }],
    ["salesforce", "list_accounts", { access_token: "sf", instance_url: "https://tenant.my.salesforce.com/redirect" }],
    ["pipedrive", "list_deals", { access_token: "pd", company: "company.pipedrive.com.attacker.invalid" }],
    ["jira-service-management", "list_service_desks", { access_token: "jsm", cloud_id: "tenant.atlassian.net.attacker.invalid" }],
    ["kubernetes", "get_version", { access_token: "ks", apiserver_url: "http://cluster.example.com" }],
    ["kubernetes", "get_version", { access_token: "ks", apiserver_url: "https://10.0.0.5" }],
    ["kubernetes", "get_version", { access_token: "ks", apiserver_url: "https://cluster.example.com:6443" }],
    ["kubernetes", "get_version", { access_token: "ks", apiserver_url: "https://cluster.example.com/api/v1" }],
  ])("rejects an unauthenticated or credential-forwarding origin before egress: %s %s", async (id, operation, secrets) => {
    let factories = 0;
    let legacy = 0;
    const handler = createCommerceInfraHandler(id, {
      egressFactory: () => { factories += 1; throw new Error("must not construct egress"); },
    });
    const result = await handler.callTool(operation, {}, ctx(secrets, () => { legacy += 1; }));
    expect(result.isError).toBe(true);
    expect(factories).toBe(0);
    expect(legacy).toBe(0);
  });

  it("validates model input before resolving authenticated connection config", async () => {
    let resolved = 0;
    let factories = 0;
    const handler = createCommerceInfraHandler("shopify", {
      resolveConnectionConfig: async () => { resolved += 1; return { access_token: "st", shop: "safe-shop" }; },
      egressFactory: () => { factories += 1; throw new Error("must not construct egress"); },
    });
    const result = await handler.callTool("list_products", {
      query: "{ shop { name } }",
      baseUrl: "https://attacker.invalid",
    }, ctx({}));
    expect(result.isError).toBe(true);
    expect(resolved).toBe(0);
    expect(factories).toBe(0);
  });

  it("reads only the official Kubernetes server-version document with a required bearer token", async () => {
    const requests: EgressRequest[] = [];
    const handler = createCommerceInfraHandler("kubernetes", {
      egressFactory: recordingEgress(requests, {
        major: "1", minor: "37", gitVersion: "v1.37.0", platform: "linux/amd64",
      }),
    });
    const result = await handler.callTool("get_version", {}, ctx({
      access_token: "kubernetes-service-account-token",
      apiserver_url: "https://cluster.example.com",
    }));
    expect(result.isError, result.text).toBe(false);
    expect(requests).toHaveLength(1);
    expect(requests[0].method).toBe("GET");
    expect(requests[0].url.toString()).toBe("https://cluster.example.com/version");
    expect(requests[0].headers.Authorization).toBe("Bearer kubernetes-service-account-token");
    expect(requests[0].redirect).toBe("deny");
    expect(requests[0].body).toBeUndefined();
  });

  // Heavy-paused wave: the added variants below are authored regressions and
  // remain UNEXECUTED until the user lifts HEAVY-COMMANDS-PAUSED.md. Earlier
  // runs of the original nine cases are historical evidence, not current proof.
  it.each([
    ["empty query delimiter", "https://cluster.example.com?"],
    ["empty query after root slash", "https://cluster.example.com/?"],
    ["query parameter", "https://cluster.example.com?next=/api/v1"],
    ["encoded query delimiter in path", "https://cluster.example.com/%3f/version"],
    ["empty fragment delimiter", "https://cluster.example.com#"],
    ["fragment", "https://cluster.example.com#version"],
    ["userinfo", "https://user:pass@cluster.example.com"],
    ["userinfo without password", "https://user@cluster.example.com"],
    ["encoded slash in authority", "https://cluster.example.com%2fversion"],
    ["encoded backslash path", "https://cluster.example.com/%5c.."],
    ["encoded dot segment", "https://cluster.example.com/%2e%2e/"],
    ["encoded current-directory segment", "https://cluster.example.com/%2e/"],
    ["root trailing slash", "https://cluster.example.com/"],
    ["duplicate trailing slashes", "https://cluster.example.com//"],
  ])("keeps Kubernetes request composition on exactly /version or denies before egress: %s", async (_name, apiserverUrl) => {
    const requests: EgressRequest[] = [];
    const handler = createCommerceInfraHandler("kubernetes", {
      egressFactory: recordingEgress(requests, {
        major: "1", minor: "37", gitVersion: "v1.37.0", platform: "linux/amd64",
      }),
    });
    const result = await handler.callTool("get_version", {}, ctx({
      access_token: "review-token",
      apiserver_url: apiserverUrl,
    }));
    if (apiserverUrl === "https://cluster.example.com/") {
      expect(result.isError, result.text).toBe(false);
      expect(requests).toHaveLength(1);
      expect(requests[0].method).toBe("GET");
      expect(requests[0].url.origin).toBe("https://cluster.example.com");
      expect(requests[0].url.pathname).toBe("/version");
      expect(requests[0].url.toString()).toBe("https://cluster.example.com/version");
      expect(requests[0].url.search).toBe("");
      expect(requests[0].url.hash).toBe("");
      expect(requests[0].headers.Authorization).toBe("Bearer review-token");
    } else {
      expect(result.isError, `${apiserverUrl}: ${result.text}`).toBe(true);
      expect(requests, apiserverUrl).toHaveLength(0);
    }
  });

  it("isolates Kubernetes cluster origins and service-account tokens between calls", async () => {
    const requests: EgressRequest[] = [];
    const handler = createCommerceInfraHandler("kubernetes", {
      egressFactory: recordingEgress(requests, {
        major: "1", minor: "37", gitVersion: "v1.37.0", platform: "linux/amd64",
      }),
    });
    for (const tenant of ["one", "two"]) {
      const result = await handler.callTool("get_version", {}, ctx({
        access_token: `service-account-${tenant}`,
        apiserver_url: `https://cluster-${tenant}.example.com`,
      }));
      expect(result.isError, result.text).toBe(false);
    }
    expect(requests.map((request) => request.url.origin)).toEqual([
      "https://cluster-one.example.com", "https://cluster-two.example.com",
    ]);
    expect(requests[0].headers.Authorization).not.toBe(requests[1].headers.Authorization);
    expect(requests[1].secretValues).not.toContain("service-account-one");
    expect(requests[1].secretValues).not.toContain("https://cluster-one.example.com");
  });

  it("rejects custom Kubernetes trust inputs before connection resolution can widen trust", async () => {
    const requests: EgressRequest[] = [];
    const handler = createCommerceInfraHandler("kubernetes", {
      egressFactory: recordingEgress(requests),
    });
    const result = await handler.callTool("get_version", {}, ctx({
      access_token: "token",
      apiserver_url: "https://cluster.example.com",
      ca_cert: "caller-supplied-ca",
      client_certificate: "caller-supplied-client-cert",
    }));
    expect(result.isError).toBe(true);
    expect(requests).toHaveLength(0);
  });

  it("uses a fixed Shopify GraphQL document and typed pagination variables", async () => {
    const requests: EgressRequest[] = [];
    const handler = createCommerceInfraHandler("shopify", {
      egressFactory: recordingEgress(requests, {
        data: { products: { nodes: [], pageInfo: { hasNextPage: false, endCursor: null } } },
      }),
    });
    const result = await handler.callTool("list_products", { first: 3, after: "cursor-one" },
      ctx({ access_token: "shopify-secret", shop: "safe-shop" }));
    expect(result.isError).toBe(false);
    expect(requests).toHaveLength(1);
    expect(requests[0].url.toString()).toBe("https://safe-shop.myshopify.com/admin/api/2026-10/graphql.json");
    const body = JSON.parse(new TextDecoder().decode(requests[0].body)) as { query: string; variables: unknown };
    expect(body.query).toContain("products(first: $first, after: $after)");
    expect(body.query).not.toContain("mutation");
    expect(body.variables).toEqual({ first: 3, after: "cursor-one" });
  });

  it("routes Jira Service Management OAuth 3LO through the bound cloud ID on api.atlassian.com", async () => {
    const requests: EgressRequest[] = [];
    const allowedOrigins: string[] = [];
    const handler = createCommerceInfraHandler("jira-service-management", {
      egressFactory: (origins) => {
        allowedOrigins.push(origins["jira-service-management"]?.[0]?.origin ?? "missing");
        return recordingEgress(requests, {
          size: 0, start: 0, limit: 10, isLastPage: true, values: [],
        })(origins);
      },
    });
    const result = await handler.callTool("list_service_desks", {},
      ctx({ access_token: "jsm-secret", cloud_id: "cloud-one" }));
    expect(result.isError, result.text).toBe(false);
    expect(allowedOrigins).toEqual(["https://api.atlassian.com"]);
    expect(requests).toHaveLength(1);
    expect(requests[0].url.toString()).toBe(
      "https://api.atlassian.com/ex/jira/cloud-one/rest/servicedeskapi/servicedesk?limit=10&start=0",
    );
    expect(requests[0].headers.Authorization).toBe("Bearer jsm-secret");
  });

  it("sends the official YouTube pageToken continuation parameter", async () => {
    const requests: EgressRequest[] = [];
    const handler = createCommerceInfraHandler("youtube", {
      egressFactory: recordingEgress(requests, {
        kind: "youtube#channelListResponse", pageInfo: {}, items: [],
      }),
    });
    const result = await handler.callTool("list_channels", { pageToken: "next-page-token" },
      ctx({ access_token: "youtube-secret" }));
    expect(result.isError, result.text).toBe(false);
    expect(requests).toHaveLength(1);
    expect(requests[0].url.searchParams.get("pageToken")).toBe("next-page-token");
    expect(requests[0].url.searchParams.has("page_token")).toBe(false);
  });

  it("uses a server-owned Salesforce SOQL statement", async () => {
    const requests: EgressRequest[] = [];
    const handler = createCommerceInfraHandler("salesforce", {
      egressFactory: recordingEgress(requests, { totalSize: 0, done: true, records: [] }),
    });
    const result = await handler.callTool("list_accounts", {},
      ctx({ access_token: "salesforce-secret", instance_url: "https://tenant.my.salesforce.com" }));
    expect(result.isError).toBe(false);
    expect(requests[0].url.origin).toBe("https://tenant.my.salesforce.com");
    expect(requests[0].url.searchParams.get("q")).toBe("SELECT Id,Name FROM Account LIMIT 10");
    expect(requests[0].url.searchParams.get("nextRecordsUrl")).toBeNull();
  });

  it("binds New Relic account reads to the authenticated account and fixed document", async () => {
    const requests: EgressRequest[] = [];
    let factories = 0;
    const factory = (origins: Readonly<Record<string, readonly URL[]>>): ProviderEgress => {
      factories += 1;
      return recordingEgress(requests, {
        data: { actor: { account: { id: 123456, name: "sanitized" } } },
      })(origins);
    };
    const handler = createCommerceInfraHandler("newrelic", { egressFactory: factory });
    const config = { user_key: "nr-secret", region_host: "api.eu.newrelic.com", account_id: "123456" };
    const denied = await handler.callTool("get_account", { account_id: 999999 }, ctx(config));
    expect(denied.isError).toBe(true);
    expect(factories).toBe(0);
    const result = await handler.callTool("get_account", { account_id: 123456 }, ctx(config));
    expect(result.isError, result.text).toBe(false);
    expect(factories).toBe(1);
    expect(requests[0].url.toString()).toBe("https://api.eu.newrelic.com/graphql");
    const body = JSON.parse(new TextDecoder().decode(requests[0].body)) as { query: string; variables: unknown };
    expect(body.query).toBe("query OvidReadAccount($id: Int!) { actor { account(id: $id) { id name } } }");
    expect(body.variables).toEqual({ id: 123456 });
    const projected = JSON.parse(result.text) as { data: { actor: { account: { id: unknown } } } };
    expect(projected.data.actor.account.id).toBe("[REDACTED]");
    expect(result.text).not.toContain('"id":123456');
  });

  it("never reuses a Docker Hub JWT or PAT across calls or tenants", async () => {
    const requests: EgressRequest[] = [];
    const factory = (): ProviderEgress => ({
      async request(request) {
        requests.push(request);
        if (request.url.pathname === "/v2/auth/token") {
          const body = JSON.parse(new TextDecoder().decode(request.body)) as { identifier: string; secret: string };
          return json({ access_token: `jwt-${body.identifier}-${body.secret}` }, request.url.origin);
        }
        return json({ results: [] }, request.url.origin);
      },
      async close() {},
    });
    const handler = createCommerceInfraHandler("docker-hub", { egressFactory: factory });
    for (const user of ["one", "two"]) {
      const result = await handler.callTool("list_repositories", {}, ctx({
        username: `user-${user}`, secret: `pat-${user}`, namespace: `namespace-${user}`,
      }));
      expect(result.isError).toBe(false);
    }
    expect(requests).toHaveLength(4);
    expect(requests[1].headers.Authorization).toBe("Bearer jwt-user-one-pat-one");
    expect(requests[3].headers.Authorization).toBe("Bearer jwt-user-two-pat-two");
    expect(requests[1].url.pathname).toBe("/v2/namespaces/namespace-one/repositories");
    expect(requests[3].url.pathname).toBe("/v2/namespaces/namespace-two/repositories");
    expect(requests[3].secretValues).not.toContain("pat-one");
  });

  it("keeps self-hosted origins and credentials isolated across sequential calls", async () => {
    const requests: EgressRequest[] = [];
    const handler = createCommerceInfraHandler("woocommerce", { egressFactory: recordingEgress(requests, []) });
    for (const tenant of ["one", "two"]) {
      const result = await handler.callTool("list_products", {}, ctx({
        consumer_key: `ck-${tenant}`, consumer_secret: `cs-${tenant}`, store_url: `https://store-${tenant}.example.com`,
      }));
      expect(result.isError).toBe(false);
    }
    expect(requests.map((request) => request.url.origin)).toEqual([
      "https://store-one.example.com", "https://store-two.example.com",
    ]);
    expect(requests[0].headers.Authorization).not.toBe(requests[1].headers.Authorization);
    expect(requests[1].secretValues).not.toContain("cs-one");
    expect(requests[1].secretValues).not.toContain("https://store-one.example.com");
  });

  it("denies arbitrary operation names and workflow/action surfaces", async () => {
    let factories = 0;
    for (const [id, config, names] of [
      ["make", { api_token: "m", zone: "eu1.make.com", team_id: "1" }, ["run_scenario", "activate_scenario", "invoke_webhook"]],
      ["n8n", { api_key: "n", instance_url: "https://n8n.example.com", edition: "enterprise" }, ["run_workflow", "activate_workflow", "invoke_webhook"]],
      ["terraform-cloud", { access_token: "t", organization: "o" }, ["create_run", "apply_run", "destroy_workspace"]],
      ["pagerduty", { access_token: "p" }, ["create_incident", "add_note", "escalate"]],
      ["kubernetes", { access_token: "k", apiserver_url: "https://cluster.example.com" }, [
        "list_pods", "watch_pods", "proxy", "exec", "get_secret", "scale_deployment",
        "rollout_restart", "delete_pod", "raw_api", "list_namespaces",
      ]],
    ] as const) {
      const handler = createCommerceInfraHandler(id, { egressFactory: () => { factories += 1; throw new Error("denied"); } });
      for (const name of names) {
        const result = await handler.callTool(name, {}, ctx(config));
        expect(result.isError).toBe(true);
        expect(result.text).toContain("Unknown provider operation");
      }
    }
    expect(factories).toBe(0);
  });

  it("enforces response byte caps without falling back to legacy fetch", async () => {
    let legacy = 0;
    const handler = createCommerceInfraHandler("hubspot", {
      egressFactory: () => ({
        async request(request) {
          return {
            status: 200,
            headers: new Headers({ "content-type": "application/json" }),
            body: new Response(`{"data":"${"x".repeat(300_000)}"}`).body!,
            origin: request.url,
            remoteAddress: "192.0.2.2",
          };
        },
        async close() {},
      }),
    });
    const result = await handler.callTool("list_contacts", {}, ctx({ access_token: "hubspot-secret" }, () => { legacy += 1; }));
    expect(result.isError).toBe(true);
    expect(legacy).toBe(0);
  });

  it("pins current provider versions and read-only fixed query parameters", () => {
    expect(descriptor("square").staticHeaders?.["Square-Version"]).toBe("2026-09-16");
    expect(descriptor("vimeo").staticHeaders?.Accept).toBe("application/vnd.vimeo.*+json;version=3.4");
    expect(descriptor("shopify").baseUrl).toContain("/admin/api/2026-10");
    expect(descriptor("salesforce").tools[0].path).toContain("/services/data/v67.0/");
    expect(descriptor("pipedrive").tools[0].path).toContain("/api/v2/");
    expect(descriptor("docker-hub").tools[0].path).toContain("/v2/namespaces/");
    expect(descriptor("stackexchange").tools[0].fixedQuery).toMatchObject({ site: "stackoverflow", pagesize: "10" });
    expect(descriptor("make").tools[0].path).not.toMatch(/\/(run|start|activate|webhook)/);
    expect(descriptor("n8n").tools[0].path).not.toMatch(/\/(run|retry|stop|activate|webhook)/);
  });
});
