/**
 * Verified files/suites expansion candidates.
 *
 * This module deliberately separates typed candidates from production-ready
 * ProviderDefinitions. Every candidate has official read paths and an OAuth
 * profile, but live app-registration/read/refresh/revoke/generation evidence
 * is still required before FILES_SUITES_PROVIDERS may contain it. No pasted
 * access-token or Firebase/Google sign-in-token fallback is accepted by the
 * handler factory: tokens must come from its provider-owned OAuth resolver.
 */

import { createHash } from "node:crypto";

import type { McpToolCallResult } from "../../client.js";
import {
  DEFAULT_EGRESS_LIMITS,
  assertBoundedHeadersOrCancel,
  readBoundedBody,
  type EgressLimits,
  type ProviderEgress,
} from "../../egress/responseLimits.js";
import { createSecretRedactor, type SecretRedactor } from "../../egress/redactor.js";
import {
  requestOAuth,
  requireOAuthEndpoint,
  type DiscoveredOAuthConfig,
  type OAuthNetworkOptions,
} from "../../oauth/discovery.js";
import { buildAuthorizeUrl, DEFAULT_MCP_REDIRECT_URI } from "../../oauth/flow.js";
import {
  snapshotProviderArgs,
  validateProviderArgs,
  type ProviderDefinition,
  type ProviderOperation,
} from "../../providers/types.js";
import {
  createProviderRegistry,
  type AuthProfile,
  type ProviderReadinessRow,
} from "../../providers/registry.js";
import type { McpCallContext, NativeMcpHandler } from "../../transports/native.js";
import {
  createRestHandler,
  restToolDefs,
  resolveTimeoutSeconds,
  type RestServiceDescriptor,
  type RestToolDef,
} from "../engine.js";

export const FILES_SUITES_CANDIDATE_IDS = [
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
] as const;

export type FilesSuitesProviderId = (typeof FILES_SUITES_CANDIDATE_IDS)[number];

export type FilesSuitesRevokeTransport = "dropbox_bearer" | "box_form" | "google_form";

export interface FilesSuitesOAuthProfile {
  profileId: string;
  authorizationUrl: string;
  tokenUrl: string;
  revokeUrl: string | null;
  revokeTransport: FilesSuitesRevokeTransport | null;
  pkce: "S256" | "unsupported";
  tokenSource: "provider_authorization_code";
  clientSecretRequired: boolean;
  offlineParameter?: readonly [string, string];
  webRedirectUri: string;
  androidRedirectUri: string | null;
  stateRequired: true;
  refreshSkewMs: number;
  disconnectGenerationRequired: true;
}

const OAUTH_PROFILE_DEFAULTS = Object.freeze({
  webRedirectUri: DEFAULT_MCP_REDIRECT_URI,
  androidRedirectUri: null,
  stateRequired: true as const,
  refreshSkewMs: 30_000,
});

export function filesSuitesAndroidRegistrationBlocker(profile: FilesSuitesOAuthProfile): string | null {
  return profile.androidRedirectUri === null ? `${profile.profileId}.androidRedirectUri` : null;
}

export const FILES_SUITES_OAUTH_PROFILES: Readonly<Record<string, FilesSuitesOAuthProfile>> = Object.freeze({
  "dropbox-user-oauth": Object.freeze({
    ...OAUTH_PROFILE_DEFAULTS,
    profileId: "dropbox-user-oauth",
    authorizationUrl: "https://www.dropbox.com/oauth2/authorize?token_access_type=offline",
    tokenUrl: "https://api.dropboxapi.com/oauth2/token",
    revokeUrl: "https://api.dropboxapi.com/2/auth/token/revoke",
    revokeTransport: "dropbox_bearer",
    pkce: "S256",
    tokenSource: "provider_authorization_code",
    clientSecretRequired: false,
    offlineParameter: ["token_access_type", "offline"] as const,
    disconnectGenerationRequired: true,
  }),
  "box-user-oauth": Object.freeze({
    ...OAUTH_PROFILE_DEFAULTS,
    profileId: "box-user-oauth",
    authorizationUrl: "https://account.box.com/api/oauth2/authorize",
    tokenUrl: "https://api.box.com/oauth2/token",
    revokeUrl: "https://api.box.com/oauth2/revoke",
    revokeTransport: "box_form",
    pkce: "unsupported",
    tokenSource: "provider_authorization_code",
    clientSecretRequired: true,
    disconnectGenerationRequired: true,
  }),
  "google-workspace-oauth": Object.freeze({
    ...OAUTH_PROFILE_DEFAULTS,
    profileId: "google-workspace-oauth",
    authorizationUrl: "https://accounts.google.com/o/oauth2/v2/auth?access_type=offline&prompt=consent&include_granted_scopes=false",
    tokenUrl: "https://oauth2.googleapis.com/token",
    revokeUrl: "https://oauth2.googleapis.com/revoke",
    revokeTransport: "google_form",
    pkce: "S256",
    tokenSource: "provider_authorization_code",
    clientSecretRequired: true,
    offlineParameter: ["access_type", "offline"] as const,
    disconnectGenerationRequired: true,
  }),
  "microsoft-graph-common-oauth": Object.freeze({
    ...OAUTH_PROFILE_DEFAULTS,
    profileId: "microsoft-graph-common-oauth",
    authorizationUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
    tokenUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    revokeUrl: null,
    revokeTransport: null,
    pkce: "S256",
    tokenSource: "provider_authorization_code",
    clientSecretRequired: false,
    disconnectGenerationRequired: true,
  }),
  "microsoft-graph-organizations-oauth": Object.freeze({
    ...OAUTH_PROFILE_DEFAULTS,
    profileId: "microsoft-graph-organizations-oauth",
    authorizationUrl: "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize",
    tokenUrl: "https://login.microsoftonline.com/organizations/oauth2/v2.0/token",
    revokeUrl: null,
    revokeTransport: null,
    pkce: "S256",
    tokenSource: "provider_authorization_code",
    clientSecretRequired: false,
    disconnectGenerationRequired: true,
  }),
});

const JSON_LIMITS: ProviderOperation["limits"] = Object.freeze({
  timeoutMs: 30_000,
  responseBytes: 65_536,
  frameBytes: 65_536,
  pageBytes: 65_536,
});
const TEXT_LIMITS: ProviderOperation["limits"] = Object.freeze({
  timeoutMs: 30_000,
  responseBytes: 8_192,
  frameBytes: 8_192,
  pageBytes: 8_192,
});
const JSON_OUTPUT = Object.freeze({ kind: "redacted_json" as const, maxBytes: 8_192 });
const TEXT_OUTPUT = Object.freeze({ kind: "redacted_text" as const, maxBytes: 8_192 });
const CATALOG_VERSION = "2026-10-24.files-suites.v1";
const VERIFIED_AT = "2026-10-24";

function objectSchema(
  properties: Record<string, unknown> = {},
  required: readonly string[] = [],
): Record<string, unknown> {
  return {
    type: "object",
    properties,
    required: [...required],
    additionalProperties: false,
    maxProperties: Object.keys(properties).length,
  };
}

const EMPTY_CONNECTION_SCHEMA = Object.freeze(objectSchema());
const ID_SCHEMA = Object.freeze({ type: "string", minLength: 1, maxLength: 512 });
const PATH_SCHEMA = Object.freeze({ type: "string", minLength: 1, maxLength: 512 });
const CURSOR_SCHEMA = Object.freeze({ type: "string", minLength: 1, maxLength: 4_096 });
const TIME_SCHEMA = Object.freeze({ type: "string", minLength: 20, maxLength: 35 });
const RANGE_SCHEMA = Object.freeze({ type: "string", minLength: 3, maxLength: 140 });
const OAUTH_CONNECTION_SCHEMA = Object.freeze(objectSchema({
  oauth_access_token: { type: "string", minLength: 1, maxLength: 16_384 },
}, ["oauth_access_token"]));

function constRef(value: unknown): string {
  return `const:${JSON.stringify(value)}`;
}

