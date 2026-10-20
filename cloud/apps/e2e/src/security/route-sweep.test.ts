/**
 * P10 Task 9 — systematic 404-not-403 route sweep.
 *
 * The sweep is ROUTE-TABLE-DRIVEN, not hand-listed: the authenticated route
 * table is parsed from `app.printRoutes()` at execution time, so a route added
 * by a later phase is swept automatically. The safety net for that dynamism:
 *
 *   - every PARAMETERIZED route MUST have an ownership case in `OWNED_CASES`
 *     (or an explicit, justified entry in `EXEMPT_PARAM_ROUTES`) — a new
 *     `:param` route without one fails the suite;
 *   - every non-GET `/cloud/v1` route WITHOUT a `:param` MUST be in
 *     `NO_PARAM_OWNERSHIP_CASES` (it is exercised cross-owner) or in the
 *     exact-array-asserted `NO_PARAM_OWNERSHIP_EXEMPT` list with a reason — a
 *     new body-scoped ownership route without one fails the suite;
 *   - every case/exemption/public entry MUST still map to a registered route
 *     — a stale entry (route removed/renamed) fails the suite;
 *   - every route not on `PUBLIC_ROUTES` MUST answer 401 without a ticket —
 *     a route accidentally registered public fails the suite.
 *
 * COVERAGE BOUNDARY (accurate, not absolute): the automatic anti-shrink
 * heuristic covers parameterized routes and non-GET `/cloud/v1` routes.
 * A new GET route whose ownership is scoped by a QUERY parameter (the
 * `GET /cloud/v1/mcp/oauth/start?serverId=` pattern) is NOT auto-detected;
 * it must be added to `NO_PARAM_OWNERSHIP_CASES` explicitly. That gap is
 * documented here rather than claimed away.
 *
 * The composition is built WITH every registration-gating optional dep wired
 * (`account`, `shares`, `reports`) and with the behavior-gating deps the
 * owner-side positive controls need (`presigner`, `storage`, `worker`,
 * `byok`), so routes registered behind an optional dep are enumerated. If a
 * future dep cannot be wired, add it to `NOT_COVERED_OPTIONAL_DEPS` with a
 * reason (exact-array asserted).
 *
 * For each ownership-gated route the sweep asserts, as a foreign user B:
 *   - a resource owned by A answers 404 (never 403) with the shared
 *     `{error:{code:"not_found"}}` envelope (legacy root routes keep their
 *     Python `{detail:"share_not_found"}` envelope);
 *   - an unknown id answers the same 404 shape;
 *   - a malformed id answers 404 (never a 500 from a uuid-column bind).
 * A per-route positive control then proves the same route answers its OWNER
 * with 2xx — an always-404 route cannot pass the sweep.
 *
 * `TIER_GATE_ALLOWLIST` is the ONLY place a literal 403 is permitted on an
 * ownership route (the P4 cron tier gates). Ownership NEVER answers 403.
 * Separate, non-ownership 403s exist in the production composition: the
 * legacy `/account/*` lifecycle and the shares/reports account-admission
 * seam. Both are asserted to carry their expected account-admission codes,
 * never an ownership answer (Finding 3).
 */

import { randomBytes } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  attachments,
  browserCredentialsRepo,
  byokKeysRepo,
  createDb,
  createPrivateMemoryStore,
  customPresets,
  fileManifests,
  mcpServers,
  messages,
  migrate,
  newId,
  plugins,
  projectsRepo,
  runs,
  schedules,
  sessions,
  sharesRepo,
  users,
  workspaceObjects,
  type AttachmentRow,
  type BrowserCredentialRow,
  type ByokKeyRow,
  type Db,
  type McpServerRow,
  type PluginRow,
  type ProjectRow,
  type RunRow,
  type ScheduleRow,
  type SessionRow,
  type ShareReceiptRow,
  type WorkspaceObjectRow,
} from "@ovid/db";
import { browserCredentialRecordId } from "@ovid/shared";
import { byokRecordId } from "@ovid/escrow";
import type { EventLog, SystemBus } from "@ovid/events";
import type { OAuthFlow } from "@ovid/mcp";
import { createEnvelopeCrypto } from "@ovid/mcp";
import type { QueueServices } from "@ovid/queue";
import { buildGateway, createTestVerifier, type GatewayDeps } from "@ovid/gateway";
// The account lifecycle's AccountError class must be the SAME module instance
// the gateway routes `instanceof`-check. Vitest inlines this workspace package
// (the gateway resolves the same dist file), so a relative import keeps the
// class identity shared; a createRequire/Node import would not.
import { AccountError } from "../../../../packages/account/dist/index.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

if (!TEST_DATABASE_URL) {
  console.error(
    "[security] route-sweep requires TEST_DATABASE_URL — refusing to skip " +
      "green. Set it to a disposable Postgres and re-run.",
  );
}

// ---------------------------------------------------------------------------
// Route table
// ---------------------------------------------------------------------------

export interface RouteEntry {
  method: string;
  path: string;
}

/**
 * Parse Fastify's `printRoutes({commonPrefix:false})` tree into flat
 * `{method, path}` pairs. HEAD is dropped (Fastify derives it from GET; it is
 * not a distinct route contract). The tree encodes depth as 4-character
 * indent groups (`│   ` / `    `) before the `├──` / `└──` node marker.
 */
export function parsePrintRoutes(tree: string): RouteEntry[] {
  const routes: RouteEntry[] = [];
  const stack: string[] = [];
  for (const line of tree.split("\n")) {
    const match = /^((?:│   |    )*)(?:├── |└── )(.*)$/.exec(line);
    if (match === null) continue;
    const depth = match[1]!.length / 4;
    const rest = match[2]!;
    const node = /^(.*) \(([A-Z, ]+)\)$/.exec(rest);
    if (node === null) continue;
    const segment = node[1]!;
    stack[depth] = segment;
    stack.length = depth + 1;
    const path = stack.join("");
    for (const method of node[2]!.split(",").map((m) => m.trim())) {
      if (method === "" || method === "HEAD") continue;
      routes.push({ method, path });
    }
  }
  return routes;
}

/**
 * The ONLY ownership routes permitted to answer a literal 403. Each entry
 * carries its one-line justification. Today both entries are the P4 cron tier
 * gate (ownership is checked FIRST, so a foreign owner still gets 404).
 */
export const TIER_GATE_ALLOWLIST: Array<{
  method: string;
  path: string;
  expected: 403;
}> = [
  // P4 cron tier gate: creating a cron schedule as a Free user answers
  // 403 tier_required.
  { method: "POST", path: "/cloud/v1/schedules", expected: 403 },
  // Same gate when an owner changes an existing schedule's trigger to cron.
  { method: "PATCH", path: "/cloud/v1/schedules/:id", expected: 403 },
];

/** Unauthenticated-by-design routes (explicit; a new public route must be
 * added here or it fails the 401 sweep). Bidirectionally checked: a stale
 * entry (route removed/renamed) also fails the suite. */
const PUBLIC_ROUTES = new Set([
  "GET /cloud/v1/health",
  // Wave 4 (SE-014) Service status screen: registered in the public scope and
  // deliberately unauthenticated (coarse capability states only, no counts or
  // hostnames). The app renders it before sign-in.
  "GET /cloud/v1/health/status",
  "GET /cloud/v1/mcp/oauth/callback",
  "GET /oauth/callback",
  "GET /cloud/ws",
  // Legacy public share viewers / App Links (token IS the capability).
  "GET /s/:token",
  "GET /s/:token.json",
  "GET /s/:token/:invite",
  "GET /.well-known/assetlinks.json",
]);

/**
 * Parameterized routes that are deliberately NOT ownership-gated. Each needs
 * a justification, and the suite still pins their fail-closed behavior.
 */
const EXEMPT_PARAM_ROUTES: Record<string, string> = {
  "POST /shares/:token/fork":
    "recipient action on a public share — the token is the capability, so a " +
    "foreign user may fork it by design; unknown tokens fail closed (pinned).",
  "GET /s/:token": "public read-only viewer (no auth by design).",
  "GET /s/:token.json": "public JSON snapshot (no auth by design).",
  "GET /s/:token/:invite": "public invite landing (no auth by design).",
  // NOT public, but caller-scoped rather than resource-scoped: the id is a
  // client-chosen slug and the write is an UPSERT under the caller's uid.
  // A foreign slug therefore creates/updates the CALLER's own preset (2xx);
  // there is no owner lookup that could answer 404. The same id on DELETE
  // IS owner-scoped and is covered in OWNED_CASES.
  "PUT /cloud/v1/presets/:id":
    "caller-scoped upsert: the row is written under the caller's uid, so a " +
    "foreign slug creates the caller's own preset instead of reading A's; " +
    "DELETE on the same slug is owner-scoped and covered in OWNED_CASES.",
};

