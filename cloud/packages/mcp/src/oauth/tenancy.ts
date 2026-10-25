import { createHash } from "node:crypto";
import { isIP } from "node:net";

/**
 * Pure dynamic-tenant origin resolution for authenticated connector config.
 *
 * The input is deliberately connection config, never model operation args.
 * Only the reviewed public-SaaS templates and explicitly review-tagged
 * public-DNS private-tenant profiles below are admitted. A private tenant is
 * not a private-network grant: local names and IP literals remain denied.
 * ProviderEgress remains mandatory for DNS pinning and non-public-address
 * rejection; this module performs no DNS or network I/O.
 */

export type ConnectorTenancyErrorCode =
  | "unsupported_provider"
  | "invalid_connection"
  | "invalid_tenant_config"
  | "invalid_tenant_origin"
  | "tenant_host_denied";

export class ConnectorTenancyError extends Error {
  constructor(readonly code: ConnectorTenancyErrorCode) {
    super(`Connector tenant resolution failed (${code}).`);
    this.name = "ConnectorTenancyError";
  }
}

export interface ConnectorTenantResolutionInput {
  readonly providerId: string;
  /** Server-owned connection identity; never a model-selected namespace. */
  readonly connectionId: string;
  /** Normalized authenticated connection config, not merged model args. */
  readonly connectionConfig: Readonly<Record<string, unknown>>;
}

export interface PinnedConnectorTenantOrigin {
  /** A fresh canonical HTTPS URL snapshot on every read. Mutating a snapshot
   *  cannot change the validated origin or its connection-scoped key. */
  readonly origin: URL;
  /** Stable for one provider/connection/canonical-origin tuple. */
  readonly originKey: string;
}

type HostRule =
  | { readonly kind: "exact"; readonly host: string }
  | { readonly kind: "suffix"; readonly suffix: string }
  | { readonly kind: "template"; readonly template: string }
  | { readonly kind: "snowflake_account"; readonly suffix: string }
  | { readonly kind: "public_dns"; readonly review: string };

interface OriginProfile {
  readonly kind: "origin";
  readonly key: string;
  readonly allowBareHost?: boolean;
  readonly fallback?: string;
  readonly hostRules: readonly HostRule[];
}

interface TemplateProfile {
  readonly kind: "template";
  readonly keys: readonly string[];
  readonly template: string;
  readonly hostRules: readonly HostRule[];
}

type TenantProfile = OriginProfile | TemplateProfile;

function exact(...hosts: string[]): readonly HostRule[] {
  return hosts.map((host) => ({ kind: "exact", host }));
}

function reviewedPublicDns(review: string): HostRule {
  return { kind: "public_dns", review };
}

function suffix(suffixValue: string): HostRule {
  return { kind: "suffix", suffix: suffixValue };
}

function snowflakeAccount(suffixValue: string): HostRule {
  return { kind: "snowflake_account", suffix: suffixValue };
}

function template(templateValue: string): HostRule {
  return { kind: "template", template: templateValue };
}

/**
 * This is an allowlist, not a generic `{host}` facility. Whole-origin fields
 * need an exact/template/suffix rule unless their existing descriptor review
 * explicitly covers public-DNS self-hosted tenants. Those review references
 * never authorize local names, IP literals, non-default ports, or private DNS
 * answers. DocuSign's discovered base_uri also needs its account-binding
 * proof and is not inferable from connection config here.
 */