function tool(
  providerId: FilesSuitesProviderId,
  input: Omit<RestToolDef, "effect" | "approval" | "request" | "limits" | "outputPolicy" | "requiredScopes"> & {
    requiredScopes: readonly string[];
    text?: boolean;
  },
): RestToolDef {
  const { text = false, ...definition } = input;
  return {
    ...definition,
    effect: "read",
    approval: "mode",
    request: { originKey: providerId, method: input.method, pathTemplate: input.path },
    limits: text ? TEXT_LIMITS : JSON_LIMITS,
    outputPolicy: text ? TEXT_OUTPUT : JSON_OUTPUT,
  };
}

function oauthDescriptor(
  providerId: FilesSuitesProviderId,
  displayName: string,
  description: string,
  baseUrl: string,
  tools: RestToolDef[],
): RestServiceDescriptor {
  return {
    curatedId: providerId,
    displayName,
    description,
    baseUrl,
    auth: "bearer",
    authPrefix: "Bearer ",
    credentialKey: "oauth_access_token",
    credentialLabel: "provider-owned OAuth access token",
    connectionSchema: OAUTH_CONNECTION_SCHEMA,
    tools,
  };
}

const DROPBOX_DESCRIPTOR = oauthDescriptor(
  "dropbox",
  "Dropbox Files",
  "Read folder and file metadata with a separately bounded text download.",
  "https://api.dropboxapi.com",
  [
    tool("dropbox", {
      name: "list_folder",
      description: "List the root folder with a fixed non-recursive 20-entry page (Dropbox read RPC).",
      method: "POST",
      path: "/2/files/list_folder",
      requiredScopes: ["files.metadata.read"],
      inputSchema: objectSchema(),
      bodyTemplate: { path: constRef(""), recursive: constRef(false), limit: constRef(20) },
    }),
    tool("dropbox", {
      name: "list_folder_continue",
      description: "Read one bounded continuation page using an opaque Dropbox cursor.",
      method: "POST",
      path: "/2/files/list_folder/continue",
      requiredScopes: ["files.metadata.read"],
      inputSchema: objectSchema({ cursor: CURSOR_SCHEMA }, ["cursor"]),
      required: ["cursor"],
      bodyTemplate: { cursor: "arg:cursor" },
    }),
    tool("dropbox", {
      name: "get_metadata",
      description: "Get one file or folder's metadata without media or deleted-item expansion.",
      method: "POST",
      path: "/2/files/get_metadata",
      requiredScopes: ["files.metadata.read"],
      inputSchema: objectSchema({ path: PATH_SCHEMA }, ["path"]),
      required: ["path"],
      bodyTemplate: {
        path: "arg:path",
        include_media_info: constRef(false),
        include_deleted: constRef(false),
        include_has_explicit_shared_members: constRef(false),
      },
    }),
    tool("dropbox", {
      name: "download_text",
      description: "Download UTF-8 text after a metadata size/extension preflight; fixed content origin, at most 8192 bytes.",
      method: "POST",
      path: "/2/files/download",
      requiredScopes: ["files.content.read"],
      inputSchema: objectSchema({ path: PATH_SCHEMA }, ["path"]),
      required: ["path"],
      text: true,
    }),
  ],
);

const BOX_DESCRIPTOR = oauthDescriptor(
  "box",
  "Box Files",
  "Read folder items and file metadata; redirecting binary downloads are intentionally not exposed.",
  "https://api.box.com",
  [
    tool("box", {
      name: "list_root_items",
      description: "List one 20-item root-folder marker page with narrow metadata fields.",
      method: "GET",
      path: "/2.0/folders/0/items",
      requiredScopes: ["root_readonly"],
      inputSchema: objectSchema(),
      fixedQuery: { usemarker: "true", limit: "20", fields: "id,type,name,size,modified_at" },
    }),
    tool("box", {
      name: "get_file",
      description: "Get narrow metadata for one Box file.",
      method: "GET",
      path: "/2.0/files/{file_id}",
      requiredScopes: ["root_readonly"],
      inputSchema: objectSchema({ file_id: ID_SCHEMA }, ["file_id"]),
      required: ["file_id"],
      fixedQuery: { fields: "id,name,size,modified_at" },
    }),
  ],
);

const ONEDRIVE_DESCRIPTOR = oauthDescriptor(
  "onedrive",
  "OneDrive Files",
  "Read OneDrive metadata through fixed Graph v1.0 operations; no arbitrary Graph or content redirect.",
  "https://graph.microsoft.com",
  [
    tool("onedrive", {
      name: "list_root_children",
      description: "List one 20-item page from the already provisioned user's drive root.",
      method: "GET",
      path: "/v1.0/me/drive/root/children",
      requiredScopes: ["Files.Read"],
      inputSchema: objectSchema(),
      fixedQuery: { $top: "20", $select: "id,name,size,file,folder" },
    }),
    tool("onedrive", {
      name: "get_item",
      description: "Get narrow metadata for one OneDrive item.",
      method: "GET",
      path: "/v1.0/me/drive/items/{item_id}",
      requiredScopes: ["Files.Read"],
      inputSchema: objectSchema({ item_id: ID_SCHEMA }, ["item_id"]),
      required: ["item_id"],
      fixedQuery: { $select: "id,name,size,file,folder" },
    }),
  ],
);

const SHAREPOINT_DESCRIPTOR = oauthDescriptor(
  "sharepoint",
  "SharePoint Files",
  "Read SharePoint site, drive and item metadata through fixed Graph v1.0 paths.",
  "https://graph.microsoft.com",
  [
    tool("sharepoint", {
      name: "get_site",
      description: "Get one SharePoint site by opaque Graph site ID, not a caller-owned hostname or URL.",
      method: "GET",
      path: "/v1.0/sites/{site_id}",
      requiredScopes: ["Sites.Read.All"],
      inputSchema: objectSchema({ site_id: ID_SCHEMA }, ["site_id"]),
      required: ["site_id"],
      fixedQuery: { $select: "id,displayName,webUrl" },
    }),
    tool("sharepoint", {
      name: "get_drive",
      description: "Get the default drive metadata for one SharePoint site.",
      method: "GET",
      path: "/v1.0/sites/{site_id}/drive",
      requiredScopes: ["Files.Read"],
      inputSchema: objectSchema({ site_id: ID_SCHEMA }, ["site_id"]),
      required: ["site_id"],
      fixedQuery: { $select: "id,name,driveType" },
    }),
    tool("sharepoint", {
      name: "list_root_children",
      description: "List one 20-item metadata page in a SharePoint site's default drive.",
      method: "GET",
      path: "/v1.0/sites/{site_id}/drive/root/children",
      requiredScopes: ["Files.Read"],
      inputSchema: objectSchema({ site_id: ID_SCHEMA }, ["site_id"]),
      required: ["site_id"],
      fixedQuery: { $top: "20", $select: "id,name,size,file,folder" },
    }),
  ],
);

const GOOGLE_DOCS_DESCRIPTOR = oauthDescriptor(
  "google-docs",
  "Google Docs",
  "Read app-created/user-selected Docs and explicitly export native documents as bounded plain text.",
  "https://docs.googleapis.com",
  [
    tool("google-docs", {
      name: "get_document",
      description: "Get one document including current tab content under the per-file drive.file grant.",
      method: "GET",
      path: "/v1/documents/{document_id}",
      requiredScopes: ["https://www.googleapis.com/auth/drive.file"],
      inputSchema: objectSchema({ document_id: ID_SCHEMA }, ["document_id"]),
      required: ["document_id"],
      fixedQuery: { includeTabsContent: "true", fields: "documentId,title,revisionId,tabs" },
    }),
    tool("google-docs", {
      name: "export_text",
      description: "Export one Google-native document as text/plain, capped at 8192 UTF-8 bytes; never alt=media.",
      method: "GET",
      path: "/drive/v3/files/{document_id}/export?mimeType=text/plain",
      requiredScopes: ["https://www.googleapis.com/auth/drive.file"],
      inputSchema: objectSchema({ document_id: ID_SCHEMA }, ["document_id"]),
      required: ["document_id"],
      text: true,
    }),
  ],
);