// ---------------------------------------------------------------------------
// Body/query-scoped ownership registry (Finding 1a)
// ---------------------------------------------------------------------------

/**
 * Ownership routes WITHOUT a `:param`: the resource id travels in the body or
 * the query string. These are exercised cross-owner below, and the staleness
 * guard requires every entry to map to a registered route.
 *
 * A new route matching the automatic heuristic (non-GET, `/cloud/v1`, no
 * `:param`, not public) must be added here or exempted below. A new GET
 * query-scoped ownership route is NOT auto-detected and must be added here
 * explicitly.
 */
export interface NoParamOwnershipCase {
  /** Build the request that targets user A's resource as user B. */
  request: (f: Fixtures) => { url: string; body?: unknown };
}

export const NO_PARAM_OWNERSHIP_CASES: Record<string, NoParamOwnershipCase> = {
  "GET /cloud/v1/mcp/oauth/start": {
    request: (f) => ({
      url: `/cloud/v1/mcp/oauth/start?serverId=${f.mcpA.id}`,
    }),
  },
  "POST /cloud/v1/mcp/oauth/disconnect": {
    request: (f) => ({
      url: "/cloud/v1/mcp/oauth/disconnect",
      body: { serverId: f.mcpA.id },
    }),
  },
  "POST /cloud/v1/import/sessions": {
    request: (f) => ({
      url: "/cloud/v1/import/sessions",
      body: {
        sessionId: f.sessionA.id,
        messages: [
          {
            clientMsgId: "sweep-import-1",
            role: "user",
            content: "hello",
            createdAt: new Date().toISOString(),
          },
        ],
      },
    }),
  },
  // Settings are caller-scoped by default, but a `byokDefault.keyId` names an
  // EXISTING escrowed key. A foreign key id must answer the same 404 as every
  // other owned-resource read (the caller's own settings are unaffected).
  "PATCH /cloud/v1/settings": {
    request: (f) => ({
      url: "/cloud/v1/settings",
      body: { byokDefault: { keyId: f.byokA.id, model: "openai/gpt-4o" } },
    }),
  },
};

/**
 * Non-parameterized non-GET `/cloud/v1` routes that are NOT ownership-scoped.
 * Exact-array asserted (like `TIER_GATE_ALLOWLIST`): adding an entry requires
 * editing the assertion in the same file, so the exemption is visible in
 * review. Every entry needs a real reason.
 */
export const NO_PARAM_OWNERSHIP_EXEMPT: Array<{
  method: string;
  path: string;
  reason: string;
}> = [
  {
    method: "POST",
    path: "/cloud/v1/auth/ticket",
    reason: "mints a WS ticket for the authenticated principal; no resource id.",
  },
  {
    method: "POST",
    path: "/cloud/v1/sessions",
    reason: "creates a session owned by the caller; no existing-resource lookup.",
  },
  {
    method: "PATCH",
    path: "/cloud/v1/preferences",
    reason: "writes the authenticated principal's own preferences row; no resource id.",
  },
  {
    method: "POST",
    path: "/cloud/v1/plugins/install",
    reason: "installs for the authenticated uid; tier-gated, no foreign resource id.",
  },
  {
    method: "POST",
    path: "/cloud/v1/system/responses",
    reason:
      "forwards to systemHub.respond(principal.uid, …); the pending-request id " +
      "is scoped to the caller's own channel.",
  },
  {
    method: "POST",
    path: "/cloud/v1/schedules",
    reason: "creates a schedule owned by the caller; no existing-resource lookup.",
  },
  {
    method: "PATCH",
    path: "/cloud/v1/preferences",
    reason:
      "writes users.preferences for request.principal.uid only; the body carries " +
      "no resource id (Wave 1a SE-005).",
  },
  {
    method: "POST",
    path: "/cloud/v1/devices",
    reason: "registers an FCM token for the authenticated uid.",
  },
  {
    method: "DELETE",
    path: "/cloud/v1/devices",
    reason:
      "deletes by token scoped to the authenticated uid; wrong owner is a " +
      "silent 204 no-op at the repo (pinned by the devices route).",
  },
  {
    method: "POST",
    path: "/cloud/v1/byok",
    reason: "creates a BYOK key owned by the caller; no existing-resource lookup.",
  },
  {
    method: "POST",
    path: "/cloud/v1/mcp/servers",
    reason: "creates an MCP server owned by the caller; no existing-resource lookup.",
  },
  {
    method: "POST",
    path: "/cloud/v1/projects",
    reason:
      "creates a project owned by the caller (UNIQUE per user); the body has " +
      "only a name, so there is no foreign resource id to scope — a " +
      "cross-owner request mints the CALLER's project, never reads A's.",
  },
  {
    method: "POST",
    path: "/cloud/v1/credentials",
    reason:
      "creates a sealed credential owned by the caller (UNIQUE label per " +
      "user); the body carries no id, so there is no foreign resource to " +
      "look up — a cross-owner request mints the CALLER's own row.",
  },
];

/**
 * Optional `GatewayDeps` fields that gate ROUTE REGISTRATION and are not
 * wired in this suite. Today the list is empty: `account`, `shares`, and
 * `reports` are all wired in `beforeAll`. A future registration-gating field
 * must be wired there or listed here with a reason; the exact-array
 * assertion makes the omission visible in review.
 */
export const NOT_COVERED_OPTIONAL_DEPS: Array<{
  dep: string;
  reason: string;
}> = [];

// ---------------------------------------------------------------------------
// Fixtures: one owned resource per family
// ---------------------------------------------------------------------------

interface Fixtures {
  sessionA: SessionRow;
  sessionB: SessionRow;
  /** Dedicated to the DELETE positive control (a successful soft-delete
   *  hides the session from every later read, so it must not be sessionA). */
  sessionDeleteA: SessionRow;
  runA: RunRow;
  scheduleA: ScheduleRow;
  /** Dedicated to the DELETE positive control (not mutated by reads). */
  scheduleDeleteA: ScheduleRow;
  /** Wave 5 run-now positive control: its own idle chat (sessionA is busy with runA). */
  scheduleRunNowA: ScheduleRow;
  /** Wave 1b history edits: idle chats with a prompt + answer each (a
   *  positive control truncates its own fixture, so they are not shared). */
  historyDeleteA: { session: SessionRow; promptId: string; answerId: string };
  historyRegenA: { session: SessionRow; promptId: string; answerId: string };
  historyBranchA: { session: SessionRow; promptId: string; answerId: string };
  pluginA: PluginRow;
  /** Dedicated to the DELETE positive control. */
  pluginDeleteA: PluginRow;
  mcpA: McpServerRow;
  /** Dedicated to the DELETE positive control. */
  mcpDeleteA: McpServerRow;
  /** Envelope-encrypted with the suite's master key, so the owner probe works. */
  byokA: ByokKeyRow;
  /** Dedicated to the DELETE positive control. */
  byokDeleteA: ByokKeyRow;
  artifactA: WorkspaceObjectRow;
  /** A's artifact under B's session — exercises artifact-level ownership. */
  foreignArtifact: WorkspaceObjectRow;
  /** A's attachment, sized to the storage stub's HEAD (5 bytes). */
  attachmentA: AttachmentRow;
  /** A's project (memory + detail + move target). */
  projectA: ProjectRow;
  /** Dedicated to the DELETE positive control. */
  projectDeleteA: ProjectRow;
  /** A's credential; DELETE has its own so the positive control is independent. */
  credentialA: BrowserCredentialRow;
  credentialDeleteA: BrowserCredentialRow;
  shareA: ShareReceiptRow;
  /** Dedicated to the DELETE positive control. */
  shareDeleteA: ShareReceiptRow;
}

