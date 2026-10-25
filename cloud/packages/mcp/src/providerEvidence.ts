/** Internal original-provider readiness seed. Descriptors/tests are not live evidence. */

import { createProviderRegistry, type AuthProfile, type ProviderReadinessRow } from "./providers/registry.js";
import type { Effect, ProviderDefinition, ProviderOperation } from "./providers/types.js";
import { restToolDefs, type RestServiceDescriptor } from "./rest/engine.js";
import { CURATED_DESCRIPTORS } from "./rest/descriptors/index.js";
import { GITHUB_READ_OPERATIONS } from "./native/github.js";
import { FETCH_OPERATIONS } from "./native/fetch.js";
import { MEMORY_OPERATIONS } from "./native/memory.js";

const VERIFIED_AT = "2026-10-24";
const REVIEWER = "batch-a-official-review";
const CONTRACT_TEST = "test/providers/originals.contract.test.ts";
const LIVE_COMMAND = "OVID_LIVE_PROVIDER_TESTS=1 ./node_modules/.bin/vitest run test/liveProvider.test.ts";

const OFFICIAL: Readonly<Record<string, readonly { url: string; apiVersion: string }[]>> = {
  github: [
    { url: "https://docs.github.com/en/rest/about-the-rest-api/api-versions", apiVersion: "2026-03-10" },
    { url: "https://docs.github.com/en/rest/authentication/authenticating-to-the-rest-api", apiVersion: "2026-03-10" },
  ],
  filesystem: [{ url: "https://modelcontextprotocol.io/specification/2024-11-05", apiVersion: "Ovid native filesystem/1.0.0; MCP 2024-11-05" }],
  fetch: [{ url: "https://modelcontextprotocol.io/specification/2024-11-05", apiVersion: "Ovid native fetch/1.0.0; MCP 2024-11-05" }],
  memory: [{ url: "https://modelcontextprotocol.io/specification/2024-11-05", apiVersion: "Ovid native memory/1.0.0; MCP 2024-11-05" }],
  gitlab: [{ url: "https://docs.gitlab.com/api/rest/", apiVersion: "v4" }],
  jira: [
    { url: "https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/", apiVersion: "v3 enhanced JQL" },
    { url: "https://developer.atlassian.com/cloud/jira/platform/basic-auth-for-rest-apis/", apiVersion: "v3 enhanced JQL" },
  ],
  linear: [{ url: "https://linear.app/developers/graphql", apiVersion: "GraphQL current; OAuth refresh system 2026-04-01" }],
  figma: [{ url: "https://developers.figma.com/docs/rest-api/authentication", apiVersion: "REST v1" }],
  sentry: [{ url: "https://docs.sentry.io/api/auth/", apiVersion: "v0" }],
  exa: [{ url: "https://docs.exa.ai/reference/search", apiVersion: "current OpenAPI /search and /contents" }],
  notion: [
    { url: "https://developers.notion.com/reference/versioning", apiVersion: "2026-03-11" },
    { url: "https://developers.notion.com/reference/query-a-data-source", apiVersion: "2026-03-11" },
  ],
  "google-drive": [{ url: "https://developers.google.com/workspace/drive/api/guides/manage-downloads", apiVersion: "Drive v3" }],
  airtable: [{ url: "https://www.airtable.com/developers/web/api/list-records", apiVersion: "Web API v0" }],
  supabase: [
    { url: "https://supabase.com/docs/guides/api/api-keys", apiVersion: "PostgREST Data API current; publishable keys" },
    { url: "https://supabase.com/docs/guides/api/securing-your-api", apiVersion: "PostgREST Data API current; RLS" },
  ],
  firebase: [{ url: "https://firebase.google.com/docs/firestore/use-rest-api", apiVersion: "Firestore REST v1" }],
  mongodb: [
    { url: "https://www.mongodb.com/docs/atlas/app-services/data-api/", apiVersion: "Atlas Data API removed 2025-09-30" },
    { url: "https://www.mongodb.com/docs/atlas/app-services/data-api/data-api-deprecation/", apiVersion: "Atlas Data API removed 2025-09-30" },
  ],
  s3: [{ url: "https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-auth-using-authorization-header.html", apiVersion: "S3 REST SigV4/SigV4A" }],
  slack: [{ url: "https://docs.slack.dev/apis/web-api/", apiVersion: "Web API conversations; ok envelope" }],
  discord: [{ url: "https://docs.discord.com/developers/reference", apiVersion: "v10" }],
  telegram: [{ url: "https://core.telegram.org/bots/api", apiVersion: "Bot API current" }],
};

