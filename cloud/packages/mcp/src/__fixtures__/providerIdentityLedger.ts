/**
 * Independently reviewed provider identity ledger (2026-10-25).
 *
 * Historical IDs are never removed or renamed implicitly. An approved new ID
 * belongs in APPROVED_PROVIDER_IDENTITY_ADDITIONS with a review reference and
 * its formal/reserved disposition; tests intentionally fail until that explicit
 * ledger update occurs. Disposition migrations preserve identity and counts.
 */
export interface ApprovedProviderIdentityAddition {
  providerId: string;
  /** True for a formal readiness row; false for a reserved-only historical ID. */
  formal: boolean;
  review: string;
}

export const APPROVED_PROVIDER_IDENTITY_ADDITIONS: readonly ApprovedProviderIdentityAddition[] = [];

export const PROVIDER_RESERVED_ONLY_IDS = [
  "shortcut-v2-query-token",
  "freshdesk-v1",
  "whatsapp-business-on-premises",
  "klaviyo-v1-v2",
] as const;

export const PROVIDER_FORMAL_IDENTITY_IDS = [
  // Original (20): 19 blocked + mongodb deprecated.
  "github",
  "filesystem",
  "fetch",
  "memory",
  "gitlab",
  "jira",
  "linear",
  "figma",
  "sentry",
  "exa",
  "notion",
  "google-drive",
  "airtable",
  "supabase",
  "firebase",
  "mongodb",
  "s3",
  "slack",
  "discord",
  "telegram",
  // Development/work (17): candidates.
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
  // Files/suites (10): blocked.
  "dropbox",
  "box",
  "onedrive",
  "sharepoint",
  "google-docs",
  "google-sheets",
  "google-calendar",
  "google-tasks",
  "gmail",
  "outlook",
  // Data/search (26 formal): 25 typed candidates + 1 blocked metadata-only Redash.
  "docusign",
  "typeform",
  "calendly",
  "miro",
  "canva",
  "webflow",
  "snowflake",
  "bigquery",
  "databricks",
  "pinecone",
  "elasticsearch",
  "typesense",
  "brave-search",
  "tavily",
  "serpapi",
  "algolia",
  "google-maps",
  "mixpanel",
  "amplitude",
  "posthog",
  "segment",
  "metabase",
  "redash",
  "superset",
  "stripe",
  "paypal",
  // Commerce/infrastructure (26): candidates, including Kubernetes.
  "razorpay",
  "square",
  "shopify",
  "woocommerce",
  "hubspot",
  "salesforce",
  "pipedrive",
  "datadog",
  "grafana",
  "pagerduty",
  "jira-service-management",
  "newrelic",
  "rollbar",
  "docker-hub",
  "kubernetes",
  "terraform-cloud",
  "youtube",
  "vimeo",
  "spotify",
  "imgur",
  "cloudinary",
  "mux",
  "cloudflare-images",
  "make",
  "n8n",
  "stackexchange",
  // Commerce descriptor-absent metadata (2).
  "opsgenie",
  "zapier",
] as const;

export const PROVIDER_DISPOSITION_MIGRATIONS = Object.freeze([
  Object.freeze({
    ids: Object.freeze([
      "docusign",
      "snowflake",
      "databricks",
      "elasticsearch",
      "typesense",
      "serpapi",
      "algolia",
      "metabase",
      "superset",
      "paypal",
    ]),
    from: "dataSearch metadata-only blocked inventory",
    to: "dataSearch typed candidate readiness rows",
    expectedReleaseState: "candidate",
  }),
  Object.freeze({
    ids: Object.freeze(["redash"]),
    from: "dataSearch metadata-only blocked inventory",
    to: "dataSearch descriptor-absent blocked readiness row; identity retained without typed operations",
    expectedReleaseState: "blocked",
  }),
  Object.freeze({
    ids: Object.freeze(["kubernetes"]),
    from: "commerceInfra metadata-only blocked inventory",
    to: "commerceInfra 26th typed candidate readiness row",
    expectedReleaseState: "candidate",
  }),
]);

export function expectedFormalProviderIdentityIds(): readonly string[] {
  return [
    ...PROVIDER_FORMAL_IDENTITY_IDS,
    ...APPROVED_PROVIDER_IDENTITY_ADDITIONS
      .filter((addition) => addition.formal)
      .map((addition) => addition.providerId),
  ];
}

export function expectedReservedProviderIdentityIds(): readonly string[] {
  return [
    ...expectedFormalProviderIdentityIds(),
    ...PROVIDER_RESERVED_ONLY_IDS,
    ...APPROVED_PROVIDER_IDENTITY_ADDITIONS
      .filter((addition) => !addition.formal)
      .map((addition) => addition.providerId),
  ];
}