const GOOGLE_SHEETS_DESCRIPTOR = oauthDescriptor(
  "google-sheets",
  "Google Sheets",
  "Read app-created/user-selected spreadsheet metadata and bounded A1 ranges.",
  "https://sheets.googleapis.com",
  [
    tool("google-sheets", {
      name: "get_spreadsheet",
      description: "Get spreadsheet and sheet properties without grid-data expansion.",
      method: "GET",
      path: "/v4/spreadsheets/{spreadsheet_id}",
      requiredScopes: ["https://www.googleapis.com/auth/drive.file"],
      inputSchema: objectSchema({ spreadsheet_id: ID_SCHEMA }, ["spreadsheet_id"]),
      required: ["spreadsheet_id"],
      fixedQuery: { fields: "spreadsheetId,properties.title,sheets.properties" },
    }),
    tool("google-sheets", {
      name: "get_values",
      description: "Get values from one explicit rectangle of at most 100 rows and 26 columns.",
      method: "GET",
      path: "/v4/spreadsheets/{spreadsheet_id}/values/{range}",
      requiredScopes: ["https://www.googleapis.com/auth/drive.file"],
      inputSchema: objectSchema({ spreadsheet_id: ID_SCHEMA, range: RANGE_SCHEMA }, ["spreadsheet_id", "range"]),
      required: ["spreadsheet_id", "range"],
      fixedQuery: { majorDimension: "ROWS", fields: "range,majorDimension,values" },
    }),
  ],
);

const GOOGLE_CALENDAR_DESCRIPTOR = oauthDescriptor(
  "google-calendar",
  "Google Calendar",
  "Read primary-calendar events with narrow fields and no insert or notification operation.",
  "https://www.googleapis.com",
  [
    tool("google-calendar", {
      name: "list_upcoming_events",
      description: "List one 20-event singleEvents page from the primary calendar after an explicit RFC3339 timeMin.",
      method: "GET",
      path: "/calendar/v3/calendars/primary/events",
      requiredScopes: ["https://www.googleapis.com/auth/calendar.events.readonly"],
      inputSchema: objectSchema({ time_min: TIME_SCHEMA }, ["time_min"]),
      required: ["time_min"],
      queryArgMap: { time_min: "timeMin" },
      fixedQuery: {
        singleEvents: "true",
        orderBy: "startTime",
        maxResults: "20",
        fields: "items(id,summary,start,end,updated),nextPageToken,nextSyncToken",
      },
    }),
    tool("google-calendar", {
      name: "get_event",
      description: "Get narrow metadata for one event on the primary calendar.",
      method: "GET",
      path: "/calendar/v3/calendars/primary/events/{event_id}",
      requiredScopes: ["https://www.googleapis.com/auth/calendar.events.readonly"],
      inputSchema: objectSchema({ event_id: ID_SCHEMA }, ["event_id"]),
      required: ["event_id"],
      fixedQuery: { fields: "id,summary,start,end,updated,status" },
    }),
  ],
);

const GOOGLE_TASKS_DESCRIPTOR = oauthDescriptor(
  "google-tasks",
  "Google Tasks",
  "Read task lists and visible tasks with bounded pages and no insert/clear operation.",
  "https://tasks.googleapis.com",
  [
    tool("google-tasks", {
      name: "list_task_lists",
      description: "List one 20-item task-list page with narrow fields.",
      method: "GET",
      path: "/tasks/v1/users/@me/lists",
      requiredScopes: ["https://www.googleapis.com/auth/tasks.readonly"],
      inputSchema: objectSchema(),
      fixedQuery: { maxResults: "20", fields: "items(id,title,updated),nextPageToken" },
    }),
    tool("google-tasks", {
      name: "list_tasks",
      description: "List visible, incomplete, non-hidden and non-deleted tasks in one bounded page.",
      method: "GET",
      path: "/tasks/v1/lists/{tasklist_id}/tasks",
      requiredScopes: ["https://www.googleapis.com/auth/tasks.readonly"],
      inputSchema: objectSchema({ tasklist_id: ID_SCHEMA }, ["tasklist_id"]),
      required: ["tasklist_id"],
      fixedQuery: {
        maxResults: "20",
        showCompleted: "false",
        showHidden: "false",
        showDeleted: "false",
        fields: "items(id,title,status,due,updated),nextPageToken",
      },
    }),
    tool("google-tasks", {
      name: "get_task",
      description: "Get narrow metadata for one task.",
      method: "GET",
      path: "/tasks/v1/lists/{tasklist_id}/tasks/{task_id}",
      requiredScopes: ["https://www.googleapis.com/auth/tasks.readonly"],
      inputSchema: objectSchema({ tasklist_id: ID_SCHEMA, task_id: ID_SCHEMA }, ["tasklist_id", "task_id"]),
      required: ["tasklist_id", "task_id"],
      fixedQuery: { fields: "id,title,status,due,updated" },
    }),
  ],
);

const GMAIL_DESCRIPTOR = oauthDescriptor(
  "gmail",
  "Gmail Metadata",
  "Read message IDs and explicitly selected headers only; no q search, raw MIME, drafts or sending.",
  "https://gmail.googleapis.com",
  [
    tool("gmail", {
      name: "list_messages",
      description: "List one 20-message ID page without q, which is incompatible with the gmail.metadata scope.",
      method: "GET",
      path: "/gmail/v1/users/me/messages",
      requiredScopes: ["https://www.googleapis.com/auth/gmail.metadata"],
      inputSchema: objectSchema(),
      fixedQuery: { maxResults: "20", fields: "messages(id,threadId),nextPageToken,resultSizeEstimate" },
    }),
    tool("gmail", {
      name: "get_message_metadata",
      description: "Get one message in metadata format with only From and Subject headers; never raw/full MIME.",
      method: "GET",
      path: "/gmail/v1/users/me/messages/{message_id}?format=metadata&metadataHeaders=From&metadataHeaders=Subject&fields=id,threadId,labelIds,payload.headers",
      requiredScopes: ["https://www.googleapis.com/auth/gmail.metadata"],
      inputSchema: objectSchema({ message_id: ID_SCHEMA }, ["message_id"]),
      required: ["message_id"],
    }),
  ],
);

const OUTLOOK_DESCRIPTOR = oauthDescriptor(
  "outlook",
  "Outlook Mail Metadata",
  "Read basic message metadata through Graph v1.0; no body, attachments, drafts or sendMail.",
  "https://graph.microsoft.com",
  [
    tool("outlook", {
      name: "list_messages",
      description: "List one 20-message page with Mail.ReadBasic metadata fields only.",
      method: "GET",
      path: "/v1.0/me/messages",
      requiredScopes: ["Mail.ReadBasic"],
      inputSchema: objectSchema(),
      fixedQuery: { $top: "20", $select: "id,subject,from,receivedDateTime,isRead" },
    }),
    tool("outlook", {
      name: "get_message",
      description: "Get one message with basic metadata fields only.",
      method: "GET",
      path: "/v1.0/me/messages/{message_id}",
      requiredScopes: ["Mail.ReadBasic"],
      inputSchema: objectSchema({ message_id: ID_SCHEMA }, ["message_id"]),
      required: ["message_id"],
      fixedQuery: { $select: "id,subject,from,receivedDateTime,isRead" },
    }),
  ],
);

export const FILES_SUITES_DESCRIPTORS: readonly RestServiceDescriptor[] = Object.freeze([
  DROPBOX_DESCRIPTOR,
  BOX_DESCRIPTOR,
  ONEDRIVE_DESCRIPTOR,
  SHAREPOINT_DESCRIPTOR,
  GOOGLE_DOCS_DESCRIPTOR,
  GOOGLE_SHEETS_DESCRIPTOR,
  GOOGLE_CALENDAR_DESCRIPTOR,
  GOOGLE_TASKS_DESCRIPTOR,
  GMAIL_DESCRIPTOR,
  OUTLOOK_DESCRIPTOR,
]);

function origins(values: readonly string[]): readonly URL[] {
  return Object.freeze(values.map((value) => new URL(value)));
}

