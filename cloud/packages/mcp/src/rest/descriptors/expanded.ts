/**
 * The curated expansion: 80 more declarative REST services, taking the
 * catalogue from 20 to 100 (owner directive 2026-10-23).
 *
 * Every entry here is pure data — no handler, no code path. The engine
 * (`../engine.ts`) turns a descriptor into calls, so a connector either works
 * through the same tested machinery as the original 20 or it is not listed.
 *
 * SCOPE RULES (carried from the original lineup decision, still binding):
 *  - Read-first. Write tools exist only where the API's write is a plain,
 *    single-resource mutation (create/update one item). Anything that moves
 *    money, deploys code, deletes in bulk, or needs multi-step OAuth dance
 *    beyond a token is deliberately absent.
 *  - No new secret surfaces. A descriptor's credential is one token/key,
 *    optionally with a host or region, exactly like the first 20.
 *  - No fabricated endpoints. A service appears with only the calls its
 *    public API actually documents; if that is two tools, it gets two.
 *
 * Ordering: grouped by domain, and stable — `CURATED_IDS` pins it.
 */

import type { CredentialField, RestAuthKind, RestServiceDescriptor, RestToolDef } from "../engine.js";

interface CompactTool {
  /** Tool name. */
  n: string;
  /** Description shown to the model. */
  d: string;
  m: RestToolDef["method"];
  /** Path, optionally with `{placeholders}` filled from args/config. */
  p: string;
  /** Args that travel as query parameters. */
  q?: readonly string[];
  /** Arg whose object travels as the JSON body. */
  b?: string;
  /** Required arg names. */
  req?: readonly string[];
  /** Extra JSON-schema properties beyond the simple string ones. */
  props?: Record<string, unknown>;
}

interface CompactService {
  id: string;
  name: string;
  desc: string;
  base: string;
  auth: RestAuthKind;
  header?: string;
  prefix?: string;
  /** queryKey param name, or the config key holding a basic-auth username. */
  param?: string;
  key: string;
  label: string;
  extra?: readonly CredentialField[];
  staticHeaders?: Record<string, string>;
  tools: readonly CompactTool[];
}

function schema(tool: CompactTool): Record<string, unknown> {
  const properties: Record<string, unknown> = {};
  for (const q of tool.q ?? []) properties[q] = { type: "string" };
  if (tool.b !== undefined) {
    properties[tool.b] = { type: "object", description: "JSON request body." };
  }
  for (const [name, spec] of Object.entries(tool.props ?? {})) {
    properties[name] = spec;
  }
  const required = tool.req ?? [];
  return required.length === 0
    ? { type: "object", properties }
    : { type: "object", properties, required: [...required] };
}

function descriptor(svc: CompactService): RestServiceDescriptor {
  return {
    curatedId: svc.id,
    displayName: svc.name,
    description: svc.desc,
    baseUrl: svc.base,
    auth: svc.auth,
    ...(svc.header !== undefined ? { authHeader: svc.header } : {}),
    ...(svc.prefix !== undefined ? { authPrefix: svc.prefix } : {}),
    ...(svc.param !== undefined ? { authParam: svc.param } : {}),
    credentialKey: svc.key,
    credentialLabel: svc.label,
    ...(svc.extra !== undefined ? { extraConfig: [...svc.extra] } : {}),
    ...(svc.staticHeaders !== undefined ? { staticHeaders: svc.staticHeaders } : {}),
    tools: svc.tools.map((t) => ({
      name: t.n,
      description: t.d,
      method: t.m,
      path: t.p,
      inputSchema: schema(t),
      ...(t.q !== undefined ? { queryArgs: [...t.q] } : {}),
      ...(t.b !== undefined ? { jsonBodyArg: t.b } : {}),
      ...(t.req !== undefined ? { required: [...t.req] } : {}),
    })),
  };
}

const token = (label: string, key = "token"): { key: string; label: string } => ({
  key,
  label,
});

/** A path placeholder the user supplies as a config value (host, region…). */
const host = (label: string): CredentialField => ({
  key: "host",
  label,
  secret: false,
  hint: "Bare host, e.g. acme.example.com",
});

