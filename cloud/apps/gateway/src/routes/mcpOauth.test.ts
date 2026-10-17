import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { mcpServers, users, type Db } from "@ovid/db";
import {
  createEnvelopeCrypto,
  createOAuthFlow,
  type GuardedFetch,
  type SystemEventPublisher,
} from "@ovid/mcp";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";

// MCP OAuth endpoints (P5 Task 15): start (authed), callback (PUBLIC —
// reachable without auth headers), disconnect. The flow is the REAL Task-9
// createOAuthFlow over a fake fetchImpl (the fixture authorization server
// below answers RFC 9728/8414/7591/6749) + the real Postgres tables. The
// capturing systemBus stands where main() wires the systemHub adapter
// (publishOut) — the flow's notify() is the single publish path.

const TEST_DATABASE_URL_ = TEST_DATABASE_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";
const AS_ORIGIN = "https://as.fixture.test";
const ACCESS_TOKEN = "fixture-access-token-5c9e";
const REDIRECT_URI = "https://ovidsi.com/oauth/callback";

/** Minimal RFC 9728 + 8414 + DCR + token authorization server, in-process. */
function fakeAsFetch(requests: string[]): GuardedFetch {
  return async (url: string, init?: RequestInit): Promise<Response> => {
    requests.push(`${init?.method ?? "GET"} ${url}`);
    const u = new URL(url);
    if (u.origin !== AS_ORIGIN) return new Response(null, { status: 404 });
    const json = (body: unknown, status = 200): Response =>
      new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json" },
      });
    switch (u.pathname) {
      case "/.well-known/oauth-protected-resource/mcp":
        return new Response(null, { status: 404 }); // path-aware candidate absent
      case "/.well-known/oauth-protected-resource":
        return json({ resource: `${AS_ORIGIN}/mcp`, authorization_servers: [AS_ORIGIN] });
      case "/.well-known/oauth-authorization-server":
        return json({
          issuer: AS_ORIGIN,
          authorization_endpoint: `${AS_ORIGIN}/as/authorize`,
          token_endpoint: `${AS_ORIGIN}/as/token`,
          registration_endpoint: `${AS_ORIGIN}/as/register`,
          code_challenge_methods_supported: ["S256"],
        });
      case "/as/register":
        return json({ client_id: "dcr-client-1", client_secret: "dcr-secret-1" });
      case "/as/token":
        return json({
          access_token: ACCESS_TOKEN,
          token_type: "Bearer",
          refresh_token: "fixture-refresh-token",
          expires_in: 3600,
        });
      default:
        return new Response(null, { status: 404 });
    }
  };
}

interface PublishedEvent {
  uid: string;
  kind: string;
  requiresResponse: boolean;
  payload: Record<string, unknown>;
}