export const FILES_SUITES_ORIGINS: Readonly<Record<FilesSuitesProviderId, readonly URL[]>> = Object.freeze({
  dropbox: origins(["https://api.dropboxapi.com", "https://content.dropboxapi.com"]),
  box: origins(["https://api.box.com"]),
  onedrive: origins(["https://graph.microsoft.com"]),
  sharepoint: origins(["https://graph.microsoft.com"]),
  "google-docs": origins(["https://docs.googleapis.com", "https://www.googleapis.com", "https://openidconnect.googleapis.com"]),
  "google-sheets": origins(["https://sheets.googleapis.com", "https://openidconnect.googleapis.com"]),
  "google-calendar": origins(["https://www.googleapis.com", "https://openidconnect.googleapis.com"]),
  "google-tasks": origins(["https://tasks.googleapis.com", "https://openidconnect.googleapis.com"]),
  gmail: origins(["https://gmail.googleapis.com", "https://openidconnect.googleapis.com"]),
  outlook: origins(["https://graph.microsoft.com"]),
});

export type FilesSuitesIdentityKind =
  | "dropbox_account"
  | "box_tokeninfo"
  | "microsoft_me"
  | "google_userinfo";

export interface FilesSuitesIdentityProfile {
  kind: FilesSuitesIdentityKind;
  url: string;
  method: "GET" | "POST";
  requiredScope: string | null;
}

/** Official metadata used only to prove the consenting tenant's stable identity. */
export const FILES_SUITES_IDENTITY_PROFILES: Readonly<Record<FilesSuitesProviderId, FilesSuitesIdentityProfile>> = Object.freeze({
  dropbox: Object.freeze({
    kind: "dropbox_account",
    url: "https://api.dropboxapi.com/2/users/get_current_account",
    method: "POST",
    requiredScope: "account_info.read",
  }),
  box: Object.freeze({
    kind: "box_tokeninfo",
    url: "https://api.box.com/oauth2/tokeninfo",
    method: "POST",
    requiredScope: null,
  }),
  onedrive: Object.freeze({
    kind: "microsoft_me",
    url: "https://graph.microsoft.com/v1.0/me?$select=id",
    method: "GET",
    requiredScope: "User.Read",
  }),
  sharepoint: Object.freeze({
    kind: "microsoft_me",
    url: "https://graph.microsoft.com/v1.0/me?$select=id",
    method: "GET",
    requiredScope: "User.Read",
  }),
  "google-docs": Object.freeze({
    kind: "google_userinfo",
    url: "https://openidconnect.googleapis.com/v1/userinfo",
    method: "GET",
    requiredScope: "openid",
  }),
  "google-sheets": Object.freeze({
    kind: "google_userinfo",
    url: "https://openidconnect.googleapis.com/v1/userinfo",
    method: "GET",
    requiredScope: "openid",
  }),
  "google-calendar": Object.freeze({
    kind: "google_userinfo",
    url: "https://openidconnect.googleapis.com/v1/userinfo",
    method: "GET",
    requiredScope: "openid",
  }),
  "google-tasks": Object.freeze({
    kind: "google_userinfo",
    url: "https://openidconnect.googleapis.com/v1/userinfo",
    method: "GET",
    requiredScope: "openid",
  }),
  gmail: Object.freeze({
    kind: "google_userinfo",
    url: "https://openidconnect.googleapis.com/v1/userinfo",
    method: "GET",
    requiredScope: "openid",
  }),
  outlook: Object.freeze({
    kind: "microsoft_me",
    url: "https://graph.microsoft.com/v1.0/me?$select=id",
    method: "GET",
    requiredScope: "User.Read",
  }),
});

/** Fail closed unless provider metadata proves the exact expected tenant user. */
export function assertFilesSuitesLiveIdentity(input: {
  providerId: FilesSuitesProviderId;
  clientId: string;
  expectedUserId: string;
  metadata: unknown;
}): void {
  const expected = input.expectedUserId.trim();
  if (expected === "" || expected.length > 256 || /[\x00-\x20\x7f]/.test(expected) ||
      typeof input.metadata !== "object" || input.metadata === null || Array.isArray(input.metadata)) {
    throw new Error("OAuth token identity evidence is invalid.");
  }
  const metadata = input.metadata as Record<string, unknown>;
  const profile = FILES_SUITES_IDENTITY_PROFILES[input.providerId];
  let matches = false;
  if (profile.kind === "dropbox_account") {
    matches = metadata.account_id === expected;
  } else if (profile.kind === "box_tokeninfo") {
    const user = metadata.user;
    matches = metadata.active === true && metadata.client_id === input.clientId &&
      typeof user === "object" && user !== null && !Array.isArray(user) &&
      (user as Record<string, unknown>).id === expected;
  } else if (profile.kind === "microsoft_me") {
    // Microsoft object IDs are tenant-specific, so this also binds the tenant.
    matches = metadata.id === expected;
  } else {
    matches = metadata.sub === expected;
  }
  if (!matches) throw new Error("OAuth token identity does not match the intended test user.");
}

export interface FilesSuitesLiveIdentityBinding {
  bind(input: {
    providerId: FilesSuitesProviderId;
    clientId: string;
    expectedUserId: string;
    accessToken: string;
    metadata: unknown;
  }): string;
  token(): string;
  clear(): void;
}

/** A failed revalidation clears the old grant; a synthetic MCP uid is never consulted. */
export function createFilesSuitesLiveIdentityBinding(): FilesSuitesLiveIdentityBinding {
  let verifiedToken: string | null = null;
  return {
    bind(input): string {
      verifiedToken = null;
      assertFilesSuitesLiveIdentity(input);
      if (input.accessToken.trim() === "") throw new Error("OAuth token identity evidence is invalid.");
      verifiedToken = input.accessToken;
      return verifiedToken;
    },
    token(): string {
      return verifiedToken ?? "";
    },
    clear(): void {
      verifiedToken = null;
    },
  };
}

export interface FilesSuitesCandidate extends Omit<ProviderDefinition, "readiness"> {
  providerId: FilesSuitesProviderId;
  releaseState: "blocked";
  blockers: readonly string[];
  liveReadEvidence: null;
}

interface CandidateSpec {
  providerId: FilesSuitesProviderId;
  displayName: string;
  description: string;
  authProfileId: keyof typeof FILES_SUITES_OAUTH_PROFILES;
  officialDocs: readonly string[];
  additionalBlockers?: readonly string[];
}

const COMMON_BLOCKERS = [
  "live OAuth read/refresh/revoke/disconnect-generation evidence not provided",
  "live provider-identity binding evidence not provided",
  "cross-instance disconnect-generation fencing and shared single-flight are not composed for static provider profiles",
  "approved Android redirect registration not provided; environment-only configuration cannot unblock",
] as const;
const MICROSOFT_REVOKE_BLOCKER =
  "Microsoft delegated remote token revocation is not supported by this profile; local disconnect still requires generation proof";

