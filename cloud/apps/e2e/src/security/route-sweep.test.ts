/**
 * P10 Task 9 — systematic 404-not-403 route sweep.
 *
 * The sweep is ROUTE-TABLE-DRIVEN, not hand-listed: the authenticated route
 * table is parsed from `app.printRoutes()` at execution time, so a route added
 * by a later phase is swept automatically. The safety net for that dynamism:
 *
 *   - every parameterized route MUST have an ownership case in
 *     `OWNED_CASES` (or an explicit, justified entry in `EXEMPT_PARAM_ROUTES`)
 *     — a new `:param` route without one fails the suite;
 *   - every `OWNED_CASES` entry MUST still correspond to a registered route —
 *     a stale case (route removed/renamed) fails the suite;
 *   - every route not on `PUBLIC_ROUTES` MUST answer 401 without a ticket —
 *     a route accidentally registered public fails the suite.
 *
 * For each ownership-gated route the sweep asserts, as a foreign user B:
 *   - a resource owned by A answers 404 (never 403) with the shared
 *     `{error:{code:"not_found"}}` envelope (legacy root routes keep their
 *     Python `{detail:"share_not_found"}` envelope);
 *   - an unknown id answers the same 404 shape;
 *   - a malformed id answers 404 (never a 500 from a uuid-column bind).
 *
 * `TIER_GATE_ALLOWLIST` is the ONLY place a literal 403 is permitted (P5/P4
 * tier gates). Ownership NEVER answers 403: every ownership failure is 404.
 * Today the only 403s are the P4 cron tier gates on schedule create/update;
 * every P5/P9 gate answers 402 `pro_required` (or 503 `unavailable`).
 */

import { randomBytes } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  byokKeysRepo,
  createDb,
  mcpServers,
  messages,
  migrate,
  newId,
  plugins,
  runs,
  schedules,
  sessions,
  sharesRepo,
  users,
  workspaceObjects,
  type ByokKeyRow,
  type Db,
  type McpServerRow,
  type PluginRow,
  type RunRow,
  type ScheduleRow,
  type SessionRow,
  type ShareReceiptRow,
  type WorkspaceObjectRow,
} from "@ovid/db";
import type { EventLog, SystemBus } from "@ovid/events";
import type { OAuthFlow } from "@ovid/mcp";
import { createEnvelopeCrypto } from "@ovid/mcp";
import type { QueueServices } from "@ovid/queue";
import { buildGateway, createTestVerifier } from "@ovid/gateway";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

