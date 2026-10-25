import { describe, expect, it } from "vitest";

import {
  ConnectorTenancyError,
  resolveConnectorTenantOrigin,
  type ConnectorTenancyErrorCode,
} from "./tenancy.js";

// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
// These are source-only regression tests until the user explicitly lifts that pause.

const CONNECTION_A = "01939a0f-0000-7000-8000-00000000000a";
const CONNECTION_B = "01939a0f-0000-7000-8000-00000000000b";

function resolve(
  providerId: string,
  connectionConfig: Readonly<Record<string, unknown>>,
  connectionId = CONNECTION_A,
) {
  return resolveConnectorTenantOrigin({ providerId, connectionId, connectionConfig });
}

function expectTenancyError(
  run: () => unknown,
  code: ConnectorTenancyErrorCode,
  valueNotInMessage?: string,
): void {
  let caught: unknown;
  try {
    run();
  } catch (error) {
    caught = error;
  }
  expect(caught).toBeInstanceOf(ConnectorTenancyError);
  expect((caught as ConnectorTenancyError).code).toBe(code);
  if (valueNotInMessage !== undefined) {
    expect((caught as ConnectorTenancyError).message).not.toContain(valueNotInMessage);
  }
}

describe("connector dynamic-tenant origin resolution", () => {
  it.each([
    ["jira", { host: "tenant-a.atlassian.net" }, "https://tenant-a.atlassian.net"],
    ["jira", { host: "https://tenant-a.atlassian.net" }, "https://tenant-a.atlassian.net"],
    ["supabase", { base_url: "https://projectref.supabase.co" }, "https://projectref.supabase.co"],
    ["zendesk", { subdomain: "tenant-a" }, "https://tenant-a.zendesk.com"],
    ["freshdesk", { subdomain: "tenant-a" }, "https://tenant-a.freshdesk.com"],
    ["shopify", { shop: "safe-shop" }, "https://safe-shop.myshopify.com"],
    ["pipedrive", { company: "safe-company" }, "https://safe-company.pipedrive.com"],
    ["algolia", { app_id: "ABC123" }, "https://abc123-dsn.algolia.net"],
    ["s3", { bucket: "bucket-a", region: "us-east-1" }, "https://bucket-a.s3.us-east-1.amazonaws.com"],
  ] as const)("pins %s to its descriptor-owned host template", (providerId, connectionConfig, expected) => {
    const pinned = resolve(providerId, connectionConfig);
    expect(pinned.origin).toBeInstanceOf(URL);
    expect(pinned.origin.origin).toBe(expected);
    expect(pinned.origin.pathname).toBe("/");
    expect(pinned.origin.search).toBe("");
    expect(pinned.origin.hash).toBe("");
    expect(pinned.originKey).toMatch(/^connector:[A-Za-z0-9_-]{43}$/);
  });

  it.each([
    ["salesforce", { instance_url: "https://tenant.my.salesforce.com" }, "https://tenant.my.salesforce.com"],
    ["salesforce", { instance_url: "https://acme--dev.sandbox.my.salesforce.com" }, "https://acme--dev.sandbox.my.salesforce.com"],
    ["snowflake", { account_url: "https://org-account.us-east-1.snowflakecomputing.com" }, "https://org-account.us-east-1.snowflakecomputing.com"],
    ["snowflake", { account_url: "https://myorg-account_name.snowflakecomputing.com" }, "https://myorg-account_name.snowflakecomputing.com"],
    ["databricks", { workspace_url: "https://workspace.cloud.databricks.com" }, "https://workspace.cloud.databricks.com"],
    ["databricks", { workspace_url: "https://adb-123.azuredatabricks.net" }, "https://adb-123.azuredatabricks.net"],
    ["databricks", { workspace_url: "https://workspace.gcp.databricks.com" }, "https://workspace.gcp.databricks.com"],
    ["intercom", { api_origin: "https://api.eu.intercom.io" }, "https://api.eu.intercom.io"],
    ["datadog", { site: "api.us3.datadoghq.com" }, "https://api.us3.datadoghq.com"],
    ["newrelic", { region_host: "api.eu.newrelic.com" }, "https://api.eu.newrelic.com"],
    ["make", { zone: "us1.make.com" }, "https://us1.make.com"],
    ["gitlab", {}, "https://gitlab.com"],
    ["gitlab", { host: "https://gitlab.com/" }, "https://gitlab.com"],
    ["gitlab", { host: "git.example.com" }, "https://git.example.com"],
    ["woocommerce", { store_url: "https://store.example.com" }, "https://store.example.com"],
    ["grafana", { instance_url: "https://grafana.example.com" }, "https://grafana.example.com"],
    ["kubernetes", { apiserver_url: "https://cluster.example.com" }, "https://cluster.example.com"],
    ["n8n", { instance_url: "https://n8n.example.com" }, "https://n8n.example.com"],
    ["elasticsearch", { instance_url: "https://search.example.com" }, "https://search.example.com"],
    ["typesense", { instance_url: "https://search.example.com" }, "https://search.example.com"],
    ["metabase", { instance_url: "https://bi.example.com" }, "https://bi.example.com"],
    ["redash", { instance_url: "https://bi.example.com" }, "https://bi.example.com"],
    ["superset", { instance_url: "https://bi.example.com" }, "https://bi.example.com"],
  ] as const)("accepts only the reviewed origin or region for %s", (providerId, connectionConfig, expected) => {
    expect(resolve(providerId, connectionConfig).origin.origin).toBe(expected);
  });

  it("canonicalizes case, one root slash, and the default HTTPS port", () => {
    const pinned = resolve("jira", { host: "HTTPS://TENANT-A.ATLASSIAN.NET:443/" });
    expect(pinned.origin.origin).toBe("https://tenant-a.atlassian.net");
    expect(pinned.origin.href).toBe("https://tenant-a.atlassian.net/");
    expect(pinned.origin.port).toBe("");
  });

  it("keeps the trusted origin/key binding immutable when a caller mutates a returned URL snapshot", () => {
    const pinned = resolve("zendesk", { subdomain: "tenant-a" });
    const originalKey = pinned.originKey;
    const mutated = pinned.origin;
    mutated.hostname = "attacker.invalid";

    expect(mutated.origin).toBe("https://attacker.invalid");
    expect(pinned.origin).not.toBe(mutated);
    expect(pinned.origin.origin).toBe("https://tenant-a.zendesk.com");
    expect(pinned.origin.href).toBe("https://tenant-a.zendesk.com/");
    expect(pinned.originKey).toBe(originalKey);
    expect(Object.isFrozen(pinned)).toBe(true);
  });

  it("scopes and binds the origin key to provider, connection, and canonical origin", () => {
    const first = resolve("zendesk", { subdomain: "tenant-a" }, CONNECTION_A);
    const same = resolve("zendesk", { subdomain: "tenant-a" }, CONNECTION_A);
    const otherConnection = resolve("zendesk", { subdomain: "tenant-a" }, CONNECTION_B);
    const otherOrigin = resolve("zendesk", { subdomain: "tenant-b" }, CONNECTION_A);
    const otherProvider = resolve("freshdesk", { subdomain: "tenant-a" }, CONNECTION_A);

    expect(same.originKey).toBe(first.originKey);
    expect(otherConnection.originKey).not.toBe(first.originKey);
    expect(otherOrigin.originKey).not.toBe(first.originKey);
    expect(otherProvider.originKey).not.toBe(first.originKey);
  });

  it.each(["", "bad connection", "../other", "connection:one", "a".repeat(129)])(
    "rejects an unsafe connection identity before producing an origin key: %s",
    (connectionId) => {
      expectTenancyError(
        () => resolve("zendesk", { subdomain: "tenant-a" }, connectionId),
        "invalid_connection",
      );
    },
  );

  it.each([
    "-tenant",
    "tenant-",
    "tenant..two",
    "tenant_two",
    "tenant/two",
    "%2e%2e",
    "victim.zendesk.com.attacker.invalid",
    "a".repeat(64),
    "",
  ])("rejects a malformed tenant label instead of interpolating it into a host: %s", (subdomain) => {
    expectTenancyError(
      () => resolve("zendesk", { subdomain }),
      "invalid_tenant_config",
    );
  });

  it("requires own string properties from normalized authenticated connection config", () => {
    expectTenancyError(() => resolve("zendesk", {}), "invalid_tenant_config");
    expectTenancyError(() => resolve("zendesk", { subdomain: 42 }), "invalid_tenant_config");
    const inherited = Object.create({ subdomain: "tenant-a" }) as Record<string, unknown>;
    expectTenancyError(() => resolve("zendesk", inherited), "invalid_tenant_config");
  });

  it("uses only the descriptor-owned connection field, never model-shaped URL overrides", () => {
    const pinned = resolve("shopify", {
      shop: "safe-shop",
      baseUrl: "https://attacker.invalid",
      host: "attacker.invalid",
      url: "https://attacker.invalid",
    });
    expect(pinned.origin.origin).toBe("https://safe-shop.myshopify.com");
  });

  it.each([
    "http://cluster.example.com",
    "https://user:pass@cluster.example.com",
    "https://user@cluster.example.com",
    "https://cluster.example.com?",
    "https://cluster.example.com/?",
    "https://cluster.example.com?next=/api/v1",
    "https://cluster.example.com#",
    "https://cluster.example.com#fragment",
    "https://cluster.example.com/api/v1",
    "https://cluster.example.com//",
    "https://cluster.example.com/.",
    "https://cluster.example.com/..",
    "https://cluster.example.com/%2e/",
    "https://cluster.example.com/%2e%2e/",
    "https://cluster.example.com/%2e%2e%2fadmin",
    "https://cluster.example.com/%3f/version",
    "https://cluster.example.com/%5c..",
    "https://cluster.example.com\\@evil.invalid",
    "https://cluster.example.com%2fversion",
    "https://cluster.example.com:",
    "https://cluster.example.com:/",
    "https://cluster.example.com:0443",
    "https://cluster.example.com:6443",
    " https://cluster.example.com",
    "https://cluster.example.com\n",
  ])(
    "rejects non-origin and normalization-escape forms, including the Kubernetes empty-query bypass: %s",
    (apiserverUrl) => {
      expectTenancyError(
        () => resolve("kubernetes", { apiserver_url: apiserverUrl }),
        "invalid_tenant_origin",
        apiserverUrl,
      );
    },
  );

  it("accepts an explicit canonical :443 port and one optional root slash", () => {
    expect(resolve("snowflake", {
      account_url: "https://acct.snowflakecomputing.com:443/",
    }).origin.origin).toBe("https://acct.snowflakecomputing.com");
  });

  it("accepts sandbox as a legitimate tenant on the official My Domain host", () => {
    const pinned = resolve("salesforce", { instance_url: "https://sandbox.my.salesforce.com" });
    expect(pinned.origin.origin).toBe("https://sandbox.my.salesforce.com");
    expect(pinned.originKey).toMatch(/^connector:[A-Za-z0-9_-]{43}$/);
  });

  it("rejects a non-official suffix on the sandbox My Domain host", () => {
    const instanceUrl = "https://sandbox.my.salesforce.com.attacker.invalid";
    expectTenancyError(
      () => resolve("salesforce", { instance_url: instanceUrl }),
      "tenant_host_denied",
      instanceUrl,
    );
  });

  it.each([
    ["jira", { host: "tenant.atlassian.net.attacker.invalid" }],
    ["jira", { host: "tenant.atlassian.net." }],
    ["jira", { host: "atlassian.net" }],
    ["jira", { host: "tenant..atlassian.net" }],
    ["supabase", { base_url: "https://project.supabase.co.attacker.invalid" }],
    ["salesforce", { instance_url: "https://my.salesforce.com.attacker.invalid" }],
    ["salesforce", { instance_url: "https://my.salesforce.com" }],
    ["salesforce", { instance_url: "https://acme--dev.sandbox.my.salesforce.com.attacker.invalid" }],
    ["salesforce", { instance_url: "https://acme--dev.evil.my.salesforce.com" }],
    ["salesforce", { instance_url: "https://acme_dev.my.salesforce.com" }],
    ["snowflake", { account_url: "https://acct.snowflakecomputing.com.attacker.invalid" }],
    ["snowflake", { account_url: "https://myorg-account_name.snowflakecomputing.com.attacker.invalid" }],
    ["snowflake", { account_url: "https://snowflakecomputing.com" }],
    ["snowflake", { account_url: "https://acct..snowflakecomputing.com" }],
    ["databricks", { workspace_url: "https://workspace.cloud.databricks.com.attacker.invalid" }],
    ["shopify", { shop: "victim.myshopify.com.attacker.invalid" }],
    ["algolia", { app_id: "app.algolia.net.attacker.invalid" }],
    ["intercom", { api_origin: "https://api.intercom.io.attacker.invalid" }],
    ["datadog", { site: "api.datadoghq.com.attacker.invalid" }],
  ] as const)("denies suffix confusion or a missing tenant boundary for %s", (providerId, connectionConfig) => {
    expect(() => resolve(providerId, connectionConfig)).toThrow(ConnectorTenancyError);
  });

  it.each([
    "https://_myorg-account.snowflakecomputing.com",
    "https://myorg-account_.snowflakecomputing.com",
    "https://myorg-account._us-east-1.snowflakecomputing.com",
    "https://myorg-account..snowflakecomputing.com",
    "https://myorg-account%5fname.snowflakecomputing.com",
    `https://${"a".repeat(64)}_name.snowflakecomputing.com`,
  ])("rejects malformed Snowflake locators and underscores outside the account label: %s", (accountUrl) => {
    expectTenancyError(
      () => resolve("snowflake", { account_url: accountUrl }),
      "invalid_tenant_origin",
      accountUrl,
    );
  });

  it("does not widen underscore support to any non-Snowflake hostname", () => {
    expectTenancyError(
      () => resolve("salesforce", { instance_url: "https://acme_dev.my.salesforce.com" }),
      "invalid_tenant_origin",
    );
    expectTenancyError(
      () => resolve("gitlab", { host: "git_example.com" }),
      "invalid_tenant_origin",
    );
  });

  it.each([
    "localhost",
    "metadata.localhost",
    "cluster.local",
    "home.arpa",
    "router.home.arpa",
    "HOME.ARPA",
    "127.0.0.1",
    "127.1",
    "2130706433",
    "0x7f000001",
    "10.0.0.5",
    "192.168.1.10",
    "https://[::1]",
    "https://[::ffff:127.0.0.1]",
  ])("never admits a local or IP-literal tenant even as a pasted host: %s", (host) => {
    expectTenancyError(() => resolve("gitlab", { host }), "invalid_tenant_origin", host);
  });

  it("does not let a bounded SaaS template escape to an arbitrary public hostname", () => {
    expectTenancyError(
      () => resolve("jira", { host: "git.example.com" }),
      "tenant_host_denied",
      "git.example.com",
    );
  });

  it("fails closed for a provider without any reviewed tenant profile", () => {
    expectTenancyError(
      () => resolve("not-a-provider", { instance_url: "https://tenant.example.com" }),
      "unsupported_provider",
    );
  });
});