const CANDIDATE_SPECS = [
  {
    providerId: "dropbox", displayName: "Dropbox Files", authProfileId: "dropbox-user-oauth",
    description: "Scoped Dropbox metadata and bounded text reads.",
    officialDocs: [
      "https://developers.dropbox.com/oauth-guide",
      "https://docs.dropboxapi.com/dropbox-api/api-reference/user-endpoints/users/get-current-account",
      "https://docs.dropboxapi.com/dropbox-api/api-reference/user-endpoints/files/list-folder",
      "https://docs.dropboxapi.com/dropbox-api/api-reference/user-endpoints/files/list-folder-continue",
      "https://docs.dropboxapi.com/dropbox-api/api-reference/user-endpoints/files/get-metadata",
      "https://docs.dropboxapi.com/dropbox-api/api-reference/user-endpoints/files/download",
      "https://docs.dropboxapi.com/dropbox-api/api-reference/user-endpoints/auth/token-revoke",
    ],
  },
  {
    providerId: "box", displayName: "Box Files", authProfileId: "box-user-oauth",
    description: "Scoped Box folder and file metadata reads.",
    officialDocs: [
      "https://developer.box.com/guides/authentication/oauth2/",
      "https://developer.box.com/reference/get-authorize/",
      "https://developer.box.com/guides/authentication/tokens/refresh/",
      "https://developer.box.com/reference/get-folders-id-items/",
      "https://developer.box.com/reference/get-files-id/",
      "https://developer.box.com/reference/post-oauth2-revoke/",
      "https://developer.box.com/reference/post-oauth2-tokeninfo/",
    ],
    additionalBlockers: ["Box PKCE support is not documented on the official authorize endpoint; Web/Android PKCE evidence is unavailable"],
  },
  {
    providerId: "onedrive", displayName: "OneDrive Files", authProfileId: "microsoft-graph-common-oauth",
    description: "Delegated OneDrive metadata reads on Microsoft Graph v1.0.",
    officialDocs: [
      "https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow",
      "https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0",
      "https://learn.microsoft.com/en-us/graph/api/driveitem-list-children?view=graph-rest-1.0",
      "https://learn.microsoft.com/en-us/graph/api/driveitem-get?view=graph-rest-1.0",
    ],
    additionalBlockers: [MICROSOFT_REVOKE_BLOCKER],
  },
  {
    providerId: "sharepoint", displayName: "SharePoint Files", authProfileId: "microsoft-graph-organizations-oauth",
    description: "Delegated SharePoint site and drive metadata reads on Microsoft Graph v1.0.",
    officialDocs: [
      "https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow",
      "https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0",
      "https://learn.microsoft.com/en-us/graph/api/site-get?view=graph-rest-1.0",
      "https://learn.microsoft.com/en-us/graph/api/drive-get?view=graph-rest-1.0",
      "https://learn.microsoft.com/en-us/graph/api/driveitem-list-children?view=graph-rest-1.0",
    ],
    additionalBlockers: [MICROSOFT_REVOKE_BLOCKER],
  },
  {
    providerId: "google-docs", displayName: "Google Docs", authProfileId: "google-workspace-oauth",
    description: "Per-file Google Docs reads and bounded native plain-text export.",
    officialDocs: [
      "https://developers.google.com/identity/protocols/oauth2/web-server",
      "https://developers.google.com/identity/protocols/oauth2/openid-connect",
      "https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/get",
      "https://developers.google.com/workspace/drive/api/reference/rest/v3/files/export",
    ],
  },
  {
    providerId: "google-sheets", displayName: "Google Sheets", authProfileId: "google-workspace-oauth",
    description: "Per-file spreadsheet metadata and bounded range reads.",
    officialDocs: [
      "https://developers.google.com/identity/protocols/oauth2/web-server",
      "https://developers.google.com/identity/protocols/oauth2/openid-connect",
      "https://developers.google.com/workspace/sheets/api/reference/rest/v4/spreadsheets/get",
      "https://developers.google.com/workspace/sheets/api/reference/rest/v4/spreadsheets.values/get",
    ],
  },
  {
    providerId: "google-calendar", displayName: "Google Calendar", authProfileId: "google-workspace-oauth",
    description: "Read-only primary-calendar event metadata.",
    officialDocs: [
      "https://developers.google.com/identity/protocols/oauth2/web-server",
      "https://developers.google.com/identity/protocols/oauth2/openid-connect",
      "https://developers.google.com/workspace/calendar/api/v3/reference/events/list",
      "https://developers.google.com/workspace/calendar/api/v3/reference/events/get",
    ],
  },
  {
    providerId: "google-tasks", displayName: "Google Tasks", authProfileId: "google-workspace-oauth",
    description: "Read-only task-list and visible-task metadata.",
    officialDocs: [
      "https://developers.google.com/identity/protocols/oauth2/web-server",
      "https://developers.google.com/identity/protocols/oauth2/openid-connect",
      "https://developers.google.com/workspace/tasks/reference/rest/v1/tasklists/list",
      "https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/list",
      "https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/get",
    ],
  },
  {
    providerId: "gmail", displayName: "Gmail Metadata", authProfileId: "google-workspace-oauth",
    description: "Restricted-scope Gmail message metadata without search, body or sending.",
    officialDocs: [
      "https://developers.google.com/identity/protocols/oauth2/web-server",
      "https://developers.google.com/identity/protocols/oauth2/openid-connect",
      "https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list",
      "https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/get",
    ],
    additionalBlockers: ["Gmail restricted-scope production verification/security assessment evidence not provided"],
  },
  {
    providerId: "outlook", displayName: "Outlook Mail Metadata", authProfileId: "microsoft-graph-common-oauth",
    description: "Delegated Mail.ReadBasic message metadata without body or sendMail.",
    officialDocs: [
      "https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow",
      "https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0",
      "https://learn.microsoft.com/en-us/graph/api/user-list-messages?view=graph-rest-1.0",
      "https://learn.microsoft.com/en-us/graph/api/message-get?view=graph-rest-1.0",
      "https://learn.microsoft.com/en-us/graph/api/user-sendmail?view=graph-rest-1.0",
    ],
    additionalBlockers: [MICROSOFT_REVOKE_BLOCKER],
  },
] satisfies readonly CandidateSpec[];

export const FILES_SUITES_CANDIDATES = Object.freeze(
  CANDIDATE_SPECS.map((spec) => {
    const descriptor = FILES_SUITES_DESCRIPTORS.find((entry) => entry.curatedId === spec.providerId)!;
    const operations = restToolDefs(descriptor).map((operation): ProviderOperation => ({
      name: operation.name,
      description: operation.description ?? operation.name,
      effect: operation.effect,
      approval: operation.approval,
      requiredScopes: operation.requiredScopes,
      inputSchema: operation.inputSchema ?? objectSchema(),
      outputPolicy: operation.outputPolicy,
      request: operation.request,
      limits: operation.limits,
    }));
    return Object.freeze({
      providerId: spec.providerId,
      catalogVersion: CATALOG_VERSION,
      displayName: spec.displayName,
      description: spec.description,
      officialDocs: Object.freeze(spec.officialDocs.map((url) => Object.freeze({ url, verifiedAt: VERIFIED_AT }))),
      authProfileId: spec.authProfileId,
      connectionSchema: EMPTY_CONNECTION_SCHEMA,
      operations: Object.freeze(operations),
      releaseState: "blocked",
      blockers: Object.freeze([...COMMON_BLOCKERS, ...(spec.additionalBlockers ?? [])]),
      liveReadEvidence: null,
    });
  }),
);

export const FILES_SUITES_CONTRACT_DEFINITIONS: readonly ProviderDefinition[] = Object.freeze(
  FILES_SUITES_CANDIDATES.map((row) => Object.freeze({
    providerId: row.providerId,
    catalogVersion: row.catalogVersion,
    displayName: row.displayName,
    description: row.description,
    officialDocs: row.officialDocs,
    authProfileId: row.authProfileId,
    connectionSchema: row.connectionSchema,
    operations: row.operations,
    readiness: "supported" as const,
  })),
);

function apiVersion(providerId: FilesSuitesProviderId, url: string): string {
  if (url.includes("oauth") || url.includes("identity-platform")) {
    if (providerId === "dropbox") return "OAuth 2.0 / Dropbox API v2";
    if (providerId === "box") return "OAuth 2.0 / Box API 2024.0";
    if (["onedrive", "sharepoint", "outlook"].includes(providerId)) return "Entra OAuth 2.0 v2.0";
    return "Google OAuth 2.0";
  }
  if (providerId === "dropbox") return "Dropbox API v2";
  if (providerId === "box") return "Box API 2024.0";
  if (["onedrive", "sharepoint", "outlook"].includes(providerId)) return "Microsoft Graph v1.0";
  if (providerId === "google-docs") return url.includes("/drive/") ? "Drive API v3" : "Docs API v1";
  if (providerId === "google-sheets") return "Sheets API v4";
  if (providerId === "google-calendar") return "Calendar API v3";
  if (providerId === "google-tasks") return "Tasks API v1";
  return "Gmail API v1";
}

function readinessAuth(row: FilesSuitesCandidate): AuthProfile {
  const profile = FILES_SUITES_OAUTH_PROFILES[row.authProfileId];
  const config = filesSuitesOAuthConfig(row.providerId, "readiness-client");
  return {
    profileId: profile.profileId,
    tokenType: "per-user delegated OAuth 2.0 access token",
    authorizationPrefix: "Bearer ",
    minimumScopes: config.scopes,
    tenantOrigins: FILES_SUITES_ORIGINS[row.providerId].map((origin) => origin.origin),
    refreshBehavior: row.providerId === "box"
      ? "Refresh helper requires one-use rotating refresh-token replacement; shared single-flight is not composed."
      : "Offline refresh helper replaces a returned refresh token and retains the old one only when omitted; shared single-flight is not composed.",
    revokeBehavior: profile.revokeUrl === null
      ? "No delegated application revoke endpoint is documented; never claim remote revocation."
      : `Revoke only through the documented fixed endpoint ${profile.revokeUrl}.`,
    disconnectBehavior: "Blocked until cross-instance disconnectGeneration fencing is proven; local token removal alone is insufficient.",
  };
}