interface Case {
  /** Path params materializing user A's resource. */
  params: (f: Fixtures) => Record<string, string>;
  /** Query string for the CROSS-OWNER request (e.g. memory's sessionId, the
   *  artifact vault's required ?source=). */
  query?: (f: Fixtures) => Record<string, string>;
  /** A valid body so only ownership (not validation) can reject. A function
   *  when it needs a fixture id (resolved per probe). */
  body?: unknown | ((f: Fixtures) => unknown);
  /** Owner-side body when the cross-owner body is intentionally invalid
   *  (a function when it needs a fixture id). */
  ownerBody?: unknown | ((f: Fixtures) => unknown);
  /** Owner-side query string (e.g. the workspace file path); a function when
   *  it needs a fixture id. */
  ownerQuery?: Record<string, string> | ((f: Fixtures) => Record<string, string>);
  /** Overrides for the unknown-id probe when a path param is NOT a uuid
   *  (memory file names, preset slugs) or when the ownership id rides the
   *  query string. Merged over the default random UUIDs. */
  unknownParams?: (f: Fixtures) => Record<string, string>;
  unknownQuery?: (f: Fixtures) => Record<string, string>;
  /** Overrides for the malformed-id probe. Used when the route validates the
   *  name/slug before the ownership id, so only the id itself is malformed. */
  malformedParams?: (f: Fixtures) => Record<string, string>;
  malformedQuery?: (f: Fixtures) => Record<string, string>;
  /** Owner positive-control expectation when the route is a documented,
   *  release-gated refusal rather than a 2xx (history mutations). */
  ownerStatus?: number;
  ownerCode?: string;
}

const shareBody = {
  session_id: "shared-session",
  request_id: "req-share-body",
  messages: [{ role: "user", content: "public text" }],
};

const OWNED_CASES: Record<string, Case> = {
  "GET /cloud/v1/sessions/:id": { params: (f) => ({ id: f.sessionA.id }) },
  "PATCH /cloud/v1/sessions/:id": {
    params: (f) => ({ id: f.sessionA.id }),
    body: { title: "foreign edit" },
  },
  // The soft-delete route (chat delete P0): a foreign DELETE must answer the
  // same 404 as every other session-scoped op. The positive control runs
  // against the dedicated sessionDeleteA (a 204 hides the row from every
  // later case, so it must not be sessionA).
  "DELETE /cloud/v1/sessions/:id": {
    params: (f) => ({ id: f.sessionDeleteA.id }),
  },
  "POST /cloud/v1/sessions/:id/messages": {
    params: (f) => ({ id: f.sessionA.id }),
    body: { content: "hello" },
  },
  "GET /cloud/v1/sessions/:id/messages": { params: (f) => ({ id: f.sessionA.id }) },
  // Wave 1b history edits (CT-004): ownership before any read of the message.
  "DELETE /cloud/v1/sessions/:id/messages/:messageId": {
    params: (f) => ({ id: f.historyDeleteA.session.id, messageId: f.historyDeleteA.answerId }),
    // Release-gated (CH-024/CT-004): the OWNER gets a documented 409 refusal,
    // never a silent no-op. Ownership still precedes it (foreign → 404).
    ownerStatus: 409,
    ownerCode: "history_actions_unavailable",
  },
  "POST /cloud/v1/sessions/:id/messages/:messageId/regenerate": {
    params: (f) => ({ id: f.historyRegenA.session.id, messageId: f.historyRegenA.answerId }),
    body: {},
    ownerStatus: 409,
    ownerCode: "history_actions_unavailable",
  },
  "POST /cloud/v1/sessions/:id/branch": {
    params: (f) => ({ id: f.historyBranchA.session.id }),
    body: {},
    ownerBody: (f: Fixtures) => ({ messageId: f.historyBranchA.answerId }),
    ownerStatus: 409,
    ownerCode: "history_actions_unavailable",
  },
  // The read-only event log the user follows a run through (the terminal was
  // removed; this route replaced it). Ownership is checked before any read.
  "GET /cloud/v1/sessions/:id/events": { params: (f) => ({ id: f.sessionA.id }) },
  "POST /cloud/v1/sessions/:id/attachments": {
    params: (f) => ({ id: f.sessionA.id }),
    body: { name: "a.txt", size: 1 },
  },
  "GET /cloud/v1/sessions/:id/artifacts": { params: (f) => ({ id: f.sessionA.id }) },
  "GET /cloud/v1/sessions/:id/artifacts/:artifactId/url": {
    params: (f) => ({ id: f.sessionA.id, artifactId: f.artifactA.id }),
  },
  "GET /cloud/v1/sessions/:id/workspace/tree": {
    params: (f) => ({ id: f.sessionA.id }),
  },
  "GET /cloud/v1/sessions/:id/workspace/file": {
    params: (f) => ({ id: f.sessionA.id }),
    ownerQuery: { path: "notes.txt" },
  },
  "PUT /cloud/v1/sessions/:id/workspace/file": {
    params: (f) => ({ id: f.sessionA.id }),
    body: {},
    ownerBody: { path: "notes.txt", contentUtf8: "hi" },
  },
  // Wave 2 Studio file management (ST-008): ownership before any worker call.
  "DELETE /cloud/v1/sessions/:id/workspace/file": {
    params: (f) => ({ id: f.sessionA.id }),
    ownerQuery: { path: "notes.txt" },
  },
  "POST /cloud/v1/sessions/:id/workspace/move": {
    params: (f) => ({ id: f.sessionA.id }),
    body: { from: "notes.txt", to: "moved.txt" },
  },
  "POST /cloud/v1/sessions/:id/workspace/mkdir": {
    params: (f) => ({ id: f.sessionA.id }),
    body: { path: "new-folder" },
  },
  "POST /cloud/v1/sessions/:id/workspace/hydrate": {
    params: (f) => ({ id: f.sessionA.id }),
  },
  "POST /cloud/v1/sessions/:id/workspace/hibernate": {
    params: (f) => ({ id: f.sessionA.id }),
  },
  "POST /cloud/v1/runs/:id/cancel": { params: (f) => ({ id: f.runA.id }) },
  "GET /cloud/v1/schedules/:id": { params: (f) => ({ id: f.scheduleA.id }) },
  "GET /cloud/v1/schedules/:id/runs": { params: (f) => ({ id: f.scheduleA.id }) },
  "POST /cloud/v1/schedules/:id/run": { params: (f) => ({ id: f.scheduleRunNowA.id }) },
  "PATCH /cloud/v1/schedules/:id": {
    params: (f) => ({ id: f.scheduleA.id }),
    body: { title: "foreign edit" },
  },
  "DELETE /cloud/v1/schedules/:id": {
    params: (f) => ({ id: f.scheduleDeleteA.id }),
  },
  "GET /cloud/v1/plugins/:id": { params: (f) => ({ id: f.pluginA.id }) },
  "DELETE /cloud/v1/plugins/:id": {
    params: (f) => ({ id: f.pluginDeleteA.id }),
  },
  "PATCH /cloud/v1/plugins/:id/config": {
    params: (f) => ({ id: f.pluginA.id }),
    body: { config: { token: "x" } },
  },
  "GET /cloud/v1/mcp/servers/:id": { params: (f) => ({ id: f.mcpA.id }) },
  "PATCH /cloud/v1/mcp/servers/:id": {
    params: (f) => ({ id: f.mcpA.id }),
    body: { enabled: false },
  },
  "DELETE /cloud/v1/mcp/servers/:id": {
    params: (f) => ({ id: f.mcpDeleteA.id }),
  },
  "DELETE /cloud/v1/byok/:id": { params: (f) => ({ id: f.byokDeleteA.id }) },
  "POST /cloud/v1/byok/:id/test": { params: (f) => ({ id: f.byokA.id }) },
  // Wave 4 settings/presets/memory + W1 projects + W6 credentials + W12 CDN.
  "GET /cloud/v1/memory/:name": {
    params: () => ({ name: "notes.md" }),
    query: (f) => ({ sessionId: f.sessionA.id }),
    ownerQuery: (f) => ({ sessionId: f.sessionA.id }),
    unknownParams: () => ({ name: "missing.md" }),
    unknownQuery: (f) => ({ sessionId: f.sessionA.id }),
    malformedParams: () => ({ name: "notes.md" }),
    malformedQuery: () => ({ sessionId: "not-a-uuid" }),
  },
  "PUT /cloud/v1/memory/:name": {
    params: () => ({ name: "put.md" }),
    query: (f) => ({ sessionId: f.sessionA.id }),
    body: { content: "foreign write" },
    ownerBody: { content: "owner write" },
    ownerQuery: (f) => ({ sessionId: f.sessionA.id }),
    // A new name is an upsert for the owner, so "unknown" means an unknown
    // OWNERSHIP id: the sessionId in the query string.
    unknownParams: () => ({ name: "missing.md" }),
    unknownQuery: () => ({ sessionId: newId() }),
    malformedParams: () => ({ name: "put.md" }),
    malformedQuery: () => ({ sessionId: "not-a-uuid" }),
  },
  "DELETE /cloud/v1/memory/:name": {
    params: () => ({ name: "delete.md" }),
    query: (f) => ({ sessionId: f.sessionA.id }),
    ownerQuery: (f) => ({ sessionId: f.sessionA.id }),
    unknownParams: () => ({ name: "missing.md" }),
    unknownQuery: (f) => ({ sessionId: f.sessionA.id }),
    malformedParams: () => ({ name: "delete.md" }),
    malformedQuery: () => ({ sessionId: "not-a-uuid" }),
  },
  "GET /cloud/v1/artifacts/:id/url": {
    params: (f) => ({ id: f.artifactA.id }),
    query: () => ({ source: "generated" }),
    ownerQuery: { source: "generated" },
    unknownQuery: () => ({ source: "generated" }),
  },
  "GET /cloud/v1/artifacts/:id/cdn-url": {
    params: (f) => ({ id: f.artifactA.id }),
    query: () => ({ source: "generated" }),
    ownerQuery: { source: "generated" },
    unknownQuery: () => ({ source: "generated" }),
  },
  "POST /cloud/v1/sessions/:id/project": {
    params: (f) => ({ id: f.sessionA.id }),
    body: (f: Fixtures) => ({ projectId: f.projectA.id }),
    ownerBody: (f: Fixtures) => ({ projectId: f.projectA.id }),
  },
  "PUT /cloud/v1/sessions/:id/preset": {
    params: (f) => ({ id: f.sessionA.id }),
    body: { presetId: "standard" },
  },
  "GET /cloud/v1/sessions/:id/attachments/:attachmentId/cdn-url": {
    params: (f) => ({ id: f.sessionA.id, attachmentId: f.attachmentA.id }),
  },
  "GET /cloud/v1/projects/:id": { params: (f) => ({ id: f.projectA.id }) },
  "PATCH /cloud/v1/projects/:id": {
    params: (f) => ({ id: f.projectA.id }),
    body: { name: "foreign rename" },
    ownerBody: { name: "sweep project renamed" },
  },
  "DELETE /cloud/v1/projects/:id": { params: (f) => ({ id: f.projectDeleteA.id }) },
  "GET /cloud/v1/projects/:id/memory": { params: (f) => ({ id: f.projectA.id }) },
  "GET /cloud/v1/projects/:id/memory/:name": {
    params: (f) => ({ id: f.projectA.id, name: "notes.md" }),
    unknownParams: (f) => ({ id: newId(), name: "missing.md" }),
    malformedParams: () => ({ id: "not-a-uuid", name: "notes.md" }),
  },
  "PUT /cloud/v1/projects/:id/memory/:name": {
    params: (f) => ({ id: f.projectA.id, name: "put.md" }),
    body: { content: "foreign write" },
    ownerBody: { content: "owner write" },
    unknownParams: (f) => ({ id: newId(), name: "missing.md" }),
    malformedParams: () => ({ id: "not-a-uuid", name: "notes.md" }),
  },
  "DELETE /cloud/v1/projects/:id/memory/:name": {
    params: (f) => ({ id: f.projectA.id, name: "delete.md" }),
    unknownParams: (f) => ({ id: newId(), name: "missing.md" }),
    malformedParams: () => ({ id: "not-a-uuid", name: "notes.md" }),
  },
  "DELETE /cloud/v1/presets/:id": {
    params: () => ({ id: "custom-sweep-delete" }),
  },
  "PATCH /cloud/v1/credentials/:id": {
    params: (f) => ({ id: f.credentialA.id }),
    body: { label: "foreign rename" },
    ownerBody: { label: "sweep credential renamed" },
  },
  "DELETE /cloud/v1/credentials/:id": {
    params: (f) => ({ id: f.credentialDeleteA.id }),
  },
  // Legacy root routes (Python envelope): owner-scoped update/revoke.
  "PUT /shares/:token": {
    params: (f) => ({ token: f.shareA.token }),
    body: shareBody,
  },
  "DELETE /shares/:token": { params: (f) => ({ token: f.shareDeleteA.token }) },
};