function authFor(id: string): AuthProfile {
  const tokenTypes: Readonly<Record<string, string>> = {
    github: "Fine-grained PAT or GitHub App user access token",
    filesystem: "No external credential; uid-jailed workspace identity",
    fetch: "No provider credential; unauthenticated public-web fetch only",
    memory: "No external credential; uid-jailed workspace identity",
    gitlab: "Personal or OAuth token; PAT uses PRIVATE-TOKEN",
    jira: "User-owned email+API token Basic profile; OAuth 3LO is a separate production onboarding profile",
    linear: "Personal API key without a prefix or OAuth access token with Bearer; exactly one per connection",
    figma: "Personal token in X-Figma-Token; OAuth Bearer requires a separate profile",
    sentry: "Personal/internal-integration/OAuth Bearer token",
    exa: "Per-integration key in x-api-key",
    notion: "Integration/OAuth Bearer token with Read content capability",
    "google-drive": "End-user Google OAuth access token",
    airtable: "Base-restricted PAT or OAuth Bearer token",
    supabase: "Publishable apikey plus a distinct Supabase Auth user JWT; secret/service-role credentials denied",
    firebase: "Firebase Authentication ID token or Google OAuth access token; web API keys denied",
    mongodb: "Retired Atlas Data API credential; no supported replacement connection",
    s3: "Short-lived STS access key, secret key, and session token with SigV4",
    slack: "Slack OAuth user token (xoxp), not a bot identity",
    discord: "Discord OAuth user access token; bot identity is not interchangeable",
    telegram: "Installation-scoped bot token in the URL path, not end-user OAuth",
  };
  const prefixes: Readonly<Record<string, string>> = {
    gitlab: "PRIVATE-TOKEN: ",
    jira: "Basic base64(email:token)",
    linear: "Personal key: empty prefix; OAuth: Bearer ",
    figma: "X-Figma-Token: ",
    exa: "x-api-key: ",
    supabase: "Bearer ",
    mongodb: "",
    telegram: "bot<token> URL path",
  };
  const nativeOrigin = id === "fetch" ? "public-web://https-only" : id === "filesystem" || id === "memory"
    ? "native://workspace"
    : undefined;
  const origins: Readonly<Record<string, string>> = {
    github: "https://api.github.com",
    gitlab: "https://{gitlab-self-managed-host}",
    jira: "https://{tenant}.atlassian.net",
    linear: "https://api.linear.app",
    figma: "https://api.figma.com",
    sentry: "https://sentry.io",
    exa: "https://api.exa.ai",
    notion: "https://api.notion.com",
    "google-drive": "https://www.googleapis.com",
    airtable: "https://api.airtable.com",
    supabase: "https://{project-ref}.supabase.co",
    firebase: "https://firestore.googleapis.com",
    mongodb: "https://www.mongodb.com",
    s3: "https://{bucket}.s3.{region}.amazonaws.com",
    slack: "https://slack.com",
    discord: "https://discord.com",
    telegram: "https://api.telegram.org",
  };
  const minimumScopes: Readonly<Record<string, readonly string[]>> = {
    github: ["Contents: Read", "Issues: Read"],
    gitlab: ["read_api", "read_repository"],
    linear: ["read"],
    figma: ["file_content:read", "file_comments:read"],
    sentry: ["org:read", "project:read", "event:read"],
    notion: ["Read content"],
    "google-drive": ["https://www.googleapis.com/auth/drive.readonly"],
    airtable: ["data.records:read"],
    supabase: ["authenticated SELECT grants with per-user RLS"],
    firebase: ["https://www.googleapis.com/auth/datastore", "roles/datastore.viewer or user Security Rules"],
    s3: ["s3:ListBucket", "s3:GetObject"],
    slack: ["channels:read", "channels:history"],
    discord: ["identify", "guilds"],
  };
  if (id === "fetch") {
    return {
      profileId: "fetch-original-auth",
      tokenType: "No provider credential; unauthenticated public-web fetch only",
      authorizationPrefix: "",
      minimumScopes: [],
      tenantOrigins: ["public-web://https-only"],
      refreshBehavior: "Not applicable: fetch has no OAuth flow or token refresh.",
      revokeBehavior: "No provider grant or remote credential exists to revoke.",
      disconnectBehavior: "Disable the local connection and fence subsequent execution through disconnectGeneration.",
    };
  }
  return {
    profileId: `${id}-original-auth`,
    tokenType: tokenTypes[id] ?? "No external credential",
    authorizationPrefix: prefixes[id] ?? (nativeOrigin === undefined ? "Bearer " : ""),
    minimumScopes: minimumScopes[id] ?? [],
    tenantOrigins: [nativeOrigin ?? origins[id] ?? "native://workspace"],
    refreshBehavior: id === "mongodb"
      ? "Unavailable because the original service is retired."
      : "Use only the connection-bound provider grant; refresh implementation and proof remain a live-support gate.",
    revokeBehavior: id === "mongodb"
      ? "No new grant can be created for the retired service."
      : "Revoke at the provider where supported and prove revocation before live support.",
    disconnectBehavior: "Delete or seal connection configuration and fence subsequent execution through disconnect generation.",
  };
}