const TENANT_PROFILES: Readonly<Record<string, TenantProfile>> = {
  gitlab: {
    kind: "origin",
    key: "host",
    allowBareHost: true,
    fallback: "gitlab.com",
    hostRules: [reviewedPublicDns(
      "dev.ts GITLAB_DESCRIPTOR: reviewed gitlab.com or public-DNS self-managed host",
    )],
  },
  jira: {
    kind: "origin",
    key: "host",
    allowBareHost: true,
    hostRules: [template("{tenant}.atlassian.net")],
  },
  supabase: {
    kind: "origin",
    key: "base_url",
    hostRules: [template("{project_ref}.supabase.co")],
  },
  s3: {
    kind: "template",
    keys: ["bucket", "region"],
    template: "https://{bucket}.s3.{region}.amazonaws.com",
    hostRules: [template("{bucket}.s3.{region}.amazonaws.com")],
  },
  intercom: {
    kind: "origin",
    key: "api_origin",
    hostRules: exact("api.intercom.io", "api.eu.intercom.io", "api.au.intercom.io"),
  },
  zendesk: {
    kind: "template",
    keys: ["subdomain"],
    template: "https://{subdomain}.zendesk.com",
    hostRules: [template("{subdomain}.zendesk.com")],
  },
  freshdesk: {
    kind: "template",
    keys: ["subdomain"],
    template: "https://{subdomain}.freshdesk.com",
    hostRules: [template("{subdomain}.freshdesk.com")],
  },
  shopify: {
    kind: "template",
    keys: ["shop"],
    template: "https://{shop}.myshopify.com",
    hostRules: [template("{shop}.myshopify.com")],
  },
  pipedrive: {
    kind: "template",
    keys: ["company"],
    template: "https://{company}.pipedrive.com",
    hostRules: [template("{company}.pipedrive.com")],
  },
  datadog: {
    kind: "origin",
    key: "site",
    allowBareHost: true,
    hostRules: exact(
      "api.datadoghq.com",
      "api.us3.datadoghq.com",
      "api.us5.datadoghq.com",
      "api.datadoghq.eu",
      "api.ap1.datadoghq.com",
      "api.ap2.datadoghq.com",
      "api.uk1.datadoghq.com",
      "api.ddog-gov.com",
      "api.us2.ddog-gov.com",
    ),
  },
  newrelic: {
    kind: "origin",
    key: "region_host",
    allowBareHost: true,
    hostRules: exact("api.newrelic.com", "api.eu.newrelic.com", "api.jp.newrelic.com"),
  },
  make: {
    kind: "origin",
    key: "zone",
    allowBareHost: true,
    hostRules: exact("eu1.make.com", "eu2.make.com", "us1.make.com", "us2.make.com"),
  },
  woocommerce: {
    kind: "origin",
    key: "store_url",
    hostRules: [reviewedPublicDns(
      "commerceInfra.ts WOOCOMMERCE: reviewed origin-only public-TLS store URL",
    )],
  },
  grafana: {
    kind: "origin",
    key: "instance_url",
    hostRules: [reviewedPublicDns(
      "commerceInfra.ts GRAFANA: reviewed public-DNS/public-CA instance URL",
    )],
  },
  kubernetes: {
    kind: "origin",
    key: "apiserver_url",
    hostRules: [reviewedPublicDns(
      "commerceInfra.ts KUBERNETES: reviewed origin-only public-DNS/public-CA API server",
    )],
  },
  n8n: {
    kind: "origin",
    key: "instance_url",
    hostRules: [reviewedPublicDns(
      "commerceInfra.ts N8N: reviewed origin-only public-DNS/public-TLS instance URL",
    )],
  },
  salesforce: {
    kind: "origin",
    key: "instance_url",
    hostRules: [
      template("{tenant}.my.salesforce.com"),
      template("{tenant}.sandbox.my.salesforce.com"),
    ],
  },
  snowflake: {
    kind: "origin",
    key: "account_url",
    hostRules: [snowflakeAccount(".snowflakecomputing.com")],
  },
  databricks: {
    kind: "origin",
    key: "workspace_url",
    hostRules: [suffix(".cloud.databricks.com"), suffix(".azuredatabricks.net"), suffix(".gcp.databricks.com")],
  },
  elasticsearch: {
    kind: "origin",
    key: "instance_url",
    hostRules: [reviewedPublicDns(
      "dataSearch.ts elasticsearch: reviewed authenticated public-DNS instance origin",
    )],
  },
  typesense: {
    kind: "origin",
    key: "instance_url",
    hostRules: [reviewedPublicDns(
      "dataSearch.ts typesense: reviewed authenticated public-DNS instance origin",
    )],
  },
  metabase: {
    kind: "origin",
    key: "instance_url",
    hostRules: [reviewedPublicDns(
      "dataSearch.ts metabase: reviewed authenticated public-DNS instance origin",
    )],
  },
  redash: {
    kind: "origin",
    key: "instance_url",
    hostRules: [reviewedPublicDns(
      "dataSearch.ts redash: reviewed authenticated public-DNS instance origin",
    )],
  },
  superset: {
    kind: "origin",
    key: "instance_url",
    hostRules: [reviewedPublicDns(
      "dataSearch.ts superset: reviewed authenticated public-DNS instance origin",
    )],
  },
  algolia: {
    kind: "template",
    keys: ["app_id"],
    template: "https://{app_id}-dsn.algolia.net",
    hostRules: [template("{app_id}-dsn.algolia.net")],
  },
};