/**
 * Bodies that let the UNAUTHENTICATED sweep reach the auth check. Two legacy
 * account routes validate their body BEFORE authentication (FastAPI param
 * resolution order), so an empty body would answer 400/422 instead of 401.
 * These are still auth-swept; only the body is supplied.
 */
const UNAUTH_SWEEP_BODIES: Record<string, unknown> = {
  "POST /account/deletion": { request_id: "sweep-unauth-request" },
  "POST /account/deletion/cancel": { consent: true },
};

function fillParams(pattern: string, values: Record<string, string>): string {
  return pattern.replace(/:([A-Za-z0-9_]+)/g, (_whole, name: string) => {
    const value = values[name];
    if (value === undefined) throw new Error(`no value for :${name} in ${pattern}`);
    return value;
  });
}

function unknownValues(pattern: string): Record<string, string> {
  const values: Record<string, string> = {};
  for (const match of pattern.matchAll(/:([A-Za-z0-9_]+)/g)) {
    const name = match[1]!;
    // 43-char base64url is the legacy share token/invite shape; UUIDs for
    // every cloud path param (all of them are uuid-typed ids).
    values[name] =
      name === "token" || name === "invite"
        ? randomBytes(32).toString("base64url")
        : newId();
  }
  return values;
}

function malformedValues(pattern: string): Record<string, string> {
  const values: Record<string, string> = {};
  for (const match of pattern.matchAll(/:([A-Za-z0-9_]+)/g)) {
    const name = match[1]!;
    values[name] =
      name === "token" || name === "invite" ? "not-a-valid-token" : "not-a-uuid";
  }
  return values;
}

function bodyFor(
  method: string,
  explicit?: unknown,
): Record<string, unknown> | undefined {
  if (explicit !== undefined) return explicit as Record<string, unknown>;
  if (method === "POST" || method === "PUT" || method === "PATCH") return {};
  return undefined;
}

/** Resolve a fixture-dependent case body (see `Case.body`). */
function resolveBody(
  body: unknown | ((f: Fixtures) => unknown) | undefined,
  f: Fixtures,
): unknown {
  return typeof body === "function" ? (body as (f: Fixtures) => unknown)(f) : body;
}

/** Resolve a fixture-dependent query map (see `Case.ownerQuery`). */
function resolveQuery(
  query: Record<string, string> | ((f: Fixtures) => Record<string, string>) | undefined,
  f: Fixtures,
): Record<string, string> | undefined {
  return typeof query === "function"
    ? (query as (f: Fixtures) => Record<string, string>)(f)
    : query;
}

/** Append a query map to a URL (no-op when undefined). */
function withQuery(url: string, query: Record<string, string> | undefined): string {
  if (query === undefined) return url;
  return `${url}?${new URLSearchParams(query).toString()}`;
}

function isCloudPath(path: string): boolean {
  return path.startsWith("/cloud/v1/");
}

function authHeaders(uid: string): Record<string, string> {
  return { authorization: `Bearer test:${uid}` };
}