function emptyConnectionSchema(): Record<string, unknown> {
  return {
    type: "object",
    properties: {},
    required: [],
    additionalProperties: false,
    maxProperties: 0,
  };
}

function descriptorConnectionSchema(descriptor: RestServiceDescriptor): Record<string, unknown> {
  if (descriptor.connectionSchema !== undefined) return descriptor.connectionSchema;
  const fields = [
    ...(descriptor.credentialKey === "" ? [] : [{ key: descriptor.credentialKey, secret: true }]),
    ...(descriptor.extraConfig ?? []),
  ];
  const properties = Object.fromEntries(fields.map((field) => [field.key, {
    type: "string",
    maxLength: field.secret ? 16_384 : /url|host|base/i.test(field.key) ? 2_048 : 1_024,
  }]));
  return {
    type: "object",
    properties,
    required: [],
    additionalProperties: false,
    maxProperties: fields.length,
  };
}

function descriptorDefinition(id: string, displayName: string, description: string): ProviderDefinition {
  const descriptor = CURATED_DESCRIPTORS.find((candidate) => candidate.curatedId === id);
  if (descriptor === undefined) throw new Error(`Original descriptor missing: ${id}`);
  const operations: ProviderOperation[] = restToolDefs(descriptor).map((operation) => ({
    name: operation.name,
    description: operation.description ?? `Read ${operation.name} through the official provider operation.`,
    effect: operation.effect,
    approval: operation.approval,
    requiredScopes: operation.requiredScopes,
    inputSchema: operation.inputSchema ?? {
      type: "object",
      properties: {},
      required: [],
      additionalProperties: false,
      maxProperties: 0,
    },
    outputPolicy: operation.outputPolicy,
    request: operation.request,
    limits: operation.limits,
  }));
  return {
    providerId: id,
    catalogVersion: "2026-10-24-original-read-first",
    displayName,
    description,
    officialDocs: (OFFICIAL[id] ?? []).map((doc) => ({ url: doc.url, verifiedAt: VERIFIED_AT })),
    authProfileId: `${id}-original-auth`,
    connectionSchema: descriptorConnectionSchema(descriptor),
    operations,
    readiness: "supported",
  };
}

function nativeDefinition(
  id: string,
  displayName: string,
  description: string,
  operations: readonly ProviderOperation[],
  connectionSchema: Record<string, unknown> = emptyConnectionSchema(),
): ProviderDefinition {
  return {
    providerId: id,
    catalogVersion: "2026-10-24-original-read-first",
    displayName,
    description,
    officialDocs: (OFFICIAL[id] ?? []).map((doc) => ({ url: doc.url, verifiedAt: VERIFIED_AT })),
    authProfileId: `${id}-original-auth`,
    connectionSchema,
    operations: [...operations],
    readiness: "supported",
  };
}