export const FILES_SUITES_READINESS_ROWS: readonly ProviderReadinessRow[] = Object.freeze(
  FILES_SUITES_CANDIDATES.map((row): ProviderReadinessRow => Object.freeze({
    providerId: row.providerId,
    catalogOwner: "task-8-files-suites",
    officialDocs: row.officialDocs.map((doc) => ({
      ...doc,
      apiVersion: apiVersion(row.providerId, doc.url),
      reviewer: "Official batch B first-party review + OpenCode Task 8",
    })),
    operations: [...row.operations],
    auth: readinessAuth(row),
    effects: Object.fromEntries(row.operations.map((operation) => [
      operation.name,
      { effect: operation.effect, approval: operation.approval },
    ])),
    isolationEvidence: [
      `test/providers/filesSuites.contract.test.ts::${row.providerId} fixed-origin tenant A/B OAuth isolation`,
      `test/providers/filesSuites.contract.test.ts::${row.providerId} hostile argument denied before token resolution or egress`,
      "src/rest/descriptors/filesSuites.test.ts::bounded fields, pages, content and no write surface",
    ],
    fixtures: [
      `test/providers/filesSuites.contract.test.ts::${row.providerId} sanitized request and redacted cross-user response fixtures`,
    ],
    automatedEvidence: {
      test: "UNEXECUTED after 2026-10-25 review fixes; historical 103/103 at 2026-10-24T17:53:00.000Z: ./node_modules/.bin/vitest run src/rest/descriptors/filesSuites.test.ts test/providers/filesSuites.contract.test.ts",
      result: "not_run" as const,
      runAt: null,
    },
    liveReadEvidence: null,
    liveWriteEvidence: [],
    credentials: "not provided" as const,
    releaseState: "blocked" as const,
  })),
);

const FILES_SUITES_REGISTRY = createProviderRegistry();
for (const definition of FILES_SUITES_CONTRACT_DEFINITIONS) {
  const row = FILES_SUITES_READINESS_ROWS.find((entry) => entry.providerId === definition.providerId)!;
  FILES_SUITES_REGISTRY.registerProvider(definition, row);
}

/** Empty until every required live and lifecycle gate has real evidence. */
export const FILES_SUITES_PROVIDERS: readonly ProviderDefinition[] = Object.freeze(
  FILES_SUITES_REGISTRY.catalogDefinitions(),
);

export interface FilesSuitesOAuthConfig extends DiscoveredOAuthConfig {
  providerId: FilesSuitesProviderId;
  profileId: string;
  revokeUrl: string | null;
  pkce: "S256" | "unsupported";
  tokenSource: "provider_authorization_code";
}

export function filesSuitesOAuthConfig(
  providerId: FilesSuitesProviderId,
  clientId: string,
): FilesSuitesOAuthConfig {
  const row = FILES_SUITES_CANDIDATES.find((entry) => entry.providerId === providerId);
  if (row === undefined || clientId.trim() === "") throw new Error("OAuth provider/client configuration is invalid.");
  const profile = FILES_SUITES_OAUTH_PROFILES[row.authProfileId];
  if (profile === undefined) throw new Error("OAuth provider profile is unavailable.");
  const scopes = [...new Set(row.operations.flatMap((operation) => operation.requiredScopes))];
  const identityScope = FILES_SUITES_IDENTITY_PROFILES[providerId].requiredScope;
  if (identityScope !== null) scopes.push(identityScope);
  if (row.authProfileId.startsWith("microsoft-graph-")) scopes.push("offline_access");
  return {
    providerId,
    profileId: profile.profileId,
    authorizationUrl: profile.authorizationUrl,
    tokenUrl: profile.tokenUrl,
    revokeUrl: profile.revokeUrl,
    clientId: clientId.trim(),
    scopes,
    discovered: false,
    pkce: profile.pkce,
    tokenSource: "provider_authorization_code",
  };
}

export interface FilesSuitesLiveOAuthEvidence {
  profile: FilesSuitesOAuthProfile;
  config: FilesSuitesOAuthConfig;
  authorizeUrl: string;
  codeVerifier: string;
  expectedState: string;
  callbackState: string;
  webRedirectUri: string;
  androidRedirectUri: string;
}

/** Offline validation of the exact external consent evidence used by the live harness. */
export function assertFilesSuitesLiveOAuthEvidence(evidence: FilesSuitesLiveOAuthEvidence): void {
  if (evidence.profile.pkce !== "S256") throw new Error("OAuth PKCE is unsupported for this profile.");
  if (evidence.config.profileId !== evidence.profile.profileId) {
    throw new Error("OAuth client config does not match the provider profile.");
  }
  if (evidence.webRedirectUri !== evidence.profile.webRedirectUri) {
    throw new Error("OAuth Web redirect does not match the registered profile.");
  }
  if (evidence.profile.androidRedirectUri === null ||
      evidence.androidRedirectUri !== evidence.profile.androidRedirectUri) {
    throw new Error("OAuth Android redirect does not match the registered profile.");
  }
  if (!/^[A-Za-z0-9._~-]{43,128}$/.test(evidence.codeVerifier)) {
    throw new Error("OAuth PKCE verifier is invalid.");
  }
  if (!/^[A-Za-z0-9._~-]{16,256}$/.test(evidence.expectedState) ||
      evidence.callbackState !== evidence.expectedState) {
    throw new Error("OAuth callback state does not match the authorization attempt.");
  }
  const webRedirect = new URL(evidence.webRedirectUri);
  if (webRedirect.protocol !== "https:") throw new Error("OAuth Web redirect must use HTTPS.");
  const androidRedirect = new URL(evidence.androidRedirectUri);
  if (androidRedirect.username !== "" || androidRedirect.password !== "") {
    throw new Error("OAuth Android redirect is invalid.");
  }
  const expectedChallenge = createHash("sha256").update(evidence.codeVerifier, "ascii").digest("base64url");
  const expectedAuthorize = new URL(buildAuthorizeUrl(evidence.config, {
    state: evidence.expectedState,
    codeChallenge: expectedChallenge,
    redirectUri: evidence.webRedirectUri,
  }));
  const actualAuthorize = new URL(evidence.authorizeUrl);
  if (actualAuthorize.origin + actualAuthorize.pathname !== expectedAuthorize.origin + expectedAuthorize.pathname ||
      actualAuthorize.searchParams.has("access_token") || actualAuthorize.hash !== "") {
    throw new Error("OAuth authorize URL does not match the provider profile.");
  }
  const expectedParams = [...expectedAuthorize.searchParams].sort();
  const actualParams = [...actualAuthorize.searchParams].sort();
  if (JSON.stringify(actualParams) !== JSON.stringify(expectedParams)) {
    throw new Error("OAuth authorize URL parameters do not match the provider profile.");
  }
}

export interface FilesSuitesOAuthTokenSet {
  accessToken: string;
  refreshToken: string | null;
  expiresAt: number | null;
  grantedScopes: readonly string[];
}

interface OAuthClientInput {
  network: OAuthNetworkOptions;
  clientId: string;
  clientSecret?: string;
}

interface OAuthCodeInput extends OAuthClientInput {
  code: string;
  codeVerifier: string;
  redirectUri: string;
}

interface OAuthRefreshInput extends OAuthClientInput {
  refreshToken: string;
}

interface OAuthRevokeInput extends OAuthClientInput {
  accessToken: string;
  refreshToken: string | null;
}

function requirePinnedOAuthEgress(network: OAuthNetworkOptions): void {
  if (network.providerEgress === undefined) {
    throw new Error("ProviderEgress is required for OAuth provider requests.");
  }
}

function profileFor(providerId: FilesSuitesProviderId): FilesSuitesOAuthProfile {
  const row = FILES_SUITES_CANDIDATES.find((entry) => entry.providerId === providerId);
  const profile = row === undefined ? undefined : FILES_SUITES_OAUTH_PROFILES[row.authProfileId];
  if (profile === undefined) throw new Error("OAuth provider profile is unavailable.");
  return profile;
}