const DNS_LABEL = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?";
const DNS_LABEL_PATTERN = new RegExp(`^${DNS_LABEL}$`, "i");
const SNOWFLAKE_ACCOUNT_LABEL_PATTERN = /^[a-z0-9](?:[a-z0-9_-]{0,61}[a-z0-9])?$/i;
const CONNECTION_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const RAW_ORIGIN_PATTERN = /^https:\/\/[^\/?#\\]+\/?$/i;
const DNS_AUTHORITY_PATTERN = /^[A-Za-z0-9.-]+(?::443)?$/;
const SNOWFLAKE_AUTHORITY_PATTERN = /^[A-Za-z0-9._-]+(?::443)?$/;
const SCHEME_PATTERN = /^[a-z][a-z0-9+.-]*:\/\//i;
const LOCAL_HOSTNAMES = new Set(["localhost", "home.arpa"]);
const LOCAL_SUFFIXES = [".localhost", ".local", ".internal", ".lan", ".home.arpa"];

function fail(code: ConnectorTenancyErrorCode): never {
  throw new ConnectorTenancyError(code);
}

function configString(
  config: Readonly<Record<string, unknown>>,
  key: string,
  fallback?: string,
): string {
  let value = Object.hasOwn(config, key) ? config[key] : undefined;
  if ((value === undefined || value === "") && fallback !== undefined) value = fallback;
  if (typeof value !== "string" || value === "" || value.length > 2_048) {
    return fail("invalid_tenant_config");
  }
  return value;
}

function configLabel(config: Readonly<Record<string, unknown>>, key: string): string {
  const value = configString(config, key);
  if (!DNS_LABEL_PATTERN.test(value)) return fail("invalid_tenant_config");
  return value;
}

function validPublicDnsName(hostname: string, snowflakeAccount: boolean): boolean {
  if (
    hostname.length > 253 ||
    isIP(hostname) !== 0 ||
    LOCAL_HOSTNAMES.has(hostname) ||
    LOCAL_SUFFIXES.some((suffixValue) => hostname.endsWith(suffixValue))
  ) {
    return false;
  }
  const labels = hostname.split(".");
  // Single-label names can be resolved through a local search domain and are
  // not valid targets for any reviewed public template in this module. The
  // sole underscore exception is Snowflake's leftmost organization-account
  // locator; region/cloud labels remain ordinary DNS labels.
  return labels.length >= 2 && labels.every((label, index) =>
    (snowflakeAccount && index === 0 ? SNOWFLAKE_ACCOUNT_LABEL_PATTERN : DNS_LABEL_PATTERN).test(label)
  );
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function hostMatchesTemplate(hostname: string, templateValue: string): boolean {
  const placeholder = /\{[a-z][a-z0-9_-]*\}/gi;
  let source = "";
  let offset = 0;
  for (const match of templateValue.matchAll(placeholder)) {
    const index = match.index!;
    source += escapeRegex(templateValue.slice(offset, index)) + DNS_LABEL;
    offset = index + match[0].length;
  }
  source += escapeRegex(templateValue.slice(offset));
  return new RegExp(`^${source}$`, "i").test(hostname);
}

function hostMatchesRule(hostname: string, rule: HostRule): boolean {
  if (rule.kind === "exact") return hostname === rule.host;
  if (rule.kind === "public_dns") {
    // validPublicDnsName has already run. An empty review reference must never
    // become an arbitrary-origin grant; ProviderEgress still validates DNS.
    return rule.review.trim() !== "";
  }
  if (rule.kind === "suffix" || rule.kind === "snowflake_account") {
    // The leading dot and non-empty prefix are the suffix-confusion boundary.
    // Snowflake's account-locator grammar is enforced by validPublicDnsName.
    return hostname.length > rule.suffix.length && hostname.endsWith(rule.suffix);
  }
  return hostMatchesTemplate(hostname, rule.template);
}

function parseOrigin(raw: string, hostRules: readonly HostRule[]): string {
  // Check raw delimiters before WHATWG parsing: URL erases an empty trailing
  // `?`/`#` and normalizes encoded dot segments, which caused the Kubernetes-
  // style origin/composition bypass this validator must not reintroduce.
  if (
    raw.length > 2_048 ||
    raw !== raw.trim() ||
    /[\x00-\x20\x7f]/.test(raw) ||
    /[?#\\]/.test(raw) ||
    !RAW_ORIGIN_PATTERN.test(raw)
  ) {
    return fail("invalid_tenant_origin");
  }

  const authorityAndPath = raw.slice("https://".length);
  const slash = authorityAndPath.indexOf("/");
  const authority = slash < 0 ? authorityAndPath : authorityAndPath.slice(0, slash);
  // DNS-only public profiles intentionally exclude userinfo, percent-encoded
  // authority delimiters, IPv6, non-canonical ports, and every non-443 port.
  // A literal underscore may reach URL parsing only for the sole reviewed
  // Snowflake profile, whose locator grammar is checked again below.
  const snowflakeAccount = hostRules.length === 1 && hostRules[0]?.kind === "snowflake_account";
  const authorityPattern = snowflakeAccount ? SNOWFLAKE_AUTHORITY_PATTERN : DNS_AUTHORITY_PATTERN;
  if (!authorityPattern.test(authority)) return fail("invalid_tenant_origin");

  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return fail("invalid_tenant_origin");
  }
  const hostname = url.hostname.toLowerCase();
  if (
    url.protocol !== "https:" ||
    url.username !== "" ||
    url.password !== "" ||
    url.pathname !== "/" ||
    url.search !== "" ||
    url.hash !== "" ||
    url.port !== "" ||
    !validPublicDnsName(hostname, snowflakeAccount)
  ) {
    return fail("invalid_tenant_origin");
  }
  if (!hostRules.some((rule) => hostMatchesRule(hostname, rule))) {
    return fail("tenant_host_denied");
  }
  return url.origin;
}

function rawOriginFor(profile: TenantProfile, config: Readonly<Record<string, unknown>>): string {
  if (profile.kind === "template") {
    let raw = profile.template;
    for (const key of profile.keys) {
      raw = raw.replace(`{${key}}`, configLabel(config, key));
    }
    return raw;
  }
  const configured = configString(config, profile.key, profile.fallback);
  return profile.allowBareHost === true && !SCHEME_PATTERN.test(configured)
    ? `https://${configured}`
    : configured;
}

/**
 * Resolve exactly one tenant origin and the connection-scoped ProviderEgress
 * key under which it may be pinned. No model argument or caller-supplied host
 * pattern is accepted, and there is no unreviewed arbitrary-origin escape.
 */
export function resolveConnectorTenantOrigin(
  input: ConnectorTenantResolutionInput,
): PinnedConnectorTenantOrigin {
  const profile = typeof input.providerId === "string" && Object.hasOwn(TENANT_PROFILES, input.providerId)
    ? TENANT_PROFILES[input.providerId]!
    : fail("unsupported_provider");
  if (typeof input.connectionId !== "string" || !CONNECTION_ID_PATTERN.test(input.connectionId)) {
    return fail("invalid_connection");
  }
  const config = input.connectionConfig;
  if (typeof config !== "object" || config === null || Array.isArray(config)) {
    return fail("invalid_tenant_config");
  }

  const canonicalOrigin = parseOrigin(rawOriginFor(profile, config), profile.hostRules);
  const digest = createHash("sha256")
    .update(JSON.stringify([input.providerId, input.connectionId, canonicalOrigin]), "utf8")
    .digest("base64url");
  return Object.freeze({
    // The immutable string above is the trust anchor. Callers receive a new
    // snapshot on every read, so mutating one URL cannot poison the pin/key.
    get origin(): URL {
      return new URL(canonicalOrigin);
    },
    // Binding the origin as well as the connection prevents a reconfigured
    // tenant from inheriting a stale allowlist entry under the same key.
    originKey: `connector:${digest}`,
  });
}