function filesystemOperations(): ProviderOperation[] {
  const path = (description: string): Record<string, unknown> => ({
    type: "string",
    description,
    minLength: 1,
    maxLength: 4_096,
  });
  const declarations: readonly {
    name: string;
    description: string;
    effect: Effect;
    properties: Record<string, Record<string, unknown>>;
    required?: readonly string[];
  }[] = [
    {
      name: "read_file",
      description: "Read the contents of a file.",
      effect: "read",
      properties: { path: path("Path to the file.") },
      required: ["path"],
    },
    {
      name: "write_file",
      description: "Create or overwrite a file with given contents.",
      effect: "write",
      properties: {
        path: path("Path to the file."),
        content: { type: "string", description: "Content to write.", maxLength: 1_000_000 },
      },
      required: ["path", "content"],
    },
    {
      name: "create_or_update_file",
      description: "Create or update a file with given contents.",
      effect: "write",
      properties: {
        path: path("Path to the file."),
        content: { type: "string", description: "Content to write.", maxLength: 1_000_000 },
      },
      required: ["path", "content"],
    },
    {
      name: "delete_file",
      description: "Delete a file or directory.",
      effect: "destructive",
      properties: { path: path("Path to delete.") },
      required: ["path"],
    },
    {
      name: "list_directory",
      description: "List contents of a directory.",
      effect: "read",
      properties: { path: path("Path to directory (default: root).") },
    },
    {
      name: "get_file_info",
      description: "Get file or directory metadata (size, modified time, etc.).",
      effect: "read",
      properties: { path: path("Path to file or directory.") },
      required: ["path"],
    },
    {
      name: "search_files",
      description: "Recursively search for files matching a pattern.",
      effect: "read",
      properties: {
        path: path("Starting path (default: root)."),
        pattern: {
          type: "string",
          description: "Filename search pattern or substring.",
          minLength: 1,
          maxLength: 4_096,
        },
      },
      required: ["pattern"],
    },
  ];

  // These declarations mirror native/filesystem.ts TOOLS. Closed-provider
  // validation deliberately adds only additionalProperties:false, the matching
  // maxProperties, and bounded strings. That safe admission narrowing leaves
  // empty file content valid and keeps directory/search path omission rooted;
  // catalog.test.ts removes exactly these additions for handler parity.
  return declarations.map(({ name, description, effect, properties, required }) => ({
    name,
    description,
    effect,
    approval: effect === "destructive" ? "per_action" : "mode",
    requiredScopes: [],
    inputSchema: {
      type: "object",
      properties,
      ...(required === undefined ? {} : { required }),
      additionalProperties: false,
      maxProperties: Object.keys(properties).length,
    },
    outputPolicy: { kind: "redacted_text", maxBytes: 65_536 },
    request: { originKey: "filesystem", method: effect === "read" ? "GET" : "POST", pathTemplate: `/${name}` },
    limits: { timeoutMs: 30_000, responseBytes: 65_536, frameBytes: 65_536, pageBytes: 65_536 },
  }));
}

export const ORIGINAL_PROVIDER_DEFINITIONS: readonly ProviderDefinition[] = [
  nativeDefinition(
    "github",
    "GitHub",
    "Read GitHub repositories, issues, pull requests, commits, and identity through REST.",
    GITHUB_READ_OPERATIONS,
    {
      type: "object",
      properties: { GITHUB_TOKEN: { type: "string", minLength: 1, maxLength: 16_384 } },
      required: ["GITHUB_TOKEN"],
      additionalProperties: false,
      maxProperties: 1,
    },
  ),
  nativeDefinition("filesystem", "Filesystem", "Access only the uid-jailed Ovid workspace.", filesystemOperations()),
  nativeDefinition(
    "fetch",
    "Fetch",
    "Fetch unauthenticated public-web resources through the SSRF guard; never a provider substitute.",
    FETCH_OPERATIONS,
    {
      type: "object",
      properties: {
        url: {
          type: "string",
          minLength: 1,
          maxLength: 2_048,
          title: "Health check URL",
          description: "Non-secret credential-free HTTPS URL on port 443 used only for an explicit fetch health check.",
        },
      },
      required: ["url"],
      additionalProperties: false,
      minProperties: 1,
      maxProperties: 1,
    },
  ),
  nativeDefinition("memory", "Memory", "Per-uid knowledge graph with serialized mutations and bounded corrupt-file handling.", MEMORY_OPERATIONS),
  descriptorDefinition("gitlab", "GitLab", "Read GitLab projects and merge requests."),
  descriptorDefinition("jira", "Jira", "Read Jira issues with enhanced JQL and bounded fields."),
  descriptorDefinition("linear", "Linear", "Read Linear viewer, issues, and teams with fixed GraphQL documents."),
  descriptorDefinition("figma", "Figma", "Read Figma files and comments."),
  descriptorDefinition("sentry", "Sentry", "Read Sentry issues and events."),
  descriptorDefinition("exa", "Exa", "Run bounded Exa search and content reads."),
  descriptorDefinition("notion", "Notion", "Search Notion and query pages/data sources with API version 2026-03-11."),
  descriptorDefinition("google-drive", "Google Drive", "Read Drive metadata, blob downloads, and native exports."),
  descriptorDefinition("airtable", "Airtable", "Read scoped Airtable records."),
  descriptorDefinition("supabase", "Supabase", "Read allowlisted tables with publishable+user-JWT auth and RLS."),
  descriptorDefinition("firebase", "Cloud Firestore", "Read Firestore documents with an authorized Bearer identity, never a web API key."),
  nativeDefinition("mongodb", "MongoDB Atlas Data API (retired)", "Deprecated on 2025-09-30; Atlas Administration API is not a document-CRUD replacement.", []),
  descriptorDefinition("s3", "S3", "Read S3 objects through short-lived SigV4 credentials without redirects."),
  descriptorDefinition("slack", "Slack", "Read Slack conversations with user-token auth and ok-envelope handling."),
  descriptorDefinition("discord", "Discord", "Read OAuth-user identity and guilds through v10."),
  descriptorDefinition("telegram", "Telegram", "Read bot-scoped metadata with envelope validation and path-token redaction."),
];