function clientFields(input: OAuthClientInput, profile: FilesSuitesOAuthProfile): Record<string, string> {
  if (input.clientId.trim() === "" || (profile.clientSecretRequired && (input.clientSecret ?? "").trim() === "")) {
    throw new Error("OAuth client registration is incomplete.");
  }
  return {
    client_id: input.clientId.trim(),
    ...(profile.clientSecretRequired && (input.clientSecret ?? "") !== ""
      ? { client_secret: input.clientSecret! }
      : {}),
  };
}

function canonicalScope(scope: string): string {
  return scope.toLowerCase().replace(/^https:\/\/graph\.microsoft\.com\//, "");
}

function parseTokenResponse(
  body: Record<string, unknown>,
  config: FilesSuitesOAuthConfig,
  previousRefreshToken?: string,
  requireGrantedScopes = false,
): FilesSuitesOAuthTokenSet {
  const access = body["access_token"];
  const tokenType = body["token_type"] ?? "Bearer";
  const expiresIn = body["expires_in"];
  const refresh = body["refresh_token"];
  if (
    typeof access !== "string" || access === "" || /[\x00-\x20\x7f]/.test(access) ||
    typeof tokenType !== "string" || tokenType.toLowerCase() !== "bearer" ||
    (refresh !== undefined && typeof refresh !== "string") ||
    (expiresIn !== undefined && (typeof expiresIn !== "number" || !Number.isInteger(expiresIn) || expiresIn < 0 || expiresIn > 315_360_000))
  ) {
    throw new Error("Malformed OAuth token response.");
  }
  const scopeValue = body["scope"];
  if (scopeValue !== undefined && typeof scopeValue !== "string") throw new Error("Malformed OAuth token response.");
  const grantedScopes = typeof scopeValue === "string" ? scopeValue.split(/\s+/).filter((scope) => scope !== "") : [];
  const isGoogle = config.profileId === "google-workspace-oauth";
  if (isGoogle && requireGrantedScopes && grantedScopes.length === 0) {
    throw new Error("OAuth granted scopes were not returned.");
  }
  if (grantedScopes.length > 0) {
    const granted = new Set(grantedScopes.map(canonicalScope));
    const expected = new Set(config.scopes.map(canonicalScope));
    const missing = config.scopes.filter((scope) => scope !== "offline_access" && !granted.has(canonicalScope(scope)));
    if (missing.length > 0) throw new Error("OAuth granted scopes do not cover the provider operations.");
    if ([...granted].some((scope) => !expected.has(scope))) {
      throw new Error("OAuth granted scopes exceed the provider operations.");
    }
  }
  if (config.profileId === "box-user-oauth" && previousRefreshToken !== undefined &&
      (typeof refresh !== "string" || refresh === "")) {
    throw new Error("OAuth refresh-token rotation was not returned.");
  }
  const refreshToken = (typeof refresh === "string" && refresh !== "" ? refresh : previousRefreshToken) ?? null;
  return {
    accessToken: access,
    refreshToken,
    expiresAt: typeof expiresIn === "number" ? Date.now() + expiresIn * 1_000 : null,
    grantedScopes: Object.freeze(grantedScopes),
  };
}

async function tokenRequest(
  config: FilesSuitesOAuthConfig,
  input: OAuthClientInput,
  fields: Record<string, string>,
  previousRefreshToken?: string,
  requireGrantedScopes = false,
): Promise<FilesSuitesOAuthTokenSet> {
  requirePinnedOAuthEgress(input.network);
  const secrets = Object.values(fields).filter((value) => value !== "");
  const response = await requestOAuth(input.network, requireOAuthEndpoint(config.tokenUrl, "Token endpoint"), {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams(fields).toString(),
    secretValues: secrets,
  });
  if (response.status < 200 || response.status >= 300) {
    await response.body.cancel().catch(() => {});
    throw new Error("OAuth token request failed.");
  }
  let body: unknown;
  try {
    const bytes = await readBoundedBody(response, DEFAULT_EGRESS_LIMITS);
    body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new Error("Malformed OAuth token response.");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new Error("Malformed OAuth token response.");
  }
  return parseTokenResponse(body as Record<string, unknown>, config, previousRefreshToken, requireGrantedScopes);
}

export async function exchangeFilesSuitesOAuthCode(
  providerId: FilesSuitesProviderId,
  input: OAuthCodeInput,
): Promise<FilesSuitesOAuthTokenSet> {
  const profile = profileFor(providerId);
  if (profile.pkce !== "S256") throw new Error("OAuth PKCE is unsupported for this profile.");
  const config = filesSuitesOAuthConfig(providerId, input.clientId);
  if (input.code.trim() === "" || !/^[A-Za-z0-9._~-]{43,128}$/.test(input.codeVerifier)) {
    throw new Error("OAuth authorization code or PKCE verifier is invalid.");
  }
  const redirect = requireOAuthEndpoint(input.redirectUri, "OAuth redirect URI");
  const fields: Record<string, string> = {
    grant_type: "authorization_code",
    code: input.code,
    redirect_uri: redirect.toString(),
    ...clientFields(input, profile),
    code_verifier: input.codeVerifier,
  };
  if (config.profileId.startsWith("microsoft-graph-")) fields.scope = config.scopes.join(" ");
  const tokens = await tokenRequest(config, input, fields, undefined, true);
  if (tokens.refreshToken === null) throw new Error("OAuth offline refresh token was not returned.");
  return tokens;
}

export async function refreshFilesSuitesOAuthToken(
  providerId: FilesSuitesProviderId,
  input: OAuthRefreshInput,
): Promise<FilesSuitesOAuthTokenSet> {
  const profile = profileFor(providerId);
  const config = filesSuitesOAuthConfig(providerId, input.clientId);
  if (input.refreshToken.trim() === "") throw new Error("OAuth refresh token is missing.");
  const fields: Record<string, string> = {
    grant_type: "refresh_token",
    refresh_token: input.refreshToken,
    ...clientFields(input, profile),
  };
  if (config.profileId.startsWith("microsoft-graph-")) fields.scope = config.scopes.join(" ");
  return tokenRequest(config, input, fields, input.refreshToken);
}

export async function revokeFilesSuitesOAuthToken(
  providerId: FilesSuitesProviderId,
  input: OAuthRevokeInput,
): Promise<void> {
  const profile = profileFor(providerId);
  if (profile.revokeUrl === null || profile.revokeTransport === null) {
    throw new Error("OAuth remote revocation is unsupported for this profile.");
  }
  requirePinnedOAuthEgress(input.network);
  const client = clientFields(input, profile);
  const token = profile.revokeTransport === "google_form"
    ? (input.refreshToken ?? input.accessToken)
    : input.accessToken;
  if (token.trim() === "") throw new Error("OAuth token is missing.");
  let endpoint = requireOAuthEndpoint(profile.revokeUrl, "OAuth revoke endpoint");
  let headers: Record<string, string> = { accept: "application/json" };
  let body: string | undefined;
  let secrets: readonly string[] = [token, ...Object.values(client)];
  if (profile.revokeTransport === "dropbox_bearer") {
    headers.Authorization = `Bearer ${token}`;
  } else if (profile.revokeTransport === "box_form") {
    headers["content-type"] = "application/x-www-form-urlencoded";
    body = new URLSearchParams({ ...client, token }).toString();
  } else {
    endpoint = new URL(`${endpoint.toString()}?token=${encodeURIComponent(token)}`);
    headers["content-type"] = "application/x-www-form-urlencoded";
    body = "";
  }
  const response = await requestOAuth(input.network, endpoint, {
    method: "POST", headers, ...(body === undefined ? {} : { body }), secretValues: secrets,
  });
  await response.body.cancel().catch(() => {});
  if (response.status < 200 || response.status >= 300) throw new Error("OAuth token revocation failed.");
}

export interface FilesSuitesHandlerOptions {
  providerEgress?: ProviderEgress;
  redactor?: SecretRedactor;
  resolveAccessToken?: (ctx: McpCallContext) => Promise<string>;
}

function result(text: string, isError = false): McpToolCallResult {
  return { text, isError, content: [{ type: "text", text }] };
}

function validId(value: unknown): boolean {
  return typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._!@=,-]{0,511}$/.test(value);
}