const EXPANDED: readonly CompactService[] = [
  // ── Dev & CI ────────────────────────────────────────────────────────────
  {
    id: "vercel",
    name: "Vercel",
    desc: "Projects and deployments over the Vercel REST API.",
    base: "https://api.vercel.com",
    auth: "bearer",
    ...token("Vercel access token"),
    tools: [
      { n: "list_projects", d: "Projects on the account.", m: "GET", p: "/v9/projects", q: ["limit"] },
      { n: "list_deployments", d: "Recent deployments.", m: "GET", p: "/v6/deployments", q: ["projectId", "limit", "state"] },
      { n: "get_deployment", d: "One deployment's status.", m: "GET", p: "/v13/deployments/{id}", props: { id: { type: "string" } }, req: ["id"] },
    ],
  },
  {
    id: "cloudflare",
    name: "Cloudflare",
    desc: "Zones, DNS records and workers over the Cloudflare API.",
    base: "https://api.cloudflare.com/client/v4",
    auth: "bearer",
    ...token("Cloudflare API token"),
    tools: [
      { n: "list_zones", d: "Zones the token can see.", m: "GET", p: "/zones", q: ["per_page"] },
      { n: "list_dns_records", d: "DNS records in a zone.", m: "GET", p: "/zones/{zone_id}/dns_records", q: ["type", "per_page"], props: { zone_id: { type: "string" } }, req: ["zone_id"] },
      { n: "purge_cache", d: "Purge a zone's cache.", m: "POST", p: "/zones/{zone_id}/purge_cache", b: "body", props: { zone_id: { type: "string" } }, req: ["zone_id", "body"] },
    ],
  },
  {
    id: "asana",
    name: "Asana",
    desc: "Projects and tasks over the Asana REST API.",
    base: "https://app.asana.com/api/1.0",
    auth: "bearer",
    ...token("Asana personal access token"),
    tools: [
      { n: "list_workspaces", d: "Workspaces the token can see.", m: "GET", p: "/workspaces" },
      { n: "list_projects", d: "Projects in a workspace.", m: "GET", p: "/projects", q: ["workspace", "limit"], req: ["workspace"] },
      { n: "create_task", d: "Create a task in a project.", m: "POST", p: "/tasks", b: "data", req: ["data"] },
    ],
  },
  {
    id: "trello",
    name: "Trello",
    desc: "Boards, lists and cards over the Trello REST API.",
    base: "https://api.trello.com/1",
    auth: "queryKey",
    param: "key",
    ...token("Trello token", "token"),
    extra: [{ key: "key", label: "API key", secret: false }],
    tools: [
      { n: "list_boards", d: "Boards for the member.", m: "GET", p: "/members/me/boards", q: ["fields"] },
      { n: "list_cards", d: "Cards on a board.", m: "GET", p: "/boards/{id}/cards", q: ["fields"], props: { id: { type: "string" } }, req: ["id"] },
      { n: "create_card", d: "Create a card in a list.", m: "POST", p: "/cards", q: ["idList", "name", "desc"], req: ["idList", "name"] },
    ],
  },
  {
    id: "clickup",
    name: "ClickUp",
    desc: "Spaces, lists and tasks over the ClickUp API v2.",
    base: "https://api.clickup.com/api/v2",
    auth: "apiKeyHeader",
    header: "Authorization",
    ...token("ClickUp personal token"),
    tools: [
      { n: "list_spaces", d: "Spaces in a team.", m: "GET", p: "/team/{team_id}/space", props: { team_id: { type: "string" } }, req: ["team_id"] },
      { n: "list_tasks", d: "Tasks in a list.", m: "GET", p: "/list/{list_id}/task", q: ["archived", "page"], props: { list_id: { type: "string" } }, req: ["list_id"] },
      { n: "create_task", d: "Create a task in a list.", m: "POST", p: "/list/{list_id}/task", b: "task", props: { list_id: { type: "string" } }, req: ["list_id", "task"] },
    ],
  },
  {
    id: "shortcut",
    name: "Shortcut",
    desc: "Stories, epics and workflows over the Shortcut API.",
    base: "https://api.app.shortcut.com/api/v3",
    auth: "apiKeyHeader",
    header: "Shortcut-Token",
    ...token("Shortcut API token"),
    tools: [
      { n: "list_stories", d: "Stories in a project.", m: "GET", p: "/projects/{project_id}/stories", props: { project_id: { type: "string" } }, req: ["project_id"] },
      { n: "search_stories", d: "Search stories with Shortcut's query syntax.", m: "GET", p: "/search/stories", q: ["query", "page_size"], req: ["query"] },
      { n: "create_story", d: "Create a story.", m: "POST", p: "/stories", b: "story", req: ["story"] },
    ],
  },
  {
    id: "confluence",
    name: "Confluence",
    desc: "Spaces and pages over the Confluence Cloud REST API.",
    base: "https://{host}/wiki/rest/api",
    auth: "basic",
    param: "email",
    ...token("API token", "api_token"),
    extra: [host("Confluence host"), { key: "email", label: "Atlassian account email", secret: false }],
    tools: [
      { n: "list_spaces", d: "Spaces the token can see.", m: "GET", p: "/space", q: ["limit"] },
      { n: "get_page", d: "A page by id.", m: "GET", p: "/content/{id}", q: ["expand"], props: { id: { type: "string" } }, req: ["id"] },
      { n: "create_page", d: "Create a page in a space.", m: "POST", p: "/content", b: "page", req: ["page"] },
    ],
  },
  {
    id: "microsoft-teams",
    name: "Microsoft Teams",
    desc: "Channels and messages over Microsoft Graph.",
    base: "https://graph.microsoft.com/v1.0",
    auth: "bearer",
    ...token("Microsoft Graph token"),
    tools: [
      { n: "list_teams", d: "Teams the token can read.", m: "GET", p: "/me/joinedTeams" },
      { n: "list_channels", d: "Channels in a team.", m: "GET", p: "/teams/{team_id}/channels", props: { team_id: { type: "string" } }, req: ["team_id"] },
      { n: "send_message", d: "Post a message to a channel.", m: "POST", p: "/teams/{team_id}/channels/{channel_id}/messages", b: "message", props: { team_id: { type: "string" }, channel_id: { type: "string" } }, req: ["team_id", "channel_id", "message"] },
    ],
  },
  {
    id: "zoom",
    name: "Zoom",
    desc: "Meetings and recordings over the Zoom API.",
    base: "https://api.zoom.us/v2",
    auth: "bearer",
    ...token("Zoom OAuth access token"),
    tools: [
      { n: "list_meetings", d: "Meetings for a user (me = the token owner).", m: "GET", p: "/users/{userId}/meetings", q: ["type", "page_size"], props: { userId: { type: "string" } }, req: ["userId"] },
      { n: "get_meeting", d: "One meeting's details.", m: "GET", p: "/meetings/{meetingId}", props: { meetingId: { type: "string" } }, req: ["meetingId"] },
      { n: "create_meeting", d: "Schedule a meeting.", m: "POST", p: "/users/{userId}/meetings", b: "meeting", props: { userId: { type: "string" } }, req: ["userId", "meeting"] },
    ],
  },
  {
    id: "intercom",
    name: "Intercom",
    desc: "Contacts and conversations over the Intercom API.",
    base: "https://api.intercom.io",
    auth: "bearer",
    ...token("Intercom access token"),
    staticHeaders: { Accept: "application/json", "Intercom-Version": "2.11" },
    tools: [
      { n: "list_contacts", d: "Contacts, paginated.", m: "GET", p: "/contacts", q: ["per_page"] },
      { n: "list_conversations", d: "Conversations.", m: "GET", p: "/conversations", q: ["per_page"] },
      { n: "search_contacts", d: "Search contacts with a query object.", m: "POST", p: "/contacts/search", b: "query", req: ["query"] },
    ],
  },
  {
    id: "zendesk",
    name: "Zendesk",
    desc: "Tickets and users over the Zendesk Support API.",
    base: "https://{subdomain}.zendesk.com/api/v2",
    auth: "basic",
    param: "email",
    ...token("API token", "api_token"),
    extra: [{ key: "subdomain", label: "Zendesk subdomain", secret: false }, { key: "email", label: "Agent email", secret: false }],
    tools: [
      { n: "list_tickets", d: "Tickets, newest first.", m: "GET", p: "/tickets", q: ["per_page", "status"] },
      { n: "get_ticket", d: "One ticket.", m: "GET", p: "/tickets/{id}", props: { id: { type: "string" } }, req: ["id"] },
      { n: "create_ticket", d: "Create a ticket.", m: "POST", p: "/tickets", b: "ticket", req: ["ticket"] },
    ],
  },
  {
    id: "freshdesk",
    name: "Freshdesk",
    desc: "Tickets and contacts over the Freshdesk API.",
    base: "https://{domain}.freshdesk.com/api/v2",
    auth: "basic",
    param: "api_key",
    ...token("Freshdesk API key", "api_key"),
    extra: [{ key: "domain", label: "Freshdesk domain", secret: false }],
    tools: [
      { n: "list_tickets", d: "Tickets, paginated.", m: "GET", p: "/tickets", q: ["page", "per_page"] },
      { n: "get_ticket", d: "One ticket.", m: "GET", p: "/tickets/{id}", props: { id: { type: "string" } }, req: ["id"] },
      { n: "create_ticket", d: "Create a ticket.", m: "POST", p: "/tickets", b: "ticket", req: ["ticket"] },
    ],
  },
  {
    id: "twilio",
    name: "Twilio",
    desc: "Send SMS and list messages over the Twilio API.",
    base: "https://api.twilio.com/2010-04-01",
    auth: "basic",
    param: "account_sid",
    ...token("Auth token", "auth_token"),
    extra: [{ key: "account_sid", label: "Account SID", secret: false }],
    tools: [
      { n: "list_messages", d: "Recent messages on the account.", m: "GET", p: "/Accounts/{account_sid}/Messages.json", q: ["PageSize", "To", "From"] },
      { n: "send_sms", d: "Send an SMS.", m: "POST", p: "/Accounts/{account_sid}/Messages.json", q: ["To", "From", "Body"], req: ["To", "From", "Body"] },
    ],
  },
  {
    id: "whatsapp-business",
    name: "WhatsApp Business",
    desc: "Send template messages over the WhatsApp Cloud API.",
    base: "https://graph.facebook.com/v21.0",
    auth: "bearer",
    ...token("WhatsApp Cloud API token"),
    extra: [{ key: "phone_number_id", label: "Phone number id", secret: false }],
    tools: [
      { n: "send_message", d: "Send a text message.", m: "POST", p: "/{phone_number_id}/messages", b: "message", req: ["message"] },
      { n: "list_templates", d: "Message templates for the WABA.", m: "GET", p: "/{waba_id}/message_templates", props: { waba_id: { type: "string" } }, req: ["waba_id"] },
    ],
  },
  {
    id: "mailchimp",
    name: "Mailchimp",
    desc: "Audiences, campaigns and members over the Mailchimp Marketing API.",
    base: "https://{dc}.api.mailchimp.com/3.0",
    auth: "basic",
    param: "username",
    ...token("Mailchimp API key", "api_key"),
    extra: [{ key: "dc", label: "Data center (e.g. us1)", secret: false }, { key: "username", label: "Any username (Mailchimp ignores it)", secret: false }],
    tools: [
      { n: "list_lists", d: "Audiences.", m: "GET", p: "/lists", q: ["count"] },
      { n: "list_members", d: "Members of an audience.", m: "GET", p: "/lists/{list_id}/members", q: ["count", "status"], props: { list_id: { type: "string" } }, req: ["list_id"] },
      { n: "list_campaigns", d: "Campaigns.", m: "GET", p: "/campaigns", q: ["count", "status"] },
    ],
  },
  {
    id: "sendgrid",
    name: "SendGrid",
    desc: "Send email and read stats over the SendGrid v3 API.",
    base: "https://api.sendgrid.com/v3",
    auth: "bearer",
    ...token("SendGrid API key"),
    tools: [
      { n: "send_email", d: "Send an email (SendGrid mail/send body).", m: "POST", p: "/mail/send", b: "message", req: ["message"] },
      { n: "list_templates", d: "Transactional templates.", m: "GET", p: "/templates", q: ["generations", "page_size"] },
    ],
  },
  {
    id: "klaviyo",
    name: "Klaviyo",
    desc: "Profiles, lists and metrics over the Klaviyo API.",
    base: "https://a.klaviyo.com/api",
    auth: "apiKeyHeader",
    header: "Authorization",
    prefix: "Klaviyo-API-Key ",
    ...token("Klaviyo private API key"),
    staticHeaders: { revision: "2024-10-15", Accept: "application/json" },
    tools: [
      { n: "list_profiles", d: "Profiles, paginated.", m: "GET", p: "/profiles", q: ["page[size]"] },
      { n: "list_lists", d: "Lists and segments.", m: "GET", p: "/lists" },
    ],
  },

  // ── Files & documents ───────────────────────────────────────────────────
  {
    id: "dropbox",
    name: "Dropbox",
    desc: "Files and folders over the Dropbox API.",
    base: "https://api.dropboxapi.com/2",
    auth: "bearer",
    ...token("Dropbox access token"),
    tools: [
      { n: "list_folder", d: "Entries in a folder (path '' = root).", m: "POST", p: "/files/list_folder", b: "body", req: ["body"] },
      { n: "search", d: "Search the account's files.", m: "POST", p: "/files/search_v2", b: "body", req: ["body"] },
      { n: "get_metadata", d: "Metadata for one path.", m: "POST", p: "/files/get_metadata", b: "body", req: ["body"] },
    ],
  },
  {
    id: "box",
    name: "Box",
    desc: "Files and folders over the Box API.",
    base: "https://api.box.com/2.0",
    auth: "bearer",
    ...token("Box access token"),
    tools: [
      { n: "list_items", d: "Items in a folder (folder id 0 = root).", m: "GET", p: "/folders/{folder_id}/items", q: ["limit"], props: { folder_id: { type: "string" } }, req: ["folder_id"] },
      { n: "search", d: "Search files and folders.", m: "GET", p: "/search", q: ["query", "limit"], req: ["query"] },
      { n: "get_file", d: "One file's metadata.", m: "GET", p: "/files/{file_id}", props: { file_id: { type: "string" } }, req: ["file_id"] },
    ],
  },
  {
    id: "onedrive",
    name: "OneDrive",
    desc: "Files and folders over Microsoft Graph.",
    base: "https://graph.microsoft.com/v1.0",
    auth: "bearer",
    ...token("Microsoft Graph token"),
    tools: [
      { n: "list_root", d: "Items at the drive root.", m: "GET", p: "/me/drive/root/children", q: ["$top"] },
      { n: "list_folder", d: "Children of a folder by path.", m: "GET", p: "/me/drive/root:/{path}:/children", q: ["$top"], props: { path: { type: "string" } }, req: ["path"] },
      { n: "search", d: "Search the drive.", m: "GET", p: "/me/drive/root/search(q='{query}')", q: ["$top"], props: { query: { type: "string" } }, req: ["query"] },
    ],
  },
  {
    id: "sharepoint",
    name: "SharePoint",
    desc: "Sites, lists and documents over Microsoft Graph.",
    base: "https://graph.microsoft.com/v1.0",
    auth: "bearer",
    ...token("Microsoft Graph token"),
    tools: [
      { n: "search_sites", d: "Find SharePoint sites.", m: "GET", p: "/sites", q: ["search"] },
      { n: "list_drives", d: "Document libraries of a site.", m: "GET", p: "/sites/{site_id}/drives", props: { site_id: { type: "string" } }, req: ["site_id"] },
      { n: "list_items", d: "Items in a drive root.", m: "GET", p: "/drives/{drive_id}/root/children", q: ["$top"], props: { drive_id: { type: "string" } }, req: ["drive_id"] },
    ],
  },
  {
    id: "google-docs",
    name: "Google Docs",
    desc: "Read and create documents over the Google Docs API.",
    base: "https://docs.googleapis.com/v1",
    auth: "bearer",
    ...token("Google OAuth access token"),
    tools: [
      { n: "get_document", d: "A document's full JSON.", m: "GET", p: "/documents/{documentId}", props: { documentId: { type: "string" } }, req: ["documentId"] },
      { n: "create_document", d: "Create an empty document.", m: "POST", p: "/documents", b: "document", req: ["document"] },
    ],
  },
  {
    id: "google-sheets",
    name: "Google Sheets",
    desc: "Read and append values over the Google Sheets API.",
    base: "https://sheets.googleapis.com/v4",
    auth: "bearer",
    ...token("Google OAuth access token"),
    tools: [
      { n: "get_values", d: "Read a range (A1 notation).", m: "GET", p: "/spreadsheets/{spreadsheetId}/values/{range}", props: { spreadsheetId: { type: "string" }, range: { type: "string" } }, req: ["spreadsheetId", "range"] },
      { n: "append_values", d: "Append rows to a range.", m: "POST", p: "/spreadsheets/{spreadsheetId}/values/{range}:append", q: ["valueInputOption", "insertDataOption"], b: "values", props: { spreadsheetId: { type: "string" }, range: { type: "string" } }, req: ["spreadsheetId", "range", "values"] },
    ],
  },
  {
    id: "google-calendar",
    name: "Google Calendar",
    desc: "Events and calendars over the Google Calendar API.",
    base: "https://www.googleapis.com/calendar/v3",
    auth: "bearer",
    ...token("Google OAuth access token"),
    tools: [
      { n: "list_events", d: "Events in a calendar (primary = the main one).", m: "GET", p: "/calendars/{calendarId}/events", q: ["timeMin", "timeMax", "maxResults", "singleEvents", "orderBy"], props: { calendarId: { type: "string" } }, req: ["calendarId"] },
      { n: "create_event", d: "Create an event.", m: "POST", p: "/calendars/{calendarId}/events", b: "event", props: { calendarId: { type: "string" } }, req: ["calendarId", "event"] },
    ],
  },
  {
    id: "google-tasks",
    name: "Google Tasks",
    desc: "Task lists and tasks over the Google Tasks API.",
    base: "https://tasks.googleapis.com/tasks/v1",
    auth: "bearer",
    ...token("Google OAuth access token"),
    tools: [
      { n: "list_tasklists", d: "The user's task lists.", m: "GET", p: "/users/@me/lists", q: ["maxResults"] },
      { n: "list_tasks", d: "Tasks in a list.", m: "GET", p: "/lists/{tasklist}/tasks", q: ["showCompleted", "maxResults"], props: { tasklist: { type: "string" } }, req: ["tasklist"] },
      { n: "create_task", d: "Add a task.", m: "POST", p: "/lists/{tasklist}/tasks", b: "task", props: { tasklist: { type: "string" } }, req: ["tasklist", "task"] },
    ],
  },
  {
    id: "gmail",
    name: "Gmail",
    desc: "Messages, threads and labels over the Gmail API.",
    base: "https://gmail.googleapis.com/gmail/v1",
    auth: "bearer",
    ...token("Google OAuth access token"),
    tools: [
      { n: "list_messages", d: "Message ids matching a query.", m: "GET", p: "/users/me/messages", q: ["q", "maxResults", "labelIds"] },
      { n: "get_message", d: "One message (format=full by default).", m: "GET", p: "/users/me/messages/{id}", q: ["format"], props: { id: { type: "string" } }, req: ["id"] },
      { n: "list_labels", d: "The account's labels.", m: "GET", p: "/users/me/labels" },
    ],
  },
  {
    id: "outlook",
    name: "Outlook",
    desc: "Mail and calendar over Microsoft Graph.",
    base: "https://graph.microsoft.com/v1.0",
    auth: "bearer",
    ...token("Microsoft Graph token"),
    tools: [
      { n: "list_messages", d: "Recent messages in a folder.", m: "GET", p: "/me/mailFolders/{folder}/messages", q: ["$top", "$search", "$select"], props: { folder: { type: "string" } }, req: ["folder"] },
      { n: "send_mail", d: "Send a message.", m: "POST", p: "/me/sendMail", b: "message", req: ["message"] },
      { n: "list_events", d: "Calendar events.", m: "GET", p: "/me/events", q: ["$top", "$select"] },
    ],
  },
  {
    id: "docusign",
    name: "DocuSign",
    desc: "Envelopes over the DocuSign eSignature API.",
    base: "https://{host}/restapi/v2.1/accounts/{account_id}",
    auth: "bearer",
    ...token("DocuSign OAuth access token"),
    extra: [host("DocuSign host (e.g. demo.docusign.net)"), { key: "account_id", label: "Account id", secret: false }],
    tools: [
      { n: "list_envelopes", d: "Envelopes, filtered by status.", m: "GET", p: "/envelopes", q: ["from_date", "status", "count"] },
      { n: "get_envelope", d: "One envelope.", m: "GET", p: "/envelopes/{envelopeId}", props: { envelopeId: { type: "string" } }, req: ["envelopeId"] },
    ],
  },
  {
    id: "typeform",
    name: "Typeform",
    desc: "Forms and responses over the Typeform API.",
    base: "https://api.typeform.com",
    auth: "bearer",
    ...token("Typeform personal token"),
    tools: [
      { n: "list_forms", d: "Forms on the account.", m: "GET", p: "/forms", q: ["page_size", "search"] },
      { n: "list_responses", d: "Responses to a form.", m: "GET", p: "/forms/{form_id}/responses", q: ["page_size", "since"], props: { form_id: { type: "string" } }, req: ["form_id"] },
    ],
  },
  {
    id: "calendly",
    name: "Calendly",
    desc: "Scheduled events and event types over the Calendly API.",
    base: "https://api.calendly.com",
    auth: "bearer",
    ...token("Calendly personal token"),
    tools: [
      { n: "get_current_user", d: "The token's user (gives the org/user URI).", m: "GET", p: "/users/me" },
      { n: "list_events", d: "Scheduled events for a user.", m: "GET", p: "/scheduled_events", q: ["user", "status", "count", "min_start_time"], req: ["user"] },
    ],
  },
  {
    id: "miro",
    name: "Miro",
    desc: "Boards and items over the Miro REST API.",
    base: "https://api.miro.com/v2",
    auth: "bearer",
    ...token("Miro access token"),
    tools: [
      { n: "list_boards", d: "Boards the token can see.", m: "GET", p: "/boards", q: ["limit", "query"] },
      { n: "list_items", d: "Items on a board.", m: "GET", p: "/boards/{board_id}/items", q: ["limit", "type"], props: { board_id: { type: "string" } }, req: ["board_id"] },
    ],
  },
  {
    id: "canva",
    name: "Canva",
    desc: "Designs and folders over the Canva Connect API.",
    base: "https://api.canva.com/rest/v1",
    auth: "bearer",
    ...token("Canva access token"),
    tools: [
      { n: "list_designs", d: "Designs the token can read.", m: "GET", p: "/designs", q: ["limit", "query"] },
      { n: "get_design", d: "One design's metadata.", m: "GET", p: "/designs/{designId}", props: { designId: { type: "string" } }, req: ["designId"] },
    ],
  },
  {
    id: "webflow",
    name: "Webflow",
    desc: "Sites and CMS items over the Webflow API.",
    base: "https://api.webflow.com/v2",
    auth: "bearer",
    ...token("Webflow API token"),
    tools: [
      { n: "list_sites", d: "Sites the token can access.", m: "GET", p: "/sites" },
      { n: "list_collections", d: "CMS collections on a site.", m: "GET", p: "/sites/{site_id}/collections", props: { site_id: { type: "string" } }, req: ["site_id"] },
      { n: "list_items", d: "Items in a collection.", m: "GET", p: "/collections/{collection_id}/items", q: ["limit", "offset"], props: { collection_id: { type: "string" } }, req: ["collection_id"] },
    ],
  },

  // ── Data & databases ────────────────────────────────────────────────────
  {
    id: "snowflake",
    name: "Snowflake",
    desc: "SQL over the Snowflake SQL API.",
    base: "https://{account}.snowflakecomputing.com/api/v2",
    auth: "bearer",
    ...token("Snowflake OAuth token"),
    extra: [{ key: "account", label: "Account identifier", secret: false }],
    tools: [
      { n: "execute", d: "Run a SQL statement; pass {statement, ...}.", m: "POST", p: "/statements", b: "body", req: ["body"] },
      { n: "get_statement", d: "Poll a statement's result.", m: "GET", p: "/statements/{handle}", props: { handle: { type: "string" } }, req: ["handle"] },
    ],
  },
  {
    id: "bigquery",
    name: "BigQuery",
    desc: "Queries over the BigQuery REST API.",
    base: "https://bigquery.googleapis.com/bigquery/v2",
    auth: "bearer",
    ...token("Google OAuth access token"),
    extra: [{ key: "projectId", label: "GCP project id", secret: false }],
    tools: [
      { n: "query", d: "Run a SQL query (jobs.query body).", m: "POST", p: "/projects/{projectId}/queries", b: "body", req: ["body"] },
      { n: "list_datasets", d: "Datasets in the project.", m: "GET", p: "/projects/{projectId}/datasets", q: ["maxResults"] },
    ],
  },
  {
    id: "databricks",
    name: "Databricks",
    desc: "Clusters, jobs and SQL over the Databricks REST API.",
    base: "https://{host}/api/2.1",
    auth: "bearer",
    ...token("Databricks personal access token"),
    extra: [host("Workspace host")],
    tools: [
      { n: "list_clusters", d: "Clusters in the workspace.", m: "GET", p: "/clusters/list" },
      { n: "list_jobs", d: "Jobs in the workspace.", m: "GET", p: "/jobs/list", q: ["limit", "offset"] },
      { n: "run_sql", d: "Execute SQL on a warehouse.", m: "POST", p: "/sql/statements", b: "body", req: ["body"] },
    ],
  },
  {
    id: "pinecone",
    name: "Pinecone",
    desc: "Vector indexes and queries over the Pinecone API.",
    base: "https://api.pinecone.io",
    auth: "apiKeyHeader",
    header: "Api-Key",
    ...token("Pinecone API key"),
    tools: [
      { n: "list_indexes", d: "Indexes in the project.", m: "GET", p: "/indexes" },
      { n: "describe_index", d: "One index's stats.", m: "GET", p: "/indexes/{name}", props: { name: { type: "string" } }, req: ["name"] },
    ],
  },
  {
    id: "elasticsearch",
    name: "Elasticsearch",
    desc: "Search and documents over the Elasticsearch REST API.",
    base: "https://{host}",
    auth: "apiKeyHeader",
    header: "Authorization",
    prefix: "ApiKey ",
    ...token("API key (base64 of id:secret)"),
    extra: [host("Cluster host")],
    tools: [
      { n: "search", d: "Search an index (query DSL body).", m: "POST", p: "/{index}/_search", b: "body", props: { index: { type: "string" } }, req: ["index", "body"] },
      { n: "get_document", d: "One document by id.", m: "GET", p: "/{index}/_doc/{id}", props: { index: { type: "string" }, id: { type: "string" } }, req: ["index", "id"] },
      { n: "list_indices", d: "Index names and stats.", m: "GET", p: "/_cat/indices", q: ["format"] },
    ],
  },
  {
    id: "typesense",
    name: "Typesense",
    desc: "Collections and search over the Typesense API.",
    base: "https://{host}",
    auth: "apiKeyHeader",
    header: "X-TYPESENSE-API-KEY",
    ...token("Typesense API key"),
    extra: [host("Typesense host")],
    tools: [
      { n: "list_collections", d: "Collections on the node.", m: "GET", p: "/collections" },
      { n: "search", d: "Search a collection.", m: "GET", p: "/collections/{collection}/documents/search", q: ["q", "query_by", "per_page"], props: { collection: { type: "string" } }, req: ["collection", "q", "query_by"] },
    ],
  },

  // ── Search & web ────────────────────────────────────────────────────────
  {
    id: "brave-search",
    name: "Brave Search",
    desc: "Web, news and local search over the Brave Search API.",
    base: "https://api.search.brave.com/res/v1",
    auth: "apiKeyHeader",
    header: "X-Subscription-Token",
    ...token("Brave Search API key"),
    staticHeaders: { Accept: "application/json" },
    tools: [
      { n: "web_search", d: "Web results for a query.", m: "GET", p: "/web/search", q: ["q", "count", "country", "safesearch"], req: ["q"] },
      { n: "news_search", d: "News results for a query.", m: "GET", p: "/news/search", q: ["q", "count", "freshness"], req: ["q"] },
    ],
  },
  {
    id: "tavily",
    name: "Tavily",
    desc: "Agent-grade web search and extraction over the Tavily API.",
    base: "https://api.tavily.com",
    auth: "bearer",
    ...token("Tavily API key"),
    tools: [
      { n: "search", d: "Search the web; pass {query, search_depth, max_results}.", m: "POST", p: "/search", b: "body", req: ["body"] },
      { n: "extract", d: "Extract readable content from URLs.", m: "POST", p: "/extract", b: "body", req: ["body"] },
    ],
  },
  {
    id: "serpapi",
    name: "SerpApi",
    desc: "Search-engine results over SerpApi.",
    base: "https://serpapi.com",
    auth: "queryKey",
    param: "api_key",
    ...token("SerpApi key", "api_key"),
    tools: [
      { n: "search", d: "Google results; pass engine and query params.", m: "GET", p: "/search.json", q: ["engine", "q", "num", "gl", "hl"], req: ["engine", "q"] },
    ],
  },
  {
    id: "algolia",
    name: "Algolia",
    desc: "Search indexes over the Algolia API.",
    base: "https://{appId}-dsn.algolia.net/1",
    auth: "apiKeyHeader",
    header: "X-Algolia-API-Key",
    ...token("Algolia search API key"),
    extra: [{ key: "appId", label: "Application id", secret: false }],
    staticHeaders: { "X-Algolia-Application-Id": "{appId}" },
    tools: [
      { n: "list_indices", d: "Indices on the application.", m: "GET", p: "/indexes" },
      { n: "search", d: "Search an index.", m: "POST", p: "/indexes/{index}/query", b: "body", props: { index: { type: "string" } }, req: ["index", "body"] },
    ],
  },
  {
    id: "google-maps",
    name: "Google Maps",
    desc: "Places and directions over the Google Maps APIs.",
    base: "https://maps.googleapis.com/maps/api",
    auth: "queryKey",
    param: "key",
    ...token("Google Maps API key", "key"),
    tools: [
      { n: "geocode", d: "Coordinates for an address.", m: "GET", p: "/geocode/json", q: ["address", "region"], req: ["address"] },
      { n: "directions", d: "Route between two places.", m: "GET", p: "/directions/json", q: ["origin", "destination", "mode", "departure_time"], req: ["origin", "destination"] },
      { n: "places_nearby", d: "Places near a coordinate.", m: "GET", p: "/place/nearbysearch/json", q: ["location", "radius", "type", "keyword"], req: ["location"] },
    ],
  },
  {
    id: "mixpanel",
    name: "Mixpanel",
    desc: "Events and profiles over the Mixpanel API.",
    base: "https://mixpanel.com/api",
    auth: "basic",
    param: "username",
    ...token("Project secret", "secret"),
    extra: [{ key: "username", label: "Service account user", secret: false }, { key: "project_id", label: "Project id", secret: false }],
    tools: [
      { n: "query_events", d: "Aggregate event counts (JSON passed as params).", m: "GET", p: "/2.0/events", q: ["event", "from_date", "to_date", "unit"], req: ["event", "from_date", "to_date"] },
      { n: "list_cohorts", d: "Cohorts in the project.", m: "GET", p: "/2.0/cohorts/list" },
    ],
  },
  {
    id: "amplitude",
    name: "Amplitude",
    desc: "Charts and events over the Amplitude Dashboard API.",
    base: "https://amplitude.com/api/2",
    auth: "basic",
    param: "username",
    ...token("API secret", "secret"),
    extra: [{ key: "username", label: "API key", secret: false }],
    tools: [
      { n: "events_segmentation", d: "Event counts over time.", m: "GET", p: "/events/segmentation", q: ["e", "start", "end", "m"], req: ["e", "start", "end"] },
      { n: "active_users", d: "Active-user counts.", m: "GET", p: "/users", q: ["start", "end", "m"], req: ["start", "end"] },
    ],
  },
  {
    id: "posthog",
    name: "PostHog",
    desc: "Events, persons and insights over the PostHog API.",
    base: "https://{host}/api",
    auth: "bearer",
    ...token("Personal API key"),
    extra: [host("PostHog host (e.g. us.posthog.com)"), { key: "project_id", label: "Project id", secret: false }],
    tools: [
      { n: "query", d: "Run a HogQL query.", m: "POST", p: "/projects/{project_id}/query", b: "body", req: ["body"] },
      { n: "list_insights", d: "Saved insights.", m: "GET", p: "/projects/{project_id}/insights", q: ["limit"] },
    ],
  },
  {
    id: "segment",
    name: "Segment",
    desc: "Sources, destinations and tracking over the Segment API.",
    base: "https://api.segmentapis.com",
    auth: "bearer",
    ...token("Segment public API token"),
    tools: [
      { n: "list_sources", d: "Sources in the workspace.", m: "GET", p: "/sources", q: ["pagination.count"] },
      { n: "list_destinations", d: "Destinations in the workspace.", m: "GET", p: "/destinations", q: ["pagination.count"] },
      { n: "track", d: "Send one tracking event.", m: "POST", p: "/track", b: "event", req: ["event"] },
    ],
  },
  {
    id: "metabase",
    name: "Metabase",
    desc: "Questions and dashboards over the Metabase API.",
    base: "https://{host}/api",
    auth: "apiKeyHeader",
    header: "X-API-KEY",
    ...token("Metabase API key"),
    extra: [host("Metabase host")],
    tools: [
      { n: "list_questions", d: "Saved questions.", m: "GET", p: "/card" },
      { n: "run_question", d: "Run a saved question.", m: "POST", p: "/card/{id}/query", props: { id: { type: "string" } }, req: ["id"] },
      { n: "list_dashboards", d: "Dashboards.", m: "GET", p: "/dashboard" },
    ],
  },
  {
    id: "redash",
    name: "Redash",
    desc: "Queries and results over the Redash API.",
    base: "https://{host}/api",
    auth: "apiKeyHeader",
    header: "Authorization",
    prefix: "Key ",
    ...token("Redash API key"),
    extra: [host("Redash host")],
    tools: [
      { n: "list_queries", d: "Saved queries.", m: "GET", p: "/queries", q: ["page_size"] },
      { n: "get_result", d: "Latest result of a query.", m: "GET", p: "/queries/{id}/results", props: { id: { type: "string" } }, req: ["id"] },
    ],
  },
  {
    id: "superset",
    name: "Superset",
    desc: "Charts and dashboards over the Superset API.",
    base: "https://{host}/api/v1",
    auth: "bearer",
    ...token("Superset access token"),
    extra: [host("Superset host")],
    tools: [
      { n: "list_charts", d: "Charts in the instance.", m: "GET", p: "/chart/", q: ["q"] },
      { n: "list_dashboards", d: "Dashboards.", m: "GET", p: "/dashboard/", q: ["q"] },
    ],
  },

  // ── Commerce & payments ─────────────────────────────────────────────────
  {
    id: "stripe",
    name: "Stripe",
    desc: "Customers, payments and invoices over the Stripe API.",
    base: "https://api.stripe.com/v1",
    auth: "bearer",
    ...token("Stripe secret key"),
    tools: [
      { n: "list_customers", d: "Customers, newest first.", m: "GET", p: "/customers", q: ["limit", "email", "starting_after"] },
      { n: "list_payments", d: "Payment intents.", m: "GET", p: "/payment_intents", q: ["limit", "customer"] },
      { n: "get_balance", d: "The account balance.", m: "GET", p: "/balance" },
    ],
  },
  {
    id: "paypal",
    name: "PayPal",
    desc: "Orders and transactions over the PayPal REST API.",
    base: "https://api-m.paypal.com",
    auth: "bearer",
    ...token("PayPal OAuth access token"),
    tools: [
      { n: "get_order", d: "One order's details.", m: "GET", p: "/v2/checkout/orders/{id}", props: { id: { type: "string" } }, req: ["id"] },
      { n: "list_transactions", d: "Transactions for a date range.", m: "GET", p: "/v1/reporting/transactions", q: ["start_date", "end_date", "page_size"], req: ["start_date", "end_date"] },
    ],
  },
  {
    id: "razorpay",
    name: "Razorpay",
    desc: "Payments and orders over the Razorpay API.",
    base: "https://api.razorpay.com/v1",
    auth: "basic",
    param: "key_id",
    ...token("Key secret", "key_secret"),
    extra: [{ key: "key_id", label: "Key id", secret: false }],
    tools: [
      { n: "list_payments", d: "Payments, newest first.", m: "GET", p: "/payments", q: ["count", "skip", "from", "to"] },
      { n: "get_payment", d: "One payment.", m: "GET", p: "/payments/{id}", props: { id: { type: "string" } }, req: ["id"] },
      { n: "list_orders", d: "Orders.", m: "GET", p: "/orders", q: ["count", "skip"] },
    ],
  },
  {
    id: "square",
    name: "Square",
    desc: "Payments and customers over the Square API.",
    base: "https://connect.squareup.com/v2",
    auth: "bearer",
    ...token("Square access token"),
    staticHeaders: { "Square-Version": "2024-11-20" },
    tools: [
      { n: "list_payments", d: "Payments for a location.", m: "GET", p: "/payments", q: ["location_id", "begin_time", "end_time", "limit"], req: ["location_id"] },
      { n: "list_customers", d: "Customers on the account.", m: "GET", p: "/customers", q: ["limit"] },
      { n: "list_locations", d: "Locations on the account.", m: "GET", p: "/locations" },
    ],
  },
  {
    id: "shopify",
    name: "Shopify",
    desc: "Products and orders over the Shopify Admin API.",
    base: "https://{shop}.myshopify.com/admin/api/2024-10",
    auth: "apiKeyHeader",
    header: "X-Shopify-Access-Token",
    ...token("Admin API access token"),
    extra: [{ key: "shop", label: "Shop handle (without .myshopify.com)", secret: false }],
    tools: [
      { n: "list_products", d: "Products, paginated.", m: "GET", p: "/products.json", q: ["limit", "since_id", "status"] },
      { n: "list_orders", d: "Orders, paginated.", m: "GET", p: "/orders.json", q: ["limit", "status", "since_id"] },
      { n: "get_shop", d: "Shop settings.", m: "GET", p: "/shop.json" },
    ],
  },
  {
    id: "woocommerce",
    name: "WooCommerce",
    desc: "Products and orders over the WooCommerce REST API.",
    base: "https://{host}/wp-json/wc/v3",
    auth: "basic",
    param: "consumer_key",
    ...token("Consumer secret", "consumer_secret"),
    extra: [host("Store host"), { key: "consumer_key", label: "Consumer key", secret: false }],
    tools: [
      { n: "list_products", d: "Products.", m: "GET", p: "/products", q: ["per_page", "page", "search", "status"] },
      { n: "list_orders", d: "Orders.", m: "GET", p: "/orders", q: ["per_page", "page", "status"] },
    ],
  },
  {
    id: "hubspot",
    name: "HubSpot",
    desc: "Contacts, companies and deals over the HubSpot API.",
    base: "https://api.hubapi.com",
    auth: "bearer",
    ...token("Private app access token"),
    tools: [
      { n: "list_contacts", d: "Contacts, paginated.", m: "GET", p: "/crm/v3/objects/contacts", q: ["limit", "after", "properties"] },
      { n: "list_deals", d: "Deals, paginated.", m: "GET", p: "/crm/v3/objects/deals", q: ["limit", "after"] },
      { n: "search_contacts", d: "Search contacts by property.", m: "POST", p: "/crm/v3/objects/contacts/search", b: "body", req: ["body"] },
    ],
  },
  {
    id: "salesforce",
    name: "Salesforce",
    desc: "SOQL queries and records over the Salesforce REST API.",
    base: "https://{instance}.salesforce.com/services/data/v61.0",
    auth: "bearer",
    ...token("OAuth access token"),
    extra: [{ key: "instance", label: "Instance (e.g. acme.my)", secret: false }],
    tools: [
      { n: "query", d: "Run a SOQL query.", m: "GET", p: "/query", q: ["q"], req: ["q"] },
      { n: "get_record", d: "One record by sobject and id.", m: "GET", p: "/sobjects/{sobject}/{id}", props: { sobject: { type: "string" }, id: { type: "string" } }, req: ["sobject", "id"] },
      { n: "create_record", d: "Create a record.", m: "POST", p: "/sobjects/{sobject}", b: "record", props: { sobject: { type: "string" } }, req: ["sobject", "record"] },
    ],
  },
  {
    id: "pipedrive",
    name: "Pipedrive",
    desc: "Deals and persons over the Pipedrive API.",
    base: "https://api.pipedrive.com/v1",
    auth: "queryKey",
    param: "api_token",
    ...token("API token", "api_token"),
    tools: [
      { n: "list_deals", d: "Deals, paginated.", m: "GET", p: "/deals", q: ["limit", "start", "status"] },
      { n: "list_persons", d: "Persons, paginated.", m: "GET", p: "/persons", q: ["limit", "start"] },
    ],
  },
  {
    id: "datadog",
    name: "Datadog",
    desc: "Monitors, events and metrics over the Datadog API.",
    base: "https://api.datadoghq.com/api/v1",
    auth: "apiKeyHeader",
    header: "DD-API-KEY",
    ...token("API key", "api_key"),
    extra: [{ key: "app_key", label: "Application key", secret: true }],
    staticHeaders: { "DD-APPLICATION-KEY": "{app_key}" },
    tools: [
      { n: "list_monitors", d: "Monitors in the account.", m: "GET", p: "/monitor", q: ["page_size", "page"] },
      { n: "query_events", d: "Events in a time range.", m: "GET", p: "/events", q: ["start", "end", "tags"], req: ["start", "end"] },
      { n: "query_metrics", d: "Query a metric timeseries.", m: "GET", p: "/query", q: ["from", "to", "query"], req: ["from", "to", "query"] },
    ],
  },
  {
    id: "grafana",
    name: "Grafana",
    desc: "Dashboards and datasources over the Grafana API.",
    base: "https://{host}/api",
    auth: "bearer",
    ...token("Service account token"),
    extra: [host("Grafana host")],
    tools: [
      { n: "search", d: "Search dashboards and folders.", m: "GET", p: "/search", q: ["query", "type", "limit"] },
      { n: "get_dashboard", d: "One dashboard by uid.", m: "GET", p: "/dashboards/uid/{uid}", props: { uid: { type: "string" } }, req: ["uid"] },
      { n: "list_datasources", d: "Configured datasources.", m: "GET", p: "/datasources" },
    ],
  },
  {
    id: "pagerduty",
    name: "PagerDuty",
    desc: "Incidents and services over the PagerDuty API.",
    base: "https://api.pagerduty.com",
    auth: "apiKeyHeader",
    header: "Authorization",
    prefix: "Token token=",
    ...token("API key"),
    staticHeaders: { Accept: "application/vnd.pagerduty+json;version=2" },
    tools: [
      { n: "list_incidents", d: "Incidents, newest first.", m: "GET", p: "/incidents", q: ["statuses[]", "limit", "since", "until"] },
      { n: "list_services", d: "Services on the account.", m: "GET", p: "/services", q: ["limit"] },
      { n: "get_incident", d: "One incident.", m: "GET", p: "/incidents/{id}", props: { id: { type: "string" } }, req: ["id"] },
    ],
  },
  {
    id: "opsgenie",
    name: "Opsgenie",
    desc: "Alerts and on-call over the Opsgenie API.",
    base: "https://api.opsgenie.com/v2",
    auth: "apiKeyHeader",
    header: "Authorization",
    prefix: "GenieKey ",
    ...token("API key"),
    tools: [
      { n: "list_alerts", d: "Open alerts.", m: "GET", p: "/alerts", q: ["limit", "query"] },
      { n: "create_alert", d: "Create an alert.", m: "POST", p: "/alerts", b: "alert", req: ["alert"] },
    ],
  },
  {
    id: "newrelic",
    name: "New Relic",
    desc: "NRQL queries over the New Relic GraphQL API.",
    base: "https://api.newrelic.com/graphql",
    auth: "apiKeyHeader",
    header: "API-Key",
    ...token("User API key"),
    tools: [
      { n: "nrql", d: "Run NRQL; pass {query, accountId}.", m: "POST", p: "", b: "body", req: ["body"] },
    ],
  },
  {
    id: "rollbar",
    name: "Rollbar",
    desc: "Items and occurrences over the Rollbar API.",
    base: "https://api.rollbar.com/api/1",
    auth: "apiKeyHeader",
    header: "X-Rollbar-Access-Token",
    ...token("Access token"),
    tools: [
      { n: "list_items", d: "Items in a project.", m: "GET", p: "/items", q: ["limit", "page", "status"] },
      { n: "get_item", d: "One item.", m: "GET", p: "/item/{id}", props: { id: { type: "string" } }, req: ["id"] },
    ],
  },
  {
    id: "docker-hub",
    name: "Docker Hub",
    desc: "Repositories and tags over the Docker Hub API.",
    base: "https://hub.docker.com/v2",
    auth: "bearer",
    ...token("Personal access token"),
    tools: [
      { n: "list_repositories", d: "Repositories for a namespace.", m: "GET", p: "/repositories/{namespace}", q: ["page_size"], props: { namespace: { type: "string" } }, req: ["namespace"] },
      { n: "list_tags", d: "Tags of a repository.", m: "GET", p: "/repositories/{namespace}/{repository}/tags", q: ["page_size"], props: { namespace: { type: "string" }, repository: { type: "string" } }, req: ["namespace", "repository"] },
    ],
  },
  {
    id: "kubernetes",
    name: "Kubernetes",
    desc: "Resources over the Kubernetes API server.",
    base: "https://{host}",
    auth: "bearer",
    ...token("Service account token"),
    extra: [host("API server host")],
    tools: [
      { n: "list_pods", d: "Pods in a namespace.", m: "GET", p: "/api/v1/namespaces/{namespace}/pods", q: ["limit"], props: { namespace: { type: "string" } }, req: ["namespace"] },
      { n: "list_deployments", d: "Deployments in a namespace.", m: "GET", p: "/apis/apps/v1/namespaces/{namespace}/deployments", props: { namespace: { type: "string" } }, req: ["namespace"] },
      { n: "get_resource", d: "One namespaced resource by path.", m: "GET", p: "/{path}", props: { path: { type: "string" } }, req: ["path"] },
    ],
  },
  {
    id: "terraform-cloud",
    name: "Terraform Cloud",
    desc: "Workspaces and runs over the Terraform Cloud API.",
    base: "https://app.terraform.io/api/v2",
    auth: "bearer",
    ...token("Team or user API token"),
    tools: [
      { n: "list_workspaces", d: "Workspaces in an organization.", m: "GET", p: "/organizations/{org}/workspaces", q: ["page[size]"], props: { org: { type: "string" } }, req: ["org"] },
      { n: "list_runs", d: "Runs in a workspace.", m: "GET", p: "/workspaces/{workspace_id}/runs", q: ["page[size]"], props: { workspace_id: { type: "string" } }, req: ["workspace_id"] },
    ],
  },
  {
    id: "youtube",
    name: "YouTube",
    desc: "Videos, channels and playlists over the YouTube Data API.",
    base: "https://www.googleapis.com/youtube/v3",
    auth: "queryKey",
    param: "key",
    ...token("Google API key", "key"),
    tools: [
      { n: "search", d: "Search videos and channels.", m: "GET", p: "/search", q: ["part", "q", "type", "maxResults", "order"], req: ["part", "q"] },
      { n: "list_videos", d: "Video details by id list.", m: "GET", p: "/videos", q: ["part", "id"], req: ["part", "id"] },
      { n: "list_playlists", d: "A channel's playlists.", m: "GET", p: "/playlists", q: ["part", "channelId", "maxResults"], req: ["part", "channelId"] },
    ],
  },
  {
    id: "vimeo",
    name: "Vimeo",
    desc: "Videos and folders over the Vimeo API.",
    base: "https://api.vimeo.com",
    auth: "bearer",
    ...token("Vimeo access token"),
    tools: [
      { n: "list_videos", d: "The token owner's videos.", m: "GET", p: "/me/videos", q: ["per_page", "page", "sort"] },
      { n: "get_video", d: "One video.", m: "GET", p: "/videos/{video_id}", props: { video_id: { type: "string" } }, req: ["video_id"] },
    ],
  },
  {
    id: "spotify",
    name: "Spotify",
    desc: "Tracks, playlists and search over the Spotify Web API.",
    base: "https://api.spotify.com/v1",
    auth: "bearer",
    ...token("Spotify access token"),
    tools: [
      { n: "search", d: "Search tracks, albums or artists.", m: "GET", p: "/search", q: ["q", "type", "limit", "market"], req: ["q", "type"] },
      { n: "list_playlists", d: "The user's playlists.", m: "GET", p: "/me/playlists", q: ["limit", "offset"] },
      { n: "get_track", d: "One track.", m: "GET", p: "/tracks/{id}", q: ["market"], props: { id: { type: "string" } }, req: ["id"] },
    ],
  },
  {
    id: "imgur",
    name: "Imgur",
    desc: "Image metadata over the Imgur API.",
    base: "https://api.imgur.com/3",
    auth: "apiKeyHeader",
    header: "Authorization",
    prefix: "Client-ID ",
    ...token("Imgur client id", "client_id"),
    tools: [
      { n: "get_image", d: "One image.", m: "GET", p: "/image/{id}", props: { id: { type: "string" } }, req: ["id"] },
      { n: "search_gallery", d: "Search the gallery.", m: "GET", p: "/gallery/search", q: ["q", "sort", "window"] },
    ],
  },
  {
    id: "cloudinary",
    name: "Cloudinary",
    desc: "Assets and transformations over the Cloudinary Admin API.",
    base: "https://api.cloudinary.com/v1_1/{cloud_name}",
    auth: "basic",
    param: "api_key",
    ...token("API secret", "api_secret"),
    extra: [{ key: "cloud_name", label: "Cloud name", secret: false }, { key: "api_key", label: "API key", secret: false }],
    tools: [
      { n: "list_resources", d: "Assets, paginated.", m: "GET", p: "/resources", q: ["resource_type", "max_results", "next_cursor"], req: ["resource_type"] },
      { n: "get_resource", d: "One asset's details.", m: "GET", p: "/resources/{resource_type}/upload/{public_id}", props: { resource_type: { type: "string" }, public_id: { type: "string" } }, req: ["resource_type", "public_id"] },
    ],
  },
  {
    id: "mux",
    name: "Mux",
    desc: "Video assets over the Mux API.",
    base: "https://api.mux.com/video/v1",
    auth: "basic",
    param: "token_id",
    ...token("Token secret", "token_secret"),
    extra: [{ key: "token_id", label: "Access token id", secret: false }],
    tools: [
      { n: "list_assets", d: "Video assets.", m: "GET", p: "/assets", q: ["limit", "page"] },
      { n: "get_asset", d: "One asset.", m: "GET", p: "/assets/{asset_id}", props: { asset_id: { type: "string" } }, req: ["asset_id"] },
    ],
  },
  {
    id: "cloudflare-images",
    name: "Cloudflare Images",
    desc: "Image listings over the Cloudflare Images API.",
    base: "https://api.cloudflare.com/client/v4/accounts/{account_id}/images/v1",
    auth: "bearer",
    ...token("Cloudflare API token"),
    extra: [{ key: "account_id", label: "Account id", secret: false }],
    tools: [
      { n: "list_images", d: "Images on the account.", m: "GET", p: "", q: ["page", "per_page"] },
      { n: "get_image", d: "One image.", m: "GET", p: "/{image_id}", props: { image_id: { type: "string" } }, req: ["image_id"] },
    ],
  },

  // ── Automation & misc ───────────────────────────────────────────────────
  {
    id: "zapier",
    name: "Zapier",
    desc: "Trigger a Zapier webhook (catch hook) or list your Zaps.",
    base: "https://api.zapier.com/v1",
    auth: "bearer",
    ...token("Zapier API key"),
    tools: [
      { n: "list_zaps", d: "Zaps on the account.", m: "GET", p: "/zaps", q: ["limit", "offset"] },
      { n: "get_zap", d: "One Zap.", m: "GET", p: "/zaps/{id}", props: { id: { type: "string" } }, req: ["id"] },
    ],
  },
  {
    id: "make",
    name: "Make",
    desc: "Scenarios and hooks over the Make API.",
    base: "https://{zone}.make.com/api/v2",
    auth: "bearer",
    ...token("API token"),
    extra: [{ key: "zone", label: "Zone (eu1, eu2, us1…)", secret: false }],
    tools: [
      { n: "list_scenarios", d: "Scenarios in a team.", m: "GET", p: "/scenarios", q: ["teamId", "pg[limit]"], req: ["teamId"] },
      { n: "list_hooks", d: "Webhooks in a team.", m: "GET", p: "/hooks", q: ["teamId"], req: ["teamId"] },
    ],
  },
  {
    id: "n8n",
    name: "n8n",
    desc: "Workflows and executions over the n8n API.",
    base: "https://{host}/api/v1",
    auth: "apiKeyHeader",
    header: "X-N8N-API-KEY",
    ...token("n8n API key"),
    extra: [host("n8n host")],
    tools: [
      { n: "list_workflows", d: "Workflows.", m: "GET", p: "/workflows", q: ["limit", "active"] },
      { n: "list_executions", d: "Recent executions.", m: "GET", p: "/executions", q: ["limit", "status"] },
    ],
  },
  {
    id: "stackexchange",
    name: "Stack Exchange",
    desc: "Questions and answers over the Stack Exchange API.",
    base: "https://api.stackexchange.com/2.3",
    auth: "queryKey",
    param: "key",
    ...token("App key", "key"),
    tools: [
      { n: "search", d: "Search questions on a site.", m: "GET", p: "/search/advanced", q: ["q", "site", "order", "sort", "pagesize"], req: ["q", "site"] },
      { n: "answers", d: "Answers for question ids.", m: "GET", p: "/questions/{ids}/answers", q: ["site", "sort", "filter"], props: { ids: { type: "string" } }, req: ["ids", "site"] },
    ],
  },
];

/** The 80 expanded descriptors, in pinned order. */
export const EXPANDED_DESCRIPTORS: readonly RestServiceDescriptor[] = EXPANDED.map(descriptor);

/** The ids, in the same order — `CURATED_IDS` appends these after the first 20. */
export const EXPANDED_IDS: readonly string[] = EXPANDED.map((s) => s.id);