function effectsFor(operations: readonly ProviderOperation[]): ProviderReadinessRow["effects"] {
  return Object.fromEntries(operations.map((operation) => [operation.name, {
    effect: operation.effect,
    approval: operation.approval,
  }]));
}

export const ORIGINAL_READINESS_ROWS: readonly ProviderReadinessRow[] = ORIGINAL_PROVIDER_DEFINITIONS.map((definition) => ({
  providerId: definition.providerId,
  catalogOwner: "connectors-originals",
  officialDocs: (OFFICIAL[definition.providerId] ?? []).map((doc) => ({
    ...doc,
    verifiedAt: VERIFIED_AT,
    reviewer: definition.providerId === "filesystem" || definition.providerId === "fetch" || definition.providerId === "memory"
      ? "batch-a-source-review"
      : REVIEWER,
  })),
  operations: [...definition.operations],
  auth: authFor(definition.providerId),
  effects: effectsFor(definition.operations),
  isolationEvidence: [
    definition.providerId === "memory"
      ? "src/native/memory.test.ts#uid-isolation-and-mutation-serialization"
      : definition.providerId === "fetch"
        ? "src/native/fetch.test.ts#public-web-guard-and-redirects"
        : definition.providerId === "github"
          ? "src/native/github.test.ts#typed-bounded-egress"
          : `${CONTRACT_TEST}#${definition.providerId}`,
  ],
  fixtures: [`${CONTRACT_TEST}#${definition.providerId}-sanitized-fixture`],
  automatedEvidence: {
    test: CONTRACT_TEST,
    result: "passed",
    runAt: "2026-10-24T18:10:59.000Z",
  },
  liveReadEvidence: null,
  liveWriteEvidence: [],
  credentials: "not provided",
  releaseState: definition.providerId === "mongodb" ? "deprecated" : "blocked",
}));

const originalRegistry = createProviderRegistry();
for (const definition of ORIGINAL_PROVIDER_DEFINITIONS) {
  const row = ORIGINAL_READINESS_ROWS.find((candidate) => candidate.providerId === definition.providerId);
  if (row === undefined) throw new Error(`Original readiness row missing: ${definition.providerId}`);
  originalRegistry.registerProvider(definition, row);
}
export const ORIGINAL_PROVIDER_REGISTRY = originalRegistry;

export interface LiveProviderOptIn {
  providerId: string;
  write: boolean;
  optInEnv: string;
  disposableResourceEnv?: string;
}

/** Checks execution opt-ins only; credential and operation gates belong to the live harness. */
export function liveProviderOptIn(
  id: string,
  write = false,
  options: { env?: Record<string, string | undefined> } = {},
): LiveProviderOptIn {
  const env = options.env ?? process.env;
  const row = ORIGINAL_READINESS_ROWS.find((candidate) => candidate.providerId === id);
  if (row === undefined) throw new Error(`Unknown original live provider: ${id}`);
  if (env.OVID_LIVE_PROVIDER_TESTS !== "1") {
    throw new Error(`Live provider execution refused: set OVID_LIVE_PROVIDER_TESTS=1 for ${id}.`);
  }
  const suffix = id.toUpperCase().replaceAll("-", "_");
  const optInEnv = `OVID_LIVE_PROVIDER_${suffix}`;
  if (env[optInEnv] !== "1") throw new Error(`Live provider execution refused: set ${optInEnv}=1.`);
  if (row.releaseState === "deprecated") throw new Error(`Live provider execution refused: ${id} is deprecated and unavailable.`);
  if (write && !row.operations.some((operation) => operation.effect !== "read")) {
    throw new Error(`Live provider write refused: ${id} advertises no write operation.`);
  }
  if (!write) return { providerId: id, write, optInEnv };
  if (env.OVID_LIVE_PROVIDER_WRITE_TESTS !== "1") {
    throw new Error(`Live provider write refused: set OVID_LIVE_PROVIDER_WRITE_TESTS=1 for ${id}.`);
  }
  const disposableResourceEnv = `${optInEnv}_DISPOSABLE_RESOURCE`;
  if ((env[disposableResourceEnv] ?? "").trim() === "") {
    throw new Error(`Live provider write refused: declare ${disposableResourceEnv} and verify cleanup.`);
  }
  return { providerId: id, write, optInEnv, disposableResourceEnv };
}

export const ORIGINAL_LIVE_COMMAND = LIVE_COMMAND;