describe.skipIf(!TEST_DATABASE_URL_)("gateway mcp oauth routes (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;
  const published: PublishedEvent[] = [];
  const requests: string[] = [];
  const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);

  beforeAll(async () => {
    db = await openTestDb();
    const systemBus: SystemEventPublisher = {
      publish: async (uid, event) => {
        published.push({
          uid,
          kind: event.kind,
          requiresResponse: event.requiresResponse ?? false,
          payload: event.payload,
        });
      },
    };
    const oauth = createOAuthFlow({
      db,
      crypto,
      systemBus,
      fetchImpl: fakeAsFetch(requests),
      redirectUri: REDIRECT_URI,
    });
    app = buildGateway({
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      crypto,
      oauth,
    });
  }, 60_000);

  afterAll(async () => {
    await app?.close();
    await closeDb(db);
  });

  async function seedServer(uid: string): Promise<string> {
    await users.ensure(db, uid, `${uid}@stub.test`);
    const row = await mcpServers.create(db, {
      userId: uid,
      name: `as-${Math.random().toString(36).slice(2, 8)}`,
      transport: "http",
      config: { url: `${AS_ORIGIN}/mcp`, type: "http" },
    });
    return row.id;
  }

  it("GET /mcp/oauth/start → 200 {authorizeUrl} with state + PKCE (fake fetchImpl, real db)", async () => {
    const uid = testUid("oau-start");
    const serverId = await seedServer(uid);
    const res = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/oauth/start?serverId=${serverId}`,
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(200);
    const { authorizeUrl } = res.json() as { authorizeUrl: string };
    const u = new URL(authorizeUrl);
    expect(u.origin + u.pathname).toBe(`${AS_ORIGIN}/as/authorize`);
    expect(u.searchParams.get("state")).toMatch(/^[A-Za-z0-9_-]{40,}$/);
    expect(u.searchParams.get("code_challenge")).toMatch(/^[A-Za-z0-9_-]{40,}$/);
    expect(u.searchParams.get("code_challenge_method")).toBe("S256");
    expect(u.searchParams.get("redirect_uri")).toBe(REDIRECT_URI);
    // Discovery + DCR actually ran through the injected fetchImpl.
    expect(requests.some((r) => r.includes("/.well-known/oauth-authorization-server"))).toBe(true);
    expect(requests.some((r) => r.startsWith("POST ") && r.includes("/as/register"))).toBe(true);
  });

  it("callback is PUBLIC (no auth headers) and a valid state → 200 HTML + publishOut observed", async () => {
    const uid = testUid("oau-cb");
    const serverId = await seedServer(uid);
    const start = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/oauth/start?serverId=${serverId}`,
      headers: authHeaders(uid),
    });
    const { authorizeUrl } = start.json() as { authorizeUrl: string };
    const state = new URL(authorizeUrl).searchParams.get("state")!;

    // No authorization header at all — the callback scope is public.
    const res = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/oauth/callback?state=${encodeURIComponent(state)}&code=fixture-code-1`,
    });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-type"]).toContain("text/html");
    expect(res.body).toContain("close this window");
    expect(res.body.toLowerCase()).not.toContain(ACCESS_TOKEN);

    const completed = published.find(
      (e) => e.uid === uid && e.kind === "mcp_oauth_completed",
    );
    expect(completed).toBeDefined();
    expect(completed!.payload).toMatchObject({ serverId, ok: true });

    // Tokens are stored SEALED (mcp_oauth_tokens:{serverId}), never plaintext.
    const rows = (await db.$client.unsafe(
      "SELECT tokens_sealed AS sealed FROM mcp_oauth_tokens WHERE server_id = $1",
      [serverId],
    )) as { sealed: { wrappedDek: string; iv: string; ciphertext: string; tag: string } }[];
    expect(rows.length).toBe(1);
    expect(JSON.stringify(rows[0]!.sealed)).not.toContain(ACCESS_TOKEN);
    const plain = JSON.parse(crypto.decrypt(rows[0]!.sealed, `mcp_oauth_tokens:${serverId}`));
    expect((plain as { accessToken: string }).accessToken).toBe(ACCESS_TOKEN);
  });

  it("callback with unknown/replayed state → 400 oauth_failed HTML", async () => {
    const res = await app.inject({
      method: "GET",
      url: "/cloud/v1/mcp/oauth/callback?state=bogus-state&code=whatever",
    });
    expect(res.statusCode).toBe(400);
    expect(res.headers["content-type"]).toContain("text/html");
    expect(res.body).toContain("Authorization failed");
  });

  it("start for an unknown or foreign server → 404 (never 403)", async () => {
    const uid = testUid("oau-404");
    const foreign = testUid("oau-foreign");
    const serverId = await seedServer(foreign);
    for (const serverIdToUse of ["00000000-0000-4000-8000-000000000000", serverId]) {
      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/mcp/oauth/start?serverId=${serverIdToUse}`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(404);
    }
  });

  it("POST /mcp/oauth/disconnect removes the tokens row", async () => {
    const uid = testUid("oau-disc");
    const serverId = await seedServer(uid);
    const start = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/oauth/start?serverId=${serverId}`,
      headers: authHeaders(uid),
    });
    const state = new URL((start.json() as { authorizeUrl: string }).authorizeUrl).searchParams.get(
      "state",
    )!;
    await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/oauth/callback?state=${encodeURIComponent(state)}&code=fixture-code-2`,
    });

    const gone = await app.inject({
      method: "POST",
      url: "/cloud/v1/mcp/oauth/disconnect",
      headers: authHeaders(uid),
      payload: { serverId },
    });
    expect(gone.statusCode).toBe(204);
    const rows = (await db.$client.unsafe(
      "SELECT count(*)::int AS n FROM mcp_oauth_tokens WHERE server_id = $1",
      [serverId],
    )) as { n: number }[];
    expect(rows[0]!.n).toBe(0);
  });

  it("oauth routes on a gateway composed WITHOUT the flow → 503 unavailable", async () => {
    const bare = buildGateway({
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
    const start = await bare.inject({
      method: "GET",
      url: `/cloud/v1/mcp/oauth/start?serverId=00000000-0000-4000-8000-000000000000`,
      headers: authHeaders(testUid("oau-bare")),
    });
    expect(start.statusCode).toBe(503);
    expect(start.json()).toEqual({
      error: { code: "unavailable", message: "MCP OAuth is not configured." },
    });
    const cb = await bare.inject({
      method: "GET",
      url: "/cloud/v1/mcp/oauth/callback?state=x&code=y",
    });
    expect(cb.statusCode).toBe(503);
    expect(cb.headers["content-type"]).toContain("text/html");
    await bare.close();
  });
});