if (!TEST_DATABASE_URL) {
  console.warn(
    "[security] route-sweep SKIPPED: TEST_DATABASE_URL is unset — the " +
      "404-not-403 ownership sweep did NOT run.",
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
 * The ONLY routes permitted to answer a literal 403. Each entry carries its
 * one-line justification. Empty today — ownership failures are 404 and tier
 * gates are 402 `pro_required`.
 */
export const TIER_GATE_ALLOWLIST: Array<{
  method: string;
  path: string;
  expected: 403;
}> = [
  // P4 cron tier gate: creating a cron schedule as a Free user answers
  // 403 tier_required (the one non-ownership 403 in the gateway).
  { method: "POST", path: "/cloud/v1/schedules", expected: 403 },
  // Same gate when an owner changes an existing schedule's trigger to cron.
  { method: "PATCH", path: "/cloud/v1/schedules/:id", expected: 403 },
];

/** Unauthenticated-by-design routes (explicit; a new public route must be
 * added here or it fails the 401 sweep). */
const PUBLIC_ROUTES = new Set([
  "GET /cloud/v1/health",
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
};

// ---------------------------------------------------------------------------
// Fixtures: one owned resource per family
// ---------------------------------------------------------------------------

interface Fixtures {
  sessionA: SessionRow;
  sessionB: SessionRow;
  runA: RunRow;
  scheduleA: ScheduleRow;
  pluginA: PluginRow;
  mcpA: McpServerRow;
  byokA: ByokKeyRow;
  artifactA: WorkspaceObjectRow;
  /** A's artifact under B's session — exercises artifact-level ownership. */
  foreignArtifact: WorkspaceObjectRow;
  shareA: ShareReceiptRow;
}

interface Case {
  /** Path params materializing user A's resource. */
  params: (f: Fixtures) => Record<string, string>;
  /** A valid body so only ownership (not validation) can reject. */
  body?: unknown;
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
  "POST /cloud/v1/sessions/:id/messages": {
    params: (f) => ({ id: f.sessionA.id }),
    body: { content: "hello" },
  },
  "GET /cloud/v1/sessions/:id/messages": { params: (f) => ({ id: f.sessionA.id }) },
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
  },
  "PUT /cloud/v1/sessions/:id/workspace/file": {
    params: (f) => ({ id: f.sessionA.id }),
    body: {},
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
  "PATCH /cloud/v1/schedules/:id": {
    params: (f) => ({ id: f.scheduleA.id }),
    body: { title: "foreign edit" },
  },
  "DELETE /cloud/v1/schedules/:id": { params: (f) => ({ id: f.scheduleA.id }) },
  "GET /cloud/v1/plugins/:id": { params: (f) => ({ id: f.pluginA.id }) },
  "DELETE /cloud/v1/plugins/:id": { params: (f) => ({ id: f.pluginA.id }) },
  "PATCH /cloud/v1/plugins/:id/config": {
    params: (f) => ({ id: f.pluginA.id }),
    body: { config: { token: "x" } },
  },
  "GET /cloud/v1/mcp/servers/:id": { params: (f) => ({ id: f.mcpA.id }) },
  "PATCH /cloud/v1/mcp/servers/:id": {
    params: (f) => ({ id: f.mcpA.id }),
    body: { enabled: false },
  },
  "DELETE /cloud/v1/mcp/servers/:id": { params: (f) => ({ id: f.mcpA.id }) },
  "DELETE /cloud/v1/byok/:id": { params: (f) => ({ id: f.byokA.id }) },
  "POST /cloud/v1/byok/:id/test": { params: (f) => ({ id: f.byokA.id }) },
  // Legacy root routes (Python envelope): owner-scoped update/revoke.
  "PUT /shares/:token": {
    params: (f) => ({ token: f.shareA.token }),
    body: shareBody,
  },
  "DELETE /shares/:token": { params: (f) => ({ token: f.shareA.token }) },
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

function isCloudPath(path: string): boolean {
  return path.startsWith("/cloud/v1/");
}

function authHeaders(uid: string): Record<string, string> {
  return { authorization: `Bearer test:${uid}` };
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_DATABASE_URL)("route sweep — 404 not 403", () => {
  let db: Db;
  let app: ReturnType<typeof buildGateway>;
  let routes: RouteEntry[];
  let fixtures: Fixtures;
  let userA: string;
  let userB: string;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);

    const stamp = `${Date.now().toString(36)}-${randomBytes(4).toString("hex")}`;
    userA = `sweep-a-${stamp}`;
    userB = `sweep-b-${stamp}`;
    await users.ensure(db, userA, null);
    await users.ensure(db, userB, null);

    const sessionA = await sessions.create(db, userA, "A session");
    const sessionB = await sessions.create(db, userB, "B session");
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
    const pluginA = await plugins.upsert(db, {
      userId: userA,
      pluginId: "@ovid/sweep-plugin",
      version: "1.0.0",
      source: { kind: "npm", label: "@ovid/sweep-plugin" },
      status: "installed",
    });
    const mcpA = await mcpServers.create(db, {
      userId: userA,
      name: "sweep-server",
      transport: "http",
      config: { url: "https://mcp.example.test" },
    });
    const byokA = await byokKeysRepo.create(db, {
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
    const shareA = await sharesRepo.create(
      db,
      userA,
      {
        sessionId: sessionA.id,
        requestId: `sweep-share-${stamp}`,
        messages: [{ role: "user", content: "public text" }],
      },
      { now: new Date(), ttlSeconds: 3_600 },
    );

    fixtures = {
      sessionA,
      sessionB,
      runA,
      scheduleA,
      pluginA,
      mcpA,
      byokA,
      artifactA,
      foreignArtifact,
      shareA,
    };

    const queues = {
      agentRuns: { remove: async () => {} },
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

    app = buildGateway({
      db,
      queues,
      verifier: createTestVerifier(),
      system,
      tickets: {
        mint: async () => "unused",
        verify: async () => null,
      },
      keys: { getKeyForUser: async () => "sk-test" },
      mint: { ensureKey: async () => ({ key: "sk-test" }) },
      events,
      crypto: createEnvelopeCrypto("11".repeat(32)),
      oauth,
      // Legacy root routes included on purpose: the sweep must see every
      // registered route, not just the /cloud/v1 surface.
      shares: { baseUrl: "https://share.example.test" },
      reports: {},
    });
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

  it("parsed the route table (sanity: known routes are present)", () => {
    const keys = new Set(routes.map(routeKey));
    for (const expected of [
      "POST /cloud/v1/sessions",
      "GET /cloud/v1/sessions/:id",
      "POST /cloud/v1/runs/:id/cancel",
      "GET /cloud/v1/sessions/:id/artifacts/:artifactId/url",
      "POST /shares/:token/fork",
      "POST /v1/reports",
    ]) {
      expect(keys.has(expected), `missing parsed route ${expected}`).toBe(true);
    }
  });

  it("every parameterized route has an ownership case or a documented exemption", () => {
    const missing = routes
      .filter((route) => route.path.includes(":"))
      .map(routeKey)
      .filter((key) => !(key in OWNED_CASES) && !(key in EXEMPT_PARAM_ROUTES));
    expect(missing).toEqual([]);
  });

  it("every ownership/exemption case maps to a registered route (no silent shrink)", () => {
    const registered = new Set(routes.map(routeKey));
    const stale = [...Object.keys(OWNED_CASES), ...Object.keys(EXEMPT_PARAM_ROUTES)].filter(
      (key) => !registered.has(key),
    );
    expect(stale).toEqual([]);
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
        payload: bodyFor(route.method),
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
      const url = fillParams(route.path, ownershipCase.params(fixtures));
      const res = await app.inject({
        method: route.method as "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
        url,
        headers: authHeaders(userB),
        payload: bodyFor(route.method, ownershipCase.body),
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
      const url = fillParams(route.path, unknownValues(route.path));
      const res = await app.inject({
        method: route.method as "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
        url,
        headers: authHeaders(userA),
        payload: bodyFor(route.method, ownershipCase.body),
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
      const url = fillParams(route.path, malformedValues(route.path));
      const res = await app.inject({
        method: route.method as "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
        url,
        headers: authHeaders(userA),
        payload: bodyFor(route.method, ownershipCase.body),
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

  it("body/query-scoped ownership also answers 404 cross-owner", async () => {
    // MCP OAuth start (query) and disconnect (body).
    const start = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/oauth/start?serverId=${fixtures.mcpA.id}`,
      headers: authHeaders(userB),
    });
    expect(start.statusCode).toBe(404);
    expect((start.json() as { error?: { code?: string } }).error?.code).toBe("not_found");

    const disconnect = await app.inject({
      method: "POST",
      url: "/cloud/v1/mcp/oauth/disconnect",
      headers: authHeaders(userB),
      payload: { serverId: fixtures.mcpA.id },
    });
    expect(disconnect.statusCode).toBe(404);
    expect((disconnect.json() as { error?: { code?: string } }).error?.code).toBe(
      "not_found",
    );

    // History import continuation targets a session id from the body.
    const importRes = await app.inject({
      method: "POST",
      url: "/cloud/v1/import/sessions",
      headers: authHeaders(userB),
      payload: {
        sessionId: fixtures.sessionA.id,
        messages: [
          {
            clientMsgId: "sweep-import-1",
            role: "user",
            content: "hello",
            createdAt: new Date().toISOString(),
          },
        ],
      },
    });
    expect(importRes.statusCode).toBe(404);
    expect((importRes.json() as { error?: { code?: string } }).error?.code).toBe(
      "not_found",
    );
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
    const plugins = await app.inject({
      method: "POST",
      url: "/cloud/v1/plugins/install",
      headers: authHeaders(userA), // tier defaults to free
      payload: { source: { kind: "npm", package: "@ovid/sweep-plugin" } },
    });
    expect(plugins.statusCode).toBe(402);
    expect((plugins.json() as { error?: { code?: string } }).error?.code).toBe(
      "pro_required",
    );

    // P4 cron tier gate: the only 403 in the gateway, explicitly allowlisted.
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
});