function splitRouteKey(key: string): { method: string; path: string } {
  const space = key.indexOf(" ");
  return { method: key.slice(0, space), path: key.slice(space + 1) };
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

// Finding 7: a missing TEST_DATABASE_URL FAILS the suite (loud, never a
// silent green). CI always provides it; a local `pnpm -r test` without the
// dev services is meant to stop here and say why.
describe("route sweep — 404 not 403", () => {
  let db: Db;
  let app: ReturnType<typeof buildGateway>;
  let routes: RouteEntry[];
  let fixtures: Fixtures;
  let userA: string;
  let userB: string;
  let baseDeps: GatewayDeps;

  beforeAll(async () => {
    if (!TEST_DATABASE_URL) {
      throw new Error(
        "[security] route-sweep: TEST_DATABASE_URL is unset — refusing to " +
          "skip green. Point it at a disposable Postgres and re-run.",
      );
    }
    await migrate(TEST_DATABASE_URL);
    db = createDb(TEST_DATABASE_URL);

    const stamp = `${Date.now().toString(36)}-${randomBytes(4).toString("hex")}`;
    userA = `sweep-a-${stamp}`;
    userB = `sweep-b-${stamp}`;
    await users.ensure(db, userA, null);
    await users.ensure(db, userB, null);

    const sessionA = await sessions.create(db, userA, "A session");
    const sessionB = await sessions.create(db, userB, "B session");
    const sessionDeleteA = await sessions.create(db, userA, "sweep delete fixture");
    const historyFixture = async (title: string) => {
      const session = await sessions.create(db, userA, title);
      const p = await messages.append(db, { sessionId: session.id, role: "user", content: "q" });
      const a = await messages.append(db, { sessionId: session.id, role: "assistant", content: "a" });
      return { session, promptId: p.id, answerId: a.id };
    };
    const historyDeleteA = await historyFixture("sweep history delete");
    const historyRegenA = await historyFixture("sweep history regenerate");
    const historyBranchA = await historyFixture("sweep history branch");
    // Warm manifest so the workspace positive controls take the live path
    // (worker stubs below) instead of the never-registered seams.
    await fileManifests.upsertWarm(db, {
      sessionId: sessionA.id,
      userId: userA,
      workspaceBytes: 0,
    });
    const prompt = await messages.append(db, {
      sessionId: sessionA.id,
      role: "user",
      content: "prompt",
    });
    const runA = await runs.create(db, {
      sessionId: sessionA.id,
      promptMessageId: prompt.id,
    });
    const scheduleA = await schedules.create(db, {
      userId: userA,
      sessionId: sessionA.id,
      title: "A schedule",
      description: "sweep fixture",
      trigger: { kind: "every", seconds: 300 },
      autonomy: "safe",
      maxRetries: 0,
      nextRunAt: new Date(Date.now() + 300_000),
    });
    const scheduleDeleteA = await schedules.create(db, {
      userId: userA,
      sessionId: sessionA.id,
      title: "A deletable schedule",
      description: "sweep delete fixture",
      trigger: { kind: "every", seconds: 300 },
      autonomy: "safe",
      maxRetries: 0,
      nextRunAt: new Date(Date.now() + 300_000),
    });
    const runNowSessionA = await sessions.create(db, userA, "sweep run-now fixture");
    const scheduleRunNowA = await schedules.create(db, {
      userId: userA,
      sessionId: runNowSessionA.id,
      title: "A run-now schedule",
      description: "sweep run-now fixture",
      trigger: { kind: "every", seconds: 300 },
      autonomy: "safe",
      maxRetries: 0,
      nextRunAt: new Date(Date.now() + 300_000),
    });
    const pluginA = await plugins.upsert(db, {
      userId: userA,
      pluginId: "@ovid/sweep-plugin",
      version: "1.0.0",
      source: { kind: "npm", label: "@ovid/sweep-plugin" },
      status: "installed",
    });
    const pluginDeleteA = await plugins.upsert(db, {
      userId: userA,
      pluginId: "@ovid/sweep-delete-plugin",
      version: "1.0.0",
      source: { kind: "npm", label: "@ovid/sweep-delete-plugin" },
      status: "installed",
    });
    const mcpA = await mcpServers.create(db, {
      userId: userA,
      name: "sweep-server",
      transport: "http",
      config: { url: "https://mcp.example.test" },
    });
    const mcpDeleteA = await mcpServers.create(db, {
      userId: userA,
      name: "sweep-delete-server",
      transport: "http",
      config: { url: "https://mcp-delete.example.test" },
    });
    const crypto = createEnvelopeCrypto("11".repeat(32));
    // byokA must be decryptable for the owner's /test positive control: bind
    // the envelope AAD to the row id, exactly as POST /byok does.
    const byokAId = newId();
    const envelope = crypto.encrypt("sk-sweep", byokRecordId(byokAId));
    const byokAInsert = {
      id: byokAId,
      userId: userA,
      providerId: "openai",
      endpoint: "https://api.openai.com/v1",
      wrappedDek: envelope.wrappedDek,
      iv: envelope.iv,
      ciphertext: envelope.ciphertext,
      tag: envelope.tag,
    };
    // The repo's declared insert type has no `id`; the route passes one the
    // same way (the generated id is overridden by the spread).
    const byokA = await byokKeysRepo.create(db, byokAInsert);
    const byokDeleteA = await byokKeysRepo.create(db, {
      userId: userA,
      providerId: "openai",
      endpoint: "https://api.openai.com/v1",
      wrappedDek: "wrapped",
      iv: "iv",
      ciphertext: "ciphertext",
      tag: "tag",
    });
    const artifactA = await workspaceObjects.registerArtifact(db, {
      id: newId(),
      userId: userA,
      sessionId: sessionA.id,
      r2Key: `artifacts/${sessionA.id}/${newId()}`,
      bytes: 5,
      sha256: "a".repeat(64),
      contentType: "text/plain",
      meta: { name: "artifact.txt" },
    });
    const foreignArtifact = await workspaceObjects.registerArtifact(db, {
      id: newId(),
      userId: userA, // owned by A …
      sessionId: sessionB.id, // … under B's session
      r2Key: `artifacts/${sessionB.id}/${newId()}`,
      bytes: 5,
      sha256: "b".repeat(64),
      contentType: "text/plain",
      meta: { name: "foreign.txt" },
    });
    // W12 CDN positive control: the storage stub's HEAD reports exactly 5
    // bytes, so this attachment (and artifactA) pass the availability proof.
    const attachmentA = await attachments.create(db, {
      id: newId(),
      sessionId: sessionA.id,
      userId: userA,
      name: "sweep.txt",
      size: 5,
      r2Key: `users/${userA}/sessions/${sessionA.id}/uploads/${newId()}`,
    });
    // W1 projects: one live project (detail/memory/move) and one dedicated to
    // the DELETE positive control (a delete detaches chats and drops memory).
    const projectA = await projectsRepo.create(db, userA, "sweep project");
    if (projectA === null) throw new Error("sweep fixture: projectA was not created");
    const projectDeleteA = await projectsRepo.create(db, userA, "sweep delete project");
    if (projectDeleteA === null) {
      throw new Error("sweep fixture: projectDeleteA was not created");
    }
    // Memory fixtures: the store re-checks session/project ownership inside
    // its transaction, which is exactly what the sweep exercises.
    const memoryStore = createPrivateMemoryStore(db);
    await memoryStore.save(
      userA,
      { sessionId: sessionA.id, shared: false },
      "notes.md",
      "session notes",
    );
    await memoryStore.save(
      userA,
      { sessionId: sessionA.id, shared: false },
      "delete.md",
      "session delete fixture",
    );
    await memoryStore.save(
      userA,
      { projectId: projectA.id, maxFiles: 80 },
      "notes.md",
      "project notes",
    );
    await memoryStore.save(
      userA,
      { projectId: projectA.id, maxFiles: 80 },
      "delete.md",
      "project delete fixture",
    );
    // Wave 4 custom preset dedicated to the DELETE positive control.
    await customPresets.upsert(db, userA, {
      id: "custom-sweep-delete",
      label: "Sweep delete",
      description: "sweep fixture",
      deniedTools: [],
      model: null,
      temperature: null,
    });
    // Wave 6 credentials: sealed envelopes with the suite's master key. The
    // routes never decrypt for metadata, but the AAD stays realistic.
    const credentialAId = newId();
    const credentialA = await browserCredentialsRepo.create(db, {
      id: credentialAId,
      userId: userA,
      label: "sweep credential",
      site: "https://example.test",
      username: "sweep",
      secretKind: "password",
      secretSealed: crypto.encrypt("sweep-secret", browserCredentialRecordId(credentialAId)),
    });
    const credentialDeleteAId = newId();
    const credentialDeleteA = await browserCredentialsRepo.create(db, {
      id: credentialDeleteAId,
      userId: userA,
      label: "sweep delete credential",
      site: "https://example.test",
      username: "sweep",
      secretKind: "password",
      secretSealed: crypto.encrypt(
        "sweep-secret",
        browserCredentialRecordId(credentialDeleteAId),
      ),
    });
    const shareA = await sharesRepo.create(
      db,
      userA,
      {
        // `shareBody.session_id` must match for the owner PUT positive
        // control (the repo refuses a session mismatch as share_not_found).
        sessionId: "shared-session",
        requestId: `sweep-share-${stamp}`,
        messages: [{ role: "user", content: "public text" }],
      },
      { now: new Date(), ttlSeconds: 3_600 },
    );
    const shareDeleteA = await sharesRepo.create(
      db,
      userA,
      {
        sessionId: "shared-session",
        requestId: `sweep-share-delete-${stamp}`,
        messages: [{ role: "user", content: "public text" }],
      },
      { now: new Date(), ttlSeconds: 3_600 },
    );

    fixtures = {
      sessionA,
      sessionB,
      sessionDeleteA,
      runA,
      scheduleA,
      scheduleDeleteA,
      scheduleRunNowA,
      historyDeleteA,
      historyRegenA,
      historyBranchA,
      pluginA,
      pluginDeleteA,
      mcpA,
      mcpDeleteA,
      byokA,
      byokDeleteA,
      artifactA,
      foreignArtifact,
      attachmentA,
      projectA,
      projectDeleteA,
      credentialA,
      credentialDeleteA,
      shareA,
      shareDeleteA,
    };

    // `remove` rejects so the cancel positive control takes the documented
    // "cancelling" degrade (202) without needing a real event log append.
    const noopQueue = {
      async add() {
        return {};
      },
    };
    const queues = {
      agentRuns: {
        async add() {
          return {};
        },
        async remove() {
          throw new Error("sweep stub: job not in queue");
        },
      },
      hydrate: noopQueue,
      hibernate: noopQueue,
      schedules: noopQueue,
      pluginInstalls: noopQueue,
    } as unknown as QueueServices;
    const events: EventLog = {
      async append() {
        throw new Error("events.append not expected in route sweep");
      },
      async readSince() {
        return [];
      },
      async subscribe() {
        return async () => {};
      },
    };
    const oauth: OAuthFlow = {
      async start() {
        return { authorizeUrl: "https://oauth.example.test/authorize" };
      },
      async handleCallback() {
        return { uid: "", serverId: "", ok: false };
      },
      async getAccessToken() {
        return null;
      },
      async disconnect() {},
    };
    const system: SystemBus = {
      async publish() {},
      async subscribe() {
        return async () => {};
      },
    };

    // -- Optional deps wired so every registration/behavior seam is live ----
    const presigner = {
      async presignPut() {
        return "https://upload.example.test/put";
      },
    };
    const storage = {
      kind: "fs" as const,
      async put(): Promise<never> {
        throw new Error("storage.put not expected in route sweep");
      },
      async get() {
        return null;
      },
      async getBuffer() {
        return null;
      },
      async head() {
        // Both fixtures (artifactA and attachmentA) are registered as 5 bytes:
        // the mint routes' single HEAD availability proof must pass for the
        // owner's positive control.
        return { bytes: 5, sha256Hex: null, etag: null, metadata: {} };
      },
      async delete() {},
      async presignGet() {
        return "https://download.example.test/artifact";
      },
      async presignPut() {
        return "https://upload.example.test/artifact";
      },
      async readerSpec() {
        return null;
      },
    };
    const worker = {
      async getTree() {
        return {
          ok: true as const,
          value: {
            tree: {
              version: 1 as const,
              generatedAt: new Date().toISOString(),
              truncated: false,
              totals: { files: 0, dirs: 0, bytes: 0 },
              roots: [],
            },
          },
        };
      },
      async getFile(_uid: string, _sessionId: string, path: string) {
        return {
          ok: true as const,
          value: {
            kind: "content" as const,
            path,
            sizeBytes: 2,
            sha256Hex: "c".repeat(64),
            contentType: "text/plain",
            contentBase64: Buffer.from("hi").toString("base64"),
          },
        };
      },
      async putFile(_uid: string, _sessionId: string, path: string) {
        return {
          ok: true as const,
          value: { path, sizeBytes: 2, sha256: "d".repeat(64) },
        };
      },
      async deleteFile(_uid: string, _sessionId: string, path: string) {
        return { ok: true as const, value: { path, type: "file" as const } };
      },
      async movePath(_uid: string, _sessionId: string, from: string, to: string) {
        return { ok: true as const, value: { from, to } };
      },
      async makeDir(_uid: string, _sessionId: string, path: string) {
        return { ok: true as const, value: { path, created: true } };
      },
    };
    // The account routes are registered at the ROOT with their own auth; the
    // lifecycle stub supplies deterministic account-admission 403s.
    const accountLifecycle = {
      async request(): Promise<never> {
        throw new AccountError("account_unavailable", 403);
      },
      async status(): Promise<never> {
        throw new AccountError("account_unavailable", 403);
      },
      async login(): Promise<never> {
        throw new AccountError("unsupported_identity", 403);
      },
      async cancel(): Promise<never> {
        throw new AccountError("account_deletion_pending", 403);
      },
      async access<T>(): Promise<T> {
        throw new AccountError("account_deletion_pending", 403);
      },
      async finalize(): Promise<never> {
        throw new AccountError("deletion_in_progress", 409);
      },
    };
    const accountVerify = async (token: string) => ({
      uid: token.replace(/^test:/, ""),
      auth_time: Math.floor(Date.now() / 1000),
      firebase: { sign_in_provider: "google.com" },
    });

    baseDeps = {
      db,
      queues,
      verifier: createTestVerifier(),
      system,
      tickets: {
        mint: async () => "unused",
        verify: async () => null,
      },
      keys: { getKeyForUser: async () => "sk-test" },
      mint: {
        ensureKeyForUid: async () => ({ key: "sk-test", tier: "free", baseUrl: "" }),
      },
      events,
      crypto,
      oauth,
      // Registration-gating optional deps: ALL wired (Finding 1b).
      // Legacy root routes included on purpose: the sweep must see every
      // registered route, not just the /cloud/v1 surface.
      shares: { baseUrl: "https://share.example.test" },
      reports: {},
      account: { lifecycle: accountLifecycle, verify: accountVerify },
      // Behavior-gating deps the owner-side positive controls exercise.
      presigner,
      storage,
      // W12: a wired CDN config so the signed-URL mints take their live path
      // (an unconfigured deployment answers a typed 503, which is not an
      // ownership answer and cannot prove the positive control).
      cdn: {
        baseUrl: "https://cdn.example.test",
        secret: "s".repeat(32),
        ttlSeconds: 900,
      },
      worker,
      byok: {
        fetchImpl: async () => new Response(null, { status: 200 }),
        lookupHost: async () => ["93.184.216.34"],
      },
    };

    app = buildGateway(baseDeps);
    await app.ready();
    routes = parsePrintRoutes(app.printRoutes({ commonPrefix: false }));
  });

  afterAll(async () => {
    await app?.close();
    await db?.$client.end({ timeout: 5 });
  });

  function routeKey(route: RouteEntry): string {
    return `${route.method} ${route.path}`;
  }

  /** Synthetic-input version of the parameterized guard (see the test below). */
  function unaccountedParamRoutes(input: RouteEntry[]): string[] {
    return input
      .filter((route) => route.path.includes(":"))
      .map(routeKey)
      .filter((key) => !(key in OWNED_CASES) && !(key in EXEMPT_PARAM_ROUTES));
  }

  /** Synthetic-input version of the non-param ownership guard. */
  function unaccountedNoParamOwnershipRoutes(input: RouteEntry[]): string[] {
    const covered = new Set([
      ...Object.keys(NO_PARAM_OWNERSHIP_CASES),
      ...NO_PARAM_OWNERSHIP_EXEMPT.map((entry) => `${entry.method} ${entry.path}`),
    ]);
    return input
      .filter((route) => route.method !== "GET")
      .filter((route) => isCloudPath(route.path))
      .filter((route) => !route.path.includes(":"))
      .map(routeKey)
      .filter((key) => !covered.has(key));
  }

  it("parsed the route table (sanity: known routes from every registration path)", () => {
    const keys = new Set(routes.map(routeKey));
    for (const expected of [
      "POST /cloud/v1/sessions",
      "GET /cloud/v1/sessions/:id",
      "POST /cloud/v1/runs/:id/cancel",
      "GET /cloud/v1/sessions/:id/artifacts/:artifactId/url",
      "POST /shares/:token/fork",
      "POST /v1/reports",
      // Each registration-gating optional dep is actually wired.
      "POST /account/deletion",
      "GET /shares",
      "POST /v1/reports",
    ]) {
      expect(keys.has(expected), `missing parsed route ${expected}`).toBe(true);
    }
  });

  it("every parameterized route has an ownership case or a documented exemption", () => {
    expect(unaccountedParamRoutes(routes)).toEqual([]);
  });

  it("the parameterized anti-shrink guard flags a newly added :param route", () => {
    // Probe with a synthetic registration: the guard is data-driven, so a new
    // route must fail until it is seeded. (The same proof the reviewer ran
    // against a live extra route, without touching gateway source.)
    expect(
      unaccountedParamRoutes([
        ...routes,
        { method: "GET", path: "/cloud/v1/newthing/:id" },
      ]),
    ).toEqual(["GET /cloud/v1/newthing/:id"]);
  });

  it("every non-GET /cloud/v1 route without a :param is owned or documented exempt", () => {
    expect(unaccountedNoParamOwnershipRoutes(routes)).toEqual([]);
  });

  it("the non-param ownership guard flags a newly added body-scoped route", () => {
    // Finding 1a probe: a new non-param ownership route (no `:param`) is
    // otherwise only 401-checked. It must fail until registered or exempted.
    expect(
      unaccountedNoParamOwnershipRoutes([
        ...routes,
        { method: "POST", path: "/cloud/v1/newthing/transfer" },
      ]),
    ).toEqual(["POST /cloud/v1/newthing/transfer"]);
  });

  it("every case/exemption/public entry maps to a registered route (no silent shrink)", () => {
    const registered = new Set(routes.map(routeKey));
    const tracked = [
      ...Object.keys(OWNED_CASES),
      ...Object.keys(EXEMPT_PARAM_ROUTES),
      ...Object.keys(NO_PARAM_OWNERSHIP_CASES),
      ...NO_PARAM_OWNERSHIP_EXEMPT.map((entry) => `${entry.method} ${entry.path}`),
      ...Object.keys(UNAUTH_SWEEP_BODIES),
      ...PUBLIC_ROUTES,
    ];
    const stale = tracked.filter((key) => !registered.has(key));
    expect(stale).toEqual([]);
  });

  it("the non-param ownership exemption list is exact (no silent widening)", () => {
    expect(NO_PARAM_OWNERSHIP_EXEMPT.map((entry) => `${entry.method} ${entry.path}`)).toEqual([
      "POST /cloud/v1/auth/ticket",
      "POST /cloud/v1/sessions",
      "PATCH /cloud/v1/preferences",
      "POST /cloud/v1/plugins/install",
      "POST /cloud/v1/system/responses",
      "POST /cloud/v1/schedules",
      "PATCH /cloud/v1/preferences",
      "POST /cloud/v1/devices",
      "DELETE /cloud/v1/devices",
      "POST /cloud/v1/byok",
      "POST /cloud/v1/mcp/servers",
      "POST /cloud/v1/projects",
      "POST /cloud/v1/credentials",
    ]);
    for (const entry of NO_PARAM_OWNERSHIP_EXEMPT) {
      expect(entry.reason.length, `${entry.method} ${entry.path} needs a reason`).toBeGreaterThan(
        10,
      );
    }
  });

  it("every registration-gating optional dep is wired or explicitly not covered", () => {
    // `account`, `shares`, and `reports` are wired in beforeAll (their routes
    // are asserted present in the sanity test). Anything that cannot be wired
    // must be listed with a reason — exact-array asserted so it stays visible.
    expect(NOT_COVERED_OPTIONAL_DEPS).toEqual([]);
  });

  it("every non-public route answers 401 without a ticket", async () => {
    const failures: string[] = [];
    for (const route of routes) {
      const key = routeKey(route);
      if (PUBLIC_ROUTES.has(key)) continue;
      const url = fillParams(route.path, unknownValues(route.path));
      const res = await app.inject({
        method: route.method as "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
        url,
        headers: {},
        payload: UNAUTH_SWEEP_BODIES[key] ?? bodyFor(route.method),
      });
      if (res.statusCode !== 401) {
        failures.push(`${key} → ${res.statusCode} (expected 401)`);
        continue;
      }
      const body = res.json() as Record<string, unknown>;
      if (isCloudPath(route.path)) {
        const error = body.error as { code?: string } | undefined;
        if (error?.code !== "unauthenticated") {
          failures.push(`${key} → 401 but code=${String(error?.code)}`);
        }
      } else {
        // Legacy Python routes keep `{detail: <code>}`.
        if (typeof body.detail !== "string" || !body.detail.includes("authentication")) {
          failures.push(`${key} → 401 but detail=${JSON.stringify(body.detail)}`);
        }
      }
    }
    expect(failures).toEqual([]);
  });

  it("every ownership-gated route answers 404 (never 403) cross-owner", async () => {
    const failures: string[] = [];
    for (const route of routes) {
      const key = routeKey(route);
      const ownershipCase = OWNED_CASES[key];
      if (ownershipCase === undefined) continue;
      const url = withQuery(
        fillParams(route.path, ownershipCase.params(fixtures)),
        resolveQuery(ownershipCase.query, fixtures),
      );
      const res = await app.inject({
        method: route.method as "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
        url,
        headers: authHeaders(userB),
        payload: bodyFor(route.method, resolveBody(ownershipCase.body, fixtures)),
      });
      const isAllowed403 = TIER_GATE_ALLOWLIST.some(
        (entry) => entry.method === route.method && entry.path === route.path,
      );
      if (res.statusCode === 403 && !isAllowed403) {
        failures.push(`${key} → 403 (LEAK: must be 404)`);
        continue;
      }
      if (res.statusCode !== 404) {
        failures.push(`${key} → ${res.statusCode} (expected 404)`);
        continue;
      }
      const body = res.json() as Record<string, unknown>;
      if (isCloudPath(route.path)) {
        const error = body.error as { code?: string } | undefined;
        if (error?.code !== "not_found") {
          failures.push(`${key} → 404 but code=${String(error?.code)}`);
        }
      } else if (body.detail !== "share_not_found") {
        failures.push(`${key} → 404 but detail=${JSON.stringify(body.detail)}`);
      }
    }
    expect(failures).toEqual([]);
  });

  it("every ownership-gated route answers the same 404 for an unknown id", async () => {
    const failures: string[] = [];
    for (const route of routes) {
      const key = routeKey(route);
      if (!(key in OWNED_CASES)) continue;
      const ownershipCase = OWNED_CASES[key]!;
      const params = {
        ...unknownValues(route.path),
        ...(ownershipCase.unknownParams?.(fixtures) ?? {}),
      };
      const url = withQuery(
        fillParams(route.path, params),
        ownershipCase.unknownQuery?.(fixtures),
      );
      const res = await app.inject({
        method: route.method as "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
        url,
        headers: authHeaders(userA),
        payload: bodyFor(route.method, resolveBody(ownershipCase.body, fixtures)),
      });
      if (res.statusCode !== 404) {
        failures.push(`${key} → ${res.statusCode} (expected 404 for unknown id)`);
        continue;
      }
      if (isCloudPath(route.path)) {
        const error = (res.json() as { error?: { code?: string } }).error;
        if (error?.code !== "not_found") {
          failures.push(`${key} → 404 but code=${String(error?.code)}`);
        }
      }
    }
    expect(failures).toEqual([]);
  });

  it("malformed ids answer 404 (never a 500 from a uuid bind)", async () => {
    const failures: string[] = [];
    for (const route of routes) {
      const key = routeKey(route);
      if (!(key in OWNED_CASES)) continue;
      const ownershipCase = OWNED_CASES[key]!;
      const params = {
        ...malformedValues(route.path),
        ...(ownershipCase.malformedParams?.(fixtures) ?? {}),
      };
      const url = withQuery(
        fillParams(route.path, params),
        ownershipCase.malformedQuery?.(fixtures),
      );
      const res = await app.inject({
        method: route.method as "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
        url,
        headers: authHeaders(userA),
        payload: bodyFor(route.method, resolveBody(ownershipCase.body, fixtures)),
      });
      if (res.statusCode === 500 || res.statusCode === 403) {
        failures.push(`${key} → ${res.statusCode} (malformed id must be 404)`);
      } else if (res.statusCode !== 404) {
        failures.push(`${key} → ${res.statusCode} (expected 404)`);
      }
    }
    expect(failures).toEqual([]);
  });

  it("artifact ownership is checked independently of session ownership", async () => {
    // B owns the session, but the artifact row belongs to A.
    const res = await app.inject({
      method: "GET",
      url:
        `/cloud/v1/sessions/${fixtures.sessionB.id}/artifacts/` +
        `${fixtures.foreignArtifact.id}/url`,
      headers: authHeaders(userB),
    });
    expect(res.statusCode).toBe(404);
    expect((res.json() as { error?: { code?: string } }).error?.code).toBe("not_found");
  });

  it("every body/query-scoped ownership route answers 404 cross-owner", async () => {
    const failures: string[] = [];
    for (const [key, ownershipCase] of Object.entries(NO_PARAM_OWNERSHIP_CASES)) {
      const { method } = splitRouteKey(key);
      const request = ownershipCase.request(fixtures);
      const res = await app.inject({
        method: method as "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
        url: request.url,
        headers: authHeaders(userB),
        payload: bodyFor(method, request.body),
      });
      if (res.statusCode !== 404) {
        failures.push(`${key} → ${res.statusCode} (expected 404)`);
        continue;
      }
      const error = (res.json() as { error?: { code?: string } }).error;
      if (error?.code !== "not_found") {
        failures.push(`${key} → 404 but code=${String(error?.code)}`);
      }
    }
    expect(failures).toEqual([]);
  });

  it("legacy share fork is a public capability, not an ownership leak", async () => {
    // The token IS the capability: any authenticated user may fork an active
    // public share. Pinned so this is never mistaken for a 404 violation.
    const requestId = `fork-${Date.now().toString(36)}`;
    const res = await app.inject({
      method: "POST",
      url: `/shares/${fixtures.shareA.token}/fork`,
      headers: authHeaders(userB),
      payload: { request_id: requestId },
    });
    expect(res.statusCode).toBe(201);
    const body = res.json() as { session_id?: string };
    expect(typeof body.session_id).toBe("string");

    // Idempotent per (recipient, request_id).
    const again = await app.inject({
      method: "POST",
      url: `/shares/${fixtures.shareA.token}/fork`,
      headers: authHeaders(userB),
      payload: { request_id: requestId },
    });
    expect(again.statusCode).toBe(201);
    expect((again.json() as { session_id?: string }).session_id).toBe(body.session_id);
  });

  it("public viewers answer 404 for an unknown token", async () => {
    const token = randomBytes(32).toString("base64url");
    const json = await app.inject({ method: "GET", url: `/s/${token}.json` });
    expect(json.statusCode).toBe(404);
    expect((json.json() as { detail?: string }).detail).toBe("share_not_found");

    const page = await app.inject({ method: "GET", url: `/s/${token}` });
    expect(page.statusCode).toBe(404);

    // The invite landing does NO lookup by design (joining, and the member
    // cap, are enforced by the authenticated join call) — it is a static
    // landing page, so an unknown token/invite is a 200 by contract.
    const invite = await app.inject({
      method: "GET",
      url: `/s/${token}/${randomBytes(32).toString("base64url")}`,
    });
    expect(invite.statusCode).toBe(200);
  });

  it("tier gates answer 402/403 per their contract, and every 403 is allowlisted", async () => {
    // P5/P9 gates: 402 pro_required.
    const pluginsRes = await app.inject({
      method: "POST",
      url: "/cloud/v1/plugins/install",
      headers: authHeaders(userA), // tier defaults to free
      payload: { source: { kind: "npm", package: "@ovid/sweep-plugin" } },
    });
    expect(pluginsRes.statusCode).toBe(402);
    expect((pluginsRes.json() as { error?: { code?: string } }).error?.code).toBe(
      "pro_required",
    );

    // P4 cron tier gate: the only 403 on an ownership route, allowlisted.
    const cron = await app.inject({
      method: "POST",
      url: "/cloud/v1/schedules",
      headers: authHeaders(userA),
      payload: {
        title: "cron schedule",
        description: "sweep",
        trigger: { kind: "cron", expr: "*/5 * * * *", tz: "UTC" },
      },
    });
    expect(cron.statusCode).toBe(403);
    expect((cron.json() as { error?: { code?: string } }).error?.code).toBe(
      "tier_required",
    );
    expect(TIER_GATE_ALLOWLIST).toEqual([
      { method: "POST", path: "/cloud/v1/schedules", expected: 403 },
      { method: "PATCH", path: "/cloud/v1/schedules/:id", expected: 403 },
    ]);
  });

  it("the allowlist's PATCH entry is a real tier gate (owner cron PATCH → 403)", async () => {
    // Positive control for the allowlist itself: the same body that a foreign
    // owner sends below must actually reach the tier gate for the OWNER.
    const res = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/schedules/${fixtures.scheduleA.id}`,
      headers: authHeaders(userA),
      payload: { trigger: { kind: "cron", expr: "*/5 * * * *", tz: "UTC" } },
    });
    expect(res.statusCode).toBe(403);
    expect((res.json() as { error?: { code?: string } }).error?.code).toBe(
      "tier_required",
    );
  });

  it("foreign owner's cron PATCH answers 404, never 403 (ownership precedes the tier gate)", async () => {
    // Finding 2 pin: if the cron tier check moved before the ownership check,
    // a stranger would get 403 tier_required — an existence probe. It must
    // stay 404 not_found even when the body would hit the gate.
    const res = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/schedules/${fixtures.scheduleA.id}`,
      headers: authHeaders(userB),
      payload: { trigger: { kind: "cron", expr: "*/5 * * * *", tz: "UTC" } },
    });
    expect(res.statusCode).toBe(404);
    expect((res.json() as { error?: { code?: string } }).error?.code).toBe("not_found");
  });

  it("/account/* 403s are account-admission codes, not ownership leaks", async () => {
    // Finding 3: the legacy lifecycle routes intentionally answer 403 for
    // identity/lifecycle states. They are not ownership routes; assert the
    // exact account codes so the report's "only cron 403s" claim is not
    // silently relied on.
    const cases = [
      {
        method: "POST" as const,
        url: "/account/deletion",
        payload: { request_id: "sweep-account-request" },
        code: "account_unavailable",
      },
      {
        method: "GET" as const,
        url: "/account/deletion",
        code: "account_unavailable",
      },
      {
        method: "POST" as const,
        url: "/account/login",
        payload: {},
        code: "unsupported_identity",
      },
      {
        method: "POST" as const,
        url: "/account/deletion/cancel",
        payload: { consent: true },
        code: "account_deletion_pending",
      },
    ];
    for (const item of cases) {
      const res = await app.inject({
        method: item.method,
        url: item.url,
        headers: authHeaders(userA),
        payload: item.payload,
      });
      expect(res.statusCode, item.url).toBe(403);
      expect((res.json() as { detail?: string }).detail, item.url).toBe(item.code);
    }
  });

  it("legacy shares/reports admission 403s are account-admission codes", async () => {
    // Finding 3: in the production composition `accountAdmission` wraps the
    // legacy shares and reports writes. Build that composition explicitly
    // (the main sweep intentionally leaves admission off so ownership
    // semantics are exercised) and assert the 403 is the admission code.
    const admission = async (): Promise<never> => {
      throw new AccountError("account_deletion_pending", 403);
    };
    const admissionApp = buildGateway({
      ...baseDeps,
      shares: { baseUrl: "https://share.example.test", admission },
      reports: { admission },
    });
    try {
      const sharesRes = await admissionApp.inject({
        method: "GET",
        url: "/shares",
        headers: authHeaders(userA),
      });
      expect(sharesRes.statusCode).toBe(403);
      expect((sharesRes.json() as { detail?: string }).detail).toBe(
        "account_deletion_pending",
      );

      const reportsRes = await admissionApp.inject({
        method: "POST",
        url: "/v1/reports",
        headers: authHeaders(userA),
        payload: {
          request_id: "sweep-report-request-1",
          kind: "ai_output",
          reason: "spam",
        },
      });
      expect(reportsRes.statusCode).toBe(403);
      expect((reportsRes.json() as { detail?: string }).detail).toBe(
        "account_deletion_pending",
      );
    } finally {
      await admissionApp.close();
    }
  });

  it("every ownership route answers its OWNER with 2xx (positive control)", async () => {
    // Finding 4: "foreign owner → 404" alone would pass for a route that
    // unconditionally 404s. Every case must also succeed for its owner.
    const failures: string[] = [];
    for (const [key, ownershipCase] of Object.entries(OWNED_CASES)) {
      const { method, path } = splitRouteKey(key);
      let url = fillParams(path, ownershipCase.params(fixtures));
      const ownerQuery = resolveQuery(ownershipCase.ownerQuery, fixtures);
      if (ownerQuery !== undefined) {
        url = withQuery(url, ownerQuery);
      }
      const res = await app.inject({
        method: method as "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
        url,
        headers: authHeaders(userA),
        payload: bodyFor(
          method,
          resolveBody(
            (typeof ownershipCase.ownerBody === "function"
              ? (ownershipCase.ownerBody as (f: Fixtures) => unknown)(fixtures)
              : ownershipCase.ownerBody) ?? ownershipCase.body,
            fixtures,
          ),
        ),
      });
      if (ownershipCase.ownerStatus !== undefined) {
        // Documented release-gated refusal (history mutations): assert the
        // exact status AND code, so a 409 cannot mask an ownership failure.
        if (res.statusCode !== ownershipCase.ownerStatus) {
          failures.push(
            `${key} → ${res.statusCode} (expected ${ownershipCase.ownerStatus} for the owner)`,
          );
          continue;
        }
        if (ownershipCase.ownerCode !== undefined) {
          const code = (res.json() as { error?: { code?: string } }).error?.code;
          if (code !== ownershipCase.ownerCode) {
            failures.push(`${key} → ${res.statusCode} but code=${String(code)}`);
          }
        }
        continue;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        failures.push(`${key} → ${res.statusCode} (expected 2xx for the owner)`);
      }
    }
    expect(failures).toEqual([]);
  });
});