function validDropboxPath(value: unknown): boolean {
  if (typeof value !== "string" || value.length < 2 || value.length > 512 || !value.startsWith("/") ||
      value.startsWith("//") || /[^\x20-\x7E]|[\\?#]/.test(value)) return false;
  return value.split("/").every((segment) => segment !== "." && segment !== "..");
}

function validRfc3339(value: unknown): boolean {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
    !Number.isNaN(Date.parse(value));
}

function columnNumber(value: string): number {
  let output = 0;
  for (const letter of value) output = output * 26 + letter.charCodeAt(0) - 64;
  return output;
}

function validA1Range(value: unknown): boolean {
  if (typeof value !== "string" || value.length > 140) return false;
  const match = /^(?:[A-Za-z0-9_ ]{1,100}!)?\$?([A-Z]{1,2})\$?(\d{1,3}):\$?([A-Z]{1,2})\$?(\d{1,3})$/.exec(value);
  if (match === null) return false;
  const firstColumn = columnNumber(match[1]!);
  const firstRow = Number(match[2]);
  const lastColumn = columnNumber(match[3]!);
  const lastRow = Number(match[4]);
  return firstRow >= 1 && lastRow >= firstRow && lastRow - firstRow < 100 &&
    firstColumn >= 1 && lastColumn >= firstColumn && lastColumn - firstColumn < 26 && lastColumn <= 26;
}

const ID_ARGUMENTS: Readonly<Record<FilesSuitesProviderId, readonly string[]>> = {
  dropbox: [],
  box: ["file_id"],
  onedrive: ["item_id"],
  sharepoint: ["site_id"],
  "google-docs": ["document_id"],
  "google-sheets": ["spreadsheet_id"],
  "google-calendar": ["event_id"],
  "google-tasks": ["tasklist_id", "task_id"],
  gmail: ["message_id"],
  outlook: ["message_id"],
};

function safeOperationArgs(
  providerId: FilesSuitesProviderId,
  operationId: string,
  args: Record<string, unknown>,
): boolean {
  for (const key of ID_ARGUMENTS[providerId]) {
    if (args[key] !== undefined && !validId(args[key])) return false;
  }
  if (providerId === "dropbox" && args.path !== undefined && !validDropboxPath(args.path)) return false;
  if (providerId === "dropbox" && args.cursor !== undefined &&
      (typeof args.cursor !== "string" || args.cursor.length > 4_096 || /[\x00-\x1f\x7f]/.test(args.cursor))) return false;
  if (providerId === "google-calendar" && args.time_min !== undefined && !validRfc3339(args.time_min)) return false;
  if (providerId === "google-sheets" && operationId === "get_values" && !validA1Range(args.range)) return false;
  return true;
}

function contentLimits(operation: ProviderOperation, args: Record<string, unknown>): EgressLimits {
  const totalMs = Math.min(operation.limits.timeoutMs, resolveTimeoutSeconds(args) * 1_000);
  return {
    ...DEFAULT_EGRESS_LIMITS,
    connectMs: totalMs,
    headersMs: totalMs,
    idleMs: totalMs,
    totalMs,
    maxRedirects: 0,
    responseBytes: operation.outputPolicy.maxBytes,
    decompressedBytes: Math.min(operation.limits.responseBytes * 4, 16_777_216),
  };
}

async function contentRead(
  providerId: "dropbox" | "google-docs",
  operation: ProviderOperation,
  args: Record<string, unknown>,
  token: string,
  egress: ProviderEgress,
  redactor: SecretRedactor,
): Promise<McpToolCallResult> {
  const url = providerId === "dropbox"
    ? new URL("https://content.dropboxapi.com/2/files/download")
    : new URL(`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(String(args.document_id))}/export?mimeType=text%2Fplain`);
  const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
  if (providerId === "dropbox") headers["Dropbox-API-Arg"] = JSON.stringify({ path: args.path });
  const limits = contentLimits(operation, args);
  let response;
  try {
    response = await egress.request({
      originKey: providerId,
      url,
      method: operation.request.method,
      headers,
      secretValues: [token],
      privileged: true,
      redirect: "deny",
      limits,
      signal: AbortSignal.timeout(limits.totalMs),
    });
    await assertBoundedHeadersOrCancel(response, limits);
    if (response.status < 200 || response.status >= 300) {
      await response.body.cancel().catch(() => {});
      return result(`Provider request failed (HTTP ${response.status}).`, true);
    }
    const actualMime = (response.headers.get("content-type") ?? "").split(";", 1)[0]!.trim().toLowerCase();
    const expectedMime = providerId === "dropbox" ? "application/octet-stream" : "text/plain";
    if (actualMime !== expectedMime) {
      await response.body.cancel().catch(() => {});
      return result("Provider returned an unsupported content type.", true);
    }
    const bytes = await readBoundedBody(response, limits);
    const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    const projected = redactor.text(text, [token]);
    if (Buffer.byteLength(projected, "utf8") > operation.outputPolicy.maxBytes) {
      return result("Provider result exceeded the tool output limit.", true);
    }
    return result(projected);
  } catch {
    return result("Provider content read failed or exceeded its safety limits.", true);
  }
}

/** One safe singleton facade; per-call handlers/tokens never cross users. */
export function createFilesSuitesHandler(
  providerId: FilesSuitesProviderId,
  options: FilesSuitesHandlerOptions = {},
): NativeMcpHandler {
  const descriptor = FILES_SUITES_DESCRIPTORS.find((entry) => entry.curatedId === providerId);
  const row = FILES_SUITES_CANDIDATES.find((entry) => entry.providerId === providerId);
  if (descriptor === undefined || row === undefined) throw new Error(`Unknown files/suites provider: ${providerId}`);
  const redactor = options.redactor ?? createSecretRedactor();

  return {
    async initialize() {
      return {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: providerId, version: "1.0.0" },
      };
    },
    async listTools() {
      return restToolDefs(descriptor).map((entry) => ({ ...entry, inputSchema: { ...entry.inputSchema } }));
    },
    async callTool(name, args, ctx) {
      const published = restToolDefs(descriptor).find((entry) => entry.name === name);
      const operation = row.operations.find((entry) => entry.name === name);
      if (published === undefined || operation === undefined) return result("Unknown provider operation.", true);
      let input: Record<string, unknown>;
      try {
        input = snapshotProviderArgs(args ?? {});
      } catch {
        return result("Invalid operation arguments.", true);
      }
      if (!validateProviderArgs(published.inputSchema ?? objectSchema(), input).ok ||
          !safeOperationArgs(providerId, name, input)) {
        return result("Invalid operation arguments.", true);
      }
      if (options.providerEgress === undefined || options.resolveAccessToken === undefined) {
        return result("Provider OAuth lifecycle is unavailable.", true);
      }
      let token: string;
      try {
        token = (await options.resolveAccessToken(ctx)).trim();
      } catch {
        return result("Provider OAuth lifecycle is unavailable.", true);
      }
      if (token === "") return result("Provider OAuth lifecycle is unavailable.", true);

      const delegate = createRestHandler(descriptor, {
        providerEgress: options.providerEgress,
        redactor,
        resolveConnectionConfig: async () => ({ oauth_access_token: token }),
      });
      if (name === "download_text") {
        const preflight = await delegate.callTool("get_metadata", { path: input.path }, ctx);
        if (preflight.isError) return result("Provider metadata preflight failed.", true);
        try {
          const metadata = JSON.parse(preflight.text) as Record<string, unknown>;
          const name = typeof metadata.name === "string" ? metadata.name.toLowerCase() : "";
          if (metadata[".tag"] !== "file" || typeof metadata.size !== "number" ||
              !Number.isInteger(metadata.size) || metadata.size < 0 || metadata.size > 8_192 ||
              !/\.(?:txt|md|csv|json)$/.test(name)) {
            return result("Provider content failed its metadata size/extension preflight.", true);
          }
        } catch {
          return result("Provider metadata preflight returned an invalid response.", true);
        }
        return contentRead("dropbox", operation, input, token, options.providerEgress, redactor);
      }
      if (name === "export_text") {
        return contentRead("google-docs", operation, input, token, options.providerEgress, redactor);
      }
      return delegate.callTool(name, input, ctx);
    },
  };
}
